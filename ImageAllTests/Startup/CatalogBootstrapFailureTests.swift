import GRDB
import XCTest
@testable import ImageAll

final class CatalogBootstrapFailureTests: XCTestCase {
    func testSnapshotFailureDoesNotBecomeReadyOrMigrateFormalDatabase() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedLegacyDatabaseWithSentinel(at: paths.catalogDatabaseURL)

        let dependencies = StartupTestSupport.makeDependencies(
            root: root,
            snapshotFailureHook: { throw CatalogSnapshotError.integrityCheckFailed }
        )
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .unavailable(reason) = result else {
            return XCTFail("Expected unavailable")
        }
        XCTAssertEqual(reason, .snapshotFailed)
        XCTAssertEqual(try SnapshotTestSupport.readMigrationIDs(at: paths.catalogDatabaseURL), [])
        XCTAssertEqual(
            try StartupTestSupport.readLegacySentinelPayload(at: paths.catalogDatabaseURL),
            LegacyStartupTestSupport.sentinelPayload
        )
    }

    func testWorkCopyMigrationFailureDoesNotBecomeReady() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedLegacyDatabaseWithMigrationConflict(at: paths.catalogDatabaseURL)

        let dependencies = StartupTestSupport.makeDependencies(root: root)
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .unavailable(reason) = result else {
            return XCTFail("Expected unavailable")
        }
        XCTAssertEqual(reason, .publicationFailed)
        XCTAssertEqual(try SnapshotTestSupport.readMigrationIDs(at: paths.catalogDatabaseURL), [])
        XCTAssertEqual(
            try StartupTestSupport.readLegacySentinelPayload(at: paths.catalogDatabaseURL),
            LegacyStartupTestSupport.sentinelPayload
        )
    }

    func testInitialReplacementFailureKeepsOriginalFacts() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedLegacyDatabaseWithSentinel(at: paths.catalogDatabaseURL)

        let dependencies = StartupTestSupport.makeDependencies(
            root: root,
            fileReplacer: FaultInjectingCatalogDatabaseFileReplacer(failInitialReplacement: true)
        )
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .unavailable(reason) = result else {
            return XCTFail("Expected unavailable")
        }
        XCTAssertEqual(reason, .publicationFailed)
        XCTAssertEqual(try SnapshotTestSupport.readMigrationIDs(at: paths.catalogDatabaseURL), [])
        XCTAssertEqual(
            try StartupTestSupport.readLegacySentinelPayload(at: paths.catalogDatabaseURL),
            LegacyStartupTestSupport.sentinelPayload
        )
    }

    func testPostReplaceValidationFailureRollsBackOriginalFactsAndDoesNotBecomeReady() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedLegacyDatabaseWithSentinel(at: paths.catalogDatabaseURL)

        let dependencies = StartupTestSupport.makeDependencies(
            root: root,
            postReplaceValidator: FaultInjectingCatalogPostReplaceValidator(shouldFail: true)
        )
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .unavailable(reason) = result else {
            return XCTFail("Expected unavailable")
        }
        XCTAssertEqual(reason, .publicationFailed)
        XCTAssertEqual(try SnapshotTestSupport.readMigrationIDs(at: paths.catalogDatabaseURL), [])
        XCTAssertEqual(
            try StartupTestSupport.readLegacySentinelPayload(at: paths.catalogDatabaseURL),
            LegacyStartupTestSupport.sentinelPayload
        )
    }

    func testRollbackFailureDoesNotBecomeReady() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedLegacyDatabaseWithSentinel(at: paths.catalogDatabaseURL)

        let dependencies = StartupTestSupport.makeDependencies(
            root: root,
            fileReplacer: FaultInjectingCatalogDatabaseFileReplacer(
                failInitialReplacement: false,
                failRollbackReplacement: true
            ),
            postReplaceValidator: FaultInjectingCatalogPostReplaceValidator(shouldFail: true)
        )
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .unavailable(reason) = result else {
            return XCTFail("Expected unavailable")
        }
        XCTAssertEqual(reason, .publicationFailed)
    }

    func testFinalOpenFailureDoesNotBecomeReadyAndReleasesLock() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.makePathsResolver(root: root).ensureRequiredDirectories(for: paths)

        let dependencies = StartupTestSupport.makeDependencies(
            root: root,
            openCurrentSchema: { _ in
                throw CatalogDatabaseError.integrityCheckFailed
            }
        )
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .unavailable(reason) = result else {
            return XCTFail("Expected unavailable")
        }
        XCTAssertEqual(reason, .finalOpenFailed)

        let second = try DarwinCatalogProcessLock().tryAcquire(at: paths.catalogLockFileURL)
        guard case let .acquired(token) = second else {
            return XCTFail("Expected lock release after final open failure")
        }
        token.release()
    }

    func testRecoveryFailureDoesNotBecomeReady() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        _ = try StartupTestSupport.seedCurrentSchemaDatabase(at: paths.catalogDatabaseURL)

        let dependencies = StartupTestSupport.makeDependencies(
            root: root,
            recoveryFailureHook: {
                throw JobQueueError.invalidClaimInput(reason: "forced recovery failure")
            }
        )
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .unavailable(reason) = result else {
            return XCTFail("Expected unavailable")
        }
        XCTAssertEqual(reason, .recoveryFailed)
    }

    func testRecoveryFailureClosesDatabaseBeforeReleasingLock() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        _ = try StartupTestSupport.seedCurrentSchemaDatabase(at: paths.catalogDatabaseURL)
        try StartupTestSupport.insertInterruptedRunningJob(at: paths.catalogDatabaseURL)

        let recorder = RecoveryCleanupRecorder()
        let dependencies = StartupTestSupport.makeDependencies(
            root: root,
            recoveryFailureHook: {
                throw JobQueueError.invalidClaimInput(reason: "forced recovery failure")
            },
            closeDatabasePool: { pool in
                recorder.record("close")
                try pool.close()
            },
            onLockReleased: {
                recorder.record("lockReleased")
            }
        )
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .unavailable(reason) = result else {
            return XCTFail("Expected recovery failure")
        }
        XCTAssertEqual(reason, .recoveryFailed)
        XCTAssertEqual(recorder.snapshot(), ["close", "lockReleased"])
    }

    func testRecoveryFailureCloseErrorKeepsLockHeld() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        _ = try StartupTestSupport.seedCurrentSchemaDatabase(at: paths.catalogDatabaseURL)
        try StartupTestSupport.insertInterruptedRunningJob(at: paths.catalogDatabaseURL)

        let lockReleaseRecorder = LockReleaseRecorder()
        let dependencies = StartupTestSupport.makeDependencies(
            root: root,
            recoveryFailureHook: {
                throw JobQueueError.invalidClaimInput(reason: "forced recovery failure")
            },
            closeDatabasePool: { _ in
                throw CatalogSnapshotError.closeFailed
            },
            onLockReleased: {
                lockReleaseRecorder.recordRelease()
            }
        )
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .unavailable(reason) = result else {
            return XCTFail("Expected recovery failure")
        }
        XCTAssertEqual(reason, .recoveryFailed)
        XCTAssertEqual(lockReleaseRecorder.releaseCount, 0)

        let second = try DarwinCatalogProcessLock().tryAcquire(at: paths.catalogLockFileURL)
        XCTAssertEqual(second, .alreadyRunning)
    }

    func testOldSchemaMigrationInvokesCheckpointBeforeRestore() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedLegacyDatabaseWithSentinel(at: paths.catalogDatabaseURL)

        let recorder = FormalCheckpointCloseRecorder()
        let sidecarState = SidecarStateRecorder()
        let dependencies = StartupTestSupport.makeDependencies(
            root: root,
            checkpointAndCloseFormalDatabase: { url in
                recorder.recordCall()
                let database = try CatalogDatabase.openWithoutMigration(at: url)
                try database.checkpointAndCloseForReplacement()
                sidecarState.recordPostCheckpoint(hasSidecars: CatalogDatabaseSidecarHelpers.hasSidecars(at: url))
            }
        )
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .ready(token) = result else {
            return XCTFail("Expected ready, got \(result)")
        }
        defer {
            try? token.close()
        }

        XCTAssertEqual(recorder.callCount, 1)
        XCTAssertEqual(sidecarState.postCheckpointHasSidecars, false)
        XCTAssertEqual(
            try StartupTestSupport.readLegacySentinelPayload(at: paths.catalogDatabaseURL),
            LegacyStartupTestSupport.sentinelPayload
        )
    }

    func testNewCandidateFailureDoesNotLeaveFormalDatabase() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.makePathsResolver(root: root).ensureRequiredDirectories(for: paths)

        let dependencies = StartupTestSupport.makeDependencies(
            root: root,
            createCandidateDatabase: { _ in
                throw CatalogSnapshotError.candidatePreparationFailed
            }
        )
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .unavailable(reason) = result else {
            return XCTFail("Expected unavailable")
        }
        XCTAssertEqual(reason, .publicationFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.catalogDatabaseURL.path))
    }
}
