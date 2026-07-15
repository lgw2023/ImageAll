import GRDB
import XCTest
@testable import ImageAll

final class V003MigrationTests: XCTestCase {
    func testFreshDatabaseAppliesThroughV003() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        XCTAssertEqual(try database.appliedMigrationIDs(), CatalogMigrationID.knownOrdered)
    }

    func testV002SentinelFactsSurviveV003Upgrade() throws {
        let url = try makeTempDatabaseURL()
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let pool = try DatabasePool(path: url.path, configuration: config)
        try DatabaseTestSupport.makeV002OnlyMigrator().migrate(pool)
        let sourceID = UUID()
        let assetID = UUID()
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'folder', 'Sentinel', ?, 0, 0, 'active', ?, ?)
                """,
                arguments: [sourceID.uuidString.lowercased(), DatabaseTestSupport.folderBookmark(), DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs]
            )
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, content_revision, availability,
                    record_created_at_ms, record_updated_at_ms
                ) VALUES (?, ?, 'file', 'sentinel.jpg', NULL, 'current', 'public.jpeg', 1, 'available', ?, ?)
                """,
                arguments: [assetID.uuidString.lowercased(), sourceID.uuidString.lowercased(), DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs]
            )
        }

        let upgraded = try CatalogDatabase.open(at: url)
        try upgraded.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0, 1)
            XCTAssertTrue(try db.tableExists("derived_image_cache_entry"))
        }
    }

    func testDerivedCacheEntryConstraints() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let assetID = UUID()
        try repository.createSourceWithAsset(
            NewSourceWithAssetInput(
                sourceID: UUID(),
                sourceKind: .folder,
                displayName: "Folder",
                bookmark: DatabaseTestSupport.folderBookmark(),
                assetID: assetID,
                locatorKind: .file,
                relativePath: "photo.jpg",
                photosLocalIdentifier: nil,
                mediaType: "public.jpeg",
                timestampMs: DatabaseTestSupport.timestampMs
            )
        )
        let asset = assetID.uuidString.lowercased()
        let hash = Data(repeating: 0xAB, count: 32)
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO derived_image_cache_entry (
                    id, asset_id, content_revision, representation_version, variant,
                    storage_format, pixel_width, pixel_height, byte_size, encoded_sha256,
                    created_at_ms, last_accessed_at_ms
                ) VALUES (?, ?, 1, 1, 'gridSmall', 'jpeg', 256, 256, 100, ?, 1, 1)
                """,
                arguments: [UUID().uuidString.lowercased(), asset, hash]
            )
        }

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO derived_image_cache_entry (
                    id, asset_id, content_revision, representation_version, variant,
                    storage_format, pixel_width, pixel_height, byte_size, encoded_sha256,
                    created_at_ms, last_accessed_at_ms
                ) VALUES (?, ?, 1, 1, 'gridSmall', 'jpeg', 256, 256, 100, ?, 1, 1)
                """,
                arguments: [UUID().uuidString.lowercased(), asset, hash]
            )
        })

        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM asset WHERE id = ?", arguments: [asset])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM derived_image_cache_entry") ?? 0, 0)
        }
    }

    func testV001AndV002DDLUnchangedAfterV003() throws {
        let v002URL = try makeTempDatabaseURL()
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let v002Pool = try DatabasePool(path: v002URL.path, configuration: config)
        try DatabaseTestSupport.makeV002OnlyMigrator().migrate(v002Pool)

        let fullURL = try makeTempDatabaseURL()
        let full = try CatalogDatabase.open(at: fullURL)
        for table in CatalogSchemaExpectations.businessTables where table != "derived_image_cache_entry" && table != "asset" {
            let baselineSQL = try v002Pool.read { db in
                try String.fetchOne(db, sql: "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?", arguments: [table])
            }
            let currentSQL = try full.pool.read { db in
                try String.fetchOne(db, sql: "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?", arguments: [table])
            }
            XCTAssertEqual(currentSQL, baselineSQL, "\(table) must remain unchanged")
        }
    }
}
