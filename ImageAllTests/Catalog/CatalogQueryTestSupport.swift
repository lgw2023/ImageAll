import Foundation
import GRDB
import XCTest
@testable import ImageAll

enum CatalogQueryTestSupport {
    struct FixtureIDs: Sendable {
        let sourceA: UUID
        let sourceB: UUID
        let sourceC: UUID
        let sourceD: UUID
        let assetNewest: UUID
        let assetMiddle: UUID
        let assetOldest: UUID
        let assetNoTime: UUID
        let assetHistorical: UUID
        let assetActive: UUID
        let assetAuthRequired: UUID
        let assetDuplicateTimeA: UUID
        let assetDuplicateTimeB: UUID
        let assetNocaseLower: UUID
        let assetNocaseUpper: UUID
        let assetLiteralWildcard: UUID
        let assetLiteralBackslash: UUID
        let assetDecoyWildcard: UUID
        let assetDecoyUnderscore: UUID
        let assetDecoyBackslash: UUID
        let assetSourceB: UUID
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

    static func openFaultDatabase() throws -> (
        database: CatalogDatabase,
        tags: GRDBTagCatalogRepository,
        repository: CatalogRepository
    ) {
        let url = try DatabaseTestSupport.makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        try database.pool.write { db in
            try CatalogQueryTestFaultSupport.installFaultInfrastructure(on: db)
        }
        let repository = CatalogRepository(database: database)
        let tags = GRDBTagCatalogRepository(database: database)
        return (database, tags, repository)
    }

    @discardableResult
    static func seedCatalogFixture(
        database: CatalogDatabase,
        repository: CatalogRepository
    ) throws -> FixtureIDs {
        let sourceA = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let sourceB = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        let sourceC = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
        let sourceD = UUID(uuidString: "10000000-0000-4000-8000-000000000004")!
        let assetNewest = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let assetMiddle = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
        let assetOldest = UUID(uuidString: "20000000-0000-4000-8000-000000000003")!
        let assetNoTime = UUID(uuidString: "20000000-0000-4000-8000-000000000004")!
        let assetHistorical = UUID(uuidString: "20000000-0000-4000-8000-000000000005")!
        let assetActive = UUID(uuidString: "20000000-0000-4000-8000-000000000006")!
        let assetAuthRequired = UUID(uuidString: "20000000-0000-4000-8000-000000000007")!
        let assetDuplicateTimeA = UUID(uuidString: "20000000-0000-4000-8000-000000000008")!
        let assetDuplicateTimeB = UUID(uuidString: "20000000-0000-4000-8000-000000000009")!
        let assetNocaseLower = UUID(uuidString: "20000000-0000-4000-8000-00000000000A")!
        let assetNocaseUpper = UUID(uuidString: "20000000-0000-4000-8000-00000000000B")!
        let assetLiteralWildcard = UUID(uuidString: "20000000-0000-4000-8000-00000000000C")!
        let assetLiteralBackslash = UUID(uuidString: "20000000-0000-4000-8000-00000000000D")!
        let assetDecoyWildcard = UUID(uuidString: "20000000-0000-4000-8000-00000000000F")!
        let assetDecoyUnderscore = UUID(uuidString: "20000000-0000-4000-8000-000000000010")!
        let assetDecoyBackslash = UUID(uuidString: "20000000-0000-4000-8000-000000000011")!
        let assetSourceB = UUID(uuidString: "20000000-0000-4000-8000-00000000000E")!
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
            try insertAsset(
                db,
                assetID: assetDuplicateTimeA,
                sourceID: sourceA,
                relativePath: "2024/beach/dup-a.jpg",
                fileName: "dup-a.jpg",
                mediaType: "public.jpeg",
                createdMs: 1_650_000_000_000,
                modifiedMs: nil,
                availability: "available"
            )
            try insertAsset(
                db,
                assetID: assetDuplicateTimeB,
                sourceID: sourceA,
                relativePath: "2024/beach/dup-b.jpg",
                fileName: "dup-b.jpg",
                mediaType: "public.jpeg",
                createdMs: 1_650_000_000_000,
                modifiedMs: nil,
                availability: "available"
            )
            try insertAsset(
                db,
                assetID: assetNocaseLower,
                sourceID: sourceA,
                relativePath: "2024/beach/cover-a.jpg",
                fileName: "AlbumCover.jpg",
                mediaType: "public.jpeg",
                createdMs: 1_640_000_000_000,
                modifiedMs: nil,
                availability: "available"
            )
            try insertAsset(
                db,
                assetID: assetNocaseUpper,
                sourceID: sourceA,
                relativePath: "2024/beach/cover-b.jpg",
                fileName: "albumcover.jpg",
                mediaType: "public.jpeg",
                createdMs: 1_640_000_000_001,
                modifiedMs: nil,
                availability: "available"
            )
            try insertAsset(
                db,
                assetID: assetLiteralWildcard,
                sourceID: sourceA,
                relativePath: "2024/beach/100%_complete.jpg",
                fileName: "100%_complete.jpg",
                mediaType: "public.jpeg",
                createdMs: 1_630_000_000_000,
                modifiedMs: nil,
                availability: "available"
            )
            try insertAsset(
                db,
                assetID: assetLiteralBackslash,
                sourceID: sourceA,
                relativePath: "2024/beach/weird\\segment.jpg",
                fileName: "weird\\segment.jpg",
                mediaType: "public.jpeg",
                createdMs: 1_620_000_000_000,
                modifiedMs: nil,
                availability: "available"
            )
            try insertAsset(
                db,
                assetID: assetDecoyWildcard,
                sourceID: sourceA,
                relativePath: "2024/beach/100ABcomplete.jpg",
                fileName: "100ABcomplete.jpg",
                mediaType: "public.jpeg",
                createdMs: 1_619_000_000_000,
                modifiedMs: nil,
                availability: "available"
            )
            try insertAsset(
                db,
                assetID: assetDecoyUnderscore,
                sourceID: sourceA,
                relativePath: "2024/beach/imgX002.jpg",
                fileName: "imgX002.jpg",
                mediaType: "public.jpeg",
                createdMs: 1_618_000_000_000,
                modifiedMs: nil,
                availability: "available"
            )
            try insertAsset(
                db,
                assetID: assetDecoyBackslash,
                sourceID: sourceA,
                relativePath: "2024/beach/weirdXsegment.jpg",
                fileName: "weirdXsegment.jpg",
                mediaType: "public.jpeg",
                createdMs: 1_617_000_000_000,
                modifiedMs: nil,
                availability: "available"
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
                assetID: assetSourceB,
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
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'folder', 'Active Library', ?, 0, 0, 'active', ?, ?)
                """,
                arguments: [
                    sourceC.uuidString.lowercased(),
                    DatabaseTestSupport.folderBookmark(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
            try insertAsset(
                db,
                assetID: assetActive,
                sourceID: sourceC,
                relativePath: "live/photo.jpg",
                fileName: "photo.jpg",
                mediaType: "public.jpeg",
                createdMs: 1_610_000_000_000,
                modifiedMs: nil,
                availability: "available"
            )
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'photos', 'Needs Auth', NULL, 0, 0, 'authorizationRequired', ?, ?)
                """,
                arguments: [
                    sourceD.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
            try insertAsset(
                db,
                assetID: assetAuthRequired,
                sourceID: sourceD,
                relativePath: nil,
                fileName: nil,
                mediaType: "public.heic",
                createdMs: 1_605_000_000_000,
                modifiedMs: nil,
                availability: "available",
                locatorKind: "photos",
                photosLocalIdentifier: "AUTH-LOCAL-ID"
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
            sourceC: sourceC,
            sourceD: sourceD,
            assetNewest: assetNewest,
            assetMiddle: assetMiddle,
            assetOldest: assetOldest,
            assetNoTime: assetNoTime,
            assetHistorical: assetHistorical,
            assetActive: assetActive,
            assetAuthRequired: assetAuthRequired,
            assetDuplicateTimeA: assetDuplicateTimeA,
            assetDuplicateTimeB: assetDuplicateTimeB,
            assetNocaseLower: assetNocaseLower,
            assetNocaseUpper: assetNocaseUpper,
            assetLiteralWildcard: assetLiteralWildcard,
            assetLiteralBackslash: assetLiteralBackslash,
            assetDecoyWildcard: assetDecoyWildcard,
            assetDecoyUnderscore: assetDecoyUnderscore,
            assetDecoyBackslash: assetDecoyBackslash,
            assetSourceB: assetSourceB,
            tagFamily: tagFamily,
            tagWork: tagWork,
            tagArchived: tagArchived
        )
    }

    static func decisionStates(
        database: CatalogDatabase,
        tagID: UUID,
        assetIDs: [UUID]
    ) throws -> [UUID: TagDecisionQueryState] {
        try database.pool.read { db in
            var states: [UUID: TagDecisionQueryState] = [:]
            for assetID in assetIDs {
                states[assetID] = .unknown
            }
            for assetID in assetIDs {
                let decision: String? = try String.fetchOne(
                    db,
                    sql: """
                    SELECT decision FROM asset_tag_decision
                    WHERE asset_id = ? AND tag_id = ?
                    """,
                    arguments: [assetID.uuidString.lowercased(), tagID.uuidString.lowercased()]
                )
                if let decision {
                    states[assetID] = decision == "accepted" ? .accepted : .rejected
                }
            }
            return states
        }
    }

    static func openV001OnlyDatabase(at url: URL) throws -> CatalogDatabase {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        let database = CatalogDatabase(pool: pool)
        let migrator = DatabaseTestSupport.makeV001OnlyMigrator()
        try migrator.migrate(pool)
        return database
    }

    private static func insertAsset(
        _ db: Database,
        assetID: UUID,
        sourceID: UUID,
        relativePath: String?,
        fileName: String?,
        mediaType: String,
        createdMs: Int64?,
        modifiedMs: Int64?,
        availability: String,
        locatorState: String = "current",
        locatorKind: String = "file",
        photosLocalIdentifier: String? = nil
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO asset (
                id, source_id, locator_kind, relative_path, photos_local_identifier,
                locator_state, media_type, media_created_at_ms, media_modified_at_ms,
                file_name, content_revision, availability, record_created_at_ms, record_updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
            """,
            arguments: [
                assetID.uuidString.lowercased(),
                sourceID.uuidString.lowercased(),
                locatorKind,
                relativePath,
                photosLocalIdentifier,
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
