from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Sequence
from zipfile import BadZipFile

import uvicorn

from imageall_model_backend.personal_suggestions import PersonalSuggestionEngine
from imageall_model_backend.personal_runtime import PersonalModelRuntime
from imageall_model_backend.personal_training import load_personal_linear_head
from imageall_model_backend.providers import EmbeddingProvider
from imageall_model_backend.rgb_linear import RGBLinearSceneProvider
from imageall_model_backend.service import create_app
from imageall_model_backend.standard_pack import load_standard_pack
from imageall_model_backend.standard_suggestions import StandardSuggestionEngine


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Serve the optional ImageAll model backend")
    parser.add_argument(
        "--provider",
        choices=("none", "dinov2", "coreml"),
        default="none",
    )
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--model-cache", type=Path)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--coreml-bundle", type=Path)
    parser.add_argument("--personal-bundle", type=Path)
    parser.add_argument("--personal-store", type=Path)
    parser.add_argument("--standard-pack", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    if args.provider == "coreml" and args.coreml_bundle is None:
        parser.error("--provider coreml requires --coreml-bundle")
    if args.provider != "coreml" and args.coreml_bundle is not None:
        parser.error("--coreml-bundle requires --provider coreml")
    if args.personal_bundle is not None and args.personal_store is not None:
        parser.error("--personal-bundle and --personal-store are mutually exclusive")
    provider: EmbeddingProvider | None = None
    if args.provider == "dinov2":
        from imageall_model_backend.dinov2 import DinoV2SmallProvider

        provider = DinoV2SmallProvider(
            cache_dir=args.model_cache,
            local_files_only=args.offline,
        )
    if args.provider == "coreml":
        from imageall_model_backend.dinov2 import CoreMLDinoV2SmallProvider

        try:
            provider = CoreMLDinoV2SmallProvider(
                artifact_path=args.coreml_bundle,
                cache_dir=args.model_cache,
                local_files_only=args.offline,
            )
        except (OSError, RuntimeError, ValueError) as error:
            parser.error(f"Core ML provider could not be loaded: {error}")
    personal_suggestion_engine: PersonalSuggestionEngine | None = None
    if args.personal_bundle is not None:
        if provider is None:
            parser.error(
                "--personal-bundle requires --provider dinov2 or coreml"
            )
        try:
            manifest = json.loads(
                (args.personal_bundle / "manifest.json").read_text(
                    encoding="utf-8"
                )
            )
            bundle = load_personal_linear_head(
                args.personal_bundle,
                expected_catalog_scope_id=manifest["catalog_scope_id"],
                expected_bundle_id=manifest["bundle_id"],
                expected_bundle_revision=manifest["bundle_revision"],
                expected_encoder_identity=provider.identity,
                expected_label_vocabulary_revision=manifest[
                    "label_vocabulary_revision"
                ],
            )
            personal_suggestion_engine = PersonalSuggestionEngine(
                provider,
                bundle,
            )
        except (BadZipFile, KeyError, OSError, TypeError, ValueError) as error:
            parser.error(f"Personal bundle could not be loaded: {error}")
    personal_model_runtime: PersonalModelRuntime | None = None
    if args.personal_store is not None:
        if provider is None:
            parser.error(
                "--personal-store requires --provider dinov2 or coreml"
            )
        try:
            personal_model_runtime = PersonalModelRuntime(
                provider=provider,
                store_root=args.personal_store,
            )
        except (BadZipFile, KeyError, OSError, TypeError, ValueError) as error:
            parser.error(f"Personal store could not be loaded: {error}")
    standard_suggestion_engine: StandardSuggestionEngine | None = None
    if args.standard_pack is not None:
        pack = load_standard_pack(args.standard_pack)
        if pack.provider_identity.provider != "rgb-linear":
            parser.error("standard pack provider is not supported by this build")
        standard_provider = RGBLinearSceneProvider.from_pack(pack)
        standard_suggestion_engine = StandardSuggestionEngine(
            pack,
            standard_provider,
        )
    uvicorn.run(
        create_app(
            provider=provider,
            standard_suggestion_engine=standard_suggestion_engine,
            personal_suggestion_engine=personal_suggestion_engine,
            personal_model_runtime=personal_model_runtime,
        ),
        host="127.0.0.1",
        port=args.port,
    )
    return 0
