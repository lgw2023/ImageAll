import base64
import io
import os

import numpy as np
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from imageall_model_backend.dinov2 import DinoV2SmallProvider
from imageall_model_backend.service import create_app


@pytest.mark.model_smoke
@pytest.mark.skipif(
    os.environ.get("IMAGEALL_RUN_MODEL_SMOKE") != "1",
    reason="set IMAGEALL_RUN_MODEL_SMOKE=1 to download/run the pinned model",
)
def test_pinned_dinov2_small_embeds_a_synthetic_png() -> None:
    image = Image.new("RGB", (96, 64), color=(80, 120, 160))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    provider = DinoV2SmallProvider()
    client = TestClient(create_app(provider=provider))

    response = client.post(
        "/v1/embeddings",
        json={
            "request_id": "dinov2-smoke",
            "image_base64": base64.b64encode(buffer.getvalue()).decode("ascii"),
        },
    )
    embedding = np.asarray(response.json()["embedding"], dtype=np.float32)

    assert response.status_code == 200
    assert response.json()["provider"] == "dinov2"
    assert provider.identity.model_revision == (
        "ed25f3a31f01632728cabb09d1542f84ab7b0056"
    )
    assert embedding.shape == (384,)
    assert np.isfinite(embedding).all()
