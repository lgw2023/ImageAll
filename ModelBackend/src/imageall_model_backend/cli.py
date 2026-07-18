from __future__ import annotations

import argparse
from pathlib import Path
from typing import Sequence

import uvicorn

from imageall_model_backend.providers import EmbeddingProvider
from imageall_model_backend.service import create_app


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Serve the optional ImageAll model backend")
    parser.add_argument("--provider", choices=("none", "dinov2"), default="none")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--model-cache", type=Path)
    parser.add_argument("--offline", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    provider: EmbeddingProvider | None = None
    if args.provider == "dinov2":
        from imageall_model_backend.dinov2 import DinoV2SmallProvider

        provider = DinoV2SmallProvider(
            cache_dir=args.model_cache,
            local_files_only=args.offline,
        )
    uvicorn.run(create_app(provider), host="127.0.0.1", port=args.port)
    return 0
