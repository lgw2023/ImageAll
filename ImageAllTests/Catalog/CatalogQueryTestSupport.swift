import Foundation
import GRDB
import XCTest
@testable import ImageAll

enum CatalogQueryTestSupport {
    struct FixtureIDs: Sendable {
        let sourceA: UUID
        let sourceB: UUID
        let assetNewest: UUID
        let assetMiddle: UUID
        let assetOldest: UUID
        let assetNoTime: UUID
        let assetHistorical: UUID
        let tagFamily: UUID
        let tagWork: UUID
        let tagArchived: UUID
    }

    static func openQueryDatabase() throws -> (
        database: CatalogDatabase,
        query: GRDBAssetCatalogQueryRepository,
        tags: GRDBTagCatalogRepository,
        repository: CatalogRepository,
        ids: FixtureIDs
    ) {
        let url = try DatabaseTestSupport.makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let query = GRDBAssetCatalogQueryRepository(database: database)
        let tags = GRDBTagCatalogRepository(database: database)
        let ids = try seedCatalogFixture(database: database, repository: repository)
        return (database, query, tags, repository, ids)
    }

    @discardableResult
    static func seedCatalogFixture(
        database: CatalogDatabase,
        repository: CatalogRepository
    ) throws -> FixtureIDs {
        let sourceA = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let sourceB = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        let assetNewest = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let assetMiddle = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
        let assetOldest = UUID(uuidString: "20000000-0000-4000-8000-000000000003")!
        let assetNoTime = UUID(uuidString: "20000000-0000-4000-8000-000000000004")!
        let assetHistorical = UUID(uuidString: "20000000-0000-4000-8000-000000000005")!
        let tagFamily = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
        let tagWork = UUID(uuidString: "30000000-0000-4000-8000-000000000002")!
        let tagArchived = UUID(uuidString: "30000000-0000-4000-8000-000000000003")!

        try repository.createSourceWithAsset(
            NewSourceWithAssetInput(
                sourceID: sourceA,
                sourceKind: .folder,
                displayName: "Vacation Archive",
                bookmark: DatabaseTestSupport.folderBookmark(),
                assetID: assetNewest,
                locatorKind: .file,
                relativePath: "2024/beach/IMG_001.jpg",
                photosLocalIdentifier: nil,
                mediaType: "public.jpeg",
                timestampMs: DatabaseTestSupport.timestampMs
            )
        )

        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE source SET state = 'disabled' WHERE id = ?
                """,
                arguments: [sourceA.uuidString.lowercased()]
            )
            try insertAsset(
                db,
                assetID: assetMiddle,
                sourceID: sourceA,
                relativePath: "2024/beach/IMG_002.jpg",
                fileName: "img_002.jpg",
                mediaType: "public.png",
                createdMs: 1_700_000_000_000,
                modifiedMs: 1_700_000_000_100,
                availability: "available"
            )
            try insertAsset(
                db,
                assetID: assetOldest,
                sourceID: sourceA,
                relativePath: "2024/beach/IMG_003.jpg",
                fileName: "IMG_003.jpg",
                mediaType: "public.heic",
                createdMs: 1_600_000_000_000,
                modifiedMs: nil,
                availability: "missing"
            )
            try insertAsset(
                db,
                assetID: assetNoTime,
                sourceID: sourceA,
                relativePath: "2024/beach/no-time.jpg",
                fileName: "no-time.jpg",
                mediaType: "public.tiff",
                createdMs: nil,
                modifiedMs: nil,
                availability: "unreadable"
            )
            try insertAsset(
                db,
                assetID: assetHistorical,
                sourceID: sourceA,
                relativePath: "2024/beach/old.jpg",
                fileName: "old.jpg",
                mediaType: "public.jpeg",
                createdMs: 1_500_000_000_000,
                modifiedMs: nil,
                availability: "available",
                locatorState: "historical"
            )
            try db.execute(
                sql: """
                UPDATE asset
                SET media_created_at_ms = ?, media_modified_at_ms = ?, file_name = ?, width = 4000, height = 3000
                WHERE id = ?
                """,
                arguments: [1_700_000_001_000, 1_700_000_001_100, "IMG_001.jpg", assetNewest.uuidString.lowercased()]
            )
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'folder', 'Work Drive', ?, 0, 0, 'unavailable', ?, ?)
                """,
                arguments: [
                    sourceB.uuidString.lowercased(),
                    DatabaseTestSupport.folderBookmark(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
            try insertAsset(
                db,
                assetID: UUID(uuidString: "20000000-0000-4000-8000-000000000006")!,
                sourceID: sourceB,
                relativePath: "projects/alpha.png",
                fileName: "alpha.png",
                mediaType: "public.png",
                createdMs: 1_650_000_000_000,
                modifiedMs: nil,
                availability: "available"
            )
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES
                    (?, 'Family', 'family', 'active', ?, ?),
                    (?, 'Work', 'work', 'active', ?, ?),
                    (?, 'Legacy', 'legacy', 'archived', ?, ?)
                """,
                arguments: [
                    tagFamily.uuidString.lowercased(), DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs,
                    tagWork.uuidString.lowercased(), DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs,
                    tagArchived.uuidString.lowercased(), DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES
                    (?, ?, 'accepted', ?),
                    (?, ?, 'rejected', ?),
                    (?, ?, 'accepted', ?)
                """,
                arguments: [
                    assetNewest.uuidString.lowercased(), tagFamily.uuidString.lowercased(), DatabaseTestSupport.timestampMs,
                    assetNewest.uuidString.lowercased(), tagWork.uuidString.lowercased(), DatabaseTestSupport.timestampMs,
                    assetMiddle.uuidString.lowercased(), tagFamily.uuidString.lowercased(), DatabaseTestSupport.timestampMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO file_fingerprint (asset_id, size_bytes, modified_at_ns, resource_id, sha256)
                VALUES (?, 12345, 9876543210, ?, ?)
                """,
                arguments: [
                    assetNewest.uuidString.lowercased(),
                    Data([0x01, 0x02]),
                    Data(repeating: 0xAB, count: 32),
                ]
            )
        }

        return FixtureIDs(
            sourceA: sourceA,
            sourceB: sourceB,
            assetNewest: assetNewest,
            assetMiddle: assetMiddle,
            assetOldest: assetOldest,
            assetNoTime: assetNoTime,
            assetHistorical: assetHistorical,
            tagFamily: tagFamily,
            tagWork: tagWork,
            tagArchived: tagArchived
        )
    }

    static func openV001OnlyDatabase(at url: URL) throws -> CatalogDatabase {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        let database = CatalogDatabase(pool: pool)
        let migrator = CatalogDatabase.makeV001OnlyMigrator()
        try migrator.migrate(pool)
        return database
    }

    private static func insertAsset(
        _ db: Database,
        assetID: UUID,
        sourceID: UUID,
        relativePath: String,
        fileName: String?,
        mediaType: String,
        createdMs: Int64?,
        modifiedMs: Int64?,
        availability: String,
        locatorState: String = "current"
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO asset (
                id, source_id, locator_kind, relative_path, photos_local_identifier,
                locator_state, media_type, media_created_at_ms, media_modified_at_ms,
                file_name, content_revision, availability, record_created_at_ms, record_updated_at_ms
            ) VALUES (?, ?, 'file', ?, NULL, ?, ?, ?, ?, ?, 1, ?, ?, ?)
            """,
            arguments: [
                assetID.uuidString.lowercased(),
                sourceID.uuidString.lowercased(),
                relativePath,
                locatorState,
                mediaType,
                createdMs,
                modifiedMs,
                fileName,
                availability,
                DatabaseTestSupport.timestampMs,
                DatabaseTestSupport.timestampMs,
            ]
        )
    }
}
