from __future__ import annotations

import base64
import io
import json
import math
import subprocess
import time
import uuid
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any, Protocol
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

from PIL import Image


class ServiceStartupProbeError(ValueError):
    pass


class ServiceProcess(Protocol):
    def poll(self) -> int | None: ...

    def terminate(self) -> None: ...

    def kill(self) -> None: ...

    def wait(self, timeout: float | None = None) -> int: ...


JSONRequest = Callable[
    [str, str, dict[str, Any] | None],
    tuple[int, dict[str, Any]],
]


def probe_service_startup(
    *,
    command: Sequence[str],
    endpoint: str,
    expected_health_status: str,
    probe_kind: str,
    timeout_seconds: float = 30.0,
    poll_interval_seconds: float = 0.1,
    process_factory: Callable[[Sequence[str]], ServiceProcess] | None = None,
    request_json: JSONRequest | None = None,
    monotonic: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
) -> dict[str, Any]:
    normalized_endpoint = _validated_endpoint(endpoint)
    normalized_command = tuple(command)
    if not normalized_command or not normalized_command[0]:
        raise ServiceStartupProbeError("service command must not be empty")
    if expected_health_status not in {"ready", "degraded"}:
        raise ServiceStartupProbeError("expected health must be ready or degraded")
    if probe_kind not in {"control", "embedding", "standard"}:
        raise ServiceStartupProbeError(
            "probe kind must be control, embedding, or standard"
        )
    if (
        not math.isfinite(timeout_seconds)
        or not math.isfinite(poll_interval_seconds)
        or timeout_seconds <= 0
        or poll_interval_seconds <= 0
    ):
        raise ServiceStartupProbeError("probe timing values must be positive")
    if probe_kind == "embedding" and expected_health_status != "ready":
        raise ServiceStartupProbeError("embedding probe requires ready health")

    factory = process_factory or _start_process
    requester = request_json or _request_json
    started_at = monotonic()
    report: dict[str, Any] = {
        "schema_revision": 1,
        "evidence_kind": "loopback_service_startup",
        "target": {
            "executable_name": Path(normalized_command[0]).name,
            "endpoint": normalized_endpoint,
            "probe_kind": probe_kind,
            "expected_health_status": expected_health_status,
        },
        "overall_passed": False,
    }
    try:
        process = factory(normalized_command)
    except OSError:
        report["failure_code"] = "process_start_failed"
        report["shutdown"] = {
            "process_stopped": True,
            "forced_kill": False,
            "exit_status": None,
        }
        return report

    try:
        health = _wait_for_health(
            process=process,
            endpoint=normalized_endpoint,
            expected_status=expected_health_status,
            timeout_seconds=timeout_seconds,
            poll_interval_seconds=poll_interval_seconds,
            requester=requester,
            started_at=started_at,
            monotonic=monotonic,
            sleep=sleep,
        )
        report["startup"] = {
            "health_observed": True,
            "startup_seconds": max(monotonic() - started_at, 0.0),
            "service_version": health["service_version"],
            "health_status": health["status"],
            "provider": health["provider"],
        }

        status, capabilities = requester(
            "GET", f"{normalized_endpoint}/v1/capabilities", None
        )
        _validate_capabilities(
            status,
            capabilities,
            service_version=health["service_version"],
        )
        report["capabilities"] = {
            "standard_status": capabilities["standard"]["status"],
            "personal_status": capabilities["personal"]["status"],
        }

        if probe_kind == "embedding":
            _probe_embedding(
                requester=requester,
                endpoint=normalized_endpoint,
                provider=health["provider"],
            )
        elif probe_kind == "standard":
            _probe_standard(
                requester=requester,
                endpoint=normalized_endpoint,
                capability=capabilities["standard"],
            )
        report["request_probe"] = {"kind": probe_kind, "passed": True}
        report["overall_passed"] = True
    except _ProbeFailure as failure:
        report["failure_code"] = failure.code
    except Exception:
        report["failure_code"] = "probe_request_failed"
    finally:
        report["shutdown"] = _stop_process(process)
        if not report["shutdown"]["process_stopped"]:
            report["overall_passed"] = False
            report["failure_code"] = "process_stop_failed"
    return report


class _ProbeFailure(Exception):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def _validated_endpoint(endpoint: str) -> str:
    parsed = urlsplit(endpoint)
    try:
        port = parsed.port
    except ValueError:
        port = None
    if (
        parsed.scheme != "http"
        or parsed.hostname != "127.0.0.1"
        or port is None
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
    ):
        raise ServiceStartupProbeError(
            "endpoint must be exactly http://127.0.0.1:<port>"
        )
    if port <= 0 or port > 65535:
        raise ServiceStartupProbeError("endpoint port is out of range")
    return f"http://127.0.0.1:{port}"


def _start_process(command: Sequence[str]) -> ServiceProcess:
    return subprocess.Popen(
        tuple(command),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
    )


def _request_json(
    method: str,
    url: str,
    payload: dict[str, Any] | None,
) -> tuple[int, dict[str, Any]]:
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = Request(
        url,
        data=body,
        method=method,
        headers={"Content-Type": "application/json"},
    )
    with urlopen(request, timeout=2.0) as response:
        decoded = json.loads(response.read().decode("utf-8"))
        if not isinstance(decoded, dict):
            raise _ProbeFailure("invalid_json_response")
        return response.status, decoded


def _wait_for_health(
    *,
    process: ServiceProcess,
    endpoint: str,
    expected_status: str,
    timeout_seconds: float,
    poll_interval_seconds: float,
    requester: JSONRequest,
    started_at: float,
    monotonic: Callable[[], float],
    sleep: Callable[[float], None],
) -> dict[str, Any]:
    deadline = started_at + timeout_seconds
    while True:
        if process.poll() is not None:
            raise _ProbeFailure("process_exited_before_ready")
        try:
            status, health = requester("GET", f"{endpoint}/v1/health", None)
        except OSError:
            if monotonic() >= deadline:
                raise _ProbeFailure("startup_timeout") from None
            sleep(poll_interval_seconds)
            continue
        _validate_health(status, health, expected_status=expected_status)
        return health


def _validate_health(
    status: int,
    payload: dict[str, Any],
    *,
    expected_status: str,
) -> None:
    if status != 200 or set(payload) != {"status", "service_version", "provider"}:
        raise _ProbeFailure("invalid_health_contract")
    if payload["status"] != expected_status:
        raise _ProbeFailure("health_status_mismatch")
    if not isinstance(payload["service_version"], str) or not payload[
        "service_version"
    ]:
        raise _ProbeFailure("invalid_health_contract")
    if expected_status == "degraded":
        if payload["provider"] is not None:
            raise _ProbeFailure("invalid_health_contract")
    else:
        _validate_provider(payload["provider"])


def _validate_provider(provider: Any) -> None:
    if not isinstance(provider, dict):
        raise _ProbeFailure("invalid_provider_identity")
    required = {
        "provider",
        "model_id",
        "model_revision",
        "preprocessing_revision",
    }
    if not required.issubset(provider) or set(provider) - required - {"element_count"}:
        raise _ProbeFailure("invalid_provider_identity")
    if not all(isinstance(provider[key], str) and provider[key] for key in required):
        raise _ProbeFailure("invalid_provider_identity")
    if "element_count" in provider and (
        not isinstance(provider["element_count"], int)
        or isinstance(provider["element_count"], bool)
        or provider["element_count"] <= 0
    ):
        raise _ProbeFailure("invalid_provider_identity")


def _validate_capabilities(
    status: int,
    payload: dict[str, Any],
    *,
    service_version: str,
) -> None:
    if (
        status != 200
        or set(payload) != {"service_version", "standard", "personal"}
        or payload["service_version"] != service_version
    ):
        raise _ProbeFailure("invalid_capability_contract")
    for track in ("standard", "personal"):
        capability = payload[track]
        if not isinstance(capability, dict) or capability.get("status") not in {
            "available",
            "unavailable",
        }:
            raise _ProbeFailure("invalid_capability_contract")
        if capability["status"] == "unavailable" and capability != {
            "status": "unavailable"
        }:
            raise _ProbeFailure("invalid_capability_contract")
    if payload["standard"]["status"] == "available":
        _validate_standard_capability(payload["standard"])
    if payload["personal"]["status"] == "available":
        _validate_personal_capability(payload["personal"])


def _validate_standard_capability(capability: dict[str, Any]) -> None:
    required = {
        "status",
        "standard_pack_id",
        "standard_pack_revision",
        "manifest_sha256",
        "ontology_id",
        "ontology_revision",
        "provider",
        "mapping_revision",
        "policy_revision",
        "weights_sha256",
    }
    if set(capability) != required:
        raise _ProbeFailure("invalid_standard_capability")
    text_fields = required - {"status", "provider", "manifest_sha256", "weights_sha256"}
    if not all(
        isinstance(capability[key], str) and capability[key] for key in text_fields
    ):
        raise _ProbeFailure("invalid_standard_capability")
    for key in ("manifest_sha256", "weights_sha256"):
        value = capability[key]
        if (
            not isinstance(value, str)
            or len(value) != 64
            or any(character not in "0123456789abcdef" for character in value)
        ):
            raise _ProbeFailure("invalid_standard_capability")
    _validate_provider(capability["provider"])


def _validate_personal_capability(capability: dict[str, Any]) -> None:
    required = {
        "status",
        "catalog_scope_id",
        "bundle_id",
        "bundle_revision",
        "encoder",
        "label_vocabulary_revision",
        "weights_sha256",
        "policy_revision",
        "tag_ids",
    }
    if set(capability) != required:
        raise _ProbeFailure("invalid_personal_capability")
    text_fields = required - {"status", "encoder", "weights_sha256", "tag_ids"}
    if not all(
        isinstance(capability[key], str) and capability[key] for key in text_fields
    ):
        raise _ProbeFailure("invalid_personal_capability")
    weights_sha256 = capability["weights_sha256"]
    if (
        not isinstance(weights_sha256, str)
        or len(weights_sha256) != 64
        or any(character not in "0123456789abcdef" for character in weights_sha256)
    ):
        raise _ProbeFailure("invalid_personal_capability")
    tag_ids = capability["tag_ids"]
    if (
        not isinstance(tag_ids, list)
        or not tag_ids
        or not all(isinstance(tag_id, str) and tag_id for tag_id in tag_ids)
        or len(set(tag_ids)) != len(tag_ids)
    ):
        raise _ProbeFailure("invalid_personal_capability")
    try:
        _validate_provider(capability["encoder"])
    except _ProbeFailure:
        raise _ProbeFailure("invalid_personal_capability") from None


def _probe_embedding(
    *,
    requester: JSONRequest,
    endpoint: str,
    provider: dict[str, Any],
) -> None:
    expected_count = provider.get("element_count")
    if not isinstance(expected_count, int):
        raise _ProbeFailure("embedding_identity_missing")
    request_id = str(uuid.uuid4())
    status, payload = requester(
        "POST",
        f"{endpoint}/v1/embeddings",
        {"request_id": request_id, "image_base64": _generated_png_base64()},
    )
    identity_keys = (
        "provider",
        "model_id",
        "model_revision",
        "preprocessing_revision",
    )
    vector = payload.get("embedding")
    if (
        status != 200
        or payload.get("request_id") != request_id
        or payload.get("element_type") != "float32"
        or payload.get("element_count") != expected_count
        or any(payload.get(key) != provider[key] for key in identity_keys)
        or not isinstance(vector, list)
        or len(vector) != expected_count
        or any(
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(float(value))
            for value in vector
        )
    ):
        raise _ProbeFailure("embedding_probe_failed")


def _probe_standard(
    *,
    requester: JSONRequest,
    endpoint: str,
    capability: dict[str, Any],
) -> None:
    if capability.get("status") != "available":
        raise _ProbeFailure("standard_capability_unavailable")
    request_id = str(uuid.uuid4())
    status, payload = requester(
        "POST",
        f"{endpoint}/v1/suggestions",
        {
            "request_id": request_id,
            "image_base64": _generated_png_base64(),
            "target": {
                "track": "standard",
                "standard_pack_id": capability["standard_pack_id"],
                "standard_pack_revision": capability["standard_pack_revision"],
            },
        },
    )
    if (
        status != 200
        or set(payload) != {"request_id", "suggestions"}
        or payload["request_id"] != request_id
        or not isinstance(payload["suggestions"], list)
    ):
        raise _ProbeFailure("standard_probe_failed")


def _generated_png_base64() -> str:
    buffer = io.BytesIO()
    Image.new("RGB", (8, 8), color=(0, 0, 255)).save(buffer, format="PNG")
    return base64.b64encode(buffer.getvalue()).decode("ascii")


def _stop_process(process: ServiceProcess) -> dict[str, Any]:
    exit_status = process.poll()
    forced_kill = False
    if exit_status is None:
        try:
            process.terminate()
            exit_status = process.wait(timeout=5.0)
        except (OSError, subprocess.TimeoutExpired):
            forced_kill = True
            try:
                process.kill()
                exit_status = process.wait(timeout=5.0)
            except (OSError, subprocess.TimeoutExpired):
                exit_status = process.poll()
    return {
        "process_stopped": exit_status is not None,
        "forced_kill": forced_kill,
        "exit_status": exit_status,
    }
