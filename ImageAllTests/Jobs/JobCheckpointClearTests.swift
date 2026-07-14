import GRDB
import XCTest
@testable import ImageAll

final class JobCheckpointClearTests: XCTestCase {
    private func assertCheckpointColumnsNull(database: CatalogDatabase, jobID: UUID) throws {
        let columns = try database.pool.read { db -> (Int?, Data?) in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT checkpoint_version, checkpoint FROM job WHERE id = ?",
                arguments: [jobID.uuidString.lowercased()]
            )
            return (row?["checkpoint_version"], row?["checkpoint"])
        }
        XCTAssertNil(columns.0)
        XCTAssertNil(columns.1)
    }

    private func writeCheckpointThenClearViaBatch(
        queue: GRDBJobQueue,
        database: CatalogDatabase,
        jobID: UUID,
        leaveRunningSetup: (GRDBJobQueue, UUID, JobLeaseToken) throws -> Void,
        outcome: JobHandlerOutcome
    ) throws {
        let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))
        _ = try queue.submitSafeBatch(
            SafeBatchCommitInput(
                lease: lease,
                outcome: .continue,
                checkpoint: JobTestSupport.testCheckpoint,
                progress: JobProgress(completed: 2, total: 5)
            )
        )
        XCTAssertEqual(try queue.fetchJob(id: jobID).checkpoint, JobTestSupport.testCheckpoint)

        try leaveRunningSetup(queue, jobID, lease)

        let snapshot = try queue.submitSafeBatch(
            SafeBatchCommitInput(
                lease: lease,
                outcome: outcome,
                checkpoint: nil,
                progress: JobProgress(completed: 3, total: 5)
            )
        )
        XCTAssertNil(snapshot.checkpoint)
        try assertCheckpointColumnsNull(database: database, jobID: jobID)
    }

    func testCompletedLeavesRunningClearsCheckpointWhenInputNil() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID)

        try writeCheckpointThenClearViaBatch(
            queue: queue,
            database: database,
            jobID: jobID,
            leaveRunningSetup: { _, _, _ in },
            outcome: .completed
        )
        XCTAssertEqual(try queue.fetchJob(id: jobID).state, .completed)
    }

    func testPauseBoundaryClearsCheckpointWhenInputNil() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID)

        try writeCheckpointThenClearViaBatch(
            queue: queue,
            database: database,
            jobID: jobID,
            leaveRunningSetup: { queue, jobID, _ in
                _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .pause))
            },
            outcome: .continue
        )
        XCTAssertEqual(try queue.fetchJob(id: jobID).state, .paused)
    }

    func testCancelBoundaryClearsCheckpointWhenInputNil() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID)

        try writeCheckpointThenClearViaBatch(
            queue: queue,
            database: database,
            jobID: jobID,
            leaveRunningSetup: { queue, jobID, _ in
                _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .cancel))
            },
            outcome: .continue
        )
        XCTAssertEqual(try queue.fetchJob(id: jobID).state, .cancelled)
    }

    func testRetryableFailureLeavesRunningClearsCheckpointWhenInputNil() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID, maxAttempts: 3)

        try writeCheckpointThenClearViaBatch(
            queue: queue,
            database: database,
            jobID: jobID,
            leaveRunningSetup: { _, _, _ in },
            outcome: .retryableFailure(code: .interrupted)
        )
        XCTAssertEqual(try queue.fetchJob(id: jobID).state, .retryableFailed)
    }
}
