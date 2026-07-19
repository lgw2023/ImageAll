import json
import subprocess
import sys
from pathlib import Path

from imageall_model_backend import standard_pack_cli


PUBLIC_FIXTURE_PACK = (
    Path(__file__).parents[1] / "fixtures" / "standard-scene-pack-v1"
)


def test_validator_reports_the_frozen_standard_pack_identity(capsys) -> None:
    exit_code = standard_pack_cli.main(["--pack", str(PUBLIC_FIXTURE_PACK)])

    assert exit_code == 0
    assert json.loads(capsys.readouterr().out) == {
        "concept_count": 3,
        "mapping_revision": "mapping-v1",
        "ontology_id": "imageall-public-fixture",
        "ontology_revision": "ontology-v1",
        "policy_revision": "policy-v1",
        "provider": {
            "model_id": "imageall/fixture-scene-linear",
            "model_revision": "model-v1",
            "preprocessing_revision": "rgb-channel-mean-v1",
            "provider": "rgb-linear",
        },
        "standard_pack_id": "imageall-public-fixture",
        "standard_pack_revision": "pack-v1",
        "valid": True,
    }


def test_validator_fails_safely_without_leaking_the_pack_path(
    tmp_path, capsys
) -> None:
    missing_pack = tmp_path / "private-pack-name"

    exit_code = standard_pack_cli.main(["--pack", str(missing_pack)])

    captured = capsys.readouterr()
    assert exit_code == 2
    assert captured.out == ""
    assert captured.err == "standard_pack_validation_failed\n"
    assert str(missing_pack) not in captured.err


def test_installed_validator_command_validates_without_starting_the_server() -> None:
    command = Path(sys.executable).with_name("imageall-validate-standard-pack")

    completed = subprocess.run(
        [str(command), "--pack", str(PUBLIC_FIXTURE_PACK)],
        check=False,
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 0
    assert json.loads(completed.stdout)["standard_pack_id"] == (
        "imageall-public-fixture"
    )
    assert completed.stderr == ""
