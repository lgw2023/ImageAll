#!/usr/bin/env python3
"""Fail-closed Photos export to ImageAll identity migration bridge.

The tool never opens a .photoslibrary package and never edits its input database.
Detailed identifiers are written only to explicitly requested JSON reports.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
import uuid
from pathlib import Path, PurePosixPath
from typing import Any, Iterable


PLAN_SCHEMA_VERSION = 2
MANIFEST_SCHEMA_VERSION = 1
FOUNDATION_FINGERPRINT_HELPER = Path(__file__).with_name(
    "foundation_file_fingerprints.swift"
)
ACTIVE_RECYCLE_STATES = ("pending", "recycled", "restoring", "purging")
KNOWN_IMAGEALL_MIGRATIONS = tuple(
    [
        "v001_create_catalog_core",
        "v002_add_stage_1_catalog_query_support",
        "v003_add_derived_image_cache",
        "v004_add_personalization",
        "v005_add_catalog_scale_indexes",
        "v006_add_asset_text_search",
        "v007_add_catalog_scope_identity",
        "v008_add_personal_model_suggestions",
        "v009_add_standard_ontology",
        "v010_add_standard_predictions",
        "v011_add_standard_prediction_provenance",
        "v012_repair_standard_tag_binding",
        "v013_photos_missing_asset_repair",
        "v014_add_training_runs_and_personal_multi_slot",
        "v015_add_suggestion_score_thresholds",
        "v016_add_tag_groups",
        "v017_per_tag_personal_suggestion_models",
        "v018_add_asset_similarity_fingerprint",
        "v019_add_library_slimming_recycle",
        "v020_harden_library_slimming_recycle",
        "v021_add_photos_recycle_identifier",
        "v022_harden_library_slimming_analysis",
        "v023_add_source_similarity_index",
        "v024_repair_source_mutation_authorization",
        "v025_retain_purged_asset_knowledge",
        "v026_add_media_kind_and_video_metadata",
        "v027_partition_personalization_by_media_kind",
        "v028_partition_slimming_by_media_kind",
        "v029_add_original_aspect_thumbnail_cache",
        "v030_add_similarity_digest_provenance",
        "v031_add_asset_location",
        "v032_add_place_tag_resolution",
        "v033_add_slimming_cluster_review_queue",
        "v034_backfill_slimming_confirmed_history",
        "v035_add_asset_favorite_state",
        "v036_add_training_run_sample_manifest",
    ]
)
PRESERVED_FACT_TABLES = (
    "asset_tag_decision",
    "asset_favorite_state",
    "tag_model_sample",
    "personal_model_sample",
    "training_run_sample",
    "recycle_entry",
    "asset_location",
)


class BridgeError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def open_read_only_database(path: Path) -> sqlite3.Connection:
    if not path.is_file():
        raise BridgeError("database_missing", "database input does not exist")
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only = ON")
    return connection


def table_exists(connection: sqlite3.Connection, table: str) -> bool:
    return (
        connection.execute(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", (table,)
        ).fetchone()
        is not None
    )


def table_columns(connection: sqlite3.Connection, table: str) -> set[str]:
    if not table_exists(connection, table):
        return set()
    return {row["name"] for row in connection.execute(f'PRAGMA table_info("{table}")')}


def require_catalog_schema(connection: sqlite3.Connection) -> None:
    required = {
        "source": {
            "id",
            "kind",
            "bookmark",
            "state",
            "scan_generation",
            "dirty_epoch",
            "updated_at_ms",
        },
        "asset": {
            "id",
            "source_id",
            "locator_kind",
            "relative_path",
            "photos_local_identifier",
            "locator_state",
            "availability",
            "content_revision",
            "last_seen_generation",
            "record_updated_at_ms",
            "file_name",
        },
        "file_fingerprint": {
            "asset_id",
            "size_bytes",
            "modified_at_ns",
            "resource_id",
            "sha256",
        },
    }
    for table, columns in required.items():
        missing = columns - table_columns(connection, table)
        if missing:
            raise BridgeError(
                "unsupported_catalog_schema",
                f"required catalog schema is missing {table} columns",
            )


def require_standalone_snapshot(path: Path) -> None:
    sidecars = (
        Path(f"{path}-wal"),
        Path(f"{path}-shm"),
        Path(f"{path}-journal"),
    )
    if any(sidecar.exists() for sidecar in sidecars):
        raise BridgeError(
            "database_snapshot_required",
            "plan and migration require a standalone snapshot without SQLite sidecars",
        )


def remove_database_output(path: Path) -> None:
    for candidate in (
        path,
        Path(f"{path}-wal"),
        Path(f"{path}-shm"),
        Path(f"{path}-journal"),
    ):
        candidate.unlink(missing_ok=True)


def load_manifest(path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if not path.is_file():
        raise BridgeError("manifest_missing", "manifest does not exist")
    header: dict[str, Any] | None = None
    assets_by_identifier: dict[str, dict[str, Any]] = {}
    with path.open("r", encoding="utf-8") as stream:
        for line_number, raw_line in enumerate(stream, start=1):
            line = raw_line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                raise BridgeError(
                    "invalid_manifest", f"invalid JSONL record at line {line_number}"
                ) from error
            if not isinstance(record, dict):
                raise BridgeError("invalid_manifest", "manifest records must be objects")
            record_type = record.get("record_type")
            if record_type == "header":
                if header is not None or assets_by_identifier:
                    raise BridgeError("invalid_manifest", "manifest header must be first")
                header = record
            elif record_type == "asset":
                identifier = record.get("local_identifier")
                if not isinstance(identifier, str) or not identifier:
                    raise BridgeError("invalid_manifest", "asset identifier is missing")
                previous = assets_by_identifier.get(identifier)
                if previous is not None and previous.get("status") == "complete":
                    raise BridgeError(
                        "duplicate_manifest_identifier",
                        "completed manifest identifier repeats",
                    )
                assets_by_identifier[identifier] = record
            else:
                raise BridgeError("invalid_manifest", "unknown manifest record type")
    if header is None or header.get("schema_version") != MANIFEST_SCHEMA_VERSION:
        raise BridgeError("unsupported_manifest_schema", "manifest schema is not supported")
    return header, list(assets_by_identifier.values())


def resolve_exported_file(export_root: Path, relative_path: str) -> Path:
    pure = PurePosixPath(relative_path)
    if pure.is_absolute() or not pure.parts or any(part in ("", ".", "..") for part in pure.parts):
        raise BridgeError("unsafe_export_path", "manifest path is not a safe relative path")
    root = export_root.resolve(strict=True)
    candidate = export_root.joinpath(*pure.parts)
    if candidate.is_symlink():
        raise BridgeError("unsafe_export_path", "manifest file cannot be a symbolic link")
    resolved = candidate.resolve(strict=True)
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise BridgeError("unsafe_export_path", "manifest path escapes export root") from error
    if not resolved.is_file():
        raise BridgeError("export_file_missing", "manifest resource is not a regular file")
    return resolved


def foundation_file_fingerprints(paths: list[Path]) -> list[dict[str, Any]]:
    """Read the exact file facts used by FoundationFolderFileResourceReader."""
    if not paths:
        return []
    if not FOUNDATION_FINGERPRINT_HELPER.is_file():
        raise BridgeError(
            "foundation_helper_missing", "Foundation fingerprint helper is missing"
        )
    request = json.dumps({"paths": [str(path) for path in paths]})
    try:
        result = subprocess.run(
            ["xcrun", "swift", str(FOUNDATION_FINGERPRINT_HELPER)],
            input=request,
            text=True,
            capture_output=True,
            check=False,
        )
    except OSError as error:
        raise BridgeError(
            "foundation_helper_unavailable", "Foundation fingerprint helper cannot run"
        ) from error
    if result.returncode != 0:
        raise BridgeError(
            "foundation_helper_failed", "Foundation fingerprint helper failed"
        )
    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise BridgeError(
            "foundation_helper_failed", "Foundation fingerprint helper returned invalid data"
        ) from error
    facts = response.get("facts") if isinstance(response, dict) else None
    if not isinstance(facts, list) or len(facts) != len(paths):
        raise BridgeError(
            "foundation_helper_failed", "Foundation fingerprint result count is invalid"
        )
    validated: list[dict[str, Any]] = []
    for fact in facts:
        if not isinstance(fact, dict):
            raise BridgeError(
                "foundation_helper_failed", "Foundation fingerprint fact is invalid"
            )
        size_bytes = fact.get("size_bytes")
        modified_at_ns = fact.get("modified_at_ns")
        resource_id_hex = fact.get("resource_id_hex")
        if (
            not isinstance(size_bytes, int)
            or size_bytes < 0
            or not isinstance(modified_at_ns, int)
            or not isinstance(resource_id_hex, str)
            or not resource_id_hex
            or len(resource_id_hex) % 2 != 0
        ):
            raise BridgeError(
                "foundation_fingerprint_unavailable",
                "Foundation did not provide a complete stable file fingerprint",
            )
        try:
            bytes.fromhex(resource_id_hex)
        except ValueError as error:
            raise BridgeError(
                "foundation_helper_failed", "Foundation resource identifier is invalid"
            ) from error
        validated.append(
            {
                "size_bytes": size_bytes,
                "modified_at_ns": modified_at_ns,
                "resource_id_hex": resource_id_hex.lower(),
            }
        )
    return validated


def primary_resource(asset: dict[str, Any]) -> dict[str, Any]:
    primary_index = asset.get("primary_resource_index")
    resources = asset.get("resources")
    if asset.get("status") != "complete" or not isinstance(resources, list):
        raise BridgeError("asset_export_incomplete", "asset export is incomplete")
    matches = [resource for resource in resources if resource.get("index") == primary_index]
    if len(matches) != 1:
        raise BridgeError("primary_resource_ambiguous", "primary resource is not unique")
    resource = matches[0]
    if not isinstance(resource.get("relative_path"), str):
        raise BridgeError("invalid_manifest", "primary resource path is missing")
    if not isinstance(resource.get("byte_size"), int) or resource["byte_size"] < 0:
        raise BridgeError("invalid_manifest", "primary resource size is invalid")
    digest = resource.get("sha256")
    if not isinstance(digest, str) or len(digest) != 64:
        raise BridgeError("invalid_manifest", "primary resource hash is invalid")
    try:
        bytes.fromhex(digest)
    except ValueError as error:
        raise BridgeError("invalid_manifest", "primary resource hash is invalid") from error
    return resource


def fact_counts(connection: sqlite3.Connection, asset_ids: list[str]) -> dict[str, int]:
    if not asset_ids:
        return {table: 0 for table in PRESERVED_FACT_TABLES if table_exists(connection, table)}
    placeholders = ",".join("?" for _ in asset_ids)
    counts: dict[str, int] = {}
    for table in PRESERVED_FACT_TABLES:
        columns = table_columns(connection, table)
        if "asset_id" not in columns:
            continue
        counts[table] = int(
            connection.execute(
                f'SELECT COUNT(*) FROM "{table}" WHERE asset_id IN ({placeholders})',
                asset_ids,
            ).fetchone()[0]
        )
    return counts


def create_plan(arguments: argparse.Namespace) -> int:
    database = Path(arguments.database).resolve()
    manifest = Path(arguments.manifest).resolve()
    export_root = Path(arguments.export_root).resolve()
    output = Path(arguments.output)
    if output.exists():
        raise BridgeError("output_exists", "plan output already exists")
    require_standalone_snapshot(database)
    _, manifest_assets = load_manifest(manifest)
    connection = open_read_only_database(database)
    try:
        require_catalog_schema(connection)
        destination = connection.execute(
            "SELECT id, kind, state, bookmark, scan_generation FROM source WHERE id = ?",
            (arguments.destination_source_id,),
        ).fetchone()
        if destination is None or destination["kind"] != "folder":
            raise BridgeError("invalid_destination_source", "destination is not a folder source")
        if destination["state"] not in ("active", "disabled"):
            raise BridgeError(
                "invalid_destination_source",
                "destination folder is neither active nor explicitly disabled",
            )
        if destination["bookmark"] is None or len(destination["bookmark"]) == 0:
            raise BridgeError("invalid_destination_source", "destination bookmark is missing")

        matches: list[dict[str, Any]] = []
        unresolved: list[dict[str, str]] = []
        manifest_identifiers: set[str] = set()
        exported_without_catalog_identity_count = 0
        unexportable_without_catalog_identity_count = 0
        for exported_asset in manifest_assets:
            identifier = exported_asset["local_identifier"]
            manifest_identifiers.add(identifier)
            try:
                rows = connection.execute(
                    "SELECT id, source_id, availability, content_revision "
                    "FROM asset WHERE locator_kind = 'photos' "
                    "AND locator_state = 'current' AND photos_local_identifier = ?",
                    (identifier,),
                ).fetchall()
                if len(rows) > 1:
                    raise BridgeError(
                        "catalog_match_not_unique", "catalog Photos match is not unique"
                    )
                if not rows and exported_asset.get("status") != "complete":
                    # PhotoKit can return zero-resource placeholder assets. They have no
                    # file identity to migrate and are irrelevant when ImageAll never
                    # cataloged them, but keep an explicit audit count.
                    unexportable_without_catalog_identity_count += 1
                    continue
                resource = primary_resource(exported_asset)
                relative_path = resource["relative_path"]
                exported_file = resolve_exported_file(export_root, relative_path)
                stat = exported_file.stat()
                if stat.st_size != resource["byte_size"]:
                    raise BridgeError("export_size_mismatch", "exported file size changed")
                digest = sha256_file(exported_file)
                if digest.lower() != resource["sha256"].lower():
                    raise BridgeError("export_hash_mismatch", "exported file hash changed")
                if not rows:
                    exported_without_catalog_identity_count += 1
                    continue

                row = rows[0]
                if row["availability"] == "recycled":
                    raise BridgeError("asset_recycled", "recycled asset stays historical")
                if table_exists(connection, "recycle_entry"):
                    placeholders = ",".join("?" for _ in ACTIVE_RECYCLE_STATES)
                    active = connection.execute(
                        f"SELECT 1 FROM recycle_entry WHERE asset_id = ? "
                        f"AND state IN ({placeholders}) LIMIT 1",
                        (row["id"], *ACTIVE_RECYCLE_STATES),
                    ).fetchone()
                    if active is not None:
                        raise BridgeError("active_recycle", "asset has active recycle lifecycle")
                collision = connection.execute(
                    "SELECT id FROM asset WHERE source_id = ? AND locator_kind = 'file' "
                    "AND locator_state = 'current' AND relative_path = ?",
                    (arguments.destination_source_id, relative_path),
                ).fetchone()
                if collision is not None:
                    raise BridgeError(
                        "destination_locator_conflict", "destination locator already exists"
                    )
                matches.append(
                    {
                        "asset_id": row["id"],
                        "photos_source_id": row["source_id"],
                        "local_identifier": identifier,
                        "content_revision": row["content_revision"],
                        "relative_path": relative_path,
                        "file_name": PurePosixPath(relative_path).name,
                        "byte_size": stat.st_size,
                        "modified_at_ns": stat.st_mtime_ns,
                        "sha256": digest,
                    }
                )
            except BridgeError as error:
                unresolved.append({"local_identifier": identifier, "reason": error.code})

        catalog_unexported = connection.execute(
            "SELECT photos_local_identifier FROM asset "
            "WHERE locator_kind = 'photos' AND locator_state = 'current' "
            "AND availability = 'available'"
        ).fetchall()
        for row in catalog_unexported:
            identifier = row["photos_local_identifier"]
            if identifier not in manifest_identifiers:
                unresolved.append(
                    {"local_identifier": identifier, "reason": "catalog_asset_not_exported"}
                )

        retained_unavailable_tombstone_count = sum(
            1
            for row in connection.execute(
                "SELECT photos_local_identifier FROM asset "
                "WHERE locator_kind = 'photos' AND locator_state = 'current' "
                "AND availability != 'available'"
            )
            if row["photos_local_identifier"] not in manifest_identifiers
        )

        exported_files = [
            resolve_exported_file(export_root, match["relative_path"])
            for match in matches
        ]
        foundation_facts = foundation_file_fingerprints(exported_files)
        for match, fact in zip(matches, foundation_facts, strict=True):
            if fact["size_bytes"] != match["byte_size"]:
                raise BridgeError(
                    "export_size_mismatch",
                    "Foundation and manifest disagree about exported file size",
                )
            match["modified_at_ns"] = fact["modified_at_ns"]
            match["resource_id_hex"] = fact["resource_id_hex"]

        matched_asset_ids = [match["asset_id"] for match in matches]
        plan = {
            "schema_version": PLAN_SCHEMA_VERSION,
            "created_at_ms": int(time.time() * 1000),
            "database_sha256": sha256_file(database),
            "manifest_sha256": sha256_file(manifest),
            "export_root": str(export_root),
            "destination_source_id": arguments.destination_source_id,
            "destination_source_state": destination["state"],
            "destination_scan_generation": destination["scan_generation"],
            "status": "ready" if matches and not unresolved else "blocked",
            "matches": matches,
            "unresolved": unresolved,
            "exported_without_catalog_identity_count": exported_without_catalog_identity_count,
            "unexportable_without_catalog_identity_count": (
                unexportable_without_catalog_identity_count
            ),
            "retained_unavailable_tombstone_count": retained_unavailable_tombstone_count,
            "preserved_fact_counts": fact_counts(connection, matched_asset_ids),
        }
    finally:
        connection.close()
    atomic_write_json(output, plan)
    print(f"matched={len(plan['matches'])} unresolved={len(plan['unresolved'])}")
    return 0


def load_plan(path: Path) -> dict[str, Any]:
    try:
        plan = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BridgeError("invalid_plan", "migration plan cannot be read") from error
    if not isinstance(plan, dict) or plan.get("schema_version") != PLAN_SCHEMA_VERSION:
        raise BridgeError("invalid_plan", "migration plan schema is not supported")
    if plan.get("status") != "ready":
        raise BridgeError("plan_blocked", "migration plan contains unresolved assets")
    matches = plan.get("matches")
    if not isinstance(matches, list) or not matches:
        raise BridgeError("invalid_plan", "migration plan has no matches")
    return plan


def backup_database(source: Path, destination: Path) -> None:
    if destination.exists():
        raise BridgeError("output_exists", "database output already exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    source_connection = open_read_only_database(source)
    destination_connection: sqlite3.Connection | None = None
    try:
        destination_connection = sqlite3.connect(destination)
        source_connection.backup(destination_connection)
        destination_connection.commit()
        destination_connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        journal_mode = destination_connection.execute(
            "PRAGMA journal_mode = DELETE"
        ).fetchone()[0]
        if str(journal_mode).lower() != "delete":
            raise BridgeError(
                "snapshot_journal_convergence_failed",
                "snapshot could not converge to DELETE journal mode",
            )
        destination_connection.commit()
    except Exception:
        if destination_connection is not None:
            destination_connection.close()
            destination_connection = None
        remove_database_output(destination)
        raise
    finally:
        source_connection.close()
        if destination_connection is not None:
            destination_connection.close()
    for sidecar in (
        Path(f"{destination}-wal"),
        Path(f"{destination}-shm"),
        Path(f"{destination}-journal"),
    ):
        if sidecar.exists():
            sidecar.unlink()


def update_favorite_to_local_only(
    connection: sqlite3.Connection, asset_id: str, now_ms: int
) -> None:
    columns = table_columns(connection, "asset_favorite_state")
    if not columns:
        return
    assignments: list[str] = []
    values: list[Any] = []
    for column in (
        "photos_observed_value",
        "photos_observed_modified_at_ms",
        "photos_write_modified_at_ms",
        "photos_observed_modification_at_ms",
        "observed_at_ms",
        "writeback_at_ms",
        "last_error_code",
    ):
        if column in columns:
            assignments.append(f'"{column}" = NULL')
    if "sync_status" in columns:
        assignments.append("sync_status = 'localOnly'")
    if "updated_at_ms" in columns:
        assignments.append("updated_at_ms = ?")
        values.append(now_ms)
    if assignments:
        values.append(asset_id)
        connection.execute(
            f"UPDATE asset_favorite_state SET {', '.join(assignments)} WHERE asset_id = ?",
            values,
        )


def invalidate_source_similarity_membership(
    connection: sqlite3.Connection,
    *,
    asset_id: str,
) -> None:
    columns = table_columns(connection, "source_similarity_bucket_member")
    if "asset_id" in columns:
        connection.execute(
            "DELETE FROM source_similarity_bucket_member WHERE asset_id = ?", (asset_id,)
        )


def mark_source_similarity_stale(
    connection: sqlite3.Connection,
    *,
    source_ids: set[str],
    now_ms: int,
) -> None:
    columns = table_columns(connection, "source_similarity_index")
    if not source_ids or "source_id" not in columns or "state" not in columns:
        return
    assignments = ["state = 'stale'"]
    values: list[Any] = []
    for column in ("job_id", "built_at_ms", "last_error"):
        if column in columns:
            assignments.append(f'"{column}" = NULL')
    if "updated_at_ms" in columns:
        assignments.append("updated_at_ms = ?")
        values.append(now_ms)
    placeholders = ",".join("?" for _ in source_ids)
    values.extend(sorted(source_ids))
    connection.execute(
        f"UPDATE source_similarity_index SET {', '.join(assignments)} "
        f"WHERE source_id IN ({placeholders})",
        values,
    )


def disable_photos_sources(
    connection: sqlite3.Connection,
    *,
    source_ids: set[str],
    now_ms: int,
) -> None:
    if not source_ids:
        return
    placeholders = ",".join("?" for _ in source_ids)
    ordered_source_ids = sorted(source_ids)
    connection.execute(
        "UPDATE source SET state = 'disabled', updated_at_ms = ? "
        f"WHERE kind = 'photos' AND id IN ({placeholders})",
        (now_ms, *ordered_source_ids),
    )
    job_columns = table_columns(connection, "job")
    required_job_columns = {
        "source_id",
        "kind",
        "state",
        "control_request",
        "lease_owner",
        "lease_expires_at_ms",
        "updated_at_ms",
    }
    if not required_job_columns.issubset(job_columns):
        return
    connection.execute(
        "UPDATE job SET state = 'cancelled', control_request = 'none', "
        "lease_owner = NULL, lease_expires_at_ms = NULL, updated_at_ms = ? "
        f"WHERE source_id IN ({placeholders}) AND kind = 'photos.reconcile.v1' "
        "AND state IN ('pending', 'paused', 'retryableFailed')",
        (now_ms, *ordered_source_ids),
    )
    connection.execute(
        "UPDATE job SET control_request = 'cancel', updated_at_ms = ? "
        f"WHERE source_id IN ({placeholders}) AND kind = 'photos.reconcile.v1' "
        "AND state = 'running'",
        (now_ms, *ordered_source_ids),
    )


def migrate_database(arguments: argparse.Namespace) -> int:
    database = Path(arguments.database).resolve()
    output = Path(arguments.output).resolve()
    plan = load_plan(Path(arguments.plan))
    require_standalone_snapshot(database)
    if sha256_file(database) != plan["database_sha256"]:
        raise BridgeError("database_changed", "database does not match migration plan")
    export_root = Path(plan["export_root"])
    exported_files: list[Path] = []
    for match in plan["matches"]:
        exported_file = resolve_exported_file(export_root, match["relative_path"])
        exported_files.append(exported_file)
        if exported_file.stat().st_size != match["byte_size"]:
            raise BridgeError("export_size_mismatch", "exported file size changed after planning")
        if sha256_file(exported_file) != match["sha256"]:
            raise BridgeError("export_hash_mismatch", "exported file changed after planning")
    foundation_facts = foundation_file_fingerprints(exported_files)
    for match, fact in zip(plan["matches"], foundation_facts, strict=True):
        if (
            fact["size_bytes"] != match["byte_size"]
            or fact["modified_at_ns"] != match.get("modified_at_ns")
            or fact["resource_id_hex"] != match.get("resource_id_hex")
        ):
            raise BridgeError(
                "export_fingerprint_changed",
                "Foundation file fingerprint changed after planning",
            )

    backup_database(database, output)
    connection = sqlite3.connect(output)
    connection.row_factory = sqlite3.Row
    try:
        connection.execute("PRAGMA foreign_keys = ON")
        require_catalog_schema(connection)
        now_ms = int(time.time() * 1000)
        affected_source_ids = {plan["destination_source_id"]}
        photos_source_ids: set[str] = set()
        with connection:
            for match, foundation_fact in zip(
                plan["matches"], foundation_facts, strict=True
            ):
                affected_source_ids.add(match["photos_source_id"])
                photos_source_ids.add(match["photos_source_id"])
                current = connection.execute(
                    "SELECT source_id, locator_kind, photos_local_identifier, locator_state, "
                    "availability, content_revision FROM asset WHERE id = ?",
                    (match["asset_id"],),
                ).fetchone()
                if (
                    current is None
                    or current["source_id"] != match["photos_source_id"]
                    or current["locator_kind"] != "photos"
                    or current["photos_local_identifier"] != match["local_identifier"]
                    or current["locator_state"] != "current"
                    or current["availability"] == "recycled"
                    or current["content_revision"] != match["content_revision"]
                ):
                    raise BridgeError("plan_precondition_changed", "asset no longer matches plan")
                collision = connection.execute(
                    "SELECT id FROM asset WHERE source_id = ? AND locator_kind = 'file' "
                    "AND locator_state = 'current' AND relative_path = ?",
                    (plan["destination_source_id"], match["relative_path"]),
                ).fetchone()
                if collision is not None:
                    raise BridgeError(
                        "destination_locator_conflict", "destination locator now exists"
                    )
                connection.execute(
                    "UPDATE asset SET source_id = ?, locator_kind = 'file', relative_path = ?, "
                    "photos_local_identifier = NULL, availability = 'available', "
                    "last_seen_generation = NULL, file_name = ?, record_updated_at_ms = ? "
                    "WHERE id = ?",
                    (
                        plan["destination_source_id"],
                        match["relative_path"],
                        match["file_name"],
                        now_ms,
                        match["asset_id"],
                    ),
                )
                connection.execute(
                    "INSERT INTO file_fingerprint "
                    "(asset_id, size_bytes, modified_at_ns, resource_id, sha256) "
                    "VALUES (?, ?, ?, ?, ?) "
                    "ON CONFLICT(asset_id) DO UPDATE SET "
                    "size_bytes = excluded.size_bytes, "
                    "modified_at_ns = excluded.modified_at_ns, "
                    "resource_id = excluded.resource_id, "
                    "sha256 = excluded.sha256",
                    (
                        match["asset_id"],
                        match["byte_size"],
                        match["modified_at_ns"],
                        bytes.fromhex(foundation_fact["resource_id_hex"]),
                        bytes.fromhex(match["sha256"]),
                    ),
                )
                update_favorite_to_local_only(connection, match["asset_id"], now_ms)
                invalidate_source_similarity_membership(
                    connection,
                    asset_id=match["asset_id"],
                )
            source_columns = table_columns(connection, "source")
            assignments = ["dirty_epoch = dirty_epoch + 1", "updated_at_ms = ?"]
            if "state" in source_columns:
                assignments.append("state = 'active'")
            connection.execute(
                f"UPDATE source SET {', '.join(assignments)} WHERE id = ? AND kind = 'folder'",
                (now_ms, plan["destination_source_id"]),
            )
            disable_photos_sources(
                connection,
                source_ids=photos_source_ids,
                now_ms=now_ms,
            )
            mark_source_similarity_stale(
                connection,
                source_ids=affected_source_ids,
                now_ms=now_ms,
            )
            if connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
                raise BridgeError("foreign_key_check_failed", "migrated database has FK errors")
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise BridgeError("integrity_check_failed", "migrated database failed integrity check")
    except Exception:
        connection.close()
        remove_database_output(output)
        raise
    finally:
        try:
            connection.close()
        except Exception:
            pass
    print(f"migrated={len(plan['matches'])}")
    return 0


def verify_database(arguments: argparse.Namespace) -> int:
    database = Path(arguments.database).resolve()
    output = Path(arguments.output)
    if output.exists():
        raise BridgeError("output_exists", "verification output already exists")
    plan = load_plan(Path(arguments.plan))
    export_root = Path(plan["export_root"])
    exported_files = [
        resolve_exported_file(export_root, match["relative_path"])
        for match in plan["matches"]
    ]
    foundation_facts = foundation_file_fingerprints(exported_files)
    connection = open_read_only_database(database)
    try:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        foreign_keys = [dict(row) for row in connection.execute("PRAGMA foreign_key_check")]
        failures: list[dict[str, str]] = []
        resource_identifier_verified_count = 0
        for match, foundation_fact in zip(
            plan["matches"], foundation_facts, strict=True
        ):
            if (
                foundation_fact["size_bytes"] != match["byte_size"]
                or foundation_fact["modified_at_ns"] != match.get("modified_at_ns")
                or foundation_fact["resource_id_hex"] != match.get("resource_id_hex")
            ):
                failures.append(
                    {
                        "asset_id": match["asset_id"],
                        "reason": "export_fingerprint_changed",
                    }
                )
                continue
            asset = connection.execute(
                "SELECT source_id, locator_kind, relative_path, photos_local_identifier, "
                "availability, content_revision FROM asset WHERE id = ?",
                (match["asset_id"],),
            ).fetchone()
            if (
                asset is None
                or asset["source_id"] != plan["destination_source_id"]
                or asset["locator_kind"] != "file"
                or asset["relative_path"] != match["relative_path"]
                or asset["photos_local_identifier"] is not None
                or asset["availability"] != "available"
                or asset["content_revision"] != match["content_revision"]
            ):
                failures.append({"asset_id": match["asset_id"], "reason": "locator_mismatch"})
                continue
            fingerprint = connection.execute(
                "SELECT size_bytes, modified_at_ns, hex(resource_id) AS resource_id, "
                "hex(sha256) AS sha256 FROM file_fingerprint "
                "WHERE asset_id = ?",
                (match["asset_id"],),
            ).fetchone()
            if (
                fingerprint is None
                or fingerprint["size_bytes"] != match["byte_size"]
                or fingerprint["modified_at_ns"] != match["modified_at_ns"]
                or fingerprint["resource_id"].lower() != match["resource_id_hex"]
                or fingerprint["sha256"].lower() != match["sha256"]
            ):
                failures.append(
                    {"asset_id": match["asset_id"], "reason": "fingerprint_mismatch"}
                )
            else:
                resource_identifier_verified_count += 1
        after_counts = fact_counts(
            connection, [match["asset_id"] for match in plan["matches"]]
        )
        fact_counts_match = after_counts == plan["preserved_fact_counts"]
        report = {
            "schema_version": 1,
            "database_sha256": sha256_file(database),
            "integrity_check": integrity,
            "foreign_key_violations": foreign_keys,
            "verified_asset_count": len(plan["matches"]) - len(failures),
            "resource_identifier_verified_count": resource_identifier_verified_count,
            "failures": failures,
            "preserved_fact_counts_before": plan["preserved_fact_counts"],
            "preserved_fact_counts_after": after_counts,
            "preserved_fact_counts_match": fact_counts_match,
            "status": (
                "passed"
                if integrity == "ok" and not foreign_keys and not failures and fact_counts_match
                else "failed"
            ),
        }
    finally:
        connection.close()
    atomic_write_json(output, report)
    if report["status"] != "passed":
        raise BridgeError("verification_failed", "migrated database verification failed")
    print(f"verified={report['verified_asset_count']}")
    return 0


def snapshot_database(arguments: argparse.Namespace) -> int:
    source = Path(arguments.database).resolve()
    destination = Path(arguments.output).resolve()
    backup_database(source, destination)
    connection = open_read_only_database(destination)
    try:
        quick_check = connection.execute("PRAGMA quick_check").fetchone()[0]
    finally:
        connection.close()
    if quick_check != "ok":
        destination.unlink(missing_ok=True)
        raise BridgeError("quick_check_failed", "database snapshot failed quick_check")
    print("snapshot=1 quick_check=ok")
    return 0


def list_sources(arguments: argparse.Namespace) -> int:
    database = Path(arguments.database).resolve()
    output = Path(arguments.output)
    if output.exists():
        raise BridgeError("output_exists", "source report output already exists")
    require_standalone_snapshot(database)
    connection = open_read_only_database(database)
    try:
        require_catalog_schema(connection)
        sources: list[dict[str, Any]] = []
        for row in connection.execute(
            "SELECT id, kind, display_name, state, scan_generation, dirty_epoch "
            "FROM source ORDER BY created_at_ms, id"
        ):
            counts = connection.execute(
                "SELECT locator_kind, COUNT(*) AS count FROM asset "
                "WHERE source_id = ? AND locator_state = 'current' GROUP BY locator_kind",
                (row["id"],),
            ).fetchall()
            sources.append(
                {
                    "id": row["id"],
                    "kind": row["kind"],
                    "display_name": row["display_name"],
                    "state": row["state"],
                    "scan_generation": row["scan_generation"],
                    "dirty_epoch": row["dirty_epoch"],
                    "current_asset_counts": {
                        count["locator_kind"]: count["count"] for count in counts
                    },
                }
            )
        report = {"schema_version": 1, "sources": sources}
    finally:
        connection.close()
    atomic_write_json(output, report)
    folder_count = sum(source["kind"] == "folder" for source in sources)
    photos_count = sum(source["kind"] == "photos" for source in sources)
    print(f"sources={len(sources)} folders={folder_count} photos={photos_count}")
    return 0


def package_snapshot(arguments: argparse.Namespace) -> int:
    database = Path(arguments.database).resolve()
    backups_directory = Path(arguments.backups_directory).resolve()
    verification_path = Path(arguments.verification)
    descriptor_output = Path(arguments.output)
    if descriptor_output.exists():
        raise BridgeError("output_exists", "snapshot descriptor already exists")
    if not arguments.app_version.strip():
        raise BridgeError("invalid_app_version", "snapshot app version cannot be empty")
    if not backups_directory.is_dir() or backups_directory.is_symlink():
        raise BridgeError("invalid_backups_directory", "backups directory is not safe")
    require_standalone_snapshot(database)
    try:
        verification = json.loads(verification_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BridgeError("invalid_verification", "verification report cannot be read") from error
    if (
        not isinstance(verification, dict)
        or verification.get("status") != "passed"
        or verification.get("database_sha256") != sha256_file(database)
    ):
        raise BridgeError("invalid_verification", "verification does not bind this database")

    snapshot_id = str(uuid.uuid4())
    temporary_directory = backups_directory / f"{snapshot_id}.tmp"
    final_directory = backups_directory / snapshot_id
    if temporary_directory.exists() or final_directory.exists():
        raise BridgeError("snapshot_collision", "snapshot destination already exists")
    temporary_directory.mkdir()
    try:
        snapshot_database = temporary_directory / "ImageAll.sqlite"
        shutil.copyfile(database, snapshot_database)
        with snapshot_database.open("rb") as stream:
            os.fsync(stream.fileno())
        connection = open_read_only_database(snapshot_database)
        try:
            integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
            foreign_key_violation = connection.execute("PRAGMA foreign_key_check").fetchone()
            if not table_exists(connection, "grdb_migrations"):
                raise BridgeError(
                    "unsupported_catalog_schema", "GRDB migration history is missing"
                )
            applied_migrations = [
                row[0]
                for row in connection.execute(
                    "SELECT identifier FROM grdb_migrations ORDER BY rowid"
                )
            ]
        finally:
            connection.close()
        if integrity != "ok":
            raise BridgeError("integrity_check_failed", "snapshot database is not integral")
        if foreign_key_violation is not None:
            raise BridgeError("foreign_key_check_failed", "snapshot database has FK errors")
        if (
            not applied_migrations
            or applied_migrations
            != list(KNOWN_IMAGEALL_MIGRATIONS[: len(applied_migrations)])
        ):
            raise BridgeError(
                "unsupported_migration_history", "database migration history is not supported"
            )
        database_size = snapshot_database.stat().st_size
        database_sha256 = sha256_file(snapshot_database)
        manifest = {
            "format_version": 1,
            "snapshot_id": snapshot_id,
            "created_at_ms": int(time.time() * 1000),
            "app_version": arguments.app_version,
            "applied_migrations": applied_migrations,
            "database_filename": "ImageAll.sqlite",
            "database_bytes": database_size,
            "database_sha256": database_sha256,
        }
        atomic_write_json(temporary_directory / "manifest.json", manifest)
        os.rename(temporary_directory, final_directory)
    except Exception:
        if temporary_directory.exists():
            shutil.rmtree(temporary_directory)
        raise
    descriptor = {
        "schema_version": 1,
        "snapshot_id": snapshot_id,
        "snapshot_directory": str(final_directory),
        "database_sha256": database_sha256,
    }
    atomic_write_json(descriptor_output, descriptor)
    print("snapshot_packaged=1")
    return 0


def converge_live_database(path: Path) -> None:
    connection = sqlite3.connect(path)
    try:
        checkpoint = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        if checkpoint is None or checkpoint[0] != 0:
            raise BridgeError("checkpoint_failed", "live database WAL did not checkpoint")
        journal_mode = connection.execute("PRAGMA journal_mode = DELETE").fetchone()[0]
        if str(journal_mode).lower() != "delete":
            raise BridgeError(
                "sidecar_convergence_failed",
                "live database did not converge to DELETE journal mode",
            )
        connection.commit()
    finally:
        connection.close()
    for sidecar in (Path(f"{path}-wal"), Path(f"{path}-shm"), Path(f"{path}-journal")):
        if sidecar.exists():
            sidecar.unlink()


def acquire_catalog_lock(lock_file: Path) -> int:
    lock_file.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(lock_file, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as error:
        os.close(descriptor)
        raise BridgeError("imageall_running", "ImageAll still owns the catalog lock") from error
    return descriptor


def install_verified_database(arguments: argparse.Namespace) -> int:
    database = Path(arguments.database).resolve()
    verification_path = Path(arguments.verification)
    live_database = Path(arguments.live_database).resolve()
    backups_directory = Path(arguments.backups_directory).resolve()
    report_output = Path(arguments.output)
    if report_output.exists():
        raise BridgeError("output_exists", "installation report already exists")
    if not arguments.app_version.strip():
        raise BridgeError("invalid_app_version", "snapshot app version cannot be empty")
    catalog_directory = live_database.parent
    application_support_directory = catalog_directory.parent
    if (
        live_database.name != "ImageAll.sqlite"
        or catalog_directory.name != "Catalog"
        or backups_directory.name != "Backups"
        or backups_directory.parent != application_support_directory
        or not live_database.is_file()
        or live_database.is_symlink()
        or not database.is_file()
        or database.is_symlink()
        or not backups_directory.is_dir()
        or backups_directory.is_symlink()
    ):
        raise BridgeError("unsafe_install_target", "installation paths are not ImageAll paths")
    require_standalone_snapshot(database)
    try:
        verification = json.loads(verification_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BridgeError("invalid_verification", "verification report cannot be read") from error
    candidate_sha256 = sha256_file(database)
    if (
        not isinstance(verification, dict)
        or verification.get("status") != "passed"
        or verification.get("database_sha256") != candidate_sha256
    ):
        raise BridgeError("invalid_verification", "verification does not bind this database")

    lock_file = application_support_directory / "Runtime" / "catalog.lock"
    lock_descriptor = acquire_catalog_lock(lock_file)
    operation_id = str(uuid.uuid4())
    staging_directory = catalog_directory / f".photos-exit-install-{operation_id}.tmp"
    previous_database = catalog_directory / f".photos-exit-previous-{operation_id}.sqlite"
    try:
        converge_live_database(live_database)
        require_standalone_snapshot(live_database)
        rollback_descriptor_path = report_output.with_name(
            f".{report_output.name}.{operation_id}.rollback.json"
        )
        rollback_arguments = argparse.Namespace(
            database=str(live_database),
            verification=str(verification_path),
            backups_directory=str(backups_directory),
            app_version=f"{arguments.app_version}-pre-install-rollback",
            output=str(rollback_descriptor_path),
        )
        # The live database is not the migrated candidate, so publish its rollback
        # snapshot with a locally bound temporary verification record.
        live_verification_path = report_output.with_name(
            f".{report_output.name}.{operation_id}.live-verification.json"
        )
        live_sha256 = sha256_file(live_database)
        atomic_write_json(
            live_verification_path,
            {"status": "passed", "database_sha256": live_sha256},
        )
        rollback_arguments.verification = str(live_verification_path)
        try:
            package_snapshot(rollback_arguments)
            rollback_descriptor = json.loads(
                rollback_descriptor_path.read_text(encoding="utf-8")
            )
        finally:
            live_verification_path.unlink(missing_ok=True)
            rollback_descriptor_path.unlink(missing_ok=True)

        staging_directory.mkdir()
        staged_database = staging_directory / "ImageAll.sqlite"
        shutil.copyfile(database, staged_database)
        with staged_database.open("rb") as stream:
            os.fsync(stream.fileno())
        if sha256_file(staged_database) != candidate_sha256:
            raise BridgeError("candidate_copy_mismatch", "staged database hash changed")
        staged_connection = open_read_only_database(staged_database)
        try:
            if staged_connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise BridgeError("integrity_check_failed", "staged database is not integral")
            if staged_connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
                raise BridgeError("foreign_key_check_failed", "staged database has FK errors")
        finally:
            staged_connection.close()

        os.rename(live_database, previous_database)
        try:
            os.rename(staged_database, live_database)
            directory_descriptor = os.open(catalog_directory, os.O_RDONLY)
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
            if sha256_file(live_database) != candidate_sha256:
                raise BridgeError("post_install_hash_mismatch", "installed database hash changed")
            installed_connection = open_read_only_database(live_database)
            try:
                if installed_connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                    raise BridgeError(
                        "post_install_integrity_failed",
                        "installed database is not integral",
                    )
                if installed_connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
                    raise BridgeError(
                        "post_install_foreign_key_failed",
                        "installed database has FK errors",
                    )
            finally:
                installed_connection.close()
        except Exception:
            failed_database = staging_directory / "failed-ImageAll.sqlite"
            if live_database.exists():
                os.rename(live_database, failed_database)
            os.rename(previous_database, live_database)
            raise
        staging_directory.rmdir()
        report = {
            "schema_version": 1,
            "status": "installed",
            "installed_database": str(live_database),
            "installed_database_sha256": candidate_sha256,
            "previous_database": str(previous_database),
            "previous_database_sha256": live_sha256,
            "rollback_snapshot_id": rollback_descriptor["snapshot_id"],
            "rollback_snapshot_directory": rollback_descriptor["snapshot_directory"],
        }
        atomic_write_json(report_output, report)
    finally:
        fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        os.close(lock_descriptor)
    print("installed=1 rollback_snapshot=1")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Preserve ImageAll asset identity after a PhotoKit export."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    snapshot = subparsers.add_parser("snapshot", help="create a consistent SQLite copy")
    snapshot.add_argument("--database", required=True)
    snapshot.add_argument("--output", required=True)
    snapshot.set_defaults(operation=snapshot_database)

    sources = subparsers.add_parser(
        "list-sources", help="write a private source-ID report from a snapshot"
    )
    sources.add_argument("--database", required=True)
    sources.add_argument("--output", required=True)
    sources.set_defaults(operation=list_sources)

    package = subparsers.add_parser(
        "package-snapshot", help="publish a verified database as a native ImageAll snapshot"
    )
    package.add_argument("--database", required=True)
    package.add_argument("--verification", required=True)
    package.add_argument("--backups-directory", required=True)
    package.add_argument("--app-version", required=True)
    package.add_argument("--output", required=True)
    package.set_defaults(operation=package_snapshot)

    install = subparsers.add_parser(
        "install", help="atomically install a verified database with native rollback"
    )
    install.add_argument("--database", required=True)
    install.add_argument("--verification", required=True)
    install.add_argument("--live-database", required=True)
    install.add_argument("--backups-directory", required=True)
    install.add_argument("--app-version", required=True)
    install.add_argument("--output", required=True)
    install.set_defaults(operation=install_verified_database)

    plan = subparsers.add_parser("plan", help="create a read-only identity migration plan")
    plan.add_argument("--database", required=True)
    plan.add_argument("--manifest", required=True)
    plan.add_argument("--export-root", required=True)
    plan.add_argument("--destination-source-id", required=True)
    plan.add_argument("--output", required=True)
    plan.set_defaults(operation=create_plan)

    migrate = subparsers.add_parser("migrate", help="create a migrated database copy")
    migrate.add_argument("--database", required=True)
    migrate.add_argument("--plan", required=True)
    migrate.add_argument("--output", required=True)
    migrate.set_defaults(operation=migrate_database)

    verify = subparsers.add_parser("verify", help="verify a migrated database copy")
    verify.add_argument("--database", required=True)
    verify.add_argument("--plan", required=True)
    verify.add_argument("--output", required=True)
    verify.set_defaults(operation=verify_database)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    parser = build_parser()
    arguments = parser.parse_args(argv)
    try:
        return int(arguments.operation(arguments))
    except BridgeError as error:
        print(f"error={error.code}", file=sys.stderr)
        return 2
    except (OSError, sqlite3.Error, ValueError, KeyError, TypeError):
        print("error=unexpected_input_or_database_failure", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
