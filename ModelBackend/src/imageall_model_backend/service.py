import base64
import binascii
import io
import math
from dataclasses import asdict

from fastapi import FastAPI, HTTPException
from PIL import Image, UnidentifiedImageError
from pydantic import BaseModel

from imageall_model_backend import __version__
from imageall_model_backend.personal_suggestions import PersonalSuggestionEngine
from imageall_model_backend.providers import EmbeddingProvider
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
    label_vocabulary_revision: str | None = None


class SuggestionRequest(BaseModel):
    request_id: str
    image_base64: str
    target: SuggestionTarget


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
) -> FastAPI:
    app = FastAPI(title="ImageAll Model Backend", version=__version__)

    @app.get("/v1/health")
    def health() -> dict[str, object]:
        active_identity = provider.identity if provider is not None else None
        if active_identity is None and standard_suggestion_engine is not None:
            active_identity = standard_suggestion_engine.provider_identity
        if active_identity is None and personal_suggestion_engine is not None:
            active_identity = personal_suggestion_engine.provider_identity
        return {
            "status": "ready" if active_identity is not None else "degraded",
            "service_version": __version__,
            "provider": (
                asdict(active_identity) if active_identity is not None else None
            ),
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
            if personal_suggestion_engine is None:
                raise HTTPException(
                    status_code=503,
                    detail={
                        "code": "personal_bundle_unavailable",
                        "message": "No personal suggestion bundle is configured.",
                    },
                )
            if (
                request.target.catalog_scope_id
                != personal_suggestion_engine.catalog_scope_id
                or request.target.bundle_id != personal_suggestion_engine.bundle_id
                or request.target.bundle_revision
                != personal_suggestion_engine.bundle_revision
                or request.target.label_vocabulary_revision
                != personal_suggestion_engine.label_vocabulary_revision
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
                personal_suggestions = personal_suggestion_engine.suggest(image_bytes)
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
