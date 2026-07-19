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


def test_cli_serves_embeddings_with_a_coreml_artifact(
    tmp_path, monkeypatch
) -> None:
    identity = EmbeddingProviderIdentity(
        provider="dinov2",
        model_id="fixture-coreml-dinov2",
        model_revision="fixture-coreml-revision",
        preprocessing_revision="fixture-coreml-preprocessing",
        element_count=3,
    )

    class FakeCoreMLProvider:
        def __init__(
            self, *, artifact_path, cache_dir, local_files_only
        ) -> None:
            assert artifact_path == tmp_path / "coreml-bundle"
            assert cache_dir is None
            assert local_files_only is True

        def embed(self, image_bytes: bytes) -> list[float]:
            assert image_bytes.startswith(b"\x89PNG\r\n\x1a\n")
            return [0.25, -0.5, 1.0]

    FakeCoreMLProvider.identity = identity
    captured: dict[str, object] = {}

    def fake_run(app, *, host: str, port: int) -> None:
        captured.update(app=app, host=host, port=port)

    monkeypatch.setattr(
        "imageall_model_backend.dinov2.CoreMLDinoV2SmallProvider",
        FakeCoreMLProvider,
    )
    monkeypatch.setattr(cli.uvicorn, "run", fake_run)

    exit_code = cli.main(
        [
            "--provider",
            "coreml",
            "--coreml-bundle",
            str(tmp_path / "coreml-bundle"),
            "--offline",
        ]
    )

    image = Image.new("RGB", (8, 8), color=(32, 64, 128))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    response = TestClient(captured["app"]).post(
        "/v1/embeddings",
        json={
            "request_id": "coreml-cli-request",
            "image_base64": base64.b64encode(buffer.getvalue()).decode("ascii"),
        },
    )

    assert exit_code == 0
    assert captured["host"] == "127.0.0.1"
    assert response.status_code == 200
    assert response.json()["provider"] == "dinov2"
    assert response.json()["embedding"] == [0.25, -0.5, 1.0]


def test_cli_enables_the_versioned_embedding_cache_explicitly(
    tmp_path, monkeypatch
) -> None:
    def png_base64(color: tuple[int, int, int]) -> str:
        image = Image.new("RGB", (8, 8), color=color)
        buffer = io.BytesIO()
        image.save(buffer, format="PNG")
        return base64.b64encode(buffer.getvalue()).decode("ascii")

    class FakeDinoProvider:
        identity = EmbeddingProviderIdentity(
            provider="dinov2",
            model_id="fixture-dinov2",
            model_revision="fixture-model-revision",
            preprocessing_revision="fixture-preprocessing-revision",
            element_count=2,
        )
        call_count = 0

        def __init__(self, *, cache_dir, local_files_only) -> None:
            assert cache_dir is None
            assert local_files_only is True

        def embed(self, image_bytes: bytes) -> list[float]:
            assert image_bytes.startswith(b"\x89PNG\r\n\x1a\n")
            type(self).call_count += 1
            return [float(type(self).call_count), 0.0]

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
            "--embedding-cache",
            str(tmp_path / "embeddings.sqlite3"),
            "--offline",
        ]
    )
    cache_key = {
        "schema_revision": 1,
        "catalog_scope_id": "11111111-1111-4111-8111-111111111111",
        "asset_id": "22222222-2222-4222-8222-222222222222",
        "content_revision": "7",
    }
    client = TestClient(captured["app"])
    first = client.post(
        "/v1/embeddings",
        json={
            "request_id": "first-cli-cache-request",
            "image_base64": png_base64((32, 64, 128)),
            "cache_key": cache_key,
        },
    )
    second = client.post(
        "/v1/embeddings",
        json={
            "request_id": "second-cli-cache-request",
            "image_base64": png_base64((128, 64, 32)),
            "cache_key": cache_key,
        },
    )

    assert exit_code == 0
    assert first.status_code == 200
    assert second.status_code == 200
    assert first.json()["embedding"] == [1.0, 0.0]
    assert second.json()["embedding"] == [1.0, 0.0]
    assert FakeDinoProvider.call_count == 1


def test_cli_rejects_coreml_without_an_artifact(monkeypatch) -> None:
    def unexpected_provider(**kwargs):
        raise AssertionError(f"provider should not be created: {kwargs}")

    monkeypatch.setattr(
        "imageall_model_backend.dinov2.CoreMLDinoV2SmallProvider",
        unexpected_provider,
    )

    with pytest.raises(SystemExit, match="2"):
        cli.main(["--provider", "coreml"])


def test_cli_rejects_a_coreml_artifact_for_another_provider(
    tmp_path, monkeypatch
) -> None:
    def unexpected_run(*args, **kwargs):
        raise AssertionError("server should not start")

    monkeypatch.setattr(cli.uvicorn, "run", unexpected_run)

    with pytest.raises(SystemExit, match="2"):
        cli.main(["--coreml-bundle", str(tmp_path / "coreml-bundle")])


def test_cli_fails_closed_when_the_coreml_artifact_cannot_be_loaded(
    tmp_path, monkeypatch
) -> None:
    def unexpected_run(*args, **kwargs):
        raise AssertionError("server should not start")

    monkeypatch.setattr(cli.uvicorn, "run", unexpected_run)

    with pytest.raises(SystemExit, match="2"):
        cli.main(
            [
                "--provider",
                "coreml",
                "--coreml-bundle",
                str(tmp_path / "missing-coreml-bundle"),
                "--offline",
            ]
        )


@pytest.mark.parametrize("provider_name", ("dinov2", "coreml"))
def test_cli_serves_a_catalog_scoped_personal_bundle(
    tmp_path, monkeypatch, provider_name
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
        def __init__(
            self,
            *,
            cache_dir,
            local_files_only,
            artifact_path=None,
        ) -> None:
            assert cache_dir is None
            assert local_files_only is True
            assert artifact_path == (
                tmp_path / "coreml-bundle"
                if provider_name == "coreml"
                else None
            )

        def embed(self, image_bytes: bytes) -> list[float]:
            assert image_bytes.startswith(b"\x89PNG\r\n\x1a\n")
            return [2.0, 0.0]

    FakeDinoProvider.identity = identity

    captured: dict[str, object] = {}

    def fake_run(app, *, host: str, port: int) -> None:
        captured.update(app=app, host=host, port=port)

    provider_class = (
        "CoreMLDinoV2SmallProvider"
        if provider_name == "coreml"
        else "DinoV2SmallProvider"
    )
    monkeypatch.setattr(
        f"imageall_model_backend.dinov2.{provider_class}",
        FakeDinoProvider,
    )
    monkeypatch.setattr(cli.uvicorn, "run", fake_run)

    arguments = ["--provider", provider_name]
    if provider_name == "coreml":
        arguments.extend(
            ["--coreml-bundle", str(tmp_path / "coreml-bundle")]
        )
    arguments.extend(
        ["--personal-bundle", str(result.bundle_path), "--offline"]
    )
    exit_code = cli.main(arguments)

    image = Image.new("RGB", (8, 8), color=(32, 64, 128))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    client = TestClient(captured["app"])
    capability_response = client.get("/v1/capabilities")
    personal = capability_response.json()["personal"]
    response = client.post(
        "/v1/suggestions",
        json={
            "request_id": "personal-cli-request",
            "image_base64": base64.b64encode(buffer.getvalue()).decode("ascii"),
            "target": {
                "track": "personal",
                "catalog_scope_id": personal["catalog_scope_id"],
                "bundle_id": personal["bundle_id"],
                "bundle_revision": personal["bundle_revision"],
                **personal["encoder"],
                "label_vocabulary_revision": personal[
                    "label_vocabulary_revision"
                ],
                "weights_sha256": personal["weights_sha256"],
                "policy_revision": personal["policy_revision"],
            },
        },
    )

    assert exit_code == 0
    assert captured["host"] == "127.0.0.1"
    assert capability_response.status_code == 200
    assert personal["status"] == "available"
    assert personal["tag_ids"] == ["tag-trip"]
    assert response.status_code == 200
    assert [item["tag_id"] for item in response.json()["suggestions"]] == [
        "tag-trip"
    ]


def test_cli_rejects_a_personal_bundle_without_an_embedding_provider() -> None:
    with pytest.raises(SystemExit, match="2"):
        cli.main(["--provider", "none", "--personal-bundle", "/tmp/bundle"])


def test_cli_starts_with_an_empty_managed_personal_store(
    tmp_path, monkeypatch
) -> None:
    class FakeDinoProvider:
        identity = EmbeddingProviderIdentity(
            provider="dinov2",
            model_id="fixture-dinov2",
            model_revision="fixture-model-revision",
            preprocessing_revision="fixture-preprocessing-revision",
            element_count=2,
        )

        def __init__(self, *, cache_dir, local_files_only) -> None:
            assert cache_dir is None
            assert local_files_only is True

        def embed(self, image_bytes: bytes) -> list[float]:
            raise AssertionError("empty store capability must not embed an image")

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
            "--personal-store",
            str(tmp_path / "personal-store"),
            "--offline",
        ]
    )

    response = TestClient(captured["app"]).get("/v1/capabilities")
    assert exit_code == 0
    assert captured["host"] == "127.0.0.1"
    assert response.status_code == 200
    assert response.json()["personal"] == {"status": "unavailable"}


@pytest.mark.parametrize("manifest_contents", (None, "[]"))
def test_cli_fails_closed_when_the_personal_bundle_cannot_be_loaded(
    tmp_path, monkeypatch, manifest_contents
) -> None:
    class FakeDinoProvider:
        identity = EmbeddingProviderIdentity(
            provider="dinov2",
            model_id="fixture-dinov2",
            model_revision="fixture-model-revision",
            preprocessing_revision="fixture-preprocessing-revision",
            element_count=2,
        )

        def __init__(self, *, cache_dir, local_files_only) -> None:
            assert cache_dir is None
            assert local_files_only is True

    def unexpected_run(*args, **kwargs):
        raise AssertionError("server should not start")

    monkeypatch.setattr(
        "imageall_model_backend.dinov2.DinoV2SmallProvider",
        FakeDinoProvider,
    )
    monkeypatch.setattr(cli.uvicorn, "run", unexpected_run)
    bundle_path = tmp_path / "invalid-personal-bundle"
    if manifest_contents is not None:
        bundle_path.mkdir()
        (bundle_path / "manifest.json").write_text(
            manifest_contents,
            encoding="utf-8",
        )

    with pytest.raises(SystemExit, match="2"):
        cli.main(
            [
                "--provider",
                "dinov2",
                "--personal-bundle",
                str(bundle_path),
                "--offline",
            ]
        )


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
