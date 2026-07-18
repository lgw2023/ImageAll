import base64
import binascii
import io
import math
from dataclasses import asdict

from fastapi import FastAPI, HTTPException
from PIL import Image, UnidentifiedImageError
from pydantic import BaseModel

from imageall_model_backend import __version__
from imageall_model_backend.providers import EmbeddingProvider

MAX_IMAGE_BYTES = 20 * 1024 * 1024
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
JPEG_PREFIX = b"\xff\xd8\xff"


class EmbeddingRequest(BaseModel):
    request_id: str
    image_base64: str


def create_app(provider: EmbeddingProvider | None = None) -> FastAPI:
    app = FastAPI(title="ImageAll Model Backend", version=__version__)

    @app.get("/v1/health")
    def health() -> dict[str, object]:
        return {
            "status": "ready" if provider is not None else "degraded",
            "service_version": __version__,
            "provider": asdict(provider.identity) if provider is not None else None,
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
        try:
            image_bytes = base64.b64decode(request.image_base64, validate=True)
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

    return app
