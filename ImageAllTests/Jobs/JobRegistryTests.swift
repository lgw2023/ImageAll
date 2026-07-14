import GRDB
import XCTest
@testable import ImageAll

final class JobRegistryTests: XCTestCase {
    func testUnknownKindTerminatesAfterClaimWithoutCallingHandler() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let tracker = JobTestSupport.HandlerCallTracker()

        let handler = FakeJobHandler(kind: JobTestSupport.testKind) { _, _, _ in
            tracker.markCalled()
            return JobHandlerExecutionResult(
                outcome: .completed,
                checkpoint: nil,
                progress: JobProgress(completed: 1, total: 1)
            )
        }

        let coordinator = JobTestSupport.makeCoordinator(queue: queue, handlers: [handler])
        _ = try JobTestSupport.enqueueDefault(queue: queue, kind: "missing.kind")

        let result = try XCTUnwrap(
            try coordinator.claimAndExecuteOnce(
                ClaimNextInput(owner: "worker", leaseDurationMs: JobTestSupport.leaseDurationMs)
            )
        )

        XCTAssertFalse(tracker.called)
        XCTAssertFalse(result.handlerInvoked)
        XCTAssertEqual(result.snapshot.state, .terminalFailed)
        XCTAssertEqual(result.snapshot.lastErrorCode, .unknownJobKind)
        XCTAssertNil(result.snapshot.leaseOwner)
        XCTAssertEqual(result.snapshot.controlRequest, .none)
    }

    func testUnsupportedPayloadVersionTerminatesWithoutHandler() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let tracker = JobTestSupport.HandlerCallTracker()

        let handler = FakeJobHandler(
            kind: JobTestSupport.testKind,
            supportedPayloadVersions: [1]
        ) { _, _, _ in
            tracker.markCalled()
            return JobHandlerExecutionResult(
                outcome: .completed,
                checkpoint: nil,
                progress: JobProgress(completed: 1, total: 1)
            )
        }

        let coordinator = JobTestSupport.makeCoordinator(queue: queue, handlers: [handler])
        _ = try queue.enqueue(
            EnqueueJobCommand(
                id: UUID(),
                kind: JobTestSupport.testKind,
                payloadVersion: 99,
                payload: JobTestSupport.testPayload,
                sourceID: nil,
                coalescingKey: nil,
                priority: 0,
                maxAttempts: 3,
                notBeforeMs: JobTestSupport.baseTimeMs
            )
        )

        let result = try XCTUnwrap(
            try coordinator.claimAndExecuteOnce(
                ClaimNextInput(owner: "worker", leaseDurationMs: JobTestSupport.leaseDurationMs)
            )
        )

        XCTAssertFalse(tracker.called)
        XCTAssertEqual(result.snapshot.state, .terminalFailed)
        XCTAssertEqual(result.snapshot.lastErrorCode, .unsupportedPayloadVersion)
    }

    func testUnsupportedCheckpointVersionTerminatesWithoutHandler() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let tracker = JobTestSupport.HandlerCallTracker()

        let handler = FakeJobHandler(
            kind: JobTestSupport.testKind,
            supportedPayloadVersions: [1],
            supportedCheckpointVersions: [1]
        ) { _, _, _ in
            tracker.markCalled()
            return JobHandlerExecutionResult(
                outcome: .completed,
                checkpoint: nil,
                progress: JobProgress(completed: 1, total: 1)
            )
        }

        let coordinator = JobTestSupport.makeCoordinator(queue: queue, handlers: [handler])
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID)

        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE job SET checkpoint_version = 99, checkpoint = ?
                WHERE id = ?
                """,
                arguments: [Data("bad".utf8), jobID.uuidString.lowercased()]
            )
        }

        let result = try XCTUnwrap(
            try coordinator.claimAndExecuteOnce(
                ClaimNextInput(owner: "worker", leaseDurationMs: JobTestSupport.leaseDurationMs)
            )
        )

        XCTAssertFalse(tracker.called)
        XCTAssertFalse(result.handlerInvoked)
        XCTAssertEqual(result.snapshot.state, .terminalFailed)
        XCTAssertEqual(result.snapshot.lastErrorCode, .unsupportedCheckpointVersion)
        XCTAssertNil(result.snapshot.leaseOwner)
    }

    func testRegistryRejectionPreservesExistingCheckpointAndProgress() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database, retryDelayMs: 0)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID, maxAttempts: 3)
        let firstLease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))
        _ = try queue.submitSafeBatch(
            SafeBatchCommitInput(
                lease: firstLease,
                outcome: .retryableFailure(code: .interrupted),
                checkpoint: JobTestSupport.testCheckpoint,
                progress: JobProgress(completed: 7, total: 10)
            )
        )
        try queue.settleRetryableJobs()

        let handler = FakeJobHandler(
            kind: JobTestSupport.testKind,
            supportedPayloadVersions: [1],
            supportedCheckpointVersions: [1]
        ) { _, _, _ in
            JobHandlerExecutionResult(
                outcome: .completed,
                checkpoint: nil,
                progress: JobProgress(completed: 99, total: 99)
            )
        }

        let coordinator = JobTestSupport.makeCoordinator(queue: queue, handlers: [handler])
        let corruptedCheckpoint = JobCheckpoint(version: 99, data: Data("bad".utf8))

        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE job SET checkpoint_version = ?, checkpoint = ?
                WHERE id = ?
                """,
                arguments: [corruptedCheckpoint.version, corruptedCheckpoint.data, jobID.uuidString.lowercased()]
            )
        }

        let result = try XCTUnwrap(
            try coordinator.claimAndExecuteOnce(
                ClaimNextInput(owner: "worker", leaseDurationMs: JobTestSupport.leaseDurationMs)
            )
        )

        XCTAssertFalse(result.handlerInvoked)
        XCTAssertEqual(result.snapshot.state, .terminalFailed)
        XCTAssertEqual(result.snapshot.lastErrorCode, .unsupportedCheckpointVersion)
        XCTAssertEqual(result.snapshot.checkpoint, corruptedCheckpoint)
        XCTAssertEqual(result.snapshot.progress, JobProgress(completed: 7, total: 10))
    }

    func testRegisteredHandlerIsInvokedOnHappyPath() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let tracker = JobTestSupport.HandlerCallTracker()

        let handler = FakeJobHandler(kind: JobTestSupport.testKind) { _, _, _ in
            tracker.markCalled()
            return JobHandlerExecutionResult(
                outcome: .completed,
                checkpoint: JobTestSupport.testCheckpoint,
                progress: JobProgress(completed: 1, total: 1)
            )
        }

        let coordinator = JobTestSupport.makeCoordinator(queue: queue, handlers: [handler])
        _ = try JobTestSupport.enqueueDefault(queue: queue)

        let result = try XCTUnwrap(
            try coordinator.claimAndExecuteOnce(
                ClaimNextInput(owner: "worker", leaseDurationMs: JobTestSupport.leaseDurationMs)
            )
        )

        XCTAssertTrue(tracker.called)
        XCTAssertTrue(result.handlerInvoked)
        XCTAssertEqual(result.snapshot.state, .completed)
    }
}
