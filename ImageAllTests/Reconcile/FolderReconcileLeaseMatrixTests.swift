import GRDB
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

/// Handoff 10.5 lease, generation, recovery and fault matrix.
final class FolderReconcileLeaseMatrixTests: XCTestCase {
    func testStaleAttemptRejectedBeforeBatch() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let bookmark = Data("b".utf8)
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        let stale = JobLeaseToken(
            jobID: lease.jobID, leaseOwner: lease.leaseOwner, attempts: lease.attempts + 1,
            leaseExpiresAtMs: lease.leaseExpiresAtMs, kind: lease.kind, payloadVersion: lease.payloadVersion,
            payload: lease.payload, checkpoint: lease.checkpoint
        )
        XCTAssertThrowsError(
            try repository.commitAssetBatch(
                FolderAssetBatchInput(
                    lease: stale, sourceID: sourceID, generation: begin.generation,
                    startedDirtyEpoch: begin.startedDirtyEpoch, checkpoint: begin.checkpoint,
                    observations: [], leaseDurationMs: 1000, outcome: .continue
                )
            )
        ) { error in
            XCTAssertEqual(error as? JobQueueError, .staleLease(lease.jobID))
        }
    }

    func testExactLeaseExpiryRejected() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let base = FolderReconcileTestSupport.baseTimeMs
        let queue = GRDBJobQueue(
            database: database,
            clock: FixedJobClock(nowMs: base),
            retryPolicy: FixedDelayRetryPolicy(delayMs: 0)
        )
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let bookmark = Data("b".utf8)
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let expiredQueue = GRDBJobQueue(
            database: database,
            clock: FixedJobClock(nowMs: base + 1000),
            retryPolicy: FixedDelayRetryPolicy(delayMs: 0)
        )
        let expiredRepo = GRDBFolderReconcileRepository(queue: expiredQueue)
        XCTAssertThrowsError(
            try expiredRepo.beginGeneration(
                FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
            )
        ) { error in
            XCTAssertEqual(error as? JobQueueError, .expiredLease(lease.jobID))
        }
    }

    func testSuccessfulLeaseRenewOnBatch() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let bookmark = Data("b".utf8)
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 5000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 5000)
        )
        _ = try repository.commitAssetBatch(
            FolderAssetBatchInput(
                lease: lease, sourceID: sourceID, generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch, checkpoint: begin.checkpoint,
                observations: [], leaseDurationMs: 5000, outcome: .continue
            )
        )
        let expires = try database.pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT lease_expires_at_ms FROM job")
        }
        XCTAssertEqual(expires, FolderReconcileTestSupport.baseTimeMs + 5000)
    }

    func testBatchProgressFaultRollsBackEntireBatch() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        try FolderReconcileTestFaults.install(on: database)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "prog")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        try FolderReconcileTestFaults.setMode(.failBatchProgress, database: database)
        let observation = FolderReconcileAssetObservation(
            relativePath: "a.png", fileName: "a.png", mediaType: UTType.png.identifier,
            width: 2, height: 2, mediaCreatedAtMs: nil, availability: .available,
            sizeBytes: 100, modifiedAtNs: 1, resourceID: nil, movePathProbe: nil
        )
        XCTAssertThrowsError(
            try repository.commitAssetBatch(
                FolderAssetBatchInput(
                    lease: lease, sourceID: sourceID, generation: begin.generation,
                    startedDirtyEpoch: begin.startedDirtyEpoch, checkpoint: begin.checkpoint,
                    observations: [observation], leaseDurationMs: 1000, outcome: .continue
                )
            )
        )
        let assetCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset")
        }
        XCTAssertEqual(assetCount, 0)
    }

    func testDuplicateFinalDoesNotCreateSecondSuccessor() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "final-idem")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        let jobID = UUID()
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: jobID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        _ = try repository.completeGeneration(
            FolderCompleteGenerationInput(
                lease: lease, sourceID: sourceID, generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch, checkpoint: begin.checkpoint, leaseDurationMs: 1000
            )
        )
        let pending = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job WHERE state = 'pending' AND source_id = ?", arguments: [sourceID.uuidString.lowercased()])
        }
        XCTAssertEqual(pending, 0)
    }
}
