from __future__ import annotations

from collections.abc import Callable
from typing import Any
from urllib.error import URLError

import pytest

from imageall_model_backend.service_startup_evidence import (
    ServiceStartupProbeError,
    probe_service_startup,
)


class FakeProcess:
    def __init__(self, *, exit_code: int | None = None) -> None:
        self.exit_code = exit_code
        self.terminate_count = 0
        self.kill_count = 0
        self.wait_count = 0

    def poll(self) -> int | None:
        return self.exit_code

    def terminate(self) -> None:
        self.terminate_count += 1
        self.exit_code = -15

    def kill(self) -> None:
        self.kill_count += 1
        self.exit_code = -9

    def wait(self, timeout: float | None = None) -> int:
        del timeout
        self.wait_count += 1
        assert self.exit_code is not None
        return self.exit_code


class AdvancingClock:
    def __init__(self) -> None:
        self.value = 0.0

    def monotonic(self) -> float:
        return self.value

    def sleep(self, seconds: float) -> None:
        self.value += seconds


def test_non_loopback_endpoint_is_rejected_before_process_start() -> None:
    starts: list[tuple[str, ...]] = []

    with pytest.raises(ServiceStartupProbeError, match="127.0.0.1"):
        probe_service_startup(
            command=["/private/tmp/imageall-model-backend"],
            endpoint="http://localhost:8765",
            expected_health_status="degraded",
            probe_kind="control",
            process_factory=lambda command: starts.append(tuple(command)),
        )

    assert starts == []


def test_invalid_port_is_reported_as_a_probe_configuration_error() -> None:
    with pytest.raises(ServiceStartupProbeError, match="127.0.0.1"):
        probe_service_startup(
            command=["imageall-model-backend"],
            endpoint="http://127.0.0.1:not-a-port",
            expected_health_status="degraded",
            probe_kind="control",
        )


def test_timing_must_be_finite_before_process_start() -> None:
    starts: list[tuple[str, ...]] = []

    with pytest.raises(ServiceStartupProbeError, match="timing"):
        probe_service_startup(
            command=["imageall-model-backend"],
            endpoint="http://127.0.0.1:18766",
            expected_health_status="degraded",
            probe_kind="control",
            timeout_seconds=float("nan"),
            process_factory=lambda command: starts.append(tuple(command)),
        )

    assert starts == []


def test_process_launch_failure_returns_sanitized_evidence() -> None:
    def fail_to_start(_command: tuple[str, ...]) -> FakeProcess:
        raise FileNotFoundError("/private/secret/backend was not found")

    report = probe_service_startup(
        command=["/private/secret/backend", "--private-argument"],
        endpoint="http://127.0.0.1:18766",
        expected_health_status="degraded",
        probe_kind="control",
        process_factory=fail_to_start,
    )

    assert report["overall_passed"] is False
    assert report["failure_code"] == "process_start_failed"
    assert report["shutdown"] == {
        "process_stopped": True,
        "forced_kill": False,
        "exit_status": None,
    }
    assert "/private" not in str(report)


def test_standard_probe_uses_generated_bytes_and_always_stops_child() -> None:
    process = FakeProcess()
    clock = AdvancingClock()
    requests: list[tuple[str, str, dict[str, Any] | None]] = []
    standard = {
        "status": "available",
        "standard_pack_id": "imageall-public-fixture",
        "standard_pack_revision": "pack-v1",
        "manifest_sha256": "a" * 64,
        "ontology_id": "imageall-public-fixture",
        "ontology_revision": "ontology-v1",
        "provider": {
            "provider": "rgb-linear",
            "model_id": "fixture",
            "model_revision": "model-v1",
            "preprocessing_revision": "rgb-v1",
        },
        "mapping_revision": "mapping-v1",
        "policy_revision": "policy-v1",
        "weights_sha256": "b" * 64,
    }
    health_attempts = 0

    def request_json(
        method: str,
        url: str,
        payload: dict[str, Any] | None,
    ) -> tuple[int, dict[str, Any]]:
        nonlocal health_attempts
        requests.append((method, url, payload))
        if url.endswith("/v1/health"):
            health_attempts += 1
            if health_attempts == 1:
                raise URLError("not listening yet")
            return 200, {
                "status": "ready",
                "service_version": "0.1.0",
                "provider": standard["provider"],
            }
        if url.endswith("/v1/capabilities"):
            return 200, {
                "service_version": "0.1.0",
                "standard": standard,
                "personal": {"status": "unavailable"},
            }
        assert payload is not None
        assert payload["target"] == {
            "track": "standard",
            "standard_pack_id": "imageall-public-fixture",
            "standard_pack_revision": "pack-v1",
        }
        assert isinstance(payload["image_base64"], str)
        assert payload["image_base64"]
        return 200, {
            "request_id": payload["request_id"],
            "suggestions": [],
        }

    report = probe_service_startup(
        command=["/private/tmp/imageall-model-backend", "--secret-path", "/private"],
        endpoint="http://127.0.0.1:18766",
        expected_health_status="ready",
        probe_kind="standard",
        timeout_seconds=2,
        poll_interval_seconds=0.1,
        process_factory=lambda _: process,
        request_json=request_json,
        monotonic=clock.monotonic,
        sleep=clock.sleep,
    )

    assert report["overall_passed"] is True
    assert report["target"] == {
        "executable_name": "imageall-model-backend",
        "endpoint": "http://127.0.0.1:18766",
        "probe_kind": "standard",
        "expected_health_status": "ready",
    }
    assert "/private" not in str(report)
    assert process.terminate_count == 1
    assert process.kill_count == 0
    assert process.wait_count == 1
    assert requests[-1][0] == "POST"


def test_timeout_fails_closed_and_terminates_child() -> None:
    process = FakeProcess()
    clock = AdvancingClock()

    report = probe_service_startup(
        command=["imageall-model-backend"],
        endpoint="http://127.0.0.1:18767",
        expected_health_status="ready",
        probe_kind="embedding",
        timeout_seconds=0.2,
        poll_interval_seconds=0.1,
        process_factory=lambda _: process,
        request_json=lambda _method, _url, _payload: (_ for _ in ()).throw(
            URLError("refused")
        ),
        monotonic=clock.monotonic,
        sleep=clock.sleep,
    )

    assert report["overall_passed"] is False
    assert report["failure_code"] == "startup_timeout"
    assert report["shutdown"]["process_stopped"] is True
    assert process.terminate_count == 1


def test_malformed_health_response_fails_immediately_instead_of_timing_out() -> None:
    process = FakeProcess()
    clock = AdvancingClock()

    report = probe_service_startup(
        command=["imageall-model-backend"],
        endpoint="http://127.0.0.1:18767",
        expected_health_status="degraded",
        probe_kind="control",
        timeout_seconds=1,
        poll_interval_seconds=0.1,
        process_factory=lambda _: process,
        request_json=lambda _method, _url, _payload: (_ for _ in ()).throw(
            ValueError("malformed json")
        ),
        monotonic=clock.monotonic,
        sleep=clock.sleep,
    )

    assert report["failure_code"] == "probe_request_failed"
    assert clock.value == 0
    assert process.terminate_count == 1


def test_early_exit_is_reported_without_retrying_http() -> None:
    process = FakeProcess(exit_code=64)
    request_count = 0

    def request_json(
        _method: str,
        _url: str,
        _payload: dict[str, Any] | None,
    ) -> tuple[int, dict[str, Any]]:
        nonlocal request_count
        request_count += 1
        raise AssertionError("HTTP must not run after an early process exit")

    report = probe_service_startup(
        command=["imageall-model-backend"],
        endpoint="http://127.0.0.1:18768",
        expected_health_status="degraded",
        probe_kind="control",
        process_factory=lambda _: process,
        request_json=request_json,
    )

    assert report["overall_passed"] is False
    assert report["failure_code"] == "process_exited_before_ready"
    assert report["shutdown"] == {
        "process_stopped": True,
        "forced_kill": False,
        "exit_status": 64,
    }
    assert request_count == 0


def test_available_personal_capability_must_include_complete_identity() -> None:
    process = FakeProcess()

    def request_json(
        _method: str,
        url: str,
        _payload: dict[str, Any] | None,
    ) -> tuple[int, dict[str, Any]]:
        if url.endswith("/v1/health"):
            return 200, {
                "status": "ready",
                "service_version": "0.1.0",
                "provider": {
                    "provider": "dinov2",
                    "model_id": "facebook/dinov2-small",
                    "model_revision": "model-v1",
                    "preprocessing_revision": "pre-v1",
                    "element_count": 384,
                },
            }
        return 200, {
            "service_version": "0.1.0",
            "standard": {"status": "unavailable"},
            "personal": {"status": "available"},
        }

    report = probe_service_startup(
        command=["imageall-model-backend"],
        endpoint="http://127.0.0.1:18771",
        expected_health_status="ready",
        probe_kind="control",
        process_factory=lambda _: process,
        request_json=request_json,
    )

    assert report["overall_passed"] is False
    assert report["failure_code"] == "invalid_personal_capability"
    assert process.terminate_count == 1
