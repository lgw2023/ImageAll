from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence

from imageall_model_backend.standard_admission import (
    StandardAdmissionReportError,
    evaluate_standard_admission,
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Verify an ImageAll standard model admission report"
    )
    parser.add_argument("--report", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        payload = json.loads(args.report.read_text(encoding="utf-8"))
        decision = evaluate_standard_admission(payload)
    except (
        json.JSONDecodeError,
        KeyError,
        OSError,
        StandardAdmissionReportError,
        TypeError,
        ValueError,
    ):
        print("standard_admission_report_invalid", file=sys.stderr)
        return 3
    print(
        json.dumps(
            {
                "reason_codes": decision.reason_codes,
                "schema_revision": 1,
                "status": decision.status,
            },
            sort_keys=True,
        )
    )
    return decision.exit_code
