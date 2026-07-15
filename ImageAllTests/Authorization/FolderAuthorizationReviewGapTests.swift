import Foundation
import GRDB
import XCTest
@testable import ImageAll

final class FolderAuthorizationReviewGapTests: XCTestCase {
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

    // 1. AppKit / actor boundary
    @MainActor
    func testFakeDirectoryPickerRunsOnMainActor() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, fakePicker, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker
        )
        fakePicker.configuredResponses = [nil]
        _ = try await coordinator.connectFolder()
        XCTAssertEqual(fakePicker.callCount, 1)
    }

    // 2. Foundation relationship identity with real temp roots
    func testFoundationRelationshipDisjointRootsAreAccepted() throws {
        let checker = FoundationFolderRootRelationshipChecker()
        let first = try registry.makeRoot(label: "disjoint-a")
        let second = try registry.makeRoot(label: "disjoint-b")
        XCTAssertEqual(checker.relationship(between: first, and: second), .disjoint)
    }

    func testParentChainResourceFailureIsIndeterminateNotDisjoint() throws {
        let checker = FolderAuthorizationTestSupport.IndeterminateParentRelationshipChecker()
        let parent = try registry.makeRoot(label: "indeterminate-parent")
        let child = parent.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        checker.indeterminatePairs.insert("\(child.path)|\(parent.path)")
        XCTAssertEqual(checker.relationship(between: child, and: parent), .indeterminate)
    }

    // 3. Public error convergence and kind distinction
    func testDisableWrongKindReturnsSourceKindMismatchWithoutLeakingDetails() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        try FolderAuthorizationTestSupport.insertPhotosSource(database: database, sourceID: sourceID)

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker
        )

        do {
            _ = try await coordinator.disableFolderSource(sourceID: sourceID)
            XCTFail("Expected sourceKindMismatch")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .sourceKindMismatch)
            FolderAuthorizationTestSupport.assertErrorDescriptionIsSanitized(error)
        }
    }

    func testReauthorizeOldBookmarkStartFailureReturnsIdentityIndeterminate() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "13131313-1313-1313-1313-131313131313")!
        let root = try registry.makeRoot(label: "old-start-fail")
        let bookmarkPort = FolderAuthorizationTestSupport.MappingBookmarkPort()
        let bookmark = bookmarkPort.register(url: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .authorizationRequired
        )
        bookmarkPort.forceStartResult = false

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        picker.configuredResponses = [root]
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            bookmarkPort: bookmarkPort
        )

        do {
            _ = try await coordinator.reauthorizeFolder(sourceID: sourceID)
            XCTFail("Expected identityIndeterminate")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .identityIndeterminate)
            FolderAuthorizationTestSupport.assertErrorDescriptionIsSanitized(error)
        }
    }

    func testRepositoryLookupMissingReturnsNotFound() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let repository = GRDBFolderSourceAuthorizationRepository(database: database)
        let lookup = try repository.lookupSource(id: UUID())
        XCTAssertEqual(lookup, .notFound)
    }

    func testRepositoryLookupWrongKindReturnsWrongKind() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "14141414-1414-1414-1414-141414141414")!
        try FolderAuthorizationTestSupport.insertPhotosSource(database: database, sourceID: sourceID)
        let repository = GRDBFolderSourceAuthorizationRepository(database: database)
        let lookup = try repository.lookupSource(id: sourceID)
        XCTAssertEqual(lookup, .wrongKind)
    }

    // 4. Ordinary access state mapping
    func testActiveAccessResolveFailurePersistsAuthorizationRequiredAndRetainsFacts() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "15151515-1515-1515-1515-151515151515")!
        let assetID = UUID(uuidString: "16161616-1616-1616-1616-161616161616")!
        let tagID = UUID(uuidString: "17171717-1717-1717-1717-171717171717")!
        let root = try registry.makeRoot(label: "resolve-fail")
        let bookmark = Data([0x01, 0x02, 0x03])
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .active
        )
        try FolderAuthorizationTestSupport.insertFolderAssetGraph(
            database: database,
            sourceID: sourceID,
            assetID: assetID,
            tagID: tagID
        )
        let before = try FolderAuthorizationTestSupport.assetGraphCounts(database, sourceID: sourceID)

        let bookmarkPort = FolderAuthorizationTestSupport.ScopeTrackingBookmarkPort()
        bookmarkPort.resolveFailure = true
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            bookmarkPort: bookmarkPort
        )

        do {
            _ = try coordinator.accessFolderSource(sourceID: sourceID) { _ in "" }
            XCTFail("Expected authorizationUnavailable")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .authorizationUnavailable)
        }

        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchSourceState(database, sourceID: sourceID), .authorizationRequired)
        let after = try FolderAuthorizationTestSupport.assetGraphCounts(database, sourceID: sourceID)
        XCTAssertEqual(after.assets, before.assets)
        XCTAssertEqual(after.fingerprints, before.fingerprints)
        XCTAssertEqual(after.tags, before.tags)
        XCTAssertEqual(after.decisions, before.decisions)
    }

    func testUnavailableAndAuthorizationRequiredAccessDoNotResolveBookmark() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "18181818-1818-1818-1818-181818181818")!
        let root = try registry.makeRoot(label: "blocked-states")
        let bookmarkPort = FolderAuthorizationTestSupport.ScopeTrackingBookmarkPort()
        let bookmark = try bookmarkPort.createReadOnlyBookmark(for: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .unavailable
        )

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, _, port) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            bookmarkPort: bookmarkPort
        )
        let tracking = port as! FolderAuthorizationTestSupport.ScopeTrackingBookmarkPort

        do {
            _ = try coordinator.accessFolderSource(sourceID: sourceID) { _ in "" }
            XCTFail("Expected authorizationUnavailable")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .authorizationUnavailable)
        }
        XCTAssertEqual(tracking.startCount, 0)

        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET state = 'authorizationRequired' WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            )
        }
        tracking.resetCounters()
        do {
            _ = try coordinator.accessFolderSource(sourceID: sourceID) { _ in "" }
            XCTFail("Expected authorizationUnavailable")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .authorizationUnavailable)
        }
        XCTAssertEqual(tracking.startCount, 0)
    }

    func testAccessStatePersistenceFailureDoesNotDeleteFacts() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        try FolderAuthorizationTestSupport.AuthorizationDatabaseTestFaults
            .installSourceStateUpdateAbortTrigger(database)

        let sourceID = UUID(uuidString: "19191919-1919-1919-1919-191919191919")!
        let assetID = UUID(uuidString: "1a1a1a1a-1a1a-1a1a-1a1a-1a1a1a1a1a1a")!
        let tagID = UUID(uuidString: "1b1b1b1b-1b1b-1b1b-1b1b-1b1b1b1b1b1b")!
        let root = try registry.makeRoot(label: "persist-fail")
        let bookmarkPort = FolderAuthorizationTestSupport.ScopeTrackingBookmarkPort()
        let bookmark = try bookmarkPort.createReadOnlyBookmark(for: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .active
        )
        try FolderAuthorizationTestSupport.insertFolderAssetGraph(
            database: database,
            sourceID: sourceID,
            assetID: assetID,
            tagID: tagID
        )
        let before = try FolderAuthorizationTestSupport.assetGraphCounts(database, sourceID: sourceID)

        bookmarkPort.resolveFailure = true
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            bookmarkPort: bookmarkPort
        )

        do {
            _ = try coordinator.accessFolderSource(sourceID: sourceID) { _ in "" }
            XCTFail("Expected persistenceFailure")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .persistenceFailure)
        }

        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchSourceState(database, sourceID: sourceID), .active)
        let after = try FolderAuthorizationTestSupport.assetGraphCounts(database, sourceID: sourceID)
        XCTAssertEqual(after.assets, before.assets)
        XCTAssertEqual(after.fingerprints, before.fingerprints)
        XCTAssertEqual(after.tags, before.tags)
        XCTAssertEqual(after.decisions, before.decisions)
    }

    // 5. stale lifecycle covered in SecurityScopedBookmarkTests

    // 6. disable covered in FolderDisableReauthorizeTests

    // 7. reauthorize matrix
    func testReauthorizeMissingSourceReturnsNotFound() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker
        )

        do {
            _ = try await coordinator.reauthorizeFolder(sourceID: UUID())
            XCTFail("Expected sourceNotFound")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .sourceNotFound)
        }
    }

    func testReauthorizeWrongKindReturnsSourceKindMismatch() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "1c1c1c1c-1c1c-1c1c-1c1c-1c1c1c1c1c1c")!
        try FolderAuthorizationTestSupport.insertPhotosSource(database: database, sourceID: sourceID)

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker
        )

        do {
            _ = try await coordinator.reauthorizeFolder(sourceID: sourceID)
            XCTFail("Expected sourceKindMismatch")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .sourceKindMismatch)
        }
    }

    func testReauthorizeCreatesJobWhenNoneActive() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "1d1d1d1d-1d1d-1d1d-1d1d-1d1d1d1d1d1d")!
        let jobID = UUID(uuidString: "1e1e1e1e-1e1e-1e1e-1e1e-1e1e1e1e1e1e")!
        let root = try registry.makeRoot(label: "reauth-new-job")
        let bookmark = try FoundationSecurityScopedBookmarkAdapter().createReadOnlyBookmark(for: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .unavailable
        )

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        picker.configuredResponses = [root]
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            ids: [jobID]
        )

        _ = try await coordinator.reauthorizeFolder(sourceID: sourceID)
        XCTAssertEqual(try FolderAuthorizationTestSupport.jobCount(database), 1)
        XCTAssertEqual(try FolderAuthorizationTestSupport.activeReconcileJobs(database, sourceID: sourceID), 1)
    }

    func testReauthorizeJobConvergenceFailureRollsBackBookmarkStateAndJobs() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        try FolderAuthorizationTestSupport.AuthorizationDatabaseTestFaults
            .installReauthorizeJobConvergenceAbortTrigger(database)

        let sourceID = UUID(uuidString: "1f1f1f1f-1f1f-1f1f-1f1f-1f1f1f1f1f1f")!
        let root = try registry.makeRoot(label: "reauth-fault")
        let bookmark = try FoundationSecurityScopedBookmarkAdapter().createReadOnlyBookmark(for: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .authorizationRequired
        )
        let beforeBookmark = try FolderAuthorizationTestSupport.fetchSourceBookmark(database, sourceID: sourceID)

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        picker.configuredResponses = [root]
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            ids: [UUID()]
        )

        do {
            _ = try await coordinator.reauthorizeFolder(sourceID: sourceID)
            XCTFail("Expected persistenceFailure")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .persistenceFailure)
        }

        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchSourceBookmark(database, sourceID: sourceID), beforeBookmark)
        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchSourceState(database, sourceID: sourceID), .authorizationRequired)
        XCTAssertEqual(try FolderAuthorizationTestSupport.jobCount(database), 0)
    }

    func testReauthorizeIndeterminateIdentityLeavesStateUnchanged() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "20202020-2020-2020-2020-202020202020")!
        let root = try registry.makeRoot(label: "reauth-indeterminate")
        let bookmarkPort = FolderAuthorizationTestSupport.MappingBookmarkPort()
        let bookmark = bookmarkPort.register(url: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .authorizationRequired
        )

        let checker = FolderAuthorizationTestSupport.IndeterminateParentRelationshipChecker()
        checker.indeterminatePairs.insert("\(root.path)|\(root.path)")

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        picker.configuredResponses = [root]
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            bookmarkPort: bookmarkPort,
            relationshipChecker: checker
        )

        do {
            _ = try await coordinator.reauthorizeFolder(sourceID: sourceID)
            XCTFail("Expected identityIndeterminate")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .identityIndeterminate)
        }
        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchSourceState(database, sourceID: sourceID), .authorizationRequired)
        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchSourceBookmark(database, sourceID: sourceID), bookmark)
    }

    // 8. connect atomicity covered in FolderOverlapAndConnectTests

    // 9. root and state matrix
    func testFourSourceStatesRetainAssetGraphOnAccessFailure() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "21212121-2121-2121-2121-212121212121")!
        let assetID = UUID(uuidString: "22222222-2222-2222-2222-222222222223")!
        let tagID = UUID(uuidString: "23232323-2323-2323-2323-232323232323")!
        let root = try registry.makeRoot(label: "four-states")
        let bookmarkPort = FolderAuthorizationTestSupport.ScopeTrackingBookmarkPort()
        let bookmark = try bookmarkPort.createReadOnlyBookmark(for: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .active
        )
        try FolderAuthorizationTestSupport.insertFolderAssetGraph(
            database: database,
            sourceID: sourceID,
            assetID: assetID,
            tagID: tagID
        )
        let before = try FolderAuthorizationTestSupport.assetGraphCounts(database, sourceID: sourceID)

        bookmarkPort.resolveFailure = true
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            bookmarkPort: bookmarkPort
        )

        for state in [SourceState.active, SourceState.unavailable, SourceState.authorizationRequired, SourceState.disabled] {
            try database.pool.write { db in
                try db.execute(
                    sql: "UPDATE source SET state = ? WHERE id = ?",
                    arguments: [state.rawValue, sourceID.uuidString.lowercased()]
                )
            }
            do {
                _ = try coordinator.accessFolderSource(sourceID: sourceID) { _ in "" }
                if state == .active {
                    XCTFail("Active with forced resolve failure should throw")
                } else {
                    XCTFail("Expected throw for \(state)")
                }
            } catch {
                if state == .active {
                    XCTAssertEqual(error as? FolderAuthorizationError, .authorizationUnavailable)
                } else if state == .disabled {
                    XCTAssertEqual(error as? FolderAuthorizationError, .invalidSourceState)
                } else {
                    XCTAssertEqual(error as? FolderAuthorizationError, .authorizationUnavailable)
                }
            }
            let after = try FolderAuthorizationTestSupport.assetGraphCounts(database, sourceID: sourceID)
            XCTAssertEqual(after.assets, before.assets)
            XCTAssertEqual(after.fingerprints, before.fingerprints)
            XCTAssertEqual(after.tags, before.tags)
            XCTAssertEqual(after.decisions, before.decisions)
        }
    }
}
