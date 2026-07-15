import GRDB
import XCTest
@testable import ImageAll

final class FolderReconcileTransactionTests: XCTestCase {
    func testBeginFailureRollsBackGenerationIncrement() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        try FolderReconcileTestFaults.install(on: database)
        try FolderReconcileTestFaults.setMode(.failBeginSourceUpdate, database: database)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "begin")
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let handler = FolderReconcileHandler(
            rootAccess: FolderReconcileRootAccessAdapter(
                repository: GRDBFolderSourceAuthorizationRepository(database: database),
                bookmarkPort: FolderReconcileTestSupport.TestBookmarkPort(rootByBookmark: [bookmark: root])
            )
        )
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        XCTAssertThrowsError(
            try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000))
        )
        let generation = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT scan_generation FROM source WHERE id = ?", arguments: [sourceID.uuidString.lowercased()])
        }
        XCTAssertEqual(generation, 0)
    }

    func testIncompleteGenerationNeverMarksMissing() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "incomplete")
        try fixture.writeFile(root: root, relativePath: "keep.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let handler = FolderReconcileHandler(
            rootAccess: FolderReconcileRootAccessAdapter(
                repository: GRDBFolderSourceAuthorizationRepository(database: database),
                bookmarkPort: FolderReconcileTestSupport.TestBookmarkPort(rootByBookmark: [bookmark: root])
            ),
            enumerationConfig: FolderEnumerationConfig(workUnitLimit: 1, assetBatchLimit: 1)
        )
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let missingCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE availability = 'missing'")
        }
        XCTAssertEqual(missingCount, 0)
    }

    func testExpiredLeaseRejectedBeforeBusinessClosure() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let baseClock = FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        let queue = GRDBJobQueue(
            database: database,
            clock: baseClock,
            retryPolicy: FixedDelayRetryPolicy(delayMs: 1000)
        )
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "lease")
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))

        let expiredQueue = GRDBJobQueue(
            database: database,
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs + 5_000),
            retryPolicy: FixedDelayRetryPolicy(delayMs: 1000)
        )
        let repository = GRDBFolderReconcileRepository(queue: expiredQueue)
        XCTAssertThrowsError(
            try repository.beginGeneration(
                FolderBeginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
            )
        ) { error in
            XCTAssertEqual(error as? JobQueueError, .expiredLease(lease.jobID))
        }
    }

    func testDirtyEpochCreatesExactlyOneSuccessor() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "succ")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        let jobID = UUID()
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: jobID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderBeginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        try database.pool.write { db in
            try JobTestSupport.incrementSourceDirtyEpoch(db, sourceID: sourceID, delta: 1)
        }
        let checkpoint = FolderReconcileCheckpointV1(
            generation: begin.generation,
            startedDirtyEpoch: begin.startedDirtyEpoch,
            attempt: lease.attempts,
            candidateFiles: 1
        )
        let complete = try repository.completeGeneration(
            FolderCompleteGenerationInput(
                lease: lease,
                sourceID: sourceID,
                generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch,
                checkpoint: checkpoint,
                leaseDurationMs: 1000
            )
        )
        XCTAssertNotNil(complete.successorJobID)
        let pending = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job WHERE source_id = ? AND state = 'pending'", arguments: [sourceID.uuidString.lowercased()])
        }
        XCTAssertEqual(pending, 1)
    }
}
