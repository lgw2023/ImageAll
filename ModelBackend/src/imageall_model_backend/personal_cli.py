from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence

from imageall_model_backend.personal_training import (
    load_personal_training_input,
    train_personal_linear_head,
)
from imageall_model_backend.training import LinearHeadTrainingConfig


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Train a catalog-scoped ImageAll personal tag bundle"
    )
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--bundle-revision", required=True)
    parser.add_argument("--epochs", type=int, default=100)
    parser.add_argument("--learning-rate", type=float, default=0.01)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        training_input = load_personal_training_input(args.input)
        result = train_personal_linear_head(
            training_input=training_input,
            output_dir=args.output,
            bundle_id=args.bundle_id,
            bundle_revision=args.bundle_revision,
            config=LinearHeadTrainingConfig(
                epochs=args.epochs,
                learning_rate=args.learning_rate,
            ),
        )
    except (KeyError, OSError, ValueError) as error:
        print(f"personal_training_failed: {error}", file=sys.stderr)
        return 2
    print(
        json.dumps(
            {
                "bundle_path": str(result.bundle_path),
                "bundle_id": args.bundle_id,
                "bundle_revision": args.bundle_revision,
                "catalog_scope_id": training_input.catalog_scope_id,
                "device": result.device,
                "final_loss": result.final_loss,
            },
            sort_keys=True,
        )
    )
    return 0
