from __future__ import annotations

import math
from dataclasses import dataclass

from imageall_model_backend.providers import (
    StandardProviderIdentity,
    StandardSuggestionProvider,
)
from imageall_model_backend.standard_pack import StandardPack


class StandardSuggestionError(ValueError):
    pass


@dataclass(frozen=True)
class StandardSuggestionCapability:
    standard_pack_id: str
    standard_pack_revision: str
    manifest_sha256: str
    ontology_id: str
    ontology_revision: str
    provider: StandardProviderIdentity
    mapping_revision: str
    policy_revision: str
    weights_sha256: str


@dataclass(frozen=True)
class StandardSuggestion:
    track: str
    concept_id: str
    tag_id: None
    score: float
    recommended_state: str
    standard_pack_id: str
    standard_pack_revision: str
    ontology_id: str
    ontology_revision: str
    provider: str
    model_revision: str
    preprocessing_revision: str
    mapping_revision: str
    policy_revision: str


@dataclass(frozen=True)
class OntologyAssignment:
    concept_id: str
    recommended_state: str
    derived_from_concept: str | None


@dataclass(frozen=True)
class StandardSuggestionTrace:
    direct_suggestions: tuple[StandardSuggestion, ...]
    ontology_assignments: tuple[OntologyAssignment, ...]


class StandardSuggestionEngine:
    def __init__(
        self, pack: StandardPack, provider: StandardSuggestionProvider
    ) -> None:
        if provider.identity != pack.provider_identity:
            raise StandardSuggestionError("provider identity does not match package")
        self._pack = pack
        self._provider = provider

    @property
    def standard_pack_id(self) -> str:
        return self._pack.standard_pack_id

    @property
    def standard_pack_revision(self) -> str:
        return self._pack.standard_pack_revision

    @property
    def provider_identity(self) -> StandardProviderIdentity:
        return self._provider.identity

    @property
    def capability(self) -> StandardSuggestionCapability:
        return StandardSuggestionCapability(
            standard_pack_id=self._pack.standard_pack_id,
            standard_pack_revision=self._pack.standard_pack_revision,
            manifest_sha256=self._pack.manifest_sha256,
            ontology_id=self._pack.ontology.ontology_id,
            ontology_revision=self._pack.ontology.ontology_revision,
            provider=self._pack.provider_identity,
            mapping_revision=self._pack.mapping.mapping_revision,
            policy_revision=self._pack.policy.policy_revision,
            weights_sha256=self._pack.weights_sha256,
        )

    def trace(self, image_bytes: bytes) -> StandardSuggestionTrace:
        best_score_by_concept: dict[str, float] = {}
        for provider_score in self._provider.predict(image_bytes):
            if not math.isfinite(provider_score.score):
                continue
            concept_id = self._pack.mapping.concept_for(
                provider_score.provider_label
            )
            if concept_id is None:
                continue
            best_score_by_concept[concept_id] = max(
                provider_score.score,
                best_score_by_concept.get(concept_id, -math.inf),
            )

        direct_suggestions: list[StandardSuggestion] = []
        for concept_id, score in best_score_by_concept.items():
            policy = self._pack.policy.entry_for(concept_id)
            if policy is None or score < policy.suggest_at:
                continue
            recommended_state = (
                "autoAssigned"
                if policy.auto_assign_at is not None
                and score >= policy.auto_assign_at
                else "suggested"
            )
            direct_suggestions.append(
                StandardSuggestion(
                    track="standard",
                    concept_id=concept_id,
                    tag_id=None,
                    score=score,
                    recommended_state=recommended_state,
                    standard_pack_id=self._pack.standard_pack_id,
                    standard_pack_revision=self._pack.standard_pack_revision,
                    ontology_id=self._pack.ontology.ontology_id,
                    ontology_revision=self._pack.ontology.ontology_revision,
                    provider=self._pack.provider_identity.provider,
                    model_revision=self._pack.provider_identity.model_revision,
                    preprocessing_revision=(
                        self._pack.provider_identity.preprocessing_revision
                    ),
                    mapping_revision=self._pack.mapping.mapping_revision,
                    policy_revision=self._pack.policy.policy_revision,
                )
            )
        direct_suggestions.sort(key=lambda item: (-item.score, item.concept_id))

        assignments: list[OntologyAssignment] = []
        for suggestion in direct_suggestions:
            assignments.append(
                OntologyAssignment(
                    concept_id=suggestion.concept_id,
                    recommended_state=suggestion.recommended_state,
                    derived_from_concept=None,
                )
            )
            seen = {suggestion.concept_id}
            pending = list(self._pack.ontology.parents_of(suggestion.concept_id))
            while pending:
                ancestor_id = pending.pop(0)
                if ancestor_id in seen:
                    continue
                seen.add(ancestor_id)
                assignments.append(
                    OntologyAssignment(
                        concept_id=ancestor_id,
                        recommended_state=suggestion.recommended_state,
                        derived_from_concept=suggestion.concept_id,
                    )
                )
                pending.extend(self._pack.ontology.parents_of(ancestor_id))

        return StandardSuggestionTrace(
            direct_suggestions=tuple(direct_suggestions),
            ontology_assignments=tuple(assignments),
        )
