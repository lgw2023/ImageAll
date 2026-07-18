import base64
import io
from pathlib import Path

from fastapi.testclient import TestClient
from PIL import Image

from imageall_model_backend.providers import EmbeddingProviderIdentity
from imageall_model_backend.rgb_linear import RGBLinearSceneProvider
from imageall_model_backend.service import create_app
from imageall_model_backend.standard_pack import load_standard_pack
from imageall_model_backend.standard_suggestions import StandardSuggestionEngine

PUBLIC_FIXTURE_PACK = (
    Path(__file__).parents[1] / "fixtures" / "standard-scene-pack-v1"
)


def standard_suggestion_client() -> TestClient:
    pack = load_standard_pack(PUBLIC_FIXTURE_PACK)
    engine = StandardSuggestionEngine(pack, RGBLinearSceneProvider.from_pack(pack))
    return TestClient(create_app(standard_suggestion_engine=engine))


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
