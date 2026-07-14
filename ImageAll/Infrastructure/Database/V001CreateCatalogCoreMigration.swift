import Foundation
import GRDB

enum V001CreateCatalogCoreMigration {
    private static let uuidAllowedCharsStripped: String = {
        var expression = "id"
        for character in Array("0123456789abcdef-") {
            expression = "replace(\(expression), '\(character)', '')"
        }
        return expression
    }()

    static let uuidCheck = """
        length(id) = 36
        AND id = lower(id)
        AND id GLOB '????????-????-????-????-????????????'
        AND \(uuidAllowedCharsStripped) = ''
        """

    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v001CreateCatalogCore) { db in
            try db.execute(sql: sourceDDL)
            try db.execute(sql: assetDDL)
            try db.execute(sql: fileFingerprintDDL)
            try db.execute(sql: tagDDL)
            try db.execute(sql: assetTagDecisionDDL)
            try db.execute(sql: jobDDL)

            for indexSQL in indexStatements {
                try db.execute(sql: indexSQL)
            }
        }
    }

    private static let sourceDDL = """
        CREATE TABLE source (
            id TEXT NOT NULL PRIMARY KEY,
            kind TEXT NOT NULL CHECK(kind IN ('folder', 'photos')),
            display_name TEXT NOT NULL CHECK(length(display_name) > 0),
            bookmark BLOB CHECK(
                (kind = 'folder' AND bookmark IS NOT NULL AND length(bookmark) > 0)
                OR (kind = 'photos' AND bookmark IS NULL)
            ),
            sync_cursor BLOB,
            scan_generation INTEGER NOT NULL DEFAULT 0 CHECK(scan_generation >= 0),
            dirty_epoch INTEGER NOT NULL DEFAULT 0 CHECK(dirty_epoch >= 0),
            state TEXT NOT NULL DEFAULT 'active'
                CHECK(state IN ('active', 'disabled', 'unavailable', 'authorizationRequired')),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            CHECK(\(uuidCheck))
        ) STRICT
        """

    private static let assetDDL = """
        CREATE TABLE asset (
            id TEXT NOT NULL PRIMARY KEY,
            source_id TEXT NOT NULL REFERENCES source(id) ON DELETE RESTRICT,
            locator_kind TEXT NOT NULL CHECK(locator_kind IN ('file', 'photos')),
            relative_path TEXT,
            photos_local_identifier TEXT,
            locator_state TEXT NOT NULL DEFAULT 'current'
                CHECK(locator_state IN ('current', 'historical')),
            media_type TEXT NOT NULL CHECK(length(media_type) > 0),
            width INTEGER CHECK(width IS NULL OR width > 0),
            height INTEGER CHECK(height IS NULL OR height > 0),
            media_created_at_ms INTEGER,
            media_modified_at_ms INTEGER,
            content_revision INTEGER NOT NULL DEFAULT 1 CHECK(content_revision >= 1),
            last_seen_generation INTEGER CHECK(last_seen_generation IS NULL OR last_seen_generation >= 0),
            availability TEXT NOT NULL DEFAULT 'available'
                CHECK(availability IN ('available', 'missing', 'unreadable', 'unsupported')),
            record_created_at_ms INTEGER NOT NULL,
            record_updated_at_ms INTEGER NOT NULL,
            CHECK(
                (locator_kind = 'file'
                    AND relative_path IS NOT NULL AND length(relative_path) > 0
                    AND photos_local_identifier IS NULL)
                OR (locator_kind = 'photos'
                    AND photos_local_identifier IS NOT NULL AND length(photos_local_identifier) > 0
                    AND relative_path IS NULL)
            ),
            CHECK(\(uuidCheck))
        ) STRICT
        """

    private static let fileFingerprintDDL = """
        CREATE TABLE file_fingerprint (
            asset_id TEXT NOT NULL PRIMARY KEY REFERENCES asset(id) ON DELETE CASCADE,
            size_bytes INTEGER NOT NULL CHECK(size_bytes >= 0),
            modified_at_ns INTEGER NOT NULL,
            resource_id BLOB,
            sha256 BLOB CHECK(sha256 IS NULL OR length(sha256) = 32)
        ) STRICT
        """

    private static let tagDDL = """
        CREATE TABLE tag (
            id TEXT NOT NULL PRIMARY KEY,
            name TEXT NOT NULL CHECK(length(name) > 0),
            normalized_name TEXT NOT NULL CHECK(length(normalized_name) > 0),
            state TEXT NOT NULL DEFAULT 'active' CHECK(state IN ('active', 'archived')),
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            CHECK(\(uuidCheck))
        ) STRICT
        """

    private static let assetTagDecisionDDL = """
        CREATE TABLE asset_tag_decision (
            asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE RESTRICT,
            tag_id TEXT NOT NULL REFERENCES tag(id) ON DELETE RESTRICT,
            decision TEXT NOT NULL CHECK(decision IN ('accepted', 'rejected')),
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (asset_id, tag_id)
        ) STRICT
        """

    private static let jobDDL = """
        CREATE TABLE job (
            id TEXT NOT NULL PRIMARY KEY,
            kind TEXT NOT NULL CHECK(length(kind) > 0),
            payload_version INTEGER NOT NULL CHECK(payload_version >= 1),
            payload BLOB NOT NULL,
            source_id TEXT REFERENCES source(id) ON DELETE SET NULL,
            coalescing_key TEXT CHECK(coalescing_key IS NULL OR length(coalescing_key) > 0),
            checkpoint_version INTEGER,
            checkpoint BLOB,
            scan_generation INTEGER CHECK(scan_generation IS NULL OR scan_generation >= 0),
            started_dirty_epoch INTEGER CHECK(started_dirty_epoch IS NULL OR started_dirty_epoch >= 0),
            state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN (
                'pending', 'running', 'paused', 'retryableFailed',
                'completed', 'terminalFailed', 'cancelled'
            )),
            control_request TEXT NOT NULL DEFAULT 'none'
                CHECK(control_request IN ('none', 'pause', 'cancel')),
            priority INTEGER NOT NULL DEFAULT 0,
            attempts INTEGER NOT NULL DEFAULT 0,
            max_attempts INTEGER NOT NULL CHECK(max_attempts > 0),
            not_before_ms INTEGER NOT NULL,
            lease_owner TEXT,
            lease_expires_at_ms INTEGER,
            progress_completed INTEGER NOT NULL DEFAULT 0 CHECK(progress_completed >= 0),
            progress_total INTEGER CHECK(progress_total IS NULL OR progress_total >= progress_completed),
            last_error_code TEXT,
            last_error_message TEXT,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            CHECK(
                (checkpoint_version IS NULL AND checkpoint IS NULL)
                OR (checkpoint_version IS NOT NULL AND checkpoint IS NOT NULL AND checkpoint_version >= 1)
            ),
            CHECK(
                (state = 'running'
                    AND lease_owner IS NOT NULL AND length(lease_owner) > 0
                    AND lease_expires_at_ms IS NOT NULL)
                OR (state != 'running'
                    AND lease_owner IS NULL
                    AND lease_expires_at_ms IS NULL)
            ),
            CHECK(
                (state = 'running' AND control_request IN ('none', 'pause', 'cancel'))
                OR (state != 'running' AND control_request = 'none')
            ),
            CHECK(attempts >= 0 AND attempts <= max_attempts),
            CHECK(\(uuidCheck))
        ) STRICT
        """

    private static let indexStatements = [
        """
        CREATE UNIQUE INDEX asset_current_file_locator_uq
        ON asset(source_id, relative_path)
        WHERE locator_kind = 'file' AND locator_state = 'current'
        """,
        """
        CREATE UNIQUE INDEX asset_current_photos_locator_uq
        ON asset(source_id, photos_local_identifier)
        WHERE locator_kind = 'photos' AND locator_state = 'current'
        """,
        """
        CREATE INDEX asset_source_availability_idx
        ON asset(source_id, availability, id)
        """,
        """
        CREATE UNIQUE INDEX tag_normalized_name_uq
        ON tag(normalized_name COLLATE BINARY)
        """,
        """
        CREATE INDEX decision_tag_idx
        ON asset_tag_decision(tag_id, decision, asset_id)
        """,
        """
        CREATE INDEX job_queue_idx
        ON job(state, priority DESC, not_before_ms, id)
        """,
        """
        CREATE UNIQUE INDEX job_active_coalescing_uq
        ON job(coalescing_key)
        WHERE coalescing_key IS NOT NULL
            AND state IN ('pending', 'running', 'paused', 'retryableFailed')
        """,
    ]
}
