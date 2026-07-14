import Foundation
import GRDB
import XCTest
@testable import ImageAll

enum SnapshotTestSupport {
    static let appVersion = "0.5.0-test"
    static let createdAtMs: Int64 = 1_750_000_000_000

    static func makeTempRoot(
        testCase: XCTestCase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAllSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    static func liveDatabaseURL(in root: URL) -> URL {
        root.appendingPathComponent("Catalog/ImageAll.sqlite")
    }

    static func backupsDirectoryURL(in root: URL) -> URL {
        root.appendingPathComponent("Backups", isDirectory: true)
    }

    static func openLiveDatabase(at url: URL) throws -> CatalogDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try CatalogDatabase.open(at: url)
    }

    static func seedRepresentativeFacts(in database: CatalogDatabase) throws -> (
        sourceID: UUID,
        assetID: UUID,
        tagID: UUID,
        jobID: UUID
    ) {
        let sourceID = UUID()
        let assetID = UUID()
        let tagID = UUID()
        let jobID = UUID()
        let repository = CatalogRepository(database: database)

        try repository.createSourceWithAsset(
            NewSourceWithAssetInput(
                sourceID: sourceID,
                sourceKind: .folder,
                displayName: "Archive",
                bookmark: DatabaseTestSupport.folderBookmark(),
                assetID: assetID,
                locatorKind: .file,
                relativePath: "photos/sample.jpg",
                photosLocalIdentifier: nil,
                mediaType: "public.jpeg",
                timestampMs: DatabaseTestSupport.timestampMs
            )
        )

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES (?, 'Family', 'family', 'active', ?, ?)
                """,
                arguments: [
                    tagID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'accepted', ?)
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    tagID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, state, control_request, priority,
                    attempts, max_attempts, not_before_ms, progress_completed, created_at_ms, updated_at_ms
                ) VALUES (?, 'test.fake', 1, ?, 'pending', 'none', 0, 0, 3, ?, 0, ?, ?)
                """,
                arguments: [
                    jobID.uuidString.lowercased(),
                    Data("payload".utf8),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        }

        return (sourceID, assetID, tagID, jobID)
    }

    static func populateManyPages(in database: CatalogDatabase, rowCount: Int = 256) throws {
        try database.pool.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS backup_padding (id INTEGER PRIMARY KEY, payload BLOB NOT NULL)")
            for index in 0..<rowCount {
                let payload = Data(repeating: UInt8(index % 251), count: 4096)
                try db.execute(
                    sql: "INSERT INTO backup_padding (payload) VALUES (?)",
                    arguments: [payload]
                )
            }
        }
    }

    static func makeManifest(
        snapshotID: String,
        appliedMigrations: [String] = CatalogMigrationID.knownOrdered,
        databaseBytes: Int64 = 1,
        databaseSHA256: String = String(repeating: "a", count: 64)
    ) -> CatalogSnapshotManifest {
        CatalogSnapshotManifest(
            formatVersion: 1,
            snapshotID: snapshotID,
            createdAtMs: createdAtMs,
            appVersion: appVersion,
            appliedMigrations: appliedMigrations,
            databaseFilename: CatalogSnapshotConstants.databaseFilename,
            databaseBytes: databaseBytes,
            databaseSHA256: databaseSHA256
        )
    }

    static func writePublishedSnapshot(
        in backupsDirectory: URL,
        snapshotID: UUID,
        sourceDatabase: CatalogDatabase,
        createdAtMs: Int64 = SnapshotTestSupport.createdAtMs
    ) throws -> CatalogSnapshotDescriptor {
        let creator = CatalogSnapshotCreator(sourceDatabase: sourceDatabase)
        return try creator.createManualSnapshot(
            snapshotID: snapshotID,
            createdAtMs: createdAtMs,
            appVersion: appVersion,
            backupsDirectoryURL: backupsDirectory
        )
    }

    static func createEmptySQLite(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            _ = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }
        try queue.close()
        try CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(at: url)
    }

    struct FactCounts: Equatable {
        let sources: Int
        let assets: Int
        let tags: Int
        let decisions: Int
        let jobs: Int
    }

    static func factCounts(in database: CatalogDatabase) throws -> FactCounts {
        try database.pool.read { db in
            FactCounts(
                sources: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") ?? 0,
                assets: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0,
                tags: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag") ?? 0,
                decisions: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tag_decision") ?? 0,
                jobs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job") ?? 0
            )
        }
    }

    static func factCounts(at databaseURL: URL) throws -> FactCounts {
        var config = Configuration()
        let pool = try DatabasePool(path: databaseURL.path, configuration: config)
        let counts = try pool.read { db in
            FactCounts(
                sources: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") ?? 0,
                assets: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0,
                tags: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag") ?? 0,
                decisions: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tag_decision") ?? 0,
                jobs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job") ?? 0
            )
        }
        try pool.close()
        try? CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(at: databaseURL)
        return counts
    }

    static func readMigrationIDs(at databaseURL: URL) throws -> [String] {
        var config = Configuration()
        let pool = try DatabasePool(path: databaseURL.path, configuration: config)
        defer {
            try? pool.close()
        }
        return try pool.read { db in
            try CatalogDatabase.readAppliedMigrationIDs(from: db)
        }
    }

    static func databaseBytes(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}
