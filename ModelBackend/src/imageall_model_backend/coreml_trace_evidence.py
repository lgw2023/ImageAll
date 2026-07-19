from __future__ import annotations

import math
import re
import xml.etree.ElementTree as ET
from typing import Any


_SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
_EXPECTED_ENCODER = {
    "provider": "dinov2",
    "model_id": "facebook/dinov2-small",
    "model_revision": "ed25f3a31f01632728cabb09d1542f84ab7b0056",
    "preprocessing_revision": "dinov2-hf-autoimageprocessor-v1",
    "element_count": 384,
}
_RESOURCE_THRESHOLDS = {
    "maximum_artifact_bytes": 80 * 1024 * 1024,
    "maximum_cold_load_seconds": 2.0,
    "maximum_median_milliseconds": 50.0,
    "maximum_p95_milliseconds": 100.0,
    "maximum_peak_rss_increment_bytes": 350 * 1024 * 1024,
    "maximum_thermal_state": "fair",
    "minimum_sequential_inference_count": 1000,
}
_THERMAL_STATES = ("nominal", "fair", "serious", "critical")


class CoreMLTraceEvidenceError(ValueError):
    pass


def verify_coreml_trace_evidence(
    *,
    benchmark: object,
    toc_xml: str,
    ane_intervals_xml: str,
) -> dict[str, object]:
    benchmark_payload = _mapping(benchmark)
    benchmark_evidence = _benchmark_evidence(benchmark_payload)
    toc_evidence = _toc_evidence(_parse_xml(toc_xml))
    ane_evidence = _ane_evidence(_parse_xml(ane_intervals_xml))
    return {
        "actual_device_allocation_verified": True,
        "benchmark": benchmark_evidence["benchmark"],
        "device": toc_evidence["device"],
        "encoder": benchmark_evidence["encoder"],
        "evidence_kind": "instruments_core_ml_trace",
        "instruments": toc_evidence["instruments"],
        "neural_engine": ane_evidence,
        "schema_revision": 1,
        "target": toc_evidence["target"],
    }


def verify_coreml_resource_trace_evidence(
    *,
    resource_report: object,
    toc_xml: str,
    ane_intervals_xml: str,
) -> dict[str, object]:
    report_evidence = _resource_report_evidence(_mapping(resource_report))
    toc_evidence = _toc_evidence(_parse_xml(toc_xml))
    ane_evidence = _ane_evidence(_parse_xml(ane_intervals_xml))
    return {
        "actual_device_allocation_verified": True,
        "artifact": report_evidence["artifact"],
        "device": toc_evidence["device"],
        "evidence_kind": "instruments_coreml_resource_trace",
        "instruments": toc_evidence["instruments"],
        "neural_engine": ane_evidence,
        "resource_benchmark": report_evidence["resource_benchmark"],
        "schema_revision": 1,
        "target": toc_evidence["target"],
    }


def _benchmark_evidence(payload: dict[str, Any]) -> dict[str, object]:
    if payload.get("schema_revision") != 2 or payload.get("overall_passed") is not True:
        raise CoreMLTraceEvidenceError("benchmark did not pass")
    input_count = _integer(payload.get("input_count"), minimum=8)
    input_revision = _nonempty_string(payload.get("input_generation_revision"))
    if input_revision != "imageall-dinov2-synthetic-rgb-processor-v1":
        raise CoreMLTraceEvidenceError("benchmark inputs are not approved fixtures")
    artifact = _mapping(payload.get("artifact"))
    encoder = _mapping(artifact.get("encoder"))
    if encoder != _EXPECTED_ENCODER:
        raise CoreMLTraceEvidenceError("unexpected encoder identity")
    model_sha256 = _nonempty_string(artifact.get("model_sha256"))
    if _SHA256_PATTERN.fullmatch(model_sha256) is None:
        raise CoreMLTraceEvidenceError("invalid artifact digest")

    compute_units = _mapping(payload.get("compute_units"))
    all_units = _compute_unit_evidence(
        compute_units.get("ALL"),
        expected_name="ALL",
        include_numerical=True,
    )
    cpu_only = _compute_unit_evidence(
        compute_units.get("CPU_ONLY"),
        expected_name="CPU_ONLY",
        include_numerical=False,
    )
    return {
        "benchmark": {
            "all": all_units,
            "cpu_only": cpu_only,
            "input_count": input_count,
            "input_generation_revision": input_revision,
        },
        "encoder": {**_EXPECTED_ENCODER, "model_sha256": model_sha256},
    }


def _resource_report_evidence(payload: dict[str, Any]) -> dict[str, object]:
    if payload.get("schema_revision") != 1 or payload.get("overall_passed") is not True:
        raise CoreMLTraceEvidenceError("resource benchmark did not pass")
    if payload.get("compute_units") != "ALL":
        raise CoreMLTraceEvidenceError("unexpected compute unit request")
    if payload.get("input_generation_revision") != (
        "imageall-coreml-synthetic-tensor-v1"
    ):
        raise CoreMLTraceEvidenceError("resource inputs are not approved fixtures")
    input_count = _integer(payload.get("input_count"), minimum=8)
    if payload.get("acceptance_thresholds") != _RESOURCE_THRESHOLDS:
        raise CoreMLTraceEvidenceError("resource thresholds do not match")

    artifact = _mapping(payload.get("artifact"))
    if artifact.get("encoder") != _EXPECTED_ENCODER:
        raise CoreMLTraceEvidenceError("unexpected encoder identity")
    model_sha256 = _nonempty_string(artifact.get("model_sha256"))
    if _SHA256_PATTERN.fullmatch(model_sha256) is None:
        raise CoreMLTraceEvidenceError("invalid artifact digest")

    performance_payload = _mapping(payload.get("performance"))
    performance = {
        "cold_load_seconds": _number(
            performance_payload.get("cold_load_seconds"), minimum=0.0
        ),
        "dependency_initialization_seconds": _number(
            performance_payload.get("dependency_initialization_seconds"),
            minimum=0.0,
        ),
        "measured_iterations": _integer(
            performance_payload.get("measured_iterations"), minimum=1000
        ),
        "median_milliseconds": _number(
            performance_payload.get("median_milliseconds"), minimum=0.0
        ),
        "p95_milliseconds": _number(
            performance_payload.get("p95_milliseconds"), minimum=0.0
        ),
        "warmup_iterations": _integer(
            performance_payload.get("warmup_iterations"), minimum=0
        ),
    }
    if (
        performance["cold_load_seconds"] > 2.0
        or performance["median_milliseconds"] > 50.0
        or performance["p95_milliseconds"] > 100.0
        or performance["p95_milliseconds"] < performance["median_milliseconds"]
    ):
        raise CoreMLTraceEvidenceError("resource performance below threshold")

    resources_payload = _mapping(payload.get("resources"))
    resources = {
        "artifact_bytes": _integer(
            resources_payload.get("artifact_bytes"), minimum=1
        ),
        "baseline_rss_bytes": _integer(
            resources_payload.get("baseline_rss_bytes"), minimum=1
        ),
        "peak_rss_bytes": _integer(
            resources_payload.get("peak_rss_bytes"), minimum=1
        ),
        "peak_rss_increment_bytes": _integer(
            resources_payload.get("peak_rss_increment_bytes"), minimum=0
        ),
        "sample_count": _integer(
            resources_payload.get("sample_count"), minimum=1
        ),
        "thermal_state_end": _thermal_state(
            resources_payload.get("thermal_state_end")
        ),
        "thermal_state_max": _thermal_state(
            resources_payload.get("thermal_state_max")
        ),
        "thermal_state_start": _thermal_state(
            resources_payload.get("thermal_state_start")
        ),
    }
    if (
        resources["artifact_bytes"] > 80 * 1024 * 1024
        or resources["peak_rss_bytes"] < resources["baseline_rss_bytes"]
        or resources["peak_rss_increment_bytes"] > 350 * 1024 * 1024
        or _THERMAL_STATES.index(resources["thermal_state_max"])
        > _THERMAL_STATES.index("fair")
    ):
        raise CoreMLTraceEvidenceError("resource usage below threshold")

    stability_payload = _mapping(payload.get("stability"))
    stability = {
        "inference_failure_count": _integer(
            stability_payload.get("inference_failure_count"), minimum=0
        ),
        "nonfinite_output_count": _integer(
            stability_payload.get("nonfinite_output_count"), minimum=0
        ),
        "sequential_inference_count": _integer(
            stability_payload.get("sequential_inference_count"), minimum=1000
        ),
    }
    if (
        stability["sequential_inference_count"]
        != performance["measured_iterations"]
        or stability["inference_failure_count"] != 0
        or stability["nonfinite_output_count"] != 0
    ):
        raise CoreMLTraceEvidenceError("resource stability below threshold")

    return {
        "artifact": {
            "encoder": dict(_EXPECTED_ENCODER),
            "model_sha256": model_sha256,
        },
        "resource_benchmark": {
            "acceptance_thresholds": dict(_RESOURCE_THRESHOLDS),
            "compute_units": "ALL",
            "input_count": input_count,
            "input_generation_revision": (
                "imageall-coreml-synthetic-tensor-v1"
            ),
            "overall_passed": True,
            "performance": performance,
            "resources": resources,
            "stability": stability,
        },
    }


def _thermal_state(value: object) -> str:
    result = _nonempty_string(value)
    if result not in _THERMAL_STATES:
        raise CoreMLTraceEvidenceError("invalid thermal state")
    return result


def _compute_unit_evidence(
    value: object,
    *,
    expected_name: str,
    include_numerical: bool,
) -> dict[str, object]:
    entry = _mapping(value)
    if entry.get("requested_compute_units") != expected_name:
        raise CoreMLTraceEvidenceError("unexpected compute unit request")
    if entry.get("actual_device_allocation_verified") is not False:
        raise CoreMLTraceEvidenceError("benchmark must not self-claim allocation")
    numerical = _mapping(entry.get("numerical"))
    if numerical.get("passed") is not True:
        raise CoreMLTraceEvidenceError("numerical benchmark did not pass")
    minimum_cosine = _number(numerical.get("minimum_cosine_similarity"))
    maximum_relative_l2 = _number(numerical.get("maximum_relative_l2_error"))
    if minimum_cosine < 0.999 or maximum_relative_l2 > 0.02:
        raise CoreMLTraceEvidenceError("numerical benchmark below threshold")

    performance = _mapping(entry.get("performance"))
    result: dict[str, object] = {
        "measured_iterations": _integer(
            performance.get("measured_iterations"), minimum=1
        ),
        "median_milliseconds": _number(
            performance.get("median_milliseconds"), minimum=0.0
        ),
        "p95_milliseconds": _number(
            performance.get("p95_milliseconds"), minimum=0.0
        ),
        "warmup_iterations": _integer(
            performance.get("warmup_iterations"), minimum=0
        ),
    }
    if include_numerical:
        result.update(
            {
                "maximum_relative_l2_error": maximum_relative_l2,
                "minimum_cosine_similarity": minimum_cosine,
            }
        )
    return result


def _toc_evidence(root: ET.Element) -> dict[str, object]:
    info = root.find("./run[@number='1']/info")
    if info is None:
        raise CoreMLTraceEvidenceError("missing trace run")
    target = info.find("./target")
    summary = info.find("./summary")
    if target is None or summary is None:
        raise CoreMLTraceEvidenceError("missing trace metadata")
    device = target.find("./device")
    process = target.find("./process")
    if device is None or process is None:
        raise CoreMLTraceEvidenceError("missing trace target")
    if process.get("type") not in {"attached", "launched"}:
        raise CoreMLTraceEvidenceError("unsupported trace target")
    if process.get("return-exit-status") != "0":
        raise CoreMLTraceEvidenceError("trace target failed")
    if process.get("termination-reason") != "exit(0)":
        raise CoreMLTraceEvidenceError("trace target did not exit cleanly")
    template = _element_text(summary.find("./template-name"))
    if template != "Core ML":
        raise CoreMLTraceEvidenceError("wrong Instruments template")
    return {
        "device": {
            "model": _nonempty_string(device.get("model")),
            "os_version": _nonempty_string(device.get("os-version")),
            "platform": _nonempty_string(device.get("platform")),
        },
        "instruments": {
            "template": template,
            "version": _element_text(summary.find("./instruments-version")),
        },
        "target": {
            "exit_status": 0,
            "termination_reason": "exit(0)",
        },
    }


def _ane_evidence(root: ET.Element) -> dict[str, object]:
    node = root.find("./node")
    if node is None:
        raise CoreMLTraceEvidenceError("missing ANE trace node")
    schema = node.find("./schema")
    if schema is None or schema.get("name") != "ane-hw-intervals-internal":
        raise CoreMLTraceEvidenceError("wrong ANE trace schema")

    durations = []
    references: dict[str, str] = {}
    for row in node.findall("./row"):
        channel = _resolved_xml_value(row.find("./ane-event-name"), references)
        state = _resolved_xml_value(row.find("./gpu-state"), references)
        label = _resolved_xml_value(row.find("./formatted-label"), references)
        if (
            channel == "Apple Neural Engine"
            and state == "Active"
            and "AneInference" in label
        ):
            duration_text = _resolved_xml_value(row.find("./duration"), references)
            try:
                duration_nanoseconds = int(duration_text)
            except (TypeError, ValueError) as error:
                raise CoreMLTraceEvidenceError("invalid ANE interval") from error
            if duration_nanoseconds <= 0:
                raise CoreMLTraceEvidenceError("invalid ANE interval")
            durations.append(duration_nanoseconds)
    if not durations:
        raise CoreMLTraceEvidenceError("no active ANE inference interval")
    return {
        "active_inference_interval_count": len(durations),
        "total_active_inference_duration_milliseconds": sum(durations) / 1_000_000,
    }


def _resolved_xml_value(
    element: ET.Element | None,
    references: dict[str, str],
) -> str:
    if element is None:
        return ""
    reference = element.get("ref")
    if reference is not None:
        try:
            return references[reference]
        except KeyError as error:
            raise CoreMLTraceEvidenceError("unknown XML reference") from error
    parts = [element.text or ""]
    for child in element:
        parts.append(_resolved_xml_value(child, references))
        parts.append(child.tail or "")
    value = "".join(parts)
    identifier = element.get("id")
    if identifier is not None:
        references[identifier] = value
    return value


def _parse_xml(payload: str) -> ET.Element:
    if not isinstance(payload, str) or "<!DOCTYPE" in payload or "<!ENTITY" in payload:
        raise CoreMLTraceEvidenceError("unsafe XML")
    try:
        return ET.fromstring(payload)
    except ET.ParseError as error:
        raise CoreMLTraceEvidenceError("invalid XML") from error


def _mapping(value: object) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CoreMLTraceEvidenceError("expected object")
    return value


def _integer(value: object, *, minimum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise CoreMLTraceEvidenceError("invalid integer")
    return value


def _number(value: object, *, minimum: float | None = None) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise CoreMLTraceEvidenceError("invalid number")
    result = float(value)
    if not math.isfinite(result) or (minimum is not None and result < minimum):
        raise CoreMLTraceEvidenceError("invalid number")
    return result


def _nonempty_string(value: object) -> str:
    if not isinstance(value, str) or not value:
        raise CoreMLTraceEvidenceError("invalid string")
    return value


def _element_text(element: ET.Element | None) -> str:
    value = _optional_element_text(element)
    if not value:
        raise CoreMLTraceEvidenceError("missing XML value")
    return value


def _optional_element_text(element: ET.Element | None) -> str:
    return "" if element is None or element.text is None else element.text
