import Foundation
import GRDB

enum V003AddDerivedImageCacheMigration {
    private static let uuidCheck = V001CreateCatalogCoreMigration.uuidCheck

    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v003AddDerivedImageCache) { db in
            try db.execute(sql: derivedImageCacheEntryDDL)
            for indexSQL in indexStatements {
                try db.execute(sql: indexSQL)
            }
        }
    }

    private static let derivedImageCacheEntryDDL = """
        CREATE TABLE derived_image_cache_entry (
            id TEXT NOT NULL PRIMARY KEY,
            asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
            content_revision INTEGER NOT NULL CHECK(content_revision >= 1),
            representation_version INTEGER NOT NULL CHECK(representation_version >= 1),
            variant TEXT NOT NULL CHECK(variant IN ('gridSmall', 'gridRegular', 'preview')),
            storage_format TEXT NOT NULL CHECK(storage_format IN ('jpeg', 'png')),
            pixel_width INTEGER NOT NULL CHECK(pixel_width > 0),
            pixel_height INTEGER NOT NULL CHECK(pixel_height > 0),
            byte_size INTEGER NOT NULL CHECK(byte_size > 0),
            encoded_sha256 BLOB NOT NULL CHECK(length(encoded_sha256) = 32),
            created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
            last_accessed_at_ms INTEGER NOT NULL CHECK(last_accessed_at_ms >= 0),
            CHECK(\(uuidCheck)),
            CHECK(
                (variant = 'gridSmall' AND pixel_width = 256 AND pixel_height = 256)
                OR (variant = 'gridRegular' AND pixel_width = 512 AND pixel_height = 512)
                OR (
                    variant = 'preview'
                    AND pixel_width > 0
                    AND pixel_height > 0
                    AND max(pixel_width, pixel_height) <= 2048
                )
            )
        ) STRICT
        """

    private static let indexStatements = [
        """
        CREATE UNIQUE INDEX derived_image_cache_key_uq ON derived_image_cache_entry (
            asset_id,
            content_revision,
            representation_version,
            variant
        )
        """,
        """
        CREATE INDEX derived_image_cache_lru_idx ON derived_image_cache_entry (
            last_accessed_at_ms,
            id
        )
        """,
    ]
}
