import io

import numpy as np
import pytest
import torch
from PIL import Image

from imageall_model_backend.coreml_export import convert_embedding_model_to_coreml
from imageall_model_backend.dinov2 import (
    CoreMLDinoV2SmallProvider,
    DinoV2SmallProvider,
)


class _TinyDinoEmbeddingModel(torch.nn.Module):
    def forward(self, pixel_values: torch.Tensor) -> torch.Tensor:
        flattened = pixel_values[:, :, :8, :8].flatten(1)
        return torch.cat((flattened, flattened), dim=1)


class _FixedImageProcessor:
    def __init__(self, pixel_values: np.ndarray) -> None:
        self._pixel_values = pixel_values

    def __call__(self, *, images: Image.Image, return_tensors: str):
        assert images.mode == "RGB"
        assert return_tensors == "np"
        return {"pixel_values": self._pixel_values}


@pytest.mark.skipif(
    not torch.backends.mps.is_built() and not torch.backends.mps.is_available(),
    reason="Core ML conversion is only supported by this project on macOS",
)
def test_coreml_dinov2_provider_embeds_a_generated_png(
    tmp_path, monkeypatch
) -> None:
    pixel_values = np.linspace(
        -1.0,
        1.0,
        num=1 * 3 * 224 * 224,
        dtype=np.float32,
    ).reshape(1, 3, 224, 224)
    artifact_path = tmp_path / "coreml-dinov2"
    convert_embedding_model_to_coreml(
        model=_TinyDinoEmbeddingModel().eval(),
        encoder_identity=DinoV2SmallProvider.identity,
        example_input=torch.from_numpy(pixel_values),
        output_dir=artifact_path,
    )
    monkeypatch.setattr(
        "imageall_model_backend.dinov2.load_dinov2_small_image_processor",
        lambda **_: _FixedImageProcessor(pixel_values),
    )
    image = Image.new("RGB", (12, 10), color=(32, 64, 128))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")

    provider = CoreMLDinoV2SmallProvider(artifact_path=artifact_path)
    embedding = np.asarray(provider.embed(buffer.getvalue()), dtype=np.float32)

    assert provider.identity == DinoV2SmallProvider.identity
    assert embedding.shape == (384,)
    assert np.isfinite(embedding).all()
    assert np.allclose(
        embedding,
        _TinyDinoEmbeddingModel()(torch.from_numpy(pixel_values)).numpy()[0],
        atol=5e-3,
        rtol=5e-3,
    )


@pytest.mark.skipif(
    not torch.backends.mps.is_built() and not torch.backends.mps.is_available(),
    reason="Core ML conversion is only supported by this project on macOS",
)
def test_coreml_dinov2_provider_rejects_a_nonproduction_input_contract(
    tmp_path, monkeypatch
) -> None:
    artifact_path = tmp_path / "wrong-input-shape"
    pixel_values = torch.ones((1, 3, 8, 8), dtype=torch.float32)
    convert_embedding_model_to_coreml(
        model=_TinyDinoEmbeddingModel().eval(),
        encoder_identity=DinoV2SmallProvider.identity,
        example_input=pixel_values,
        output_dir=artifact_path,
    )

    def unexpected_processor(**kwargs):
        raise AssertionError(f"processor should not be loaded: {kwargs}")

    monkeypatch.setattr(
        "imageall_model_backend.dinov2.load_dinov2_small_image_processor",
        unexpected_processor,
    )

    with pytest.raises(ValueError, match="input contract does not match"):
        CoreMLDinoV2SmallProvider(artifact_path=artifact_path)
