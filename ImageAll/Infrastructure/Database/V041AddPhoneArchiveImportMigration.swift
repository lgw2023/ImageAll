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
