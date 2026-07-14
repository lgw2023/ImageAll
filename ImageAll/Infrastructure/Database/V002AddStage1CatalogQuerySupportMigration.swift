import Foundation
import GRDB

enum V002AddStage1CatalogQuerySupportMigration {
    static let timeEmptyMarkerExpression = """
        (CASE WHEN media_created_at_ms IS NOT NULL OR media_modified_at_ms IS NOT NULL THEN 0 ELSE 1 END)
        """

    static let coalescedMediaTimeExpression = "coalesce(media_created_at_ms, media_modified_at_ms)"

    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v002AddStage1CatalogQuerySupport) { db in
            try db.execute(sql: addFileNameColumnSQL)
            for indexSQL in indexStatements {
                try db.execute(sql: indexSQL)
            }
        }
    }

    private static let addFileNameColumnSQL = """
        ALTER TABLE asset ADD COLUMN file_name TEXT CHECK(
            file_name IS NULL
            OR (
                length(file_name) > 0
                AND file_name NOT IN ('.', '..')
                AND instr(file_name, '/') = 0
                AND instr(file_name, char(0)) = 0
            )
        )
        """

    private static let indexStatements = [
        """
        CREATE INDEX asset_current_time_idx ON asset (
            \(timeEmptyMarkerExpression),
            \(coalescedMediaTimeExpression),
            id
        ) WHERE locator_state = 'current'
        """,
        """
        CREATE INDEX asset_current_source_time_idx ON asset (
            source_id,
            \(timeEmptyMarkerExpression),
            \(coalescedMediaTimeExpression),
            id
        ) WHERE locator_state = 'current'
        """,
        """
        CREATE INDEX asset_current_file_name_idx ON asset (
            file_name COLLATE NOCASE,
            id
        ) WHERE locator_kind = 'file'
            AND locator_state = 'current'
            AND file_name IS NOT NULL
        """,
        """
        CREATE INDEX asset_generation_missing_idx ON asset (
            source_id,
            last_seen_generation,
            id
        ) WHERE locator_kind = 'file' AND locator_state = 'current'
        """,
        """
        CREATE INDEX file_fingerprint_resource_id_idx ON file_fingerprint (
            resource_id,
            asset_id
        ) WHERE resource_id IS NOT NULL
        """,
        """
        CREATE INDEX file_fingerprint_sha256_idx ON file_fingerprint (
            sha256,
            asset_id
        ) WHERE sha256 IS NOT NULL
        """,
    ]
}
