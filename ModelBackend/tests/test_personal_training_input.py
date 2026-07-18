import hashlib
import json
from dataclasses import asdict
from pathlib import Path

import numpy as np
import pytest

from imageall_model_backend.personal_training import load_personal_training_input
from imageall_model_backend.personal_training import (
    load_personal_linear_head,
    train_personal_linear_head,
)
from imageall_model_backend.providers import EmbeddingProviderIdentity
from imageall_model_backend.training import LinearHeadTrainingConfig


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_personal_training_input(root: Path) -> Path:
    root.mkdir()
    encoder = EmbeddingProviderIdentity(
        provider="dinov2",
        model_id="facebook/dinov2-small",
        model_revision="fixture-model-revision",
        preprocessing_revision="fixture-preprocessing-revision",
        element_count=2,
    )
    np.savez(
        root / "embeddings.npz",
        asset_ids=np.asarray(["asset-1", "asset-2", "asset-3"], dtype=np.str_),
        content_revisions=np.asarray(["r1", "r1", "r1"], dtype=np.str_),
        embeddings=np.asarray(
            [[-2.0, -1.0], [1.0, 2.0], [2.0, 1.0]], dtype=np.float32
        ),
    )
    decisions = [
        {
            "asset_id": "asset-1",
            "content_revision": "r1",
            "tag_id": "tag-trip",
            "state": "manualRejected",
        },
        {
            "asset_id": "asset-2",
            "content_revision": "r1",
            "tag_id": "tag-trip",
            "state": "manualAccepted",
        },
        {
            "asset_id": "asset-3",
            "content_revision": "r1",
            "tag_id": "tag-work",
            "state": "manualAccepted",
        },
    ]
    decisions_path = root / "decisions.jsonl"
    decisions_path.write_text(
        "".join(json.dumps(decision, sort_keys=True) + "\n" for decision in decisions),
        encoding="utf-8",
    )
    manifest = {
        "schema_revision": 1,
        "track": "personal",
        "catalog_scope_id": "catalog-fixture",
        "decision_snapshot_revision": "decisions-v1",
        "encoder": asdict(encoder),
        "personal_tag_ids": ["tag-trip", "tag-work"],
        "label_vocabulary_revision": "personal-tags-v1",
        "files": {
            "embeddings.npz": {"sha256": _sha256(root / "embeddings.npz")},
            "decisions.jsonl": {"sha256": _sha256(decisions_path)},
        },
    }
    (root / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return root


def rewrite_decisions_and_checksum(root: Path, decisions: list[dict[str, str]]) -> None:
    decisions_path = root / "decisions.jsonl"
    decisions_path.write_text(
        "".join(json.dumps(decision, sort_keys=True) + "\n" for decision in decisions),
        encoding="utf-8",
    )
    manifest_path = root / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["files"]["decisions.jsonl"]["sha256"] = _sha256(decisions_path)
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def rewrite_embeddings_and_checksum(
    root: Path,
    *,
    asset_ids: list[str],
    embeddings: np.ndarray,
) -> None:
    embeddings_path = root / "embeddings.npz"
    np.savez(
        embeddings_path,
        asset_ids=np.asarray(asset_ids, dtype=np.str_),
        content_revisions=np.asarray(["r1"] * len(asset_ids), dtype=np.str_),
        embeddings=np.asarray(embeddings, dtype=np.float32),
    )
    manifest_path = root / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["files"]["embeddings.npz"]["sha256"] = _sha256(embeddings_path)
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def write_trainable_personal_training_input(root: Path) -> tuple[Path, np.ndarray]:
    root = write_personal_training_input(root)
    asset_ids = ["asset-1", "asset-2", "asset-3", "asset-4"]
    embeddings = np.asarray(
        [[-2.0, -2.0], [-2.0, 2.0], [2.0, -2.0], [2.0, 2.0]],
        dtype=np.float32,
    )
    rewrite_embeddings_and_checksum(root, asset_ids=asset_ids, embeddings=embeddings)
    decisions = []
    for asset_id, trip_state, work_state in (
        ("asset-1", "manualRejected", "manualRejected"),
        ("asset-2", "manualRejected", "manualAccepted"),
        ("asset-3", "manualAccepted", "manualRejected"),
        ("asset-4", "manualAccepted", "manualAccepted"),
    ):
        decisions.extend(
            [
                {
                    "asset_id": asset_id,
                    "content_revision": "r1",
                    "tag_id": "tag-trip",
                    "state": trip_state,
                },
                {
                    "asset_id": asset_id,
                    "content_revision": "r1",
                    "tag_id": "tag-work",
                    "state": work_state,
                },
            ]
        )
    rewrite_decisions_and_checksum(root, decisions)
    return root, embeddings


def test_loads_only_explicit_personal_decisions_as_observed_targets(tmp_path: Path) -> None:
    training_input = load_personal_training_input(
        write_personal_training_input(tmp_path / "training-input")
    )

    assert training_input.catalog_scope_id == "catalog-fixture"
    assert training_input.personal_tag_ids == ("tag-trip", "tag-work")
    np.testing.assert_array_equal(
        training_input.observation_mask,
        np.asarray(
            [[True, False], [True, False], [False, True]], dtype=np.bool_
        ),
    )
    np.testing.assert_array_equal(
        training_input.targets,
        np.asarray([[0.0, 0.0], [1.0, 0.0], [0.0, 1.0]], dtype=np.float32),
    )


def test_rejects_a_standard_track_manifest_as_personal_training_input(
    tmp_path: Path,
) -> None:
    root = write_personal_training_input(tmp_path / "training-input")
    manifest_path = root / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["track"] = "standard"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    with pytest.raises(ValueError, match="training input track is not personal"):
        load_personal_training_input(root)


def test_rejects_a_training_input_file_changed_after_manifest_creation(
    tmp_path: Path,
) -> None:
    root = write_personal_training_input(tmp_path / "training-input")
    with (root / "decisions.jsonl").open("a", encoding="utf-8") as decisions:
        decisions.write("{}\n")

    with pytest.raises(ValueError, match="decisions.jsonl checksum mismatch"):
        load_personal_training_input(root)


def test_rejects_duplicate_decisions_for_the_same_asset_and_tag(tmp_path: Path) -> None:
    root = write_personal_training_input(tmp_path / "training-input")
    decisions = [
        json.loads(line)
        for line in (root / "decisions.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    decisions.append(decisions[0])
    rewrite_decisions_and_checksum(root, decisions)

    with pytest.raises(ValueError, match="duplicate personal decision"):
        load_personal_training_input(root)


def test_rejects_machine_generated_states_as_personal_training_targets(
    tmp_path: Path,
) -> None:
    root = write_personal_training_input(tmp_path / "training-input")
    decisions = [
        json.loads(line)
        for line in (root / "decisions.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    decisions[0]["state"] = "suggested"
    rewrite_decisions_and_checksum(root, decisions)

    with pytest.raises(
        ValueError, match="decision state must be manualAccepted or manualRejected"
    ):
        load_personal_training_input(root)


def test_rejects_a_decision_without_a_matching_embedding_revision(
    tmp_path: Path,
) -> None:
    root = write_personal_training_input(tmp_path / "training-input")
    decisions = [
        json.loads(line)
        for line in (root / "decisions.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    decisions[0]["content_revision"] = "stale-revision"
    rewrite_decisions_and_checksum(root, decisions)

    with pytest.raises(ValueError, match="decision references missing embedding"):
        load_personal_training_input(root)


def test_rejects_embeddings_that_do_not_match_the_dinov2_identity(
    tmp_path: Path,
) -> None:
    root = write_personal_training_input(tmp_path / "training-input")
    rewrite_embeddings_and_checksum(
        root,
        asset_ids=["asset-1", "asset-2", "asset-3"],
        embeddings=np.zeros((3, 3), dtype=np.float32),
    )

    with pytest.raises(
        ValueError, match="embedding matrix does not match encoder identity"
    ):
        load_personal_training_input(root)


def test_rejects_a_decision_for_an_unpublished_personal_tag(tmp_path: Path) -> None:
    root = write_personal_training_input(tmp_path / "training-input")
    decisions = [
        json.loads(line)
        for line in (root / "decisions.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    decisions[0]["tag_id"] = "tag-not-in-vocabulary"
    rewrite_decisions_and_checksum(root, decisions)

    with pytest.raises(ValueError, match="decision references unknown personal tag"):
        load_personal_training_input(root)


def test_trains_and_reloads_a_catalog_scoped_personal_bundle(tmp_path: Path) -> None:
    root, embeddings = write_trainable_personal_training_input(
        tmp_path / "training-input"
    )

    result = train_personal_linear_head(
        training_input=load_personal_training_input(root),
        output_dir=tmp_path / "bundle",
        bundle_id="personal-fixture",
        bundle_revision="bundle-v1",
        config=LinearHeadTrainingConfig(epochs=80, learning_rate=0.1),
    )

    assert result.final_loss < 0.1
    manifest_path = result.bundle_path / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    weights_path = result.bundle_path / "linear-head.npz"
    assert manifest["track"] == "personal"
    assert manifest["bundle_id"] == "personal-fixture"
    assert manifest["bundle_revision"] == "bundle-v1"
    assert manifest["catalog_scope_id"] == "catalog-fixture"
    assert manifest["decision_snapshot_revision"] == "decisions-v1"
    assert manifest["sample_counts"] == {
        "tag-trip": {"negative": 2, "positive": 2},
        "tag-work": {"negative": 2, "positive": 2},
    }
    assert manifest["weights_sha256"] == _sha256(weights_path)

    bundle = load_personal_linear_head(
        result.bundle_path,
        expected_catalog_scope_id="catalog-fixture",
        expected_bundle_id="personal-fixture",
        expected_bundle_revision="bundle-v1",
        expected_encoder_identity=load_personal_training_input(root).encoder_identity,
        expected_label_vocabulary_revision="personal-tags-v1",
    )
    logits = bundle.predict_logits(embeddings)
    assert np.all(logits[:2, 0] < 0)
    assert np.all(logits[2:, 0] > 0)
    assert np.all(logits[[0, 2], 1] < 0)
    assert np.all(logits[[1, 3], 1] > 0)


def test_rejects_loading_a_personal_bundle_for_another_catalog_scope(
    tmp_path: Path,
) -> None:
    root, _ = write_trainable_personal_training_input(tmp_path / "training-input")
    training_input = load_personal_training_input(root)
    result = train_personal_linear_head(
        training_input=training_input,
        output_dir=tmp_path / "bundle",
        bundle_id="personal-fixture",
        bundle_revision="bundle-v1",
        config=LinearHeadTrainingConfig(epochs=1, learning_rate=0.1),
    )

    with pytest.raises(ValueError, match="catalog scope mismatch"):
        load_personal_linear_head(
            result.bundle_path,
            expected_catalog_scope_id="another-catalog",
            expected_bundle_id="personal-fixture",
            expected_bundle_revision="bundle-v1",
            expected_encoder_identity=training_input.encoder_identity,
            expected_label_vocabulary_revision="personal-tags-v1",
        )


def test_unobserved_asset_tag_pairs_do_not_change_that_tag_classifier(
    tmp_path: Path,
) -> None:
    bundles = []
    for index, unobserved_embedding in enumerate(([-20.0, 20.0], [20.0, -20.0])):
        root, base_embeddings = write_trainable_personal_training_input(
            tmp_path / f"training-input-{index}"
        )
        embeddings = np.vstack(
            [base_embeddings, np.asarray(unobserved_embedding, dtype=np.float32)]
        )
        rewrite_embeddings_and_checksum(
            root,
            asset_ids=["asset-1", "asset-2", "asset-3", "asset-4", "asset-5"],
            embeddings=embeddings,
        )
        decisions = [
            json.loads(line)
            for line in (root / "decisions.jsonl").read_text(encoding="utf-8").splitlines()
        ]
        decisions.append(
            {
                "asset_id": "asset-5",
                "content_revision": "r1",
                "tag_id": "tag-work",
                "state": "manualAccepted",
            }
        )
        rewrite_decisions_and_checksum(root, decisions)
        training_input = load_personal_training_input(root)
        result = train_personal_linear_head(
            training_input=training_input,
            output_dir=tmp_path / f"bundle-{index}",
            bundle_id="personal-fixture",
            bundle_revision=f"bundle-v{index}",
            config=LinearHeadTrainingConfig(epochs=20, learning_rate=0.1),
        )
        bundles.append(
            load_personal_linear_head(
                result.bundle_path,
                expected_catalog_scope_id="catalog-fixture",
                expected_bundle_id="personal-fixture",
                expected_bundle_revision=f"bundle-v{index}",
                expected_encoder_identity=training_input.encoder_identity,
                expected_label_vocabulary_revision="personal-tags-v1",
            )
        )

    np.testing.assert_allclose(bundles[0].weights[0], bundles[1].weights[0])
    np.testing.assert_allclose(bundles[0].bias[0], bundles[1].bias[0])
    assert not np.allclose(bundles[0].weights[1], bundles[1].weights[1])


def test_personal_training_cli_writes_a_versioned_bundle(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    from imageall_model_backend.personal_cli import main

    root, _ = write_trainable_personal_training_input(tmp_path / "training-input")
    output_dir = tmp_path / "bundle"

    exit_code = main(
        [
            "--input",
            str(root),
            "--output",
            str(output_dir),
            "--bundle-id",
            "personal-fixture",
            "--bundle-revision",
            "bundle-v1",
            "--epochs",
            "1",
            "--learning-rate",
            "0.1",
        ]
    )

    assert exit_code == 0
    summary = json.loads(capsys.readouterr().out)
    assert summary["bundle_id"] == "personal-fixture"
    assert summary["bundle_revision"] == "bundle-v1"
    assert summary["catalog_scope_id"] == "catalog-fixture"
    assert summary["bundle_path"] == str(output_dir)
    assert (output_dir / "manifest.json").is_file()
    assert (output_dir / "linear-head.npz").is_file()


def test_personal_training_cli_fails_cleanly_below_the_two_by_two_sample_gate(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    from imageall_model_backend.personal_cli import main

    root = write_personal_training_input(tmp_path / "training-input")

    exit_code = main(
        [
            "--input",
            str(root),
            "--output",
            str(tmp_path / "bundle"),
            "--bundle-id",
            "personal-fixture",
            "--bundle-revision",
            "bundle-v1",
            "--epochs",
            "1",
        ]
    )

    assert exit_code == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "requires at least 2 positive and 2 negative decisions" in captured.err
    assert not (tmp_path / "bundle").exists()


@pytest.mark.parametrize(
    ("option", "value"),
    (("--epochs", "0"), ("--learning-rate", "0")),
)
def test_personal_training_cli_rejects_non_positive_training_configuration(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    option: str,
    value: str,
) -> None:
    from imageall_model_backend.personal_cli import main

    root, _ = write_trainable_personal_training_input(tmp_path / "training-input")

    exit_code = main(
        [
            "--input",
            str(root),
            "--output",
            str(tmp_path / "bundle"),
            "--bundle-id",
            "personal-fixture",
            "--bundle-revision",
            "bundle-v1",
            option,
            value,
        ]
    )

    assert exit_code == 2
    assert "training configuration must be positive" in capsys.readouterr().err
    assert not (tmp_path / "bundle").exists()
