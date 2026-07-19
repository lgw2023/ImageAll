import json
import subprocess
import sys

import pytest

from imageall_model_backend import coreml_trace_evidence_cli
from imageall_model_backend.coreml_trace_evidence import (
    CoreMLTraceEvidenceError,
    verify_coreml_trace_evidence,
    verify_coreml_resource_trace_evidence,
)


def _benchmark() -> dict:
    return {
        "schema_revision": 2,
        "overall_passed": True,
        "input_count": 8,
        "input_generation_revision": (
            "imageall-dinov2-synthetic-rgb-processor-v1"
        ),
        "artifact": {
            "model_sha256": "a" * 64,
            "encoder": {
                "provider": "dinov2",
                "model_id": "facebook/dinov2-small",
                "model_revision": "ed25f3a31f01632728cabb09d1542f84ab7b0056",
                "preprocessing_revision": "dinov2-hf-autoimageprocessor-v1",
                "element_count": 384,
            },
        },
        "compute_units": {
            "ALL": {
                "requested_compute_units": "ALL",
                "actual_device_allocation_verified": False,
                "numerical": {
                    "passed": True,
                    "minimum_cosine_similarity": 0.9999,
                    "maximum_relative_l2_error": 0.01,
                },
                "performance": {
                    "warmup_iterations": 5,
                    "measured_iterations": 50,
                    "median_milliseconds": 2.8,
                    "p95_milliseconds": 3.0,
                },
            },
            "CPU_ONLY": {
                "requested_compute_units": "CPU_ONLY",
                "actual_device_allocation_verified": False,
                "numerical": {
                    "passed": True,
                    "minimum_cosine_similarity": 0.9998,
                    "maximum_relative_l2_error": 0.015,
                },
                "performance": {
                    "warmup_iterations": 5,
                    "measured_iterations": 50,
                    "median_milliseconds": 6.8,
                    "p95_milliseconds": 7.3,
                },
            },
        },
    }


def _toc(*, exit_status: int = 0, template: str = "Core ML") -> str:
    return f"""<?xml version="1.0"?>
<trace-toc>
  <run number="1">
    <info>
      <target>
        <device platform="macOS" model="Mac mini" name="private-host"
                os-version="26.5.1 (25F80)" uuid="private-uuid"/>
        <process type="attached" return-exit-status="{exit_status}"
                 name="python3" pid="1234" termination-reason="exit({exit_status})"/>
      </target>
      <environment><item key="SECRET_TOKEN" value="do-not-emit"/></environment>
      <summary>
        <instruments-version>16.0 (17F113)</instruments-version>
        <template-name>{template}</template-name>
      </summary>
    </info>
  </run>
</trace-toc>
"""


def _ane_intervals(*, include_row: bool = True, state: str = "Active") -> str:
    row = ""
    if include_row:
        row = f"""
    <row>
      <start-time>1160091583</start-time>
      <duration>2545917</duration>
      <ane-event-name>Apple Neural Engine</ane-event-name>
      <formatted-label><string>encoder_main__Op0_AneInference</string></formatted-label>
      <gpu-state>{state}</gpu-state>
    </row>"""
    return f"""<?xml version="1.0"?>
<trace-query-result>
  <node xpath="//trace-toc[1]/run[1]/data[1]/table[34]">
    <schema name="ane-hw-intervals-internal"/>{row}
  </node>
</trace-query-result>
"""


def _resource_report() -> dict:
    return {
        "schema_revision": 1,
        "overall_passed": True,
        "compute_units": "ALL",
        "input_count": 8,
        "input_generation_revision": "imageall-coreml-synthetic-tensor-v1",
        "artifact": {
            "encoder": _benchmark()["artifact"]["encoder"],
            "model_sha256": "c" * 64,
        },
        "acceptance_thresholds": {
            "maximum_artifact_bytes": 80 * 1024 * 1024,
            "maximum_cold_load_seconds": 2.0,
            "maximum_median_milliseconds": 50.0,
            "maximum_p95_milliseconds": 100.0,
            "maximum_peak_rss_increment_bytes": 350 * 1024 * 1024,
            "maximum_thermal_state": "fair",
            "minimum_sequential_inference_count": 1000,
        },
        "performance": {
            "cold_load_seconds": 0.1,
            "dependency_initialization_seconds": 0.7,
            "measured_iterations": 1000,
            "median_milliseconds": 2.7,
            "p95_milliseconds": 2.9,
            "warmup_iterations": 20,
        },
        "resources": {
            "artifact_bytes": 42 * 1024 * 1024,
            "baseline_rss_bytes": 300 * 1024 * 1024,
            "peak_rss_bytes": 355 * 1024 * 1024,
            "peak_rss_increment_bytes": 55 * 1024 * 1024,
            "sample_count": 1200,
            "thermal_state_start": "nominal",
            "thermal_state_max": "nominal",
            "thermal_state_end": "nominal",
        },
        "stability": {
            "inference_failure_count": 0,
            "nonfinite_output_count": 0,
            "sequential_inference_count": 1000,
        },
    }


def test_actual_ane_evidence_is_derived_without_host_metadata() -> None:
    evidence = verify_coreml_trace_evidence(
        benchmark=_benchmark(),
        toc_xml=_toc(),
        ane_intervals_xml=_ane_intervals(),
    )

    assert evidence == {
        "actual_device_allocation_verified": True,
        "benchmark": {
            "all": {
                "maximum_relative_l2_error": 0.01,
                "measured_iterations": 50,
                "median_milliseconds": 2.8,
                "minimum_cosine_similarity": 0.9999,
                "p95_milliseconds": 3.0,
                "warmup_iterations": 5,
            },
            "cpu_only": {
                "measured_iterations": 50,
                "median_milliseconds": 6.8,
                "p95_milliseconds": 7.3,
                "warmup_iterations": 5,
            },
            "input_count": 8,
            "input_generation_revision": (
                "imageall-dinov2-synthetic-rgb-processor-v1"
            ),
        },
        "device": {
            "model": "Mac mini",
            "os_version": "26.5.1 (25F80)",
            "platform": "macOS",
        },
        "encoder": {
            "element_count": 384,
            "model_id": "facebook/dinov2-small",
            "model_revision": "ed25f3a31f01632728cabb09d1542f84ab7b0056",
            "model_sha256": "a" * 64,
            "preprocessing_revision": "dinov2-hf-autoimageprocessor-v1",
            "provider": "dinov2",
        },
        "evidence_kind": "instruments_core_ml_trace",
        "instruments": {
            "template": "Core ML",
            "version": "16.0 (17F113)",
        },
        "neural_engine": {
            "active_inference_interval_count": 1,
            "total_active_inference_duration_milliseconds": 2.545917,
        },
        "schema_revision": 1,
        "target": {
            "exit_status": 0,
            "termination_reason": "exit(0)",
        },
    }
    serialized = json.dumps(evidence, sort_keys=True)
    assert "private-host" not in serialized
    assert "private-uuid" not in serialized
    assert "do-not-emit" not in serialized
    assert "1234" not in serialized


@pytest.mark.parametrize(
    ("benchmark", "toc_xml", "ane_xml"),
    (
        ({**_benchmark(), "overall_passed": False}, _toc(), _ane_intervals()),
        (_benchmark(), _toc(exit_status=2), _ane_intervals()),
        (_benchmark(), _toc(template="Time Profiler"), _ane_intervals()),
        (_benchmark(), _toc(), _ane_intervals(include_row=False)),
        (_benchmark(), _toc(), _ane_intervals(state="Idle")),
    ),
)
def test_unproven_runtime_evidence_is_rejected(
    benchmark, toc_xml, ane_xml
) -> None:
    with pytest.raises(CoreMLTraceEvidenceError):
        verify_coreml_trace_evidence(
            benchmark=benchmark,
            toc_xml=toc_xml,
            ane_intervals_xml=ane_xml,
        )


def test_xml_with_a_document_type_is_rejected() -> None:
    with pytest.raises(CoreMLTraceEvidenceError):
        verify_coreml_trace_evidence(
            benchmark=_benchmark(),
            toc_xml='<!DOCTYPE trace SYSTEM "file:///etc/passwd">' + _toc(),
            ane_intervals_xml=_ane_intervals(),
        )


def test_non_synthetic_benchmark_inputs_are_rejected() -> None:
    benchmark = _benchmark()
    benchmark["input_generation_revision"] = "private-photo-inputs-v1"

    with pytest.raises(CoreMLTraceEvidenceError):
        verify_coreml_trace_evidence(
            benchmark=benchmark,
            toc_xml=_toc(),
            ane_intervals_xml=_ane_intervals(),
        )


def test_repeated_xctrace_rows_resolve_id_references() -> None:
    intervals = _ane_intervals().replace(
        "  </node>",
        """    <row>
      <start-time>1163091583</start-time>
      <duration>3000000</duration>
      <ane-event-name ref="3"/>
      <formatted-label ref="5"/>
      <gpu-state ref="9"/>
    </row>
  </node>""",
    ).replace(
        "<ane-event-name>", '<ane-event-name id="3">',
    ).replace(
        "<formatted-label>", '<formatted-label id="5">',
    ).replace(
        "<gpu-state>", '<gpu-state id="9">',
    )

    evidence = verify_coreml_trace_evidence(
        benchmark=_benchmark(),
        toc_xml=_toc(),
        ane_intervals_xml=intervals,
    )

    assert evidence["neural_engine"] == {
        "active_inference_interval_count": 2,
        "total_active_inference_duration_milliseconds": 5.545917,
    }


def test_resource_trace_evidence_preserves_compiled_identity() -> None:
    intervals = _ane_intervals().replace(
        "  </node>",
        """    <row>
      <duration>3000000</duration>
      <ane-event-name ref="3"/>
      <formatted-label ref="5"/>
      <gpu-state ref="9"/>
    </row>
  </node>""",
    ).replace(
        "<ane-event-name>", '<ane-event-name id="3">',
    ).replace(
        "<formatted-label>", '<formatted-label id="5">',
    ).replace(
        "<gpu-state>", '<gpu-state id="9">',
    )

    evidence = verify_coreml_resource_trace_evidence(
        resource_report=_resource_report(),
        toc_xml=_toc(),
        ane_intervals_xml=intervals,
    )

    assert evidence["actual_device_allocation_verified"] is True
    assert evidence["evidence_kind"] == "instruments_coreml_resource_trace"
    assert evidence["artifact"]["model_sha256"] == "c" * 64
    assert evidence["resource_benchmark"]["overall_passed"] is True
    assert evidence["neural_engine"] == {
        "active_inference_interval_count": 2,
        "total_active_inference_duration_milliseconds": 5.545917,
    }


def test_cli_accepts_a_passing_resource_report(tmp_path, capsys) -> None:
    report_path = tmp_path / "resource.json"
    toc_path = tmp_path / "toc.xml"
    ane_path = tmp_path / "ane.xml"
    report_path.write_text(json.dumps(_resource_report()), encoding="utf-8")
    toc_path.write_text(_toc(), encoding="utf-8")
    ane_path.write_text(_ane_intervals(), encoding="utf-8")

    exit_code = coreml_trace_evidence_cli.main(
        [
            "--resource-report",
            str(report_path),
            "--toc",
            str(toc_path),
            "--ane-intervals",
            str(ane_path),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 0
    assert json.loads(captured.out)["artifact"]["model_sha256"] == "c" * 64
    assert captured.err == ""


def test_cli_emits_stable_safe_json(tmp_path, capsys) -> None:
    benchmark_path = tmp_path / "benchmark.json"
    toc_path = tmp_path / "toc.xml"
    ane_path = tmp_path / "ane.xml"
    benchmark_path.write_text(json.dumps(_benchmark()), encoding="utf-8")
    toc_path.write_text(_toc(), encoding="utf-8")
    ane_path.write_text(_ane_intervals(), encoding="utf-8")

    exit_code = coreml_trace_evidence_cli.main(
        [
            "--benchmark",
            str(benchmark_path),
            "--toc",
            str(toc_path),
            "--ane-intervals",
            str(ane_path),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 0
    assert json.loads(captured.out)["actual_device_allocation_verified"] is True
    assert captured.err == ""


def test_cli_fails_closed_without_exposing_input_paths(tmp_path, capsys) -> None:
    secret_path = tmp_path / "private-hostname-toc.xml"

    exit_code = coreml_trace_evidence_cli.main(
        [
            "--benchmark",
            str(tmp_path / "missing-benchmark.json"),
            "--toc",
            str(secret_path),
            "--ane-intervals",
            str(tmp_path / "missing-ane.xml"),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 3
    assert captured.out == ""
    assert captured.err == "coreml_trace_evidence_invalid\n"
    assert str(tmp_path) not in captured.err


def test_installed_cli_documents_required_evidence_inputs() -> None:
    result = subprocess.run(
        [sys.executable, "-m", "imageall_model_backend.coreml_trace_evidence_cli", "--help"],
        check=True,
        capture_output=True,
        text=True,
    )

    assert "--benchmark" in result.stdout
    assert "--toc" in result.stdout
    assert "--ane-intervals" in result.stdout
