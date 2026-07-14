import XCTest
@testable import ImageAll

final class JobClaimTests: XCTestCase {
    func testClaimSelectsDuePendingInPriorityOrder() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)

        let lowPriority = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let highPriority = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let laterNotBefore = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

        _ = try JobTestSupport.enqueueDefault(
            queue: queue,
            id: lowPriority,
            priority: 1,
            notBeforeMs: JobTestSupport.baseTimeMs
        )
        _ = try JobTestSupport.enqueueDefault(
            queue: queue,
            id: highPriority,
            priority: 10,
            notBeforeMs: JobTestSupport.baseTimeMs
        )
        _ = try JobTestSupport.enqueueDefault(
            queue: queue,
            id: laterNotBefore,
            priority: 10,
            notBeforeMs: JobTestSupport.baseTimeMs + 100
        )

        let lease = try JobTestSupport.claimDefault(queue: queue)
        XCTAssertEqual(lease?.jobID, highPriority)
        XCTAssertEqual(lease?.attempts, 1)
        XCTAssertEqual(lease?.leaseOwner, "worker-1")
        XCTAssertEqual(lease?.leaseExpiresAtMs, JobTestSupport.baseTimeMs + JobTestSupport.leaseDurationMs)
    }

    func testClaimIncrementsAttemptsAndWritesLease() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()

        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID)
        let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))

        let snapshot = try queue.fetchJob(id: jobID)
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertEqual(snapshot.attempts, 1)
        XCTAssertEqual(snapshot.leaseOwner, lease.leaseOwner)
        XCTAssertEqual(snapshot.leaseExpiresAtMs, lease.leaseExpiresAtMs)
        XCTAssertNil(snapshot.lastErrorCode)
    }

    func testClaimSkipsNotBeforeFutureJobs() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)

        _ = try JobTestSupport.enqueueDefault(
            queue: queue,
            notBeforeMs: JobTestSupport.baseTimeMs + 10_000
        )

        XCTAssertNil(try JobTestSupport.claimDefault(queue: queue))
    }

    func testClaimSkipsWhenAttemptsEqualMaxAttempts() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()

        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID, maxAttempts: 2)
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE job SET attempts = 2, state = 'pending'
                WHERE id = ?
                """,
                arguments: [jobID.uuidString.lowercased()]
            )
        }

        XCTAssertNil(try JobTestSupport.claimDefault(queue: queue))
    }

    func testInvalidClaimInputRejected() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)

        XCTAssertThrowsError(
            try queue.claimNext(ClaimNextInput(owner: "", leaseDurationMs: 1000))
        ) { error in
            XCTAssertEqual(
                error as? JobQueueError,
                .invalidClaimInput(reason: "owner must be non-empty")
            )
        }

        XCTAssertThrowsError(
            try queue.claimNext(ClaimNextInput(owner: "worker", leaseDurationMs: 0))
        ) { error in
            XCTAssertEqual(
                error as? JobQueueError,
                .invalidClaimInput(reason: "leaseDurationMs must be > 0")
            )
        }
    }

    func testNoRunnableJobReturnsNilNotError() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)

        XCTAssertNil(try JobTestSupport.claimDefault(queue: queue))
    }
}
