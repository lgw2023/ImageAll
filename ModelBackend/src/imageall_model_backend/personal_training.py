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
from imageall_model_backend.training import LinearHeadTrainingConfig


@dataclass(frozen=True)
class PersonalTrainingInput:
    catalog_scope_id: str
    decision_snapshot_revision: str
    encoder_identity: EmbeddingProviderIdentity
    personal_tag_ids: tuple[str, ...]
    label_vocabulary_revision: str
    asset_ids: tuple[str, ...]
    content_revisions: tuple[str, ...]
    embeddings: np.ndarray
    targets: np.ndarray
    observation_mask: np.ndarray


@dataclass(frozen=True)
class PersonalLinearHeadTrainingResult:
    bundle_path: Path
    device: str
    final_loss: float


@dataclass(frozen=True)
class PersonalLinearHeadBundle:
    bundle_id: str
    bundle_revision: str
    catalog_scope_id: str
    decision_snapshot_revision: str
    encoder_identity: EmbeddingProviderIdentity
    personal_tag_ids: tuple[str, ...]
    label_vocabulary_revision: str
    weights: np.ndarray
    bias: np.ndarray

    def predict_logits(self, embeddings: np.ndarray) -> np.ndarray:
        values = np.asarray(embeddings, dtype=np.float32)
        if values.ndim != 2 or values.shape[1] != self.encoder_identity.element_count:
            raise ValueError("embedding width does not match encoder identity")
        return values @ self.weights.T + self.bias


def load_personal_training_input(root: Path) -> PersonalTrainingInput:
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("schema_revision") != 1:
        raise ValueError("unsupported personal training input schema")
    if manifest.get("track") != "personal":
        raise ValueError("training input track is not personal")
    for filename in ("embeddings.npz", "decisions.jsonl"):
        actual_hash = hashlib.sha256((root / filename).read_bytes()).hexdigest()
        if actual_hash != manifest["files"][filename]["sha256"]:
            raise ValueError(f"{filename} checksum mismatch")
    encoder = EmbeddingProviderIdentity(**manifest["encoder"])
    tag_ids = tuple(manifest["personal_tag_ids"])

    with np.load(root / "embeddings.npz", allow_pickle=False) as payload:
        asset_ids = tuple(str(value) for value in payload["asset_ids"])
        content_revisions = tuple(str(value) for value in payload["content_revisions"])
        embeddings = np.asarray(payload["embeddings"], dtype=np.float32)
    if (
        embeddings.ndim != 2
        or embeddings.shape != (len(asset_ids), encoder.element_count)
        or len(content_revisions) != len(asset_ids)
        or not np.isfinite(embeddings).all()
    ):
        raise ValueError("embedding matrix does not match encoder identity")

    asset_index = {
        (asset_id, content_revision): index
        for index, (asset_id, content_revision) in enumerate(
            zip(asset_ids, content_revisions, strict=True)
        )
    }
    tag_index = {tag_id: index for index, tag_id in enumerate(tag_ids)}
    targets = np.zeros((len(asset_ids), len(tag_ids)), dtype=np.float32)
    observation_mask = np.zeros_like(targets, dtype=np.bool_)
    seen_decisions: set[tuple[int, int]] = set()

    for line in (root / "decisions.jsonl").read_text(encoding="utf-8").splitlines():
        decision = json.loads(line)
        asset_key = (decision["asset_id"], decision["content_revision"])
        if asset_key not in asset_index:
            raise ValueError("decision references missing embedding")
        row = asset_index[asset_key]
        if decision["tag_id"] not in tag_index:
            raise ValueError("decision references unknown personal tag")
        column = tag_index[decision["tag_id"]]
        if (row, column) in seen_decisions:
            raise ValueError("duplicate personal decision")
        seen_decisions.add((row, column))
        if decision["state"] == "manualAccepted":
            targets[row, column] = 1.0
        elif decision["state"] != "manualRejected":
            raise ValueError("decision state must be manualAccepted or manualRejected")
        observation_mask[row, column] = True

    return PersonalTrainingInput(
        catalog_scope_id=manifest["catalog_scope_id"],
        decision_snapshot_revision=manifest["decision_snapshot_revision"],
        encoder_identity=encoder,
        personal_tag_ids=tag_ids,
        label_vocabulary_revision=manifest["label_vocabulary_revision"],
        asset_ids=asset_ids,
        content_revisions=content_revisions,
        embeddings=embeddings,
        targets=targets,
        observation_mask=observation_mask,
    )


def train_personal_linear_head(
    *,
    training_input: PersonalTrainingInput,
    output_dir: Path,
    bundle_id: str,
    bundle_revision: str,
    config: LinearHeadTrainingConfig,
) -> PersonalLinearHeadTrainingResult:
    if config.epochs <= 0 or config.learning_rate <= 0:
        raise ValueError("training configuration must be positive")
    positive_counts = np.sum(
        training_input.observation_mask & (training_input.targets == 1.0), axis=0
    )
    negative_counts = np.sum(
        training_input.observation_mask & (training_input.targets == 0.0), axis=0
    )
    for index, tag_id in enumerate(training_input.personal_tag_ids):
        if positive_counts[index] < 2 or negative_counts[index] < 2:
            raise ValueError(
                f"personal tag {tag_id} requires at least 2 positive "
                "and 2 negative decisions"
            )

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    torch.manual_seed(0)
    model = torch.nn.Linear(
        training_input.embeddings.shape[1], len(training_input.personal_tag_ids)
    ).to(device)
    input_tensor = torch.from_numpy(training_input.embeddings).to(device)
    target_tensor = torch.from_numpy(training_input.targets).to(device)
    mask_tensor = torch.from_numpy(training_input.observation_mask).to(device)
    optimizer = torch.optim.Adam(model.parameters(), lr=config.learning_rate)
    loss_function = torch.nn.BCEWithLogitsLoss(reduction="none")

    final_loss = 0.0
    for _ in range(config.epochs):
        optimizer.zero_grad()
        losses = loss_function(model(input_tensor), target_tensor)
        loss = losses.masked_select(mask_tensor).mean()
        loss.backward()
        optimizer.step()
        final_loss = float(loss.detach().cpu())

    with torch.inference_mode():
        weights = model.weight.detach().cpu().numpy().astype(np.float32)
        bias = model.bias.detach().cpu().numpy().astype(np.float32)

    output_dir.mkdir(parents=True, exist_ok=False)
    weights_path = output_dir / "linear-head.npz"
    with tempfile.NamedTemporaryFile(dir=output_dir, delete=False) as temporary_weights:
        temporary_weights_path = Path(temporary_weights.name)
        np.savez(temporary_weights, weights=weights, bias=bias)
    os.replace(temporary_weights_path, weights_path)

    manifest = {
        "schema_revision": 1,
        "track": "personal",
        "bundle_id": bundle_id,
        "bundle_revision": bundle_revision,
        "catalog_scope_id": training_input.catalog_scope_id,
        "decision_snapshot_revision": training_input.decision_snapshot_revision,
        "encoder": asdict(training_input.encoder_identity),
        "personal_tag_ids": list(training_input.personal_tag_ids),
        "label_vocabulary_revision": training_input.label_vocabulary_revision,
        "sample_counts": {
            tag_id: {
                "positive": int(positive_counts[index]),
                "negative": int(negative_counts[index]),
            }
            for index, tag_id in enumerate(training_input.personal_tag_ids)
        },
        "training": {
            "device": device.type,
            "epochs": config.epochs,
            "learning_rate": config.learning_rate,
            "final_loss": final_loss,
        },
        "weights_sha256": hashlib.sha256(weights_path.read_bytes()).hexdigest(),
    }
    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return PersonalLinearHeadTrainingResult(
        bundle_path=output_dir,
        device=device.type,
        final_loss=final_loss,
    )


def load_personal_linear_head(
    bundle_path: Path,
    *,
    expected_catalog_scope_id: str,
    expected_bundle_id: str,
    expected_bundle_revision: str,
    expected_encoder_identity: EmbeddingProviderIdentity,
    expected_label_vocabulary_revision: str,
) -> PersonalLinearHeadBundle:
    manifest = json.loads((bundle_path / "manifest.json").read_text(encoding="utf-8"))
    if manifest["track"] != "personal":
        raise ValueError("bundle track is not personal")
    if manifest["catalog_scope_id"] != expected_catalog_scope_id:
        raise ValueError("catalog scope mismatch")
    if manifest["bundle_id"] != expected_bundle_id:
        raise ValueError("personal bundle id mismatch")
    if manifest["bundle_revision"] != expected_bundle_revision:
        raise ValueError("personal bundle revision mismatch")
    encoder_identity = EmbeddingProviderIdentity(**manifest["encoder"])
    if encoder_identity != expected_encoder_identity:
        raise ValueError("personal bundle encoder identity mismatch")
    if manifest["label_vocabulary_revision"] != expected_label_vocabulary_revision:
        raise ValueError("personal bundle label vocabulary revision mismatch")
    weights_path = bundle_path / "linear-head.npz"
    if hashlib.sha256(weights_path.read_bytes()).hexdigest() != manifest["weights_sha256"]:
        raise ValueError("personal linear head weights hash does not match manifest")
    with np.load(weights_path, allow_pickle=False) as payload:
        weights = np.asarray(payload["weights"], dtype=np.float32)
        bias = np.asarray(payload["bias"], dtype=np.float32)
    return PersonalLinearHeadBundle(
        bundle_id=manifest["bundle_id"],
        bundle_revision=manifest["bundle_revision"],
        catalog_scope_id=manifest["catalog_scope_id"],
        decision_snapshot_revision=manifest["decision_snapshot_revision"],
        encoder_identity=encoder_identity,
        personal_tag_ids=tuple(manifest["personal_tag_ids"]),
        label_vocabulary_revision=manifest["label_vocabulary_revision"],
        weights=weights,
        bias=bias,
    )
