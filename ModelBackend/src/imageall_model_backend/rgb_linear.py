from __future__ import annotations

import io
import json
import math
from dataclasses import dataclass

from PIL import Image, ImageOps

from imageall_model_backend.providers import (
    StandardProviderIdentity,
    StandardProviderScore,
)
from imageall_model_backend.standard_pack import StandardPack


@dataclass(frozen=True)
class _LinearLabel:
    provider_label: str
    weights: tuple[float, float, float]
    bias: float


class RGBLinearSceneProvider:
    def __init__(
        self,
        *,
        identity: StandardProviderIdentity,
        labels: tuple[_LinearLabel, ...],
    ) -> None:
        self.identity = identity
        self._labels = labels

    @classmethod
    def from_pack(cls, pack: StandardPack) -> RGBLinearSceneProvider:
        payload = json.loads(pack.model_path.read_text(encoding="utf-8"))
        if payload["feature_revision"] != pack.provider_identity.preprocessing_revision:
            raise ValueError("model feature revision does not match package identity")
        labels = tuple(
            _LinearLabel(
                provider_label=entry["provider_label"],
                weights=tuple(float(value) for value in entry["weights"]),
                bias=float(entry["bias"]),
            )
            for entry in payload["labels"]
        )
        return cls(identity=pack.provider_identity, labels=labels)

    def predict(self, image_bytes: bytes) -> list[StandardProviderScore]:
        with Image.open(io.BytesIO(image_bytes)) as opened:
            image = ImageOps.exif_transpose(opened).convert("RGB")
            mean_pixel = image.resize((1, 1), Image.Resampling.BOX).getpixel((0, 0))
        features = tuple(channel / 255.0 for channel in mean_pixel)
        return [
            StandardProviderScore(
                provider_label=label.provider_label,
                score=1.0
                / (
                    1.0
                    + math.exp(
                        -(
                            sum(
                                weight * feature
                                for weight, feature in zip(
                                    label.weights, features, strict=True
                                )
                            )
                            + label.bias
                        )
                    )
                ),
            )
            for label in self._labels
        ]
