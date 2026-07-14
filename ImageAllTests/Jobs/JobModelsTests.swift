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

    func testUnknownPersistedRawValueIsStructuredError() {
        XCTAssertThrowsError(try JobPersistenceMapping.jobState(from: "bogus")) { error in
            XCTAssertEqual(
                error as? JobQueueError,
                .unknownPersistedRawValue(field: "state", value: "bogus")
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
