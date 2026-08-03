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

    func testDisableIsIdempotentAndCancelsActiveReconcileJobs() async throws {
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
        let pausedRunningID = UUID(uuidString: "abababab-abab-abab-abab-abababababab")!
        let nowMs = JobTestSupport.baseTimeMs
        try await database.pool.write { db in
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
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, source_id, coalescing_key,
                    state, control_request, priority, attempts, max_attempts, not_before_ms,
                    lease_owner, lease_expires_at_ms, progress_completed, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 1, ?, ?, ?, 'running', 'pause', 0, 1, 5, ?, 'worker', ?, 0, ?, ?)
                """,
                arguments: [
                    pausedRunningID.uuidString.lowercased(),
                    FolderReconcileJobFactory.kind,
                    try FolderReconcileJobFactory.makePayload(sourceID: sourceID),
                    sourceID.uuidString.lowercased(),
                    "folder.reconcile.v1:paused-\(sourceID.uuidString.lowercased())",
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

        let first = try await coordinator.disableFolderSource(sourceID: sourceID)
        XCTAssertEqual(first, .disabled(sourceID: sourceID))
        let second = try await coordinator.disableFolderSource(sourceID: sourceID)
        XCTAssertEqual(second, .disabled(sourceID: sourceID))

        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchSourceState(database, sourceID: sourceID), .disabled)
        let pendingState: String = try await database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM job WHERE id = ?", arguments: [pendingID.uuidString.lowercased()]) ?? ""
        }
        XCTAssertEqual(pendingState, JobState.cancelled.rawValue)

        for runningJobID in [runningID, pausedRunningID] {
            let runningControl: String = try await database.pool.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT control_request FROM job WHERE id = ?",
                    arguments: [runningJobID.uuidString.lowercased()]
                ) ?? ""
            }
            XCTAssertEqual(runningControl, JobControlRequest.cancel.rawValue)
        }
    }

    func testDisableOnAlreadyDisabledSourceStillConvergesActiveJobs() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd")!
        let root = try registry.makeRoot(label: "already-disabled")
        let bookmark = try FoundationSecurityScopedBookmarkAdapter().createReadOnlyBookmark(for: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .disabled
        )

        let pendingID = UUID(uuidString: "dededede-dede-dede-dede-dededededede")!
        let nowMs = JobTestSupport.baseTimeMs
        try await database.pool.write { db in
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
        }

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker
        )

        _ = try await coordinator.disableFolderSource(sourceID: sourceID)

        let pendingState: String = try await database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM job WHERE id = ?", arguments: [pendingID.uuidString.lowercased()]) ?? ""
        }
        XCTAssertEqual(pendingState, JobState.cancelled.rawValue)
    }

    func testDisableConvergesFullJobKindAndStateMatrix() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "12121212-1212-1212-1212-121212121212")!
        let root = try registry.makeRoot(label: "disable-matrix")
        let bookmark = try FoundationSecurityScopedBookmarkAdapter().createReadOnlyBookmark(for: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark
        )

        let pendingID = UUID(uuidString: "13131313-1313-1313-1313-131313131313")!
        let pausedID = UUID(uuidString: "14141414-1414-1414-1414-141414141414")!
        let retryableFailedID = UUID(uuidString: "15151515-1515-1515-1515-151515151516")!
        let runningNoneID = UUID(uuidString: "16161616-1616-1616-1616-161616161617")!
        let runningPauseID = UUID(uuidString: "17171717-1717-1717-1717-171717171718")!
        let terminalID = UUID(uuidString: "18181818-1818-1818-1818-181818181819")!
        let otherKindID = UUID(uuidString: "19191919-1919-1919-1919-19191919191a")!
        let nowMs = JobTestSupport.baseTimeMs
        let payload = try FolderReconcileJobFactory.makePayload(sourceID: sourceID)
        let coalescingKey = FolderReconcileJobFactory.coalescingKey(sourceID: sourceID)

        try await database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, source_id, coalescing_key,
                    state, control_request, priority, attempts, max_attempts, not_before_ms,
                    progress_completed, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 1, ?, ?, ?, 'pending', 'none', 0, 0, 5, ?, 0, ?, ?)
                """,
                arguments: [
                    pendingID.uuidString.lowercased(), FolderReconcileJobFactory.kind, payload,
                    sourceID.uuidString.lowercased(), coalescingKey, nowMs, nowMs, nowMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, source_id, coalescing_key,
                    state, control_request, priority, attempts, max_attempts, not_before_ms,
                    progress_completed, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 1, ?, ?, ?, 'paused', 'none', 0, 1, 5, ?, 0, ?, ?)
                """,
                arguments: [
                    pausedID.uuidString.lowercased(), FolderReconcileJobFactory.kind, payload,
                    sourceID.uuidString.lowercased(), "\(coalescingKey):paused", nowMs, nowMs, nowMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, source_id, coalescing_key,
                    state, control_request, priority, attempts, max_attempts, not_before_ms,
                    last_error_code, last_error_message, progress_completed, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 1, ?, ?, ?, 'retryableFailed', 'none', 0, 2, 5, ?, 'interrupted', 'retry me', 0, ?, ?)
                """,
                arguments: [
                    retryableFailedID.uuidString.lowercased(), FolderReconcileJobFactory.kind, payload,
                    sourceID.uuidString.lowercased(), "\(coalescingKey):retry", nowMs, nowMs, nowMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, source_id, coalescing_key,
                    state, control_request, priority, attempts, max_attempts, not_before_ms,
                    lease_owner, lease_expires_at_ms, progress_completed, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 1, ?, ?, ?, 'running', 'none', 0, 1, 5, ?, 'worker-a', ?, 0, ?, ?)
                """,
                arguments: [
                    runningNoneID.uuidString.lowercased(), FolderReconcileJobFactory.kind, payload,
                    sourceID.uuidString.lowercased(), "\(coalescingKey):running-none", nowMs, nowMs + 60_000, nowMs, nowMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, source_id, coalescing_key,
                    state, control_request, priority, attempts, max_attempts, not_before_ms,
                    lease_owner, lease_expires_at_ms, progress_completed, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 1, ?, ?, ?, 'running', 'pause', 0, 1, 5, ?, 'worker-b', ?, 0, ?, ?)
                """,
                arguments: [
                    runningPauseID.uuidString.lowercased(), FolderReconcileJobFactory.kind, payload,
                    sourceID.uuidString.lowercased(), "\(coalescingKey):running-pause", nowMs, nowMs + 60_000, nowMs, nowMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, source_id, coalescing_key,
                    state, control_request, priority, attempts, max_attempts, not_before_ms,
                    progress_completed, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 1, ?, ?, ?, 'completed', 'none', 0, 1, 5, ?, 10, ?, ?)
                """,
                arguments: [
                    terminalID.uuidString.lowercased(), FolderReconcileJobFactory.kind, payload,
                    sourceID.uuidString.lowercased(), "\(coalescingKey):terminal", nowMs, nowMs, nowMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, source_id, coalescing_key,
                    state, control_request, priority, attempts, max_attempts, not_before_ms,
                    progress_completed, created_at_ms, updated_at_ms
                ) VALUES (?, 'other.job.v1', 1, ?, ?, ?, 'pending', 'none', 0, 0, 5, ?, 0, ?, ?)
                """,
                arguments: [
                    otherKindID.uuidString.lowercased(), payload,
                    sourceID.uuidString.lowercased(), "other.job.v1:\(sourceID.uuidString.lowercased())",
                    nowMs, nowMs, nowMs,
                ]
            )
        }

        let pendingBefore = try FolderAuthorizationTestSupport.fetchJobSnapshot(database, jobID: pendingID)!
        let pausedBefore = try FolderAuthorizationTestSupport.fetchJobSnapshot(database, jobID: pausedID)!
        let retryableFailedBefore = try FolderAuthorizationTestSupport.fetchJobSnapshot(database, jobID: retryableFailedID)!
        let runningNoneBefore = try FolderAuthorizationTestSupport.fetchJobSnapshot(database, jobID: runningNoneID)!
        let runningPauseBefore = try FolderAuthorizationTestSupport.fetchJobSnapshot(database, jobID: runningPauseID)!
        let terminalBefore = try FolderAuthorizationTestSupport.fetchJobSnapshot(database, jobID: terminalID)!
        let otherBefore = try FolderAuthorizationTestSupport.fetchJobSnapshot(database, jobID: otherKindID)!
        let sourceBefore = try FolderAuthorizationTestSupport.fetchSourceRowSnapshot(database, sourceID: sourceID)!

        let disableNowMs = FolderAuthorizationTestSupport.baseTimeMs
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            nowMs: disableNowMs
        )
        _ = try await coordinator.disableFolderSource(sourceID: sourceID)

        FolderAuthorizationTestSupport.assertJobRow(
            try XCTUnwrap(try FolderAuthorizationTestSupport.fetchSourceRowSnapshot(database, sourceID: sourceID)),
            expectedChanges: [
                "state": SourceState.disabled.rawValue,
                "updated_at_ms": String(disableNowMs),
            ],
            unchangedFrom: sourceBefore
        )

        for (jobID, before) in [
            (pendingID, pendingBefore),
            (pausedID, pausedBefore),
            (retryableFailedID, retryableFailedBefore),
        ] {
            let actual = try XCTUnwrap(try FolderAuthorizationTestSupport.fetchJobSnapshot(database, jobID: jobID))
            FolderAuthorizationTestSupport.assertJobRowConvergedToCancelled(
                actual: actual,
                before: before,
                updatedAtMs: disableNowMs
            )
        }

        for (jobID, before) in [
            (runningNoneID, runningNoneBefore),
            (runningPauseID, runningPauseBefore),
        ] {
            let actual = try XCTUnwrap(try FolderAuthorizationTestSupport.fetchJobSnapshot(database, jobID: jobID))
            FolderAuthorizationTestSupport.assertJobRowConvergedToRunningCancel(
                actual: actual,
                before: before,
                updatedAtMs: disableNowMs
            )
        }

        XCTAssertEqual(
            try FolderAuthorizationTestSupport.fetchJobSnapshot(database, jobID: terminalID),
            terminalBefore
        )
        XCTAssertEqual(
            try FolderAuthorizationTestSupport.fetchJobSnapshot(database, jobID: otherKindID),
            otherBefore
        )
    }

    func testDisableJobConvergenceFailureRollsBackSourceAndJobs() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        try FolderAuthorizationTestSupport.AuthorizationDatabaseTestFaults
            .installDisableLateJobConvergenceAbortTrigger(database)

        let sourceID = UUID(uuidString: "efefefef-efef-efef-efef-efefefefefef")!
        let root = try registry.makeRoot(label: "disable-fault")
        let bookmark = try FoundationSecurityScopedBookmarkAdapter().createReadOnlyBookmark(for: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark
        )

        let pendingID = UUID(uuidString: "fafafafa-fafa-fafa-fafa-fafafafafafa")!
        let runningID = UUID(uuidString: "fbfbfbfb-fbfb-fbfb-fbfb-fbfbfbfbfbfb")!
        let nowMs = JobTestSupport.baseTimeMs
        let payload = try FolderReconcileJobFactory.makePayload(sourceID: sourceID)
        try await database.pool.write { db in
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
                    payload,
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
                    payload,
                    sourceID.uuidString.lowercased(),
                    "folder.reconcile.v1:fault-\(sourceID.uuidString.lowercased())",
                    nowMs,
                    nowMs + 60_000,
                    nowMs,
                    nowMs,
                ]
            )
        }

        let sourceBefore = try FolderAuthorizationTestSupport.fetchSourceRowSnapshot(database, sourceID: sourceID)!
        let pendingBefore = try FolderAuthorizationTestSupport.fetchJobSnapshot(database, jobID: pendingID)!
        let runningBefore = try FolderAuthorizationTestSupport.fetchJobSnapshot(database, jobID: runningID)!

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker
        )

        do {
            _ = try await coordinator.disableFolderSource(sourceID: sourceID)
            XCTFail("Expected persistenceFailure")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .persistenceFailure)
        }

        XCTAssertEqual(
            try FolderAuthorizationTestSupport.fetchSourceRowSnapshot(database, sourceID: sourceID),
            sourceBefore
        )
        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchJobSnapshot(database, jobID: pendingID), pendingBefore)
        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchJobSnapshot(database, jobID: runningID), runningBefore)
    }

    func testDeleteLibrarySourceRemovesAppRecordsButLeavesOriginalFileUntouched() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "20202020-2020-2020-2020-202020202020")!
        let assetID = UUID(uuidString: "21212121-2121-2121-2121-212121212121")!
        let tagID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let jobID = UUID(uuidString: "23232323-2323-2323-2323-232323232323")!
        let recycleID = UUID(uuidString: "24232323-2323-2323-2323-232323232323")!
        let root = try registry.makeRoot(label: "delete-source")
        let originalURL = root.appendingPathComponent("photo.jpg")
        let originalBytes = Data("original-photo-bytes".utf8)
        try originalBytes.write(to: originalURL)
        let bookmark = try FoundationSecurityScopedBookmarkAdapter().createReadOnlyBookmark(for: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .disabled
        )
        try FolderAuthorizationTestSupport.insertFolderAssetGraph(
            database: database,
            sourceID: sourceID,
            assetID: assetID,
            tagID: tagID
        )
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source_mutation_authorization (
                    source_id, bookmark, updated_at_ms
                ) VALUES (?, ?, 100)
                """,
                arguments: [
                    sourceID.uuidString.lowercased(),
                    Data("fixture-write-bookmark".utf8),
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO recycle_entry (
                    id, asset_id, source_kind, trashed_at_ms, purge_after_ms,
                    state, quarantine_relative_path, original_relative_path,
                    created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'file', 100, 200, 'restored', ?, 'photo.jpg', 100, 100)
                """,
                arguments: [
                    recycleID.uuidString.lowercased(),
                    assetID.uuidString.lowercased(),
                    "objects/restored-photo.jpg",
                ]
            )
        }
        _ = try JobTestSupport.makeQueue(database: database).enqueue(
            EnqueueJobCommand(
                id: jobID,
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
        let purger = RecordingAssetCachePurger()
        let service = LibrarySourceDeletionService(database: database, cachePurger: purger)

        let preparation = try service.prepare(sourceID: sourceID)
        let outcome = try service.delete(preparation: preparation)

        XCTAssertEqual(
            outcome,
            DeleteLibrarySourceOutcome(sourceID: sourceID, deletedAssetCount: 1)
        )
        XCTAssertEqual(purger.assetIDs, [assetID])
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        try database.pool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source WHERE id = ?", arguments: [sourceID.uuidString.lowercased()]),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE id = ?", arguments: [assetID.uuidString.lowercased()]),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tag_decision WHERE asset_id = ?", arguments: [assetID.uuidString.lowercased()]),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job WHERE id = ?", arguments: [jobID.uuidString.lowercased()]),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM recycle_entry WHERE id = ?",
                    arguments: [recycleID.uuidString.lowercased()]
                ),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM source_mutation_authorization WHERE source_id = ?",
                    arguments: [sourceID.uuidString.lowercased()]
                ),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag WHERE id = ?", arguments: [tagID.uuidString.lowercased()]),
                1,
                "Global tag definitions are not owned by one source"
            )
        }
    }

    func testDeleteLibrarySourceRejectsUnresolvedRecycleEntryWithoutChangingCatalog() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "24242424-2424-2424-2424-242424242424")!
        let assetID = UUID(uuidString: "25252525-2525-2525-2525-252525252525")!
        let tagID = UUID(uuidString: "26262626-2626-2626-2626-262626262626")!
        let recycleID = UUID(uuidString: "27272727-2727-2727-2727-272727272727")!
        let failedID = UUID(uuidString: "37373737-3737-3737-3737-373737373737")!
        let root = try registry.makeRoot(label: "delete-source-recycle-block")
        let bookmark = try FoundationSecurityScopedBookmarkAdapter().createReadOnlyBookmark(for: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .disabled
        )
        try FolderAuthorizationTestSupport.insertFolderAssetGraph(
            database: database,
            sourceID: sourceID,
            assetID: assetID,
            tagID: tagID
        )
        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET availability = 'recycled' WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
            try db.execute(
                sql: """
                INSERT INTO recycle_entry (
                    id, asset_id, source_kind, trashed_at_ms, purge_after_ms,
                    state, quarantine_relative_path, original_relative_path,
                    created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'file', 100, 200, 'recycled', ?, 'photo.jpg', 100, 100)
                """,
                arguments: [
                    recycleID.uuidString.lowercased(),
                    assetID.uuidString.lowercased(),
                    "objects/recycled-photo.jpg",
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO recycle_entry (
                    id, asset_id, source_kind, trashed_at_ms, purge_after_ms,
                    state, quarantine_relative_path, original_relative_path,
                    error_code, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'file', 90, 200, 'failed', ?, 'photo.jpg', ?, 90, 90)
                """,
                arguments: [
                    failedID.uuidString.lowercased(),
                    assetID.uuidString.lowercased(),
                    "objects/recycled-photo.jpg",
                    RecycleFailureCode.mutationAuthorizationRequired,
                ]
            )
        }
        let purger = RecordingAssetCachePurger()
        let service = LibrarySourceDeletionService(database: database, cachePurger: purger)

        XCTAssertThrowsError(try service.prepare(sourceID: sourceID)) { error in
            XCTAssertEqual(
                error as? DeleteLibrarySourceError,
                .unresolvedRecycleEntries(
                    blockers: LibrarySourceDeletionBlockers(
                        recycledItemCount: 1,
                        discardableAuthorizationFailureCount: 1,
                        inspectionRequiredCount: 0
                    )
                )
            )
        }
        XCTAssertTrue(purger.assetIDs.isEmpty)
        let recycle = LibrarySlimmingRecycleService(
            database: database,
            mutationAccess: DirectFolderMutationAccess(
                rootsBySourceID: [sourceID: root]
            ),
            quarantineRootURL: root.appendingPathComponent("Quarantine"),
            clock: FixedJobClock(nowMs: 300)
        )
        try recycle.discardFailedPreflightEntry(entryID: failedID)
        XCTAssertEqual(try recycle.listRecycleBinEntries().map(\.id), [recycleID])
        XCTAssertThrowsError(try service.prepare(sourceID: sourceID)) { error in
            XCTAssertEqual(
                error as? DeleteLibrarySourceError,
                .unresolvedRecycleEntries(
                    blockers: LibrarySourceDeletionBlockers(
                        recycledItemCount: 1,
                        discardableAuthorizationFailureCount: 0,
                        inspectionRequiredCount: 0
                    )
                )
            )
        }
        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchSourceState(database, sourceID: sourceID), .disabled)
        let assetCount = try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM asset WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            ) ?? 0
        }
        XCTAssertEqual(assetCount, 1)
    }

    func testPreflightAuthorizationFailureCanBeDiscardedBeforeSourceDeletion() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "28282828-2828-2828-2828-282828282828")!
        let assetID = UUID(uuidString: "29292929-2929-2929-2929-292929292929")!
        let tagID = UUID(uuidString: "30303030-3030-3030-3030-303030303030")!
        let recycleID = UUID(uuidString: "31313131-3131-3131-3131-313131313131")!
        let root = try registry.makeRoot(label: "delete-source-preflight-failure")
        let originalURL = root.appendingPathComponent("photo.jpg")
        let originalBytes = Data("preflight-original".utf8)
        try originalBytes.write(to: originalURL)
        let bookmark = try FoundationSecurityScopedBookmarkAdapter()
            .createReadOnlyBookmark(for: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .disabled
        )
        try FolderAuthorizationTestSupport.insertFolderAssetGraph(
            database: database,
            sourceID: sourceID,
            assetID: assetID,
            tagID: tagID
        )
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO recycle_entry (
                    id, asset_id, source_kind, trashed_at_ms, purge_after_ms,
                    state, quarantine_relative_path, original_relative_path,
                    error_code, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'file', 100, 200, 'failed', ?, 'photo.jpg', ?, 100, 100)
                """,
                arguments: [
                    recycleID.uuidString.lowercased(),
                    assetID.uuidString.lowercased(),
                    "objects/preflight-photo.jpg",
                    RecycleFailureCode.mutationAuthorizationRequired,
                ]
            )
        }
        let purger = RecordingAssetCachePurger()
        let deletion = LibrarySourceDeletionService(
            database: database,
            cachePurger: purger
        )

        XCTAssertThrowsError(try deletion.prepare(sourceID: sourceID)) { error in
            XCTAssertEqual(
                error as? DeleteLibrarySourceError,
                .unresolvedRecycleEntries(
                    blockers: LibrarySourceDeletionBlockers(
                        recycledItemCount: 0,
                        discardableAuthorizationFailureCount: 1,
                        inspectionRequiredCount: 0
                    )
                )
            )
        }
        XCTAssertTrue(purger.assetIDs.isEmpty)

        let recycle = LibrarySlimmingRecycleService(
            database: database,
            mutationAccess: DirectFolderMutationAccess(
                rootsBySourceID: [sourceID: root]
            ),
            quarantineRootURL: root.appendingPathComponent("Quarantine"),
            clock: FixedJobClock(nowMs: 300)
        )
        let visible = try recycle.listRecycleBinEntries()
        XCTAssertEqual(visible.map(\.id), [recycleID])
        XCTAssertEqual(visible.first?.resolution, .discardPreflightFailure)

        try recycle.discardFailedPreflightEntry(entryID: recycleID)

        XCTAssertTrue(try recycle.listRecycleBinEntries().isEmpty)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Quarantine").path
            )
        )

        let preparation = try deletion.prepare(sourceID: sourceID)
        let outcome = try deletion.delete(preparation: preparation)

        XCTAssertEqual(outcome.deletedAssetCount, 1)
        XCTAssertEqual(purger.assetIDs, [assetID])
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        try database.pool.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM source WHERE id = ?",
                    arguments: [sourceID.uuidString.lowercased()]
                ),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM asset WHERE source_id = ?",
                    arguments: [sourceID.uuidString.lowercased()]
                ),
                0
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM recycle_entry WHERE asset_id = ?",
                    arguments: [assetID.uuidString.lowercased()]
                ),
                0
            )
        }
    }

    func testIndeterminateFailedAndPendingEntriesRemainVisibleAndBlockWithoutCacheCleanup() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "32323232-3232-3232-3232-323232323232")!
        let assetID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let tagID = UUID(uuidString: "34343434-3434-3434-3434-343434343434")!
        let failedID = UUID(uuidString: "35353535-3535-3535-3535-353535353535")!
        let pendingID = UUID(uuidString: "36363636-3636-3636-3636-363636363636")!
        let root = try registry.makeRoot(label: "delete-source-indeterminate")
        let originalURL = root.appendingPathComponent("photo.jpg")
        let originalBytes = Data("indeterminate-original".utf8)
        try originalBytes.write(to: originalURL)
        let quarantineRoot = root.appendingPathComponent("Quarantine", isDirectory: true)
        let quarantineRelativePath = "objects/indeterminate-photo.jpg"
        let quarantineURL = quarantineRoot.appendingPathComponent(quarantineRelativePath)
        try FileManager.default.createDirectory(
            at: quarantineURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let quarantineBytes = Data("retained-quarantine".utf8)
        try quarantineBytes.write(to: quarantineURL)
        let bookmark = try FoundationSecurityScopedBookmarkAdapter()
            .createReadOnlyBookmark(for: root)
        try FolderAuthorizationTestSupport.insertFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark,
            state: .disabled
        )
        try FolderAuthorizationTestSupport.insertFolderAssetGraph(
            database: database,
            sourceID: sourceID,
            assetID: assetID,
            tagID: tagID
        )
        try database.pool.write { db in
            for (entryID, state, errorCode) in [
                (failedID, "failed", "ioFailure"),
                (pendingID, "pending", nil),
            ] {
                try db.execute(
                    sql: """
                    INSERT INTO recycle_entry (
                        id, asset_id, source_kind, trashed_at_ms, purge_after_ms,
                        state, quarantine_relative_path, original_relative_path,
                        error_code, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'file', 100, 200, ?, ?, 'photo.jpg', ?, 100, 100)
                    """,
                    arguments: [
                        entryID.uuidString.lowercased(),
                        assetID.uuidString.lowercased(),
                        state,
                        quarantineRelativePath,
                        errorCode,
                    ]
                )
            }
        }
        let purger = RecordingAssetCachePurger()
        let deletion = LibrarySourceDeletionService(
            database: database,
            cachePurger: purger
        )
        let recycle = LibrarySlimmingRecycleService(
            database: database,
            mutationAccess: DirectFolderMutationAccess(
                rootsBySourceID: [sourceID: root]
            ),
            quarantineRootURL: quarantineRoot,
            clock: FixedJobClock(nowMs: 300)
        )

        XCTAssertThrowsError(try deletion.prepare(sourceID: sourceID)) { error in
            XCTAssertEqual(
                error as? DeleteLibrarySourceError,
                .unresolvedRecycleEntries(
                    blockers: LibrarySourceDeletionBlockers(
                        recycledItemCount: 0,
                        discardableAuthorizationFailureCount: 0,
                        inspectionRequiredCount: 2
                    )
                )
            )
        }
        XCTAssertThrowsError(
            try recycle.discardFailedPreflightEntry(entryID: failedID)
        ) { error in
            XCTAssertEqual(error as? LibrarySlimmingRecycleError, .invalidState)
        }
        let visible = try recycle.listRecycleBinEntries()
        XCTAssertEqual(Set(visible.map(\.id)), Set([failedID, pendingID]))
        XCTAssertEqual(
            Set(visible.map(\.resolution)),
            Set([.inspect, .retryInterruptedOperation])
        )
        XCTAssertTrue(purger.assetIDs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: quarantineURL), quarantineBytes)
        XCTAssertEqual(
            try FolderAuthorizationTestSupport.fetchSourceState(
                database,
                sourceID: sourceID
            ),
            .disabled
        )
    }

    func testReauthorizeSameRootSucceedsAndReusesActiveJob() async throws {
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

        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        picker.configuredResponses = [root]
        let (coordinator, _, _, _) = FolderAuthorizationTestSupport.makeCoordinator(
            database: database,
            picker: picker,
            ids: [UUID()]
        )

        let outcome = try await coordinator.reauthorizeFolder(sourceID: sourceID)
        guard case let .reauthorized(reauthorizedID) = outcome else {
            return XCTFail("Expected reauthorized, got \(outcome)")
        }
        XCTAssertEqual(reauthorizedID, sourceID)
        XCTAssertEqual(try FolderAuthorizationTestSupport.fetchSourceState(database, sourceID: sourceID), .active)
        XCTAssertEqual(try FolderAuthorizationTestSupport.activeReconcileJobs(database, sourceID: sourceID), 1)
        XCTAssertEqual(try FolderAuthorizationTestSupport.jobCount(database), 1)
        let mutationBookmark: Data? = try await database.pool.read { db in
            try Data.fetchOne(
                db,
                sql: """
                SELECT bookmark
                FROM source_mutation_authorization
                WHERE source_id = ?
                """,
                arguments: [sourceID.uuidString.lowercased()]
            )
        }
        XCTAssertNotNil(mutationBookmark)
    }

    func testReauthorizeRejectsActiveDisabledMismatchIndeterminateAndCancel() async throws {
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
            _ = try await coordinator.reauthorizeFolder(sourceID: sourceID)
            XCTFail("Expected invalid state")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .invalidSourceState)
        }

        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET state = 'disabled' WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            )
        }
        do {
            _ = try await coordinator.reauthorizeFolder(sourceID: sourceID)
            XCTFail("Expected invalid state")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .invalidSourceState)
        }

        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET state = 'authorizationRequired' WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            )
        }

        picker.configuredResponses = [nil]
        let cancelled = try await coordinator.reauthorizeFolder(sourceID: sourceID)
        XCTAssertEqual(cancelled, .cancelled)

        picker.configuredResponses = [other]
        do {
            _ = try await coordinator.reauthorizeFolder(sourceID: sourceID)
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

private final class RecordingAssetCachePurger: AppOwnedAssetCachePurging, @unchecked Sendable {
    private let lock = NSLock()
    private var storedAssetIDs: [UUID] = []

    var assetIDs: [UUID] {
        lock.withLock { storedAssetIDs }
    }

    func purge(assetID: UUID) throws {
        lock.withLock { storedAssetIDs.append(assetID) }
    }
}
