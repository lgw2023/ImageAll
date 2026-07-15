import Foundation
import XCTest
@testable import ImageAll

final class SecurityScopedBookmarkTests: XCTestCase {
    private var registry: FolderAuthorizationTestSupport.TempRootRegistry!

    override func setUp() {
        super.setUp()
        registry = FolderAuthorizationTestSupport.TempRootRegistry()
    }

    override func tearDown() {
        registry.cleanup()
        registry = nil
        super.tearDown()
    }

    func testBookmarkCreationAndResolutionOptionsMatchHandoff() throws {
        XCTAssertTrue(SecurityScopedBookmarkOptions.creationOptions.contains(.withSecurityScope))
        XCTAssertTrue(
            SecurityScopedBookmarkOptions.creationOptions.contains(.securityScopeAllowOnlyReadAccess)
        )
        XCTAssertTrue(SecurityScopedBookmarkOptions.resolutionOptions.contains(.withSecurityScope))
        XCTAssertTrue(SecurityScopedBookmarkOptions.resolutionOptions.contains(.withoutUI))
        XCTAssertTrue(SecurityScopedBookmarkOptions.resolutionOptions.contains(.withoutMounting))
        XCTAssertTrue(
            SecurityScopedBookmarkOptions.resolutionOptions.contains(.withoutImplicitStartAccessing)
        )
    }

    func testStartTruePathsStopExactlyOnceIncludingThrownClosure() throws {
        let port = FolderAuthorizationTestSupport.ScopeTrackingBookmarkPort()
        let url = URL(fileURLWithPath: "/tmp/folder")
        port.forceStartResult = true

        _ = try SecurityScopedAccessRunner.withAccess(bookmarkPort: port, url: url) { _ in
            "ok"
        }
        XCTAssertEqual(port.startCount, 1)
        XCTAssertEqual(port.stopCount, 1)

        port.resetCounters()
        do {
            _ = try SecurityScopedAccessRunner.withAccess(bookmarkPort: port, url: url) { _ in
                throw FolderAuthorizationError.invalidRoot
            }
            XCTFail("Expected throw")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .invalidRoot)
        }
        XCTAssertEqual(port.startCount, 1)
        XCTAssertEqual(port.stopCount, 1)
    }

    func testStartFalseDoesNotStop() {
        let port = FolderAuthorizationTestSupport.ScopeTrackingBookmarkPort()
        port.forceStartResult = false
        let url = URL(fileURLWithPath: "/tmp/folder")

        do {
            _ = try SecurityScopedAccessRunner.withAccess(bookmarkPort: port, url: url) { _ in "" }
            XCTFail("Expected throw")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .authorizationUnavailable)
        }
        XCTAssertEqual(port.startCount, 0)
        XCTAssertEqual(port.stopCount, 0)
    }

    func testStaleRefreshReplacesBookmarkOnlyAfterSuccessfulCreateAndSQL() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let root = try registry.makeRoot(label: "stale")
        let bookmarkPort = FoundationSecurityScopedBookmarkAdapter()
        let bookmark = try bookmarkPort.createReadOnlyBookmark(for: root)
        let sourceID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark
        )

        let repository = GRDBFolderSourceAuthorizationRepository(database: database)
        let oldBlob = try FolderAuthorizationTestSupport.fetchSourceBookmark(database, sourceID: sourceID)
        let newBlob = try bookmarkPort.createReadOnlyBookmark(for: root)

        try repository.replaceStaleBookmark(sourceID: sourceID, bookmark: newBlob, nowMs: 1)
        let stored = try FolderAuthorizationTestSupport.fetchSourceBookmark(database, sourceID: sourceID)
        XCTAssertEqual(stored, newBlob)
        let updatedAt: Int64 = try database.pool.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT updated_at_ms FROM source WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            ) ?? 0
        }
        XCTAssertEqual(updatedAt, 1)
        _ = oldBlob
    }

    func testStaleCreateFailureKeepsOldBlobAndSetsAuthorizationRequired() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let root = try registry.makeRoot(label: "stale-fail")
        let underlying = FoundationSecurityScopedBookmarkAdapter()
        let bookmark = try underlying.createReadOnlyBookmark(for: root)
        let sourceID = UUID(uuidString: "bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee")!
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .active
        )

        let bookmarkPort = FolderAuthorizationTestSupport.ScopeTrackingBookmarkPort()
        bookmarkPort.createBookmarkFailure = true
        bookmarkPort.forceStartResult = true
        let repository = GRDBFolderSourceAuthorizationRepository(database: database)
        let coordinator = FolderAuthorizationCoordinator(
            dependencies: FolderAuthorizationDependencies(
                repository: repository,
                picker: FolderAuthorizationTestSupport.FakeDirectoryPicker(),
                bookmarkPort: bookmarkPort,
                rootValidator: FolderRootValidator(),
                relationshipChecker: FoundationFolderRootRelationshipChecker(),
                clock: FixedJobClock(nowMs: FolderAuthorizationTestSupport.baseTimeMs),
                idGenerator: UUID.init
            )
        )

        bookmarkPort.resolveResults = [
            BookmarkResolveResult(url: root, isStale: true),
        ]

        do {
            _ = try coordinator.accessFolderSource(sourceID: sourceID) { _ in "" }
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .authorizationUnavailable)
        }

        let stored = try FolderAuthorizationTestSupport.fetchSourceBookmark(database, sourceID: sourceID)
        XCTAssertEqual(stored, bookmark)
        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchSourceState(database, sourceID: sourceID), .authorizationRequired)
    }

    func testStaleRefreshUsesSingleScopeWithoutSecondResolve() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let root = try registry.makeRoot(label: "stale-single-scope")
        let bookmarkPort = FolderAuthorizationTestSupport.MappingBookmarkPort()
        let bookmark = bookmarkPort.register(url: root)
        let sourceID = UUID(uuidString: "cccccccc-cccd-dddd-eeee-000000000001")!
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .active
        )

        bookmarkPort.staleOnResolve = true
        bookmarkPort.issueDistinctBookmarksOnCreate = true

        let repository = GRDBFolderSourceAuthorizationRepository(database: database)
        let coordinator = FolderAuthorizationCoordinator(
            dependencies: FolderAuthorizationDependencies(
                repository: repository,
                picker: FolderAuthorizationTestSupport.FakeDirectoryPicker(),
                bookmarkPort: bookmarkPort,
                rootValidator: FolderRootValidator(),
                relationshipChecker: FoundationFolderRootRelationshipChecker(),
                clock: FixedJobClock(nowMs: FolderAuthorizationTestSupport.baseTimeMs),
                idGenerator: UUID.init
            )
        )

        let value = try coordinator.accessFolderSource(sourceID: sourceID) { url in
            url.lastPathComponent
        }
        XCTAssertEqual(value, root.lastPathComponent)
        XCTAssertEqual(bookmarkPort.startCount, 1)
        XCTAssertEqual(bookmarkPort.stopCount, 1)
    }

    func testStaleSQLReplaceFailureKeepsOldBlob() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        try FolderAuthorizationTestSupport.AuthorizationDatabaseTestFaults
            .installStaleBookmarkReplaceAbortTrigger(database)

        let root = try registry.makeRoot(label: "stale-sql-fail")
        let bookmarkPort = FolderAuthorizationTestSupport.MappingBookmarkPort()
        let bookmark = bookmarkPort.register(url: root, token: Data("stale-old-bookmark-v1".utf8))
        let sourceID = UUID(uuidString: "dddddddd-dddd-eeee-ffff-000000000002")!
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .active
        )

        bookmarkPort.staleOnResolve = true
        bookmarkPort.issueDistinctBookmarksOnCreate = true

        let repository = GRDBFolderSourceAuthorizationRepository(database: database)
        let coordinator = FolderAuthorizationCoordinator(
            dependencies: FolderAuthorizationDependencies(
                repository: repository,
                picker: FolderAuthorizationTestSupport.FakeDirectoryPicker(),
                bookmarkPort: bookmarkPort,
                rootValidator: FolderRootValidator(),
                relationshipChecker: FoundationFolderRootRelationshipChecker(),
                clock: FixedJobClock(nowMs: FolderAuthorizationTestSupport.baseTimeMs),
                idGenerator: UUID.init
            )
        )

        do {
            _ = try coordinator.accessFolderSource(sourceID: sourceID) { _ in "" }
            XCTFail("Expected persistenceFailure")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .persistenceFailure)
        }

        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchSourceBookmark(database, sourceID: sourceID), bookmark)
        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchSourceState(database, sourceID: sourceID), .active)
        XCTAssertEqual(bookmarkPort.startCount, 1)
        XCTAssertEqual(bookmarkPort.stopCount, 1)
    }
}
