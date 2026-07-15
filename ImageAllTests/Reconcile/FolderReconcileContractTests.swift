import XCTest
@testable import ImageAll

final class FolderReconcileContractTests: XCTestCase {
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

        let handler = FolderReconcileHandler(
            rootAccess: FolderReconcileRootAccessAdapter(
                repository: GRDBFolderSourceAuthorizationRepository(database: database),
                bookmarkPort: FolderReconcileTestSupport.TestBookmarkPort(rootByBookmark: [bookmark: root])
            ),
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
