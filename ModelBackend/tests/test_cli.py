import base64
import io
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from imageall_model_backend import cli
from imageall_model_backend.personal_training import (
    PersonalTrainingInput,
    train_personal_linear_head,
)
from imageall_model_backend.providers import EmbeddingProviderIdentity
from imageall_model_backend.training import LinearHeadTrainingConfig

PUBLIC_FIXTURE_PACK = (
    Path(__file__).parents[1] / "fixtures" / "standard-scene-pack-v1"
)


def test_cli_serves_only_on_loopback(monkeypatch) -> None:
    captured: dict[str, object] = {}

    def fake_run(app, *, host: str, port: int) -> None:
        captured.update(app=app, host=host, port=port)

    monkeypatch.setattr(cli.uvicorn, "run", fake_run)

    exit_code = cli.main(["--provider", "none", "--port", "9876"])

    assert exit_code == 0
    assert captured["host"] == "127.0.0.1"
    assert captured["port"] == 9876
    assert captured["app"] is not None


def test_cli_serves_a_catalog_scoped_personal_bundle(
    tmp_path, monkeypatch
) -> None:
    identity = EmbeddingProviderIdentity(
        provider="dinov2",
        model_id="fixture-dinov2",
        model_revision="fixture-model-revision",
        preprocessing_revision="fixture-preprocessing-revision",
        element_count=2,
    )
    training_input = PersonalTrainingInput(
        catalog_scope_id="catalog-fixture",
        decision_snapshot_revision="decisions-v1",
        encoder_identity=identity,
        personal_tag_ids=("tag-trip",),
        label_vocabulary_revision="personal-tags-v1",
        asset_ids=("asset-1", "asset-2", "asset-3", "asset-4"),
        content_revisions=("r1", "r1", "r1", "r1"),
        embeddings=np.asarray(
            [[-2.0, 0.0], [-1.0, 0.0], [1.0, 0.0], [2.0, 0.0]],
            dtype=np.float32,
        ),
        targets=np.asarray([[0.0], [0.0], [1.0], [1.0]], dtype=np.float32),
        observation_mask=np.ones((4, 1), dtype=np.bool_),
    )
    result = train_personal_linear_head(
        training_input=training_input,
        output_dir=tmp_path / "personal-bundle",
        bundle_id="personal-fixture",
        bundle_revision="bundle-v1",
        config=LinearHeadTrainingConfig(epochs=40, learning_rate=0.1),
    )

    class FakeDinoProvider:
        def __init__(self, *, cache_dir, local_files_only) -> None:
            assert cache_dir is None
            assert local_files_only is True

        def embed(self, image_bytes: bytes) -> list[float]:
            assert image_bytes.startswith(b"\x89PNG\r\n\x1a\n")
            return [2.0, 0.0]

    FakeDinoProvider.identity = identity

    captured: dict[str, object] = {}

    def fake_run(app, *, host: str, port: int) -> None:
        captured.update(app=app, host=host, port=port)

    monkeypatch.setattr(
        "imageall_model_backend.dinov2.DinoV2SmallProvider",
        FakeDinoProvider,
    )
    monkeypatch.setattr(cli.uvicorn, "run", fake_run)

    exit_code = cli.main(
        [
            "--provider",
            "dinov2",
            "--personal-bundle",
            str(result.bundle_path),
            "--offline",
        ]
    )

    image = Image.new("RGB", (8, 8), color=(32, 64, 128))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    response = TestClient(captured["app"]).post(
        "/v1/suggestions",
        json={
            "request_id": "personal-cli-request",
            "image_base64": base64.b64encode(buffer.getvalue()).decode("ascii"),
            "target": {
                "track": "personal",
                "catalog_scope_id": "catalog-fixture",
                "bundle_id": "personal-fixture",
                "bundle_revision": "bundle-v1",
                "label_vocabulary_revision": "personal-tags-v1",
            },
        },
    )

    assert exit_code == 0
    assert captured["host"] == "127.0.0.1"
    assert response.status_code == 200
    assert [item["tag_id"] for item in response.json()["suggestions"]] == [
        "tag-trip"
    ]


def test_cli_rejects_a_personal_bundle_without_a_dino_provider() -> None:
    with pytest.raises(SystemExit, match="2"):
        cli.main(["--provider", "none", "--personal-bundle", "/tmp/bundle"])


def test_cli_serves_a_validated_standard_pack(monkeypatch) -> None:
    captured: dict[str, object] = {}

    def fake_run(app, *, host: str, port: int) -> None:
        captured.update(app=app, host=host, port=port)

    monkeypatch.setattr(cli.uvicorn, "run", fake_run)

    exit_code = cli.main(["--standard-pack", str(PUBLIC_FIXTURE_PACK)])

    image = Image.new("RGB", (8, 8), color=(0, 0, 255))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    response = TestClient(captured["app"]).post(
        "/v1/suggestions",
        json={
            "request_id": "standard-cli-request",
            "image_base64": base64.b64encode(buffer.getvalue()).decode("ascii"),
            "target": {
                "track": "standard",
                "standard_pack_id": "imageall-public-fixture",
                "standard_pack_revision": "pack-v1",
            },
        },
    )

    assert exit_code == 0
    assert captured["host"] == "127.0.0.1"
    assert response.status_code == 200
    assert [item["concept_id"] for item in response.json()["suggestions"]] == [
        "scene.water"
    ]
