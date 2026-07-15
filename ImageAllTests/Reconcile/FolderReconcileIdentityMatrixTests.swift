import GRDB
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

/// Handoff 10.4 identity and asset-fact matrix.
final class FolderReconcileIdentityMatrixTests: XCTestCase {
    func testFirstScanCreatesCurrentAssetWithRevisionOne() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let (database, sourceID, coordinator, _) = try makeScanHarness(fixture: fixture, label: "first")
        _ = try runOnce(coordinator: coordinator)
        let rows = try FolderReconcileTestSupport.fetchAssetRows(database: database, sourceID: sourceID)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].locatorState, "current")
        XCTAssertEqual(rows[0].availability, "available")
        XCTAssertEqual(rows[0].contentRevision, 1)
        XCTAssertEqual(rows[0].lastSeenGeneration, 1)
        XCTAssertNotNil(rows[0].sizeBytes)
        XCTAssertNotNil(rows[0].modifiedAtNs)
        XCTAssertNil(rows[0].sha256)
    }

    func testIdempotentRescanRetainsAssetIDRevisionAndFingerprint() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let (database, sourceID, coordinator, queue) = try makeScanHarness(fixture: fixture, label: "idem")
        _ = try runOnce(coordinator: coordinator)
        let first = try FolderReconcileTestSupport.fetchAssetRows(database: database, sourceID: sourceID)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: UUID())
        _ = try runOnce(coordinator: coordinator, owner: "w2")
        let second = try FolderReconcileTestSupport.fetchAssetRows(database: database, sourceID: sourceID)
        XCTAssertEqual(second.filter { $0.locatorState == "current" }.count, 1)
        XCTAssertEqual(second[0].id, first[0].id)
        XCTAssertEqual(second[0].contentRevision, 1)
        XCTAssertEqual(second[0].sizeBytes, first[0].sizeBytes)
        XCTAssertEqual(second[0].resourceID, first[0].resourceID)
    }

    func testMoveReconnectPreservesAssetIDTagAndLocator() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "move")
        try fixture.writeFile(root: root, relativePath: "old/p.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let (database, sourceID, coordinator, queue) = try makeScanHarness(fixture: fixture, label: "move", root: root)
        _ = try runOnce(coordinator: coordinator)
        let before = try FolderReconcileTestSupport.fetchAssetRows(database: database, sourceID: sourceID)[0]
        try FolderReconcileTestSupport.seedActiveTag(database: database, assetID: before.id, label: "keep")
        let oldURL = root.appendingPathComponent("old/p.png")
        let newURL = root.appendingPathComponent("new/p.png")
        try FileManager.default.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: UUID())
        _ = try runOnce(coordinator: coordinator, owner: "w2")
        let rows = try FolderReconcileTestSupport.fetchAssetRows(database: database, sourceID: sourceID)
        XCTAssertEqual(rows.filter { $0.locatorState == "current" }.count, 1)
        let current = rows.first { $0.locatorState == "current" }!
        XCTAssertEqual(current.id, before.id)
        XCTAssertEqual(current.relativePath, "new/p.png")
        XCTAssertEqual(current.contentRevision, 1)
        XCTAssertEqual(current.tagCount, 1)
        XCTAssertEqual(current.resourceID, before.resourceID)
    }

    func testResourceIDChangeSamePathReplacesWithHistoricalLocator() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "replace")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let (database, sourceID, coordinator, queue) = try makeScanHarness(fixture: fixture, label: "replace", root: root)
        _ = try runOnce(coordinator: coordinator)
        let first = try FolderReconcileTestSupport.fetchAssetRows(database: database, sourceID: sourceID)[0]
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.png"))
        _ = try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData() + Data([0xAA]))
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: UUID())
        _ = try runOnce(coordinator: coordinator, owner: "w2")
        let rows = try FolderReconcileTestSupport.fetchAssetRows(database: database, sourceID: sourceID)
        XCTAssertEqual(rows.filter { $0.locatorState == "historical" }.count, 1)
        XCTAssertEqual(rows.filter { $0.locatorState == "current" }.count, 1)
        XCTAssertNotEqual(rows.first { $0.locatorState == "current" }?.id, first.id)
        XCTAssertEqual(rows.first { $0.locatorState == "current" }?.contentRevision, 1)
    }

    func testDualNilResourceIDRetainsAssetOnRescan() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "nil")
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        let obs = FolderReconcileAssetObservation(
            relativePath: "x.png", fileName: "x.png", mediaType: UTType.png.identifier,
            width: 2, height: 2, mediaCreatedAtMs: nil, availability: .available,
            sizeBytes: 10, modifiedAtNs: 20, resourceID: nil, movePathProbe: nil
        )
        _ = try repository.commitAssetBatch(
            FolderAssetBatchInput(
                lease: lease, sourceID: sourceID, generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch, checkpoint: begin.checkpoint,
                observations: [obs], leaseDurationMs: 1000, outcome: .continue
            )
        )
        let firstID = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM asset WHERE locator_state = 'current'")
        }
        _ = try repository.commitAssetBatch(
            FolderAssetBatchInput(
                lease: lease, sourceID: sourceID, generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch, checkpoint: begin.checkpoint,
                observations: [obs], leaseDurationMs: 1000, outcome: .continue
            )
        )
        let secondID = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM asset WHERE locator_state = 'current'")
        }
        XCTAssertEqual(firstID, secondID)
    }

    func testHardlinkAddsIdentityConflictAndSecondCurrentLocator() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "hardlink")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let (database, sourceID, coordinator, queue) = try makeScanHarness(fixture: fixture, label: "hardlink", root: root)
        _ = try runOnce(coordinator: coordinator)
        let primary = root.appendingPathComponent("a.png")
        try FileManager.default.linkItem(at: primary, to: root.appendingPathComponent("link.png"))
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: UUID())
        let result = try XCTUnwrap(try runOnce(coordinator: coordinator, owner: "w2"))
        let rows = try FolderReconcileTestSupport.fetchAssetRows(database: database, sourceID: sourceID)
        XCTAssertEqual(rows.filter { $0.locatorState == "current" }.count, 2)
        let decoded = try FolderReconcileCheckpointCodec.decode(XCTUnwrap(result.snapshot.checkpoint?.data))
        XCTAssertGreaterThanOrEqual(decoded.identityConflicts, 1)
    }

    private func makeScanHarness(
        fixture: FolderReconcileTestSupport.TempFixtureRoot,
        label: String,
        root: URL? = nil,
        relative: String = "a.png"
    ) throws -> (CatalogDatabase, UUID, JobExecutionCoordinator, GRDBJobQueue) {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let actualRoot = try root ?? fixture.makeRoot(label: label)
        if root == nil {
            try fixture.writeFile(root: actualRoot, relativePath: relative, contents: FolderReconcileTestSupport.minimalPNGData())
        }
        let bookmark = actualRoot.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(database: database, root: actualRoot, bookmark: bookmark)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        return (database, sourceID, coordinator, queue)
    }

    private func runOnce(coordinator: JobExecutionCoordinator, owner: String = "w") throws -> JobExecutionResult? {
        try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: owner, leaseDurationMs: 1000))
    }
}
