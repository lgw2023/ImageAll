from __future__ import annotations

import json
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path

from imageall_model_backend.coreml_export import (
    COREML_COMPILED_ARTIFACT_SCHEMA_REVISION,
    COREML_COMPILED_MODEL_NAME,
    COREML_MANIFEST_NAME,
    _directory_sha256,
    load_coreml_artifact,
)
from imageall_model_backend.providers import EmbeddingProviderIdentity


@dataclass(frozen=True)
class CoreMLInstallationResult:
    bundle_path: Path
    model_path: Path
    model_sha256: str
    source_model_sha256: str


def install_compiled_coreml_artifact(
    *,
    source_bundle: Path,
    output_dir: Path,
    expected_encoder_identity: EmbeddingProviderIdentity,
) -> CoreMLInstallationResult:
    source_bundle = Path(source_bundle)
    output_dir = Path(output_dir)
    if output_dir.exists():
        raise FileExistsError(f"Core ML install output already exists: {output_dir}")

    source_artifact = load_coreml_artifact(
        source_bundle,
        expected_encoder_identity=expected_encoder_identity,
    )
    source_manifest = json.loads(
        (source_bundle / COREML_MANIFEST_NAME).read_text(encoding="utf-8")
    )
    compiled_source = Path(source_artifact._model.get_compiled_model_path())
    if not compiled_source.is_dir() or compiled_source.is_symlink():
        raise ValueError("compiled Core ML model is missing or unsafe")

    output_dir.parent.mkdir(parents=True, exist_ok=True)
    temporary_dir = Path(
        tempfile.mkdtemp(prefix=f".{output_dir.name}-", dir=output_dir.parent)
    )
    compiled_destination = temporary_dir / COREML_COMPILED_MODEL_NAME
    try:
        shutil.copytree(compiled_source, compiled_destination)
        model_sha256 = _directory_sha256(compiled_destination)
        installed_manifest = {
            "schema_revision": COREML_COMPILED_ARTIFACT_SCHEMA_REVISION,
            "encoder": source_manifest["encoder"],
            "conversion": source_manifest["conversion"],
            "input": source_manifest["input"],
            "output": source_manifest["output"],
            "model_path": COREML_COMPILED_MODEL_NAME,
            "model_sha256": model_sha256,
            "source_model_sha256": source_artifact.model_sha256,
        }
        (temporary_dir / COREML_MANIFEST_NAME).write_text(
            json.dumps(installed_manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        temporary_dir.replace(output_dir)
    except BaseException:
        shutil.rmtree(temporary_dir, ignore_errors=True)
        raise

    return CoreMLInstallationResult(
        bundle_path=output_dir,
        model_path=output_dir / COREML_COMPILED_MODEL_NAME,
        model_sha256=model_sha256,
        source_model_sha256=source_artifact.model_sha256,
    )
