from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence

from imageall_model_backend.coreml_trace_evidence import (
    CoreMLTraceEvidenceError,
    verify_coreml_trace_evidence,
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Verify sanitized Core ML Instruments runtime evidence"
    )
    parser.add_argument("--benchmark", type=Path, required=True)
    parser.add_argument("--toc", type=Path, required=True)
    parser.add_argument("--ane-intervals", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        evidence = verify_coreml_trace_evidence(
            benchmark=json.loads(args.benchmark.read_text(encoding="utf-8")),
            toc_xml=args.toc.read_text(encoding="utf-8"),
            ane_intervals_xml=args.ane_intervals.read_text(encoding="utf-8"),
        )
    except (
        CoreMLTraceEvidenceError,
        json.JSONDecodeError,
        OSError,
        TypeError,
        ValueError,
    ):
        print("coreml_trace_evidence_invalid", file=sys.stderr)
        return 3
    print(json.dumps(evidence, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
