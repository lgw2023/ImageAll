import GRDB
import XCTest
@testable import ImageAll

final class CatalogBootstrapFailureTests: XCTestCase {
    func testSnapshotFailureDoesNotBecomeReadyOrMigrateFormalDatabase() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedEmptySQLite(at: paths.catalogDatabaseURL)

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
    }

    func testWorkCopyMigrationFailureDoesNotBecomeReady() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedEmptySQLite(at: paths.catalogDatabaseURL)

        let dependencies = StartupTestSupport.makeDependencies(
            root: root,
            restoreBeforeWorkCopyHook: { throw CatalogSnapshotError.candidatePreparationFailed }
        )
        let result = CatalogBootstrapCoordinator(dependencies: dependencies).bootstrap()
        guard case let .unavailable(reason) = result else {
            return XCTFail("Expected unavailable")
        }
        XCTAssertEqual(reason, .publicationFailed)
        XCTAssertEqual(try SnapshotTestSupport.readMigrationIDs(at: paths.catalogDatabaseURL), [])
    }

    func testInitialReplacementFailureKeepsOriginalFacts() throws {
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

    func testPostReplaceValidationFailureRollsBackOriginalFactsAndDoesNotBecomeReady() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedEmptySQLite(at: paths.catalogDatabaseURL)

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
    }

    func testRollbackFailureDoesNotBecomeReady() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedEmptySQLite(at: paths.catalogDatabaseURL)

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
