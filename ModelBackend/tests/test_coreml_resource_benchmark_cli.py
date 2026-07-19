import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import pytest

from imageall_model_backend import coreml_resource_benchmark as benchmark_module
from imageall_model_backend import coreml_resource_benchmark_cli
from imageall_model_backend.coreml_resource_benchmark import (
    ProcessMetrics,
    benchmark_coreml_runtime,
)
from imageall_model_backend.dinov2 import DinoV2SmallProvider


MIB = 1024 * 1024


class _FakeArtifact:
    encoder_identity = DinoV2SmallProvider.identity
    input_shape = (1, 3, 224, 224)
    output_shape = (1, 384)
    model_sha256 = "a" * 64

    def __init__(self, *, nonfinite: bool = False) -> None:
        self._nonfinite = nonfinite

    def predict(self, value) -> np.ndarray:
        assert np.asarray(value).shape == self.input_shape
        result = np.zeros(self.output_shape, dtype=np.float32)
        if self._nonfinite:
            result[0, 0] = np.nan
        return result


class _FakeSampler:
    def __init__(self, *, thermal_state: str = "fair") -> None:
        self.baseline = ProcessMetrics(
            resident_size_bytes=100 * MIB,
            resident_size_max_bytes=100 * MIB,
            thermal_state="nominal",
        )
        self._thermal_state = thermal_state

    def start(self) -> None:
        pass

    def capture(self) -> None:
        pass

    def stop(self) -> None:
        pass

    def summary(self) -> dict[str, object]:
        return {
            "baseline_rss_bytes": 100 * MIB,
            "peak_rss_bytes": 200 * MIB,
            "peak_rss_increment_bytes": 100 * MIB,
            "sample_count": 1002,
            "thermal_state_start": "nominal",
            "thermal_state_max": self._thermal_state,
            "thermal_state_end": self._thermal_state,
        }


def _install_fakes(monkeypatch, *, thermal_state="fair", nonfinite=False) -> None:
    monkeypatch.setattr(
        benchmark_module,
        "_load_all_artifact",
        lambda _: _FakeArtifact(nonfinite=nonfinite),
    )
    monkeypatch.setattr(
        benchmark_module,
        "_artifact_size_bytes",
        lambda _: 41 * MIB,
    )
    monkeypatch.setattr(
        benchmark_module,
        "_RuntimeSampler",
        lambda: _FakeSampler(thermal_state=thermal_state),
    )
    tick = iter(index / 1000 for index in range(4004))
    monkeypatch.setattr(benchmark_module.time, "perf_counter", lambda: next(tick))


def test_runtime_resource_benchmark_passes_fixed_gates(monkeypatch) -> None:
    _install_fakes(monkeypatch)

    report = benchmark_coreml_runtime(Path("/synthetic/coreml-bundle"))

    assert report["overall_passed"] is True
    assert report["artifact"] == {
        "encoder": {
            "element_count": 384,
            "model_id": "facebook/dinov2-small",
            "model_revision": "ed25f3a31f01632728cabb09d1542f84ab7b0056",
            "preprocessing_revision": "dinov2-hf-autoimageprocessor-v1",
            "provider": "dinov2",
        },
        "model_sha256": "a" * 64,
    }
    assert report["input_generation_revision"] == (
        "imageall-coreml-synthetic-tensor-v1"
    )
    assert report["input_count"] == 8
    assert report["compute_units"] == "ALL"
    assert report["performance"] == pytest.approx({
        "cold_load_seconds": 0.001,
        "measured_iterations": 1000,
        "median_milliseconds": 1.0,
        "p95_milliseconds": 1.0,
        "warmup_iterations": 20,
    })
    assert report["resources"] == {
        "artifact_bytes": 41 * MIB,
        "baseline_rss_bytes": 100 * MIB,
        "peak_rss_bytes": 200 * MIB,
        "peak_rss_increment_bytes": 100 * MIB,
        "sample_count": 1002,
        "thermal_state_end": "fair",
        "thermal_state_max": "fair",
        "thermal_state_start": "nominal",
    }
    assert report["stability"] == {
        "inference_failure_count": 0,
        "nonfinite_output_count": 0,
        "sequential_inference_count": 1000,
    }


def test_serious_thermal_state_fails_the_resource_gate(monkeypatch) -> None:
    _install_fakes(monkeypatch, thermal_state="serious")

    report = benchmark_coreml_runtime(Path("/synthetic/coreml-bundle"))

    assert report["overall_passed"] is False
    assert report["resources"]["thermal_state_max"] == "serious"


def test_nonfinite_output_fails_the_stability_gate(monkeypatch) -> None:
    _install_fakes(monkeypatch, nonfinite=True)

    report = benchmark_coreml_runtime(Path("/synthetic/coreml-bundle"))

    assert report["overall_passed"] is False
    assert report["stability"] == {
        "inference_failure_count": 0,
        "nonfinite_output_count": 1000,
        "sequential_inference_count": 1000,
    }


@pytest.mark.skipif(sys.platform != "darwin", reason="macOS telemetry API")
def test_process_metrics_are_safe_under_concurrent_sampling() -> None:
    with ThreadPoolExecutor(max_workers=8) as pool:
        samples = tuple(pool.map(lambda _: benchmark_module._process_metrics(), range(200)))

    assert all(sample.resident_size_bytes > 0 for sample in samples)
    assert all(sample.thermal_state in benchmark_module.THERMAL_STATES for sample in samples)


def test_cli_returns_two_for_a_measured_gate_failure(
    tmp_path, monkeypatch, capsys
) -> None:
    monkeypatch.setattr(
        coreml_resource_benchmark_cli,
        "benchmark_coreml_runtime",
        lambda _: {"overall_passed": False, "schema_revision": 1},
    )

    exit_code = coreml_resource_benchmark_cli.main(
        ["--coreml-bundle", str(tmp_path / "bundle")]
    )

    captured = capsys.readouterr()
    assert exit_code == 2
    assert json.loads(captured.out) == {
        "overall_passed": False,
        "schema_revision": 1,
    }
    assert captured.err == ""


def test_cli_fails_closed_without_exposing_bundle_path(tmp_path, capsys) -> None:
    private_path = tmp_path / "private-host-bundle"

    exit_code = coreml_resource_benchmark_cli.main(
        ["--coreml-bundle", str(private_path)]
    )

    captured = capsys.readouterr()
    assert exit_code == 3
    assert captured.out == ""
    assert captured.err == "coreml_resource_benchmark_invalid\n"
    assert str(private_path) not in captured.err


def test_module_cli_documents_the_runtime_only_input() -> None:
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "imageall_model_backend.coreml_resource_benchmark_cli",
            "--help",
        ],
        check=True,
        capture_output=True,
        text=True,
    )

    assert "--coreml-bundle" in result.stdout
    assert "--model-cache" not in result.stdout
