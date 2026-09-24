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
