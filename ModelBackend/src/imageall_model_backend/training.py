from __future__ import annotations

import hashlib
import json
import os
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np
import torch

from imageall_model_backend.providers import EmbeddingProviderIdentity


@dataclass(frozen=True)
class LinearHeadTrainingConfig:
    epochs: int = 100
    learning_rate: float = 0.01


@dataclass(frozen=True)
class LinearHeadTrainingResult:
    bundle_path: Path
    device: str
    final_loss: float
    training_logits: np.ndarray


@dataclass(frozen=True)
class LinearHeadBundle:
    labels: tuple[str, ...]
    label_vocabulary_revision: str
    encoder_identity: EmbeddingProviderIdentity
    weights: np.ndarray
    bias: np.ndarray

    def predict_logits(self, embeddings: np.ndarray) -> np.ndarray:
        values = np.asarray(embeddings, dtype=np.float32)
        return values @ self.weights.T + self.bias


def _training_device() -> torch.device:
    return torch.device("mps" if torch.backends.mps.is_available() else "cpu")


def train_linear_head(
    *,
    embeddings: np.ndarray,
    targets: np.ndarray,
    labels: list[str],
    label_vocabulary_revision: str,
    encoder_identity: EmbeddingProviderIdentity,
    output_dir: Path,
    config: LinearHeadTrainingConfig,
) -> LinearHeadTrainingResult:
    values = np.asarray(embeddings, dtype=np.float32)
    expected = np.asarray(targets, dtype=np.float32)
    if values.ndim != 2 or values.shape[1] != encoder_identity.element_count:
        raise ValueError("embedding width does not match encoder identity")
    device = _training_device()

    torch.manual_seed(0)
    model = torch.nn.Linear(values.shape[1], len(labels)).to(device)
    input_tensor = torch.from_numpy(values).to(device)
    target_tensor = torch.from_numpy(expected).to(device)
    optimizer = torch.optim.Adam(model.parameters(), lr=config.learning_rate)
    loss_function = torch.nn.BCEWithLogitsLoss()

    final_loss = 0.0
    for _ in range(config.epochs):
        optimizer.zero_grad()
        logits = model(input_tensor)
        loss = loss_function(logits, target_tensor)
        loss.backward()
        optimizer.step()
        final_loss = float(loss.detach().cpu())

    with torch.inference_mode():
        training_logits = model(input_tensor).detach().cpu().numpy().astype(np.float32)
        weights = model.weight.detach().cpu().numpy().astype(np.float32)
        bias = model.bias.detach().cpu().numpy().astype(np.float32)

    output_dir.mkdir(parents=True, exist_ok=False)
    weights_path = output_dir / "linear-head.npz"
    with tempfile.NamedTemporaryFile(dir=output_dir, delete=False) as temporary_weights:
        temporary_weights_path = Path(temporary_weights.name)
        np.savez(temporary_weights, weights=weights, bias=bias)
    os.replace(temporary_weights_path, weights_path)

    weights_hash = hashlib.sha256(weights_path.read_bytes()).hexdigest()
    manifest = {
        "schema_revision": 1,
        "encoder": asdict(encoder_identity),
        "labels": labels,
        "label_vocabulary_revision": label_vocabulary_revision,
        "training": {
            "device": device.type,
            "epochs": config.epochs,
            "learning_rate": config.learning_rate,
            "final_loss": final_loss,
        },
        "weights_sha256": weights_hash,
    }
    manifest_path = output_dir / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    return LinearHeadTrainingResult(
        bundle_path=output_dir,
        device=device.type,
        final_loss=final_loss,
        training_logits=training_logits,
    )


def load_linear_head(bundle_path: Path) -> LinearHeadBundle:
    manifest = json.loads((bundle_path / "manifest.json").read_text(encoding="utf-8"))
    weights_path = bundle_path / "linear-head.npz"
    actual_hash = hashlib.sha256(weights_path.read_bytes()).hexdigest()
    if actual_hash != manifest["weights_sha256"]:
        raise ValueError("linear head weights hash does not match manifest")

    encoder = EmbeddingProviderIdentity(**manifest["encoder"])
    with np.load(weights_path, allow_pickle=False) as data:
        weights = np.asarray(data["weights"], dtype=np.float32)
        bias = np.asarray(data["bias"], dtype=np.float32)
    return LinearHeadBundle(
        labels=tuple(manifest["labels"]),
        label_vocabulary_revision=manifest["label_vocabulary_revision"],
        encoder_identity=encoder,
        weights=weights,
        bias=bias,
    )
