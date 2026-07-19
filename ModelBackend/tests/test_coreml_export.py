import json
from dataclasses import replace

import numpy as np
import pytest
import torch

from imageall_model_backend.coreml_export import (
    benchmark_coreml_artifact,
    convert_embedding_model_to_coreml,
    load_coreml_artifact,
)
from imageall_model_backend.providers import EmbeddingProviderIdentity


class _TinyEmbeddingModel(torch.nn.Module):
    def forward(self, pixel_values: torch.Tensor) -> torch.Tensor:
        pooled = pixel_values.mean(dim=(2, 3))
        return torch.cat((pooled, pooled[:, :1]), dim=1)


def _fixture_identity() -> EmbeddingProviderIdentity:
    return EmbeddingProviderIdentity(
        provider="fixture",
        model_id="fixture-encoder",
        model_revision="fixture-model-revision",
        preprocessing_revision="fixture-preprocessing-v1",
        element_count=4,
    )


@pytest.mark.skipif(
    not torch.backends.mps.is_built() and not torch.backends.mps.is_available(),
    reason="Core ML conversion is only supported by this project on macOS",
)
def test_fp16_mlprogram_artifact_preserves_encoder_identity(tmp_path) -> None:
    output_dir = tmp_path / "coreml-bundle"
    example_input = torch.linspace(
        -1.0,
        1.0,
        steps=1 * 3 * 8 * 8,
        dtype=torch.float32,
    ).reshape(1, 3, 8, 8)

    result = convert_embedding_model_to_coreml(
        model=_TinyEmbeddingModel().eval(),
        encoder_identity=_fixture_identity(),
        example_input=example_input,
        output_dir=output_dir,
    )

    manifest = json.loads((output_dir / "manifest.json").read_text())
    assert result.bundle_path == output_dir
    assert manifest["schema_revision"] == 1
    assert manifest["encoder"] == {
        "provider": "fixture",
        "model_id": "fixture-encoder",
        "model_revision": "fixture-model-revision",
        "preprocessing_revision": "fixture-preprocessing-v1",
        "element_count": 4,
    }
    assert manifest["conversion"]["source_graph"] == "torch.jit.trace"
    assert manifest["conversion"]["model_format"] == "mlprogram"
    assert manifest["conversion"]["compute_precision"] == "float16"
    assert manifest["conversion"]["minimum_deployment_target"] == "macOS15"
    assert manifest["input"] == {
        "name": "pixel_values",
        "shape": [1, 3, 8, 8],
        "element_type": "float32",
    }
    assert manifest["output"] == {
        "name": "embedding",
        "shape": [1, 4],
        "element_type": "float32",
    }
    assert len(manifest["model_sha256"]) == 64

    loaded = load_coreml_artifact(
        output_dir,
        expected_encoder_identity=_fixture_identity(),
    )
    assert loaded.bundle_path == output_dir
    assert loaded.model_path == output_dir / "encoder.mlpackage"
    assert loaded.model_sha256 == manifest["model_sha256"]
    assert loaded.input_shape == (1, 3, 8, 8)
    assert loaded.output_shape == (1, 4)

    prediction = loaded.predict(example_input.numpy())
    expected = _TinyEmbeddingModel()(example_input).detach().numpy()
    assert prediction.shape == (1, 4)
    assert np.isfinite(prediction).all()
    assert np.allclose(prediction, expected, atol=5e-3, rtol=5e-3)


def test_coreml_artifact_rejects_a_different_encoder_revision(tmp_path) -> None:
    output_dir = tmp_path / "coreml-bundle"
    example_input = torch.ones((1, 3, 8, 8), dtype=torch.float32)
    convert_embedding_model_to_coreml(
        model=_TinyEmbeddingModel().eval(),
        encoder_identity=_fixture_identity(),
        example_input=example_input,
        output_dir=output_dir,
    )

    mismatched_identity = replace(
        _fixture_identity(),
        model_revision="different-model-revision",
    )
    with pytest.raises(ValueError, match="encoder identity does not match"):
        load_coreml_artifact(
            output_dir,
            expected_encoder_identity=mismatched_identity,
        )


def test_coreml_artifact_rejects_modified_model_package(tmp_path) -> None:
    output_dir = tmp_path / "coreml-bundle"
    example_input = torch.ones((1, 3, 8, 8), dtype=torch.float32)
    convert_embedding_model_to_coreml(
        model=_TinyEmbeddingModel().eval(),
        encoder_identity=_fixture_identity(),
        example_input=example_input,
        output_dir=output_dir,
    )
    package_file = next(
        path
        for path in (output_dir / "encoder.mlpackage").rglob("*")
        if path.is_file()
    )
    package_file.write_bytes(package_file.read_bytes() + b"modified")

    with pytest.raises(ValueError, match="checksum does not match"):
        load_coreml_artifact(
            output_dir,
            expected_encoder_identity=_fixture_identity(),
        )


def test_coreml_benchmark_reports_numerical_and_requested_compute_units(
    tmp_path,
) -> None:
    output_dir = tmp_path / "coreml-bundle"
    source_model = _TinyEmbeddingModel().eval()
    first_input = torch.linspace(
        -1.0,
        1.0,
        steps=1 * 3 * 8 * 8,
        dtype=torch.float32,
    ).reshape(1, 3, 8, 8)
    second_input = first_input.flip(-1)
    convert_embedding_model_to_coreml(
        model=source_model,
        encoder_identity=_fixture_identity(),
        example_input=first_input,
        output_dir=output_dir,
    )

    report = benchmark_coreml_artifact(
        bundle_path=output_dir,
        expected_encoder_identity=_fixture_identity(),
        source_model=source_model,
        inputs=(first_input, second_input),
        warmup_iterations=1,
        measured_iterations=3,
    )

    assert report["schema_revision"] == 2
    assert report["artifact"]["model_sha256"] == json.loads(
        (output_dir / "manifest.json").read_text()
    )["model_sha256"]
    assert report["artifact"]["encoder"] == {
        "provider": "fixture",
        "model_id": "fixture-encoder",
        "model_revision": "fixture-model-revision",
        "preprocessing_revision": "fixture-preprocessing-v1",
        "element_count": 4,
    }
    assert report["acceptance_thresholds"] == {
        "minimum_cosine_similarity": 0.999,
        "maximum_relative_l2_error": 0.02,
    }
    assert report["overall_passed"] is True
    assert set(report["compute_units"]) == {"CPU_ONLY", "ALL"}
    for result in report["compute_units"].values():
        assert result["requested_compute_units"] in {"CPU_ONLY", "ALL"}
        assert result["actual_device_allocation_verified"] is False
        assert result["numerical"]["passed"] is True
        assert result["numerical"]["minimum_cosine_similarity"] >= 0.999
        assert result["numerical"]["maximum_relative_l2_error"] <= 0.02
        assert result["performance"]["warmup_iterations"] == 1
        assert result["performance"]["measured_iterations"] == 3
        assert result["performance"]["median_milliseconds"] > 0
        assert result["performance"]["p95_milliseconds"] > 0


def test_coreml_benchmark_reports_anticipated_compute_plan_without_claiming_actual_allocation(
    tmp_path,
) -> None:
    output_dir = tmp_path / "coreml-bundle"
    source_model = _TinyEmbeddingModel().eval()
    example_input = torch.ones((1, 3, 8, 8), dtype=torch.float32)
    convert_embedding_model_to_coreml(
        model=source_model,
        encoder_identity=_fixture_identity(),
        example_input=example_input,
        output_dir=output_dir,
    )

    report = benchmark_coreml_artifact(
        bundle_path=output_dir,
        expected_encoder_identity=_fixture_identity(),
        source_model=source_model,
        inputs=(example_input,),
        warmup_iterations=0,
        measured_iterations=1,
    )

    compute_plan = report["compute_plan"]
    assert compute_plan["requested_compute_units"] == "ALL"
    assert compute_plan["evidence_kind"] == "anticipated_compute_plan"
    assert compute_plan["actual_device_allocation_verified"] is False
    assert compute_plan["accessible_compute_devices"]["cpu"] >= 1
    assert compute_plan["accessible_compute_devices"]["gpu"] >= 1
    assert compute_plan["accessible_compute_devices"]["neural_engine"] >= 1
    assert compute_plan["neural_engine_total_core_count"] > 0

    operations = compute_plan["operations"]
    assert operations["total"] > 0
    assert operations["with_device_usage"] > 0
    assert operations["with_device_usage"] + operations["without_device_usage"] == (
        operations["total"]
    )
    assert set(operations["preferred_compute_device_counts"]) == {
        "cpu",
        "gpu",
        "neural_engine",
    }
    assert set(operations["supported_compute_device_counts"]) == {
        "cpu",
        "gpu",
        "neural_engine",
    }
    assert set(operations["estimated_cost_weight_by_preferred_compute_device"]) == {
        "cpu",
        "gpu",
        "neural_engine",
        "unknown",
    }
    assert sum(operations["preferred_compute_device_counts"].values()) == operations[
        "with_device_usage"
    ]
