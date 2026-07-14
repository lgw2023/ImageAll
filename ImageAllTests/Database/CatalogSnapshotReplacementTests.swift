import XCTest
@testable import ImageAll

final class CatalogSnapshotReplacementTests: XCTestCase {
    func testSuccessfulReplaceRetainsPreRestoreBackupItemWithoutDeleteFirst() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        _ = try SnapshotTestSupport.seedRepresentativeFacts(in: database)

        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let descriptor = try SnapshotTestSupport.writePublishedSnapshot(
            in: backups,
            snapshotID: UUID(),
            sourceDatabase: database
        )

        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM job")
        }
        try database.checkpointAndCloseForReplacement()

        let operationID = UUID()
        let result = try CatalogDatabaseRestoreCoordinator().restoreSnapshot(
            snapshotDirectoryURL: descriptor.directoryURL,
            liveDatabaseURL: liveURL,
            operationID: operationID
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.preRestoreBackupItemURL.path))
        let backupCounts = try SnapshotTestSupport.factCounts(at: result.preRestoreBackupItemURL)
        XCTAssertEqual(backupCounts.jobs, 0)

        let restoredCounts = try SnapshotTestSupport.factCounts(at: result.restoredDatabaseURL)
        XCTAssertEqual(restoredCounts.jobs, 1)
        XCTAssertFalse(CatalogDatabaseSidecarHelpers.hasSidecars(at: result.restoredDatabaseURL))
        XCTAssertFalse(CatalogDatabaseSidecarHelpers.hasSidecars(at: result.preRestoreBackupItemURL))
    }

    func testInitialReplacementFailureLeavesLiveDatabaseUnchanged() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        _ = try SnapshotTestSupport.seedRepresentativeFacts(in: database)

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
                dependencies: .init(failInitialReplacement: true)
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .initialReplacementFailed)
        }

        XCTAssertEqual(try SnapshotTestSupport.databaseBytes(at: liveURL), beforeBytes)
    }

    func testPostReplaceValidationFailureRollsBackAndQuarantinesCandidate() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        _ = try SnapshotTestSupport.seedRepresentativeFacts(in: database)

        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let descriptor = try SnapshotTestSupport.writePublishedSnapshot(
            in: backups,
            snapshotID: UUID(),
            sourceDatabase: database
        )
        try database.checkpointAndCloseForReplacement()

        let operationID = UUID()
        let operationIDString = operationID.uuidString.lowercased()
        let beforeCounts = try SnapshotTestSupport.factCounts(at: liveURL)

        XCTAssertThrowsError(
            try CatalogDatabaseRestoreCoordinator().restoreSnapshot(
                snapshotDirectoryURL: descriptor.directoryURL,
                liveDatabaseURL: liveURL,
                operationID: operationID,
                dependencies: .init(failPostReplaceValidation: true)
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .postReplaceValidationFailedWithSuccessfulRollback)
        }

        XCTAssertEqual(try SnapshotTestSupport.factCounts(at: liveURL), beforeCounts)
        XCTAssertFalse(CatalogDatabaseSidecarHelpers.hasSidecars(at: liveURL))

        let quarantineURL = liveURL.deletingLastPathComponent()
            .appendingPathComponent("ImageAll.sqlite.quarantine-\(operationIDString)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
        XCTAssertFalse(CatalogDatabaseSidecarHelpers.hasSidecars(at: quarantineURL))
    }

    func testRollbackReplacementFailureReturnsManualIntervention() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        _ = try SnapshotTestSupport.seedRepresentativeFacts(in: database)

        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let descriptor = try SnapshotTestSupport.writePublishedSnapshot(
            in: backups,
            snapshotID: UUID(),
            sourceDatabase: database
        )
        try database.checkpointAndCloseForReplacement()

        XCTAssertThrowsError(
            try CatalogDatabaseRestoreCoordinator().restoreSnapshot(
                snapshotDirectoryURL: descriptor.directoryURL,
                liveDatabaseURL: liveURL,
                operationID: UUID(),
                dependencies: .init(
                    failPostReplaceValidation: true,
                    failRollbackReplacement: true
                )
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .manualInterventionRequired)
        }
    }

    func testCheckpointAndCloseRemovesLiveSidecars() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        _ = try SnapshotTestSupport.seedRepresentativeFacts(in: database)

        XCTAssertTrue(CatalogDatabaseSidecarHelpers.hasSidecars(at: liveURL))
        try database.checkpointAndCloseForReplacement()
        XCTAssertFalse(CatalogDatabaseSidecarHelpers.hasSidecars(at: liveURL))
    }
}
