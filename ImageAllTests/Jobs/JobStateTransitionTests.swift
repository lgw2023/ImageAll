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
            (.retryableFailed, .resume(notBeforeMs: JobTestSupport.baseTimeMs), .transition(state: .pending, control: .none)),
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

    func testResumeRetryableJobRunsImmediatelyAndClearsTransientFailure() throws {
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = try JobTestSupport.prepareJobInState(
            queue: queue,
            database: database,
            state: .retryableFailed
        )
        let failed = try queue.fetchJob(id: jobID)
        XCTAssertEqual(failed.lastErrorCode, .interrupted)
        XCTAssertEqual(failed.notBeforeMs, JobTestSupport.baseTimeMs + JobTestSupport.retryDelayMs)

        let resumed = try queue.applyStateCommand(
            JobStateCommand(
                jobID: jobID,
                operation: .resume(notBeforeMs: JobTestSupport.baseTimeMs)
            )
        )

        XCTAssertEqual(resumed.state, .pending)
        XCTAssertEqual(resumed.controlRequest, .none)
        XCTAssertEqual(resumed.notBeforeMs, JobTestSupport.baseTimeMs)
        XCTAssertNil(resumed.lastErrorCode)
        XCTAssertNil(resumed.leaseOwner)
        XCTAssertNil(resumed.leaseExpiresAtMs)
        XCTAssertEqual(try JobTestSupport.claimDefault(queue: queue)?.jobID, jobID)
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

    func testActivityProjectionUsesSafeKindsActiveFirstOrderingAndProgress() throws {
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        let queue = JobTestSupport.makeQueue(database: database)
        let folderID = UUID()
        let photosID = UUID()
        let suggestionsID = UUID()
        let unknownID = UUID()

        _ = try JobTestSupport.enqueueDefault(
            queue: queue,
            id: folderID,
            kind: "folder.reconcile.v1"
        )
        _ = try queue.applyStateCommand(JobStateCommand(jobID: folderID, operation: .pause))
        _ = try JobTestSupport.enqueueDefault(
            queue: queue,
            id: photosID,
            kind: "photos.reconcile.v1"
        )
        _ = try JobTestSupport.enqueueDefault(
            queue: queue,
            id: suggestionsID,
            kind: "personalization.fullLibrarySuggestions"
        )
        _ = try XCTUnwrap(
            try queue.claimNext(
                ClaimNextInput(
                    owner: "activity-worker",
                    leaseDurationMs: JobTestSupport.leaseDurationMs,
                    allowedKinds: ["personalization.fullLibrarySuggestions"]
                )
            )
        )
        _ = try queue.applyStateCommand(JobStateCommand(jobID: suggestionsID, operation: .pause))
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: unknownID, kind: "secret.internal.kind")
        let unknownLease = try XCTUnwrap(
            try queue.claimNext(
                ClaimNextInput(
                    owner: "terminal-worker",
                    leaseDurationMs: JobTestSupport.leaseDurationMs,
                    allowedKinds: ["secret.internal.kind"]
                )
            )
        )
        _ = try queue.submitSafeBatch(
            SafeBatchCommitInput(
                lease: unknownLease,
                outcome: .completed,
                checkpoint: nil,
                progress: JobProgress(completed: 1, total: 1)
            )
        )

        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE job SET updated_at_ms = ?, progress_completed = ?, progress_total = ? WHERE id = ?",
                arguments: [100, 2, 8, folderID.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE job SET updated_at_ms = ?, progress_completed = ?, progress_total = NULL WHERE id = ?",
                arguments: [300, 4, photosID.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE job SET updated_at_ms = ?, progress_completed = ?, progress_total = ? WHERE id = ?",
                arguments: [200, 6, 10, suggestionsID.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE job SET updated_at_ms = ? WHERE id = ?",
                arguments: [1_000, unknownID.uuidString.lowercased()]
            )
        }

        let items = try queue.fetchActivityItems()

        XCTAssertEqual(items.map(\.id), [photosID, suggestionsID, folderID, unknownID])
        XCTAssertEqual(items.map(\.kind), [.photosReconcile, .personalizationSuggestions, .folderReconcile, .background])
        XCTAssertEqual(items[0].progress, JobProgress(completed: 4, total: nil))
        XCTAssertEqual(items[1].progress, JobProgress(completed: 6, total: 10))
        XCTAssertEqual(items[1].controlRequest, .pause)
    }

    func testPersonalLibrarySuggestionActivityUsesPersonalizationPresentation() throws {
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()

        _ = try JobTestSupport.enqueueDefault(
            queue: queue,
            id: jobID,
            kind: PersonalLibrarySuggestionsJobFactory.kind
        )

        let item = try XCTUnwrap(queue.fetchActivityItems().first { $0.id == jobID })
        XCTAssertEqual(item.kind, .personalizationSuggestions)
    }

    func testActivityProjectionLimitsResultsToOneHundredNewestActiveJobs() throws {
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        let queue = JobTestSupport.makeQueue(database: database)
        var jobs: [(id: UUID, updatedAtMs: Int64)] = []
        for offset in 0 ..< 105 {
            let id = UUID()
            let updatedAtMs = Int64(offset)
            _ = try JobTestSupport.enqueueDefault(queue: queue, id: id, kind: "test.\(offset)")
            jobs.append((id, updatedAtMs))
            try database.pool.write { db in
                try db.execute(
                    sql: "UPDATE job SET updated_at_ms = ? WHERE id = ?",
                    arguments: [updatedAtMs, id.uuidString.lowercased()]
                )
            }
        }

        let items = try queue.fetchActivityItems()

        XCTAssertEqual(items.count, 100)
        XCTAssertEqual(items.first?.id, jobs.last?.id)
        XCTAssertFalse(items.contains { $0.id == jobs.first?.id })
        XCTAssertTrue(items.allSatisfy { $0.kind == .background })
    }

    func testActivityActionMatrixHonorsRunningControlPrecedence() {
        let matrix: [(JobState, JobControlRequest, [JobActivityAction])] = [
            (.pending, .none, [.pause, .cancel]),
            (.running, .none, [.pause, .cancel]),
            (.running, .pause, [.cancel]),
            (.running, .cancel, []),
            (.paused, .none, [.resume, .cancel]),
            (.retryableFailed, .none, [.resume, .cancel]),
            (.completed, .none, []),
            (.terminalFailed, .none, []),
            (.cancelled, .none, []),
        ]

        for (state, controlRequest, expected) in matrix {
            let item = JobActivityItem(
                id: UUID(),
                kind: .background,
                state: state,
                controlRequest: controlRequest,
                progress: JobProgress(completed: 0, total: nil)
            )
            XCTAssertEqual(item.availableActions, expected)
        }
    }
}
