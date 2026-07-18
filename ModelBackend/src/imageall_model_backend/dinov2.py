from __future__ import annotations

import io
import math
from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageOps

from imageall_model_backend.providers import EmbeddingProviderIdentity

DINO_V2_SMALL_MODEL_ID = "facebook/dinov2-small"
DINO_V2_SMALL_REVISION = "ed25f3a31f01632728cabb09d1542f84ab7b0056"
DINO_V2_SMALL_INPUT_SHAPE = (1, 3, 224, 224)


class DinoV2SmallEmbeddingModel(torch.nn.Module):
    def __init__(self, model: torch.nn.Module) -> None:
        super().__init__()
        self.model = model
        embeddings = model.embeddings
        patch_size = embeddings.patch_size
        input_height = DINO_V2_SMALL_INPUT_SHAPE[2]
        input_width = DINO_V2_SMALL_INPUT_SHAPE[3]
        position_embeddings = embeddings.position_embeddings
        class_position = position_embeddings[:, :1]
        patch_positions = position_embeddings[:, 1:]
        position_grid_size = math.isqrt(patch_positions.shape[1])
        if position_grid_size**2 != patch_positions.shape[1]:
            raise ValueError("DINOv2 position embedding grid is invalid")
        patch_positions = patch_positions.reshape(
            1,
            position_grid_size,
            position_grid_size,
            position_embeddings.shape[-1],
        ).permute(0, 3, 1, 2)
        patch_positions = torch.nn.functional.interpolate(
            patch_positions.to(torch.float32),
            size=(input_height // patch_size, input_width // patch_size),
            mode="bicubic",
            align_corners=False,
        ).to(dtype=position_embeddings.dtype)
        patch_positions = patch_positions.permute(0, 2, 3, 1).reshape(
            1,
            -1,
            position_embeddings.shape[-1],
        )
        self.register_buffer(
            "static_position_embeddings",
            torch.cat((class_position, patch_positions), dim=1),
        )

    def forward(self, pixel_values: torch.Tensor) -> torch.Tensor:
        embeddings_module = self.model.embeddings
        target_dtype = embeddings_module.patch_embeddings.projection.weight.dtype
        embeddings = embeddings_module.patch_embeddings.projection(
            pixel_values.to(dtype=target_dtype)
        ).flatten(2).transpose(1, 2)
        class_tokens = embeddings_module.cls_token
        embeddings = torch.cat((class_tokens, embeddings), dim=1)
        embeddings = embeddings + self.static_position_embeddings
        embeddings = embeddings_module.dropout(embeddings)
        encoded = self.model.encoder(
            embeddings,
            head_mask=None,
            output_hidden_states=False,
        ).last_hidden_state
        return self.model.layernorm(encoded)[:, 0, :]


def load_dinov2_small_embedding_model(
    *,
    cache_dir: Path | None = None,
    local_files_only: bool = False,
) -> DinoV2SmallEmbeddingModel:
    return DinoV2SmallEmbeddingModel(
        _load_dinov2_small_model(
            cache_dir=cache_dir,
            local_files_only=local_files_only,
        )
    )


def _load_dinov2_small_model(
    *,
    cache_dir: Path | None,
    local_files_only: bool,
) -> torch.nn.Module:
    from transformers import AutoModel

    load_options = _load_options(
        cache_dir=cache_dir,
        local_files_only=local_files_only,
    )
    return AutoModel.from_pretrained(
        DINO_V2_SMALL_MODEL_ID,
        **load_options,
    ).eval()


def load_dinov2_small_image_processor(
    *,
    cache_dir: Path | None = None,
    local_files_only: bool = False,
):
    from transformers import AutoImageProcessor

    return AutoImageProcessor.from_pretrained(
        DINO_V2_SMALL_MODEL_ID,
        use_fast=False,
        **_load_options(
            cache_dir=cache_dir,
            local_files_only=local_files_only,
        ),
    )


class DinoV2SmallProvider:
    identity = EmbeddingProviderIdentity(
        provider="dinov2",
        model_id=DINO_V2_SMALL_MODEL_ID,
        model_revision=DINO_V2_SMALL_REVISION,
        preprocessing_revision="dinov2-hf-autoimageprocessor-v1",
        element_count=384,
    )

    def __init__(
        self,
        *,
        device: str | None = None,
        cache_dir: Path | None = None,
        local_files_only: bool = False,
    ) -> None:
        self._device = torch.device(
            device
            or ("mps" if torch.backends.mps.is_available() else "cpu")
        )
        self._processor = load_dinov2_small_image_processor(
            cache_dir=cache_dir,
            local_files_only=local_files_only,
        )
        self._model = _load_dinov2_small_model(
            cache_dir=cache_dir,
            local_files_only=local_files_only,
        ).to(self._device)
        self._model.eval()

    @property
    def device(self) -> str:
        return self._device.type

    def embed(self, image_bytes: bytes) -> list[float]:
        with Image.open(io.BytesIO(image_bytes)) as opened:
            image = ImageOps.exif_transpose(opened).convert("RGB")
        inputs = self._processor(images=image, return_tensors="pt")
        inputs = {name: value.to(self._device) for name, value in inputs.items()}
        with torch.inference_mode():
            outputs = self._model(**inputs)
            vector = outputs.last_hidden_state[:, 0, :].detach().cpu().numpy()[0]
        embedding = np.asarray(vector, dtype=np.float32)
        if embedding.shape != (self.identity.element_count,) or not np.isfinite(
            embedding
        ).all():
            raise RuntimeError("DINOv2 returned an invalid embedding")
        return embedding.tolist()


def _load_options(
    *,
    cache_dir: Path | None,
    local_files_only: bool,
) -> dict[str, object]:
    options: dict[str, object] = {
        "revision": DINO_V2_SMALL_REVISION,
        "local_files_only": local_files_only,
    }
    if cache_dir is not None:
        options["cache_dir"] = str(cache_dir)
    return options
