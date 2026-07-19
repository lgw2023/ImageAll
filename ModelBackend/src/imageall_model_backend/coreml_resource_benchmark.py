from __future__ import annotations

import ctypes
import math
import sys
import threading
import time
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import numpy as np

from imageall_model_backend.coreml_export import load_coreml_artifact
from imageall_model_backend.dinov2 import (
    DINO_V2_SMALL_INPUT_SHAPE,
    DinoV2SmallProvider,
)


MIB = 1024 * 1024
MAXIMUM_ARTIFACT_BYTES = 80 * MIB
MAXIMUM_COLD_LOAD_SECONDS = 2.0
MAXIMUM_MEDIAN_MILLISECONDS = 50.0
MAXIMUM_P95_MILLISECONDS = 100.0
MAXIMUM_PEAK_RSS_INCREMENT_BYTES = 350 * MIB
THERMAL_STATES = ("nominal", "fair", "serious", "critical")


class CoreMLResourceBenchmarkError(ValueError):
    pass


@dataclass(frozen=True)
class ProcessMetrics:
    resident_size_bytes: int
    resident_size_max_bytes: int
    thermal_state: str


def benchmark_coreml_runtime(
    bundle_path: Path,
    *,
    warmup_iterations: int = 20,
    measured_iterations: int = 1000,
) -> dict[str, object]:
    if warmup_iterations < 0 or measured_iterations < 1:
        raise CoreMLResourceBenchmarkError("invalid iteration count")
    bundle_path = Path(bundle_path)
    artifact_bytes = _artifact_size_bytes(bundle_path)
    inputs = _generated_inputs()
    sampler = _RuntimeSampler()
    sampler.start()
    try:
        load_start = time.perf_counter()
        artifact = _load_all_artifact(bundle_path)
        cold_load_seconds = time.perf_counter() - load_start
        sampler.capture()
        if (
            artifact.encoder_identity != DinoV2SmallProvider.identity
            or artifact.input_shape != DINO_V2_SMALL_INPUT_SHAPE
            or artifact.output_shape != (1, 384)
        ):
            raise CoreMLResourceBenchmarkError("unexpected Core ML artifact")

        for iteration in range(warmup_iterations):
            artifact.predict(inputs[iteration % len(inputs)])
            sampler.capture()

        durations: list[float] = []
        failure_count = 0
        nonfinite_count = 0
        for iteration in range(measured_iterations):
            selected_input = inputs[iteration % len(inputs)]
            start = time.perf_counter()
            try:
                output = np.asarray(artifact.predict(selected_input))
            except Exception:
                failure_count += 1
            else:
                durations.append((time.perf_counter() - start) * 1000.0)
                if output.shape != artifact.output_shape or not np.isfinite(output).all():
                    nonfinite_count += 1
            sampler.capture()
    finally:
        sampler.stop()

    median_milliseconds = _percentile(durations, 50)
    p95_milliseconds = _percentile(durations, 95)
    resources = {
        "artifact_bytes": artifact_bytes,
        **sampler.summary(),
    }
    stability = {
        "inference_failure_count": failure_count,
        "nonfinite_output_count": nonfinite_count,
        "sequential_inference_count": measured_iterations,
    }
    performance = {
        "cold_load_seconds": cold_load_seconds,
        "measured_iterations": measured_iterations,
        "median_milliseconds": median_milliseconds,
        "p95_milliseconds": p95_milliseconds,
        "warmup_iterations": warmup_iterations,
    }
    return {
        "acceptance_thresholds": {
            "maximum_artifact_bytes": MAXIMUM_ARTIFACT_BYTES,
            "maximum_cold_load_seconds": MAXIMUM_COLD_LOAD_SECONDS,
            "maximum_median_milliseconds": MAXIMUM_MEDIAN_MILLISECONDS,
            "maximum_p95_milliseconds": MAXIMUM_P95_MILLISECONDS,
            "maximum_peak_rss_increment_bytes": (
                MAXIMUM_PEAK_RSS_INCREMENT_BYTES
            ),
            "maximum_thermal_state": "fair",
            "minimum_sequential_inference_count": 1000,
        },
        "artifact": {
            "encoder": {
                "element_count": artifact.encoder_identity.element_count,
                "model_id": artifact.encoder_identity.model_id,
                "model_revision": artifact.encoder_identity.model_revision,
                "preprocessing_revision": (
                    artifact.encoder_identity.preprocessing_revision
                ),
                "provider": artifact.encoder_identity.provider,
            },
            "model_sha256": artifact.model_sha256,
        },
        "compute_units": "ALL",
        "input_count": len(inputs),
        "input_generation_revision": "imageall-coreml-synthetic-tensor-v1",
        "overall_passed": _passes_gates(
            performance=performance,
            resources=resources,
            stability=stability,
        ),
        "performance": performance,
        "resources": resources,
        "schema_revision": 1,
        "stability": stability,
    }


def _passes_gates(
    *,
    performance: dict[str, object],
    resources: dict[str, object],
    stability: dict[str, int],
) -> bool:
    median = performance["median_milliseconds"]
    p95 = performance["p95_milliseconds"]
    return bool(
        resources["artifact_bytes"] <= MAXIMUM_ARTIFACT_BYTES
        and performance["cold_load_seconds"] <= MAXIMUM_COLD_LOAD_SECONDS
        and median is not None
        and median <= MAXIMUM_MEDIAN_MILLISECONDS
        and p95 is not None
        and p95 <= MAXIMUM_P95_MILLISECONDS
        and resources["peak_rss_increment_bytes"]
        <= MAXIMUM_PEAK_RSS_INCREMENT_BYTES
        and THERMAL_STATES.index(resources["thermal_state_max"])
        <= THERMAL_STATES.index("fair")
        and stability["sequential_inference_count"] >= 1000
        and stability["inference_failure_count"] == 0
        and stability["nonfinite_output_count"] == 0
    )


def _generated_inputs() -> tuple[np.ndarray, ...]:
    element_count = math.prod(DINO_V2_SMALL_INPUT_SHAPE)
    base = np.arange(element_count, dtype=np.uint32).reshape(
        DINO_V2_SMALL_INPUT_SHAPE
    )
    return tuple(
        (((base + index * 37) % 1021) / 510.0 - 1.0).astype(np.float32)
        for index in range(8)
    )


def _load_all_artifact(bundle_path: Path):
    from imageall_model_backend.coreml_export import _coremltools

    return load_coreml_artifact(
        bundle_path,
        expected_encoder_identity=DinoV2SmallProvider.identity,
        compute_units=_coremltools().ComputeUnit.ALL,
    )


def _artifact_size_bytes(bundle_path: Path) -> int:
    if not bundle_path.is_dir() or bundle_path.is_symlink():
        raise CoreMLResourceBenchmarkError("Core ML bundle is missing or unsafe")
    total = 0
    for path in bundle_path.rglob("*"):
        if path.is_symlink():
            raise CoreMLResourceBenchmarkError("Core ML bundle contains a symlink")
        if path.is_file():
            total += path.stat().st_size
    return total


def _percentile(values: list[float], percentile: int) -> float | None:
    if not values:
        return None
    return float(np.percentile(values, percentile))


class _RuntimeSampler:
    def __init__(self) -> None:
        self.baseline = _process_metrics()
        self._samples = [self.baseline]
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._error: Exception | None = None
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def capture(self) -> None:
        sample = _process_metrics()
        with self._lock:
            self._samples.append(sample)

    def stop(self) -> None:
        self._stop.set()
        self._thread.join()
        self.capture()

    def summary(self) -> dict[str, object]:
        if self._error is not None:
            raise CoreMLResourceBenchmarkError("resource sampling failed") from self._error
        with self._lock:
            samples = tuple(self._samples)
        peak_rss = max(sample.resident_size_bytes for sample in samples)
        peak_rss_increment = max(
            peak_rss - self.baseline.resident_size_bytes,
            max(sample.resident_size_max_bytes for sample in samples)
            - self.baseline.resident_size_max_bytes,
            0,
        )
        thermal_states = [sample.thermal_state for sample in samples]
        return {
            "baseline_rss_bytes": self.baseline.resident_size_bytes,
            "peak_rss_bytes": peak_rss,
            "peak_rss_increment_bytes": peak_rss_increment,
            "sample_count": len(samples),
            "thermal_state_end": thermal_states[-1],
            "thermal_state_max": max(
                thermal_states, key=THERMAL_STATES.index
            ),
            "thermal_state_start": thermal_states[0],
        }

    def _run(self) -> None:
        try:
            while not self._stop.wait(0.01):
                self.capture()
        except Exception as error:
            self._error = error
            self._stop.set()


def _process_metrics() -> ProcessMetrics:
    if sys.platform != "darwin":
        raise CoreMLResourceBenchmarkError("resource benchmark requires macOS")
    resident_size, resident_size_max = _mach_memory_sizes()
    thermal_raw = _thermal_state_raw()
    if thermal_raw not in range(len(THERMAL_STATES)):
        raise CoreMLResourceBenchmarkError("unknown thermal state")
    return ProcessMetrics(
        resident_size_bytes=resident_size,
        resident_size_max_bytes=resident_size_max,
        thermal_state=THERMAL_STATES[thermal_raw],
    )


class _TimeValue(ctypes.Structure):
    _fields_ = [("seconds", ctypes.c_int), ("microseconds", ctypes.c_int)]


class _MachTaskBasicInfo(ctypes.Structure):
    _fields_ = [
        ("virtual_size", ctypes.c_uint64),
        ("resident_size", ctypes.c_uint64),
        ("resident_size_max", ctypes.c_uint64),
        ("user_time", _TimeValue),
        ("system_time", _TimeValue),
        ("policy", ctypes.c_int),
        ("suspend_count", ctypes.c_int),
    ]


@lru_cache(maxsize=1)
def _system_library():
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    library.task_info.argtypes = [
        ctypes.c_uint,
        ctypes.c_int,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_uint32),
    ]
    library.task_info.restype = ctypes.c_int
    return library


def _mach_memory_sizes() -> tuple[int, int]:
    library = _system_library()
    info = _MachTaskBasicInfo()
    count = ctypes.c_uint32(
        ctypes.sizeof(info) // ctypes.sizeof(ctypes.c_uint32)
    )
    task = ctypes.c_uint.in_dll(library, "mach_task_self_").value
    if library.task_info(task, 20, ctypes.byref(info), ctypes.byref(count)) != 0:
        raise CoreMLResourceBenchmarkError("task_info failed")
    return int(info.resident_size), int(info.resident_size_max)


@lru_cache(maxsize=1)
def _objc_runtime():
    ctypes.CDLL("/System/Library/Frameworks/Foundation.framework/Foundation")
    runtime = ctypes.CDLL("/usr/lib/libobjc.A.dylib")
    runtime.objc_getClass.restype = ctypes.c_void_p
    runtime.objc_getClass.argtypes = [ctypes.c_char_p]
    runtime.sel_registerName.restype = ctypes.c_void_p
    runtime.sel_registerName.argtypes = [ctypes.c_char_p]
    message_address = ctypes.cast(
        runtime.objc_msgSend, ctypes.c_void_p
    ).value
    if message_address is None:
        raise CoreMLResourceBenchmarkError("objc_msgSend is unavailable")
    object_message = ctypes.CFUNCTYPE(
        ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p
    )(message_address)
    integer_message = ctypes.CFUNCTYPE(
        ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p
    )(message_address)
    return runtime, object_message, integer_message


def _thermal_state_raw() -> int:
    runtime, object_message, integer_message = _objc_runtime()
    process_info = object_message(
        runtime.objc_getClass(b"NSProcessInfo"),
        runtime.sel_registerName(b"processInfo"),
    )
    return int(
        integer_message(
            process_info, runtime.sel_registerName(b"thermalState")
        )
    )
