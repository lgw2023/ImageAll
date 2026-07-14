import GRDB
import XCTest
@testable import ImageAll

final class JobBatchTransactionTests: XCTestCase {
    func testSourceDirtyEpochBatchCommitsCheckpointAndProgressTogether() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let sourceID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, sourceID: sourceID)

        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID, sourceID: sourceID)
        let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))

        let snapshot = try queue.commitLeaseProtectedBatch(
            input: SafeBatchCommitInput(
                lease: lease,
                outcome: .continue,
                checkpoint: JobTestSupport.testCheckpoint,
                progress: JobProgress(completed: 3, total: 10)
            )
        ) { db in
            try JobTestSupport.incrementSourceDirtyEpoch(db, sourceID: sourceID, delta: 2)
        }

        XCTAssertEqual(snapshot.state, .running)
        XCTAssertEqual(snapshot.checkpoint, JobTestSupport.testCheckpoint)
        XCTAssertEqual(snapshot.progress.completed, 3)

        let dirtyEpoch = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT dirty_epoch FROM source WHERE id = ?", arguments: [sourceID.uuidString.lowercased()])
        }
        XCTAssertEqual(dirtyEpoch, 2)
    }

    func testBusinessClosureFailureRollsBackJobAndSource() throws {
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
            try JobTestSupport.fetchSourceRowSnapshot(db, sourceID: sourceID)
        }

        struct InjectedFailure: Error {}

        XCTAssertThrowsError(
            try queue.commitLeaseProtectedBatch(
                input: SafeBatchCommitInput(
                    lease: lease,
                    outcome: .continue,
                    checkpoint: JobTestSupport.testCheckpoint,
                    progress: JobProgress(completed: 1, total: 2)
                )
            ) { db in
                try JobTestSupport.incrementSourceDirtyEpoch(db, sourceID: sourceID, delta: 5)
                throw InjectedFailure()
            }
        )

        try assertRowUnchanged(database: database, jobID: jobID, baseline: try XCTUnwrap(jobBaseline))
        try assertSourceRowUnchanged(database: database, sourceID: sourceID, baseline: try XCTUnwrap(sourceBaseline))
    }

    func testInvalidJobProgressAfterSourceUpdateRollsBackBoth() throws {
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
            try JobTestSupport.fetchSourceRowSnapshot(db, sourceID: sourceID)
        }

        XCTAssertThrowsError(
            try queue.runLeaseProtectedTransaction(lease: lease) { db in
                try JobTestSupport.incrementSourceDirtyEpoch(db, sourceID: sourceID, delta: 3)
                try db.execute(
                    sql: """
                    UPDATE job SET progress_completed = 10, progress_total = 5, updated_at_ms = ?
                    WHERE id = ? AND state = 'running'
                    """,
                    arguments: [JobTestSupport.baseTimeMs, jobID.uuidString.lowercased()]
                )
            }
        )

        try assertRowUnchanged(database: database, jobID: jobID, baseline: try XCTUnwrap(jobBaseline))
        try assertSourceRowUnchanged(database: database, sourceID: sourceID, baseline: try XCTUnwrap(sourceBaseline))
    }

    func testProgressRegressionRejectedBeforeBusinessClosureRuns() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let sourceID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, sourceID: sourceID)

        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID, sourceID: sourceID)
        let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))

        _ = try queue.commitLeaseProtectedBatch(
            input: SafeBatchCommitInput(
                lease: lease,
                outcome: .continue,
                checkpoint: JobTestSupport.testCheckpoint,
                progress: JobProgress(completed: 5, total: 10)
            )
        ) { db in
            try JobTestSupport.incrementSourceDirtyEpoch(db, sourceID: sourceID, delta: 1)
        }

        let jobBaseline = try database.pool.read { db in
            try JobTestSupport.fetchRowSnapshot(db, jobID: jobID)
        }
        let sourceBaseline = try database.pool.read { db in
            try JobTestSupport.fetchSourceRowSnapshot(db, sourceID: sourceID)
        }
        let workTracker = JobTestSupport.BusinessWorkTracker()

        XCTAssertThrowsError(
            try queue.commitLeaseProtectedBatch(
                input: SafeBatchCommitInput(
                    lease: lease,
                    outcome: .continue,
                    checkpoint: JobTestSupport.testCheckpoint,
                    progress: JobProgress(completed: 3, total: 10)
                )
            ) { _ in
                workTracker.markExecuted()
            }
        ) { error in
            XCTAssertEqual(
                error as? JobQueueError,
                .invalidProgress(reason: "progress_completed must not regress")
            )
        }

        XCTAssertFalse(workTracker.executed)
        try assertRowUnchanged(database: database, jobID: jobID, baseline: try XCTUnwrap(jobBaseline))
        try assertSourceRowUnchanged(database: database, sourceID: sourceID, baseline: try XCTUnwrap(sourceBaseline))
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
            try queue.commitLeaseProtectedBatch(
                input: SafeBatchCommitInput(
                    lease: staleLease,
                    outcome: .continue,
                    checkpoint: JobTestSupport.testCheckpoint,
                    progress: JobProgress(completed: 1, total: 2)
                )
            ) { db in
                try JobTestSupport.incrementSourceDirtyEpoch(db, sourceID: sourceID, delta: 1)
            }
        ) { error in
            XCTAssertEqual(error as? JobQueueError, .staleLease(jobID))
        }

        let dirtyEpoch = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT dirty_epoch FROM source WHERE id = ?", arguments: [sourceID.uuidString.lowercased()])
        }
        XCTAssertEqual(dirtyEpoch, 0)
    }
}
