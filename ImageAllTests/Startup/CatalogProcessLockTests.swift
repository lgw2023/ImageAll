import XCTest
@testable import ImageAll

final class CatalogProcessLockTests: XCTestCase {
    func testFirstInstanceAcquiresLockAndSecondInstanceGetsAlreadyRunning() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.makePathsResolver(root: root).ensureRequiredDirectories(for: paths)

        let lock = DarwinCatalogProcessLock()
        let first = try lock.tryAcquire(at: paths.catalogLockFileURL)
        guard case let .acquired(firstToken) = first else {
            return XCTFail("Expected first instance to acquire lock")
        }
        defer { firstToken.release() }

        let second = try lock.tryAcquire(at: paths.catalogLockFileURL)
        XCTAssertEqual(second, .alreadyRunning)
    }

    func testReleasedLockAllowsSecondInstanceEvenWhenLockFileRemains() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.makePathsResolver(root: root).ensureRequiredDirectories(for: paths)

        let lock = DarwinCatalogProcessLock()
        let first = try lock.tryAcquire(at: paths.catalogLockFileURL)
        guard case let .acquired(firstToken) = first else {
            return XCTFail("Expected first instance to acquire lock")
        }
        firstToken.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.catalogLockFileURL.path))

        let second = try lock.tryAcquire(at: paths.catalogLockFileURL)
        guard case let .acquired(secondToken) = second else {
            return XCTFail("Expected second instance to acquire lock after release")
        }
        secondToken.release()
    }

    func testIOFailureIsDistinctFromContention() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.makePathsResolver(root: root).ensureRequiredDirectories(for: paths)

        let blockedParent = paths.runtimeDirectory.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blockedParent)
        let lockURL = blockedParent.appendingPathComponent("catalog.lock")

        let lock = DarwinCatalogProcessLock()
        XCTAssertThrowsError(try lock.tryAcquire(at: lockURL)) { error in
            XCTAssertEqual(error as? CatalogProcessLockError, .ioFailure)
        }
    }

    func testAbandonKeepingLockHeldDoesNotInvokeReleaseHandler() {
        let releaseRecorder = LockReleaseRecorder()
        let token = CatalogProcessLockToken {
            releaseRecorder.recordRelease()
        }
        token.abandonKeepingLockHeld()
        token.release()
        XCTAssertEqual(releaseRecorder.releaseCount, 0)
    }
}

extension CatalogProcessLockAcquireResult: Equatable {
    public static func == (
        lhs: CatalogProcessLockAcquireResult,
        rhs: CatalogProcessLockAcquireResult
    ) -> Bool {
        switch (lhs, rhs) {
        case (.alreadyRunning, .alreadyRunning):
            return true
        case (.acquired, .acquired):
            return true
        default:
            return false
        }
    }
}
