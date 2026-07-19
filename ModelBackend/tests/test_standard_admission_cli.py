import json
import subprocess
import sys
from pathlib import Path

from imageall_model_backend import standard_admission_cli


SHA_A = "a" * 64
SHA_B = "b" * 64
SHA_C = "c" * 64
RESEARCH_FIXTURE = (
    Path(__file__).parents[1]
    / "fixtures"
    / "standard-admission"
    / "places365-resnet18-research-v1.json"
)


def _research_report() -> dict:
    return {
        "schema_revision": 1,
        "candidate": {
            "provider": "places365-resnet18",
            "model_id": "csailvision/places365-resnet18",
            "model_revision": "upstream-8a953ed-weights-2f47592",
            "upstream_revision": "8a953ed56438726dc98bdef3796d042e7f1f171e",
            "upstream_readme_sha256": (
                "1de70ec4bb303cc7e8ab569bbdb7ab835112ee5c16cdbb73328acbb33895b521"
            ),
            "weights_sha256": (
                "2f4759217d470da2b803f8f66cd4488a066406b555a5fb95ee9a4663f9f05588"
            ),
            "weights_sha256_verified": False,
            "code_license_id": "MIT",
            "code_license_sha256": (
                "d4e65e5f2171ee6cca57b0f15ef1da5f11e91a170b6f4511342574b8e2d046c2"
            ),
            "weights_license_id": (
                "LicenseRef-Places365-Pretrained-CC-BY-Unversioned"
            ),
            "weights_license_evidence_sha256": (
                "1de70ec4bb303cc7e8ab569bbdb7ab835112ee5c16cdbb73328acbb33895b521"
            ),
            "weights_license_verified": False,
            "preprocessing_revision": "places365-resnet18-center-crop-v1",
        },
        "dataset": {
            "manifest_sha256": SHA_A,
            "license_sha256": SHA_B,
            "verified": False,
        },
        "quality": {
            "measured": False,
            "provider_top1_accuracy": 0.0,
            "provider_top5_accuracy": 0.0,
            "micro_precision": 0.0,
            "micro_coverage": 0.0,
            "concepts": [],
        },
        "coreml": {
            "measured": False,
            "artifact_sha256": SHA_B,
            "compiled_artifact_sha256": SHA_C,
            "sample_count": 0,
            "minimum_cosine": 0.0,
            "maximum_relative_l2": 1.0,
            "top1_match_rate": 0.0,
        },
        "resources": {
            "measured": False,
            "artifact_bytes": 0,
            "cold_load_seconds": 0.0,
            "median_inference_ms": 0.0,
            "p95_inference_ms": 0.0,
            "peak_rss_increment_bytes": 0,
            "sequential_inference_count": 0,
            "sequential_failure_count": 0,
        },
        "pack": {
            "measured": False,
            "validated": False,
            "suggested_only": True,
        },
    }


def _passing_report() -> dict:
    report = _research_report()
    report["candidate"]["weights_sha256_verified"] = True
    report["candidate"]["weights_license_id"] = "CC-BY-4.0"
    report["candidate"]["weights_license_verified"] = True
    report["dataset"]["verified"] = True
    report["quality"] = {
        "measured": True,
        "provider_top1_accuracy": 0.5,
        "provider_top5_accuracy": 0.8,
        "micro_precision": 0.8,
        "micro_coverage": 0.2,
        "concepts": [
            {
                "concept_id": "scene.water",
                "support": 25,
                "precision": 0.65,
                "recall": 0.5,
                "coverage": 0.2,
            }
        ],
    }
    report["coreml"] = {
        "measured": True,
        "artifact_sha256": SHA_B,
        "compiled_artifact_sha256": SHA_C,
        "sample_count": 8,
        "minimum_cosine": 0.999,
        "maximum_relative_l2": 0.02,
        "top1_match_rate": 1.0,
    }
    report["resources"] = {
        "measured": True,
        "artifact_bytes": 80 * 1024 * 1024,
        "cold_load_seconds": 2.0,
        "median_inference_ms": 50.0,
        "p95_inference_ms": 100.0,
        "peak_rss_increment_bytes": 350 * 1024 * 1024,
        "sequential_inference_count": 1000,
        "sequential_failure_count": 0,
    }
    report["pack"] = {
        "measured": True,
        "validated": True,
        "suggested_only": True,
    }
    return report


def test_unverified_places365_candidate_remains_research(
    tmp_path, capsys
) -> None:
    report_path = tmp_path / "admission-report.json"
    report_path.write_text(json.dumps(_research_report()), encoding="utf-8")

    exit_code = standard_admission_cli.main(["--report", str(report_path)])

    captured = capsys.readouterr()
    assert exit_code == 2
    assert json.loads(captured.out) == {
        "reason_codes": [
            "dataset_unverified",
            "weights_license_unverified",
            "weights_sha256_unverified",
        ],
        "schema_revision": 1,
        "status": "research",
    }
    assert captured.err == ""


def test_tracked_places365_candidate_fixture_remains_research(capsys) -> None:
    exit_code = standard_admission_cli.main(
        ["--report", str(RESEARCH_FIXTURE)]
    )

    assert exit_code == 2
    assert json.loads(capsys.readouterr().out) == {
        "reason_codes": [
            "dataset_unverified",
            "weights_license_unverified",
            "weights_sha256_unverified",
        ],
        "schema_revision": 1,
        "status": "research",
    }


def test_candidate_source_and_license_evidence_hashes_are_accepted(
    tmp_path, capsys
) -> None:
    report = _research_report()
    report["candidate"].update(
        {
            "upstream_readme_sha256": SHA_A,
            "code_license_sha256": SHA_B,
            "weights_license_evidence_sha256": SHA_A,
        }
    )
    report_path = tmp_path / "admission-report.json"
    report_path.write_text(json.dumps(report), encoding="utf-8")

    exit_code = standard_admission_cli.main(["--report", str(report_path)])

    assert exit_code == 2
    assert json.loads(capsys.readouterr().out)["status"] == "research"


def test_verified_inputs_are_evaluation_ready_until_measurements_exist(
    tmp_path, capsys
) -> None:
    report = _research_report()
    report["candidate"]["weights_sha256_verified"] = True
    report["candidate"]["weights_license_id"] = "CC-BY-4.0"
    report["candidate"]["weights_license_verified"] = True
    report["dataset"]["verified"] = True
    report_path = tmp_path / "admission-report.json"
    report_path.write_text(json.dumps(report), encoding="utf-8")

    exit_code = standard_admission_cli.main(["--report", str(report_path)])

    assert exit_code == 2
    assert json.loads(capsys.readouterr().out) == {
        "reason_codes": [
            "coreml_unmeasured",
            "pack_unmeasured",
            "quality_unmeasured",
            "resources_unmeasured",
        ],
        "schema_revision": 1,
        "status": "evaluationReady",
    }


def test_complete_report_at_every_boundary_is_approved_suggested_only(
    tmp_path, capsys
) -> None:
    report_path = tmp_path / "admission-report.json"
    report_path.write_text(json.dumps(_passing_report()), encoding="utf-8")

    exit_code = standard_admission_cli.main(["--report", str(report_path)])

    assert exit_code == 0
    assert json.loads(capsys.readouterr().out) == {
        "reason_codes": [],
        "schema_revision": 1,
        "status": "approvedSuggestedOnly",
    }


def test_unversioned_weights_license_cannot_be_claimed_as_verified(
    tmp_path, capsys
) -> None:
    report = _passing_report()
    report["candidate"]["weights_license_id"] = (
        "LicenseRef-Places365-Pretrained-CC-BY-Unversioned"
    )
    report_path = tmp_path / "admission-report.json"
    report_path.write_text(json.dumps(report), encoding="utf-8")

    exit_code = standard_admission_cli.main(["--report", str(report_path)])

    assert exit_code == 2
    assert json.loads(capsys.readouterr().out) == {
        "reason_codes": ["weights_license_unresolved"],
        "schema_revision": 1,
        "status": "research",
    }


def test_unknown_report_field_is_rejected_without_leaking_path(
    tmp_path, capsys
) -> None:
    report = _passing_report()
    report["approved"] = True
    report_path = tmp_path / "private-report-name.json"
    report_path.write_text(json.dumps(report), encoding="utf-8")

    exit_code = standard_admission_cli.main(["--report", str(report_path)])

    captured = capsys.readouterr()
    assert exit_code == 3
    assert captured.out == ""
    assert captured.err == "standard_admission_report_invalid\n"
    assert str(report_path) not in captured.err


def test_unknown_nested_field_is_rejected_as_malformed(tmp_path, capsys) -> None:
    report = _passing_report()
    report["candidate"]["display_name"] = "Places365"
    report_path = tmp_path / "admission-report.json"
    report_path.write_text(json.dumps(report), encoding="utf-8")

    exit_code = standard_admission_cli.main(["--report", str(report_path)])

    captured = capsys.readouterr()
    assert exit_code == 3
    assert captured.out == ""
    assert captured.err == "standard_admission_report_invalid\n"


def test_uppercase_sha256_is_rejected_as_malformed(tmp_path, capsys) -> None:
    report = _passing_report()
    report["candidate"]["weights_sha256"] = report["candidate"][
        "weights_sha256"
    ].upper()
    report_path = tmp_path / "admission-report.json"
    report_path.write_text(json.dumps(report), encoding="utf-8")

    exit_code = standard_admission_cli.main(["--report", str(report_path)])

    captured = capsys.readouterr()
    assert exit_code == 3
    assert captured.out == ""
    assert captured.err == "standard_admission_report_invalid\n"


def test_empty_candidate_identity_is_rejected_as_malformed(tmp_path, capsys) -> None:
    report = _passing_report()
    report["candidate"]["model_id"] = ""
    report_path = tmp_path / "admission-report.json"
    report_path.write_text(json.dumps(report), encoding="utf-8")

    exit_code = standard_admission_cli.main(["--report", str(report_path)])

    captured = capsys.readouterr()
    assert exit_code == 3
    assert captured.out == ""
    assert captured.err == "standard_admission_report_invalid\n"


def test_non_finite_metric_is_rejected_as_malformed(tmp_path, capsys) -> None:
    report = _passing_report()
    report["quality"]["micro_precision"] = float("nan")
    report_path = tmp_path / "admission-report.json"
    report_path.write_text(json.dumps(report), encoding="utf-8")

    exit_code = standard_admission_cli.main(["--report", str(report_path)])

    captured = capsys.readouterr()
    assert exit_code == 3
    assert captured.out == ""
    assert captured.err == "standard_admission_report_invalid\n"


def test_integer_cannot_impersonate_verified_boolean(tmp_path, capsys) -> None:
    report = _passing_report()
    report["candidate"]["weights_sha256_verified"] = 1
    report_path = tmp_path / "admission-report.json"
    report_path.write_text(json.dumps(report), encoding="utf-8")

    exit_code = standard_admission_cli.main(["--report", str(report_path)])

    captured = capsys.readouterr()
    assert exit_code == 3
    assert captured.out == ""
    assert captured.err == "standard_admission_report_invalid\n"


def test_boolean_cannot_impersonate_schema_revision(tmp_path, capsys) -> None:
    report = _passing_report()
    report["schema_revision"] = True
    report_path = tmp_path / "admission-report.json"
    report_path.write_text(json.dumps(report), encoding="utf-8")

    exit_code = standard_admission_cli.main(["--report", str(report_path)])

    captured = capsys.readouterr()
    assert exit_code == 3
    assert captured.out == ""
    assert captured.err == "standard_admission_report_invalid\n"


def test_verified_dataset_cannot_use_placeholder_hash(tmp_path, capsys) -> None:
    report = _passing_report()
    report["dataset"]["manifest_sha256"] = "0" * 64
    report_path = tmp_path / "admission-report.json"
    report_path.write_text(json.dumps(report), encoding="utf-8")

    exit_code = standard_admission_cli.main(["--report", str(report_path)])

    captured = capsys.readouterr()
    assert exit_code == 3
    assert captured.out == ""
    assert captured.err == "standard_admission_report_invalid\n"


def test_metric_outside_unit_interval_is_rejected_as_malformed(
    tmp_path, capsys
) -> None:
    report = _passing_report()
    report["quality"]["micro_precision"] = 1.01
    report_path = tmp_path / "admission-report.json"
    report_path.write_text(json.dumps(report), encoding="utf-8")

    exit_code = standard_admission_cli.main(["--report", str(report_path)])

    captured = capsys.readouterr()
    assert exit_code == 3
    assert captured.out == ""
    assert captured.err == "standard_admission_report_invalid\n"


def test_top5_accuracy_below_top1_is_rejected_as_malformed(
    tmp_path, capsys
) -> None:
    report = _passing_report()
    report["quality"]["provider_top1_accuracy"] = 0.8
    report["quality"]["provider_top5_accuracy"] = 0.79
    report_path = tmp_path / "admission-report.json"
    report_path.write_text(json.dumps(report), encoding="utf-8")

    exit_code = standard_admission_cli.main(["--report", str(report_path)])

    captured = capsys.readouterr()
    assert exit_code == 3
    assert captured.out == ""
    assert captured.err == "standard_admission_report_invalid\n"


def test_negative_resource_measurement_is_rejected_as_malformed(
    tmp_path, capsys
) -> None:
    report = _passing_report()
    report["resources"]["artifact_bytes"] = -1
    report_path = tmp_path / "admission-report.json"
    report_path.write_text(json.dumps(report), encoding="utf-8")

    exit_code = standard_admission_cli.main(["--report", str(report_path)])

    captured = capsys.readouterr()
    assert exit_code == 3
    assert captured.out == ""
    assert captured.err == "standard_admission_report_invalid\n"


def test_duplicate_concept_is_rejected_as_malformed(tmp_path, capsys) -> None:
    report = _passing_report()
    report["quality"]["concepts"].append(
        dict(report["quality"]["concepts"][0])
    )
    report_path = tmp_path / "admission-report.json"
    report_path.write_text(json.dumps(report), encoding="utf-8")

    exit_code = standard_admission_cli.main(["--report", str(report_path)])

    captured = capsys.readouterr()
    assert exit_code == 3
    assert captured.out == ""
    assert captured.err == "standard_admission_report_invalid\n"


def test_complete_but_failed_measurements_are_rejected_with_all_reasons(
    tmp_path, capsys
) -> None:
    report = _passing_report()
    report["quality"]["micro_precision"] = 0.79
    report["coreml"]["sample_count"] = 7
    report["resources"]["artifact_bytes"] += 1
    report["pack"]["suggested_only"] = False
    report_path = tmp_path / "admission-report.json"
    report_path.write_text(json.dumps(report), encoding="utf-8")

    exit_code = standard_admission_cli.main(["--report", str(report_path)])

    assert exit_code == 2
    assert json.loads(capsys.readouterr().out) == {
        "reason_codes": [
            "coreml_below_threshold",
            "pack_invalid",
            "quality_below_threshold",
            "resources_out_of_bounds",
        ],
        "schema_revision": 1,
        "status": "rejected",
    }


def test_installed_admission_command_emits_stable_decision(tmp_path) -> None:
    report_path = tmp_path / "admission-report.json"
    report_path.write_text(json.dumps(_research_report()), encoding="utf-8")
    command = Path(sys.executable).with_name("imageall-verify-standard-admission")

    completed = subprocess.run(
        [str(command), "--report", str(report_path)],
        check=False,
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 2
    assert json.loads(completed.stdout)["status"] == "research"
    assert completed.stderr == ""
