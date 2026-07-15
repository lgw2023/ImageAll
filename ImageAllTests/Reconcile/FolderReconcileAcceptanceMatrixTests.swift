import GRDB
import Security
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

/// Acceptance matrix covering Codex 5.3 second-review blockers.
final class FolderReconcileAcceptanceMatrixTests: XCTestCase {
    func testEnqueuePayloadPassesStrictValidationAgainstJobSource() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let bookmark = Data("b".utf8)
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        let snapshot = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let result = FolderReconcilePayloadValidation.validate(
            payloadVersion: snapshot.payloadVersion,
            payload: snapshot.payload,
            jobSourceID: snapshot.sourceID
        )
        switch result {
        case let .success(valid):
            XCTAssertEqual(valid.sourceID, sourceID)
        case let .failure(error):
            XCTFail("enqueue payload must validate: \(error)")
        }
    }

    // MARK: - 5.3.1 Strict JSON

    func testPayloadRejectsBooleanContractVersion() {
        let sourceID = UUID()
        let payload: [String: Any] = ["contract_version": true, "source_id": sourceID.uuidString.lowercased()]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let result = FolderReconcilePayloadValidation.validate(payloadVersion: 1, payload: data, jobSourceID: sourceID)
        XCTAssertEqual(result, .failure(.invalid(.folderPayloadInvalid)))
    }

    func testPayloadRejectsFloatingPointContractVersion() {
        let sourceID = UUID()
        let data = Data("{\"contract_version\":1.0,\"source_id\":\"\(sourceID.uuidString.lowercased())\"}".utf8)
        let result = FolderReconcilePayloadValidation.validate(payloadVersion: 1, payload: data, jobSourceID: sourceID)
        XCTAssertEqual(result, .failure(.invalid(.folderPayloadInvalid)))
    }

    func testPayloadRejectsNullSourceID() {
        let payload = Data("{\"contract_version\":1,\"source_id\":null}".utf8)
        let result = FolderReconcilePayloadValidation.validate(payloadVersion: 1, payload: payload, jobSourceID: UUID())
        XCTAssertEqual(result, .failure(.invalid(.folderPayloadInvalid)))
    }

    func testPayloadRejectsMissingContractVersion() {
        let sourceID = UUID()
        let payload: [String: Any] = ["source_id": sourceID.uuidString.lowercased()]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let result = FolderReconcilePayloadValidation.validate(payloadVersion: 1, payload: data, jobSourceID: sourceID)
        XCTAssertEqual(result, .failure(.invalid(.folderPayloadInvalid)))
    }

    func testCheckpointRejectsBooleanGeneration() {
        let json = """
        {"contract_version":1,"generation":true,"started_dirty_epoch":0,"attempt":1,
        "enumerated_entries":0,"candidate_files":0,"committed_assets":0,"ignored_entries":0,
        "unsupported_assets":0,"unreadable_assets":0,"identity_conflicts":0}
        """
        XCTAssertThrowsError(try FolderReconcileCheckpointCodec.decode(Data(json.utf8)))
    }

    func testCheckpointRejectsFloatingPointAttempt() {
        let json = """
        {"contract_version":1,"generation":1,"started_dirty_epoch":0,"attempt":1.0,
        "enumerated_entries":0,"candidate_files":0,"committed_assets":0,"ignored_entries":0,
        "unsupported_assets":0,"unreadable_assets":0,"identity_conflicts":0}
        """
        XCTAssertThrowsError(try FolderReconcileCheckpointCodec.decode(Data(json.utf8)))
    }

    func testCheckpointRejectsNegativeEnumeratedEntries() {
        let json = """
        {"contract_version":1,"generation":1,"started_dirty_epoch":0,"attempt":1,
        "enumerated_entries":-1,"candidate_files":0,"committed_assets":0,"ignored_entries":0,
        "unsupported_assets":0,"unreadable_assets":0,"identity_conflicts":0}
        """
        XCTAssertThrowsError(try FolderReconcileCheckpointCodec.decode(Data(json.utf8)))
    }

    func testCheckpointResumableAllowsPriorAttempt() {
        let checkpoint = FolderReconcileCheckpointV1(generation: 1, startedDirtyEpoch: 0, attempt: 1)
        XCTAssertTrue(
            FolderReconcileCheckpointCodec.validateResumable(
                checkpoint,
                scanGeneration: 1,
                startedDirtyEpoch: 0,
                currentAttempt: 2
            )
        )
    }

    func testCheckpointResumableRejectsFutureAttempt() {
        let checkpoint = FolderReconcileCheckpointV1(generation: 1, startedDirtyEpoch: 0, attempt: 3)
        XCTAssertFalse(
            FolderReconcileCheckpointCodec.validateResumable(
                checkpoint,
                scanGeneration: 1,
                startedDirtyEpoch: 0,
                currentAttempt: 2
            )
        )
    }

    // MARK: - 5.3.2 Cross-attempt recovery

    func testCrossAttemptRecoveryViaInterruptedRunningJobs() throws {
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
        let progressedCheckpoint = FolderReconcileCheckpointV1(
            generation: begin.generation,
            startedDirtyEpoch: begin.startedDirtyEpoch,
            attempt: lease.attempts,
            candidateFiles: 4
        )
        _ = try repository.commitAssetBatch(
            FolderAssetBatchInput(
                lease: lease,
                sourceID: sourceID,
                generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch,
                checkpoint: progressedCheckpoint,
                observations: [],
                leaseDurationMs: 1000,
                outcome: .continue
            )
        )

        try queue.recoverInterruptedRunningJobs()
        try queue.settleRetryableJobs()

        let interrupted = try queue.fetchJob(id: jobID)
        XCTAssertEqual(interrupted.state, .pending)
        XCTAssertEqual(interrupted.attempts, 1)
        XCTAssertEqual(interrupted.scanGeneration, begin.generation)
        XCTAssertGreaterThanOrEqual(interrupted.progress.completed, 4)

        let (handler, _) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        let result = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w2", leaseDurationMs: 1000)))
        XCTAssertEqual(result.snapshot.state, .completed)
        let decoded = try FolderReconcileCheckpointCodec.decode(XCTUnwrap(result.snapshot.checkpoint?.data))
        XCTAssertEqual(decoded.attempt, 2)
        XCTAssertEqual(decoded.generation, begin.generation)
        XCTAssertEqual(decoded.candidateFiles, 1)
        XCTAssertGreaterThanOrEqual(result.snapshot.progress.completed, 4)
    }

    // MARK: - 5.3.3 Stop without forged checkpoint

    func testPayloadInvalidStopDoesNotFabricateGeneration() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let bookmark = Data("bookmark".utf8)
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        let jobID = UUID()
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: jobID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let repository = GRDBFolderReconcileRepository(queue: queue)
        _ = try repository.stopIncomplete(
            FolderStopIncompleteInput(
                lease: lease,
                sourceID: sourceID,
                checkpoint: nil,
                leaseDurationMs: 1000,
                errorCode: .folderPayloadInvalid,
                outcome: .nonRetryableFailure(code: .folderPayloadInvalid)
            )
        )
        let scanGen = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT scan_generation FROM job WHERE id = ?", arguments: [jobID.uuidString.lowercased()])
        }
        XCTAssertNil(scanGen)
        let sourceGen = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT scan_generation FROM source WHERE id = ?", arguments: [sourceID.uuidString.lowercased()])
        }
        XCTAssertEqual(sourceGen, 0)
    }

    // MARK: - 5.3.4 Disable+cancel before source active check

    func testDisabledSourceWithCancelControlCompletesWithoutMissing() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "cancel")
        try fixture.writeFile(root: root, relativePath: "old.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        let jobID = UUID()
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: jobID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET state = 'disabled' WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE job SET control_request = 'cancel' WHERE id = ?",
                arguments: [jobID.uuidString.lowercased()]
            )
        }
        _ = try repository.completeGeneration(
            FolderCompleteGenerationInput(
                lease: lease,
                sourceID: sourceID,
                generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch,
                checkpoint: begin.checkpoint,
                leaseDurationMs: 1000
            )
        )
        let missing = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE availability = 'missing'")
        }
        XCTAssertEqual(missing, 0)
        let state = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM job WHERE id = ?", arguments: [jobID.uuidString.lowercased()])
        }
        XCTAssertEqual(state, JobState.cancelled.rawValue)
    }

    // MARK: - 5.3.5 Offline maps to sourceUnavailable

    func testOfflineBookmarkMapsToSourceUnavailable() throws {
        struct OfflineBookmarkPort: SecurityScopedBookmarkPort {
            let root: URL
            func createReadOnlyBookmark(for url: URL) throws -> Data { url.path.data(using: .utf8) ?? Data() }
            func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolveResult {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: nil)
            }
            func startAccessing(_ url: URL) -> Bool { true }
            func stopAccessing(_ url: URL) {}
        }
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "offline")
        let bookmark = Data("offline-bookmark".utf8)
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        let offlinePort = OfflineBookmarkPort(root: root)
        let access = FolderReconcileSourceAccessService(
            repository: GRDBFolderSourceAuthorizationRepository(database: database),
            bookmarkPort: offlinePort,
            rootValidator: FolderRootValidator(),
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )
        XCTAssertThrowsError(try access.withActiveSourceRootURL(sourceID: sourceID) { _ in }) { error in
            XCTAssertEqual(error as? FolderReconcileHandlerError, .sourceUnavailable)
        }
    }

    // MARK: - 5.3.6 Enumeration incomplete

    func testInjectedResourceValueFailureMarksIncomplete() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "inject-error")
        try fixture.writeFile(root: root, relativePath: "good.png", contents: FolderReconcileTestSupport.minimalPNGData())
        try fixture.writeFile(root: root, relativePath: "bad.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(
            database: database,
            root: root,
            bookmark: bookmark,
            enumerationConfig: FolderEnumerationConfig(
                workUnitLimit: 32,
                assetBatchLimit: 32,
                errorInjection: FolderEnumerationErrorInjection(resourceValueFailureRelativePaths: ["bad.png"])
            )
        )
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        let result = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        XCTAssertEqual(result.snapshot.state, .retryableFailed)
        XCTAssertEqual(result.snapshot.lastErrorCode, .folderEnumerationIncomplete)
    }

    func testEnumerationDirectoryErrorMarksIncompleteNotMissing() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "enum-error")
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try fixture.writeFile(root: root, relativePath: "locked/hidden.png", contents: FolderReconcileTestSupport.minimalPNGData())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let session = FolderDirectoryEnumerator(rootURL: root).makeSession()
        while let _ = try session.nextEntry() {}
        XCTAssertTrue(session.directoryHadError)

        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        let result = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        XCTAssertEqual(result.snapshot.state, .retryableFailed)
        XCTAssertEqual(result.snapshot.lastErrorCode, .folderEnumerationIncomplete)
        let missing = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE availability = 'missing'")
        }
        XCTAssertEqual(missing, 0)
    }

    func testStrictRootBoundaryRejectsInvalidRelativeComponents() {
        XCTAssertEqual(RelativePathRules.validate(""), .failure(.empty))
        XCTAssertEqual(RelativePathRules.validate("."), .failure(.invalidComponent))
        XCTAssertEqual(RelativePathRules.validate(".."), .failure(.invalidComponent))
        XCTAssertEqual(RelativePathRules.validate("a/../b"), .failure(.invalidComponent))
        XCTAssertEqual(RelativePathRules.validate("/abs"), .failure(.absolute))
    }

    // MARK: - 5.3.10 Fault triggers

    func testBatchCheckpointFaultRollsBackEntireBatch() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        try FolderReconcileTestFaults.install(on: database)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "ckpt-fault")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        try FolderReconcileTestFaults.setMode(.failBatchCheckpoint, database: database)
        let observation = FolderReconcileAssetObservation(
            relativePath: "a.png",
            fileName: "a.png",
            mediaType: UTType.png.identifier,
            width: 2,
            height: 1,
            mediaCreatedAtMs: nil,
            availability: .available,
            sizeBytes: 100,
            modifiedAtNs: 1,
            resourceID: nil,
            movePathProbe: nil
        )
        XCTAssertThrowsError(
            try repository.commitAssetBatch(
                FolderAssetBatchInput(
                    lease: lease,
                    sourceID: sourceID,
                    generation: begin.generation,
                    startedDirtyEpoch: begin.startedDirtyEpoch,
                    checkpoint: begin.checkpoint,
                    observations: [observation],
                    leaseDurationMs: 1000,
                    outcome: .continue
                )
            )
        )
        let assetCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset")
        }
        XCTAssertEqual(assetCount, 0)
    }

    func testFinalCompletionFaultRollsBackMissingAndCompletion() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        try FolderReconcileTestFaults.install(on: database)
        try FolderReconcileTestFaults.setMode(.failFinalCompletion, database: database)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "final-comp")
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        let jobID = UUID()
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: jobID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        XCTAssertThrowsError(
            try repository.completeGeneration(
                FolderCompleteGenerationInput(
                    lease: lease,
                    sourceID: sourceID,
                    generation: begin.generation,
                    startedDirtyEpoch: begin.startedDirtyEpoch,
                    checkpoint: begin.checkpoint,
                    leaseDurationMs: 1000
                )
            )
        )
        let state = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM job WHERE id = ?", arguments: [jobID.uuidString.lowercased()])
        }
        XCTAssertEqual(state, JobState.running.rawValue)
    }

    func testFingerprintInsertFaultRollsBackAsset() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        try FolderReconcileTestFaults.install(on: database)
        try FolderReconcileTestFaults.setMode(.failFingerprintInsert, database: database)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "fp-fault")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        let observation = FolderReconcileAssetObservation(
            relativePath: "a.png",
            fileName: "a.png",
            mediaType: UTType.png.identifier,
            width: 2,
            height: 1,
            mediaCreatedAtMs: nil,
            availability: .available,
            sizeBytes: 100,
            modifiedAtNs: 1,
            resourceID: nil,
            movePathProbe: nil
        )
        XCTAssertThrowsError(
            try repository.commitAssetBatch(
                FolderAssetBatchInput(
                    lease: lease,
                    sourceID: sourceID,
                    generation: begin.generation,
                    startedDirtyEpoch: begin.startedDirtyEpoch,
                    checkpoint: begin.checkpoint,
                    observations: [observation],
                    leaseDurationMs: 1000,
                    outcome: .continue
                )
            )
        )
        let assetCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset")
        }
        XCTAssertEqual(assetCount, 0)
    }

    func testBatchLeaseRenewFaultRollsBackEntireBatch() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        try FolderReconcileTestFaults.install(on: database)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "lease-fault")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        try FolderReconcileTestFaults.setMode(.failBatchLeaseRenew, database: database)
        let observation = FolderReconcileAssetObservation(
            relativePath: "a.png",
            fileName: "a.png",
            mediaType: UTType.png.identifier,
            width: 2,
            height: 1,
            mediaCreatedAtMs: nil,
            availability: .available,
            sizeBytes: 100,
            modifiedAtNs: 1,
            resourceID: nil,
            movePathProbe: nil
        )
        XCTAssertThrowsError(
            try repository.commitAssetBatch(
                FolderAssetBatchInput(
                    lease: lease,
                    sourceID: sourceID,
                    generation: begin.generation,
                    startedDirtyEpoch: begin.startedDirtyEpoch,
                    checkpoint: begin.checkpoint,
                    observations: [observation],
                    leaseDurationMs: 1000,
                    outcome: .continue
                )
            )
        )
        let assetCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset")
        }
        XCTAssertEqual(assetCount, 0)
    }

    func testStaleLeaseOwnerRejectedBeforeBatch() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let bookmark = Data("bookmark".utf8)
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        let staleLease = JobLeaseToken(
            jobID: lease.jobID,
            leaseOwner: "other-worker",
            attempts: lease.attempts,
            leaseExpiresAtMs: lease.leaseExpiresAtMs,
            kind: lease.kind,
            payloadVersion: lease.payloadVersion,
            payload: lease.payload,
            checkpoint: lease.checkpoint
        )
        XCTAssertThrowsError(
            try repository.commitAssetBatch(
                FolderAssetBatchInput(
                    lease: staleLease,
                    sourceID: sourceID,
                    generation: begin.generation,
                    startedDirtyEpoch: begin.startedDirtyEpoch,
                    checkpoint: begin.checkpoint,
                    observations: [],
                    leaseDurationMs: 1000,
                    outcome: .continue
                )
            )
        ) { error in
            XCTAssertEqual(error as? JobQueueError, .staleLease(lease.jobID))
        }
    }

    // MARK: - 5.3.12 Readonly snapshot includes directories

    func testReadonlySnapshotIncludesEmptyDirectoryMetadata() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "tree")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        _ = try fixture.writeFile(root: root, relativePath: "empty/photo.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let before = try fixture.snapshotDetailed(root: root)
        XCTAssertTrue(before["empty"]?.isDirectory == true)
        XCTAssertNotNil(before["empty/photo.png"]?.bytes)

        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let after = try fixture.snapshotDetailed(root: root)
        XCTAssertEqual(before, after)
    }
}
