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

    func testSuccessfulLeaseRenewOnBatchAdvancesExpiryFromNow() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let clock = AdvancingJobClock(startMs: FolderReconcileTestSupport.baseTimeMs)
        let queue = GRDBJobQueue(
            database: database,
            clock: clock,
            retryPolicy: FixedDelayRetryPolicy(delayMs: 0)
        )
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let bookmark = Data("b".utf8)
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let leaseDuration: Int64 = 5000
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: leaseDuration)))
        let initialExpiry = try XCTUnwrap(try database.pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT lease_expires_at_ms FROM job")
        })
        XCTAssertEqual(initialExpiry, FolderReconcileTestSupport.baseTimeMs + leaseDuration)
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: leaseDuration)
        )
        clock.advance(by: 2000)
        _ = try repository.commitAssetBatch(
            FolderAssetBatchInput(
                lease: lease, sourceID: sourceID, generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch, checkpoint: begin.checkpoint,
                observations: [], leaseDurationMs: leaseDuration, outcome: .continue
            )
        )
        let renewedExpiry = try XCTUnwrap(try database.pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT lease_expires_at_ms FROM job")
        })
        XCTAssertEqual(renewedExpiry, clock.nowMs + leaseDuration)
        XCTAssertNotEqual(renewedExpiry, initialExpiry)
    }

    func testBatchProgressFaultRollsBackAllDatabaseFacts() throws {
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
        let before = try ReconcileDatabaseFactCapture.capture(database: database, jobID: lease.jobID, sourceID: sourceID)
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
        let after = try ReconcileDatabaseFactCapture.capture(database: database, jobID: lease.jobID, sourceID: sourceID)
        XCTAssertEqual(after, before)
    }

    func testDuplicateFinalAfterDirtyEpochCreatesOneSuccessorOnly() throws {
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
        try FolderReconcileTestSupport.bumpDirtyEpoch(database: database, sourceID: sourceID, to: 1)
        _ = try repository.completeGeneration(
            FolderCompleteGenerationInput(
                lease: lease, sourceID: sourceID, generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch, checkpoint: begin.checkpoint, leaseDurationMs: 1000
            )
        )
        let afterFirst = try ReconcileDatabaseFactCapture.capture(database: database, jobID: jobID, sourceID: sourceID)
        XCTAssertEqual(afterFirst.pendingSuccessorCount, 1)
        XCTAssertThrowsError(
            try repository.completeGeneration(
                FolderCompleteGenerationInput(
                    lease: lease, sourceID: sourceID, generation: begin.generation,
                    startedDirtyEpoch: begin.startedDirtyEpoch, checkpoint: begin.checkpoint, leaseDurationMs: 1000
                )
            )
        )
        let afterSecond = try ReconcileDatabaseFactCapture.capture(database: database, jobID: jobID, sourceID: sourceID)
        XCTAssertEqual(afterSecond, afterFirst)
    }

    func testPauseDuringRunningScanLeavesPausedWithoutMissing() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "pause")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        let jobID = UUID()
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: jobID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        let observation = FolderReconcileAssetObservation(
            relativePath: "a.png", fileName: "a.png", mediaType: UTType.png.identifier,
            width: 2, height: 2, mediaCreatedAtMs: nil, availability: .available,
            sizeBytes: 100, modifiedAtNs: 1, resourceID: nil, movePathProbe: nil
        )
        _ = try repository.commitAssetBatch(
            FolderAssetBatchInput(
                lease: lease, sourceID: sourceID, generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch, checkpoint: begin.checkpoint,
                observations: [observation], leaseDurationMs: 1000, outcome: .continue
            )
        )
        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE job SET control_request = 'pause' WHERE id = ?",
                arguments: [jobID.uuidString.lowercased()]
            )
        }
        _ = try repository.completeGeneration(
            FolderCompleteGenerationInput(
                lease: lease, sourceID: sourceID, generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch, checkpoint: begin.checkpoint, leaseDurationMs: 1000
            )
        )
        let state = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM job WHERE id = ?", arguments: [jobID.uuidString.lowercased()])
        }
        XCTAssertEqual(state, JobState.paused.rawValue)
        let missing = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE availability = 'missing'")
        }
        XCTAssertEqual(missing, 0)
    }

    func testCancelDuringRunningScanLeavesCancelledWithoutMissing() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "cancel-scan")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        let jobID = UUID()
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: jobID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        let observation = FolderReconcileAssetObservation(
            relativePath: "a.png", fileName: "a.png", mediaType: UTType.png.identifier,
            width: 2, height: 2, mediaCreatedAtMs: nil, availability: .available,
            sizeBytes: 100, modifiedAtNs: 1, resourceID: nil, movePathProbe: nil
        )
        _ = try repository.commitAssetBatch(
            FolderAssetBatchInput(
                lease: lease, sourceID: sourceID, generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch, checkpoint: begin.checkpoint,
                observations: [observation], leaseDurationMs: 1000, outcome: .continue
            )
        )
        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE job SET control_request = 'cancel' WHERE id = ?",
                arguments: [jobID.uuidString.lowercased()]
            )
        }
        _ = try repository.completeGeneration(
            FolderCompleteGenerationInput(
                lease: lease, sourceID: sourceID, generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch, checkpoint: begin.checkpoint, leaseDurationMs: 1000
            )
        )
        let state = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM job WHERE id = ?", arguments: [jobID.uuidString.lowercased()])
        }
        XCTAssertEqual(state, JobState.cancelled.rawValue)
        let missing = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE availability = 'missing'")
        }
        XCTAssertEqual(missing, 0)
    }

    func testPauseDuringHandlerScanPausesWithoutMissing() throws {
        try assertHandlerControlInjection(
            control: "pause",
            expectedState: .paused,
            label: "pause-handler"
        )
    }

    func testCancelDuringHandlerScanCancelsWithPairedScope() throws {
        try assertHandlerControlInjection(
            control: "cancel",
            expectedState: .cancelled,
            label: "cancel-handler"
        )
    }

    func testInterruptedBatchRecoveryCompletesWithoutDuplicateAssets() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = GRDBJobQueue(
            database: database,
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs),
            retryPolicy: FixedDelayRetryPolicy(delayMs: 0)
        )
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "recovery")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        let jobID = UUID()
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: jobID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w1", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        let observation = FolderReconcileAssetObservation(
            relativePath: "a.png", fileName: "a.png", mediaType: UTType.png.identifier,
            width: 2, height: 2, mediaCreatedAtMs: nil, availability: .available,
            sizeBytes: 100, modifiedAtNs: 1, resourceID: nil, movePathProbe: nil
        )
        _ = try repository.commitAssetBatch(
            FolderAssetBatchInput(
                lease: lease, sourceID: sourceID, generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch, checkpoint: begin.checkpoint,
                observations: [observation], leaseDurationMs: 1000, outcome: .continue
            )
        )
        try queue.recoverInterruptedRunningJobs()
        try queue.settleRetryableJobs()
        let (handler, _) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w2", leaseDurationMs: 1000)))
        let assetCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE locator_state = 'current'")
        }
        XCTAssertEqual(assetCount, 1)
    }

    func testAllDeclaredFaultStagesPreserveDatabaseFacts() throws {
        let stages: [FolderReconcileTestFaults.FaultStage] = [
            .failBeginSourceUpdate,
            .failAssetInsert,
            .failBatchCheckpoint,
            .failFingerprintInsert,
            .failBatchLeaseRenew,
            .failBatchProgress,
            .failFinalMissing,
            .failFinalCompletion,
            .failFinalSuccessor,
        ]
        for stage in stages {
            try assertFaultPreservesFacts(stage: stage)
        }
    }

    private func assertFaultPreservesFacts(stage: FolderReconcileTestFaults.FaultStage) throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        try FolderReconcileTestFaults.install(on: database)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "fault-\(stage.rawValue)")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let observation = FolderReconcileAssetObservation(
            relativePath: "a.png", fileName: "a.png", mediaType: UTType.png.identifier,
            width: 2, height: 2, mediaCreatedAtMs: nil, availability: .available,
            sizeBytes: 100, modifiedAtNs: 1, resourceID: nil, movePathProbe: nil
        )

        switch stage {
        case .failBeginSourceUpdate:
            let before = try ReconcileDatabaseFactCapture.capture(database: database, jobID: lease.jobID, sourceID: sourceID)
            try FolderReconcileTestFaults.setMode(stage, database: database)
            XCTAssertThrowsError(
                try repository.beginGeneration(
                    FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
                )
            )
            let after = try ReconcileDatabaseFactCapture.capture(database: database, jobID: lease.jobID, sourceID: sourceID)
            XCTAssertEqual(after, before, "fault stage \(stage.rawValue) must fully rollback")

        case .failFinalMissing, .failFinalCompletion, .failFinalSuccessor:
            let begin1 = try repository.beginGeneration(
                FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
            )
            _ = try repository.commitAssetBatch(
                FolderAssetBatchInput(
                    lease: lease, sourceID: sourceID, generation: begin1.generation,
                    startedDirtyEpoch: begin1.startedDirtyEpoch, checkpoint: begin1.checkpoint,
                    observations: [observation], leaseDurationMs: 1000, outcome: .continue
                )
            )
            _ = try repository.completeGeneration(
                FolderCompleteGenerationInput(
                    lease: lease, sourceID: sourceID, generation: begin1.generation,
                    startedDirtyEpoch: begin1.startedDirtyEpoch, checkpoint: begin1.checkpoint, leaseDurationMs: 1000
                )
            )
            _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: UUID())
            let lease2 = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w2", leaseDurationMs: 1000)))
            let begin2 = try repository.beginGeneration(
                FolderReconcileTestSupport.beginGenerationInput(lease: lease2, sourceID: sourceID, leaseDurationMs: 1000)
            )
            if stage == .failFinalSuccessor {
                try FolderReconcileTestSupport.bumpDirtyEpoch(
                    database: database,
                    sourceID: sourceID,
                    to: begin2.startedDirtyEpoch + 1
                )
            }
            let beforeFinal = try ReconcileDatabaseFactCapture.capture(database: database, jobID: lease2.jobID, sourceID: sourceID)
            try FolderReconcileTestFaults.setMode(stage, database: database)
            XCTAssertThrowsError(
                try repository.completeGeneration(
                    FolderCompleteGenerationInput(
                        lease: lease2, sourceID: sourceID, generation: begin2.generation,
                        startedDirtyEpoch: begin2.startedDirtyEpoch, checkpoint: begin2.checkpoint, leaseDurationMs: 1000
                    )
                )
            )
            let afterFinal = try ReconcileDatabaseFactCapture.capture(database: database, jobID: lease2.jobID, sourceID: sourceID)
            XCTAssertEqual(afterFinal, beforeFinal, "fault stage \(stage.rawValue) must fully rollback")

        default:
            let begin = try repository.beginGeneration(
                FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
            )
            let beforeBatch = try ReconcileDatabaseFactCapture.capture(database: database, jobID: lease.jobID, sourceID: sourceID)
            try FolderReconcileTestFaults.setMode(stage, database: database)
            XCTAssertThrowsError(
                try repository.commitAssetBatch(
                    FolderAssetBatchInput(
                        lease: lease, sourceID: sourceID, generation: begin.generation,
                        startedDirtyEpoch: begin.startedDirtyEpoch, checkpoint: begin.checkpoint,
                        observations: [observation], leaseDurationMs: 1000, outcome: .continue
                    )
                )
            )
            let afterBatch = try ReconcileDatabaseFactCapture.capture(database: database, jobID: lease.jobID, sourceID: sourceID)
            XCTAssertEqual(afterBatch, beforeBatch, "fault stage \(stage.rawValue) must fully rollback")
        }
    }

    private func assertHandlerControlInjection(
        control: String,
        expectedState: JobState,
        label: String
    ) throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: label)
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        try fixture.writeFile(root: root, relativePath: "b.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let config = FolderEnumerationConfig(workUnitLimit: 256, assetBatchLimit: 1)
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let spy = RecordingReconcileBatchPort(queue: queue)
        var didInjectControl = false
        spy.afterCommit = { _ in
            guard !didInjectControl, spy.committedBatchSizes.contains(where: { $0 > 0 }) else { return }
            didInjectControl = true
            try database.pool.write { db in
                try db.execute(
                    sql: "UPDATE job SET control_request = ? WHERE state = 'running'",
                    arguments: [control]
                )
            }
        }
        let sourceID = UUID()
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, port) = FolderReconcileTestSupport.makeHandler(
            database: database,
            root: root,
            bookmark: bookmark,
            enumerationConfig: config
        )
        let coordinator = FolderReconcileTestSupport.makeCoordinator(
            queue: queue,
            handler: handler,
            leaseContextProvider: SpyJobLeaseContextProvider(queue: queue, batchPort: spy)
        )
        let result = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        XCTAssertTrue(didInjectControl, "first asset batch must inject \(control) before final")
        XCTAssertFalse(spy.committedBatchSizes.isEmpty)
        XCTAssertTrue(spy.committedBatchSizes.contains(where: { $0 > 0 }))
        XCTAssertEqual(result.snapshot.state, expectedState)
        let missing = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE availability = 'missing'")
        }
        XCTAssertEqual(missing, 0)
        XCTAssertEqual(port.scopeStartCount, 1)
        XCTAssertEqual(port.scopeStopCount, 1)
    }
}
