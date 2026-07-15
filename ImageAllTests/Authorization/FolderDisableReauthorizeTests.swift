import Foundation
import GRDB
import XCTest
@testable import ImageAll

final class FolderDisableReauthorizeTests: XCTestCase {
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

    func testDisableIsIdempotentAndCancelsActiveReconcileJobs() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let root = try registry.makeRoot(label: "disable")
        let bookmark = try FoundationSecurityScopedBookmarkAdapter().createReadOnlyBookmark(for: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark
        )

        let pendingID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let runningID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let nowMs = JobTestSupport.baseTimeMs
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, source_id, coalescing_key,
                    state, control_request, priority, attempts, max_attempts, not_before_ms,
                    progress_completed, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 1, ?, ?, ?, 'pending', 'none', 0, 0, 5, ?, 0, ?, ?)
                """,
                arguments: [
                    pendingID.uuidString.lowercased(),
                    FolderReconcileJobFactory.kind,
                    try FolderReconcileJobFactory.makePayload(sourceID: sourceID),
                    sourceID.uuidString.lowercased(),
                    FolderReconcileJobFactory.coalescingKey(sourceID: sourceID),
                    nowMs,
                    nowMs,
                    nowMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, source_id, coalescing_key,
                    state, control_request, priority, attempts, max_attempts, not_before_ms,
                    lease_owner, lease_expires_at_ms, progress_completed, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 1, ?, ?, ?, 'running', 'none', 0, 1, 5, ?, 'worker', ?, 0, ?, ?)
                """,
                arguments: [
                    runningID.uuidString.lowercased(),
                    FolderReconcileJobFactory.kind,
                    try FolderReconcileJobFactory.makePayload(sourceID: sourceID),
                    sourceID.uuidString.lowercased(),
                    "folder.reconcile.v1:running-\(sourceID.uuidString.lowercased())",
                    nowMs,
                    nowMs + 60_000,
                    nowMs,
                    nowMs,
                ]
            )
        }

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker
        )

        let first = try FolderAuthorizationTestSupport.awaitResult {
            try await coordinator.disableFolderSource(sourceID: sourceID)
        }
        XCTAssertEqual(first, .disabled(sourceID: sourceID))
        let second = try FolderAuthorizationTestSupport.awaitResult {
            try await coordinator.disableFolderSource(sourceID: sourceID)
        }
        XCTAssertEqual(second, .disabled(sourceID: sourceID))

        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchSourceState(database, sourceID: sourceID), .disabled)
        let pendingState: String = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM job WHERE id = ?", arguments: [pendingID.uuidString.lowercased()]) ?? ""
        }
        XCTAssertEqual(pendingState, JobState.cancelled.rawValue)

        let runningControl: String = try database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT control_request FROM job WHERE id = ?",
                arguments: [runningID.uuidString.lowercased()]
            ) ?? ""
        }
        XCTAssertEqual(runningControl, JobControlRequest.cancel.rawValue)
    }

    func testReauthorizeSameRootSucceedsAndReusesActiveJob() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let root = try registry.makeRoot(label: "reauth")
        let foundationBookmarkPort = FoundationSecurityScopedBookmarkAdapter()
        let bookmark = try foundationBookmarkPort.createReadOnlyBookmark(for: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .authorizationRequired
        )

        let queue = JobTestSupport.makeQueue(database: database)
        let existingJobID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        _ = try queue.enqueue(
            EnqueueJobCommand(
                id: existingJobID,
                kind: FolderReconcileJobFactory.kind,
                payloadVersion: 1,
                payload: try FolderReconcileJobFactory.makePayload(sourceID: sourceID),
                sourceID: sourceID,
                coalescingKey: FolderReconcileJobFactory.coalescingKey(sourceID: sourceID),
                priority: 0,
                maxAttempts: 5,
                notBeforeMs: JobTestSupport.baseTimeMs
            )
        )

        let mappingBookmarkPort = FolderAuthorizationTestSupport.MappingBookmarkPort()
        mappingBookmarkPort.register(url: root)
        let storedBookmark = try FolderAuthorizationTestSupport.fetchSourceBookmark(database, sourceID: sourceID)!
        mappingBookmarkPort.urlByBookmark[storedBookmark] = root

        let checker = FolderAuthorizationTestSupport.FixedRelationshipChecker()
        checker.relationships[FolderAuthorizationTestSupport.FixedRelationshipChecker.key(root, root)] = .same

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        picker.configuredResponses = [root]
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            bookmarkPort: mappingBookmarkPort,
            relationshipChecker: checker,
            ids: [UUID()]
        )

        let outcome = try FolderAuthorizationTestSupport.awaitResult {
            try await coordinator.reauthorizeFolder(sourceID: sourceID)
        }
        guard case let .reauthorized(reauthorizedID) = outcome else {
            return XCTFail("Expected reauthorized, got \(outcome)")
        }
        XCTAssertEqual(reauthorizedID, sourceID)
        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchSourceState(database, sourceID: sourceID), .active)
        XCTAssertEqual(try FolderAuthorizationTestSupport.activeReconcileJobs(database, sourceID: sourceID), 1)
        XCTAssertEqual(try FolderAuthorizationTestSupport.jobCount(database), 1)
    }

    func testReauthorizeRejectsActiveDisabledMismatchIndeterminateAndCancel() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let root = try registry.makeRoot(label: "reject")
        let other = try registry.makeRoot(label: "other")
        let bookmarkPort = FoundationSecurityScopedBookmarkAdapter()
        let bookmark = try bookmarkPort.createReadOnlyBookmark(for: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .active
        )

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker
        )

        do {
            _ = try FolderAuthorizationTestSupport.awaitResult {
                try await coordinator.reauthorizeFolder(sourceID: sourceID)
            }
            XCTFail("Expected invalid state")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .invalidSourceState)
        }

        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET state = 'disabled' WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            )
        }
        do {
            _ = try FolderAuthorizationTestSupport.awaitResult {
                try await coordinator.reauthorizeFolder(sourceID: sourceID)
            }
            XCTFail("Expected invalid state")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .invalidSourceState)
        }

        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET state = 'authorizationRequired' WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            )
        }

        picker.configuredResponses = [nil]
        let cancelled = try FolderAuthorizationTestSupport.awaitResult {
            try await coordinator.reauthorizeFolder(sourceID: sourceID)
        }
        XCTAssertEqual(cancelled, .cancelled)

        picker.configuredResponses = [other]
        do {
            _ = try FolderAuthorizationTestSupport.awaitResult {
                try await coordinator.reauthorizeFolder(sourceID: sourceID)
            }
            XCTFail("Expected mismatch")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .identityMismatch)
        }
    }

    func testDisabledSourceAccessDoesNotRemoveExistingAssets() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        let assetID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        let root = try registry.makeRoot(label: "state-map")
        let bookmark = try FoundationSecurityScopedBookmarkAdapter().createReadOnlyBookmark(for: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .disabled
        )
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, content_revision, availability,
                    record_created_at_ms, record_updated_at_ms
                ) VALUES (?, ?, 'file', 'a.jpg', NULL, 'current', 'public.jpeg', 1, 'available', ?, ?)
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    sourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        }

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker
        )

        do {
            _ = try coordinator.accessFolderSource(sourceID: sourceID) { _ in "" }
            XCTFail("Expected disabled rejection")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .invalidSourceState)
        }

        let assetCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE source_id = ?", arguments: [sourceID.uuidString.lowercased()]) ?? 0
        }
        XCTAssertEqual(assetCount, 1)
    }
}
