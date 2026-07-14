import GRDB
import XCTest
@testable import ImageAll

final class JobStateTransitionTests: XCTestCase {
    private enum CommandExpectation {
        case transition(state: JobState, control: JobControlRequest)
        case idempotentNoOp
        case invalid(String)
    }

    func testStateCommandMatrix() throws {
        let matrix: [(state: JobState, operation: JobStateCommand.Operation, expected: CommandExpectation)] = [
            (.pending, .pause, .transition(state: .paused, control: .none)),
            (.pending, .cancel, .transition(state: .cancelled, control: .none)),
            (.pending, .resume(notBeforeMs: JobTestSupport.baseTimeMs), .invalid("resume")),
            (.running, .pause, .transition(state: .running, control: .pause)),
            (.running, .cancel, .transition(state: .running, control: .cancel)),
            (.running, .resume(notBeforeMs: JobTestSupport.baseTimeMs), .invalid("resume")),
            (.paused, .pause, .invalid("pause")),
            (.paused, .cancel, .transition(state: .cancelled, control: .none)),
            (.paused, .resume(notBeforeMs: JobTestSupport.baseTimeMs), .transition(state: .pending, control: .none)),
            (.retryableFailed, .pause, .invalid("pause")),
            (.retryableFailed, .cancel, .transition(state: .cancelled, control: .none)),
            (.retryableFailed, .resume(notBeforeMs: JobTestSupport.baseTimeMs), .invalid("resume")),
            (.completed, .pause, .invalid("pause")),
            (.completed, .cancel, .invalid("cancel")),
            (.completed, .resume(notBeforeMs: JobTestSupport.baseTimeMs), .invalid("resume")),
            (.terminalFailed, .pause, .invalid("pause")),
            (.terminalFailed, .cancel, .invalid("cancel")),
            (.terminalFailed, .resume(notBeforeMs: JobTestSupport.baseTimeMs), .invalid("resume")),
            (.cancelled, .pause, .invalid("pause")),
            (.cancelled, .cancel, .invalid("cancel")),
            (.cancelled, .resume(notBeforeMs: JobTestSupport.baseTimeMs), .invalid("resume")),
        ]

        for entry in matrix {
            let url = try makeTempDatabaseURL()
            let database = try CatalogDatabase.open(at: url)
            let queue = JobTestSupport.makeQueue(database: database)
            let jobID = try JobTestSupport.prepareJobInState(queue: queue, database: database, state: entry.state)

            let baseline = try database.pool.read { db in
                try JobTestSupport.fetchRowSnapshot(db, jobID: jobID)
            }

            do {
                _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: entry.operation))
                switch entry.expected {
                case let .transition(state, control):
                    let snapshot = try queue.fetchJob(id: jobID)
                    XCTAssertEqual(snapshot.state, state, "state=\(entry.state) op=\(entry.operation)")
                    XCTAssertEqual(snapshot.controlRequest, control, "state=\(entry.state) op=\(entry.operation)")
                case .idempotentNoOp:
                    try assertRowUnchanged(database: database, jobID: jobID, baseline: try XCTUnwrap(baseline))
                case let .invalid(operation):
                    XCTFail("Expected invalid transition for \(entry.state)/\(operation)")
                }
            } catch let error as JobQueueError {
                switch entry.expected {
                case let .invalid(operation):
                    XCTAssertEqual(
                        error,
                        .invalidTransition(currentState: entry.state, operation: operation),
                        "state=\(entry.state) op=\(entry.operation)"
                    )
                    try assertRowUnchanged(database: database, jobID: jobID, baseline: try XCTUnwrap(baseline))
                default:
                    XCTFail("Unexpected error \(error) for \(entry.state)/\(entry.operation)")
                }
            }
        }
    }

    func testRunningControlRequestsAreIdempotentNoOps() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID)
        _ = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))

        _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .pause))
        let afterPause = try database.pool.read { db in
            try JobTestSupport.fetchRowSnapshot(db, jobID: jobID)
        }
        _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .pause))
        try assertRowUnchanged(database: database, jobID: jobID, baseline: try XCTUnwrap(afterPause))

        _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .cancel))
        let afterCancel = try database.pool.read { db in
            try JobTestSupport.fetchRowSnapshot(db, jobID: jobID)
        }
        _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .cancel))
        try assertRowUnchanged(database: database, jobID: jobID, baseline: try XCTUnwrap(afterCancel))

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

    func testTerminalStatesRejectClaimAndMutations() throws {
        for terminalState in [JobState.completed, JobState.terminalFailed, JobState.cancelled] {
            let url = try makeTempDatabaseURL()
            let database = try CatalogDatabase.open(at: url)
            let queue = JobTestSupport.makeQueue(database: database)
            let jobID = try JobTestSupport.prepareJobInState(queue: queue, database: database, state: terminalState)

            let baseline = try database.pool.read { db in
                try JobTestSupport.fetchRowSnapshot(db, jobID: jobID)
            }

            XCTAssertNil(try JobTestSupport.claimDefault(queue: queue))

            let staleLease = JobLeaseToken(
                jobID: jobID,
                leaseOwner: "stale-owner",
                attempts: 1,
                leaseExpiresAtMs: JobTestSupport.baseTimeMs + JobTestSupport.leaseDurationMs,
                kind: JobTestSupport.testKind,
                payloadVersion: 1,
                payload: JobTestSupport.testPayload,
                checkpoint: JobTestSupport.testCheckpoint
            )

            for outcome in [
                JobHandlerOutcome.completed,
                .retryableFailure(code: .interrupted),
                .nonRetryableFailure(code: .interrupted),
            ] {
                XCTAssertThrowsError(
                    try queue.submitSafeBatch(
                        SafeBatchCommitInput(
                            lease: staleLease,
                            outcome: outcome,
                            checkpoint: JobTestSupport.testCheckpoint,
                            progress: JobProgress(completed: 1, total: 1)
                        )
                    )
                )
                try assertRowUnchanged(database: database, jobID: jobID, baseline: try XCTUnwrap(baseline))
            }

            for operation in [
                JobStateCommand.Operation.pause,
                .cancel,
                .resume(notBeforeMs: JobTestSupport.baseTimeMs),
            ] {
                XCTAssertThrowsError(
                    try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: operation))
                )
                try assertRowUnchanged(database: database, jobID: jobID, baseline: try XCTUnwrap(baseline))
            }
        }
    }
}
