import XCTest
@testable import ImageAll

final class JobEnqueueTests: XCTestCase {
    func testEnqueuePersistsDefaultsAndPayload() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        let payload = Data([0x01, 0x02, 0x03])

        let snapshot = try JobTestSupport.enqueueDefault(
            queue: queue,
            id: jobID,
            payload: payload,
            priority: 2,
            maxAttempts: 5,
            notBeforeMs: JobTestSupport.baseTimeMs + 100
        )

        XCTAssertEqual(snapshot.id, jobID)
        XCTAssertEqual(snapshot.kind, JobTestSupport.testKind)
        XCTAssertEqual(snapshot.payload, payload)
        XCTAssertEqual(snapshot.state, .pending)
        XCTAssertEqual(snapshot.controlRequest, .none)
        XCTAssertEqual(snapshot.attempts, 0)
        XCTAssertEqual(snapshot.maxAttempts, 5)
        XCTAssertEqual(snapshot.priority, 2)
        XCTAssertNil(snapshot.leaseOwner)
        XCTAssertNil(snapshot.lastErrorCode)
    }

    func testNullCoalescingKeysCanCoexist() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)

        _ = try JobTestSupport.enqueueDefault(queue: queue, id: UUID(), coalescingKey: nil)
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: UUID(), coalescingKey: nil)

        let count = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job") ?? 0
        }
        XCTAssertEqual(count, 2)
    }

    func testActiveCoalescingConflictReturnsStructuredError() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let firstID = UUID()
        let key = "scan:source-1"

        _ = try JobTestSupport.enqueueDefault(queue: queue, id: firstID, coalescingKey: key)

        XCTAssertThrowsError(
            try JobTestSupport.enqueueDefault(queue: queue, id: UUID(), coalescingKey: key)
        ) { error in
            XCTAssertEqual(
                error as? JobQueueError,
                .activeCoalescingConflict(existingJobID: firstID)
            )
        }
    }

    func testTerminalCoalescingKeyAllowsNewJob() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let key = "scan:source-1"
        let firstID = UUID()

        _ = try JobTestSupport.enqueueDefault(queue: queue, id: firstID, coalescingKey: key)
        _ = try queue.applyStateCommand(JobStateCommand(jobID: firstID, operation: .cancel))

        let second = try JobTestSupport.enqueueDefault(queue: queue, id: UUID(), coalescingKey: key)
        XCTAssertEqual(second.coalescingKey, key)
        XCTAssertEqual(second.state, .pending)
    }

    func testMissingSourceReferenceRejected() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)

        XCTAssertThrowsError(
            try JobTestSupport.enqueueDefault(queue: queue, sourceID: UUID())
        ) { error in
            XCTAssertEqual(error as? JobQueueError, .referenceNotFound)
        }
    }

    func testExistingSourceReferenceAccepted() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let sourceID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, sourceID: sourceID)

        let queue = JobTestSupport.makeQueue(database: database)
        let snapshot = try JobTestSupport.enqueueDefault(queue: queue, sourceID: sourceID)
        XCTAssertEqual(snapshot.sourceID, sourceID)
    }
}
