from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Sequence

import numpy as np
import torch
from PIL import Image

from imageall_model_backend.coreml_export import (
    benchmark_coreml_artifact,
    convert_embedding_model_to_coreml,
)
from imageall_model_backend.dinov2 import (
    DINO_V2_SMALL_INPUT_SHAPE,
    DINO_V2_SMALL_MODEL_ID,
    DinoV2SmallProvider,
    load_dinov2_small_embedding_model,
    load_dinov2_small_image_processor,
)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            f"Convert pinned {DINO_V2_SMALL_MODEL_ID} to a Core ML FP16 ML Program"
        )
    )
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model-cache", type=Path)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--benchmark-samples", type=int, default=3)
    parser.add_argument("--warmup-iterations", type=int, default=2)
    parser.add_argument("--measured-iterations", type=int, default=10)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    source_model = load_dinov2_small_embedding_model(
        cache_dir=args.model_cache,
        local_files_only=args.offline,
    )
    processor = load_dinov2_small_image_processor(
        cache_dir=args.model_cache,
        local_files_only=args.offline,
    )
    benchmark_inputs = _deterministic_benchmark_inputs(
        processor,
        args.benchmark_samples,
    )
    result = convert_embedding_model_to_coreml(
        model=source_model,
        encoder_identity=DinoV2SmallProvider.identity,
        example_input=benchmark_inputs[0],
        output_dir=args.output,
    )
    report = benchmark_coreml_artifact(
        bundle_path=result.bundle_path,
        expected_encoder_identity=DinoV2SmallProvider.identity,
        source_model=source_model,
        inputs=benchmark_inputs,
        warmup_iterations=args.warmup_iterations,
        measured_iterations=args.measured_iterations,
    )
    report["input_generation_revision"] = (
        "imageall-dinov2-synthetic-rgb-processor-v1"
    )
    report_path = result.bundle_path / "benchmark.json"
    report_path.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(report_path)
    return 0 if report["overall_passed"] else 2


def _deterministic_benchmark_inputs(
    processor,
    sample_count: int,
) -> tuple[torch.Tensor, ...]:
    if sample_count < 1:
        raise ValueError("benchmark sample count must be positive")
    y_coordinates, x_coordinates = np.indices((240, 320))
    return tuple(
        processor(
            images=Image.fromarray(
                np.stack(
                    (
                        (x_coordinates + index * 37) % 256,
                        (y_coordinates * 2 + index * 53) % 256,
                        ((x_coordinates + y_coordinates) * 3 + index * 71) % 256,
                    ),
                    axis=-1,
                ).astype(np.uint8),
                mode="RGB",
            ),
            return_tensors="pt",
        )["pixel_values"].to(dtype=torch.float32)
        for index in range(sample_count)
    )
