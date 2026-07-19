from __future__ import annotations

import base64
import io
import json
from pathlib import Path
from uuid import UUID

import pytest
from fastapi.testclient import TestClient
from PIL import Image
from starlette.requests import Request

import imageall_model_backend.personal_runtime as personal_runtime_module
from imageall_model_backend.personal_runtime import PersonalModelRuntime
from imageall_model_backend.providers import EmbeddingProviderIdentity
from imageall_model_backend.service import create_app
from imageall_model_backend.training import LinearHeadTrainingConfig


class FakeEmbeddingProvider:
    identity = EmbeddingProviderIdentity(
        provider="dinov2",
        model_id="facebook/dinov2-small",
        model_revision="fixture-model-revision",
        preprocessing_revision="fixture-preprocessing-revision",
        element_count=2,
    )

    def __init__(self) -> None:
        self.embed_call_count = 0

    def embed(self, image_bytes: bytes) -> list[float]:
        assert image_bytes.startswith(b"\x89PNG\r\n\x1a\n")
        self.embed_call_count += 1
        return [2.0, -2.0]


TAG_TRIP = "10000000-0000-4000-8000-000000000001"
TAG_WORK = "10000000-0000-4000-8000-000000000002"


def rebuild_request() -> dict[str, object]:
    embeddings = (
        ("20000000-0000-4000-8000-000000000001", [-2.0, -2.0]),
        ("20000000-0000-4000-8000-000000000002", [-2.0, 2.0]),
        ("20000000-0000-4000-8000-000000000003", [2.0, -2.0]),
        ("20000000-0000-4000-8000-000000000004", [2.0, 2.0]),
    )
    decisions: list[dict[str, str]] = []
    for asset_id, trip_state, work_state in (
        (embeddings[0][0], "manualRejected", "manualRejected"),
        (embeddings[1][0], "manualRejected", "manualAccepted"),
        (embeddings[2][0], "manualAccepted", "manualRejected"),
        (embeddings[3][0], "manualAccepted", "manualAccepted"),
    ):
        decisions.extend(
            (
                {
                    "asset_id": asset_id,
                    "content_revision": "1",
                    "tag_id": TAG_TRIP,
                    "state": trip_state,
                },
                {
                    "asset_id": asset_id,
                    "content_revision": "1",
                    "tag_id": TAG_WORK,
                    "state": work_state,
                },
            )
        )
    return {
        "request_id": "30000000-0000-4000-8000-000000000001",
        "expected_active_bundle": None,
        "snapshot": {
            "schema_revision": 1,
            "catalog_scope_id": "40000000-0000-4000-8000-000000000001",
            "decision_snapshot_revision": "a" * 64,
            "encoder": {
                "provider": "dinov2",
                "model_id": "facebook/dinov2-small",
                "model_revision": "fixture-model-revision",
                "preprocessing_revision": "fixture-preprocessing-revision",
                "element_count": 2,
            },
            "personal_tag_ids": [TAG_TRIP, TAG_WORK],
            "label_vocabulary_revision": "b" * 64,
            "embeddings": [
                {
                    "asset_id": asset_id,
                    "content_revision": "1",
                    "embedding": embedding,
                }
                for asset_id, embedding in embeddings
            ],
            "decisions": decisions,
        },
    }


def png_base64() -> str:
    image = Image.new("RGB", (8, 8), color=(32, 64, 128))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return base64.b64encode(buffer.getvalue()).decode("ascii")


def test_rebuild_activates_a_catalog_scoped_bundle(tmp_path: Path) -> None:
    provider = FakeEmbeddingProvider()
    runtime = PersonalModelRuntime(
        provider=provider,
        store_root=tmp_path / "personal-store",
        training_config=LinearHeadTrainingConfig(epochs=20, learning_rate=0.1),
    )
    client = TestClient(
        create_app(provider=provider, personal_model_runtime=runtime)
    )

    response = client.post("/v1/personal/rebuild", json=rebuild_request())

    assert response.status_code == 200
    payload = response.json()
    assert payload["request_id"] == "30000000-0000-4000-8000-000000000001"
    personal = payload["personal"]
    assert personal["status"] == "available"
    assert personal["catalog_scope_id"] == "40000000-0000-4000-8000-000000000001"
    assert personal["tag_ids"] == [TAG_TRIP, TAG_WORK]
    assert personal["encoder"] == rebuild_request()["snapshot"]["encoder"]
    assert UUID(personal["bundle_id"]) == UUID(personal["bundle_id"])
    assert UUID(personal["bundle_revision"]) == UUID(personal["bundle_revision"])
    assert len(personal["weights_sha256"]) == 64
    assert client.get("/v1/capabilities").json()["personal"] == personal


def test_rebuild_hot_reloads_personal_suggestions_without_a_restart(
    tmp_path: Path,
) -> None:
    provider = FakeEmbeddingProvider()
    runtime = PersonalModelRuntime(
        provider=provider,
        store_root=tmp_path / "personal-store",
        training_config=LinearHeadTrainingConfig(epochs=40, learning_rate=0.1),
    )
    client = TestClient(
        create_app(provider=provider, personal_model_runtime=runtime)
    )
    personal = client.post(
        "/v1/personal/rebuild", json=rebuild_request()
    ).json()["personal"]

    response = client.post(
        "/v1/suggestions",
        json={
            "request_id": "personal-after-rebuild",
            "image_base64": png_base64(),
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

    assert response.status_code == 200
    assert provider.embed_call_count == 1
    assert TAG_TRIP in {
        suggestion["tag_id"] for suggestion in response.json()["suggestions"]
    }
    assert {
        suggestion["tag_id"] for suggestion in response.json()["suggestions"]
    } <= {TAG_TRIP, TAG_WORK}


def test_rebuild_with_a_stale_active_identity_keeps_the_current_bundle(
    tmp_path: Path,
) -> None:
    provider = FakeEmbeddingProvider()
    runtime = PersonalModelRuntime(
        provider=provider,
        store_root=tmp_path / "personal-store",
        training_config=LinearHeadTrainingConfig(epochs=1, learning_rate=0.1),
    )
    client = TestClient(
        create_app(provider=provider, personal_model_runtime=runtime)
    )
    first = client.post("/v1/personal/rebuild", json=rebuild_request())
    active = first.json()["personal"]
    stale_request = rebuild_request()
    stale_request["expected_active_bundle"] = {
        "bundle_revision": "50000000-0000-4000-8000-000000000001",
        "weights_sha256": "f" * 64,
    }

    response = client.post("/v1/personal/rebuild", json=stale_request)

    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "personal_bundle_mismatch"
    assert client.get("/v1/capabilities").json()["personal"] == active


def test_rebuild_with_the_current_active_identity_publishes_a_new_revision(
    tmp_path: Path,
) -> None:
    provider = FakeEmbeddingProvider()
    runtime = PersonalModelRuntime(
        provider=provider,
        store_root=tmp_path / "personal-store",
        training_config=LinearHeadTrainingConfig(epochs=1, learning_rate=0.1),
    )
    client = TestClient(
        create_app(provider=provider, personal_model_runtime=runtime)
    )
    first = client.post("/v1/personal/rebuild", json=rebuild_request()).json()[
        "personal"
    ]
    next_request = rebuild_request()
    next_request["request_id"] = "30000000-0000-4000-8000-000000000002"
    next_request["expected_active_bundle"] = {
        "bundle_revision": first["bundle_revision"],
        "weights_sha256": first["weights_sha256"],
    }
    next_request["snapshot"]["decision_snapshot_revision"] = "c" * 64

    response = client.post("/v1/personal/rebuild", json=next_request)

    assert response.status_code == 200
    second = response.json()["personal"]
    assert second["bundle_id"] == first["bundle_id"]
    assert second["bundle_revision"] != first["bundle_revision"]
    assert client.get("/v1/capabilities").json()["personal"] == second


def test_rebuild_rejects_a_noncanonical_request_id_before_training(
    tmp_path: Path,
) -> None:
    provider = FakeEmbeddingProvider()
    runtime = PersonalModelRuntime(
        provider=provider,
        store_root=tmp_path / "personal-store",
        training_config=LinearHeadTrainingConfig(epochs=1, learning_rate=0.1),
    )
    client = TestClient(
        create_app(provider=provider, personal_model_runtime=runtime)
    )
    request = rebuild_request()
    request["request_id"] = "NOT-A-LOWERCASE-UUID"

    response = client.post("/v1/personal/rebuild", json=request)

    assert response.status_code == 422
    assert response.json()["detail"]["code"] == (
        "invalid_personal_training_snapshot"
    )
    assert client.get("/v1/capabilities").json()["personal"] == {
        "status": "unavailable"
    }


def test_rebuild_rejects_image_or_path_data_in_the_training_snapshot(
    tmp_path: Path,
) -> None:
    provider = FakeEmbeddingProvider()
    runtime = PersonalModelRuntime(
        provider=provider,
        store_root=tmp_path / "personal-store",
        training_config=LinearHeadTrainingConfig(epochs=1, learning_rate=0.1),
    )
    client = TestClient(
        create_app(provider=provider, personal_model_runtime=runtime)
    )
    request = rebuild_request()
    request["snapshot"]["image_base64"] = "not-allowed"
    request["snapshot"]["path"] = "/not-allowed"
    request["snapshot"]["bookmark"] = "not-allowed"

    response = client.post("/v1/personal/rebuild", json=request)

    assert response.status_code == 422
    assert client.get("/v1/capabilities").json()["personal"] == {
        "status": "unavailable"
    }


def test_managed_store_reloads_the_same_active_bundle_after_restart(
    tmp_path: Path,
) -> None:
    provider = FakeEmbeddingProvider()
    store_root = tmp_path / "personal-store"
    first_runtime = PersonalModelRuntime(
        provider=provider,
        store_root=store_root,
        training_config=LinearHeadTrainingConfig(epochs=1, learning_rate=0.1),
    )
    first_client = TestClient(
        create_app(provider=provider, personal_model_runtime=first_runtime)
    )
    active = first_client.post(
        "/v1/personal/rebuild", json=rebuild_request()
    ).json()["personal"]

    restarted_runtime = PersonalModelRuntime(
        provider=provider,
        store_root=store_root,
        training_config=LinearHeadTrainingConfig(epochs=1, learning_rate=0.1),
    )
    restarted_client = TestClient(
        create_app(provider=provider, personal_model_runtime=restarted_runtime)
    )

    assert restarted_client.get("/v1/capabilities").json()["personal"] == active


def test_managed_store_rejects_an_active_pointer_that_escapes_bundles(
    tmp_path: Path,
) -> None:
    provider = FakeEmbeddingProvider()
    store_root = tmp_path / "personal-store"
    runtime = PersonalModelRuntime(
        provider=provider,
        store_root=store_root,
        training_config=LinearHeadTrainingConfig(epochs=1, learning_rate=0.1),
    )
    client = TestClient(
        create_app(provider=provider, personal_model_runtime=runtime)
    )
    active = client.post(
        "/v1/personal/rebuild", json=rebuild_request()
    ).json()["personal"]
    outside_bundle = tmp_path / "outside-bundle"
    (store_root / "bundles" / active["bundle_revision"]).rename(outside_bundle)
    manifest_path = outside_bundle / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["bundle_revision"] = "../../outside-bundle"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    pointer_path = store_root / "active.json"
    pointer = json.loads(pointer_path.read_text(encoding="utf-8"))
    pointer["bundle_revision"] = "../../outside-bundle"
    pointer_path.write_text(
        json.dumps(pointer, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="personal bundle revision"):
        PersonalModelRuntime(
            provider=provider,
            store_root=store_root,
            training_config=LinearHeadTrainingConfig(
                epochs=1, learning_rate=0.1
            ),
        )


def test_publish_failure_keeps_the_previous_active_bundle(
    tmp_path: Path, monkeypatch
) -> None:
    provider = FakeEmbeddingProvider()
    store_root = tmp_path / "personal-store"
    runtime = PersonalModelRuntime(
        provider=provider,
        store_root=store_root,
        training_config=LinearHeadTrainingConfig(epochs=1, learning_rate=0.1),
    )
    client = TestClient(
        create_app(provider=provider, personal_model_runtime=runtime)
    )
    active = client.post(
        "/v1/personal/rebuild", json=rebuild_request()
    ).json()["personal"]
    next_request = rebuild_request()
    next_request["expected_active_bundle"] = {
        "bundle_revision": active["bundle_revision"],
        "weights_sha256": active["weights_sha256"],
    }
    next_request["snapshot"]["decision_snapshot_revision"] = "c" * 64
    real_replace = personal_runtime_module.os.replace

    def fail_active_pointer_replace(source, destination) -> None:
        if Path(destination).name == "active.json":
            raise OSError("synthetic active pointer failure")
        real_replace(source, destination)

    monkeypatch.setattr(
        personal_runtime_module.os, "replace", fail_active_pointer_replace
    )

    response = client.post("/v1/personal/rebuild", json=next_request)

    assert response.status_code == 503
    assert response.json()["detail"]["code"] == "personal_rebuild_failed"
    assert client.get("/v1/capabilities").json()["personal"] == active
    restarted_runtime = PersonalModelRuntime(
        provider=provider,
        store_root=store_root,
        training_config=LinearHeadTrainingConfig(epochs=1, learning_rate=0.1),
    )
    assert restarted_runtime.current_engine is not None
    assert restarted_runtime.current_engine.bundle_identity == (
        runtime.current_engine.bundle_identity
    )


def test_client_disconnect_before_activation_keeps_the_previous_bundle(
    tmp_path: Path, monkeypatch
) -> None:
    provider = FakeEmbeddingProvider()
    store_root = tmp_path / "personal-store"
    runtime = PersonalModelRuntime(
        provider=provider,
        store_root=store_root,
        training_config=LinearHeadTrainingConfig(epochs=1, learning_rate=0.1),
    )
    client = TestClient(
        create_app(provider=provider, personal_model_runtime=runtime)
    )
    active = client.post(
        "/v1/personal/rebuild", json=rebuild_request()
    ).json()["personal"]
    active_pointer = (store_root / "active.json").read_bytes()
    active_bundles = sorted(
        path.name for path in (store_root / "bundles").iterdir()
    )
    next_request = rebuild_request()
    next_request["expected_active_bundle"] = {
        "bundle_revision": active["bundle_revision"],
        "weights_sha256": active["weights_sha256"],
    }
    next_request["snapshot"]["decision_snapshot_revision"] = "c" * 64
    disconnected = iter((False, False, True))

    async def disconnect_before_activation(_request: Request) -> bool:
        return next(disconnected, True)

    monkeypatch.setattr(Request, "is_disconnected", disconnect_before_activation)

    response = client.post("/v1/personal/rebuild", json=next_request)

    assert response.status_code == 503
    assert response.json()["detail"]["code"] == "personal_rebuild_failed"
    assert client.get("/v1/capabilities").json()["personal"] == active
    assert (store_root / "active.json").read_bytes() == active_pointer
    assert sorted(path.name for path in (store_root / "bundles").iterdir()) == (
        active_bundles
    )


def test_rebuild_rejects_machine_generated_training_decisions(
    tmp_path: Path,
) -> None:
    provider = FakeEmbeddingProvider()
    runtime = PersonalModelRuntime(
        provider=provider,
        store_root=tmp_path / "personal-store",
        training_config=LinearHeadTrainingConfig(epochs=1, learning_rate=0.1),
    )
    client = TestClient(
        create_app(provider=provider, personal_model_runtime=runtime)
    )
    request = rebuild_request()
    request["snapshot"]["decisions"][0]["state"] = "suggested"

    response = client.post("/v1/personal/rebuild", json=request)

    assert response.status_code == 422
    assert response.json()["detail"]["code"] == (
        "invalid_personal_training_snapshot"
    )
    assert client.get("/v1/capabilities").json()["personal"] == {
        "status": "unavailable"
    }


def test_rebuild_enforces_two_positive_and_two_negative_decisions_per_tag(
    tmp_path: Path,
) -> None:
    provider = FakeEmbeddingProvider()
    runtime = PersonalModelRuntime(
        provider=provider,
        store_root=tmp_path / "personal-store",
        training_config=LinearHeadTrainingConfig(epochs=1, learning_rate=0.1),
    )
    client = TestClient(
        create_app(provider=provider, personal_model_runtime=runtime)
    )
    request = rebuild_request()
    request["snapshot"]["decisions"] = [
        decision
        for decision in request["snapshot"]["decisions"]
        if not (
            decision["asset_id"]
            == "20000000-0000-4000-8000-000000000004"
            and decision["tag_id"] == TAG_TRIP
        )
    ]

    response = client.post("/v1/personal/rebuild", json=request)

    assert response.status_code == 422
    assert "requires at least 2 positive and 2 negative" in (
        response.json()["detail"]["message"]
    )
    assert client.get("/v1/capabilities").json()["personal"] == {
        "status": "unavailable"
    }
