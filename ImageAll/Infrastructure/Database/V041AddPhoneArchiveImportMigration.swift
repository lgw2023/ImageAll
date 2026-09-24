import Foundation
import GRDB

enum V041AddPhoneArchiveImportMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v041AddPhoneArchiveImport) { db in
            try db.execute(sql: """
                CREATE TABLE migration_import (
                    id TEXT NOT NULL PRIMARY KEY,
                    source_device_id TEXT NOT NULL,
                    source_epoch TEXT NOT NULL,
                    scope_revision INTEGER NOT NULL CHECK(scope_revision >= 0),
                    inventory_watermark INTEGER NOT NULL CHECK(inventory_watermark >= 0),
                    manifest_sha256 TEXT NOT NULL CHECK(length(manifest_sha256) = 64),
                    target_parent_path TEXT NOT NULL,
                    target_bookmark BLOB,
                    archive_path TEXT NOT NULL UNIQUE,
                    item_count INTEGER NOT NULL CHECK(item_count >= 0),
                    resource_count INTEGER NOT NULL CHECK(resource_count >= 0),
                    verified_bytes INTEGER NOT NULL CHECK(verified_bytes >= 0),
                    state TEXT NOT NULL CHECK(state IN ('prepared', 'catalogCommitted')),
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE TABLE migration_import_item (
                    source_device_id TEXT NOT NULL,
                    source_epoch TEXT NOT NULL,
                    media_id TEXT NOT NULL,
                    migration_id TEXT NOT NULL REFERENCES migration_import(id) ON DELETE RESTRICT,
                    source_local_identifier TEXT NOT NULL,
                    media_kind TEXT NOT NULL CHECK(media_kind IN ('image', 'video')),
                    created_at_ms INTEGER,
                    observed_favorite INTEGER NOT NULL CHECK(observed_favorite IN (0, 1)),
                    favorite_target INTEGER CHECK(favorite_target IN (0, 1)),
                    fact_revision INTEGER NOT NULL CHECK(fact_revision >= 0),
                    PRIMARY KEY (source_device_id, source_epoch, media_id),
                    UNIQUE (source_device_id, source_epoch, source_local_identifier)
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE INDEX migration_import_item_batch_idx
                ON migration_import_item(migration_id, media_id)
                """)
            try db.execute(sql: """
                CREATE TABLE migration_import_resource (
                    id TEXT NOT NULL PRIMARY KEY,
                    source_device_id TEXT NOT NULL,
                    source_epoch TEXT NOT NULL,
                    media_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    version INTEGER NOT NULL CHECK(version >= 1),
                    uti TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
                    sha256 TEXT NOT NULL CHECK(length(sha256) = 64),
                    FOREIGN KEY (source_device_id, source_epoch, media_id)
                        REFERENCES migration_import_item(source_device_id, source_epoch, media_id)
                        ON DELETE RESTRICT
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE TABLE migration_import_tag_decision (
                    source_device_id TEXT NOT NULL,
                    source_epoch TEXT NOT NULL,
                    media_id TEXT NOT NULL,
                    tag_id TEXT NOT NULL,
                    tag_name TEXT NOT NULL,
                    decision TEXT NOT NULL CHECK(decision IN ('accepted', 'rejected', 'cleared')),
                    PRIMARY KEY (source_device_id, source_epoch, media_id, tag_id),
                    FOREIGN KEY (source_device_id, source_epoch, media_id)
                        REFERENCES migration_import_item(source_device_id, source_epoch, media_id)
                        ON DELETE RESTRICT
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE TABLE migration_import_collection (
                    source_device_id TEXT NOT NULL,
                    source_epoch TEXT NOT NULL,
                    media_id TEXT NOT NULL,
                    collection_id TEXT NOT NULL,
                    collection_name TEXT NOT NULL,
                    included INTEGER NOT NULL CHECK(included IN (0, 1)),
                    PRIMARY KEY (source_device_id, source_epoch, media_id, collection_id),
                    FOREIGN KEY (source_device_id, source_epoch, media_id)
                        REFERENCES migration_import_item(source_device_id, source_epoch, media_id)
                        ON DELETE RESTRICT
                ) STRICT
                """)
        }
    }
}

/// Additive checkpoint. V041 remains unchanged for catalogs that already ran it.
enum V042AddPhoneArchiveFactCheckpointMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v042AddPhoneArchiveFactCheckpoint) { db in
            try db.execute(sql: """
                ALTER TABLE migration_import ADD COLUMN fact_snapshot_sequence
                INTEGER NOT NULL DEFAULT 0 CHECK(fact_snapshot_sequence >= 0)
                """)
            try db.execute(sql: """
                ALTER TABLE migration_import ADD COLUMN fact_watermark
                INTEGER NOT NULL DEFAULT 0 CHECK(fact_watermark >= 0)
                """)
            try db.execute(sql: """
                ALTER TABLE migration_import ADD COLUMN fact_snapshot_sha256
                TEXT CHECK(fact_snapshot_sha256 IS NULL OR length(fact_snapshot_sha256) = 64)
                """)
        }
    }
}

/// Keep the source Photos album identity separate from ImageAll collections.
/// These rows describe only members inside the selected migration scope.
enum V043AddPhoneArchiveAppleAlbumsMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v043AddPhoneArchiveAppleAlbums) { db in
            try db.execute(sql: """
                ALTER TABLE migration_import ADD COLUMN apple_album_coverage
                TEXT CHECK(apple_album_coverage IS NULL OR
                           apple_album_coverage = 'selectedAssetsOnly')
                """)
            try db.execute(sql: """
                CREATE TABLE migration_import_apple_album_member (
                    migration_id TEXT NOT NULL REFERENCES migration_import(id) ON DELETE RESTRICT,
                    source_device_id TEXT NOT NULL,
                    source_epoch TEXT NOT NULL,
                    media_id TEXT NOT NULL,
                    album_local_identifier TEXT NOT NULL,
                    album_title TEXT,
                    folder_path_json TEXT NOT NULL,
                    source_ordinal INTEGER NOT NULL CHECK(source_ordinal >= 0),
                    PRIMARY KEY (migration_id, album_local_identifier, media_id),
                    UNIQUE (migration_id, album_local_identifier, source_ordinal),
                    FOREIGN KEY (source_device_id, source_epoch, media_id)
                        REFERENCES migration_import_item(source_device_id, source_epoch, media_id)
                        ON DELETE RESTRICT
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE INDEX migration_import_apple_album_item_idx
                ON migration_import_apple_album_member(migration_id, media_id)
                """)
        }
    }
}

/// Append-only evidence for a selected phone archive. The stored row is a
/// historical candidate; callers must re-audit both copies and current Host
/// watermarks before presenting it as current.
enum V044AddPhoneArchiveValidationMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v044AddPhoneArchiveValidation) { db in
            try db.execute(sql: """
                CREATE TABLE migration_import_validation (
                    id TEXT NOT NULL PRIMARY KEY,
                    migration_id TEXT NOT NULL
                        REFERENCES migration_import(id) ON DELETE RESTRICT,
                    archive_path TEXT NOT NULL,
                    archive_volume_uuid TEXT,
                    recovery_archive_path TEXT NOT NULL,
                    recovery_catalog_path TEXT NOT NULL,
                    recovery_parent_bookmark BLOB,
                    manifest_sha256 TEXT NOT NULL CHECK(length(manifest_sha256) = 64),
                    fact_snapshot_sha256 TEXT NOT NULL CHECK(length(fact_snapshot_sha256) = 64),
                    fact_snapshot_sequence INTEGER NOT NULL CHECK(fact_snapshot_sequence > 0),
                    fact_watermark INTEGER NOT NULL CHECK(fact_watermark >= 0),
                    item_count INTEGER NOT NULL CHECK(item_count > 0),
                    resource_count INTEGER NOT NULL CHECK(resource_count > 0),
                    verified_bytes INTEGER NOT NULL CHECK(verified_bytes >= 0),
                    host_id TEXT NOT NULL,
                    device_id TEXT NOT NULL,
                    source_verified_at_ms INTEGER NOT NULL CHECK(source_verified_at_ms > 0),
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms > 0)
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE INDEX migration_import_validation_batch_idx
                ON migration_import_validation(migration_id, created_at_ms DESC)
                """)
        }
    }
}

/// Formal logical media and storage-instance identity. Existing Mac Asset rows
/// remain independent until a user-confirmed binding is recorded later.
enum V045AddMediaIdentityReplicaMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v045AddMediaIdentityReplica) { db in
            try db.execute(sql: """
                CREATE TABLE media_item (
                    id TEXT NOT NULL PRIMARY KEY,
                    source_install_id TEXT NOT NULL,
                    source_epoch TEXT NOT NULL,
                    source_local_identifier TEXT NOT NULL,
                    media_kind TEXT NOT NULL CHECK(media_kind IN ('image', 'video')),
                    UNIQUE(id, source_install_id, source_epoch),
                    UNIQUE(source_install_id, source_epoch, source_local_identifier)
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX migration_import_item_replica_fk_idx
                ON migration_import_item(
                    migration_id, source_device_id, source_epoch, media_id
                )
                """)
            try db.execute(sql: """
                CREATE TABLE media_replica (
                    id TEXT NOT NULL PRIMARY KEY,
                    media_id TEXT NOT NULL REFERENCES media_item(id) ON DELETE RESTRICT,
                    storage_kind TEXT NOT NULL CHECK(storage_kind = 'macArchive'),
                    migration_id TEXT NOT NULL REFERENCES migration_import(id) ON DELETE RESTRICT,
                    source_install_id TEXT NOT NULL,
                    source_epoch TEXT NOT NULL,
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    UNIQUE(migration_id, media_id),
                    FOREIGN KEY(media_id, source_install_id, source_epoch)
                        REFERENCES media_item(id, source_install_id, source_epoch)
                        ON DELETE RESTRICT,
                    FOREIGN KEY(migration_id, source_install_id, source_epoch, media_id)
                        REFERENCES migration_import_item(
                            migration_id, source_device_id, source_epoch, media_id
                        )
                        ON DELETE RESTRICT
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE INDEX media_replica_media_idx ON media_replica(media_id, storage_kind)
                """)
            try db.execute(sql: """
                CREATE TABLE media_asset_binding (
                    media_id TEXT NOT NULL REFERENCES media_item(id) ON DELETE RESTRICT,
                    asset_id TEXT NOT NULL UNIQUE REFERENCES asset(id) ON DELETE RESTRICT,
                    evidence_kind TEXT NOT NULL CHECK(evidence_kind IN ('userConfirmed', 'migrationManifest')),
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    PRIMARY KEY(media_id, asset_id)
                ) STRICT
                """)
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT i.media_id, i.source_device_id, i.source_epoch,
                       i.source_local_identifier, i.media_kind, i.migration_id,
                       m.updated_at_ms
                FROM migration_import_item i
                JOIN migration_import m ON m.id = i.migration_id
                WHERE m.state = 'catalogCommitted'
                ORDER BY i.migration_id, i.media_id
                """)
            while let row = try cursor.next() {
                let media: String = row["media_id"]
                let install: String = row["source_device_id"]
                let epoch: String = row["source_epoch"]
                let locator: String = row["source_local_identifier"]
                let kind: String = row["media_kind"]
                let migration: String = row["migration_id"]
                let timestamp: Int64 = row["updated_at_ms"]
                try db.execute(sql: """
                    INSERT INTO media_item (
                        id, source_install_id, source_epoch,
                        source_local_identifier, media_kind
                    ) VALUES (?, ?, ?, ?, ?)
                    """, arguments: [media, install, epoch, locator, kind])
                try db.execute(sql: """
                    INSERT INTO media_replica (
                        id, media_id, storage_kind, migration_id,
                        source_install_id, source_epoch, created_at_ms
                    ) VALUES (?, ?, 'macArchive', ?, ?, ?, ?)
                    """, arguments: [
                        UUID().uuidString.lowercased(), media, migration,
                        install, epoch, timestamp,
                    ])
            }
        }
    }
}

/// Append-only history for explicit binding and correction. Existing active
/// bindings receive a confirmation event without changing their identity.
enum V046AuditMediaAssetBindingMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v046AuditMediaAssetBinding) { db in
            try db.execute(sql: """
                CREATE TABLE media_asset_binding_event (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    media_id TEXT NOT NULL REFERENCES media_item(id) ON DELETE RESTRICT,
                    asset_id TEXT NOT NULL,
                    event_kind TEXT NOT NULL CHECK(event_kind IN ('confirmed', 'revoked')),
                    confirmed_event_id TEXT UNIQUE
                        REFERENCES media_asset_binding_event(id) ON DELETE RESTRICT,
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    CHECK(
                        (event_kind = 'confirmed' AND confirmed_event_id IS NULL)
                        OR (event_kind = 'revoked' AND confirmed_event_id IS NOT NULL)
                    )
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE INDEX media_asset_binding_event_pair_idx
                ON media_asset_binding_event(media_id, asset_id, sequence)
                """)
            let rows = try Row.fetchAll(db, sql: """
                SELECT media_id, asset_id, created_at_ms
                FROM media_asset_binding ORDER BY media_id, asset_id
                """)
            for row in rows {
                let media: String = row["media_id"]
                let asset: String = row["asset_id"]
                let createdAtMs: Int64 = row["created_at_ms"]
                try db.execute(sql: """
                    INSERT INTO media_asset_binding_event (
                        id, media_id, asset_id, event_kind, confirmed_event_id, created_at_ms
                    ) VALUES (?, ?, ?, 'confirmed', NULL, ?)
                    """, arguments: [
                        UUID().uuidString.lowercased(), media, asset, createdAtMs,
                    ])
            }
        }
    }
}

/// Explicit identity aliases between a phone tag namespace and the existing
/// Mac tag catalog. Alias events are retained after an alias is revoked.
enum V047AddPhoneTagAliasMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v047AddPhoneTagAlias) { db in
            try db.execute(sql: """
                CREATE TABLE phone_tag_alias (
                    source_install_id TEXT NOT NULL,
                    source_epoch TEXT NOT NULL,
                    phone_tag_id TEXT NOT NULL,
                    mac_tag_id TEXT NOT NULL REFERENCES tag(id) ON DELETE RESTRICT,
                    confirmed_phone_name TEXT NOT NULL CHECK(length(confirmed_phone_name) > 0),
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    PRIMARY KEY(source_install_id, source_epoch, phone_tag_id),
                    UNIQUE(source_install_id, source_epoch, mac_tag_id)
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE TABLE phone_tag_alias_event (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    source_install_id TEXT NOT NULL,
                    source_epoch TEXT NOT NULL,
                    phone_tag_id TEXT NOT NULL,
                    mac_tag_id TEXT NOT NULL,
                    event_kind TEXT NOT NULL CHECK(event_kind IN ('confirmed', 'revoked')),
                    confirmed_event_id TEXT UNIQUE
                        REFERENCES phone_tag_alias_event(id) ON DELETE RESTRICT,
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    CHECK(
                        (event_kind = 'confirmed' AND confirmed_event_id IS NULL)
                        OR (event_kind = 'revoked' AND confirmed_event_id IS NOT NULL)
                    )
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE INDEX phone_tag_alias_event_scope_idx
                ON phone_tag_alias_event(
                    source_install_id, source_epoch, phone_tag_id, sequence
                )
                """)
        }
    }
}

/// A monotonic version survives a cleared decision and detects change-back ABA.
/// Triggers cover every existing Mac tag mutation path, including undo and batch edits.
enum V048AddAssetTagDecisionRevisionMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v048AddAssetTagDecisionRevision) { db in
            try db.execute(sql: """
                CREATE TABLE asset_tag_decision_revision (
                    asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
                    tag_id TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
                    revision INTEGER NOT NULL CHECK(revision > 0),
                    PRIMARY KEY(asset_id, tag_id)
                ) STRICT
                """)
            try db.execute(sql: """
                INSERT INTO asset_tag_decision_revision (asset_id, tag_id, revision)
                SELECT asset_id, tag_id, 1 FROM asset_tag_decision
                """)
            for (name, operation, row) in [
                ("asset_tag_decision_revision_insert", "INSERT", "NEW"),
                ("asset_tag_decision_revision_update", "UPDATE", "NEW"),
                ("asset_tag_decision_revision_delete", "DELETE", "OLD"),
            ] {
                try db.execute(sql: """
                    CREATE TRIGGER \(name) AFTER \(operation) ON asset_tag_decision
                    BEGIN
                        INSERT INTO asset_tag_decision_revision (asset_id, tag_id, revision)
                        VALUES (\(row).asset_id, \(row).tag_id, 1)
                        ON CONFLICT(asset_id, tag_id) DO UPDATE SET
                            revision = revision + 1;
                    END
                    """)
            }
            try db.execute(sql: """
                CREATE TABLE phone_tag_mac_application_event (
                    id TEXT NOT NULL PRIMARY KEY,
                    migration_id TEXT NOT NULL REFERENCES migration_import(id) ON DELETE RESTRICT,
                    media_id TEXT NOT NULL REFERENCES media_item(id) ON DELETE RESTRICT,
                    asset_id TEXT NOT NULL,
                    binding_confirmation_event_id TEXT NOT NULL
                        REFERENCES media_asset_binding_event(id) ON DELETE RESTRICT,
                    source_install_id TEXT NOT NULL,
                    source_epoch TEXT NOT NULL,
                    phone_device_id TEXT NOT NULL,
                    phone_scope_revision INTEGER NOT NULL CHECK(phone_scope_revision >= 0),
                    phone_tag_id TEXT NOT NULL,
                    mac_tag_id TEXT NOT NULL,
                    phone_field_revision INTEGER NOT NULL CHECK(phone_field_revision > 0),
                    phone_decision TEXT NOT NULL
                        CHECK(phone_decision IN ('accepted', 'rejected', 'cleared')),
                    prior_mac_decision TEXT CHECK(prior_mac_decision IN ('accepted', 'rejected')),
                    prior_mac_revision INTEGER NOT NULL CHECK(prior_mac_revision >= 0),
                    resulting_mac_revision INTEGER NOT NULL
                        CHECK(resulting_mac_revision > prior_mac_revision),
                    committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms >= 0)
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE INDEX phone_tag_mac_application_event_asset_idx
                ON phone_tag_mac_application_event(asset_id, mac_tag_id, committed_at_ms)
                """)
        }
    }
}

/// The SQLite half of a Mac-to-phone shared tag operation. A JSON ledger
/// receipt with the same operation ID is required before marking it committed.
enum V049AddPhoneTagOutboundIntentMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v049AddPhoneTagOutboundIntent) { db in
            try db.execute(sql: """
                CREATE TABLE phone_tag_mac_outbound_intent (
                    id TEXT NOT NULL PRIMARY KEY,
                    migration_id TEXT NOT NULL REFERENCES migration_import(id) ON DELETE RESTRICT,
                    media_id TEXT NOT NULL REFERENCES media_item(id) ON DELETE RESTRICT,
                    asset_id TEXT NOT NULL,
                    binding_confirmation_event_id TEXT NOT NULL
                        REFERENCES media_asset_binding_event(id) ON DELETE RESTRICT,
                    source_install_id TEXT NOT NULL,
                    source_epoch TEXT NOT NULL,
                    phone_device_id TEXT NOT NULL,
                    phone_scope_revision INTEGER NOT NULL CHECK(phone_scope_revision >= 0),
                    phone_tag_id TEXT NOT NULL,
                    phone_tag_name TEXT NOT NULL CHECK(length(phone_tag_name) > 0),
                    mac_tag_id TEXT NOT NULL,
                    mac_expected_revision INTEGER NOT NULL CHECK(mac_expected_revision >= 0),
                    mac_expected_decision TEXT NOT NULL
                        CHECK(mac_expected_decision IN ('accepted', 'rejected')),
                    phone_expected_revision INTEGER NOT NULL CHECK(phone_expected_revision > 0),
                    phone_expected_decision TEXT NOT NULL
                        CHECK(phone_expected_decision IN ('accepted', 'rejected', 'cleared')),
                    desired_decision TEXT NOT NULL
                        CHECK(desired_decision IN ('accepted', 'rejected')),
                    state TEXT NOT NULL DEFAULT 'prepared'
                        CHECK(state IN ('prepared', 'committed', 'conflict')),
                    phone_resulting_revision INTEGER CHECK(phone_resulting_revision > 0),
                    phone_change_sequence INTEGER CHECK(phone_change_sequence > 0),
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    resolved_at_ms INTEGER CHECK(resolved_at_ms >= created_at_ms),
                    CHECK(
                        (state = 'prepared' AND phone_resulting_revision IS NULL
                            AND phone_change_sequence IS NULL AND resolved_at_ms IS NULL)
                        OR (state = 'committed' AND phone_resulting_revision IS NOT NULL
                            AND phone_change_sequence IS NOT NULL AND resolved_at_ms IS NOT NULL)
                        OR (state = 'conflict' AND phone_resulting_revision IS NULL
                            AND phone_change_sequence IS NULL AND resolved_at_ms IS NOT NULL)
                    )
                ) STRICT
                """)
            try db.execute(sql: """
                CREATE INDEX phone_tag_mac_outbound_intent_asset_idx
                ON phone_tag_mac_outbound_intent(asset_id, media_id, state, created_at_ms)
                """)
        }
    }
}

/// Keep V049 immutable while admitting a Mac-side cleared decision. Existing
/// intents retain their IDs and receipts through this transactional rebuild.
enum V050AllowClearedPhoneTagOutboundIntentMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(
            CatalogMigrationID.v050AllowClearedPhoneTagOutboundIntent
        ) { db in
            try db.execute(sql: """
                CREATE TABLE phone_tag_mac_outbound_intent_v050 (
                    id TEXT NOT NULL PRIMARY KEY,
                    migration_id TEXT NOT NULL REFERENCES migration_import(id) ON DELETE RESTRICT,
                    media_id TEXT NOT NULL REFERENCES media_item(id) ON DELETE RESTRICT,
                    asset_id TEXT NOT NULL,
                    binding_confirmation_event_id TEXT NOT NULL
                        REFERENCES media_asset_binding_event(id) ON DELETE RESTRICT,
                    source_install_id TEXT NOT NULL,
                    source_epoch TEXT NOT NULL,
                    phone_device_id TEXT NOT NULL,
                    phone_scope_revision INTEGER NOT NULL CHECK(phone_scope_revision >= 0),
                    phone_tag_id TEXT NOT NULL,
                    phone_tag_name TEXT NOT NULL CHECK(length(phone_tag_name) > 0),
                    mac_tag_id TEXT NOT NULL,
                    mac_expected_revision INTEGER NOT NULL CHECK(mac_expected_revision >= 0),
                    mac_expected_decision TEXT NOT NULL
                        CHECK(mac_expected_decision IN ('accepted', 'rejected', 'cleared')),
                    phone_expected_revision INTEGER NOT NULL CHECK(phone_expected_revision > 0),
                    phone_expected_decision TEXT NOT NULL
                        CHECK(phone_expected_decision IN ('accepted', 'rejected', 'cleared')),
                    desired_decision TEXT NOT NULL
                        CHECK(desired_decision IN ('accepted', 'rejected', 'cleared')),
                    state TEXT NOT NULL DEFAULT 'prepared'
                        CHECK(state IN ('prepared', 'committed', 'conflict')),
                    phone_resulting_revision INTEGER CHECK(phone_resulting_revision > 0),
                    phone_change_sequence INTEGER CHECK(phone_change_sequence > 0),
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    resolved_at_ms INTEGER CHECK(resolved_at_ms >= created_at_ms),
                    CHECK(
                        (state = 'prepared' AND phone_resulting_revision IS NULL
                            AND phone_change_sequence IS NULL AND resolved_at_ms IS NULL)
                        OR (state = 'committed' AND phone_resulting_revision IS NOT NULL
                            AND phone_change_sequence IS NOT NULL AND resolved_at_ms IS NOT NULL)
                        OR (state = 'conflict' AND phone_resulting_revision IS NULL
                            AND phone_change_sequence IS NULL AND resolved_at_ms IS NOT NULL)
                    )
                ) STRICT
                """)
            try db.execute(sql: """
                INSERT INTO phone_tag_mac_outbound_intent_v050 (
                    id, migration_id, media_id, asset_id,
                    binding_confirmation_event_id, source_install_id, source_epoch,
                    phone_device_id, phone_scope_revision, phone_tag_id, phone_tag_name,
                    mac_tag_id, mac_expected_revision, mac_expected_decision,
                    phone_expected_revision, phone_expected_decision, desired_decision,
                    state, phone_resulting_revision, phone_change_sequence,
                    created_at_ms, resolved_at_ms
                ) SELECT
                    id, migration_id, media_id, asset_id,
                    binding_confirmation_event_id, source_install_id, source_epoch,
                    phone_device_id, phone_scope_revision, phone_tag_id, phone_tag_name,
                    mac_tag_id, mac_expected_revision, mac_expected_decision,
                    phone_expected_revision, phone_expected_decision, desired_decision,
                    state, phone_resulting_revision, phone_change_sequence,
                    created_at_ms, resolved_at_ms
                FROM phone_tag_mac_outbound_intent
                """)
            try db.execute(sql: "DROP TABLE phone_tag_mac_outbound_intent")
            try db.execute(sql: """
                ALTER TABLE phone_tag_mac_outbound_intent_v050
                RENAME TO phone_tag_mac_outbound_intent
                """)
            try db.execute(sql: """
                CREATE INDEX phone_tag_mac_outbound_intent_asset_idx
                ON phone_tag_mac_outbound_intent(asset_id, media_id, state, created_at_ms)
                """)
        }
    }
}

/// Revision zero and a NULL phone decision mean the shared field did not exist.
/// This is distinct from an existing field whose explicit decision is cleared.
enum V051AllowNewPhoneTagOutboundIntentMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v051AllowNewPhoneTagOutboundIntent) { db in
            try db.execute(sql: """
                CREATE TABLE phone_tag_mac_outbound_intent_v051 (
                    id TEXT NOT NULL PRIMARY KEY,
                    migration_id TEXT NOT NULL REFERENCES migration_import(id) ON DELETE RESTRICT,
                    media_id TEXT NOT NULL REFERENCES media_item(id) ON DELETE RESTRICT,
                    asset_id TEXT NOT NULL,
                    binding_confirmation_event_id TEXT NOT NULL
                        REFERENCES media_asset_binding_event(id) ON DELETE RESTRICT,
                    source_install_id TEXT NOT NULL,
                    source_epoch TEXT NOT NULL,
                    phone_device_id TEXT NOT NULL,
                    phone_scope_revision INTEGER NOT NULL CHECK(phone_scope_revision >= 0),
                    phone_tag_id TEXT NOT NULL,
                    phone_tag_name TEXT NOT NULL CHECK(length(phone_tag_name) > 0),
                    mac_tag_id TEXT NOT NULL,
                    mac_tag_updated_at_ms INTEGER CHECK(mac_tag_updated_at_ms >= 0),
                    mac_expected_revision INTEGER NOT NULL CHECK(mac_expected_revision >= 0),
                    mac_expected_decision TEXT NOT NULL
                        CHECK(mac_expected_decision IN ('accepted', 'rejected', 'cleared')),
                    phone_expected_revision INTEGER NOT NULL CHECK(phone_expected_revision >= 0),
                    phone_expected_decision TEXT
                        CHECK(phone_expected_decision IN ('accepted', 'rejected', 'cleared')),
                    desired_decision TEXT NOT NULL
                        CHECK(desired_decision IN ('accepted', 'rejected', 'cleared')),
                    state TEXT NOT NULL DEFAULT 'prepared'
                        CHECK(state IN ('prepared', 'committed', 'conflict')),
                    phone_resulting_revision INTEGER CHECK(phone_resulting_revision > 0),
                    phone_change_sequence INTEGER CHECK(phone_change_sequence > 0),
                    created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
                    resolved_at_ms INTEGER CHECK(resolved_at_ms >= created_at_ms),
                    CHECK(
                        (phone_expected_revision = 0 AND phone_expected_decision IS NULL)
                        OR (phone_expected_revision > 0 AND phone_expected_decision IS NOT NULL)
                    ),
                    CHECK(
                        (state = 'prepared' AND phone_resulting_revision IS NULL
                            AND phone_change_sequence IS NULL AND resolved_at_ms IS NULL)
                        OR (state = 'committed' AND phone_resulting_revision IS NOT NULL
                            AND phone_change_sequence IS NOT NULL AND resolved_at_ms IS NOT NULL)
                        OR (state = 'conflict' AND phone_resulting_revision IS NULL
                            AND phone_change_sequence IS NULL AND resolved_at_ms IS NOT NULL)
                    )
                ) STRICT
                """)
            try db.execute(sql: """
                INSERT INTO phone_tag_mac_outbound_intent_v051 (
                    id, migration_id, media_id, asset_id,
                    binding_confirmation_event_id, source_install_id, source_epoch,
                    phone_device_id, phone_scope_revision, phone_tag_id, phone_tag_name,
                    mac_tag_id, mac_tag_updated_at_ms,
                    mac_expected_revision, mac_expected_decision,
                    phone_expected_revision, phone_expected_decision, desired_decision,
                    state, phone_resulting_revision, phone_change_sequence,
                    created_at_ms, resolved_at_ms
                ) SELECT
                    id, migration_id, media_id, asset_id,
                    binding_confirmation_event_id, source_install_id, source_epoch,
                    phone_device_id, phone_scope_revision, phone_tag_id, phone_tag_name,
                    mac_tag_id, NULL,
                    mac_expected_revision, mac_expected_decision,
                    phone_expected_revision, phone_expected_decision, desired_decision,
                    state, phone_resulting_revision, phone_change_sequence,
                    created_at_ms, resolved_at_ms
                FROM phone_tag_mac_outbound_intent
                """)
            try db.execute(sql: "DROP TABLE phone_tag_mac_outbound_intent")
            try db.execute(sql: """
                ALTER TABLE phone_tag_mac_outbound_intent_v051
                RENAME TO phone_tag_mac_outbound_intent
                """)
            try db.execute(sql: """
                CREATE INDEX phone_tag_mac_outbound_intent_asset_idx
                ON phone_tag_mac_outbound_intent(asset_id, media_id, state, created_at_ms)
                """)
        }
    }
}
