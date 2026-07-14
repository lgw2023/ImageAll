import GRDB
import XCTest
@testable import ImageAll

final class JobStateTransitionTests: XCTestCase {
    private struct TransitionCase {
        let name: String
        let setup: (GRDBJobQueue, UUID) throws -> Void
        let command: JobStateCommand.Operation
        let expectSuccess: Bool
    }

    func testLegalStateCommandsSucceed() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        let pendingQueue = JobTestSupport.makeQueue(database: database)
        let pendingID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: pendingQueue, id: pendingID)
        _ = try pendingQueue.applyStateCommand(JobStateCommand(jobID: pendingID, operation: .pause))
        XCTAssertEqual(try pendingQueue.fetchJob(id: pendingID).state, .paused)

        let resumeQueue = JobTestSupport.makeQueue(database: try CatalogDatabase.open(at: try makeTempDatabaseURL()))
        let resumeID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: resumeQueue, id: resumeID)
        _ = try resumeQueue.applyStateCommand(JobStateCommand(jobID: resumeID, operation: .pause))
        _ = try resumeQueue.applyStateCommand(
            JobStateCommand(jobID: resumeID, operation: .resume(notBeforeMs: JobTestSupport.baseTimeMs))
        )
        XCTAssertEqual(try resumeQueue.fetchJob(id: resumeID).state, .pending)

        let cancelQueue = JobTestSupport.makeQueue(database: try CatalogDatabase.open(at: try makeTempDatabaseURL()))
        let cancelPendingID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: cancelQueue, id: cancelPendingID)
        _ = try cancelQueue.applyStateCommand(JobStateCommand(jobID: cancelPendingID, operation: .cancel))
        XCTAssertEqual(try cancelQueue.fetchJob(id: cancelPendingID).state, .cancelled)

        let retryQueue = JobTestSupport.makeQueue(database: try CatalogDatabase.open(at: try makeTempDatabaseURL()))
        let retryCancelID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: retryQueue, id: retryCancelID, maxAttempts: 2)
        let retryLease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: retryQueue))
        XCTAssertEqual(retryLease.jobID, retryCancelID)
        _ = try retryQueue.submitSafeBatch(
            SafeBatchCommitInput(
                lease: retryLease,
                outcome: .retryableFailure(code: .interrupted),
                checkpoint: nil,
                progress: JobProgress(completed: 0, total: nil)
            )
        )
        _ = try retryQueue.applyStateCommand(JobStateCommand(jobID: retryCancelID, operation: .cancel))
        XCTAssertEqual(try retryQueue.fetchJob(id: retryCancelID).state, .cancelled)
    }

    func testIllegalTransitionsLeaveRowUnchanged() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID)
        let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))
        _ = try queue.submitSafeBatch(
            SafeBatchCommitInput(
                lease: lease,
                outcome: .completed,
                checkpoint: nil,
                progress: JobProgress(completed: 1, total: 1)
            )
        )

        let baseline = try database.pool.read { db in
            try JobTestSupport.fetchRowSnapshot(db, jobID: jobID)
        }

        XCTAssertThrowsError(
            try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .pause))
        ) { error in
            XCTAssertEqual(
                error as? JobQueueError,
                .invalidTransition(currentState: .completed, operation: "pause")
            )
        }
        try assertRowUnchanged(database: database, jobID: jobID, baseline: try XCTUnwrap(baseline))

        XCTAssertThrowsError(
            try queue.applyStateCommand(
                JobStateCommand(jobID: jobID, operation: .resume(notBeforeMs: JobTestSupport.baseTimeMs))
            )
        ) { error in
            XCTAssertEqual(
                error as? JobQueueError,
                .invalidTransition(currentState: .completed, operation: "resume")
            )
        }
        try assertRowUnchanged(database: database, jobID: jobID, baseline: try XCTUnwrap(baseline))
    }

    func testRunningPauseAndCancelAreMonotonic() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID)
        _ = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))

        _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .pause))
        var snapshot = try queue.fetchJob(id: jobID)
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertEqual(snapshot.controlRequest, .pause)

        let afterPause = try database.pool.read { db in
            try JobTestSupport.fetchRowSnapshot(db, jobID: jobID)
        }
        _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .pause))
        try assertRowUnchanged(database: database, jobID: jobID, baseline: try XCTUnwrap(afterPause))

        _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .cancel))
        snapshot = try queue.fetchJob(id: jobID)
        XCTAssertEqual(snapshot.controlRequest, .cancel)

        let afterCancel = try database.pool.read { db in
            try JobTestSupport.fetchRowSnapshot(db, jobID: jobID)
        }
        _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .pause))
        try assertRowUnchanged(database: database, jobID: jobID, baseline: try XCTUnwrap(afterCancel))
    }

    func testPauseThenCancelOnRunningCancelWinsAtBoundary() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID)
        let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))

        _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .pause))
        _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .cancel))

        let snapshot = try queue.submitSafeBatch(
            SafeBatchCommitInput(
                lease: lease,
                outcome: .completed,
                checkpoint: JobTestSupport.testCheckpoint,
                progress: JobProgress(completed: 1, total: 1)
            )
        )

        XCTAssertEqual(snapshot.state, .cancelled)
        XCTAssertEqual(snapshot.controlRequest, .none)
        XCTAssertEqual(snapshot.checkpoint, JobTestSupport.testCheckpoint)
        XCTAssertEqual(snapshot.progress.completed, 1)
    }

    func testRetryableFailedPauseRejected() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID, maxAttempts: 3)
        let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))
        _ = try queue.submitSafeBatch(
            SafeBatchCommitInput(
                lease: lease,
                outcome: .retryableFailure(code: .interrupted),
                checkpoint: nil,
                progress: JobProgress(completed: 0, total: nil)
            )
        )

        let baseline = try database.pool.read { db in
            try JobTestSupport.fetchRowSnapshot(db, jobID: jobID)
        }

        XCTAssertThrowsError(
            try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .pause))
        ) { error in
            XCTAssertEqual(
                error as? JobQueueError,
                .invalidTransition(currentState: .retryableFailed, operation: "pause")
            )
        }
        try assertRowUnchanged(database: database, jobID: jobID, baseline: try XCTUnwrap(baseline))
    }
}
