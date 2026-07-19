from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence

from imageall_model_backend.coreml_install import (
    install_compiled_coreml_artifact,
)
from imageall_model_backend.dinov2 import DinoV2SmallProvider


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Atomically install a verified compiled Core ML bundle"
    )
    parser.add_argument("--source-bundle", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        result = install_compiled_coreml_artifact(
            source_bundle=args.source_bundle,
            output_dir=args.output,
            expected_encoder_identity=DinoV2SmallProvider.identity,
        )
    except Exception:
        print("coreml_install_invalid", file=sys.stderr)
        return 3
    print(
        json.dumps(
            {
                "model_sha256": result.model_sha256,
                "schema_revision": 2,
                "source_model_sha256": result.source_model_sha256,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
