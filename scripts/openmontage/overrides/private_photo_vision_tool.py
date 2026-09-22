"""Pipeline-discovered, bounded configured model visual observations; no creative orchestration."""
from __future__ import annotations

import json
import os
from pathlib import Path

import jsonschema

from tools.base_tool import BaseTool, Determinism, ResourceProfile, ToolResult, ToolRuntime, ToolStability, ToolStatus, ToolTier
from lib.private_photo_vision import review, validate_saved
from lib.model_connection import KEY_ENV, load_connection


class PrivatePhotoVision(BaseTool):
    name = "private_photo_vision"
    version = "1.1.0"
    capability = "analysis"
    provider = "openai-compatible"
    tier = ToolTier.ANALYZE
    stability = ToolStability.BETA
    runtime = ToolRuntime.API
    determinism = Determinism.STOCHASTIC
    agent_skills = []
    dependencies = ["python:PIL", "python:jsonschema"]
    install_instructions = "Configure endpoint, API key and model in ImageAll settings."
    supports = {"multiple_images": True, "local_result_validation": True, "offline_saved_validation": True}
    best_for = ["authorized private-photo first pass and key-shot recheck inside private-photo-atelier"]
    not_good_for = ["identity verification", "autonomous aesthetic acceptance", "original library discovery"]
    side_effects = ["review sends 2-12 resized project images to the explicitly authorized configured model endpoint",
                    "writes a unique private call record including rejected-response usage"]
    resource_profile = ResourceProfile(cpu_cores=1, ram_mb=256, network_required=True)
    input_schema = {
        "type": "object",
        "required": ["operation", "project_dir", "expected_scope"],
        "properties": {
            "operation": {"enum": ["review", "validate_saved"]},
            "project_dir": {"type": "string"},
            "expected_scope": {"type": "string", "pattern": "^[a-f0-9]{64}$"},
            "phase": {"enum": ["initial", "verify"]},
            "asset_ids": {"type": "array", "items": {"type": "string"}, "minItems": 2, "maxItems": 12, "uniqueItems": True},
            "key_env": {"type": "string", "pattern": "^[A-Za-z_][A-Za-z0-9_]*$"},
            "acknowledged_external_send": {"const": True},
            "observation_path": {"type": "string"},
        },
        "allOf": [
            {"if": {"properties": {"operation": {"const": "review"}}},
             "then": {"required": ["phase", "asset_ids", "acknowledged_external_send"]}},
            {"if": {"properties": {"operation": {"const": "validate_saved"}}},
             "then": {"required": ["observation_path"]}},
        ],
        "additionalProperties": False,
    }

    def get_status(self) -> ToolStatus:
        # Configuration availability is not authorization to send photos.
        try:
            load_connection()
            return ToolStatus.AVAILABLE if os.environ.get(KEY_ENV) else ToolStatus.DEGRADED
        except (ValueError, OSError):
            return ToolStatus.DEGRADED

    def estimate_cost(self, inputs: dict) -> float | None:
        return 0.0 if inputs.get("operation") == "validate_saved" else None

    def execute(self, inputs: dict) -> ToolResult:
        cost = None
        try:
            jsonschema.validate(inputs, self.input_schema)
            project = Path(inputs["project_dir"]).resolve()
            scope = inputs["expected_scope"]
            if inputs["operation"] == "validate_saved":
                cost = 0.0
                checked = validate_saved(project, inputs["observation_path"], scope)
                data = {"validatedAssetIDs": checked["validatedAssetIDs"], "provenance": checked["provenance"],
                        "phase": checked["observation"]["phase"], "model": checked["observation"]["model"],
                        "usage": checked["observation"].get("usage"), "newExternalCalls": 0}
                return ToolResult(success=True, data=data, cost_usd=cost, model=checked["observation"]["model"])
            path = review(project, inputs["phase"], inputs["asset_ids"],
                          acknowledged_external_send=inputs["acknowledged_external_send"],
                          expected_scope=scope)
            output = json.loads(path.read_text())
            return ToolResult(success=True, data={"output": str(path), "model": output["model"],
                              "phase": inputs["phase"], "usage": output["usage"],
                              "newExternalCalls": 1, "billingCNY": None},
                              artifacts=[str(path)], cost_usd=None, model=output["model"])
        except Exception as exc:
            # Schema exceptions can quote private instance data. Never emit them.
            return ToolResult(success=False, error=f"Private photo review rejected ({type(exc).__name__}); no automatic retry or fallback.",
                              data={"billingCNY": None, "audit": "Inspect private artifacts/vision/calls outcome records; unknown is not zero."},
                              cost_usd=cost)
