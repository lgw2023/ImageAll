from __future__ import annotations

import io
from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageOps

from imageall_model_backend.providers import EmbeddingProviderIdentity

DINO_V2_SMALL_MODEL_ID = "facebook/dinov2-small"
DINO_V2_SMALL_REVISION = "ed25f3a31f01632728cabb09d1542f84ab7b0056"


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
        from transformers import AutoImageProcessor, AutoModel

        self._device = torch.device(
            device
            or ("mps" if torch.backends.mps.is_available() else "cpu")
        )
        load_options = {
            "revision": DINO_V2_SMALL_REVISION,
            "local_files_only": local_files_only,
        }
        if cache_dir is not None:
            load_options["cache_dir"] = str(cache_dir)
        self._processor = AutoImageProcessor.from_pretrained(
            DINO_V2_SMALL_MODEL_ID,
            use_fast=False,
            **load_options,
        )
        self._model = AutoModel.from_pretrained(
            DINO_V2_SMALL_MODEL_ID,
            **load_options,
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
