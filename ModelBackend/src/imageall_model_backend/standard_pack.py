from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass
from pathlib import Path

from imageall_model_backend.providers import StandardProviderIdentity


class StandardPackValidationError(ValueError):
    pass


@dataclass(frozen=True)
class StandardOntology:
    ontology_id: str
    ontology_revision: str
    concept_ids: frozenset[str]
    _parents_by_concept: dict[str, tuple[str, ...]]

    def parents_of(self, concept_id: str) -> tuple[str, ...]:
        return self._parents_by_concept.get(concept_id, ())


@dataclass(frozen=True)
class StandardMapping:
    mapping_revision: str
    _concept_by_provider_label: dict[str, str]

    def concept_for(self, provider_label: str) -> str | None:
        return self._concept_by_provider_label.get(provider_label)


@dataclass(frozen=True)
class StandardPolicyEntry:
    concept_id: str
    suggest_at: float
    auto_assign_at: float | None
    calibration_evidence_id: str | None


@dataclass(frozen=True)
class StandardPolicy:
    policy_revision: str
    _entry_by_concept: dict[str, StandardPolicyEntry]

    def entry_for(self, concept_id: str) -> StandardPolicyEntry | None:
        return self._entry_by_concept.get(concept_id)


@dataclass(frozen=True)
class StandardPack:
    root: Path
    standard_pack_id: str
    standard_pack_revision: str
    provider_identity: StandardProviderIdentity
    model_path: Path
    ontology: StandardOntology
    mapping: StandardMapping
    policy: StandardPolicy


def _validate_acyclic(parents: dict[str, list[str]]) -> None:
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(concept_id: str) -> None:
        if concept_id in visiting:
            raise StandardPackValidationError("ontology contains a cycle")
        if concept_id in visited:
            return
        visiting.add(concept_id)
        for parent_id in parents[concept_id]:
            visit(parent_id)
        visiting.remove(concept_id)
        visited.add(concept_id)

    for concept_id in parents:
        visit(concept_id)


def _package_file(root: Path, relative_path: str) -> Path:
    path = Path(relative_path)
    candidate = root / path
    if (
        path.is_absolute()
        or not path.parts
        or not candidate.resolve(strict=False).is_relative_to(root.resolve())
    ):
        raise StandardPackValidationError("path escapes package root")
    return candidate


def load_standard_pack(root: Path) -> StandardPack:
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    recorded_license_ids = {
        license_entry["id"] for license_entry in manifest["licenses"]
    }
    if manifest["model_license_id"] not in recorded_license_ids:
        raise StandardPackValidationError("model license is not recorded")
    required_paths = {
        "ontology.json",
        "mapping.json",
        "policy.json",
        manifest["model_path"],
        *(license_entry["path"] for license_entry in manifest["licenses"]),
    }
    if not required_paths.issubset(manifest["file_sha256"]):
        raise StandardPackValidationError("missing required checksum")
    for relative_path, expected_hash in manifest["file_sha256"].items():
        actual_hash = hashlib.sha256(
            _package_file(root, relative_path).read_bytes()
        ).hexdigest()
        if actual_hash != expected_hash:
            raise StandardPackValidationError(
                f"checksum mismatch for {relative_path}"
            )
    ontology_payload = json.loads(
        (root / "ontology.json").read_text(encoding="utf-8")
    )
    if (
        ontology_payload["ontology_id"] != manifest["ontology_id"]
        or ontology_payload["ontology_revision"] != manifest["ontology_revision"]
    ):
        raise StandardPackValidationError("ontology identity mismatch")
    concept_id_list = [
        concept["concept_id"] for concept in ontology_payload["concepts"]
    ]
    concept_ids = frozenset(concept_id_list)
    if len(concept_ids) != len(concept_id_list):
        raise StandardPackValidationError("duplicate concept ID")
    parents: dict[str, list[str]] = {concept_id: [] for concept_id in concept_ids}
    for edge in ontology_payload["edges"]:
        if edge["parent"] not in concept_ids or edge["child"] not in concept_ids:
            raise StandardPackValidationError("dangling ontology edge")
        parents[edge["child"]].append(edge["parent"])
    _validate_acyclic(parents)
    mapping_payload = json.loads(
        (root / "mapping.json").read_text(encoding="utf-8")
    )
    if mapping_payload["mapping_revision"] != manifest["mapping_revision"]:
        raise StandardPackValidationError("mapping revision mismatch")
    concept_by_provider_label: dict[str, str] = {}
    for entry in mapping_payload["entries"]:
        if entry["concept_id"] not in concept_ids:
            raise StandardPackValidationError("mapping concept is not published")
        if entry["provider_label"] in concept_by_provider_label:
            raise StandardPackValidationError("duplicate provider label")
        concept_by_provider_label[entry["provider_label"]] = entry["concept_id"]
    policy_payload = json.loads(
        (root / "policy.json").read_text(encoding="utf-8")
    )
    if policy_payload["policy_revision"] != manifest["policy_revision"]:
        raise StandardPackValidationError("policy revision mismatch")
    entry_by_concept: dict[str, StandardPolicyEntry] = {}
    for entry in policy_payload["concepts"]:
        if entry["concept_id"] not in concept_ids:
            raise StandardPackValidationError("policy concept is not published")
        if entry["concept_id"] in entry_by_concept:
            raise StandardPackValidationError("duplicate policy concept")
        if entry["auto_assign_at"] is not None and not entry[
            "calibration_evidence_id"
        ]:
            raise StandardPackValidationError(
                "automatic policy requires calibration evidence"
            )
        suggest_at = float(entry["suggest_at"])
        auto_assign_at = (
            float(entry["auto_assign_at"])
            if entry["auto_assign_at"] is not None
            else None
        )
        if not math.isfinite(suggest_at) or (
            auto_assign_at is not None and not math.isfinite(auto_assign_at)
        ):
            raise StandardPackValidationError("policy thresholds must be finite")
        if auto_assign_at is not None and auto_assign_at < suggest_at:
            raise StandardPackValidationError(
                "automatic threshold must not be below suggestion threshold"
            )
        policy_entry = StandardPolicyEntry(
            concept_id=entry["concept_id"],
            suggest_at=suggest_at,
            auto_assign_at=auto_assign_at,
            calibration_evidence_id=entry["calibration_evidence_id"],
        )
        entry_by_concept[policy_entry.concept_id] = policy_entry
    ontology = StandardOntology(
        ontology_id=ontology_payload["ontology_id"],
        ontology_revision=ontology_payload["ontology_revision"],
        concept_ids=concept_ids,
        _parents_by_concept={
            concept_id: tuple(concept_parents)
            for concept_id, concept_parents in parents.items()
        },
    )
    return StandardPack(
        root=root,
        standard_pack_id=manifest["standard_pack_id"],
        standard_pack_revision=manifest["standard_pack_revision"],
        provider_identity=StandardProviderIdentity(**manifest["provider_identity"]),
        model_path=_package_file(root, manifest["model_path"]),
        ontology=ontology,
        mapping=StandardMapping(
            mapping_revision=mapping_payload["mapping_revision"],
            _concept_by_provider_label=concept_by_provider_label,
        ),
        policy=StandardPolicy(
            policy_revision=policy_payload["policy_revision"],
            _entry_by_concept=entry_by_concept,
        ),
    )
