import XCTest
@testable import ImageAll

final class JobSafeBoundaryTests: XCTestCase {
    private struct SafeBoundaryCase {
        let control: JobControlRequest
        let outcome: JobHandlerOutcome
        let maxAttempts: Int
        let expectedState: JobState
        let expectedError: JobSafeErrorCode?
        let keepsLease: Bool
    }

    func testSafeBoundaryFullDecisionMatrix() throws {
        let customCode = try JobSafeErrorCode("scanTimeout")
        let cases: [SafeBoundaryCase] = [
            SafeBoundaryCase(control: .cancel, outcome: .continue, maxAttempts: 3, expectedState: .cancelled, expectedError: nil, keepsLease: false),
            SafeBoundaryCase(control: .cancel, outcome: .completed, maxAttempts: 3, expectedState: .cancelled, expectedError: nil, keepsLease: false),
            SafeBoundaryCase(control: .cancel, outcome: .retryableFailure(code: .interrupted), maxAttempts: 3, expectedState: .cancelled, expectedError: nil, keepsLease: false),
            SafeBoundaryCase(control: .cancel, outcome: .nonRetryableFailure(code: .unknownJobKind), maxAttempts: 3, expectedState: .cancelled, expectedError: nil, keepsLease: false),
            SafeBoundaryCase(control: .pause, outcome: .continue, maxAttempts: 3, expectedState: .paused, expectedError: nil, keepsLease: false),
            SafeBoundaryCase(control: .pause, outcome: .completed, maxAttempts: 3, expectedState: .paused, expectedError: nil, keepsLease: false),
            SafeBoundaryCase(control: .pause, outcome: .retryableFailure(code: .interrupted), maxAttempts: 3, expectedState: .paused, expectedError: nil, keepsLease: false),
            SafeBoundaryCase(control: .pause, outcome: .nonRetryableFailure(code: .unknownJobKind), maxAttempts: 3, expectedState: .paused, expectedError: nil, keepsLease: false),
            SafeBoundaryCase(control: .none, outcome: .continue, maxAttempts: 3, expectedState: .running, expectedError: nil, keepsLease: true),
            SafeBoundaryCase(control: .none, outcome: .completed, maxAttempts: 3, expectedState: .completed, expectedError: nil, keepsLease: false),
            SafeBoundaryCase(control: .none, outcome: .retryableFailure(code: customCode), maxAttempts: 3, expectedState: .retryableFailed, expectedError: customCode, keepsLease: false),
            SafeBoundaryCase(control: .none, outcome: .nonRetryableFailure(code: customCode), maxAttempts: 3, expectedState: .terminalFailed, expectedError: customCode, keepsLease: false),
            SafeBoundaryCase(control: .none, outcome: .retryableFailure(code: .interrupted), maxAttempts: 1, expectedState: .terminalFailed, expectedError: .interrupted, keepsLease: false),
        ]

        for testCase in cases {
            let url = try makeTempDatabaseURL()
            let database = try CatalogDatabase.open(at: url)
            let queue = JobTestSupport.makeQueue(database: database)
            let jobID = UUID()
            _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID, maxAttempts: testCase.maxAttempts)
            let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))

            if testCase.control == .pause {
                _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .pause))
            } else if testCase.control == .cancel {
                _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .cancel))
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
            XCTAssertEqual(snapshot.lastErrorCode, testCase.expectedError)
            if testCase.keepsLease {
                XCTAssertNotNil(snapshot.leaseOwner)
            } else {
                XCTAssertNil(snapshot.leaseOwner)
            }
            if testCase.expectedState == .retryableFailed {
                XCTAssertEqual(snapshot.notBeforeMs, JobTestSupport.baseTimeMs + JobTestSupport.retryDelayMs)
            }
        }
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
