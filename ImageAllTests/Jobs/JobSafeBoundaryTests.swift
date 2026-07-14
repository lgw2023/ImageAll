import GRDB
import XCTest
@testable import ImageAll

final class JobSafeBoundaryTests: XCTestCase {
    func testSafeBoundaryDecisionTable() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        let cases: [(control: JobControlRequest, outcome: JobHandlerOutcome, expectedState: JobState, expectedError: JobSafeErrorCode?)] = [
            (.cancel, .continue, .cancelled, nil),
            (.cancel, .completed, .cancelled, nil),
            (.cancel, .retryableFailure(code: .interrupted), .cancelled, nil),
            (.cancel, .nonRetryableFailure(code: .unknownJobKind), .cancelled, nil),
            (.pause, .continue, .paused, nil),
            (.pause, .completed, .paused, nil),
            (.pause, .retryableFailure(code: .interrupted), .paused, nil),
            (.pause, .nonRetryableFailure(code: .unknownJobKind), .paused, nil),
            (.none, .continue, .running, nil),
            (.none, .completed, .completed, nil),
        ]

        for testCase in cases {
            let queue = JobTestSupport.makeQueue(database: database)
            let jobID = UUID()
            _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID, maxAttempts: 3)
            let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue, owner: "worker-\(testCase.expectedState.rawValue)"))

            if testCase.control != .none {
                switch testCase.control {
                case .pause:
                    _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .pause))
                case .cancel:
                    _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .cancel))
                case .none:
                    break
                }
            }

            let snapshot = try queue.submitSafeBatch(
                SafeBatchCommitInput(
                    lease: lease,
                    outcome: testCase.outcome,
                    checkpoint: JobTestSupport.testCheckpoint,
                    progress: JobProgress(completed: 2, total: 5)
                )
            )

            XCTAssertEqual(snapshot.state, testCase.expectedState, "control=\(testCase.control) outcome=\(testCase.outcome)")
            XCTAssertEqual(snapshot.controlRequest, .none)
            if testCase.expectedState == .running {
                XCTAssertNotNil(snapshot.leaseOwner)
            } else {
                XCTAssertNil(snapshot.leaseOwner)
            }
            if testCase.expectedError == nil {
                XCTAssertNil(snapshot.lastErrorCode)
            }

            try database.pool.write { db in
                try db.execute(sql: "DELETE FROM job")
            }
        }
    }

    func testRetryableFailureUsesRetryPolicyWhenAttemptsRemain() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID, maxAttempts: 3)
        let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))

        let snapshot = try queue.submitSafeBatch(
            SafeBatchCommitInput(
                lease: lease,
                outcome: .retryableFailure(code: .interrupted),
                checkpoint: nil,
                progress: JobProgress(completed: 0, total: nil)
            )
        )

        XCTAssertEqual(snapshot.state, .retryableFailed)
        XCTAssertEqual(snapshot.lastErrorCode, .interrupted)
        XCTAssertEqual(snapshot.notBeforeMs, JobTestSupport.baseTimeMs + JobTestSupport.retryDelayMs)
        XCTAssertNil(snapshot.leaseOwner)
    }

    func testRetryableFailureBecomesTerminalWhenAttemptsExhausted() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID, maxAttempts: 1)
        let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))

        let snapshot = try queue.submitSafeBatch(
            SafeBatchCommitInput(
                lease: lease,
                outcome: .retryableFailure(code: .interrupted),
                checkpoint: nil,
                progress: JobProgress(completed: 0, total: nil)
            )
        )

        XCTAssertEqual(snapshot.state, .terminalFailed)
        XCTAssertEqual(snapshot.lastErrorCode, .interrupted)
    }

    func testStaleLeaseRejected() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID)
        let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))

        let staleLease = JobLeaseToken(
            jobID: lease.jobID,
            leaseOwner: lease.leaseOwner,
            attempts: lease.attempts - 1,
            leaseExpiresAtMs: lease.leaseExpiresAtMs,
            kind: lease.kind,
            payloadVersion: lease.payloadVersion,
            payload: lease.payload,
            checkpoint: lease.checkpoint
        )

        let baseline = try database.pool.read { db in
            try JobTestSupport.fetchRowSnapshot(db, jobID: jobID)
        }

        XCTAssertThrowsError(
            try queue.submitSafeBatch(
                SafeBatchCommitInput(
                    lease: staleLease,
                    outcome: .completed,
                    checkpoint: nil,
                    progress: JobProgress(completed: 1, total: 1)
                )
            )
        ) { error in
            XCTAssertEqual(error as? JobQueueError, .staleLease(jobID))
        }
        try assertRowUnchanged(database: database, jobID: jobID, baseline: try XCTUnwrap(baseline))
    }
}
