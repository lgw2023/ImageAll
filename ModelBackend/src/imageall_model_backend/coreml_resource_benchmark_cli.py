from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence

from imageall_model_backend.coreml_resource_benchmark import (
    benchmark_coreml_runtime,
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Benchmark a verified Core ML artifact without source weights"
    )
    parser.add_argument("--coreml-bundle", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        report = benchmark_coreml_runtime(args.coreml_bundle)
    except Exception:
        print("coreml_resource_benchmark_invalid", file=sys.stderr)
        return 3
    print(json.dumps(report, sort_keys=True))
    return 0 if report["overall_passed"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
