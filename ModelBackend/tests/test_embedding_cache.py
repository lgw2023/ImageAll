import base64
import io
import sqlite3
from dataclasses import replace
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from imageall_model_backend.embedding_cache import EmbeddingCache
from imageall_model_backend.providers import EmbeddingProviderIdentity
from imageall_model_backend.service import create_app

CATALOG_SCOPE_ID = "11111111-1111-4111-8111-111111111111"
ASSET_ID = "22222222-2222-4222-8222-222222222222"


class CountingEmbeddingProvider:
    identity = EmbeddingProviderIdentity(
        provider="dinov2",
        model_id="facebook/dinov2-small",
        model_revision="fixture-model-revision",
        preprocessing_revision="fixture-preprocessing-revision",
        element_count=2,
    )

    def __init__(self, values: list[float] | None = None) -> None:
        self.call_count = 0
        self._values = values

    def embed(self, image_bytes: bytes) -> list[float]:
        assert image_bytes.startswith(b"\x89PNG\r\n\x1a\n")
        self.call_count += 1
        return self._values or [float(self.call_count), 0.0]


def cache_key(**changes: object) -> dict[str, object]:
    key: dict[str, object] = {
        "schema_revision": 1,
        "catalog_scope_id": CATALOG_SCOPE_ID,
        "asset_id": ASSET_ID,
        "content_revision": "7",
    }
    key.update(changes)
    return key


def png_base64(color: tuple[int, int, int]) -> str:
    image = Image.new("RGB", (8, 8), color=color)
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return base64.b64encode(buffer.getvalue()).decode("ascii")


def embedding_request(
    request_id: str,
    *,
    key: dict[str, object] | None = None,
    color: tuple[int, int, int] = (32, 64, 128),
) -> dict[str, object]:
    return {
        "request_id": request_id,
        "image_base64": png_base64(color),
        "cache_key": key or cache_key(),
    }


def embedding_client(
    cache_path: Path,
    provider: CountingEmbeddingProvider,
) -> TestClient:
    return TestClient(
        create_app(
            provider=provider,
            embedding_cache=EmbeddingCache(cache_path),
        )
    )


def test_embedding_reuses_an_exact_versioned_cache_entry(tmp_path: Path) -> None:
    provider = CountingEmbeddingProvider()
    client = embedding_client(tmp_path / "embeddings.sqlite3", provider)

    first = client.post(
        "/v1/embeddings",
        json=embedding_request("first-request"),
    )
    second = client.post(
        "/v1/embeddings",
        json=embedding_request(
            "second-request",
            color=(128, 64, 32),
        ),
    )

    assert first.status_code == 200
    assert second.status_code == 200
    assert first.json()["embedding"] == [1.0, 0.0]
    assert second.json()["embedding"] == [1.0, 0.0]
    assert provider.call_count == 1


def test_embedding_cache_survives_a_service_restart(tmp_path: Path) -> None:
    cache_path = tmp_path / "embeddings.sqlite3"
    first_provider = CountingEmbeddingProvider()
    first = embedding_client(cache_path, first_provider).post(
        "/v1/embeddings",
        json=embedding_request("before-restart-request"),
    )

    restarted_provider = CountingEmbeddingProvider()
    second = embedding_client(cache_path, restarted_provider).post(
        "/v1/embeddings",
        json=embedding_request("after-restart-request"),
    )

    assert first.status_code == 200
    assert second.status_code == 200
    assert second.json()["embedding"] == [1.0, 0.0]
    assert first_provider.call_count == 1
    assert restarted_provider.call_count == 0


def test_embedding_returns_the_same_float32_values_before_and_after_cache_hit(
    tmp_path: Path,
) -> None:
    provider = CountingEmbeddingProvider([0.1, -0.2])
    client = embedding_client(tmp_path / "embeddings.sqlite3", provider)

    first = client.post(
        "/v1/embeddings",
        json=embedding_request("rounding-request"),
    )
    second = client.post(
        "/v1/embeddings",
        json=embedding_request("rounding-request-cached"),
    )

    expected = [float(np.float32(0.1)), float(np.float32(-0.2))]
    assert first.status_code == 200
    assert second.status_code == 200
    assert first.json()["embedding"] == expected
    assert second.json()["embedding"] == expected
    assert provider.call_count == 1


def test_embedding_ignores_an_unavailable_rebuildable_cache(
    tmp_path: Path,
) -> None:
    cache_path = tmp_path / "embeddings.sqlite3"
    cache_path.write_bytes(b"not-a-sqlite-database")
    provider = CountingEmbeddingProvider()

    response = embedding_client(cache_path, provider).post(
        "/v1/embeddings",
        json=embedding_request("unavailable-cache-request"),
    )

    assert response.status_code == 200
    assert response.json()["embedding"] == [1.0, 0.0]
    assert provider.call_count == 1


@pytest.mark.parametrize(
    ("field", "value"),
    (
        ("catalog_scope_id", "33333333-3333-4333-8333-333333333333"),
        ("content_revision", "8"),
    ),
)
def test_embedding_cache_misses_when_the_asset_version_key_changes(
    tmp_path: Path,
    field: str,
    value: str,
) -> None:
    provider = CountingEmbeddingProvider()
    client = embedding_client(tmp_path / "embeddings.sqlite3", provider)
    first = client.post(
        "/v1/embeddings",
        json=embedding_request("first-version-request"),
    )
    second = client.post(
        "/v1/embeddings",
        json=embedding_request(
            "changed-version-request",
            key=cache_key(**{field: value}),
        ),
    )

    assert first.status_code == 200
    assert second.status_code == 200
    assert second.json()["embedding"] == [2.0, 0.0]
    assert provider.call_count == 2


@pytest.mark.parametrize(
    ("field", "value"),
    (
        ("provider", "coreml-dinov2"),
        ("model_id", "fixture-dinov2-v2"),
        ("model_revision", "fixture-model-revision-v2"),
        ("preprocessing_revision", "fixture-preprocessing-revision-v2"),
    ),
)
def test_embedding_cache_misses_when_the_encoder_identity_changes(
    tmp_path: Path,
    field: str,
    value: str,
) -> None:
    cache_path = tmp_path / "embeddings.sqlite3"
    first_provider = CountingEmbeddingProvider()
    first = embedding_client(cache_path, first_provider).post(
        "/v1/embeddings",
        json=embedding_request("first-encoder-request"),
    )

    changed_provider = CountingEmbeddingProvider()
    changed_provider.identity = replace(
        changed_provider.identity,
        **{field: value},
    )
    second = embedding_client(cache_path, changed_provider).post(
        "/v1/embeddings",
        json=embedding_request("changed-encoder-request"),
    )

    assert first.status_code == 200
    assert second.status_code == 200
    assert first_provider.call_count == 1
    assert changed_provider.call_count == 1


def test_embedding_cache_key_rejects_file_system_and_image_fields(
    tmp_path: Path,
) -> None:
    provider = CountingEmbeddingProvider()
    private_key = cache_key(
        path="/private/photo.png",
        bookmark="opaque-bookmark",
        image="persistent-image-bytes",
    )

    response = embedding_client(
        tmp_path / "embeddings.sqlite3",
        provider,
    ).post(
        "/v1/embeddings",
        json=embedding_request("private-field-request", key=private_key),
    )

    assert response.status_code == 422
    assert provider.call_count == 0


@pytest.mark.parametrize(
    "corrupt_embedding",
    (
        np.asarray([99.0, 99.0], dtype="<f4").tobytes(),
        "not-a-binary-vector",
    ),
)
def test_embedding_cache_recomputes_a_corrupt_vector(
    tmp_path: Path,
    corrupt_embedding: bytes | str,
) -> None:
    cache_path = tmp_path / "embeddings.sqlite3"
    provider = CountingEmbeddingProvider()
    client = embedding_client(cache_path, provider)
    first = client.post(
        "/v1/embeddings",
        json=embedding_request("first-integrity-request"),
    )
    with sqlite3.connect(cache_path) as connection:
        connection.execute(
            "UPDATE embedding_cache SET embedding = ?",
            (corrupt_embedding,),
        )

    second = client.post(
        "/v1/embeddings",
        json=embedding_request("second-integrity-request"),
    )

    assert first.status_code == 200
    assert second.status_code == 200
    assert second.json()["embedding"] == [2.0, 0.0]
    assert provider.call_count == 2


def test_embedding_cache_persists_only_identity_and_vector_data(
    tmp_path: Path,
) -> None:
    cache_path = tmp_path / "embeddings.sqlite3"
    provider = CountingEmbeddingProvider()
    encoded_image = png_base64((32, 64, 128))
    request = embedding_request("privacy-contract-request")
    request["image_base64"] = encoded_image

    response = embedding_client(cache_path, provider).post(
        "/v1/embeddings",
        json=request,
    )

    with sqlite3.connect(cache_path) as connection:
        columns = {
            row[1]
            for row in connection.execute(
                "PRAGMA table_info(embedding_cache)"
            ).fetchall()
        }
    cache_bytes = cache_path.read_bytes()
    assert response.status_code == 200
    assert columns == {
        "catalog_scope_id",
        "asset_id",
        "content_revision",
        "provider",
        "model_id",
        "model_revision",
        "preprocessing_revision",
        "element_count",
        "embedding",
        "embedding_sha256",
    }
    assert base64.b64decode(encoded_image) not in cache_bytes
    assert encoded_image.encode("ascii") not in cache_bytes
