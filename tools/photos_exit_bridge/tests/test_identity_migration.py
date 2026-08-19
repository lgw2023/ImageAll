import hashlib
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path


TOOL = Path(__file__).parents[1] / "photos_exit_bridge.py"
BUILD_EXPORTER = Path(__file__).parents[1] / "build_photokit_exporter.sh"


class IdentityMigrationCLITests(unittest.TestCase):
    def test_photokit_exporter_builds_and_help_does_not_access_photos(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            build = subprocess.run(
                [str(BUILD_EXPORTER), temporary_directory],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(build.returncode, 0, build.stderr)
            executable = (
                Path(temporary_directory)
                / "Photos Exit Exporter.app"
                / "Contents"
                / "MacOS"
                / "photos-exit-exporter"
            )
            help_result = subprocess.run(
                [str(executable), "--help"],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(help_result.returncode, 0, help_result.stderr)
            self.assertIn("inventory", help_result.stdout)
            self.assertIn("export", help_result.stdout)

    def test_unique_export_preserves_asset_identity_and_user_facts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            database = root / "catalog.sqlite"
            export_root = root / "export"
            export_root.mkdir()
            primary = export_root / "assets" / "fixture" / "001-photo.jpg"
            primary.parent.mkdir(parents=True)
            primary.write_bytes(b"synthetic-photo-bytes")

            photos_source_id = str(uuid.uuid4())
            folder_source_id = str(uuid.uuid4())
            asset_id = str(uuid.uuid4())
            tag_id = str(uuid.uuid4())
            local_identifier = "fixture-local-identifier/L0/001"
            self._create_catalog(
                database,
                photos_source_id=photos_source_id,
                folder_source_id=folder_source_id,
                asset_id=asset_id,
                tag_id=tag_id,
                local_identifier=local_identifier,
            )

            manifest = root / "manifest.jsonl"
            manifest.write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "record_type": "header",
                                "schema_version": 1,
                                "exporter": "fixture",
                            }
                        ),
                        json.dumps(
                            {
                                "record_type": "asset",
                                "schema_version": 1,
                                "local_identifier": local_identifier,
                                "status": "complete",
                                "primary_resource_index": 1,
                                "resources": [
                                    {
                                        "index": 1,
                                        "type": "photo",
                                        "relative_path": "assets/fixture/001-photo.jpg",
                                        "byte_size": primary.stat().st_size,
                                        "sha256": hashlib.sha256(primary.read_bytes()).hexdigest(),
                                    }
                                ],
                            }
                        ),
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            plan = root / "plan.json"
            result = self._run(
                "plan",
                "--database",
                str(database),
                "--manifest",
                str(manifest),
                "--export-root",
                str(export_root),
                "--destination-source-id",
                folder_source_id,
                "--output",
                str(plan),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("matched=1", result.stdout)

            migrated = root / "migrated.sqlite"
            result = self._run(
                "migrate",
                "--database",
                str(database),
                "--plan",
                str(plan),
                "--output",
                str(migrated),
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            connection = sqlite3.connect(migrated)
            connection.row_factory = sqlite3.Row
            asset = connection.execute(
                "SELECT * FROM asset WHERE id = ?", (asset_id,)
            ).fetchone()
            self.assertEqual(asset["source_id"], folder_source_id)
            self.assertEqual(asset["locator_kind"], "file")
            self.assertEqual(asset["relative_path"], "assets/fixture/001-photo.jpg")
            self.assertIsNone(asset["photos_local_identifier"])
            self.assertEqual(asset["availability"], "available")
            self.assertEqual(
                connection.execute(
                    "SELECT COUNT(*) FROM asset_tag_decision WHERE asset_id = ?",
                    (asset_id,),
                ).fetchone()[0],
                1,
            )
            favorite = connection.execute(
                "SELECT desired_value, sync_status, photos_observed_value "
                "FROM asset_favorite_state WHERE asset_id = ?",
                (asset_id,),
            ).fetchone()
            self.assertEqual(tuple(favorite), (1, "localOnly", None))
            self.assertEqual(
                connection.execute(
                    "SELECT COUNT(*) FROM personal_model_sample WHERE asset_id = ?",
                    (asset_id,),
                ).fetchone()[0],
                1,
            )
            self.assertEqual(
                connection.execute(
                    "SELECT COUNT(*) FROM recycle_entry WHERE asset_id = ?",
                    (asset_id,),
                ).fetchone()[0],
                1,
            )
            fingerprint = connection.execute(
                "SELECT size_bytes, hex(sha256) FROM file_fingerprint WHERE asset_id = ?",
                (asset_id,),
            ).fetchone()
            self.assertEqual(fingerprint[0], primary.stat().st_size)
            self.assertEqual(
                fingerprint[1].lower(), hashlib.sha256(primary.read_bytes()).hexdigest()
            )
            connection.close()

            verification = root / "verification.json"
            result = self._run(
                "verify",
                "--database",
                str(migrated),
                "--plan",
                str(plan),
                "--output",
                str(verification),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("verified=1", result.stdout)

    def test_hash_mismatch_blocks_migration_without_modifying_input(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            database = root / "catalog.sqlite"
            export_root = root / "export"
            primary = export_root / "assets" / "fixture" / "001-photo.jpg"
            primary.parent.mkdir(parents=True)
            primary.write_bytes(b"synthetic-photo-bytes")
            photos_source_id = str(uuid.uuid4())
            folder_source_id = str(uuid.uuid4())
            asset_id = str(uuid.uuid4())
            local_identifier = "hash-mismatch/L0/001"
            self._create_catalog(
                database,
                photos_source_id=photos_source_id,
                folder_source_id=folder_source_id,
                asset_id=asset_id,
                tag_id=str(uuid.uuid4()),
                local_identifier=local_identifier,
            )
            database_before = database.read_bytes()
            manifest = root / "manifest.jsonl"
            manifest.write_text(
                json.dumps(
                    {"record_type": "header", "schema_version": 1, "exporter": "fixture"}
                )
                + "\n"
                + json.dumps(
                    {
                        "record_type": "asset",
                        "schema_version": 1,
                        "local_identifier": local_identifier,
                        "status": "complete",
                        "primary_resource_index": 1,
                        "resources": [
                            {
                                "index": 1,
                                "type": "photo",
                                "relative_path": "assets/fixture/001-photo.jpg",
                                "byte_size": primary.stat().st_size,
                                "sha256": "0" * 64,
                            }
                        ],
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            plan = root / "plan.json"
            result = self._run(
                "plan",
                "--database",
                str(database),
                "--manifest",
                str(manifest),
                "--export-root",
                str(export_root),
                "--destination-source-id",
                folder_source_id,
                "--output",
                str(plan),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(plan.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "blocked")
            self.assertEqual(report["matches"], [])
            self.assertEqual(report["unresolved"][0]["reason"], "export_hash_mismatch")
            self.assertNotIn(local_identifier, result.stdout + result.stderr)

            migrated = root / "migrated.sqlite"
            result = self._run(
                "migrate",
                "--database",
                str(database),
                "--plan",
                str(plan),
                "--output",
                str(migrated),
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("error=plan_blocked", result.stderr)
            self.assertFalse(migrated.exists())
            self.assertEqual(database.read_bytes(), database_before)

    def test_active_recycle_lifecycle_blocks_identity_migration(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            database = root / "catalog.sqlite"
            export_root, primary, manifest = self._make_complete_export(root, "active-recycle")
            photos_source_id = str(uuid.uuid4())
            folder_source_id = str(uuid.uuid4())
            asset_id = str(uuid.uuid4())
            local_identifier = "active-recycle/L0/001"
            self._create_catalog(
                database,
                photos_source_id=photos_source_id,
                folder_source_id=folder_source_id,
                asset_id=asset_id,
                tag_id=str(uuid.uuid4()),
                local_identifier=local_identifier,
            )
            connection = sqlite3.connect(database)
            connection.execute(
                "UPDATE recycle_entry SET state = 'recycled' WHERE asset_id = ?", (asset_id,)
            )
            connection.commit()
            connection.close()
            self._write_complete_manifest(
                manifest, local_identifier=local_identifier, primary=primary, export_root=export_root
            )

            plan = root / "plan.json"
            result = self._run(
                "plan",
                "--database",
                str(database),
                "--manifest",
                str(manifest),
                "--export-root",
                str(export_root),
                "--destination-source-id",
                folder_source_id,
                "--output",
                str(plan),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(plan.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "blocked")
            self.assertEqual(report["unresolved"][0]["reason"], "active_recycle")

    def test_existing_destination_locator_blocks_identity_migration(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            database = root / "catalog.sqlite"
            export_root, primary, manifest = self._make_complete_export(root, "locator-conflict")
            photos_source_id = str(uuid.uuid4())
            folder_source_id = str(uuid.uuid4())
            asset_id = str(uuid.uuid4())
            local_identifier = "locator-conflict/L0/001"
            self._create_catalog(
                database,
                photos_source_id=photos_source_id,
                folder_source_id=folder_source_id,
                asset_id=asset_id,
                tag_id=str(uuid.uuid4()),
                local_identifier=local_identifier,
            )
            relative_path = primary.relative_to(export_root).as_posix()
            connection = sqlite3.connect(database)
            now = 1_700_000_000_000
            connection.execute(
                "INSERT INTO asset VALUES (?, ?, 'file', ?, NULL, 'current', "
                "'public.jpeg', 'image', 10, 10, ?, ?, NULL, 1, 0, 'available', ?, ?, ?)",
                (
                    str(uuid.uuid4()),
                    folder_source_id,
                    relative_path,
                    now,
                    now,
                    now,
                    now,
                    primary.name,
                ),
            )
            connection.commit()
            connection.close()
            self._write_complete_manifest(
                manifest, local_identifier=local_identifier, primary=primary, export_root=export_root
            )

            plan = root / "plan.json"
            result = self._run(
                "plan",
                "--database",
                str(database),
                "--manifest",
                str(manifest),
                "--export-root",
                str(export_root),
                "--destination-source-id",
                folder_source_id,
                "--output",
                str(plan),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(plan.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "blocked")
            self.assertEqual(
                report["unresolved"][0]["reason"], "destination_locator_conflict"
            )

    def test_exported_asset_without_imageall_identity_does_not_block_existing_match(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            database = root / "catalog.sqlite"
            export_root, primary, manifest = self._make_complete_export(root, "known")
            unknown = export_root / "assets" / "unknown" / "001-photo.jpg"
            unknown.parent.mkdir(parents=True)
            unknown.write_bytes(b"another-synthetic-photo")
            photos_source_id = str(uuid.uuid4())
            folder_source_id = str(uuid.uuid4())
            asset_id = str(uuid.uuid4())
            local_identifier = "known/L0/001"
            self._create_catalog(
                database,
                photos_source_id=photos_source_id,
                folder_source_id=folder_source_id,
                asset_id=asset_id,
                tag_id=str(uuid.uuid4()),
                local_identifier=local_identifier,
            )
            self._write_complete_manifest(
                manifest, local_identifier=local_identifier, primary=primary, export_root=export_root
            )
            with manifest.open("a", encoding="utf-8") as stream:
                stream.write(
                    json.dumps(
                        {
                            "record_type": "asset",
                            "schema_version": 1,
                            "local_identifier": "not-in-imageall/L0/001",
                            "status": "complete",
                            "primary_resource_index": 0,
                            "resources": [
                                {
                                    "index": 0,
                                    "type": "photo",
                                    "relative_path": unknown.relative_to(export_root).as_posix(),
                                    "byte_size": unknown.stat().st_size,
                                    "sha256": hashlib.sha256(unknown.read_bytes()).hexdigest(),
                                }
                            ],
                        }
                    )
                    + "\n"
                )

            plan = root / "plan.json"
            result = self._run(
                "plan",
                "--database",
                str(database),
                "--manifest",
                str(manifest),
                "--export-root",
                str(export_root),
                "--destination-source-id",
                folder_source_id,
                "--output",
                str(plan),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(plan.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "ready")
            self.assertEqual(len(report["matches"]), 1)
            self.assertEqual(report["unresolved"], [])
            self.assertEqual(report["exported_without_catalog_identity_count"], 1)

    def test_missing_photos_tombstone_is_retained_without_blocking_available_asset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            database = root / "catalog.sqlite"
            export_root, primary, manifest = self._make_complete_export(root, "available")
            photos_source_id = str(uuid.uuid4())
            folder_source_id = str(uuid.uuid4())
            available_asset_id = str(uuid.uuid4())
            local_identifier = "available/L0/001"
            self._create_catalog(
                database,
                photos_source_id=photos_source_id,
                folder_source_id=folder_source_id,
                asset_id=available_asset_id,
                tag_id=str(uuid.uuid4()),
                local_identifier=local_identifier,
            )
            missing_asset_id = str(uuid.uuid4())
            now = 1_700_000_000_000
            connection = sqlite3.connect(database)
            connection.execute(
                "INSERT INTO asset VALUES (?, ?, 'photos', NULL, ?, 'current', "
                "'public.jpeg', 'image', 10, 10, ?, ?, NULL, 1, 0, 'missing', ?, ?, NULL)",
                (
                    missing_asset_id,
                    photos_source_id,
                    "deleted-from-photos/L0/001",
                    now,
                    now,
                    now,
                    now,
                ),
            )
            connection.commit()
            connection.close()
            self._write_complete_manifest(
                manifest, local_identifier=local_identifier, primary=primary, export_root=export_root
            )

            plan = root / "plan.json"
            result = self._run(
                "plan",
                "--database",
                str(database),
                "--manifest",
                str(manifest),
                "--export-root",
                str(export_root),
                "--destination-source-id",
                folder_source_id,
                "--output",
                str(plan),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(plan.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "ready")
            self.assertEqual(report["unresolved"], [])
            self.assertEqual(report["retained_unavailable_tombstone_count"], 1)

    def test_resumed_manifest_uses_later_complete_record(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            database = root / "catalog.sqlite"
            export_root, primary, manifest = self._make_complete_export(root, "resumed")
            photos_source_id = str(uuid.uuid4())
            folder_source_id = str(uuid.uuid4())
            local_identifier = "resumed/L0/001"
            self._create_catalog(
                database,
                photos_source_id=photos_source_id,
                folder_source_id=folder_source_id,
                asset_id=str(uuid.uuid4()),
                tag_id=str(uuid.uuid4()),
                local_identifier=local_identifier,
            )
            manifest.write_text(
                json.dumps(
                    {"record_type": "header", "schema_version": 1, "exporter": "fixture"}
                )
                + "\n"
                + json.dumps(
                    {
                        "record_type": "asset",
                        "schema_version": 1,
                        "local_identifier": local_identifier,
                        "status": "incomplete",
                        "primary_resource_index": 0,
                        "resources": [],
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            complete_record = {
                "record_type": "asset",
                "schema_version": 1,
                "local_identifier": local_identifier,
                "status": "complete",
                "primary_resource_index": 0,
                "resources": [
                    {
                        "index": 0,
                        "type": "photo",
                        "relative_path": primary.relative_to(export_root).as_posix(),
                        "byte_size": primary.stat().st_size,
                        "sha256": hashlib.sha256(primary.read_bytes()).hexdigest(),
                    }
                ],
            }
            with manifest.open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(complete_record) + "\n")

            plan = root / "plan.json"
            result = self._run(
                "plan",
                "--database",
                str(database),
                "--manifest",
                str(manifest),
                "--export-root",
                str(export_root),
                "--destination-source-id",
                folder_source_id,
                "--output",
                str(plan),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(plan.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "ready")
            self.assertEqual(len(report["matches"]), 1)

    def test_source_similarity_membership_is_invalidated_when_asset_changes_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            database = root / "catalog.sqlite"
            export_root, primary, manifest = self._make_complete_export(root, "similarity")
            photos_source_id = str(uuid.uuid4())
            folder_source_id = str(uuid.uuid4())
            asset_id = str(uuid.uuid4())
            local_identifier = "similarity/L0/001"
            self._create_catalog(
                database,
                photos_source_id=photos_source_id,
                folder_source_id=folder_source_id,
                asset_id=asset_id,
                tag_id=str(uuid.uuid4()),
                local_identifier=local_identifier,
            )
            connection = sqlite3.connect(database)
            connection.executescript(
                """
                CREATE TABLE source_similarity_index (
                    source_id TEXT NOT NULL,
                    media_kind TEXT NOT NULL,
                    state TEXT NOT NULL,
                    job_id TEXT,
                    built_at_ms INTEGER,
                    updated_at_ms INTEGER NOT NULL,
                    last_error TEXT,
                    PRIMARY KEY(source_id, media_kind)
                );
                CREATE TABLE source_similarity_bucket_member (
                    source_id TEXT NOT NULL,
                    media_kind TEXT NOT NULL,
                    asset_id TEXT NOT NULL REFERENCES asset(id),
                    content_revision INTEGER NOT NULL,
                    bucket_key INTEGER NOT NULL,
                    cluster_id TEXT,
                    PRIMARY KEY(source_id, media_kind, asset_id)
                );
                """
            )
            now = 1_700_000_000_000
            connection.executemany(
                "INSERT INTO source_similarity_index VALUES (?, 'image', 'ready', NULL, ?, ?, NULL)",
                [
                    (photos_source_id, now, now),
                    (folder_source_id, now, now),
                ],
            )
            connection.execute(
                "INSERT INTO source_similarity_bucket_member "
                "VALUES (?, 'image', ?, 3, 1, NULL)",
                (photos_source_id, asset_id),
            )
            connection.commit()
            connection.close()
            self._write_complete_manifest(
                manifest, local_identifier=local_identifier, primary=primary, export_root=export_root
            )
            plan = root / "plan.json"
            self.assertEqual(
                self._run(
                    "plan",
                    "--database",
                    str(database),
                    "--manifest",
                    str(manifest),
                    "--export-root",
                    str(export_root),
                    "--destination-source-id",
                    folder_source_id,
                    "--output",
                    str(plan),
                ).returncode,
                0,
            )
            migrated = root / "migrated.sqlite"
            result = self._run(
                "migrate",
                "--database",
                str(database),
                "--plan",
                str(plan),
                "--output",
                str(migrated),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            connection = sqlite3.connect(migrated)
            self.assertEqual(
                connection.execute(
                    "SELECT COUNT(*) FROM source_similarity_bucket_member WHERE asset_id = ?",
                    (asset_id,),
                ).fetchone()[0],
                0,
            )
            self.assertEqual(
                set(
                    row[0]
                    for row in connection.execute(
                        "SELECT state FROM source_similarity_index "
                        "WHERE source_id IN (?, ?)",
                        (photos_source_id, folder_source_id),
                    )
                ),
                {"stale"},
            )
            connection.close()

    def test_verified_database_can_be_packaged_as_native_imageall_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            database = root / "migrated.sqlite"
            self._create_catalog(
                database,
                photos_source_id=str(uuid.uuid4()),
                folder_source_id=str(uuid.uuid4()),
                asset_id=str(uuid.uuid4()),
                tag_id=str(uuid.uuid4()),
                local_identifier="snapshot/L0/001",
            )
            connection = sqlite3.connect(database)
            connection.execute("CREATE TABLE grdb_migrations(identifier TEXT PRIMARY KEY)")
            connection.executemany(
                "INSERT INTO grdb_migrations VALUES (?)",
                [("v001_create_catalog_core",), ("v002_add_stage_1_catalog_query_support",)],
            )
            connection.commit()
            connection.close()
            backups = root / "Backups"
            backups.mkdir()
            verification = root / "verification.json"
            verification.write_text(
                json.dumps(
                    {
                        "status": "passed",
                        "database_sha256": hashlib.sha256(database.read_bytes()).hexdigest(),
                    }
                ),
                encoding="utf-8",
            )
            descriptor = root / "snapshot-descriptor.json"
            result = self._run(
                "package-snapshot",
                "--database",
                str(database),
                "--backups-directory",
                str(backups),
                "--verification",
                str(verification),
                "--app-version",
                "photos-exit-test",
                "--output",
                str(descriptor),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(descriptor.read_text(encoding="utf-8"))
            snapshot = backups / report["snapshot_id"]
            manifest = json.loads((snapshot / "manifest.json").read_text(encoding="utf-8"))
            snapshot_database = snapshot / "ImageAll.sqlite"
            self.assertEqual(manifest["format_version"], 1)
            self.assertEqual(manifest["snapshot_id"], report["snapshot_id"])
            self.assertEqual(manifest["database_filename"], "ImageAll.sqlite")
            self.assertEqual(
                manifest["applied_migrations"],
                ["v001_create_catalog_core", "v002_add_stage_1_catalog_query_support"],
            )
            self.assertEqual(
                manifest["database_sha256"],
                hashlib.sha256(snapshot_database.read_bytes()).hexdigest(),
            )

    def test_snapshot_converges_live_wal_database_to_standalone_copy(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            database = root / "live.sqlite"
            self._create_catalog(
                database,
                photos_source_id=str(uuid.uuid4()),
                folder_source_id=str(uuid.uuid4()),
                asset_id=str(uuid.uuid4()),
                tag_id=str(uuid.uuid4()),
                local_identifier="wal/L0/001",
            )
            live = sqlite3.connect(database)
            self.assertEqual(live.execute("PRAGMA journal_mode=WAL").fetchone()[0], "wal")
            live.execute("UPDATE source SET dirty_epoch = dirty_epoch + 1")
            live.commit()

            snapshot = root / "snapshot.sqlite"
            result = self._run(
                "snapshot", "--database", str(database), "--output", str(snapshot)
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(Path(f"{snapshot}-wal").exists())
            self.assertFalse(Path(f"{snapshot}-shm").exists())
            self.assertFalse(Path(f"{snapshot}-journal").exists())
            source_report = root / "sources.json"
            result = self._run(
                "list-sources",
                "--database",
                str(snapshot),
                "--output",
                str(source_report),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            live.close()

    def _run(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(TOOL), *arguments],
            text=True,
            capture_output=True,
            check=False,
        )

    def _make_complete_export(
        self, root: Path, directory_name: str
    ) -> tuple[Path, Path, Path]:
        export_root = root / "export"
        primary = export_root / "assets" / directory_name / "001-photo.jpg"
        primary.parent.mkdir(parents=True)
        primary.write_bytes(b"synthetic-photo-bytes")
        return export_root, primary, root / "manifest.jsonl"

    def _write_complete_manifest(
        self,
        manifest: Path,
        *,
        local_identifier: str,
        primary: Path,
        export_root: Path,
    ) -> None:
        manifest.write_text(
            json.dumps(
                {"record_type": "header", "schema_version": 1, "exporter": "fixture"}
            )
            + "\n"
            + json.dumps(
                {
                    "record_type": "asset",
                    "schema_version": 1,
                    "local_identifier": local_identifier,
                    "status": "complete",
                    "primary_resource_index": 1,
                    "resources": [
                        {
                            "index": 1,
                            "type": "photo",
                            "relative_path": primary.relative_to(export_root).as_posix(),
                            "byte_size": primary.stat().st_size,
                            "sha256": hashlib.sha256(primary.read_bytes()).hexdigest(),
                        }
                    ],
                }
            )
            + "\n",
            encoding="utf-8",
        )

    def _create_catalog(
        self,
        database: Path,
        *,
        photos_source_id: str,
        folder_source_id: str,
        asset_id: str,
        tag_id: str,
        local_identifier: str,
    ) -> None:
        connection = sqlite3.connect(database)
        connection.executescript(
            """
            PRAGMA foreign_keys = ON;
            CREATE TABLE source (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                display_name TEXT NOT NULL,
                bookmark BLOB,
                scan_generation INTEGER NOT NULL DEFAULT 0,
                dirty_epoch INTEGER NOT NULL DEFAULT 0,
                state TEXT NOT NULL,
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL
            );
            CREATE TABLE asset (
                id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL REFERENCES source(id),
                locator_kind TEXT NOT NULL,
                relative_path TEXT,
                photos_local_identifier TEXT,
                locator_state TEXT NOT NULL,
                media_type TEXT NOT NULL,
                media_kind TEXT NOT NULL DEFAULT 'image',
                width INTEGER,
                height INTEGER,
                media_created_at_ms INTEGER,
                media_modified_at_ms INTEGER,
                duration_ms INTEGER,
                content_revision INTEGER NOT NULL,
                last_seen_generation INTEGER,
                availability TEXT NOT NULL,
                record_created_at_ms INTEGER NOT NULL,
                record_updated_at_ms INTEGER NOT NULL,
                file_name TEXT
            );
            CREATE UNIQUE INDEX asset_current_file_locator_uq
                ON asset(source_id, relative_path)
                WHERE locator_kind = 'file' AND locator_state = 'current';
            CREATE UNIQUE INDEX asset_current_photos_locator_uq
                ON asset(source_id, photos_local_identifier)
                WHERE locator_kind = 'photos' AND locator_state = 'current';
            CREATE TABLE file_fingerprint (
                asset_id TEXT PRIMARY KEY REFERENCES asset(id) ON DELETE CASCADE,
                size_bytes INTEGER NOT NULL,
                modified_at_ns INTEGER NOT NULL,
                resource_id BLOB,
                sha256 BLOB
            );
            CREATE TABLE asset_tag_decision (
                asset_id TEXT NOT NULL REFERENCES asset(id),
                tag_id TEXT NOT NULL,
                decision TEXT NOT NULL,
                updated_at_ms INTEGER NOT NULL,
                PRIMARY KEY(asset_id, tag_id)
            );
            CREATE TABLE asset_favorite_state (
                asset_id TEXT PRIMARY KEY REFERENCES asset(id),
                desired_value INTEGER NOT NULL,
                photos_observed_value INTEGER,
                sync_status TEXT NOT NULL,
                intent_revision INTEGER NOT NULL,
                requested_at_ms INTEGER NOT NULL,
                observed_at_ms INTEGER,
                writeback_at_ms INTEGER,
                photos_observed_modification_at_ms INTEGER,
                last_error_code TEXT,
                updated_at_ms INTEGER NOT NULL
            );
            CREATE TABLE personal_model_sample (
                model_revision_id TEXT NOT NULL,
                asset_id TEXT NOT NULL REFERENCES asset(id),
                content_revision INTEGER NOT NULL,
                label INTEGER NOT NULL,
                created_at_ms INTEGER NOT NULL,
                PRIMARY KEY(model_revision_id, asset_id)
            );
            CREATE TABLE recycle_entry (
                id TEXT PRIMARY KEY,
                asset_id TEXT REFERENCES asset(id),
                source_kind TEXT NOT NULL,
                trashed_at_ms INTEGER NOT NULL,
                purge_after_ms INTEGER NOT NULL,
                state TEXT NOT NULL,
                quarantine_relative_path TEXT,
                original_relative_path TEXT,
                photos_local_identifier TEXT,
                error_code TEXT,
                created_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER NOT NULL
            );
            """
        )
        now = 1_700_000_000_000
        connection.executemany(
            "INSERT INTO source VALUES (?, ?, ?, ?, 0, 0, 'active', ?, ?)",
            [
                (photos_source_id, "photos", "System Photos", None, now, now),
                (folder_source_id, "folder", "Export", b"fixture-bookmark", now, now),
            ],
        )
        connection.execute(
            "INSERT INTO asset VALUES (?, ?, 'photos', NULL, ?, 'current', "
            "'public.jpeg', 'image', 10, 10, ?, ?, NULL, 3, 1, 'available', ?, ?, NULL)",
            (asset_id, photos_source_id, local_identifier, now, now, now, now),
        )
        connection.execute(
            "INSERT INTO asset_tag_decision VALUES (?, ?, 'accepted', ?)",
            (asset_id, tag_id, now),
        )
        connection.execute(
            "INSERT INTO asset_favorite_state VALUES "
            "(?, 1, 1, 'synced', 2, ?, ?, ?, ?, NULL, ?)",
            (asset_id, now, now, now, now, now),
        )
        connection.execute(
            "INSERT INTO personal_model_sample VALUES ('model-v1', ?, 3, 1, ?)",
            (asset_id, now),
        )
        connection.execute(
            "INSERT INTO recycle_entry VALUES (?, ?, 'photos', ?, ?, 'restored', "
            "NULL, NULL, ?, NULL, ?, ?)",
            (str(uuid.uuid4()), asset_id, now - 100, now + 100, local_identifier, now, now),
        )
        connection.commit()
        connection.close()


if __name__ == "__main__":
    unittest.main()
