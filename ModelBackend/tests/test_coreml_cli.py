import io
import json
import os

import numpy as np
import pytest
import torch
from PIL import Image

from imageall_model_backend import coreml_cli
from imageall_model_backend.dinov2 import (
    CoreMLDinoV2SmallProvider,
    DINO_V2_SMALL_INPUT_SHAPE,
    load_dinov2_small_embedding_model,
)


def test_coreml_cli_documents_the_pinned_conversion_contract(capsys) -> None:
    with pytest.raises(SystemExit) as exit_info:
        coreml_cli.main(["--help"])

    assert exit_info.value.code == 0
    help_text = capsys.readouterr().out
    assert "facebook/dinov2-small" in help_text
    assert "FP16 ML Program" in help_text
    assert "--output" in help_text
    assert "--offline" in help_text
    assert "--benchmark-samples" in help_text
    assert "--warmup-iterations" in help_text
    assert "--measured-iterations" in help_text


@pytest.mark.coreml_smoke
@pytest.mark.skipif(
    os.environ.get("IMAGEALL_RUN_COREML_SMOKE") != "1",
    reason="set IMAGEALL_RUN_COREML_SMOKE=1 to convert/run the pinned model",
)
def test_pinned_dinov2_small_converts_and_passes_coreml_fp16_gate(
    tmp_path,
) -> None:
    output_dir = tmp_path / "dinov2-small-coreml"
    source_model = load_dinov2_small_embedding_model()
    reference_input = torch.zeros(DINO_V2_SMALL_INPUT_SHAPE, dtype=torch.float32)
    with torch.inference_mode():
        dynamic_embedding = source_model.model(
            pixel_values=reference_input
        ).last_hidden_state[:, 0, :]
        static_embedding = source_model(reference_input)
    assert torch.allclose(static_embedding, dynamic_embedding, atol=1e-6, rtol=1e-6)
    del source_model

    exit_code = coreml_cli.main(
        [
            "--output",
            str(output_dir),
            "--benchmark-samples",
            "2",
            "--warmup-iterations",
            "1",
            "--measured-iterations",
            "3",
        ]
    )

    report = json.loads((output_dir / "benchmark.json").read_text())
    manifest = json.loads((output_dir / "manifest.json").read_text())
    assert exit_code == 0
    assert report["schema_revision"] == 2
    assert report["overall_passed"] is True
    assert report["input_generation_revision"] == (
        "imageall-dinov2-synthetic-rgb-processor-v1"
    )
    compute_plan = report["compute_plan"]
    assert compute_plan["evidence_kind"] == "anticipated_compute_plan"
    assert compute_plan["actual_device_allocation_verified"] is False
    assert compute_plan["neural_engine_total_core_count"] > 0
    assert compute_plan["operations"]["preferred_compute_device_counts"][
        "neural_engine"
    ] > 0
    assert compute_plan["operations"][
        "estimated_cost_weight_by_preferred_compute_device"
    ]["neural_engine"] > 0
    assert manifest["encoder"]["model_id"] == "facebook/dinov2-small"
    assert manifest["encoder"]["model_revision"] == (
        "ed25f3a31f01632728cabb09d1542f84ab7b0056"
    )
    assert manifest["model_sha256"] == report["artifact"]["model_sha256"]

    image = Image.new("RGB", (96, 64), color=(80, 120, 160))
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    provider = CoreMLDinoV2SmallProvider(
        artifact_path=output_dir,
        local_files_only=True,
    )
    embedding = np.asarray(provider.embed(buffer.getvalue()), dtype=np.float32)
    assert embedding.shape == (384,)
    assert np.isfinite(embedding).all()
