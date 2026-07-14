import XCTest
@testable import ImageAll

final class CatalogBootstrapTests: XCTestCase {
    func testBootstrapOrderingForFreshDatabase() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let callLog = CatalogBootstrapCallLog()
        let dependencies = StartupTestSupport.makeDependencies(root: root, callLog: callLog)
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()

        guard case let .ready(token) = result else {
            return XCTFail("Expected ready, got \(result)")
        }
        defer {
            try? token.close()
        }

        XCTAssertEqual(
            callLog.snapshot(),
            [.paths, .lock, .inspect, .prepare, .finalOpen, .recover, .ready]
        )
    }

    func testLockMustPrecedeDatabaseWorkAndRecoveryMustPrecedeReady() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedCurrentSchemaDatabase(at: paths.catalogDatabaseURL)
        try StartupTestSupport.makePathsResolver(root: root).ensureRequiredDirectories(for: paths)

        let callLog = CatalogBootstrapCallLog()
        let dependencies = StartupTestSupport.makeDependencies(root: root, callLog: callLog)
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .ready(token) = result else {
            return XCTFail("Expected ready")
        }
        defer {
            try? token.close()
        }

        let stages = callLog.snapshot()
        XCTAssertLessThan(stages.firstIndex(of: .lock)!, stages.firstIndex(of: .inspect)!)
        XCTAssertLessThan(stages.firstIndex(of: .finalOpen)!, stages.firstIndex(of: .recover)!)
        XCTAssertLessThan(stages.firstIndex(of: .recover)!, stages.firstIndex(of: .ready)!)
    }

    func testNewDatabaseCreatesCandidateMigratesAndPublishesFormalDatabase() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.makePathsResolver(root: root).ensureRequiredDirectories(for: paths)

        let dependencies = StartupTestSupport.makeDependencies(root: root)
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .ready(token) = result else {
            return XCTFail("Expected ready")
        }
        defer {
            try? token.close()
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.catalogDatabaseURL.path))
        let migrations = try SnapshotTestSupport.readMigrationIDs(at: paths.catalogDatabaseURL)
        XCTAssertEqual(migrations, CatalogMigrationID.knownOrdered)
    }

    func testPublishCandidateDatabaseRejectsExistingFormalPath() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.makePathsResolver(root: root).ensureRequiredDirectories(for: paths)

        let operationID = UUID()
        let candidateURL = paths.catalogDirectory.appendingPathComponent(
            "ImageAll.candidate-\(operationID.uuidString.lowercased()).sqlite"
        )
        try CatalogDatabase.createCandidateDatabase(at: candidateURL)
        try Data("formal".utf8).write(to: paths.catalogDatabaseURL)

        XCTAssertThrowsError(
            try CatalogDatabase.publishCandidateDatabase(
                candidateURL: candidateURL,
                formalURL: paths.catalogDatabaseURL
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .publicationFailed)
        }

        let existing = String(data: try Data(contentsOf: paths.catalogDatabaseURL), encoding: .utf8)
        XCTAssertEqual(existing, "formal")
    }

    func testCurrentSchemaSkipsSnapshotAndReplacement() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        _ = try StartupTestSupport.seedCurrentSchemaDatabase(at: paths.catalogDatabaseURL)
        let beforeBytes = try SnapshotTestSupport.databaseBytes(at: paths.catalogDatabaseURL)

        let dependencies = StartupTestSupport.makeDependencies(root: root)
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .ready(token) = result else {
            return XCTFail("Expected ready")
        }
        defer {
            try? token.close()
        }

        XCTAssertEqual(try SnapshotTestSupport.databaseBytes(at: paths.catalogDatabaseURL), beforeBytes)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: paths.backupsDirectory.path).isEmpty
        )
    }

    func testFutureSchemaDoesNotRecoverOrBecomeReady() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedFutureSchemaDatabase(at: paths.catalogDatabaseURL)

        let dependencies = StartupTestSupport.makeDependencies(root: root)
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .unavailable(reason) = result else {
            return XCTFail("Expected unavailable")
        }
        XCTAssertEqual(reason, .schemaUnsupported)
    }

    func testIntegrityFailureDoesNotRecoverOrBecomeReady() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedCorruptDatabase(at: paths.catalogDatabaseURL)

        let dependencies = StartupTestSupport.makeDependencies(root: root)
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .unavailable(reason) = result else {
            return XCTFail("Expected unavailable")
        }
        XCTAssertEqual(reason, .integrityFailed)
    }

    func testOldSchemaMigratesFromWorkCopyAndPreservesOriginalAsBackup() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedEmptySQLite(at: paths.catalogDatabaseURL)

        let operationID = UUID()
        let dependencies = StartupTestSupport.makeDependencies(
            root: root,
            operationID: operationID
        )
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .ready(token) = result else {
            return XCTFail("Expected ready, got \(result)")
        }
        defer {
            try? token.close()
        }

        let migrations = try SnapshotTestSupport.readMigrationIDs(at: paths.catalogDatabaseURL)
        XCTAssertEqual(migrations, CatalogMigrationID.knownOrdered)

        let backupName = "ImageAll.sqlite.pre-migration-\(operationID.uuidString.lowercased())"
        let backupURL = paths.catalogDirectory.appendingPathComponent(backupName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(try SnapshotTestSupport.readMigrationIDs(at: backupURL), [])
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: paths.backupsDirectory.path).isEmpty
        )
    }

    func testInsufficientSpaceBlocksOldSchemaMigration() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedEmptySQLite(at: paths.catalogDatabaseURL)

        let dependencies = StartupTestSupport.makeDependencies(
            root: root,
            capacityProvider: FixedCapacityProvider(bytes: 0)
        )
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .unavailable(.insufficientSpace(requiredBytes)) = result else {
            return XCTFail("Expected insufficient space")
        }
        XCTAssertGreaterThan(requiredBytes, 0)
        XCTAssertEqual(try SnapshotTestSupport.readMigrationIDs(at: paths.catalogDatabaseURL), [])
    }

    func testMigrationReplacementFailureKeepsOriginalDatabase() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedEmptySQLite(at: paths.catalogDatabaseURL)

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
    }

    func testRecoveryFailureClosesDatabaseAndReleasesLock() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        _ = try StartupTestSupport.seedCurrentSchemaDatabase(at: paths.catalogDatabaseURL)
        try StartupTestSupport.insertInterruptedRunningJob(at: paths.catalogDatabaseURL)

        let dependencies = StartupTestSupport.makeDependencies(
            root: root,
            recoveryFailureHook: {
                throw JobQueueError.invalidClaimInput(reason: "forced recovery failure")
            }
        )
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .unavailable(reason) = result else {
            return XCTFail("Expected recovery failure")
        }
        XCTAssertEqual(reason, .recoveryFailed)

        let second = try DarwinCatalogProcessLock().tryAcquire(at: paths.catalogLockFileURL)
        guard case let .acquired(token) = second else {
            return XCTFail("Expected lock to be released after recovery failure")
        }
        token.release()
    }

    func testSecondInstanceWithoutLockDoesNotOpenFormalDatabase() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        _ = try StartupTestSupport.seedCurrentSchemaDatabase(at: paths.catalogDatabaseURL)

        let firstLock = try DarwinCatalogProcessLock().tryAcquire(at: paths.catalogLockFileURL)
        guard case let .acquired(firstToken) = firstLock else {
            return XCTFail("Expected first lock")
        }
        defer { firstToken.release() }

        let callLog = CatalogBootstrapCallLog()
        let dependencies = StartupTestSupport.makeDependencies(
            root: root,
            callLog: callLog
        )
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case .anotherInstanceRunning = result else {
            return XCTFail("Expected anotherInstanceRunning")
        }
        XCTAssertEqual(callLog.snapshot(), [.paths, .lock])
    }

    func testReadyRuntimeRetainsDatabaseLockAndMigrationHistory() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        let jobID = UUID()
        _ = try StartupTestSupport.seedCurrentSchemaDatabase(at: paths.catalogDatabaseURL)
        try StartupTestSupport.insertInterruptedRunningJob(at: paths.catalogDatabaseURL, jobID: jobID)

        let dependencies = StartupTestSupport.makeDependencies(root: root)
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .ready(token) = result else {
            return XCTFail("Expected ready")
        }
        defer {
            try? token.close()
        }

        let migrations = try token.runtime.database.appliedMigrationIDs()
        XCTAssertEqual(migrations, CatalogMigrationID.knownOrdered)

        let second = try DarwinCatalogProcessLock().tryAcquire(at: paths.catalogLockFileURL)
        XCTAssertEqual(second, .alreadyRunning)

        let snapshot = try token.runtime.jobQueue.fetchJob(id: jobID)
        XCTAssertEqual(snapshot.state, .retryableFailed)
    }

    func testExplicitCloseAllowsReacquiringLock() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)

        let dependencies = StartupTestSupport.makeDependencies(root: root)
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .ready(token) = result else {
            return XCTFail("Expected ready")
        }
        try token.close()

        let second = try DarwinCatalogProcessLock().tryAcquire(at: paths.catalogLockFileURL)
        guard case let .acquired(secondToken) = second else {
            return XCTFail("Expected second lock after close")
        }
        secondToken.release()
    }
}

private extension CatalogBootstrapResult {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
