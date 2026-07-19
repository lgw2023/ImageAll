from __future__ import annotations

import math
import re
from dataclasses import dataclass
from typing import Any


class StandardAdmissionReportError(ValueError):
    pass


@dataclass(frozen=True)
class StandardAdmissionDecision:
    status: str
    reason_codes: tuple[str, ...]

    @property
    def exit_code(self) -> int:
        return 0 if self.status == "approvedSuggestedOnly" else 2


_TOP_LEVEL_FIELDS = {
    "candidate",
    "coreml",
    "dataset",
    "pack",
    "quality",
    "resources",
    "schema_revision",
}
_SECTION_FIELDS = {
    "candidate": {
        "code_license_id",
        "code_license_sha256",
        "model_id",
        "model_revision",
        "preprocessing_revision",
        "provider",
        "upstream_readme_sha256",
        "upstream_revision",
        "weights_license_evidence_sha256",
        "weights_license_id",
        "weights_license_verified",
        "weights_sha256",
        "weights_sha256_verified",
    },
    "dataset": {"license_sha256", "manifest_sha256", "verified"},
    "quality": {
        "concepts",
        "measured",
        "micro_coverage",
        "micro_precision",
        "provider_top1_accuracy",
        "provider_top5_accuracy",
    },
    "coreml": {
        "artifact_sha256",
        "compiled_artifact_sha256",
        "maximum_relative_l2",
        "measured",
        "minimum_cosine",
        "sample_count",
        "top1_match_rate",
    },
    "resources": {
        "artifact_bytes",
        "cold_load_seconds",
        "measured",
        "median_inference_ms",
        "p95_inference_ms",
        "peak_rss_increment_bytes",
        "sequential_failure_count",
        "sequential_inference_count",
    },
    "pack": {"measured", "suggested_only", "validated"},
}
_CONCEPT_FIELDS = {"concept_id", "coverage", "precision", "recall", "support"}
_LOWER_SHA256 = re.compile(r"[0-9a-f]{64}").fullmatch
_LOWER_GIT_SHA = re.compile(r"[0-9a-f]{40}").fullmatch
_ZERO_SHA256 = "0" * 64


def _validate_report(report: Any) -> dict[str, Any]:
    if not isinstance(report, dict) or set(report) != _TOP_LEVEL_FIELDS:
        raise StandardAdmissionReportError("unexpected report shape")
    if any(
        not isinstance(report[section], dict)
        or set(report[section]) != expected_fields
        for section, expected_fields in _SECTION_FIELDS.items()
    ):
        raise StandardAdmissionReportError("unexpected report section shape")

    concepts = report["quality"]["concepts"]
    if not isinstance(concepts, list) or any(
        not isinstance(concept, dict) or set(concept) != _CONCEPT_FIELDS
        for concept in concepts
    ):
        raise StandardAdmissionReportError("unexpected concept shape")

    sha256_values = (
        report["candidate"]["weights_sha256"],
        report["candidate"]["upstream_readme_sha256"],
        report["candidate"]["code_license_sha256"],
        report["candidate"]["weights_license_evidence_sha256"],
        report["dataset"]["manifest_sha256"],
        report["dataset"]["license_sha256"],
        report["coreml"]["artifact_sha256"],
        report["coreml"]["compiled_artifact_sha256"],
    )
    schema_revision = report["schema_revision"]
    if type(schema_revision) is not int or schema_revision != 1 or not all(
        isinstance(value, str) and _LOWER_SHA256(value)
        for value in sha256_values
    ):
        raise StandardAdmissionReportError("invalid report identity")

    candidate = report["candidate"]
    identity_values = (
        candidate["provider"],
        candidate["model_id"],
        candidate["model_revision"],
        candidate["preprocessing_revision"],
        candidate["code_license_id"],
        candidate["weights_license_id"],
    )
    if not all(
        isinstance(value, str) and value.strip() == value and value
        for value in identity_values
    ) or not (
        isinstance(candidate["upstream_revision"], str)
        and _LOWER_GIT_SHA(candidate["upstream_revision"])
    ):
        raise StandardAdmissionReportError("invalid candidate identity")

    boolean_values = (
        candidate["weights_license_verified"],
        candidate["weights_sha256_verified"],
        report["dataset"]["verified"],
        report["quality"]["measured"],
        report["coreml"]["measured"],
        report["resources"]["measured"],
        report["pack"]["measured"],
        report["pack"]["validated"],
        report["pack"]["suggested_only"],
    )
    if not all(type(value) is bool for value in boolean_values):
        raise StandardAdmissionReportError("invalid report boolean")
    if (
        _ZERO_SHA256
        in (
            candidate["weights_sha256"],
            candidate["upstream_readme_sha256"],
            candidate["code_license_sha256"],
            candidate["weights_license_evidence_sha256"],
        )
        or report["dataset"]["verified"]
        and _ZERO_SHA256
        in (
            report["dataset"]["manifest_sha256"],
            report["dataset"]["license_sha256"],
        )
        or report["coreml"]["measured"]
        and _ZERO_SHA256
        in (
            report["coreml"]["artifact_sha256"],
            report["coreml"]["compiled_artifact_sha256"],
        )
    ):
        raise StandardAdmissionReportError("placeholder hash marked verified")

    finite_values = (
        report["quality"]["provider_top1_accuracy"],
        report["quality"]["provider_top5_accuracy"],
        report["quality"]["micro_precision"],
        report["quality"]["micro_coverage"],
        report["coreml"]["minimum_cosine"],
        report["coreml"]["maximum_relative_l2"],
        report["coreml"]["top1_match_rate"],
        report["resources"]["cold_load_seconds"],
        report["resources"]["median_inference_ms"],
        report["resources"]["p95_inference_ms"],
        *(
            value
            for concept in concepts
            for value in (
                concept["precision"],
                concept["recall"],
                concept["coverage"],
            )
        ),
    )
    if not all(
        type(value) in (int, float) and math.isfinite(value)
        for value in finite_values
    ):
        raise StandardAdmissionReportError("non-finite report metric")

    unit_interval_values = (
        report["quality"]["provider_top1_accuracy"],
        report["quality"]["provider_top5_accuracy"],
        report["quality"]["micro_precision"],
        report["quality"]["micro_coverage"],
        report["coreml"]["minimum_cosine"],
        report["coreml"]["top1_match_rate"],
        *(
            value
            for concept in concepts
            for value in (
                concept["precision"],
                concept["recall"],
                concept["coverage"],
            )
        ),
    )
    if not all(0.0 <= value <= 1.0 for value in unit_interval_values):
        raise StandardAdmissionReportError("report metric outside unit interval")
    if (
        report["quality"]["provider_top5_accuracy"]
        < report["quality"]["provider_top1_accuracy"]
    ):
        raise StandardAdmissionReportError("top-5 accuracy below top-1")

    nonnegative_values = (
        report["coreml"]["maximum_relative_l2"],
        report["resources"]["cold_load_seconds"],
        report["resources"]["median_inference_ms"],
        report["resources"]["p95_inference_ms"],
    )
    integer_values = (
        report["coreml"]["sample_count"],
        report["resources"]["artifact_bytes"],
        report["resources"]["peak_rss_increment_bytes"],
        report["resources"]["sequential_failure_count"],
        report["resources"]["sequential_inference_count"],
        *(concept["support"] for concept in concepts),
    )
    if any(value < 0 for value in nonnegative_values) or not all(
        type(value) is int and value >= 0 for value in integer_values
    ):
        raise StandardAdmissionReportError(
            "negative or invalid report measurement"
        )

    concept_ids = [concept["concept_id"] for concept in concepts]
    if any(
        not isinstance(concept_id, str)
        or not concept_id
        or concept_id.strip() != concept_id
        for concept_id in concept_ids
    ) or len(concept_ids) != len(set(concept_ids)):
        raise StandardAdmissionReportError("invalid concept identity")
    return report


def evaluate_standard_admission(report: Any) -> StandardAdmissionDecision:
    report = _validate_report(report)
    candidate = report["candidate"]
    reasons: list[str] = []
    if not report["dataset"]["verified"]:
        reasons.append("dataset_unverified")
    if not candidate["weights_license_verified"]:
        reasons.append("weights_license_unverified")
    elif candidate["weights_license_id"].endswith("-Unversioned"):
        reasons.append("weights_license_unresolved")
    if not candidate["weights_sha256_verified"]:
        reasons.append("weights_sha256_unverified")
    if reasons:
        return StandardAdmissionDecision("research", tuple(sorted(reasons)))

    quality = report["quality"]
    concepts_pass = bool(quality["concepts"]) and all(
        concept["support"] >= 25 and concept["precision"] >= 0.65
        for concept in quality["concepts"]
    )
    if not quality["measured"]:
        reasons.append("quality_unmeasured")
    elif not (
        quality["micro_precision"] >= 0.80
        and quality["micro_coverage"] >= 0.20
        and concepts_pass
    ):
        reasons.append("quality_below_threshold")

    coreml = report["coreml"]
    if not coreml["measured"]:
        reasons.append("coreml_unmeasured")
    elif not (
        coreml["sample_count"] >= 8
        and coreml["minimum_cosine"] >= 0.999
        and coreml["maximum_relative_l2"] <= 0.02
        and coreml["top1_match_rate"] == 1.0
    ):
        reasons.append("coreml_below_threshold")

    resources = report["resources"]
    if not resources["measured"]:
        reasons.append("resources_unmeasured")
    elif not (
        resources["artifact_bytes"] <= 80 * 1024 * 1024
        and resources["cold_load_seconds"] <= 2.0
        and resources["median_inference_ms"] <= 50.0
        and resources["p95_inference_ms"] <= 100.0
        and resources["peak_rss_increment_bytes"] <= 350 * 1024 * 1024
        and resources["sequential_inference_count"] >= 1000
        and resources["sequential_failure_count"] == 0
    ):
        reasons.append("resources_out_of_bounds")

    pack = report["pack"]
    if not pack["measured"]:
        reasons.append("pack_unmeasured")
    elif not (pack["validated"] and pack["suggested_only"]):
        reasons.append("pack_invalid")
    if any(
        reason.endswith(("_below_threshold", "_invalid", "_out_of_bounds"))
        for reason in reasons
    ):
        return StandardAdmissionDecision("rejected", tuple(sorted(reasons)))
    if reasons:
        return StandardAdmissionDecision(
            "evaluationReady", tuple(sorted(reasons))
        )
    return StandardAdmissionDecision("approvedSuggestedOnly", ())
