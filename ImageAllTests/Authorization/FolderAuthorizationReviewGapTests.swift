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

    private func assertAssetGraphUnchanged(
        _ before: (assets: Int, fingerprints: Int, tags: Int, decisions: Int),
        _ after: (assets: Int, fingerprints: Int, tags: Int, decisions: Int),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(after.assets, before.assets, file: file, line: line)
        XCTAssertEqual(after.fingerprints, before.fingerprints, file: file, line: line)
        XCTAssertEqual(after.tags, before.tags, file: file, line: line)
        XCTAssertEqual(after.decisions, before.decisions, file: file, line: line)
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
            .installReauthorizeJobInsertAbortTrigger(database)

        let sourceID = UUID(uuidString: "1f1f1f1f-1f1f-1f1f-1f1f-1f1f1f1f1f1f")!
        let root = try registry.makeRoot(label: "reauth-fault")
        let bookmarkPort = FolderAuthorizationTestSupport.MappingBookmarkPort()
        bookmarkPort.issueDistinctBookmarksOnCreate = true
        let oldBookmark = bookmarkPort.register(url: root, token: Data([0x01, 0x02, 0x03]))
        let insertNowMs = FolderAuthorizationTestSupport.baseTimeMs - 5_000
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            displayName: "Before Display",
            bookmark: oldBookmark,
            state: .authorizationRequired,
            nowMs: insertNowMs
        )
        let sourceBefore = try FolderAuthorizationTestSupport.fetchSourceRowSnapshot(database, sourceID: sourceID)!

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        picker.configuredResponses = [root]
        let reauthorizeNowMs = FolderAuthorizationTestSupport.baseTimeMs
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            bookmarkPort: bookmarkPort,
            nowMs: reauthorizeNowMs,
            ids: [UUID()]
        )

        do {
            _ = try await coordinator.reauthorizeFolder(sourceID: sourceID)
            XCTFail("Expected persistenceFailure")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .persistenceFailure)
        }

        let distinctBookmarksForRoot = bookmarkPort.urlByBookmark.filter { $0.value == root }.map(\.key)
        XCTAssertTrue(distinctBookmarksForRoot.contains(oldBookmark))
        XCTAssertTrue(distinctBookmarksForRoot.contains { $0 != oldBookmark })

        XCTAssertEqual(
            try FolderAuthorizationTestSupport.fetchSourceRowSnapshot(database, sourceID: sourceID),
            sourceBefore
        )
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

    private func assertOfflineResolvePersistsUnavailable(
        label: String,
        sourceID: UUID,
        assetID: UUID,
        tagID: UUID,
        resolveError: Error
    ) throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let root = try registry.makeRoot(label: "offline-\(label)")
        let bookmarkPort = FolderAuthorizationTestSupport.MappingBookmarkPort()
        let bookmark = bookmarkPort.register(url: root)
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
        bookmarkPort.resolveError = resolveError

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, _, port) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            bookmarkPort: bookmarkPort
        )
        let tracking = port as! FolderAuthorizationTestSupport.MappingBookmarkPort
        var closureExecuted = false

        do {
            _ = try coordinator.accessFolderSource(sourceID: sourceID) { _ in
                closureExecuted = true
                return ""
            }
            XCTFail("Expected authorizationUnavailable for \(label)")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .authorizationUnavailable)
        }

        XCTAssertFalse(closureExecuted, label)
        XCTAssertEqual(tracking.startCount, 0, label)
        XCTAssertEqual(tracking.stopCount, 0, label)
        XCTAssertEqual(
            try FolderAuthorizationTestSupport.fetchSourceState(database, sourceID: sourceID),
            .unavailable,
            label
        )
        let after = try FolderAuthorizationTestSupport.assetGraphCounts(database, sourceID: sourceID)
        assertAssetGraphUnchanged(before, after)
    }

    // §4.5 / §4.8 access state contract
    func testOfflineCocoaNoSuchFileResolvePersistsUnavailableWithoutScopeAccess() throws {
        try assertOfflineResolvePersistsUnavailable(
            label: "cocoa-no-such-file",
            sourceID: UUID(uuidString: "24242424-2424-2424-2424-242424242424")!,
            assetID: UUID(uuidString: "25252525-2525-2525-2525-252525252525")!,
            tagID: UUID(uuidString: "26262626-2626-2626-2626-262626262626")!,
            resolveError: NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: nil)
        )
    }

    func testOfflinePosixENOENTResolvePersistsUnavailableWithoutScopeAccess() throws {
        try assertOfflineResolvePersistsUnavailable(
            label: "posix-enoent",
            sourceID: UUID(uuidString: "34343434-3434-3434-3434-343434343434")!,
            assetID: UUID(uuidString: "35353535-3535-3535-3535-353535353535")!,
            tagID: UUID(uuidString: "36363636-3636-3636-3636-363636363636")!,
            resolveError: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: nil)
        )
    }

    func testScopeStartFailurePersistsAuthorizationRequiredWithoutStop() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "27272727-2727-2727-2727-272727272727")!
        let assetID = UUID(uuidString: "28282828-2828-2828-2828-282828282828")!
        let tagID = UUID(uuidString: "29292929-2929-2929-2929-292929292929")!
        let root = try registry.makeRoot(label: "scope-false")
        let bookmarkPort = FolderAuthorizationTestSupport.MappingBookmarkPort()
        let bookmark = bookmarkPort.register(url: root)
        bookmarkPort.forceStartResult = false
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

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, _, port) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            bookmarkPort: bookmarkPort
        )
        let tracking = port as! FolderAuthorizationTestSupport.MappingBookmarkPort
        var closureExecuted = false

        do {
            _ = try coordinator.accessFolderSource(sourceID: sourceID) { _ in
                closureExecuted = true
                return ""
            }
            XCTFail("Expected authorizationUnavailable")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .authorizationUnavailable)
        }

        XCTAssertFalse(closureExecuted)
        XCTAssertEqual(tracking.startCount, 1)
        XCTAssertEqual(tracking.stopCount, 0)
        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchSourceState(database, sourceID: sourceID), .authorizationRequired)
        let after = try FolderAuthorizationTestSupport.assetGraphCounts(database, sourceID: sourceID)
        assertAssetGraphUnchanged(before, after)
    }

    func testInvalidRootAfterScopeStartPersistsAuthorizationRequiredAndStopsScope() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "2a2a2a2a-2a2a-2a2a-2a2a-2a2a2a2a2a2a")!
        let assetID = UUID(uuidString: "2b2b2b2b-2b2b-2b2b-2b2b-2b2b2b2b2b2b")!
        let tagID = UUID(uuidString: "2c2c2c2c-2c2c-2c2c-2c2c-2c2c2c2c2c2c")!
        let root = try registry.makeFile(label: "not-a-directory")
        let bookmarkPort = FolderAuthorizationTestSupport.MappingBookmarkPort()
        let bookmark = bookmarkPort.register(url: root)
        bookmarkPort.forceStartResult = true
        let reader = FolderAuthorizationTestSupport.FixedResourceReader()
        reader.snapshots[root] = FolderRootResourceSnapshot(
            isDirectory: false,
            isSymbolicLink: false,
            isAliasFile: false,
            isPackage: false,
            isReadable: true,
            localizedName: "fixture",
            pathExtension: "txt"
        )
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

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, _, port) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            bookmarkPort: bookmarkPort,
            resourceReader: reader
        )
        let tracking = port as! FolderAuthorizationTestSupport.MappingBookmarkPort
        var closureExecuted = false

        do {
            _ = try coordinator.accessFolderSource(sourceID: sourceID) { _ in
                closureExecuted = true
                return ""
            }
            XCTFail("Expected authorizationUnavailable")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .authorizationUnavailable)
        }

        XCTAssertFalse(closureExecuted)
        XCTAssertEqual(tracking.startCount, 1)
        XCTAssertEqual(tracking.stopCount, 1)
        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchSourceState(database, sourceID: sourceID), .authorizationRequired)
        let after = try FolderAuthorizationTestSupport.assetGraphCounts(database, sourceID: sourceID)
        assertAssetGraphUnchanged(before, after)
    }

    func testFetchAllFolderSourcesCorruptFolderRowSurfacesPersistenceFailure() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let corruptID = UUID(uuidString: "30303030-3030-3030-3030-303030303030")!
        try FolderAuthorizationTestSupport.insertUndecodableFolderSource(
            database: database,
            sourceID: corruptID
        )

        let repository = GRDBFolderSourceAuthorizationRepository(database: database)
        XCTAssertThrowsError(try repository.fetchAllFolderSources()) { error in
            XCTAssertEqual(error as? FolderAuthorizationError, .persistenceFailure)
        }
    }

    func testConnectRejectsWhenExistingFolderRowIsCorrupt() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let corruptID = UUID(uuidString: "31313131-3131-3131-3131-313131313131")!
        try FolderAuthorizationTestSupport.insertUndecodableFolderSource(
            database: database,
            sourceID: corruptID
        )

        let root = try registry.makeRoot(label: "connect-corrupt-overlap")
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        picker.configuredResponses = [root]
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker
        )

        do {
            _ = try await coordinator.connectFolder()
            XCTFail("Expected persistenceFailure")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .persistenceFailure)
        }
        XCTAssertEqual(try FolderAuthorizationTestSupport.sourceCount(database), 1)
    }

    func testReauthorizeRepositoryRejectsWhenStateChangesBeforeTransactionalUpdate() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "2d2d2d2d-2d2d-2d2d-2d2d-2d2d2d2d2d2d")!
        let oldBookmark = Data([0x0A, 0x0B, 0x0C])
        let newBookmark = Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertNotEqual(oldBookmark, newBookmark)
        let insertNowMs = FolderAuthorizationTestSupport.baseTimeMs - 3_000
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            displayName: "Before Display",
            bookmark: oldBookmark,
            state: .authorizationRequired,
            nowMs: insertNowMs
        )

        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET state = 'disabled' WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            )
        }
        let sourceBeforeReauthorizeAttempt = try FolderAuthorizationTestSupport.fetchSourceRowSnapshot(
            database,
            sourceID: sourceID
        )!

        let repository = GRDBFolderSourceAuthorizationRepository(database: database)
        let attemptedNowMs = FolderAuthorizationTestSupport.baseTimeMs + 9_000
        XCTAssertNotEqual(String(attemptedNowMs), sourceBeforeReauthorizeAttempt.columns["updated_at_ms"] ?? "")
        XCTAssertNotEqual("After Display", sourceBeforeReauthorizeAttempt.columns["display_name"] ?? "")
        XCTAssertNotEqual(newBookmark.base64EncodedString(), sourceBeforeReauthorizeAttempt.columns["bookmark"] ?? "")

        XCTAssertThrowsError(
            try repository.reauthorizeFolder(
                sourceID: sourceID,
                displayName: "After Display",
                bookmark: newBookmark,
                jobID: UUID(),
                nowMs: attemptedNowMs
            )
        ) { error in
            XCTAssertEqual(error as? FolderAuthorizationError, .invalidSourceState)
        }

        XCTAssertEqual(
            try FolderAuthorizationTestSupport.fetchSourceRowSnapshot(database, sourceID: sourceID),
            sourceBeforeReauthorizeAttempt
        )
        XCTAssertEqual(try FolderAuthorizationTestSupport.jobCount(database), 0)
    }

    func testReauthorizeRepositoryRejectsNonReauthorizableState() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "2e2e2e2e-2e2e-2e2e-2e2e-2e2e2e2e2e2e")!
        let root = try registry.makeRoot(label: "reauth-repo-guard")
        let bookmark = try FoundationSecurityScopedBookmarkAdapter().createReadOnlyBookmark(for: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .disabled
        )

        let repository = GRDBFolderSourceAuthorizationRepository(database: database)
        XCTAssertThrowsError(
            try repository.reauthorizeFolder(
                sourceID: sourceID,
                displayName: "After",
                bookmark: bookmark,
                jobID: UUID(),
                nowMs: FolderAuthorizationTestSupport.baseTimeMs
            )
        ) { error in
            XCTAssertEqual(error as? FolderAuthorizationError, .invalidSourceState)
        }
        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchSourceState(database, sourceID: sourceID), .disabled)
    }
}
