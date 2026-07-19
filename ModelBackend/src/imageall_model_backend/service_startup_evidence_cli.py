from __future__ import annotations

import argparse
import json
import tempfile
from pathlib import Path
from typing import Sequence

from imageall_model_backend.service_startup_evidence import (
    ServiceStartupProbeError,
    probe_service_startup,
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Launch and verify an ImageAll loopback model service"
    )
    parser.add_argument("--endpoint", required=True)
    parser.add_argument(
        "--expected-health",
        choices=("ready", "degraded"),
        required=True,
    )
    parser.add_argument(
        "--probe-kind",
        choices=("control", "embedding", "standard"),
        required=True,
    )
    parser.add_argument("--timeout-seconds", type=float, default=30.0)
    parser.add_argument("--poll-interval-seconds", type=float, default=0.1)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "service_command",
        nargs=argparse.REMAINDER,
        help="service argv after --",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    command = list(args.service_command)
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("a service command must follow --")
    try:
        report = probe_service_startup(
            command=command,
            endpoint=args.endpoint,
            expected_health_status=args.expected_health,
            probe_kind=args.probe_kind,
            timeout_seconds=args.timeout_seconds,
            poll_interval_seconds=args.poll_interval_seconds,
        )
    except ServiceStartupProbeError as error:
        parser.error(str(error))
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output is None:
        print(rendered, end="")
    else:
        _write_atomically(args.output, rendered)
    return 0 if report["overall_passed"] else 1


def _write_atomically(output: Path, rendered: str) -> None:
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        prefix=f".{output.name}-",
        dir=output.parent,
        delete=False,
    ) as handle:
        temporary = Path(handle.name)
        handle.write(rendered)
    try:
        temporary.replace(output)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    raise SystemExit(main())
