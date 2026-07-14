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
        try factCountsReadOnly(at: databaseURL)
    }

    static func readMigrationIDs(at databaseURL: URL) throws -> [String] {
        try CatalogDatabase.withReadonlyQueue(at: databaseURL) { db in
            try CatalogDatabase.readAppliedMigrationIDs(from: db)
        }
    }

    static func databaseBytes(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    static func sha256Hex(at url: URL) throws -> String {
        try CatalogSnapshotHashing.sha256Hex(of: url)
    }

    static func readJournalMode(at databaseURL: URL) throws -> String {
        try CatalogDatabase.withReadonlyQueue(at: databaseURL) { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
        }
    }

    static func validatePublishedSnapshotReadOnly(at databaseURL: URL) throws {
        try CatalogDatabase.withReadonlyQueue(at: databaseURL) { db in
            try CatalogDatabase.performQuickCheck(on: db)
            let migrations = try CatalogDatabase.readAppliedMigrationIDs(from: db)
            try CatalogSnapshotManifestValidator.validateMigrationPrefix(migrations)
        }
    }

    static func corruptDestinationQuickCheck(at databaseURL: URL) throws {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try db.execute(sql: "PRAGMA writable_schema = ON")
            try db.execute(sql: "UPDATE sqlite_schema SET rootpage = 0 WHERE name = 'job'")
        }
        try queue.close()
        let verify = try DatabaseQueue(path: databaseURL.path)
        let results = try verify.read { db in
            try String.fetchAll(db, sql: "PRAGMA quick_check")
        }
        try verify.close()
        XCTAssertNotEqual(results, ["ok"])
    }

    static func factCountsReadOnly(at databaseURL: URL) throws -> FactCounts {
        try CatalogDatabase.withReadonlyQueue(at: databaseURL) { db in
            FactCounts(
                sources: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") ?? 0,
                assets: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0,
                tags: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag") ?? 0,
                decisions: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tag_decision") ?? 0,
                jobs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job") ?? 0
            )
        }
    }
}

// MARK: - Test-only fault injection (ImageAllTests only)

final class FaultInjectingCatalogDatabaseFileReplacer: CatalogDatabaseFileReplacing, @unchecked Sendable {
    let underlying: any CatalogDatabaseFileReplacing
    var failInitialReplacement: Bool
    var failRollbackReplacement: Bool
    var deleteRetainedBackupAfterFirstReplace: Bool
    private let lock = NSLock()
    private(set) var replacementCallCount = 0

    init(
        underlying: any CatalogDatabaseFileReplacing = FoundationCatalogDatabaseFileReplacer(),
        failInitialReplacement: Bool = false,
        failRollbackReplacement: Bool = false,
        deleteRetainedBackupAfterFirstReplace: Bool = false
    ) {
        self.underlying = underlying
        self.failInitialReplacement = failInitialReplacement
        self.failRollbackReplacement = failRollbackReplacement
        self.deleteRetainedBackupAfterFirstReplace = deleteRetainedBackupAfterFirstReplace
    }

    func replaceItem(
        at originalItemURL: URL,
        withItemAt newItemURL: URL,
        backupItemName: String,
        options: FileManager.ItemReplacementOptions
    ) throws -> URL {
        lock.lock()
        replacementCallCount += 1
        let callCount = replacementCallCount
        lock.unlock()

        if failInitialReplacement && callCount == 1 {
            throw CatalogSnapshotError.initialReplacementFailed
        }
        if failRollbackReplacement && callCount == 2 {
            throw CatalogSnapshotError.rollbackReplacementFailed
        }

        let resultingURL = try underlying.replaceItem(
            at: originalItemURL,
            withItemAt: newItemURL,
            backupItemName: backupItemName,
            options: options
        )

        if deleteRetainedBackupAfterFirstReplace && callCount == 1 {
            let retainedBackupURL = originalItemURL.deletingLastPathComponent()
                .appendingPathComponent(backupItemName)
            try? FileManager.default.removeItem(at: retainedBackupURL)
        }

        return resultingURL
    }
}

struct FaultInjectingCatalogPostReplaceValidator: CatalogPostReplaceValidator {
    var shouldFail: Bool
    var shouldFailWithCloseFailed: Bool
    let underlying: any CatalogPostReplaceValidator

    init(
        shouldFail: Bool = false,
        shouldFailWithCloseFailed: Bool = false,
        underlying: any CatalogPostReplaceValidator = DefaultCatalogPostReplaceValidator()
    ) {
        self.shouldFail = shouldFail
        self.shouldFailWithCloseFailed = shouldFailWithCloseFailed
        self.underlying = underlying
    }

    func validateDatabase(at url: URL) throws {
        if shouldFailWithCloseFailed {
            throw CatalogSnapshotError.closeFailed
        }
        if shouldFail {
            throw CatalogSnapshotError.postReplaceValidationFailed
        }
        try underlying.validateDatabase(at: url)
    }
}
