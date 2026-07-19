from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path
from typing import Sequence

from imageall_model_backend.standard_pack import load_standard_pack


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate an ImageAll standard model pack without activating it"
    )
    parser.add_argument("--pack", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        pack = load_standard_pack(args.pack)
    except (KeyError, OSError, TypeError, ValueError):
        print("standard_pack_validation_failed", file=sys.stderr)
        return 2
    print(
        json.dumps(
            {
                "valid": True,
                "standard_pack_id": pack.standard_pack_id,
                "standard_pack_revision": pack.standard_pack_revision,
                "provider": asdict(pack.provider_identity),
                "ontology_id": pack.ontology.ontology_id,
                "ontology_revision": pack.ontology.ontology_revision,
                "concept_count": len(pack.ontology.concept_ids),
                "mapping_revision": pack.mapping.mapping_revision,
                "policy_revision": pack.policy.policy_revision,
            },
            sort_keys=True,
        )
    )
    return 0
