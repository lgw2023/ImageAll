import GRDB
import XCTest
@testable import ImageAll

final class CatalogSnapshotRestoreTests: XCTestCase {
    func testSameSchemaRestoreMatchesSnapshotFactsWithoutChangingLiveBeforeReplacement() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        _ = try SnapshotTestSupport.seedRepresentativeFacts(in: database)

        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let snapshotID = UUID()
        let descriptor = try SnapshotTestSupport.writePublishedSnapshot(
            in: backups,
            snapshotID: snapshotID,
            sourceDatabase: database
        )

        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM job")
        }
        try database.checkpointAndCloseForReplacement()

        let beforeCounts = try SnapshotTestSupport.factCounts(at: liveURL)
        let result = try CatalogDatabaseRestoreCoordinator().restoreSnapshot(
            snapshotDirectoryURL: descriptor.directoryURL,
            liveDatabaseURL: liveURL,
            operationID: UUID()
        )

        XCTAssertEqual(try SnapshotTestSupport.factCounts(at: result.restoredDatabaseURL).jobs, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.preRestoreBackupItemURL.path))
        XCTAssertEqual(try SnapshotTestSupport.factCounts(at: result.preRestoreBackupItemURL).jobs, 0)
        XCTAssertEqual(try SnapshotTestSupport.factCounts(at: result.preRestoreBackupItemURL), beforeCounts)
    }

    func testEmptyPrefixSnapshotUpgradesOnlyOnWorkCopyAndLeavesPublishedSnapshotImmutable() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let emptyURL = root.appendingPathComponent("empty/ImageAll.sqlite")
        try SnapshotTestSupport.createEmptySQLite(at: emptyURL)

        let snapshotID = UUID()
        let emptyDir = backups.appendingPathComponent(snapshotID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let snapshotDB = emptyDir.appendingPathComponent(CatalogSnapshotConstants.databaseFilename)
        try FileManager.default.copyItem(at: emptyURL, to: snapshotDB)
        let beforeSnapshotBytes = try SnapshotTestSupport.databaseBytes(at: snapshotDB)
        let beforeSnapshotSHA = try SnapshotTestSupport.sha256Hex(at: snapshotDB)
        let bytes = try CatalogSnapshotHashing.fileSize(of: snapshotDB)
        let sha = try CatalogSnapshotHashing.sha256Hex(of: snapshotDB)
        let manifest = SnapshotTestSupport.makeManifest(
            snapshotID: snapshotID.uuidString.lowercased(),
            appliedMigrations: [],
            databaseBytes: bytes,
            databaseSHA256: sha
        )
        try CatalogSnapshotManifestCodec.encode(manifest).write(
            to: emptyDir.appendingPathComponent(CatalogSnapshotConstants.manifestFilename)
        )

        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let liveDatabase = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        _ = try SnapshotTestSupport.seedRepresentativeFacts(in: liveDatabase)
        try liveDatabase.checkpointAndCloseForReplacement()

        let result = try CatalogDatabaseRestoreCoordinator().restoreSnapshot(
            snapshotDirectoryURL: emptyDir,
            liveDatabaseURL: liveURL,
            operationID: UUID()
        )

        let restored = try CatalogDatabase.open(at: result.restoredDatabaseURL)
        XCTAssertEqual(try restored.appliedMigrationIDs(), CatalogMigrationID.knownOrdered)
        let snapshotMigrations = try SnapshotTestSupport.readMigrationIDs(at: snapshotDB)
        XCTAssertTrue(snapshotMigrations.isEmpty)

        XCTAssertEqual(try SnapshotTestSupport.databaseBytes(at: snapshotDB), beforeSnapshotBytes)
        XCTAssertEqual(try SnapshotTestSupport.sha256Hex(at: snapshotDB), beforeSnapshotSHA)
        XCTAssertFalse(CatalogDatabaseSidecarHelpers.hasSidecars(at: snapshotDB))
        XCTAssertFalse(CatalogDatabaseSidecarHelpers.hasSidecars(at: emptyDir.appendingPathComponent(CatalogSnapshotConstants.manifestFilename)))
    }

    func testFutureMigrationSnapshotIsRejectedBeforeReplacement() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)

        let snapshotID = UUID()
        let descriptor = try SnapshotTestSupport.writePublishedSnapshot(
            in: backups,
            snapshotID: snapshotID,
            sourceDatabase: database
        )
        let snapshotDB = descriptor.directoryURL.appendingPathComponent(CatalogSnapshotConstants.databaseFilename)

        var config = Configuration()
        let pool = try DatabasePool(path: snapshotDB.path, configuration: config)
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v002_future')")
        }
        try CatalogDatabase.closePool(pool)
        try CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(at: snapshotDB)

        let bytes = try CatalogSnapshotHashing.fileSize(of: snapshotDB)
        let sha = try CatalogSnapshotHashing.sha256Hex(of: snapshotDB)
        let badManifest = SnapshotTestSupport.makeManifest(
            snapshotID: snapshotID.uuidString.lowercased(),
            appliedMigrations: CatalogMigrationID.knownOrdered,
            databaseBytes: bytes,
            databaseSHA256: sha
        )
        try CatalogSnapshotManifestCodec.encode(badManifest).write(
            to: descriptor.directoryURL.appendingPathComponent(CatalogSnapshotConstants.manifestFilename)
        )

        try database.checkpointAndCloseForReplacement()
        let beforeBytes = try SnapshotTestSupport.databaseBytes(at: liveURL)

        XCTAssertThrowsError(
            try CatalogDatabaseRestoreCoordinator().restoreSnapshot(
                snapshotDirectoryURL: descriptor.directoryURL,
                liveDatabaseURL: liveURL,
                operationID: UUID()
            )
        ) { error in
            if case .futureMigrationHistory = error as? CatalogSnapshotError {
                // expected
            } else {
                XCTFail("Expected futureMigrationHistory, got \(error)")
            }
        }

        XCTAssertEqual(try SnapshotTestSupport.databaseBytes(at: liveURL), beforeBytes)
    }

    func testManifestDatabaseMigrationMismatchIsRejectedBeforeReplacement() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        let descriptor = try SnapshotTestSupport.writePublishedSnapshot(
            in: backups,
            snapshotID: UUID(),
            sourceDatabase: database
        )

        let mismatchedManifest = SnapshotTestSupport.makeManifest(
            snapshotID: descriptor.snapshotID,
            appliedMigrations: [],
            databaseBytes: descriptor.manifest.databaseBytes,
            databaseSHA256: descriptor.manifest.databaseSHA256
        )
        try CatalogSnapshotManifestCodec.encode(mismatchedManifest).write(
            to: descriptor.directoryURL.appendingPathComponent(CatalogSnapshotConstants.manifestFilename)
        )

        try database.checkpointAndCloseForReplacement()

        XCTAssertThrowsError(
            try CatalogDatabaseRestoreCoordinator().restoreSnapshot(
                snapshotDirectoryURL: descriptor.directoryURL,
                liveDatabaseURL: liveURL,
                operationID: UUID()
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .migrationHistoryMismatch)
        }
    }

    func testLiveSidecarPreconditionFailurePreventsReplacement() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let descriptor = try SnapshotTestSupport.writePublishedSnapshot(
            in: backups,
            snapshotID: UUID(),
            sourceDatabase: database
        )

        let beforeBytes = try SnapshotTestSupport.databaseBytes(at: liveURL)

        XCTAssertThrowsError(
            try CatalogDatabaseRestoreCoordinator().restoreSnapshot(
                snapshotDirectoryURL: descriptor.directoryURL,
                liveDatabaseURL: liveURL,
                operationID: UUID()
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .replacementPreconditionNotMet)
        }

        XCTAssertEqual(try SnapshotTestSupport.databaseBytes(at: liveURL), beforeBytes)
        _ = database
    }

    func testDifferentVolumeWorkCandidateIsRejected() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let descriptor = try SnapshotTestSupport.writePublishedSnapshot(
            in: backups,
            snapshotID: UUID(),
            sourceDatabase: database
        )
        try database.checkpointAndCloseForReplacement()

        let volumeCheckCapture = VolumeCheckCapture()

        XCTAssertThrowsError(
            try CatalogDatabaseRestoreCoordinator().restoreSnapshot(
                snapshotDirectoryURL: descriptor.directoryURL,
                liveDatabaseURL: liveURL,
                operationID: UUID(),
                dependencies: .init(sameVolumeChecker: { candidate, live in
                    volumeCheckCapture.record(candidate: candidate, live: live)
                    return false
                })
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .differentVolume)
        }

        XCTAssertEqual(volumeCheckCapture.live, liveURL)
        XCTAssertEqual(volumeCheckCapture.candidate?.lastPathComponent, CatalogSnapshotConstants.databaseFilename)
        XCTAssertTrue(volumeCheckCapture.candidate?.path.contains(".restore-") == true)
        XCTAssertNotEqual(volumeCheckCapture.candidate?.deletingLastPathComponent().path, descriptor.directoryURL.path)
    }

    func testSnapshotOnDifferentVolumeFromLiveCanRestoreWhenWorkCandidateIsSameVolume() throws {
        let liveRoot = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let snapshotRoot = try SnapshotTestSupport.makeTempRoot(testCase: self)

        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: liveRoot)
        let liveDatabase = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        _ = try SnapshotTestSupport.seedRepresentativeFacts(in: liveDatabase)

        let snapshotBackups = SnapshotTestSupport.backupsDirectoryURL(in: snapshotRoot)
        let descriptor = try SnapshotTestSupport.writePublishedSnapshot(
            in: snapshotBackups,
            snapshotID: UUID(),
            sourceDatabase: liveDatabase
        )

        try liveDatabase.checkpointAndCloseForReplacement()

        let result = try CatalogDatabaseRestoreCoordinator().restoreSnapshot(
            snapshotDirectoryURL: descriptor.directoryURL,
            liveDatabaseURL: liveURL,
            operationID: UUID()
        )

        XCTAssertEqual(try SnapshotTestSupport.factCounts(at: result.restoredDatabaseURL).sources, 1)
    }

    func testSameVolumeCheckerThrowMapsToDifferentVolume() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let descriptor = try SnapshotTestSupport.writePublishedSnapshot(
            in: backups,
            snapshotID: UUID(),
            sourceDatabase: database
        )
        try database.checkpointAndCloseForReplacement()
        let beforeBytes = try SnapshotTestSupport.databaseBytes(at: liveURL)

        XCTAssertThrowsError(
            try CatalogDatabaseRestoreCoordinator().restoreSnapshot(
                snapshotDirectoryURL: descriptor.directoryURL,
                liveDatabaseURL: liveURL,
                operationID: UUID(),
                dependencies: .init(sameVolumeChecker: { _, _ in
                    struct Probe: Error {}
                    throw Probe()
                })
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .differentVolume)
        }

        XCTAssertEqual(try SnapshotTestSupport.databaseBytes(at: liveURL), beforeBytes)
    }
}

private final class VolumeCheckCapture: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var candidate: URL?
    private(set) var live: URL?

    func record(candidate: URL, live: URL) {
        lock.lock()
        self.candidate = candidate
        self.live = live
        lock.unlock()
    }
}
