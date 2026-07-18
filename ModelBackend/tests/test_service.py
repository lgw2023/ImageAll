import base64
import io

from fastapi.testclient import TestClient
from PIL import Image

from imageall_model_backend.providers import EmbeddingProviderIdentity
from imageall_model_backend.service import create_app


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
