"""Bounded configurable visual review for an explicitly exported private-photo Atelier project.

The user must authorize the exact external endpoint and selected images before use.
This command reads only manifest-listed project media, shrinks them in memory,
and writes validated model observations into the private project. It does not
select a final edit or send source-library paths, locations, or credentials.
"""
from __future__ import annotations

import base64
import hashlib
import io
import json
import os
import re
from pathlib import Path

from datetime import date, datetime, timezone
from uuid import uuid4

from PIL import Image, ImageOps
import jsonschema

from scripts.private_photo_atelier import _inside, _json


from lib.model_connection import KEY_ENV, complete, load_connection, normalize_url

ITEM = {
    "type": "object",
    "required": ["assetID", "date", "visibleEvidence", "subjectClarity", "narrativeRole", "identityUncertain", "risk"],
    "properties": {
        "assetID": {"type": "string"},
        "date": {"type": "string"},
        "visibleEvidence": {"type": "string", "minLength": 8, "maxLength": 240},
        "subjectClarity": {"enum": ["clear", "partial", "small", "ambiguous"]},
        "narrativeRole": {"enum": ["establish", "proximity", "environment", "pause", "ending", "avoid"]},
        "identityUncertain": {"type": "boolean"},
        "risk": {"enum": ["none", "identity", "privacy", "subject_small", "ambiguous"]},
    },
    "additionalProperties": False,
}
RESPONSE_SCHEMA = {
    "type": "object",
    "required": ["items", "recommendedAssetIDs", "selectionReason"],
    "properties": {
        "items": {"type": "array", "items": ITEM, "minItems": 1},
        "recommendedAssetIDs": {"type": "array", "items": {"type": "string"}, "uniqueItems": True},
        "selectionReason": {"type": "string", "minLength": 8, "maxLength": 600},
    },
    "additionalProperties": False,
}


def _small_jpeg(path: Path) -> bytes:
    with Image.open(path) as original:
        source = ImageOps.exif_transpose(original)
        source.thumbnail((960, 960), Image.Resampling.LANCZOS)
        buffer = io.BytesIO()
        source.convert("RGB").save(buffer, format="JPEG", quality=78, optimize=True)
        return buffer.getvalue()


def _write_new(path: Path, value: dict) -> None:
    # New UUID call directories preserve previous successful and failed attempts.
    with path.open("x", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def load_scope(project: Path, expected_scope: str) -> tuple[dict, dict]:
    if not re.fullmatch(r"[a-f0-9]{64}", expected_scope):
        raise ValueError("a separately confirmed scope digest is required")
    if not _inside(project, "project.json").is_file():
        raise ValueError("missing OpenMontage project marker")
    manifest = _json(_inside(project, "artifacts/source-assets.json"))
    if manifest.get("version") != "1.0" or manifest.get("scopeDigestSHA256") != expected_scope:
        raise ValueError("source manifest does not match authorized scope")
    known = {}
    for asset in manifest.get("assets", []):
        ident = asset.get("assetID")
        if not isinstance(ident, str) or not ident or ident in known:
            raise ValueError("duplicate or invalid manifest asset ID")
        capture = asset.get("captureDate")
        if not isinstance(capture, str) or date.fromisoformat(capture).isoformat() != capture:
            raise ValueError("capture date must be a confirmed ISO date")
        if not asset.get("sourceContentVersion"):
            raise ValueError("missing source content version")
        known[ident] = asset
    if not known:
        raise ValueError("empty source manifest")
    return manifest, known


def validate_result(result: dict, requested: list[str], known: dict) -> None:
    jsonschema.validate(result, RESPONSE_SCHEMA)
    returned = [item["assetID"] for item in result["items"]]
    if len(returned) != len(requested) or set(returned) != set(requested):
        raise ValueError("provider omitted, repeated, or invented an asset ID")
    for item in result["items"]:
        if item["date"] != known[item["assetID"]]["captureDate"]:
            raise ValueError("provider date differs from ImageAll metadata")
    if set(result["recommendedAssetIDs"]) - set(requested):
        raise ValueError("provider recommendation leaves bounded request")
    dates = [known[i]["captureDate"] for i in result["recommendedAssetIDs"]]
    if dates != sorted(dates):
        raise ValueError("provider recommendation regresses capture date")


def _check_ids(requested: list[str], known: dict) -> None:
    if (not isinstance(requested, list) or not all(isinstance(i, str) for i in requested)
            or not 2 <= len(requested) <= 12 or len(set(requested)) != len(requested)):
        raise ValueError("provide 2-12 distinct, explicit asset IDs")
    if set(requested) - set(known):
        raise ValueError("unlisted asset ID; no external request made")


def _asset_file(project: Path, asset: dict) -> Path:
    file = _inside(project, asset["relativePath"])
    # A symlinked public root must never become an escape hatch.
    public = project / "public"
    if not public.resolve().is_relative_to(project) or not file.is_relative_to(public.resolve()):
        raise ValueError("asset outside private public directory")
    if not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != asset["sha256"]:
        raise ValueError("normalized asset missing or hash changed")
    return file


def validate_saved(project: Path, relative: str, expected_scope: str) -> dict:
    project = project.resolve()
    _, known = load_scope(project, expected_scope)
    saved = _json(_inside(project, relative))
    if (saved.get("version") not in {"1.0", "1.1"} or not isinstance(saved.get("model"), str) or not saved.get("model")
            or not isinstance(saved.get("endpoint"), str) or saved.get("scopeDigestSHA256") != expected_scope
            or saved.get("phase") not in {"initial", "verify"}):
        raise ValueError("saved observation model, endpoint or scope mismatch")
    normalize_url(saved["endpoint"])
    requested = saved.get("sentAssetIDs")
    _check_ids(requested, known)
    validate_result(saved["modelResult"], requested, known)
    for ident in requested:
        _asset_file(project, known[ident])
    if saved["version"] == "1.1":
        expected = {i: {"sha256": known[i]["sha256"],
                        "sourceContentVersion": known[i]["sourceContentVersion"]} for i in requested}
        if saved.get("sourceAssets") != expected:
            raise ValueError("saved observations refer to changed source versions")
    # Legacy evidence remains explicitly legacy; current validation cannot prove
    # the exact image bytes sent by the old client, which did not record hashes.
    return {"observation": saved,
            "provenance": "legacy-without-sent-source-hashes" if saved["version"] == "1.0" else "versioned-source-hashes",
            "validatedAssetIDs": requested}


def review(project: Path, phase: str, requested: list[str], *, acknowledged_external_send: bool,
           expected_scope: str, key_env: str | None = None) -> Path:
    project = project.resolve()
    if acknowledged_external_send is not True:
        raise ValueError("explicit external-send authorization is required")
    if phase not in {"initial", "verify"}:
        raise ValueError("phase must be initial or verify")
    connection = load_connection()
    endpoint, model = connection["endpoint"], connection["model"]
    # Legacy key_env input is accepted for old tasks, but only App-managed credentials are used.
    manifest, known = load_scope(project, expected_scope)
    _check_ids(requested, known)
    key = os.environ.get(KEY_ENV)
    if not key:
        raise ValueError("selected credential variable absent; no external request made")

    content: list[dict] = [{"type": "text", "text": (
        "请按 JSON 返回所附多张私人照片的逐张视觉观察与有依据的剪辑建议。"
        "仅陈述画面可见事实；日期只可原样回写，不要推断身份、年龄、地点、旅行、病况或经历。"
        "accepted tag 只定义候选范围，不保证每张是同一只猫。"
        "recommendedAssetIDs 仅包含你认为适合这一段按时间顺序展示的照片；不要用美观程度代替故事关系。"
        "字段严格为 items[{assetID,date,visibleEvidence,subjectClarity,narrativeRole,identityUncertain,risk}],"
        "recommendedAssetIDs, selectionReason。"
        "subjectClarity 只可为 clear/partial/small/ambiguous；"
        "narrativeRole 只可为 establish/proximity/environment/pause/ending/avoid；"
        "risk 只可为 none/identity/privacy/subject_small/ambiguous。"
        f"本轮为 {phase}，共有 {len(requested)} 张，每张前的文字给出唯一 ID 和可靠日期。"
        + ("这次是关键选片复核：特别检查第一张与后续猫的外观差别、主体是否真的清楚、"
           "人脸或环境隐私，以及‘幼猫/成长/出行/地点/同一只猫’是否只是猜测；不要把猜测写成事实。"
           if phase == "verify" else "")
    )}]
    sent_sizes = {}
    for asset_id in requested:
        asset = known[asset_id]
        file = _asset_file(project, asset)
        jpeg = _small_jpeg(file)
        sent_sizes[asset_id] = len(jpeg)
        content.append({"type": "text", "text": f"assetID={asset_id}; date={asset['captureDate']}"})
        content.append({"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + base64.b64encode(jpeg).decode("ascii")}})

    messages = [
        {"role": "system", "content": "你是私人照片电影的审片助手。只输出合法 JSON，保持事实和解释分离，遇到身份或事件不确定必须指出。"},
        {"role": "user", "content": content},
    ]
    folder = _inside(project, "artifacts/vision/calls/" + uuid4().hex)
    folder.mkdir(parents=True, exist_ok=False)
    request_record = {
        "version": "1.1", "phase": phase, "endpoint": endpoint, "model": model,
        "scopeDigestSHA256": manifest["scopeDigestSHA256"], "sentAssetIDs": requested,
        "sourceAssets": {i: {"sha256": known[i]["sha256"],
                             "sourceContentVersion": known[i]["sourceContentVersion"]} for i in requested},
        "sentJpegBytes": sent_sizes, "imageMaxDimension": 960,
        "startedAt": datetime.now(timezone.utc).isoformat(),
        "inference": "hosted", "billingCNY": None,
    }
    _write_new(folder / "request.json", request_record)
    usage = None
    status = "request_failed_or_uncertain"
    try:
        remote = complete(connection, messages, key)
        usage = remote.get("usage")
        # Preserve usage before any model/finish/schema check. Never persist headers,
        # credentials, image data URLs or the full HTTP request.
        choice = (remote.get("choices") or [{}])[0]
        raw = choice.get("message", {}).get("content")
        raw_record = {"model": remote.get("model"), "usage": usage,
                      "finish_reason": choice.get("finish_reason"), "content": raw}
        # Defensive redaction; the key is never part of the model prompt.
        clean = json.loads(json.dumps(raw_record, ensure_ascii=False).replace(key, "[redacted]"))
        _write_new(folder / "response.json", clean)
        status = "response_rejected"
        if choice.get("finish_reason") != "stop" or not isinstance(raw, str):
            raise ValueError("provider result is incomplete or non-text")
        result = json.loads(clean["content"])
        validate_result(result, requested, known)
        # Reject source changes during the call, before accepting observations.
        _, current = load_scope(project, expected_scope)
        for ident in requested:
            _asset_file(project, current[ident])
            if current[ident] != known[ident]:
                raise ValueError("source changed during visual request")
        output = {**request_record, "provider": "OpenAI-compatible", "returnedModel": remote.get("model"),
                  "usage": usage, "modelResult": result,
                  "validation": "schema, IDs, dates, scope, source hashes/versions and references passed"}
        path = folder / "validated.json"
        _write_new(path, output)
        status = "validated"
        return path
    except Exception as exc:
        # SDK errors can contain response bodies or request metadata. Do not expose them.
        raise RuntimeError(f"Model request or validation failed ({type(exc).__name__}); no automatic retry") from None
    finally:
        _write_new(folder / "outcome.json", {"status": status, "usage": usage, "billingCNY": None,
                                            "finishedAt": datetime.now(timezone.utc).isoformat()})
        key = ""
