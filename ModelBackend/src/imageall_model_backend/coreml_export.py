from __future__ import annotations

import hashlib
import json
import shutil
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import torch

from imageall_model_backend.providers import EmbeddingProviderIdentity

COREML_ARTIFACT_SCHEMA_REVISION = 1
COREML_MODEL_PACKAGE_NAME = "encoder.mlpackage"
COREML_MANIFEST_NAME = "manifest.json"
COREML_BENCHMARK_SCHEMA_REVISION = 2
COREML_MINIMUM_COSINE_SIMILARITY = 0.999
COREML_MAXIMUM_RELATIVE_L2_ERROR = 0.02


@dataclass(frozen=True)
class CoreMLConversionResult:
    bundle_path: Path
    model_path: Path
    model_sha256: str


@dataclass(frozen=True)
class CoreMLArtifact:
    bundle_path: Path
    model_path: Path
    model_sha256: str
    encoder_identity: EmbeddingProviderIdentity
    input_shape: tuple[int, ...]
    output_shape: tuple[int, ...]
    _model: Any

    def predict(self, pixel_values: np.ndarray) -> np.ndarray:
        values = np.asarray(pixel_values, dtype=np.float32)
        if values.shape != self.input_shape or not np.isfinite(values).all():
            raise ValueError("Core ML input does not match the artifact contract")
        prediction = np.asarray(
            self._model.predict({"pixel_values": values})["embedding"],
            dtype=np.float32,
        )
        if prediction.shape != self.output_shape or not np.isfinite(prediction).all():
            raise RuntimeError("Core ML returned an invalid embedding")
        return prediction


def convert_embedding_model_to_coreml(
    *,
    model: torch.nn.Module,
    encoder_identity: EmbeddingProviderIdentity,
    example_input: torch.Tensor,
    output_dir: Path,
) -> CoreMLConversionResult:
    ct = _coremltools()
    output_dir = Path(output_dir)
    if output_dir.exists():
        raise FileExistsError(f"Core ML output already exists: {output_dir}")
    if example_input.dtype != torch.float32 or example_input.ndim != 4:
        raise ValueError("Core ML example input must be a rank-4 float32 tensor")

    cpu_model = model.eval().cpu()
    cpu_input = example_input.detach().cpu()
    with torch.inference_mode():
        source_output = cpu_model(cpu_input)
    expected_output_shape = (cpu_input.shape[0], encoder_identity.element_count)
    if tuple(source_output.shape) != expected_output_shape:
        raise ValueError("embedding model output does not match encoder identity")
    if not torch.isfinite(source_output).all():
        raise ValueError("embedding model returned non-finite values")

    traced = torch.jit.trace(cpu_model, cpu_input, strict=True)
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    temporary_dir = Path(
        tempfile.mkdtemp(prefix=f".{output_dir.name}-", dir=output_dir.parent)
    )
    temporary_model_path = temporary_dir / COREML_MODEL_PACKAGE_NAME
    try:
        coreml_model = ct.convert(
            traced,
            convert_to="mlprogram",
            compute_precision=ct.precision.FLOAT16,
            minimum_deployment_target=ct.target.macOS15,
            inputs=[
                ct.TensorType(
                    name="pixel_values",
                    shape=tuple(cpu_input.shape),
                    dtype=np.float32,
                )
            ],
            outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        )
        coreml_model.author = "ImageAll"
        coreml_model.short_description = "Versioned ImageAll embedding encoder"
        coreml_model.user_defined_metadata.update(
            {
                "com.imageall.provider": encoder_identity.provider,
                "com.imageall.model-id": encoder_identity.model_id,
                "com.imageall.model-revision": encoder_identity.model_revision,
                "com.imageall.preprocessing-revision": (
                    encoder_identity.preprocessing_revision
                ),
            }
        )
        coreml_model.save(temporary_model_path)
        model_sha256 = _directory_sha256(temporary_model_path)
        manifest = {
            "schema_revision": COREML_ARTIFACT_SCHEMA_REVISION,
            "encoder": _identity_dict(encoder_identity),
            "conversion": {
                "source_graph": "torch.jit.trace",
                "model_format": "mlprogram",
                "compute_precision": "float16",
                "minimum_deployment_target": "macOS15",
                "torch_version": torch.__version__,
                "coremltools_version": ct.__version__,
            },
            "input": {
                "name": "pixel_values",
                "shape": list(cpu_input.shape),
                "element_type": "float32",
            },
            "output": {
                "name": "embedding",
                "shape": list(expected_output_shape),
                "element_type": "float32",
            },
            "model_path": COREML_MODEL_PACKAGE_NAME,
            "model_sha256": model_sha256,
        }
        (temporary_dir / COREML_MANIFEST_NAME).write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        temporary_dir.replace(output_dir)
    except BaseException:
        shutil.rmtree(temporary_dir, ignore_errors=True)
        raise

    return CoreMLConversionResult(
        bundle_path=output_dir,
        model_path=output_dir / COREML_MODEL_PACKAGE_NAME,
        model_sha256=model_sha256,
    )


def load_coreml_artifact(
    bundle_path: Path,
    *,
    expected_encoder_identity: EmbeddingProviderIdentity,
    compute_units: Any | None = None,
) -> CoreMLArtifact:
    ct = _coremltools()
    bundle_path = Path(bundle_path)
    try:
        manifest = json.loads(
            (bundle_path / COREML_MANIFEST_NAME).read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError("Core ML manifest is missing or invalid") from error

    if manifest.get("schema_revision") != COREML_ARTIFACT_SCHEMA_REVISION:
        raise ValueError("unsupported Core ML artifact schema")
    if manifest.get("encoder") != _identity_dict(expected_encoder_identity):
        raise ValueError("Core ML encoder identity does not match")
    conversion_identity = manifest.get("conversion")
    if not isinstance(conversion_identity, dict) or {
        "source_graph": conversion_identity.get("source_graph"),
        "model_format": conversion_identity.get("model_format"),
        "compute_precision": conversion_identity.get("compute_precision"),
        "minimum_deployment_target": conversion_identity.get(
            "minimum_deployment_target"
        ),
    } != {
        "source_graph": "torch.jit.trace",
        "model_format": "mlprogram",
        "compute_precision": "float16",
        "minimum_deployment_target": "macOS15",
    }:
        raise ValueError("Core ML conversion identity does not match")

    input_contract = manifest.get("input")
    output_contract = manifest.get("output")
    expected_output_shape = [1, expected_encoder_identity.element_count]
    if (
        not isinstance(input_contract, dict)
        or input_contract.get("name") != "pixel_values"
    ):
        raise ValueError("Core ML input contract is invalid")
    if (
        input_contract.get("element_type") != "float32"
        or not _valid_shape(input_contract.get("shape"), rank=4)
        or input_contract["shape"][0] != 1
    ):
        raise ValueError("Core ML input contract is invalid")
    if output_contract != {
        "name": "embedding",
        "shape": expected_output_shape,
        "element_type": "float32",
    }:
        raise ValueError("Core ML output contract is invalid")
    if manifest.get("model_path") != COREML_MODEL_PACKAGE_NAME:
        raise ValueError("Core ML model path is invalid")

    model_path = bundle_path / COREML_MODEL_PACKAGE_NAME
    if not model_path.is_dir() or model_path.is_symlink():
        raise ValueError("Core ML model package is missing or unsafe")
    model_sha256 = _directory_sha256(model_path)
    if manifest.get("model_sha256") != model_sha256:
        raise ValueError("Core ML model checksum does not match")

    load_options = {}
    if compute_units is not None:
        load_options["compute_units"] = compute_units
    coreml_model = ct.models.MLModel(str(model_path), **load_options)
    return CoreMLArtifact(
        bundle_path=bundle_path,
        model_path=model_path,
        model_sha256=model_sha256,
        encoder_identity=expected_encoder_identity,
        input_shape=tuple(input_contract["shape"]),
        output_shape=tuple(expected_output_shape),
        _model=coreml_model,
    )


def benchmark_coreml_artifact(
    *,
    bundle_path: Path,
    expected_encoder_identity: EmbeddingProviderIdentity,
    source_model: torch.nn.Module,
    inputs: tuple[torch.Tensor, ...],
    warmup_iterations: int,
    measured_iterations: int,
) -> dict[str, object]:
    if not inputs:
        raise ValueError("Core ML benchmark requires at least one input")
    if warmup_iterations < 0 or measured_iterations < 1:
        raise ValueError("Core ML benchmark iteration counts are invalid")

    ct = _coremltools()
    source_model = source_model.eval().cpu()
    cpu_inputs = tuple(value.detach().cpu() for value in inputs)
    with torch.inference_mode():
        source_outputs = tuple(
            np.asarray(source_model(value).detach().numpy(), dtype=np.float32)
            for value in cpu_inputs
        )

    compute_unit_results: dict[str, object] = {}
    all_artifact: CoreMLArtifact | None = None
    for name, compute_units in (
        ("CPU_ONLY", ct.ComputeUnit.CPU_ONLY),
        ("ALL", ct.ComputeUnit.ALL),
    ):
        artifact = load_coreml_artifact(
            bundle_path,
            expected_encoder_identity=expected_encoder_identity,
            compute_units=compute_units,
        )
        if name == "ALL":
            all_artifact = artifact
        numpy_inputs = tuple(
            np.asarray(value.numpy(), dtype=np.float32) for value in cpu_inputs
        )
        coreml_outputs = tuple(artifact.predict(value) for value in numpy_inputs)
        numerical = _numerical_summary(source_outputs, coreml_outputs)

        for iteration in range(warmup_iterations):
            artifact.predict(numpy_inputs[iteration % len(numpy_inputs)])
        durations: list[float] = []
        for iteration in range(measured_iterations):
            selected_input = numpy_inputs[iteration % len(numpy_inputs)]
            start = time.perf_counter()
            artifact.predict(selected_input)
            durations.append((time.perf_counter() - start) * 1000.0)

        compute_unit_results[name] = {
            "requested_compute_units": name,
            "actual_device_allocation_verified": False,
            "numerical": numerical,
            "performance": {
                "warmup_iterations": warmup_iterations,
                "measured_iterations": measured_iterations,
                "median_milliseconds": float(np.median(durations)),
                "p95_milliseconds": float(np.percentile(durations, 95)),
            },
        }

    manifest = json.loads(
        (Path(bundle_path) / COREML_MANIFEST_NAME).read_text(encoding="utf-8")
    )
    if all_artifact is None:
        raise RuntimeError("Core ML ALL artifact was not loaded")
    return {
        "schema_revision": COREML_BENCHMARK_SCHEMA_REVISION,
        "artifact": {
            "encoder": _identity_dict(expected_encoder_identity),
            "model_sha256": manifest["model_sha256"],
        },
        "input_generation_revision": "caller-supplied-preprocessed-tensor-v1",
        "input_count": len(cpu_inputs),
        "acceptance_thresholds": {
            "minimum_cosine_similarity": COREML_MINIMUM_COSINE_SIMILARITY,
            "maximum_relative_l2_error": COREML_MAXIMUM_RELATIVE_L2_ERROR,
        },
        "compute_units": compute_unit_results,
        "compute_plan": _coreml_compute_plan_summary(all_artifact),
        "overall_passed": all(
            result["numerical"]["passed"]
            for result in compute_unit_results.values()
        ),
    }


def _coreml_compute_plan_summary(artifact: CoreMLArtifact) -> dict[str, object]:
    from coremltools.models.compute_device import (
        MLComputeDevice,
        MLCPUComputeDevice,
        MLGPUComputeDevice,
        MLNeuralEngineComputeDevice,
    )
    from coremltools.models.compute_plan import MLComputePlan

    ct = _coremltools()
    device_types = (
        (MLCPUComputeDevice, "cpu"),
        (MLGPUComputeDevice, "gpu"),
        (MLNeuralEngineComputeDevice, "neural_engine"),
    )

    def device_name(device: object) -> str:
        for device_type, name in device_types:
            if isinstance(device, device_type):
                return name
        raise RuntimeError("Core ML compute plan returned an unknown device")

    compiled_model_path = artifact._model.get_compiled_model_path()
    compute_plan = MLComputePlan.load_from_path(
        compiled_model_path,
        compute_units=ct.ComputeUnit.ALL,
    )
    program = compute_plan.model_structure.program
    if program is None:
        raise RuntimeError("Core ML compute plan is not an ML Program")

    accessible_counts = {"cpu": 0, "gpu": 0, "neural_engine": 0}
    neural_engine_total_core_count = 0
    for device in MLComputeDevice.get_all_compute_devices():
        name = device_name(device)
        accessible_counts[name] += 1
        if name == "neural_engine":
            neural_engine_total_core_count += device.total_core_count

    preferred_counts = {"cpu": 0, "gpu": 0, "neural_engine": 0}
    supported_counts = {"cpu": 0, "gpu": 0, "neural_engine": 0}
    estimated_costs = {
        "cpu": 0.0,
        "gpu": 0.0,
        "neural_engine": 0.0,
        "unknown": 0.0,
    }
    total_operations = 0
    operations_with_device_usage = 0

    def visit_block(block: Any) -> None:
        nonlocal total_operations, operations_with_device_usage
        for operation in block.operations:
            total_operations += 1
            usage = compute_plan.get_compute_device_usage_for_mlprogram_operation(
                operation
            )
            preferred_name = "unknown"
            if usage is not None:
                operations_with_device_usage += 1
                preferred_name = device_name(usage.preferred_compute_device)
                preferred_counts[preferred_name] += 1
                supported_names = {
                    device_name(device)
                    for device in usage.supported_compute_devices
                }
                if preferred_name not in supported_names:
                    raise RuntimeError(
                        "Core ML compute plan preferred device is not supported"
                    )
                for name in supported_names:
                    supported_counts[name] += 1

            cost = compute_plan.get_estimated_cost_for_mlprogram_operation(operation)
            if cost is not None:
                weight = float(cost.weight)
                if not np.isfinite(weight) or weight < 0.0 or weight > 1.0:
                    raise RuntimeError("Core ML compute plan cost is invalid")
                estimated_costs[preferred_name] += weight
            for nested_block in operation.blocks:
                visit_block(nested_block)

    for function in program.functions.values():
        visit_block(function.block)

    if total_operations < 1 or operations_with_device_usage < 1:
        raise RuntimeError("Core ML compute plan has no device usage evidence")
    return {
        "requested_compute_units": "ALL",
        "evidence_kind": "anticipated_compute_plan",
        "actual_device_allocation_verified": False,
        "accessible_compute_devices": accessible_counts,
        "neural_engine_total_core_count": neural_engine_total_core_count,
        "operations": {
            "total": total_operations,
            "with_device_usage": operations_with_device_usage,
            "without_device_usage": total_operations - operations_with_device_usage,
            "preferred_compute_device_counts": preferred_counts,
            "supported_compute_device_counts": supported_counts,
            "estimated_cost_weight_by_preferred_compute_device": estimated_costs,
        },
    }


def _coremltools() -> Any:
    try:
        import coremltools as ct
    except ImportError as error:
        raise RuntimeError(
            "Core ML support is not installed; install imageall-model-backend[coreml]"
        ) from error
    return ct


def _identity_dict(identity: EmbeddingProviderIdentity) -> dict[str, object]:
    return {
        "provider": identity.provider,
        "model_id": identity.model_id,
        "model_revision": identity.model_revision,
        "preprocessing_revision": identity.preprocessing_revision,
        "element_count": identity.element_count,
    }


def _numerical_summary(
    expected_outputs: tuple[np.ndarray, ...],
    actual_outputs: tuple[np.ndarray, ...],
) -> dict[str, object]:
    cosine_similarities: list[float] = []
    maximum_absolute_error = 0.0
    maximum_relative_l2_error = 0.0
    for expected, actual in zip(expected_outputs, actual_outputs, strict=True):
        if expected.shape != actual.shape or not np.isfinite(actual).all():
            raise RuntimeError("Core ML benchmark returned an invalid embedding")
        maximum_absolute_error = max(
            maximum_absolute_error,
            float(np.max(np.abs(expected - actual))),
        )
        expected_flat = expected.reshape(-1).astype(np.float64)
        actual_flat = actual.reshape(-1).astype(np.float64)
        expected_norm = float(np.linalg.norm(expected_flat))
        absolute_l2_error = float(np.linalg.norm(expected_flat - actual_flat))
        relative_l2_error = (
            absolute_l2_error / expected_norm
            if expected_norm > 0
            else float(absolute_l2_error > 0)
        )
        maximum_relative_l2_error = max(
            maximum_relative_l2_error,
            relative_l2_error,
        )
        denominator = float(
            expected_norm * np.linalg.norm(actual_flat)
        )
        cosine_similarities.append(
            float(np.dot(expected_flat, actual_flat) / denominator)
            if denominator > 0
            else float(np.array_equal(expected_flat, actual_flat))
        )

    minimum_cosine_similarity = min(cosine_similarities)
    passed = (
        minimum_cosine_similarity >= COREML_MINIMUM_COSINE_SIMILARITY
        and maximum_relative_l2_error <= COREML_MAXIMUM_RELATIVE_L2_ERROR
    )
    return {
        "minimum_cosine_similarity": minimum_cosine_similarity,
        "maximum_absolute_error": maximum_absolute_error,
        "maximum_relative_l2_error": maximum_relative_l2_error,
        "passed": passed,
    }


def _valid_shape(value: object, *, rank: int) -> bool:
    return (
        isinstance(value, list)
        and len(value) == rank
        and all(
            isinstance(item, int) and not isinstance(item, bool) and item > 0
            for item in value
        )
    )


def _directory_sha256(directory: Path) -> str:
    digest = hashlib.sha256()
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError("Core ML model package is missing or unsafe")
    for path in sorted(
        directory.rglob("*"),
        key=lambda item: item.relative_to(directory).as_posix(),
    ):
        if path.is_symlink():
            raise ValueError("Core ML model package contains a symlink")
        if not path.is_file():
            continue
        relative_path = path.relative_to(directory).as_posix().encode("utf-8")
        content = path.read_bytes()
        digest.update(len(relative_path).to_bytes(8, "big"))
        digest.update(relative_path)
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
    return digest.hexdigest()
