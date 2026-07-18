from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from imageall_model_backend.personal_training import PersonalLinearHeadBundle
from imageall_model_backend.providers import (
    EmbeddingProvider,
    EmbeddingProviderIdentity,
)


class PersonalSuggestionError(ValueError):
    pass


@dataclass(frozen=True)
class PersonalBundleIdentity:
    catalog_scope_id: str
    bundle_id: str
    bundle_revision: str
    encoder: EmbeddingProviderIdentity
    label_vocabulary_revision: str
    weights_sha256: str
    policy_revision: str
    tag_ids: tuple[str, ...]


@dataclass(frozen=True)
class PersonalSuggestion:
    track: str
    concept_id: None
    tag_id: str
    score: float
    recommended_state: str
    catalog_scope_id: str
    bundle_id: str
    bundle_revision: str
    provider: str
    model_id: str
    model_revision: str
    preprocessing_revision: str
    element_count: int
    label_vocabulary_revision: str
    weights_sha256: str
    policy_revision: str
    standard_pack_id: None = None
    standard_pack_revision: None = None
    ontology_id: None = None
    ontology_revision: None = None
    mapping_revision: None = None


class PersonalSuggestionEngine:
    def __init__(
        self,
        provider: EmbeddingProvider,
        bundle: PersonalLinearHeadBundle,
    ) -> None:
        if provider.identity != bundle.encoder_identity:
            raise PersonalSuggestionError(
                "personal provider identity does not match bundle encoder"
            )
        self._provider = provider
        self._bundle = bundle

    @property
    def provider_identity(self) -> EmbeddingProviderIdentity:
        return self._provider.identity

    @property
    def catalog_scope_id(self) -> str:
        return self._bundle.catalog_scope_id

    @property
    def bundle_id(self) -> str:
        return self._bundle.bundle_id

    @property
    def bundle_revision(self) -> str:
        return self._bundle.bundle_revision

    @property
    def label_vocabulary_revision(self) -> str:
        return self._bundle.label_vocabulary_revision

    @property
    def bundle_identity(self) -> PersonalBundleIdentity:
        return PersonalBundleIdentity(
            catalog_scope_id=self._bundle.catalog_scope_id,
            bundle_id=self._bundle.bundle_id,
            bundle_revision=self._bundle.bundle_revision,
            encoder=self._bundle.encoder_identity,
            label_vocabulary_revision=self._bundle.label_vocabulary_revision,
            weights_sha256=self._bundle.weights_sha256,
            policy_revision=self._bundle.suggestion_policy.revision,
            tag_ids=self._bundle.personal_tag_ids,
        )

    def suggest(self, image_bytes: bytes) -> tuple[PersonalSuggestion, ...]:
        embedding = np.asarray(self._provider.embed(image_bytes), dtype=np.float32)
        if (
            embedding.shape != (self._bundle.encoder_identity.element_count,)
            or not np.isfinite(embedding).all()
        ):
            raise RuntimeError("personal provider returned an invalid embedding")
        logits = self._bundle.predict_logits(embedding[np.newaxis, :])[0]
        if (
            logits.shape != (len(self._bundle.personal_tag_ids),)
            or not np.isfinite(logits).all()
        ):
            raise RuntimeError("personal bundle returned invalid logits")

        identity = self._provider.identity
        suggestions = [
            PersonalSuggestion(
                track="personal",
                concept_id=None,
                tag_id=tag_id,
                score=float(score),
                recommended_state="suggested",
                catalog_scope_id=self._bundle.catalog_scope_id,
                bundle_id=self._bundle.bundle_id,
                bundle_revision=self._bundle.bundle_revision,
                provider=identity.provider,
                model_id=identity.model_id,
                model_revision=identity.model_revision,
                preprocessing_revision=identity.preprocessing_revision,
                element_count=identity.element_count,
                label_vocabulary_revision=self._bundle.label_vocabulary_revision,
                weights_sha256=self._bundle.weights_sha256,
                policy_revision=self._bundle.suggestion_policy.revision,
            )
            for tag_id, score, threshold in zip(
                self._bundle.personal_tag_ids,
                logits,
                self._bundle.suggestion_policy.thresholds,
                strict=True,
            )
            if score >= threshold
        ]
        suggestions.sort(key=lambda item: (-item.score, item.tag_id))
        return tuple(
            suggestions[: self._bundle.suggestion_policy.max_suggestions]
        )
