from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence

from imageall_model_backend.coreml_trace_evidence import (
    CoreMLTraceEvidenceError,
    verify_coreml_trace_evidence,
    verify_coreml_resource_trace_evidence,
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Verify sanitized Core ML Instruments runtime evidence"
    )
    report_group = parser.add_mutually_exclusive_group(required=True)
    report_group.add_argument("--benchmark", type=Path)
    report_group.add_argument("--resource-report", type=Path)
    parser.add_argument("--toc", type=Path, required=True)
    parser.add_argument("--ane-intervals", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        toc_xml = args.toc.read_text(encoding="utf-8")
        ane_intervals_xml = args.ane_intervals.read_text(encoding="utf-8")
        if args.benchmark is not None:
            evidence = verify_coreml_trace_evidence(
                benchmark=json.loads(args.benchmark.read_text(encoding="utf-8")),
                toc_xml=toc_xml,
                ane_intervals_xml=ane_intervals_xml,
            )
        else:
            evidence = verify_coreml_resource_trace_evidence(
                resource_report=json.loads(
                    args.resource_report.read_text(encoding="utf-8")
                ),
                toc_xml=toc_xml,
                ane_intervals_xml=ane_intervals_xml,
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
