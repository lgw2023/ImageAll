import GRDB
import XCTest
@testable import ImageAll

final class JobRetryRecoveryTests: XCTestCase {
    func testRetryableFailedNotDueStaysUnchanged() throws {
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

        try queue.settleRetryableJobs()
        try assertRowUnchanged(database: database, jobID: jobID, baseline: try XCTUnwrap(baseline))
    }

    func testRetryableFailedDuePromotesToPending() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(
            database: database,
            nowMs: JobTestSupport.baseTimeMs,
            retryDelayMs: 0
        )
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

        try queue.settleRetryableJobs()
        let snapshot = try queue.fetchJob(id: jobID)
        XCTAssertEqual(snapshot.state, .pending)
        XCTAssertEqual(snapshot.lastErrorCode, .interrupted)
    }

    func testExhaustedRetryableFailedTerminatesWithoutWaitingForNotBefore() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, state, control_request,
                    priority, attempts, max_attempts, not_before_ms,
                    progress_completed, last_error_code, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 1, ?, 'retryableFailed', 'none', 0, 3, 3, ?, 0, 'interrupted', ?, ?)
                """,
                arguments: [
                    jobID.uuidString.lowercased(),
                    JobTestSupport.testKind,
                    JobTestSupport.testPayload,
                    JobTestSupport.baseTimeMs + 999_999,
                    JobTestSupport.baseTimeMs,
                    JobTestSupport.baseTimeMs,
                ]
            )
        }

        try queue.settleRetryableJobs()
        let snapshot = try queue.fetchJob(id: jobID)
        XCTAssertEqual(snapshot.state, .terminalFailed)
        XCTAssertEqual(snapshot.lastErrorCode, .attemptsExhausted)
    }

    func testRecoverInterruptedRunningJobsPaths() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)

        let cancelID = UUID()
        let pauseID = UUID()
        let retryID = UUID()
        let terminalID = UUID()

        try JobTestSupport.insertRunningJobForRecovery(database: database, id: cancelID, control: .cancel)
        try JobTestSupport.insertRunningJobForRecovery(database: database, id: pauseID, control: .pause)
        try JobTestSupport.insertRunningJobForRecovery(database: database, id: retryID, control: .none, attempts: 1, maxAttempts: 3)
        try JobTestSupport.insertRunningJobForRecovery(database: database, id: terminalID, control: .none, attempts: 3, maxAttempts: 3)

        try queue.recoverInterruptedRunningJobs()

        XCTAssertEqual(try queue.fetchJob(id: cancelID).state, .cancelled)
        XCTAssertEqual(try queue.fetchJob(id: pauseID).state, .paused)
        XCTAssertEqual(try queue.fetchJob(id: retryID).state, .retryableFailed)
        XCTAssertEqual(try queue.fetchJob(id: retryID).lastErrorCode, .interrupted)
        XCTAssertEqual(try queue.fetchJob(id: terminalID).state, .terminalFailed)
        XCTAssertEqual(try queue.fetchJob(id: terminalID).lastErrorCode, .interrupted)
    }

    func testRecoveryIsIdempotent() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        try JobTestSupport.insertRunningJobForRecovery(database: database, id: jobID, control: .pause)

        try queue.recoverInterruptedRunningJobs()
        let afterFirst = try database.pool.read { db in
            try JobTestSupport.fetchRowSnapshot(db, jobID: jobID)
        }

        try queue.recoverInterruptedRunningJobs()
        try assertRowUnchanged(database: database, jobID: jobID, baseline: try XCTUnwrap(afterFirst))
    }

    func testRecoveryPreservesExistingCheckpointAndProgress() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        let checkpoint = JobTestSupport.testCheckpoint
        let progress = JobProgress(completed: 4, total: 9)
        try JobTestSupport.insertRunningJobForRecovery(
            database: database,
            id: jobID,
            control: .pause,
            checkpoint: checkpoint,
            progress: progress
        )

        try queue.recoverInterruptedRunningJobs()

        let snapshot = try queue.fetchJob(id: jobID)
        XCTAssertEqual(snapshot.state, .paused)
        XCTAssertEqual(snapshot.checkpoint, checkpoint)
        XCTAssertEqual(snapshot.progress, progress)
    }

    func testRecoveryFailureRollsBackAllRunningRows() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)

        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        try JobTestSupport.insertRunningJobForRecovery(database: database, id: firstID, control: .none)
        try JobTestSupport.insertRunningJobForRecovery(database: database, id: secondID, control: .none)

        let baselines = try database.pool.read { db in
            (
                try JobTestSupport.fetchRowSnapshot(db, jobID: firstID),
                try JobTestSupport.fetchRowSnapshot(db, jobID: secondID)
            )
        }

        try database.pool.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER recovery_abort_second_update
                AFTER UPDATE ON job
                WHEN NEW.id = '\(secondID.uuidString.lowercased())'
                BEGIN
                    SELECT RAISE(ABORT, 'recovery fault injection');
                END
                """)
        }

        XCTAssertThrowsError(try queue.recoverInterruptedRunningJobs())

        try assertRowUnchanged(database: database, jobID: firstID, baseline: try XCTUnwrap(baselines.0))
        try assertRowUnchanged(database: database, jobID: secondID, baseline: try XCTUnwrap(baselines.1))
    }

    func testClaimClearsPreservedRetryError() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(
            database: database,
            nowMs: JobTestSupport.baseTimeMs,
            retryDelayMs: 0
        )
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
        try queue.settleRetryableJobs()

        _ = try JobTestSupport.claimDefault(queue: queue)
        let snapshot = try queue.fetchJob(id: jobID)
        XCTAssertNil(snapshot.lastErrorCode)
    }
}
