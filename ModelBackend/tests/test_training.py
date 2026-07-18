import hashlib
import json

import numpy as np
import pytest
import torch

from imageall_model_backend.providers import EmbeddingProviderIdentity
from imageall_model_backend.training import (
    LinearHeadTrainingConfig,
    load_linear_head,
    train_linear_head,
)


def test_linear_head_trains_on_the_mac_device_and_reloads_the_same_bundle(tmp_path) -> None:
    embeddings = np.asarray(
        [
            [-2.0, -1.0],
            [-1.0, -2.0],
            [1.0, 2.0],
            [2.0, 1.0],
        ],
        dtype=np.float32,
    )
    targets = np.asarray([[0.0], [0.0], [1.0], [1.0]], dtype=np.float32)
    identity = EmbeddingProviderIdentity(
        provider="fixture",
        model_id="fixture-encoder",
        model_revision="fixture-model-revision",
        preprocessing_revision="fixture-preprocessing-v1",
        element_count=2,
    )

    result = train_linear_head(
        embeddings=embeddings,
        targets=targets,
        labels=["positive"],
        label_vocabulary_revision="fixture-labels-v1",
        encoder_identity=identity,
        output_dir=tmp_path / "bundle",
        config=LinearHeadTrainingConfig(epochs=80, learning_rate=0.1),
    )

    assert result.device == ("mps" if torch.backends.mps.is_available() else "cpu")
    assert result.final_loss < 0.1
    manifest = json.loads((result.bundle_path / "manifest.json").read_text())
    weights_path = result.bundle_path / "linear-head.npz"
    assert manifest["schema_revision"] == 1
    assert manifest["encoder"] == {
        "provider": "fixture",
        "model_id": "fixture-encoder",
        "model_revision": "fixture-model-revision",
        "preprocessing_revision": "fixture-preprocessing-v1",
        "element_count": 2,
    }
    assert manifest["labels"] == ["positive"]
    assert manifest["label_vocabulary_revision"] == "fixture-labels-v1"
    assert manifest["weights_sha256"] == hashlib.sha256(weights_path.read_bytes()).hexdigest()

    bundle = load_linear_head(result.bundle_path)
    logits = bundle.predict_logits(embeddings)

    assert logits.shape == (4, 1)
    assert np.all(logits[:2, 0] < 0)
    assert np.all(logits[2:, 0] > 0)
    np.testing.assert_allclose(logits, result.training_logits, rtol=1e-6, atol=1e-6)


def test_linear_head_rejects_embeddings_from_a_different_encoder_shape(tmp_path) -> None:
    identity = EmbeddingProviderIdentity(
        provider="fixture",
        model_id="fixture-encoder",
        model_revision="fixture-model-revision",
        preprocessing_revision="fixture-preprocessing-v1",
        element_count=3,
    )

    with pytest.raises(ValueError, match="embedding width does not match encoder identity"):
        train_linear_head(
            embeddings=np.zeros((2, 2), dtype=np.float32),
            targets=np.zeros((2, 1), dtype=np.float32),
            labels=["positive"],
            label_vocabulary_revision="fixture-labels-v1",
            encoder_identity=identity,
            output_dir=tmp_path / "bundle",
            config=LinearHeadTrainingConfig(epochs=1, learning_rate=0.1),
        )
