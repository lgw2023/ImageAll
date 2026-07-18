from __future__ import annotations

import io

import numpy as np
from PIL import Image

from imageall_model_backend.personal_suggestions import PersonalSuggestionEngine
from imageall_model_backend.personal_training import (
    PersonalLinearHeadBundle,
    PersonalSuggestionPolicy,
)
from imageall_model_backend.providers import EmbeddingProviderIdentity


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


def _png_bytes() -> bytes:
    image = Image.new("RGB", (8, 8), color=(32, 64, 128))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


def test_personal_engine_returns_only_bundle_tags_as_suggestions() -> None:
    identity = FakePersonalEmbeddingProvider.identity
    bundle = PersonalLinearHeadBundle(
        bundle_id="personal-fixture",
        bundle_revision="bundle-v1",
        catalog_scope_id="catalog-fixture",
        decision_snapshot_revision="decisions-v1",
        encoder_identity=identity,
        personal_tag_ids=("tag-low", "tag-trip"),
        label_vocabulary_revision="personal-tags-v1",
        weights_sha256="1" * 64,
        suggestion_policy=PersonalSuggestionPolicy(
            revision="personal-logit-zero-top10-v1",
            max_suggestions=1,
            thresholds=(0.0, 0.0),
        ),
        weights=np.asarray([[-1.0, 0.0], [1.0, 0.0]], dtype=np.float32),
        bias=np.zeros(2, dtype=np.float32),
    )
    engine = PersonalSuggestionEngine(FakePersonalEmbeddingProvider(), bundle)

    suggestions = engine.suggest(_png_bytes())

    assert len(suggestions) == 1
    suggestion = suggestions[0]
    assert suggestion.track == "personal"
    assert suggestion.concept_id is None
    assert suggestion.tag_id == "tag-trip"
    assert suggestion.score == 2.0
    assert suggestion.recommended_state == "suggested"
    assert suggestion.catalog_scope_id == "catalog-fixture"
    assert suggestion.bundle_id == "personal-fixture"
    assert suggestion.bundle_revision == "bundle-v1"
    assert suggestion.provider == "dinov2"
    assert suggestion.model_revision == "fixture-model-revision"
    assert suggestion.preprocessing_revision == "fixture-preprocessing-revision"
    assert suggestion.element_count == 2
    assert suggestion.label_vocabulary_revision == "personal-tags-v1"
    assert suggestion.weights_sha256 == "1" * 64
    assert suggestion.policy_revision == "personal-logit-zero-top10-v1"
