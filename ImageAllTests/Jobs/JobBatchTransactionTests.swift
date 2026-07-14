import GRDB
import XCTest
@testable import ImageAll

final class JobBatchTransactionTests: XCTestCase {
    func testSimulatedBusinessWriteCheckpointAndProgressCommitTogether() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let sourceID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, sourceID: sourceID)

        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID, sourceID: sourceID)
        let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))

        let snapshot = try queue.commitSimulatedBusinessBatch(
            SimulatedBusinessWriteInput(
                lease: lease,
                sourceID: sourceID,
                dirtyEpochDelta: 2,
                outcome: .continue,
                checkpoint: JobTestSupport.testCheckpoint,
                progress: JobProgress(completed: 3, total: 10)
            )
        )

        XCTAssertEqual(snapshot.state, .running)
        XCTAssertEqual(snapshot.checkpoint, JobTestSupport.testCheckpoint)
        XCTAssertEqual(snapshot.progress.completed, 3)

        let dirtyEpoch = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT dirty_epoch FROM source WHERE id = ?", arguments: [sourceID.uuidString.lowercased()])
        }
        XCTAssertEqual(dirtyEpoch, 2)
    }

    func testBusinessWriteFailureRollsBackJobAndSource() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let sourceID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, sourceID: sourceID)

        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID, sourceID: sourceID)
        let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))

        let jobBaseline = try database.pool.read { db in
            try JobTestSupport.fetchRowSnapshot(db, jobID: jobID)
        }
        let sourceBaseline = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT dirty_epoch FROM source WHERE id = ?", arguments: [sourceID.uuidString.lowercased()])
        }

        struct InjectedFailure: Error {}

        XCTAssertThrowsError(
            try queue.commitSimulatedBusinessBatchWithFaultInjection(
                SimulatedBusinessWriteInput(
                    lease: lease,
                    sourceID: sourceID,
                    dirtyEpochDelta: 5,
                    outcome: .continue,
                    checkpoint: JobTestSupport.testCheckpoint,
                    progress: JobProgress(completed: 1, total: 2)
                ),
                afterSourceUpdate: { throw InjectedFailure() }
            )
        )

        try assertRowUnchanged(database: database, jobID: jobID, baseline: try XCTUnwrap(jobBaseline))
        let dirtyEpoch = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT dirty_epoch FROM source WHERE id = ?", arguments: [sourceID.uuidString.lowercased()])
        }
        XCTAssertEqual(dirtyEpoch, sourceBaseline)
    }

    func testInvalidJobProgressRollsBackSourceWrite() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let sourceID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, sourceID: sourceID)

        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID, sourceID: sourceID)
        let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))

        let sourceBaseline = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT dirty_epoch FROM source WHERE id = ?", arguments: [sourceID.uuidString.lowercased()])
        }

        XCTAssertThrowsError(
            try queue.submitSafeBatchWithForcedInvalidProgress(
                SafeBatchCommitInput(
                    lease: lease,
                    outcome: .continue,
                    checkpoint: JobTestSupport.testCheckpoint,
                    progress: JobProgress(completed: 1, total: 2)
                ),
                forcedProgressCompleted: 10,
                forcedProgressTotal: 5
            )
        )

        let dirtyEpoch = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT dirty_epoch FROM source WHERE id = ?", arguments: [sourceID.uuidString.lowercased()])
        }
        XCTAssertEqual(dirtyEpoch, sourceBaseline)

        let snapshot = try queue.fetchJob(id: jobID)
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertNil(snapshot.checkpoint)
    }

    func testStaleLeaseDoesNotExecuteBusinessBatch() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let sourceID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, sourceID: sourceID)

        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID, sourceID: sourceID)
        let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))
        let staleLease = JobLeaseToken(
            jobID: lease.jobID,
            leaseOwner: "other-owner",
            attempts: lease.attempts,
            leaseExpiresAtMs: lease.leaseExpiresAtMs,
            kind: lease.kind,
            payloadVersion: lease.payloadVersion,
            payload: lease.payload,
            checkpoint: lease.checkpoint
        )

        XCTAssertThrowsError(
            try queue.commitSimulatedBusinessBatch(
                SimulatedBusinessWriteInput(
                    lease: staleLease,
                    sourceID: sourceID,
                    dirtyEpochDelta: 1,
                    outcome: .continue,
                    checkpoint: JobTestSupport.testCheckpoint,
                    progress: JobProgress(completed: 1, total: 2)
                )
            )
        ) { error in
            XCTAssertEqual(error as? JobQueueError, .staleLease(jobID))
        }

        let dirtyEpoch = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT dirty_epoch FROM source WHERE id = ?", arguments: [sourceID.uuidString.lowercased()])
        }
        XCTAssertEqual(dirtyEpoch, 0)
    }
}
