import base64
import io
import json
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from imageall_model_backend.personal_suggestions import PersonalSuggestionEngine
from imageall_model_backend.personal_training import (
    PersonalTrainingInput,
    load_personal_linear_head,
    train_personal_linear_head,
)
from imageall_model_backend.providers import EmbeddingProviderIdentity
from imageall_model_backend.rgb_linear import RGBLinearSceneProvider
from imageall_model_backend.service import create_app
from imageall_model_backend.standard_pack import load_standard_pack
from imageall_model_backend.standard_suggestions import StandardSuggestionEngine
from imageall_model_backend.training import LinearHeadTrainingConfig

PUBLIC_FIXTURE_PACK = (
    Path(__file__).parents[1] / "fixtures" / "standard-scene-pack-v1"
)


def standard_suggestion_client() -> TestClient:
    pack = load_standard_pack(PUBLIC_FIXTURE_PACK)
    engine = StandardSuggestionEngine(pack, RGBLinearSceneProvider.from_pack(pack))
    return TestClient(create_app(standard_suggestion_engine=engine))


class FakePersonalEmbeddingProvider:
    identity = EmbeddingProviderIdentity(
        provider="dinov2",
        model_id="facebook/dinov2-small",
        model_revision="fixture-model-revision",
        preprocessing_revision="fixture-preprocessing-revision",
        element_count=2,
    )

    def embed(self, image_bytes: bytes) -> list[float]:
        assert image_bytes.startswith(b"\x89PNG\r\n\x1a\n")
        return [2.0, 0.0]


def personal_suggestion_engine(
    tmp_path: Path,
    provider: FakePersonalEmbeddingProvider | None = None,
) -> PersonalSuggestionEngine:
    identity = FakePersonalEmbeddingProvider.identity
    embeddings = np.asarray(
        [[-2.0, 0.0], [-1.0, 0.0], [1.0, 0.0], [2.0, 0.0]],
        dtype=np.float32,
    )
    training_input = PersonalTrainingInput(
        catalog_scope_id="catalog-fixture",
        decision_snapshot_revision="decisions-v1",
        encoder_identity=identity,
        personal_tag_ids=("tag-trip",),
        label_vocabulary_revision="personal-tags-v1",
        asset_ids=("asset-1", "asset-2", "asset-3", "asset-4"),
        content_revisions=("r1", "r1", "r1", "r1"),
        embeddings=embeddings,
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
    bundle = load_personal_linear_head(
        result.bundle_path,
        expected_catalog_scope_id="catalog-fixture",
        expected_bundle_id="personal-fixture",
        expected_bundle_revision="bundle-v1",
        expected_encoder_identity=identity,
        expected_label_vocabulary_revision="personal-tags-v1",
    )
    return PersonalSuggestionEngine(provider or FakePersonalEmbeddingProvider(), bundle)


def personal_suggestion_client(tmp_path: Path) -> TestClient:
    return TestClient(
        create_app(personal_suggestion_engine=personal_suggestion_engine(tmp_path))
    )


def personal_target(tmp_path: Path) -> dict[str, object]:
    manifest = json.loads(
        (tmp_path / "personal-bundle" / "manifest.json").read_text(
            encoding="utf-8"
        )
    )
    return {
        "track": "personal",
        "catalog_scope_id": "catalog-fixture",
        "bundle_id": "personal-fixture",
        "bundle_revision": "bundle-v1",
        "provider": "dinov2",
        "model_id": "facebook/dinov2-small",
        "model_revision": "fixture-model-revision",
        "preprocessing_revision": "fixture-preprocessing-revision",
        "element_count": 2,
        "label_vocabulary_revision": "personal-tags-v1",
        "weights_sha256": manifest["weights_sha256"],
        "policy_revision": "personal-logit-zero-top10-v1",
    }


def png_base64(color: tuple[int, int, int]) -> str:
    image = Image.new("RGB", (8, 8), color=color)
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return base64.b64encode(buffer.getvalue()).decode("ascii")


def test_service_starts_degraded_without_a_model_provider() -> None:
    client = TestClient(create_app(provider=None))

    health = client.get("/v1/health")
    embedding = client.post(
        "/v1/embeddings",
        json={"request_id": "request-1", "image_base64": "aW1hZ2U="},
    )

    assert health.status_code == 200
    assert health.json() == {
        "status": "degraded",
        "service_version": "0.1.0",
        "provider": None,
    }
    assert embedding.status_code == 503
    assert embedding.json() == {
        "detail": {
            "code": "model_unavailable",
            "message": "No model provider is configured.",
        }
    }


def test_capabilities_reports_unloaded_suggestion_tracks_as_unavailable() -> None:
    client = TestClient(create_app())

    response = client.get("/v1/capabilities")

    assert response.status_code == 200
    assert response.json() == {
        "service_version": "0.1.0",
        "standard": {"status": "unavailable"},
        "personal": {"status": "unavailable"},
    }


def test_capabilities_reports_the_loaded_standard_package_identity() -> None:
    client = standard_suggestion_client()

    response = client.get("/v1/capabilities")

    assert response.status_code == 200
    assert response.json() == {
        "service_version": "0.1.0",
        "standard": {
            "status": "available",
            "standard_pack_id": "imageall-public-fixture",
            "standard_pack_revision": "pack-v1",
            "manifest_sha256": (
                "dc7b0a9a8391978a56b7e55f97c1abc7"
                "3fe9e9834f1c2dd16152fc13883bd873"
            ),
            "ontology_id": "imageall-public-fixture",
            "ontology_revision": "ontology-v1",
            "provider": {
                "provider": "rgb-linear",
                "model_id": "imageall/fixture-scene-linear",
                "model_revision": "model-v1",
                "preprocessing_revision": "rgb-channel-mean-v1",
            },
            "mapping_revision": "mapping-v1",
            "policy_revision": "policy-v1",
            "weights_sha256": (
                "4129427105a9392e02b5306b657a029f"
                "7d0034f05a10d1363254e5f3d579fce9"
            ),
        },
        "personal": {"status": "unavailable"},
    }


def test_capabilities_reports_the_loaded_personal_bundle_identity(
    tmp_path: Path,
) -> None:
    client = personal_suggestion_client(tmp_path)
    manifest = json.loads(
        (tmp_path / "personal-bundle" / "manifest.json").read_text(
            encoding="utf-8"
        )
    )

    response = client.get("/v1/capabilities")

    assert response.status_code == 200
    assert response.json() == {
        "service_version": "0.1.0",
        "standard": {"status": "unavailable"},
        "personal": {
            "status": "available",
            "catalog_scope_id": "catalog-fixture",
            "bundle_id": "personal-fixture",
            "bundle_revision": "bundle-v1",
            "encoder": {
                "provider": "dinov2",
                "model_id": "facebook/dinov2-small",
                "model_revision": "fixture-model-revision",
                "preprocessing_revision": "fixture-preprocessing-revision",
                "element_count": 2,
            },
            "label_vocabulary_revision": "personal-tags-v1",
            "weights_sha256": manifest["weights_sha256"],
            "policy_revision": "personal-logit-zero-top10-v1",
            "tag_ids": ["tag-trip"],
        },
    }


class FakeEmbeddingProvider:
    identity = EmbeddingProviderIdentity(
        provider="fake",
        model_id="fixture-model",
        model_revision="fixture-revision",
        preprocessing_revision="fixture-preprocessing-v1",
        element_count=3,
    )

    def embed(self, image_bytes: bytes) -> list[float]:
        assert image_bytes.startswith(b"\x89PNG\r\n\x1a\n")
        return [0.25, -0.5, 1.0]


def test_embedding_returns_provider_identity_and_float32_vector() -> None:
    image = Image.new("RGB", (8, 8), color=(32, 64, 128))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    request_body = {
        "request_id": "request-2",
        "image_base64": base64.b64encode(buffer.getvalue()).decode("ascii"),
    }
    client = TestClient(create_app(provider=FakeEmbeddingProvider()))

    health = client.get("/v1/health")
    embedding = client.post("/v1/embeddings", json=request_body)

    assert health.status_code == 200
    assert health.json()["status"] == "ready"
    assert health.json()["provider"] == {
        "provider": "fake",
        "model_id": "fixture-model",
        "model_revision": "fixture-revision",
        "preprocessing_revision": "fixture-preprocessing-v1",
        "element_count": 3,
    }
    assert embedding.status_code == 200
    assert embedding.json() == {
        "request_id": "request-2",
        "provider": "fake",
        "model_id": "fixture-model",
        "model_revision": "fixture-revision",
        "preprocessing_revision": "fixture-preprocessing-v1",
        "element_type": "float32",
        "element_count": 3,
        "embedding": [0.25, -0.5, 1.0],
    }


def test_embedding_rejects_invalid_base64_without_exposing_an_exception() -> None:
    client = TestClient(create_app(provider=FakeEmbeddingProvider()))

    response = client.post(
        "/v1/embeddings",
        json={"request_id": "request-3", "image_base64": "not-base64!"},
    )

    assert response.status_code == 422
    assert response.json() == {
        "detail": {
            "code": "invalid_image",
            "message": "image_base64 must be valid base64.",
        }
    }


def test_embedding_rejects_an_empty_decoded_image() -> None:
    client = TestClient(create_app(provider=FakeEmbeddingProvider()))

    response = client.post(
        "/v1/embeddings",
        json={"request_id": "request-4", "image_base64": ""},
    )

    assert response.status_code == 422
    assert response.json()["detail"] == {
        "code": "invalid_image",
        "message": "image payload must not be empty.",
    }


def test_embedding_rejects_a_decoded_image_over_twenty_mebibytes() -> None:
    oversized = b"x" * (20 * 1024 * 1024 + 1)
    client = TestClient(create_app(provider=FakeEmbeddingProvider()))

    response = client.post(
        "/v1/embeddings",
        json={
            "request_id": "request-5",
            "image_base64": base64.b64encode(oversized).decode("ascii"),
        },
    )

    assert response.status_code == 422
    assert response.json()["detail"] == {
        "code": "invalid_image",
        "message": "decoded image exceeds 20 MiB.",
    }


def test_embedding_rejects_bytes_that_are_not_jpeg_or_png() -> None:
    client = TestClient(create_app(provider=FakeEmbeddingProvider()))

    response = client.post(
        "/v1/embeddings",
        json={
            "request_id": "request-6",
            "image_base64": base64.b64encode(b"GIF89a").decode("ascii"),
        },
    )

    assert response.status_code == 422
    assert response.json()["detail"] == {
        "code": "unsupported_image",
        "message": "only JPEG and PNG images are supported.",
    }


def test_embedding_rejects_corrupt_png_bytes_before_calling_the_provider() -> None:
    client = TestClient(create_app(provider=FakeEmbeddingProvider()))

    response = client.post(
        "/v1/embeddings",
        json={
            "request_id": "request-7",
            "image_base64": base64.b64encode(
                b"\x89PNG\r\n\x1a\nnot-a-real-image"
            ).decode("ascii"),
        },
    )

    assert response.status_code == 422
    assert response.json()["detail"] == {
        "code": "invalid_image",
        "message": "image payload is not a decodable JPEG or PNG.",
    }


class InvalidEmbeddingProvider(FakeEmbeddingProvider):
    def embed(self, image_bytes: bytes) -> list[float]:
        return [float("nan")]


def test_embedding_hides_invalid_provider_output_behind_a_stable_error() -> None:
    image = Image.new("RGB", (8, 8), color=(32, 64, 128))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    client = TestClient(create_app(provider=InvalidEmbeddingProvider()))

    response = client.post(
        "/v1/embeddings",
        json={
            "request_id": "request-8",
            "image_base64": base64.b64encode(buffer.getvalue()).decode("ascii"),
        },
    )

    assert response.status_code == 503
    assert response.json()["detail"] == {
        "code": "model_failure",
        "message": "Model provider failed to produce a valid embedding.",
    }


def test_standard_suggestion_endpoint_returns_only_direct_concepts() -> None:
    client = standard_suggestion_client()

    response = client.post(
        "/v1/suggestions",
        json={
            "request_id": "suggestion-request-1",
            "image_base64": png_base64((0, 0, 255)),
            "target": {
                "track": "standard",
                "standard_pack_id": "imageall-public-fixture",
                "standard_pack_revision": "pack-v1",
            },
        },
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["request_id"] == "suggestion-request-1"
    assert len(payload["suggestions"]) == 1
    assert payload["suggestions"][0]["concept_id"] == "scene.water"
    assert payload["suggestions"][0]["recommended_state"] == "autoAssigned"
    assert "derived_from_concept" not in payload["suggestions"][0]


def test_personal_target_does_not_fall_back_to_standard_suggestions() -> None:
    client = standard_suggestion_client()

    response = client.post(
        "/v1/suggestions",
        json={
            "request_id": "personal-request-1",
            "image_base64": png_base64((0, 0, 255)),
            "target": {
                "track": "personal",
                "bundle_id": "missing-bundle",
                "bundle_revision": "missing-revision",
            },
        },
    )

    assert response.status_code == 503
    assert response.json() == {
        "detail": {
            "code": "personal_bundle_unavailable",
            "message": "No personal suggestion bundle is configured.",
        }
    }


def test_personal_suggestion_endpoint_returns_only_scoped_bundle_tags(
    tmp_path: Path,
) -> None:
    client = personal_suggestion_client(tmp_path)
    target = personal_target(tmp_path)

    response = client.post(
        "/v1/suggestions",
        json={
            "request_id": "personal-request-2",
            "image_base64": png_base64((32, 64, 128)),
            "target": target,
        },
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["request_id"] == "personal-request-2"
    assert len(payload["suggestions"]) == 1
    suggestion = payload["suggestions"][0]
    assert suggestion["track"] == "personal"
    assert suggestion["concept_id"] is None
    assert suggestion["tag_id"] == "tag-trip"
    assert suggestion["recommended_state"] == "suggested"
    assert suggestion["catalog_scope_id"] == "catalog-fixture"
    assert suggestion["bundle_id"] == "personal-fixture"
    assert suggestion["bundle_revision"] == "bundle-v1"
    assert suggestion["provider"] == "dinov2"
    assert suggestion["model_id"] == "facebook/dinov2-small"
    assert suggestion["model_revision"] == "fixture-model-revision"
    assert suggestion["preprocessing_revision"] == (
        "fixture-preprocessing-revision"
    )
    assert suggestion["element_count"] == 2
    assert suggestion["label_vocabulary_revision"] == "personal-tags-v1"
    assert suggestion["weights_sha256"] == target["weights_sha256"]
    assert suggestion["policy_revision"] == "personal-logit-zero-top10-v1"


@pytest.mark.parametrize(
    ("field", "stale_value"),
    (
        ("catalog_scope_id", "another-catalog"),
        ("bundle_id", "another-bundle"),
        ("bundle_revision", "stale-bundle-revision"),
        ("provider", "another-provider"),
        ("model_id", "another-model"),
        ("model_revision", "stale-model-revision"),
        ("preprocessing_revision", "stale-preprocessing-revision"),
        ("element_count", 384),
        ("label_vocabulary_revision", "stale-vocabulary"),
        ("weights_sha256", "0" * 64),
        ("policy_revision", "stale-policy-revision"),
    ),
)
def test_personal_target_fails_closed_on_bundle_identity_mismatch(
    tmp_path: Path,
    field: str,
    stale_value: object,
) -> None:
    client = personal_suggestion_client(tmp_path)
    target = personal_target(tmp_path)
    target[field] = stale_value

    response = client.post(
        "/v1/suggestions",
        json={
            "request_id": "stale-personal-request",
            "image_base64": png_base64((32, 64, 128)),
            "target": target,
        },
    )

    assert response.status_code == 409
    assert response.json()["detail"] == {
        "code": "personal_bundle_mismatch",
        "message": "Requested personal bundle identity is not loaded.",
    }


def test_personal_target_fails_closed_when_weight_identity_is_missing(
    tmp_path: Path,
) -> None:
    client = personal_suggestion_client(tmp_path)
    target = personal_target(tmp_path)
    del target["weights_sha256"]

    response = client.post(
        "/v1/suggestions",
        json={
            "request_id": "incomplete-personal-request",
            "image_base64": png_base64((32, 64, 128)),
            "target": target,
        },
    )

    assert response.status_code == 409
    assert response.json()["detail"] == {
        "code": "personal_bundle_mismatch",
        "message": "Requested personal bundle identity is not loaded.",
    }


class InvalidPersonalEmbeddingProvider(FakePersonalEmbeddingProvider):
    def embed(self, image_bytes: bytes) -> list[float]:
        return [float("nan"), 0.0]


def test_personal_provider_failure_is_stable_and_does_not_return_suggestions(
    tmp_path: Path,
) -> None:
    engine = personal_suggestion_engine(
        tmp_path,
        provider=InvalidPersonalEmbeddingProvider(),
    )
    client = TestClient(create_app(personal_suggestion_engine=engine))

    response = client.post(
        "/v1/suggestions",
        json={
            "request_id": "failed-personal-request",
            "image_base64": png_base64((32, 64, 128)),
            "target": personal_target(tmp_path),
        },
    )

    assert response.status_code == 503
    assert response.json()["detail"] == {
        "code": "personal_model_failure",
        "message": "Personal provider failed to produce suggestions.",
    }


def test_health_reports_a_loaded_standard_suggestion_provider() -> None:
    client = standard_suggestion_client()

    response = client.get("/v1/health")

    assert response.status_code == 200
    assert response.json() == {
        "status": "ready",
        "service_version": "0.1.0",
        "provider": {
            "provider": "rgb-linear",
            "model_id": "imageall/fixture-scene-linear",
            "model_revision": "model-v1",
            "preprocessing_revision": "rgb-channel-mean-v1",
        },
    }


def test_standard_target_rejects_a_stale_package_revision() -> None:
    client = standard_suggestion_client()

    response = client.post(
        "/v1/suggestions",
        json={
            "request_id": "stale-pack-request",
            "image_base64": png_base64((0, 0, 255)),
            "target": {
                "track": "standard",
                "standard_pack_id": "imageall-public-fixture",
                "standard_pack_revision": "stale-revision",
            },
        },
    )

    assert response.status_code == 409
    assert response.json()["detail"] == {
        "code": "standard_pack_mismatch",
        "message": "Requested standard package identity is not loaded.",
    }


def test_unavailable_standard_model_does_not_affect_service_startup() -> None:
    client = TestClient(create_app())

    health = client.get("/v1/health")
    response = client.post(
        "/v1/suggestions",
        json={
            "request_id": "unavailable-request",
            "image_base64": png_base64((0, 0, 255)),
            "target": {
                "track": "standard",
                "standard_pack_id": "imageall-public-fixture",
                "standard_pack_revision": "pack-v1",
            },
        },
    )

    assert health.status_code == 200
    assert health.json()["status"] == "degraded"
    assert response.status_code == 503
    assert response.json()["detail"] == {
        "code": "model_unavailable",
        "message": "No standard suggestion provider is configured.",
    }
