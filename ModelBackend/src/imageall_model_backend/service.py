import base64
import binascii
import io
import math
import re
from dataclasses import asdict
from uuid import UUID

import numpy as np
from fastapi import FastAPI, HTTPException
from PIL import Image, UnidentifiedImageError
from pydantic import BaseModel, ConfigDict

from imageall_model_backend import __version__
from imageall_model_backend.personal_runtime import (
    ExpectedActivePersonalBundle,
    PersonalBundleMismatch,
    PersonalModelRuntime,
)
from imageall_model_backend.personal_suggestions import PersonalSuggestionEngine
from imageall_model_backend.personal_training import PersonalTrainingInput
from imageall_model_backend.providers import (
    EmbeddingProvider,
    EmbeddingProviderIdentity,
)
from imageall_model_backend.standard_suggestions import StandardSuggestionEngine

MAX_IMAGE_BYTES = 20 * 1024 * 1024
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
JPEG_PREFIX = b"\xff\xd8\xff"


class EmbeddingRequest(BaseModel):
    request_id: str
    image_base64: str


class SuggestionTarget(BaseModel):
    track: str
    catalog_scope_id: str | None = None
    standard_pack_id: str | None = None
    standard_pack_revision: str | None = None
    bundle_id: str | None = None
    bundle_revision: str | None = None
    provider: str | None = None
    model_id: str | None = None
    model_revision: str | None = None
    preprocessing_revision: str | None = None
    element_count: int | None = None
    label_vocabulary_revision: str | None = None
    weights_sha256: str | None = None
    policy_revision: str | None = None


class SuggestionRequest(BaseModel):
    request_id: str
    image_base64: str
    target: SuggestionTarget


class PersonalRebuildEncoder(BaseModel):
    model_config = ConfigDict(extra="forbid")

    provider: str
    model_id: str
    model_revision: str
    preprocessing_revision: str
    element_count: int


class PersonalRebuildEmbedding(BaseModel):
    model_config = ConfigDict(extra="forbid")

    asset_id: str
    content_revision: str
    embedding: list[float]


class PersonalRebuildDecision(BaseModel):
    model_config = ConfigDict(extra="forbid")

    asset_id: str
    content_revision: str
    tag_id: str
    state: str


class PersonalRebuildSnapshot(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_revision: int
    catalog_scope_id: str
    decision_snapshot_revision: str
    encoder: PersonalRebuildEncoder
    personal_tag_ids: list[str]
    label_vocabulary_revision: str
    embeddings: list[PersonalRebuildEmbedding]
    decisions: list[PersonalRebuildDecision]


class ExpectedActivePersonalBundleRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    bundle_revision: str
    weights_sha256: str


class PersonalRebuildRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    request_id: str
    expected_active_bundle: ExpectedActivePersonalBundleRequest | None
    snapshot: PersonalRebuildSnapshot


def _decode_image(image_base64: str) -> bytes:
    try:
        image_bytes = base64.b64decode(image_base64, validate=True)
    except (binascii.Error, ValueError):
        raise HTTPException(
            status_code=422,
            detail={
                "code": "invalid_image",
                "message": "image_base64 must be valid base64.",
            },
        ) from None
    if not image_bytes:
        raise HTTPException(
            status_code=422,
            detail={
                "code": "invalid_image",
                "message": "image payload must not be empty.",
            },
        )
    if len(image_bytes) > MAX_IMAGE_BYTES:
        raise HTTPException(
            status_code=422,
            detail={
                "code": "invalid_image",
                "message": "decoded image exceeds 20 MiB.",
            },
        )
    if not (
        image_bytes.startswith(PNG_SIGNATURE)
        or image_bytes.startswith(JPEG_PREFIX)
    ):
        raise HTTPException(
            status_code=422,
            detail={
                "code": "unsupported_image",
                "message": "only JPEG and PNG images are supported.",
            },
        )
    try:
        with Image.open(io.BytesIO(image_bytes)) as image:
            image.verify()
    except (
        Image.DecompressionBombError,
        OSError,
        SyntaxError,
        UnidentifiedImageError,
        ValueError,
    ):
        raise HTTPException(
            status_code=422,
            detail={
                "code": "invalid_image",
                "message": "image payload is not a decodable JPEG or PNG.",
            },
        ) from None
    return image_bytes


def create_app(
    provider: EmbeddingProvider | None = None,
    standard_suggestion_engine: StandardSuggestionEngine | None = None,
    personal_suggestion_engine: PersonalSuggestionEngine | None = None,
    personal_model_runtime: PersonalModelRuntime | None = None,
) -> FastAPI:
    if (
        personal_suggestion_engine is not None
        and personal_model_runtime is not None
    ):
        raise ValueError("personal engine and runtime are mutually exclusive")
    app = FastAPI(title="ImageAll Model Backend", version=__version__)

    def active_personal_engine() -> PersonalSuggestionEngine | None:
        if personal_model_runtime is not None:
            return personal_model_runtime.current_engine
        return personal_suggestion_engine

    @app.get("/v1/health")
    def health() -> dict[str, object]:
        active_identity = provider.identity if provider is not None else None
        if active_identity is None and standard_suggestion_engine is not None:
            active_identity = standard_suggestion_engine.provider_identity
        current_personal_engine = active_personal_engine()
        if active_identity is None and current_personal_engine is not None:
            active_identity = current_personal_engine.provider_identity
        return {
            "status": "ready" if active_identity is not None else "degraded",
            "service_version": __version__,
            "provider": (
                asdict(active_identity) if active_identity is not None else None
            ),
        }

    @app.get("/v1/capabilities")
    def capabilities() -> dict[str, object]:
        personal: dict[str, object] = {"status": "unavailable"}
        current_personal_engine = active_personal_engine()
        if current_personal_engine is not None:
            personal = {
                "status": "available",
                **asdict(current_personal_engine.bundle_identity),
            }
        return {
            "service_version": __version__,
            "personal": personal,
        }

    @app.post("/v1/personal/rebuild")
    def rebuild_personal(request: PersonalRebuildRequest) -> dict[str, object]:
        if personal_model_runtime is None:
            raise HTTPException(
                status_code=503,
                detail={
                    "code": "personal_rebuild_unavailable",
                    "message": "No personal model store is configured.",
                },
            )
        try:
            _canonical_uuid(request.request_id, "request id")
            training_input = _personal_training_input(request.snapshot)
            expected_active_bundle = (
                ExpectedActivePersonalBundle(
                    bundle_revision=request.expected_active_bundle.bundle_revision,
                    weights_sha256=request.expected_active_bundle.weights_sha256,
                )
                if request.expected_active_bundle is not None
                else None
            )
            engine = personal_model_runtime.rebuild(
                training_input=training_input,
                expected_active_bundle=expected_active_bundle,
            )
        except PersonalBundleMismatch:
            raise HTTPException(
                status_code=409,
                detail={
                    "code": "personal_bundle_mismatch",
                    "message": "Expected personal bundle identity is not active.",
                },
            ) from None
        except ValueError as error:
            raise HTTPException(
                status_code=422,
                detail={
                    "code": "invalid_personal_training_snapshot",
                    "message": str(error),
                },
            ) from None
        except (OSError, RuntimeError):
            raise HTTPException(
                status_code=503,
                detail={
                    "code": "personal_rebuild_failed",
                    "message": "Personal model training or publication failed.",
                },
            ) from None
        return {
            "request_id": request.request_id,
            "personal": {
                "status": "available",
                **asdict(engine.bundle_identity),
            },
        }

    @app.post("/v1/embeddings")
    def embeddings(request: EmbeddingRequest) -> dict[str, object]:
        if provider is None:
            raise HTTPException(
                status_code=503,
                detail={
                    "code": "model_unavailable",
                    "message": "No model provider is configured.",
                },
            )
        image_bytes = _decode_image(request.image_base64)
        try:
            vector = [float(value) for value in provider.embed(image_bytes)]
        except Exception:
            raise HTTPException(
                status_code=503,
                detail={
                    "code": "model_failure",
                    "message": "Model provider failed to produce a valid embedding.",
                },
            ) from None
        identity = provider.identity
        if len(vector) != identity.element_count or not all(
            math.isfinite(value) for value in vector
        ):
            raise HTTPException(
                status_code=503,
                detail={
                    "code": "model_failure",
                    "message": "Model provider failed to produce a valid embedding.",
                },
            )
        return {
            "request_id": request.request_id,
            "provider": identity.provider,
            "model_id": identity.model_id,
            "model_revision": identity.model_revision,
            "preprocessing_revision": identity.preprocessing_revision,
            "element_type": "float32",
            "element_count": identity.element_count,
            "embedding": vector,
        }

    @app.post("/v1/suggestions")
    def suggestions(request: SuggestionRequest) -> dict[str, object]:
        if request.target.track == "personal":
            current_personal_engine = active_personal_engine()
            if current_personal_engine is None:
                raise HTTPException(
                    status_code=503,
                    detail={
                        "code": "personal_bundle_unavailable",
                        "message": "No personal suggestion bundle is configured.",
                    },
                )
            bundle_identity = current_personal_engine.bundle_identity
            encoder_identity = bundle_identity.encoder
            if (
                request.target.catalog_scope_id
                != bundle_identity.catalog_scope_id
                or request.target.bundle_id != bundle_identity.bundle_id
                or request.target.bundle_revision
                != bundle_identity.bundle_revision
                or request.target.provider != encoder_identity.provider
                or request.target.model_id != encoder_identity.model_id
                or request.target.model_revision
                != encoder_identity.model_revision
                or request.target.preprocessing_revision
                != encoder_identity.preprocessing_revision
                or request.target.element_count != encoder_identity.element_count
                or request.target.label_vocabulary_revision
                != bundle_identity.label_vocabulary_revision
                or request.target.weights_sha256
                != bundle_identity.weights_sha256
                or request.target.policy_revision
                != bundle_identity.policy_revision
            ):
                raise HTTPException(
                    status_code=409,
                    detail={
                        "code": "personal_bundle_mismatch",
                        "message": "Requested personal bundle identity is not loaded.",
                    },
                )
            image_bytes = _decode_image(request.image_base64)
            try:
                personal_suggestions = current_personal_engine.suggest(image_bytes)
            except Exception:
                raise HTTPException(
                    status_code=503,
                    detail={
                        "code": "personal_model_failure",
                        "message": "Personal provider failed to produce suggestions.",
                    },
                ) from None
            return {
                "request_id": request.request_id,
                "suggestions": [
                    asdict(suggestion) for suggestion in personal_suggestions
                ],
            }
        if request.target.track != "standard":
            raise HTTPException(
                status_code=422,
                detail={
                    "code": "invalid_target",
                    "message": "Only standard and personal suggestion tracks are available.",
                },
            )
        if standard_suggestion_engine is None:
            raise HTTPException(
                status_code=503,
                detail={
                    "code": "model_unavailable",
                    "message": "No standard suggestion provider is configured.",
                },
            )
        if (
            request.target.standard_pack_id
            != standard_suggestion_engine.standard_pack_id
            or request.target.standard_pack_revision
            != standard_suggestion_engine.standard_pack_revision
        ):
            raise HTTPException(
                status_code=409,
                detail={
                    "code": "standard_pack_mismatch",
                    "message": "Requested standard package identity is not loaded.",
                },
            )
        image_bytes = _decode_image(request.image_base64)
        try:
            trace = standard_suggestion_engine.trace(image_bytes)
        except Exception:
            raise HTTPException(
                status_code=503,
                detail={
                    "code": "model_failure",
                    "message": "Standard provider failed to produce suggestions.",
                },
            ) from None
        return {
            "request_id": request.request_id,
            "suggestions": [
                asdict(suggestion) for suggestion in trace.direct_suggestions
            ],
        }

    return app


def _personal_training_input(
    snapshot: PersonalRebuildSnapshot,
) -> PersonalTrainingInput:
    if snapshot.schema_revision != 1:
        raise ValueError("unsupported personal training snapshot schema")
    _canonical_uuid(snapshot.catalog_scope_id, "catalog_scope_id")
    _sha256_revision(snapshot.decision_snapshot_revision, "decision snapshot revision")
    _sha256_revision(snapshot.label_vocabulary_revision, "label vocabulary revision")
    if not snapshot.personal_tag_ids or len(set(snapshot.personal_tag_ids)) != len(
        snapshot.personal_tag_ids
    ):
        raise ValueError("personal tag vocabulary must be non-empty and unique")
    for tag_id in snapshot.personal_tag_ids:
        _canonical_uuid(tag_id, "personal tag id")
    encoder_identity = EmbeddingProviderIdentity(**snapshot.encoder.model_dump())
    if encoder_identity.element_count <= 0:
        raise ValueError("encoder element count must be positive")

    asset_keys: list[tuple[str, str]] = []
    seen_asset_keys: set[tuple[str, str]] = set()
    vectors: list[list[float]] = []
    for row in snapshot.embeddings:
        _canonical_uuid(row.asset_id, "asset id")
        _decimal_revision(row.content_revision)
        key = (row.asset_id, row.content_revision)
        if key in seen_asset_keys:
            raise ValueError("duplicate personal embedding row")
        if len(row.embedding) != encoder_identity.element_count or not all(
            math.isfinite(value) for value in row.embedding
        ):
            raise ValueError("embedding matrix does not match encoder identity")
        asset_keys.append(key)
        seen_asset_keys.add(key)
        vectors.append(row.embedding)
    if not asset_keys:
        raise ValueError("personal training snapshot has no embeddings")

    asset_index = {key: index for index, key in enumerate(asset_keys)}
    tag_index = {
        tag_id: index for index, tag_id in enumerate(snapshot.personal_tag_ids)
    }
    targets = np.zeros((len(asset_keys), len(tag_index)), dtype=np.float32)
    observation_mask = np.zeros_like(targets, dtype=np.bool_)
    seen_decisions: set[tuple[int, int]] = set()
    for decision in snapshot.decisions:
        _canonical_uuid(decision.asset_id, "asset id")
        _decimal_revision(decision.content_revision)
        key = (decision.asset_id, decision.content_revision)
        if key not in asset_index:
            raise ValueError("decision references missing embedding")
        if decision.tag_id not in tag_index:
            raise ValueError("decision references unknown personal tag")
        row = asset_index[key]
        column = tag_index[decision.tag_id]
        if (row, column) in seen_decisions:
            raise ValueError("duplicate personal decision")
        seen_decisions.add((row, column))
        if decision.state == "manualAccepted":
            targets[row, column] = 1.0
        elif decision.state != "manualRejected":
            raise ValueError(
                "decision state must be manualAccepted or manualRejected"
            )
        observation_mask[row, column] = True

    return PersonalTrainingInput(
        catalog_scope_id=snapshot.catalog_scope_id,
        decision_snapshot_revision=snapshot.decision_snapshot_revision,
        encoder_identity=encoder_identity,
        personal_tag_ids=tuple(snapshot.personal_tag_ids),
        label_vocabulary_revision=snapshot.label_vocabulary_revision,
        asset_ids=tuple(asset_id for asset_id, _ in asset_keys),
        content_revisions=tuple(revision for _, revision in asset_keys),
        embeddings=np.asarray(vectors, dtype=np.float32),
        targets=targets,
        observation_mask=observation_mask,
    )


def _canonical_uuid(value: str, field: str) -> None:
    try:
        parsed = UUID(value)
    except ValueError:
        raise ValueError(f"{field} must be a canonical lowercase UUID") from None
    if str(parsed) != value:
        raise ValueError(f"{field} must be a canonical lowercase UUID")


def _sha256_revision(value: str, field: str) -> None:
    if re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ValueError(f"{field} must be a lowercase SHA-256")


def _decimal_revision(value: str) -> None:
    if not value.isdecimal() or str(int(value)) != value:
        raise ValueError("content revision must be a canonical decimal string")
