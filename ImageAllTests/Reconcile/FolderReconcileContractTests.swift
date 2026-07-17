import XCTest
@testable import ImageAll

final class FolderReconcileContractTests: XCTestCase {
    func testFolderDirtyBatchIncrementsEpochAndCoalescesReconcileJob() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        try FolderReconcileTestSupport.seedActiveFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: Data("bookmark".utf8)
        )
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(
            queue: queue,
            sourceID: sourceID
        )
        let trigger = FolderSourceDirtyTrigger(
            database: database,
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )

        XCTAssertTrue(try trigger.recordEventBatch(sourceID: sourceID, eventCount: 3))

        let evidence = try database.pool.read { db in
            (
                dirtyEpoch: try Int.fetchOne(
                    db,
                    sql: "SELECT dirty_epoch FROM source WHERE id = ?",
                    arguments: [sourceID.uuidString.lowercased()]
                ),
                activeJobCount: try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM job
                    WHERE coalescing_key = ?
                        AND state IN ('pending', 'running', 'paused', 'retryableFailed')
                    """,
                    arguments: [FolderReconcileJobFactory.coalescingKey(sourceID: sourceID)]
                )
            )
        }
        XCTAssertEqual(evidence.dirtyEpoch, 3)
        XCTAssertEqual(evidence.activeJobCount, 1)
    }

    func testFolderMonitorRootLossMarksSourceUnavailableAndStopsAccess() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "watch-root-loss")
        let bookmark = Data("watch-bookmark".utf8)
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        let sourceID = UUID()
        try FolderReconcileTestSupport.seedActiveFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark
        )
        let bookmarkPort = FolderReconcileTestSupport.TestBookmarkPort(
            rootByBookmark: [bookmark: root]
        )
        let streamFactory = TestFolderEventStreamFactory()
        let repository = GRDBFolderSourceAuthorizationRepository(database: database)
        let monitor = FolderSourceMonitoringCoordinator(
            repository: repository,
            bookmarkPort: bookmarkPort,
            rootValidator: FolderRootValidator(),
            dirtyTrigger: FolderSourceDirtyTrigger(database: database),
            streamFactory: streamFactory
        )
        try monitor.start(onChange: {})

        streamFactory.send(
            FolderFileSystemEventBatch(eventCount: 1, flags: [.rootChanged])
        )

        guard case let .folder(source) = try repository.lookupSource(id: sourceID) else {
            return XCTFail("folder source missing")
        }
        XCTAssertEqual(source.state, .unavailable)
        XCTAssertEqual(source.dirtyEpoch, 0)
        XCTAssertEqual(streamFactory.stopCount, 1)
        XCTAssertEqual(bookmarkPort.scopeStopCount, 1)
    }

    func testFSEventAutomaticallyReconcilesSyntheticFolderChange() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "fsevents-reconcile")
        let firstData = FolderReconcileTestSupport.minimalPNGData()
        try firstData.write(to: root.appendingPathComponent("first.png"))
        let bookmark = Data("watch-bookmark".utf8)
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let clock = FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        let sourceID = UUID()
        try FolderReconcileTestSupport.seedActiveFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark
        )
        let bookmarkPort = FolderReconcileTestSupport.TestBookmarkPort(
            rootByBookmark: [bookmark: root]
        )
        let access = FolderReconcileTestSupport.makeSourceAccess(
            database: database,
            bookmarkPort: bookmarkPort
        )
        let handler = FolderReconcileHandler(rootAccess: access)
        let execution = FolderReconcileTestSupport.makeCoordinator(
            queue: queue,
            handler: handler
        )
        let monitor = FolderSourceMonitoringCoordinator(
            repository: GRDBFolderSourceAuthorizationRepository(database: database),
            bookmarkPort: bookmarkPort,
            rootValidator: FolderRootValidator(),
            dirtyTrigger: FolderSourceDirtyTrigger(database: database, clock: clock),
            streamFactory: FoundationFolderFileSystemEventStreamFactory(latency: 0.05),
            clock: clock
        )
        let workerQueue = DispatchQueue(label: "ImageAllTests.fsevents-reconcile")
        let initial = expectation(description: "initial reconcile")
        initial.assertForOverFulfill = false
        let changed = expectation(description: "event-driven reconcile")
        changed.assertForOverFulfill = false
        let failure = LockedFailure()

        try monitor.start {
            workerQueue.async {
                do {
                    let claim = ClaimNextInput(
                        owner: "fsevents-test-worker",
                        leaseDurationMs: FolderReconcileTestSupport.leaseDurationMs,
                        allowedKinds: [FolderReconcileJobFactory.kind]
                    )
                    while let result = try execution.claimAndExecuteOnce(claim) {
                        guard result.snapshot.state == .completed else {
                            throw ProductionLibraryWorkspaceError.reconcileFailed
                        }
                    }
                    let names = try database.pool.read { db in
                        try String.fetchAll(
                            db,
                            sql: """
                            SELECT file_name FROM asset
                            WHERE source_id = ? AND availability = 'available'
                            ORDER BY file_name
                            """,
                            arguments: [sourceID.uuidString.lowercased()]
                        )
                    }
                    if names == ["first.png"] { initial.fulfill() }
                    if names == ["first.png", "second.png"] { changed.fulfill() }
                } catch {
                    failure.record(error)
                    initial.fulfill()
                    changed.fulfill()
                }
            }
        }
        wait(for: [initial], timeout: 5)
        XCTAssertNil(failure.message)

        let secondData = firstData + Data([0x00])
        try secondData.write(to: root.appendingPathComponent("second.png"))

        wait(for: [changed], timeout: 5)
        monitor.stop()
        XCTAssertNil(failure.message)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("first.png")), firstData)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("second.png")), secondData)
        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
    }

    func testStrictJSONAcceptsDeserializedIntegerOne() throws {
        let sourceID = UUID()
        let payload: [String: Any] = [
            "contract_version": 1,
            "source_id": sourceID.uuidString.lowercased(),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(StrictJSONValidation.exactContractVersion(object["contract_version"]), 1)
        let result = FolderReconcilePayloadValidation.validate(
            payloadVersion: 1,
            payload: data,
            jobSourceID: sourceID
        )
        XCTAssertEqual(result, .success(FolderReconcilePayloadValidation.ValidPayload(sourceID: sourceID, contractVersion: 1)))
    }

    func testStrictJSONRejectsBooleanContractVersion() {
        XCTAssertNil(StrictJSONValidation.nonNegativeInteger(true))
        let payload = Data("{\"contract_version\":true,\"source_id\":\"\(UUID().uuidString.lowercased())\"}".utf8)
        let result = FolderReconcilePayloadValidation.validate(payloadVersion: 1, payload: payload, jobSourceID: UUID())
        XCTAssertEqual(result, .failure(.invalid(.folderPayloadInvalid)))
    }

    func testStrictJSONRejectsFloatingPointContractVersion() {
        let payload = Data("{\"contract_version\":1.0,\"source_id\":\"\(UUID().uuidString.lowercased())\"}".utf8)
        let result = FolderReconcilePayloadValidation.validate(payloadVersion: 1, payload: payload, jobSourceID: UUID())
        XCTAssertEqual(result, .failure(.invalid(.folderPayloadInvalid)))
    }

    func testStrictJSONRejectsNegativeInteger() {
        XCTAssertNil(StrictJSONValidation.nonNegativeInteger(NSNumber(value: -1)))
    }

    func testStrictJSONRejectsIntegerOverflow() throws {
        let json = Data("{\"contract_version\": 92233720368547758070}".utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertNil(StrictJSONValidation.nonNegativeInteger(object["contract_version"]))
    }

    func testPayloadRejectsUppercaseUUID() {
        let uuid = UUID()
        let uppercase = uuid.uuidString.uppercased()
        let payload: [String: Any] = [
            "contract_version": 1,
            "source_id": uppercase,
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let result = FolderReconcilePayloadValidation.validate(
            payloadVersion: 1,
            payload: data,
            jobSourceID: uuid
        )
        XCTAssertEqual(result, .failure(.invalid(FolderReconcileSafeErrorCode.payloadInvalid)))
    }

    func testPayloadRejectsSourceMismatch() {
        let sourceID = UUID()
        let payload: [String: Any] = [
            "contract_version": 1,
            "source_id": sourceID.uuidString.lowercased(),
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let result = FolderReconcilePayloadValidation.validate(
            payloadVersion: 1,
            payload: data,
            jobSourceID: UUID()
        )
        XCTAssertEqual(result, .failure(.invalid(FolderReconcileSafeErrorCode.payloadInvalid)))
    }

    func testSafeErrorSettlementMapsAuthorizationToNonRetryable() {
        let outcome = FolderReconcileSafeErrorSettlement.outcome(for: .folderAuthorizationRequired)
        XCTAssertEqual(outcome, .nonRetryableFailure(code: .folderAuthorizationRequired))
    }

    func testSafeErrorSettlementMapsEnumerationIncompleteToRetryable() {
        let outcome = FolderReconcileSafeErrorSettlement.outcome(for: .folderEnumerationIncomplete)
        XCTAssertEqual(outcome, .retryableFailure(code: .folderEnumerationIncomplete))
    }

    func testCheckpointRejectsMismatchedAttempt() {
        let checkpoint = FolderReconcileCheckpointV1(
            generation: 1,
            startedDirtyEpoch: 0,
            attempt: 2
        )
        XCTAssertFalse(
            FolderReconcileCheckpointCodec.validateAgainstJob(
                checkpoint,
                scanGeneration: 1,
                startedDirtyEpoch: 0,
                attempt: 1
            )
        )
    }

    func testPayloadRejectsUnknownFieldBeforeDirectoryAccess() {
        let payload: [String: Any] = [
            "contract_version": 1,
            "source_id": UUID().uuidString.lowercased(),
            "extra": true,
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let result = FolderReconcilePayloadValidation.validate(
            payloadVersion: 1,
            payload: data,
            jobSourceID: UUID()
        )
        XCTAssertEqual(result, .failure(.invalid(FolderReconcileSafeErrorCode.payloadInvalid)))
    }

    func testCheckpointRejectsExtraFields() {
        let json = """
        {"contract_version":1,"generation":1,"started_dirty_epoch":0,"attempt":1,
        "enumerated_entries":0,"candidate_files":0,"committed_assets":0,"ignored_entries":0,
        "unsupported_assets":0,"unreadable_assets":0,"identity_conflicts":0,"path":"x"}
        """
        XCTAssertThrowsError(try FolderReconcileCheckpointCodec.decode(Data(json.utf8)))
    }

    func testLeaseBoundHandlerSettlesWithoutCoordinatorDoubleSettle() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "contract")
        try fixture.writeFile(root: root, relativePath: "a/photo.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        let jobID = UUID()
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: jobID)

        let (handler, _) = FolderReconcileTestSupport.makeHandler(
            database: database,
            root: root,
            bookmark: bookmark,
            enumerationConfig: FolderEnumerationConfig(workUnitLimit: 32, assetBatchLimit: 32)
        )
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        let result = try XCTUnwrap(
            try coordinator.claimAndExecuteOnce(
                ClaimNextInput(owner: "worker", leaseDurationMs: FolderReconcileTestSupport.leaseDurationMs)
            )
        )
        XCTAssertTrue(result.handlerInvoked)
        XCTAssertEqual(result.snapshot.state, .completed)
        XCTAssertNil(result.snapshot.lastErrorCode?.rawValue)
    }

    func testFakeHandlerRegressionStillCoordinatorSettles() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let handler = FakeJobHandler(kind: JobTestSupport.testKind) { _, _, _ in
            JobHandlerExecutionResult(
                outcome: .completed,
                checkpoint: JobTestSupport.testCheckpoint,
                progress: JobProgress(completed: 1, total: 1)
            )
        }
        let coordinator = JobTestSupport.makeCoordinator(queue: queue, handlers: [handler])
        _ = try JobTestSupport.enqueueDefault(queue: queue)
        let result = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        XCTAssertEqual(result.snapshot.state, .completed)
        XCTAssertEqual(result.snapshot.checkpoint, JobTestSupport.testCheckpoint)
    }
}

private final class TestFolderEventStreamFactory: FolderFileSystemEventStreamFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var storedStopCount = 0
    private var callbacks: [@Sendable (FolderFileSystemEventBatch) -> Void] = []

    var stopCount: Int {
        lock.withLock { storedStopCount }
    }

    func start(
        rootURL: URL,
        onEventBatch: @escaping @Sendable (FolderFileSystemEventBatch) -> Void
    ) throws -> any FolderFileSystemEventStream {
        lock.withLock {
            callbacks.append(onEventBatch)
        }
        return TestFolderEventStream { [weak self] in
            self?.lock.withLock { self?.storedStopCount += 1 }
        }
    }

    func send(_ batch: FolderFileSystemEventBatch) {
        let captured = lock.withLock { callbacks }
        captured.forEach { $0(batch) }
    }
}

private final class TestFolderEventStream: FolderFileSystemEventStream, @unchecked Sendable {
    private let onStop: @Sendable () -> Void
    private let lock = NSLock()
    private var stopped = false

    init(onStop: @escaping @Sendable () -> Void) {
        self.onStop = onStop
    }

    func stop() {
        let shouldStop = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
        if shouldStop { onStop() }
    }
}

private final class LockedFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMessage: String?

    var message: String? { lock.withLock { storedMessage } }

    func record(_ error: Error) {
        lock.withLock { storedMessage = String(describing: error) }
    }
}
