import GRDB
import XCTest
@testable import ImageAll

final class JobModelsTests: XCTestCase {
    func testJobStateRawValuesMatchV001() {
        XCTAssertEqual(JobState.pending.rawValue, "pending")
        XCTAssertEqual(JobState.running.rawValue, "running")
        XCTAssertEqual(JobState.paused.rawValue, "paused")
        XCTAssertEqual(JobState.retryableFailed.rawValue, "retryableFailed")
        XCTAssertEqual(JobState.completed.rawValue, "completed")
        XCTAssertEqual(JobState.terminalFailed.rawValue, "terminalFailed")
        XCTAssertEqual(JobState.cancelled.rawValue, "cancelled")
    }

    func testControlRequestRawValuesMatchV001() {
        XCTAssertEqual(JobControlRequest.none.rawValue, "none")
        XCTAssertEqual(JobControlRequest.pause.rawValue, "pause")
        XCTAssertEqual(JobControlRequest.cancel.rawValue, "cancel")
    }

    func testControlRequestMonotonicUpgrade() {
        XCTAssertEqual(
            JobPersistenceMapping.upgradedControl(current: .none, requested: .pause),
            .pause
        )
        XCTAssertEqual(
            JobPersistenceMapping.upgradedControl(current: .pause, requested: .cancel),
            .cancel
        )
        XCTAssertEqual(
            JobPersistenceMapping.upgradedControl(current: .cancel, requested: .pause),
            .cancel
        )
        XCTAssertEqual(
            JobPersistenceMapping.upgradedControl(current: .pause, requested: .pause),
            .pause
        )
    }

    func testUnknownPersistedStateFromDatabaseIsStructuredError() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID)

        try database.pool.write { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try db.execute(
                sql: "UPDATE job SET state = 'bogus' WHERE id = ?",
                arguments: [jobID.uuidString.lowercased()]
            )
        }

        XCTAssertThrowsError(try queue.fetchJob(id: jobID)) { error in
            XCTAssertEqual(
                error as? JobQueueError,
                .unknownPersistedRawValue(field: "state", value: "bogus")
            )
        }
    }

    func testUnknownPersistedControlFromDatabaseIsStructuredError() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID)
        _ = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))

        try database.pool.write { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try db.execute(
                sql: "UPDATE job SET control_request = 'bogus' WHERE id = ?",
                arguments: [jobID.uuidString.lowercased()]
            )
        }

        XCTAssertThrowsError(try queue.fetchJob(id: jobID)) { error in
            XCTAssertEqual(
                error as? JobQueueError,
                .unknownPersistedRawValue(field: "control_request", value: "bogus")
            )
        }
    }

    func testCustomHandlerErrorCodeRoundTripsThroughDatabase() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let customCode = try JobSafeErrorCode("scanTimeout")
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID)
        let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))

        _ = try queue.submitSafeBatch(
            SafeBatchCommitInput(
                lease: lease,
                outcome: .retryableFailure(code: customCode),
                checkpoint: nil,
                progress: JobProgress(completed: 0, total: nil)
            )
        )

        let snapshot = try queue.fetchJob(id: jobID)
        XCTAssertEqual(snapshot.lastErrorCode, customCode)
    }

    func testEmptySafeErrorCodeRejected() {
        XCTAssertThrowsError(try JobSafeErrorCode("")) { error in
            XCTAssertEqual(error as? JobQueueError, .invalidSafeErrorCode(rawValue: ""))
        }
    }

    func testInvalidSafeErrorCodePatternsRejected() {
        let invalidCodes = ["1bad", "bad-code", String(repeating: "a", count: 65)]
        for code in invalidCodes {
            XCTAssertThrowsError(try JobSafeErrorCode(code)) { error in
                XCTAssertEqual(error as? JobQueueError, .invalidSafeErrorCode(rawValue: code))
            }
        }
    }

    func testPersistedSafeErrorCodeUsesSameValidation() {
        XCTAssertThrowsError(try JobSafeErrorCode(persisted: "")) { error in
            XCTAssertEqual(
                error as? JobQueueError,
                .unknownPersistedRawValue(field: "last_error_code", value: "")
            )
        }
        XCTAssertThrowsError(try JobSafeErrorCode(persisted: "bad-code")) { error in
            XCTAssertEqual(
                error as? JobQueueError,
                .unknownPersistedRawValue(field: "last_error_code", value: "bad-code")
            )
        }
    }

    func testUnknownPersistedSafeErrorCodeFromDatabaseIsStructuredError() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID)
        let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))

        _ = try queue.submitSafeBatch(
            SafeBatchCommitInput(
                lease: lease,
                outcome: .retryableFailure(code: .interrupted),
                checkpoint: nil,
                progress: JobProgress(completed: 0, total: nil)
            )
        )

        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE job SET last_error_code = 'bad-code' WHERE id = ?",
                arguments: [jobID.uuidString.lowercased()]
            )
        }

        XCTAssertThrowsError(try queue.fetchJob(id: jobID)) { error in
            XCTAssertEqual(
                error as? JobQueueError,
                .unknownPersistedRawValue(field: "last_error_code", value: "bad-code")
            )
        }
    }

    func testInvalidProgressRejectedBeforePersistence() {
        XCTAssertThrowsError(
            try JobPersistenceMapping.validateProgress(JobProgress(completed: 5, total: 3))
        ) { error in
            XCTAssertEqual(
                error as? JobQueueError,
                .invalidProgress(reason: "total must be >= completed")
            )
        }
    }
}
