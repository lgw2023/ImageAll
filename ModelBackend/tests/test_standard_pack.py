import hashlib
import json
from pathlib import Path

import pytest

from imageall_model_backend.standard_pack import (
    StandardPackValidationError,
    load_standard_pack,
)


def write_standard_pack(root: Path) -> Path:
    root.mkdir()
    (root / "models").mkdir()
    (root / "LICENSES").mkdir()

    ontology = {
        "ontology_id": "imageall-public-fixture",
        "ontology_revision": "ontology-v1",
        "concepts": [
            {"concept_id": "scene.environment", "names": {"en": "Environment"}},
            {"concept_id": "scene.outdoor", "names": {"en": "Outdoor"}},
            {"concept_id": "scene.water", "names": {"en": "Water"}},
        ],
        "edges": [
            {"parent": "scene.environment", "child": "scene.outdoor"},
            {"parent": "scene.outdoor", "child": "scene.water"},
        ],
    }
    mapping = {
        "mapping_revision": "mapping-v1",
        "entries": [{"provider_label": "blue_scene", "concept_id": "scene.water"}],
    }
    policy = {
        "policy_revision": "policy-v1",
        "concepts": [
            {
                "concept_id": "scene.water",
                "suggest_at": 0.6,
                "auto_assign_at": 0.8,
                "calibration_evidence_id": "fixture-calibration-v1",
            }
        ],
    }
    model = {
        "feature_revision": "rgb-channel-mean-v1",
        "labels": [
            {
                "provider_label": "blue_scene",
                "weights": [-1.0, 0.0, 1.0],
                "bias": 0.5,
            }
        ],
    }
    files = {
        "ontology.json": ontology,
        "mapping.json": mapping,
        "policy.json": policy,
        "models/scene-linear.json": model,
    }
    for relative_path, payload in files.items():
        (root / relative_path).write_text(
            json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8"
        )
    (root / "LICENSES/model.txt").write_text("CC0-1.0\n", encoding="utf-8")

    checksummed_paths = [*files, "LICENSES/model.txt"]
    manifest = {
        "schema_revision": 1,
        "standard_pack_id": "imageall-public-fixture",
        "standard_pack_revision": "pack-v1",
        "ontology_id": "imageall-public-fixture",
        "ontology_revision": "ontology-v1",
        "provider_identity": {
            "provider": "rgb-linear",
            "model_id": "imageall/fixture-scene-linear",
            "model_revision": "model-v1",
            "preprocessing_revision": "rgb-channel-mean-v1",
        },
        "model_path": "models/scene-linear.json",
        "model_license_id": "CC0-1.0",
        "mapping_revision": "mapping-v1",
        "policy_revision": "policy-v1",
        "supported_languages": ["en"],
        "licenses": [{"id": "CC0-1.0", "path": "LICENSES/model.txt"}],
        "file_sha256": {
            path: hashlib.sha256((root / path).read_bytes()).hexdigest()
            for path in checksummed_paths
        },
    }
    (root / "manifest.json").write_text(
        json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8"
    )
    return root


def rewrite_payload_and_checksum(
    root: Path, relative_path: str, payload: object
) -> None:
    payload_path = root / relative_path
    payload_path.write_text(
        json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8"
    )
    manifest_path = root / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["file_sha256"][relative_path] = hashlib.sha256(
        payload_path.read_bytes()
    ).hexdigest()
    manifest_path.write_text(
        json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8"
    )


def test_loads_a_complete_standard_pack_with_versioned_ontology(tmp_path: Path) -> None:
    pack = load_standard_pack(write_standard_pack(tmp_path / "standard-pack"))

    assert pack.standard_pack_id == "imageall-public-fixture"
    assert pack.standard_pack_revision == "pack-v1"
    assert pack.ontology.parents_of("scene.water") == ("scene.outdoor",)
    assert pack.mapping.concept_for("blue_scene") == "scene.water"
    assert pack.policy.entry_for("scene.water").auto_assign_at == 0.8


def test_rejects_a_standard_pack_with_a_checksum_mismatch(tmp_path: Path) -> None:
    pack_path = write_standard_pack(tmp_path / "standard-pack")
    (pack_path / "ontology.json").write_text("{}\n", encoding="utf-8")

    with pytest.raises(StandardPackValidationError, match="checksum mismatch"):
        load_standard_pack(pack_path)


def test_rejects_a_model_without_a_recorded_license(tmp_path: Path) -> None:
    pack_path = write_standard_pack(tmp_path / "standard-pack")
    manifest_path = pack_path / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["licenses"] = []
    manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")

    with pytest.raises(StandardPackValidationError, match="license is not recorded"):
        load_standard_pack(pack_path)


def test_rejects_an_ontology_edge_with_a_missing_concept(tmp_path: Path) -> None:
    pack_path = write_standard_pack(tmp_path / "standard-pack")
    ontology_path = pack_path / "ontology.json"
    ontology = json.loads(ontology_path.read_text(encoding="utf-8"))
    ontology["edges"].append(
        {"parent": "scene.environment", "child": "scene.missing"}
    )
    rewrite_payload_and_checksum(pack_path, "ontology.json", ontology)

    with pytest.raises(StandardPackValidationError, match="dangling ontology edge"):
        load_standard_pack(pack_path)


def test_rejects_a_cycle_in_the_ontology_dag(tmp_path: Path) -> None:
    pack_path = write_standard_pack(tmp_path / "standard-pack")
    ontology_path = pack_path / "ontology.json"
    ontology = json.loads(ontology_path.read_text(encoding="utf-8"))
    ontology["edges"].append(
        {"parent": "scene.water", "child": "scene.environment"}
    )
    rewrite_payload_and_checksum(pack_path, "ontology.json", ontology)

    with pytest.raises(StandardPackValidationError, match="ontology contains a cycle"):
        load_standard_pack(pack_path)


def test_rejects_a_mapping_to_an_unpublished_concept(tmp_path: Path) -> None:
    pack_path = write_standard_pack(tmp_path / "standard-pack")
    mapping = {
        "mapping_revision": "mapping-v1",
        "entries": [
            {"provider_label": "open_text", "concept_id": "scene.unpublished"}
        ],
    }
    rewrite_payload_and_checksum(pack_path, "mapping.json", mapping)

    with pytest.raises(
        StandardPackValidationError, match="mapping concept is not published"
    ):
        load_standard_pack(pack_path)


def test_rejects_an_automatic_policy_without_calibration_evidence(
    tmp_path: Path,
) -> None:
    pack_path = write_standard_pack(tmp_path / "standard-pack")
    policy = {
        "policy_revision": "policy-v1",
        "concepts": [
            {
                "concept_id": "scene.water",
                "suggest_at": 0.6,
                "auto_assign_at": 0.8,
                "calibration_evidence_id": None,
            }
        ],
    }
    rewrite_payload_and_checksum(pack_path, "policy.json", policy)

    with pytest.raises(StandardPackValidationError, match="automatic policy requires"):
        load_standard_pack(pack_path)


def test_rejects_duplicate_ontology_concept_ids(tmp_path: Path) -> None:
    pack_path = write_standard_pack(tmp_path / "standard-pack")
    ontology_path = pack_path / "ontology.json"
    ontology = json.loads(ontology_path.read_text(encoding="utf-8"))
    ontology["concepts"].append(
        {"concept_id": "scene.water", "names": {"en": "Duplicate"}}
    )
    rewrite_payload_and_checksum(pack_path, "ontology.json", ontology)

    with pytest.raises(StandardPackValidationError, match="duplicate concept ID"):
        load_standard_pack(pack_path)


def test_rejects_a_model_artifact_without_a_checksum(tmp_path: Path) -> None:
    pack_path = write_standard_pack(tmp_path / "standard-pack")
    manifest_path = pack_path / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    del manifest["file_sha256"][manifest["model_path"]]
    manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")

    with pytest.raises(StandardPackValidationError, match="missing required checksum"):
        load_standard_pack(pack_path)


def test_rejects_an_ontology_revision_that_differs_from_the_manifest(
    tmp_path: Path,
) -> None:
    pack_path = write_standard_pack(tmp_path / "standard-pack")
    ontology_path = pack_path / "ontology.json"
    ontology = json.loads(ontology_path.read_text(encoding="utf-8"))
    ontology["ontology_revision"] = "other-revision"
    rewrite_payload_and_checksum(pack_path, "ontology.json", ontology)

    with pytest.raises(StandardPackValidationError, match="ontology identity mismatch"):
        load_standard_pack(pack_path)


def test_rejects_a_package_path_that_escapes_the_package_root(tmp_path: Path) -> None:
    pack_path = write_standard_pack(tmp_path / "standard-pack")
    manifest_path = pack_path / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["model_path"] = "../outside-model.json"
    manifest["file_sha256"]["../outside-model.json"] = "0" * 64
    manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")

    with pytest.raises(StandardPackValidationError, match="path escapes package root"):
        load_standard_pack(pack_path)


def test_rejects_a_mapping_revision_that_differs_from_the_manifest(
    tmp_path: Path,
) -> None:
    pack_path = write_standard_pack(tmp_path / "standard-pack")
    mapping_path = pack_path / "mapping.json"
    mapping = json.loads(mapping_path.read_text(encoding="utf-8"))
    mapping["mapping_revision"] = "other-revision"
    rewrite_payload_and_checksum(pack_path, "mapping.json", mapping)

    with pytest.raises(StandardPackValidationError, match="mapping revision mismatch"):
        load_standard_pack(pack_path)


def test_rejects_a_policy_revision_that_differs_from_the_manifest(
    tmp_path: Path,
) -> None:
    pack_path = write_standard_pack(tmp_path / "standard-pack")
    policy_path = pack_path / "policy.json"
    policy = json.loads(policy_path.read_text(encoding="utf-8"))
    policy["policy_revision"] = "other-revision"
    rewrite_payload_and_checksum(pack_path, "policy.json", policy)

    with pytest.raises(StandardPackValidationError, match="policy revision mismatch"):
        load_standard_pack(pack_path)
