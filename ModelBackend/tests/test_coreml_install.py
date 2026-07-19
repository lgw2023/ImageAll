import json
from pathlib import Path

import numpy as np
import pytest
import torch

from imageall_model_backend import coreml_install_cli
from imageall_model_backend.coreml_export import (
    _coreml_compute_plan_summary,
    convert_embedding_model_to_coreml,
    load_coreml_artifact,
)
from imageall_model_backend.coreml_install import install_compiled_coreml_artifact
from imageall_model_backend.providers import EmbeddingProviderIdentity


class _TinyEmbeddingModel(torch.nn.Module):
    def forward(self, pixel_values: torch.Tensor) -> torch.Tensor:
        pooled = pixel_values.mean(dim=(2, 3))
        return torch.cat((pooled, pooled[:, :1]), dim=1)


def _identity() -> EmbeddingProviderIdentity:
    return EmbeddingProviderIdentity(
        provider="fixture",
        model_id="fixture-encoder",
        model_revision="fixture-model-revision",
        preprocessing_revision="fixture-preprocessing-v1",
        element_count=4,
    )


def _source_bundle(tmp_path: Path) -> tuple[Path, torch.Tensor]:
    source = tmp_path / "source-coreml-bundle"
    example = torch.linspace(
        -1.0,
        1.0,
        steps=1 * 3 * 8 * 8,
        dtype=torch.float32,
    ).reshape(1, 3, 8, 8)
    convert_embedding_model_to_coreml(
        model=_TinyEmbeddingModel().eval(),
        encoder_identity=_identity(),
        example_input=example,
        output_dir=source,
    )
    return source, example


def test_installed_bundle_loads_only_verified_compiled_model(tmp_path) -> None:
    source, example = _source_bundle(tmp_path)
    source_manifest = json.loads((source / "manifest.json").read_text())
    destination = tmp_path / "installed-coreml-bundle"

    result = install_compiled_coreml_artifact(
        source_bundle=source,
        output_dir=destination,
        expected_encoder_identity=_identity(),
    )

    manifest = json.loads((destination / "manifest.json").read_text())
    assert result.bundle_path == destination
    assert result.model_path == destination / "encoder.mlmodelc"
    assert result.model_sha256 == manifest["model_sha256"]
    assert manifest["schema_revision"] == 2
    assert manifest["model_path"] == "encoder.mlmodelc"
    assert manifest["source_model_sha256"] == source_manifest["model_sha256"]
    assert len(manifest["model_sha256"]) == 64
    assert not (destination / "encoder.mlpackage").exists()

    loaded = load_coreml_artifact(
        destination,
        expected_encoder_identity=_identity(),
    )
    prediction = loaded.predict(example.numpy())
    expected = _TinyEmbeddingModel()(example).detach().numpy()
    assert np.allclose(prediction, expected, atol=5e-3, rtol=5e-3)


def test_install_does_not_replace_an_existing_destination(tmp_path) -> None:
    source, _ = _source_bundle(tmp_path)
    destination = tmp_path / "installed-coreml-bundle"
    destination.mkdir()
    marker = destination / "owned-by-user.txt"
    marker.write_text("preserve", encoding="utf-8")

    with pytest.raises(FileExistsError):
        install_compiled_coreml_artifact(
            source_bundle=source,
            output_dir=destination,
            expected_encoder_identity=_identity(),
        )

    assert marker.read_text(encoding="utf-8") == "preserve"


def test_compiled_bundle_remains_compatible_with_compute_plan(tmp_path) -> None:
    source, _ = _source_bundle(tmp_path)
    destination = tmp_path / "installed-coreml-bundle"
    install_compiled_coreml_artifact(
        source_bundle=source,
        output_dir=destination,
        expected_encoder_identity=_identity(),
    )
    loaded = load_coreml_artifact(
        destination,
        expected_encoder_identity=_identity(),
    )

    plan = _coreml_compute_plan_summary(loaded)

    assert plan["requested_compute_units"] == "ALL"
    assert plan["evidence_kind"] == "anticipated_compute_plan"


def test_compiled_bundle_rejects_modified_model_bytes(tmp_path) -> None:
    source, _ = _source_bundle(tmp_path)
    destination = tmp_path / "installed-coreml-bundle"
    install_compiled_coreml_artifact(
        source_bundle=source,
        output_dir=destination,
        expected_encoder_identity=_identity(),
    )
    model_file = next(
        path
        for path in (destination / "encoder.mlmodelc").rglob("*")
        if path.is_file()
    )
    model_file.write_bytes(model_file.read_bytes() + b"modified")

    with pytest.raises(ValueError, match="checksum does not match"):
        load_coreml_artifact(
            destination,
            expected_encoder_identity=_identity(),
        )


def test_install_cli_emits_only_compiled_identity(tmp_path, monkeypatch, capsys) -> None:
    class _Result:
        model_sha256 = "a" * 64
        source_model_sha256 = "b" * 64

    monkeypatch.setattr(
        coreml_install_cli,
        "install_compiled_coreml_artifact",
        lambda **_: _Result(),
    )

    exit_code = coreml_install_cli.main(
        [
            "--source-bundle",
            str(tmp_path / "private-source"),
            "--output",
            str(tmp_path / "private-output"),
        ]
    )

    assert exit_code == 0
    assert json.loads(capsys.readouterr().out) == {
        "model_sha256": "a" * 64,
        "schema_revision": 2,
        "source_model_sha256": "b" * 64,
    }


def test_install_cli_fails_closed_without_exposing_paths(tmp_path, capsys) -> None:
    exit_code = coreml_install_cli.main(
        [
            "--source-bundle",
            str(tmp_path / "private-source"),
            "--output",
            str(tmp_path / "private-output"),
        ]
    )

    captured = capsys.readouterr()
    assert exit_code == 3
    assert captured.out == ""
    assert captured.err == "coreml_install_invalid\n"
    assert str(tmp_path) not in captured.err
