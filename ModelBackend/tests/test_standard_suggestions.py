import io
from pathlib import Path

from PIL import Image

from imageall_model_backend.rgb_linear import RGBLinearSceneProvider
from imageall_model_backend.providers import (
    StandardProviderIdentity,
    StandardProviderScore,
)
from imageall_model_backend.standard_pack import load_standard_pack
from imageall_model_backend.standard_suggestions import StandardSuggestionEngine

PUBLIC_FIXTURE_PACK = (
    Path(__file__).parents[1] / "fixtures" / "standard-scene-pack-v1"
)


def blue_png() -> bytes:
    image = Image.new("RGB", (8, 8), color=(0, 0, 255))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


def black_png() -> bytes:
    image = Image.new("RGB", (8, 8), color=(0, 0, 0))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


def test_public_fixture_produces_a_zero_sample_standard_suggestion() -> None:
    pack = load_standard_pack(PUBLIC_FIXTURE_PACK)
    provider = RGBLinearSceneProvider.from_pack(pack)

    trace = StandardSuggestionEngine(pack, provider).trace(blue_png())

    assert [
        (item.track, item.concept_id, item.recommended_state)
        for item in trace.direct_suggestions
    ] == [("standard", "scene.water", "autoAssigned")]
    assert [
        (item.concept_id, item.derived_from_concept)
        for item in trace.ontology_assignments
    ] == [
        ("scene.water", None),
        ("scene.outdoor", "scene.water"),
        ("scene.environment", "scene.water"),
    ]


def test_standard_policy_keeps_uncalibrated_score_in_review() -> None:
    pack = load_standard_pack(PUBLIC_FIXTURE_PACK)
    provider = RGBLinearSceneProvider.from_pack(pack)

    trace = StandardSuggestionEngine(pack, provider).trace(black_png())

    assert [item.recommended_state for item in trace.direct_suggestions] == [
        "suggested"
    ]


class OpenTextProvider:
    def __init__(self, identity: StandardProviderIdentity) -> None:
        self.identity = identity

    def predict(self, image_bytes: bytes) -> list[StandardProviderScore]:
        return [StandardProviderScore(provider_label="caption:ocean", score=0.99)]


def test_open_text_provider_output_cannot_become_a_standard_concept() -> None:
    pack = load_standard_pack(PUBLIC_FIXTURE_PACK)
    provider = OpenTextProvider(pack.provider_identity)

    trace = StandardSuggestionEngine(pack, provider).trace(blue_png())

    assert trace.direct_suggestions == ()
    assert trace.ontology_assignments == ()
