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
        try FolderReconcileTestSupport.seedActiveTag(database: database, assetID: first.id, label: "old-tag")
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.png"))
        _ = try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData() + Data([0xAA]))
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: UUID())
        _ = try runOnce(coordinator: coordinator, owner: "w2")
        let rows = try FolderReconcileTestSupport.fetchAssetRows(database: database, sourceID: sourceID)
        XCTAssertEqual(rows.filter { $0.locatorState == "historical" }.count, 1)
        XCTAssertEqual(rows.filter { $0.locatorState == "current" }.count, 1)
        XCTAssertNotEqual(rows.first { $0.locatorState == "current" }?.id, first.id)
        XCTAssertEqual(rows.first { $0.locatorState == "current" }?.contentRevision, 1)
        XCTAssertEqual(rows.first { $0.locatorState == "current" }?.tagCount, 0)
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

    func testMultipleMoveCandidatesRecordsConflictViaHandler() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "multi")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let (database, sourceID, coordinator, queue) = try makeScanHarness(fixture: fixture, label: "multi", root: root)
        _ = try runOnce(coordinator: coordinator)
        let primary = root.appendingPathComponent("a.png")
        try FileManager.default.linkItem(at: primary, to: root.appendingPathComponent("link.png"))
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: UUID())
        _ = try runOnce(coordinator: coordinator, owner: "w2")
        let moved = root.appendingPathComponent("moved/p.png")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: primary, to: moved)
        try FileManager.default.removeItem(at: root.appendingPathComponent("link.png"))
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: UUID())
        let result = try XCTUnwrap(try runOnce(coordinator: coordinator, owner: "w3"))
        let decoded = try FolderReconcileCheckpointCodec.decode(XCTUnwrap(result.snapshot.checkpoint?.data))
        XCTAssertGreaterThanOrEqual(decoded.identityConflicts, 1)
    }

    func testOldPathProbeErrorRecordsConflictViaHandler() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "probe")
        try fixture.writeFile(root: root, relativePath: "old/p.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try runOnce(coordinator: coordinator)
        let oldURL = root.appendingPathComponent("old/p.png")
        let newURL = root.appendingPathComponent("new/p.png")
        try FileManager.default.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        _ = try fixture.writeFile(root: root, relativePath: "old/p.png", contents: Data([0x00]))
        let reader = ProbeFailingFileResourceReader(failResourceIDFor: oldURL)
        let (handler2, _) = FolderReconcileTestSupport.makeHandler(
            database: database,
            root: root,
            bookmark: bookmark,
            fileResourceReader: reader
        )
        let coordinator2 = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler2)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: UUID())
        let result = try XCTUnwrap(try coordinator2.claimAndExecuteOnce(ClaimNextInput(owner: "w2", leaseDurationMs: 1000)))
        let decoded = try FolderReconcileCheckpointCodec.decode(XCTUnwrap(result.snapshot.checkpoint?.data))
        XCTAssertGreaterThanOrEqual(decoded.identityConflicts, 1)
    }

    func testUnsupportedAssetStoresFingerprintViaHandler() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "unsupported")
        let gif = Data([
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x21, 0xF9, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x4C, 0x01, 0x00, 0x3B,
        ])
        try fixture.writeFile(root: root, relativePath: "a.gif", contents: gif)
        let (database, sourceID, coordinator, _) = try makeScanHarness(fixture: fixture, label: "unsupported", root: root, relative: "a.gif")
        _ = try runOnce(coordinator: coordinator)
        let rows = try FolderReconcileTestSupport.fetchAssetRows(database: database, sourceID: sourceID)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].availability, "unsupported")
        XCTAssertNotNil(rows[0].sizeBytes)
        XCTAssertNotNil(rows[0].resourceID)
    }

    func testPriorResourceIDToNilSamePathMarksUnreadableConflict() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "id-nil")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let (database, sourceID, coordinator, queue) = try makeScanHarness(fixture: fixture, label: "id-nil", root: root)
        _ = try runOnce(coordinator: coordinator)
        let first = try FolderReconcileTestSupport.fetchAssetRows(database: database, sourceID: sourceID)
        XCTAssertEqual(first.count, 1)
        XCTAssertNotNil(first[0].resourceID)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: UUID())
        let (handler2, _) = FolderReconcileTestSupport.makeHandler(
            database: database,
            root: root,
            bookmark: root.path.data(using: .utf8)!,
            fileResourceReader: NilResourceIDFileResourceReader()
        )
        let coordinator2 = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler2)
        let result = try XCTUnwrap(try coordinator2.claimAndExecuteOnce(ClaimNextInput(owner: "w2", leaseDurationMs: 1000)))
        let decoded = try FolderReconcileCheckpointCodec.decode(XCTUnwrap(result.snapshot.checkpoint?.data))
        XCTAssertEqual(decoded.identityConflicts, 1)
        let after = try FolderReconcileTestSupport.fetchAssetRows(database: database, sourceID: sourceID)
        XCTAssertEqual(after.filter { $0.locatorState == "current" }.count, 1)
        let current = after.first { $0.locatorState == "current" }!
        XCTAssertEqual(current.id, first[0].id)
        XCTAssertEqual(current.relativePath, first[0].relativePath)
        XCTAssertEqual(current.contentRevision, first[0].contentRevision)
        XCTAssertEqual(current.sizeBytes, first[0].sizeBytes)
        XCTAssertEqual(current.modifiedAtNs, first[0].modifiedAtNs)
        XCTAssertEqual(current.resourceID, first[0].resourceID)
        XCTAssertEqual(current.availability, "unreadable")
        XCTAssertEqual(current.lastSeenGeneration, 2)
    }

    func testPriorNilResourceIDToIDSamePathMarksUnreadableConflict() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "nil-id")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler1, _) = FolderReconcileTestSupport.makeHandler(
            database: database,
            root: root,
            bookmark: bookmark,
            fileResourceReader: NilResourceIDFileResourceReader()
        )
        let coordinator1 = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler1)
        _ = try runOnce(coordinator: coordinator1)
        let first = try FolderReconcileTestSupport.fetchAssetRows(database: database, sourceID: sourceID)
        XCTAssertEqual(first.count, 1)
        XCTAssertNil(first[0].resourceID)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: UUID())
        let (handler2, _) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark)
        let coordinator2 = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler2)
        let result = try XCTUnwrap(try coordinator2.claimAndExecuteOnce(ClaimNextInput(owner: "w2", leaseDurationMs: 1000)))
        let decoded = try FolderReconcileCheckpointCodec.decode(XCTUnwrap(result.snapshot.checkpoint?.data))
        XCTAssertEqual(decoded.identityConflicts, 1)
        let after = try FolderReconcileTestSupport.fetchAssetRows(database: database, sourceID: sourceID)
        XCTAssertEqual(after.filter { $0.locatorState == "current" }.count, 1)
        let current = after.first { $0.locatorState == "current" }!
        XCTAssertEqual(current.id, first[0].id)
        XCTAssertEqual(current.relativePath, first[0].relativePath)
        XCTAssertEqual(current.contentRevision, first[0].contentRevision)
        XCTAssertEqual(current.sizeBytes, first[0].sizeBytes)
        XCTAssertEqual(current.modifiedAtNs, first[0].modifiedAtNs)
        XCTAssertNil(current.resourceID)
        XCTAssertEqual(current.availability, "unreadable")
        XCTAssertEqual(current.lastSeenGeneration, 2)
    }

    func testDuplicateObservationBatchViaCoordinatorIsIdempotent() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let (database, sourceID, coordinator, queue) = try makeScanHarness(fixture: fixture, label: "dup")
        _ = try runOnce(coordinator: coordinator)
        let first = try FolderReconcileTestSupport.fetchAssetRows(database: database, sourceID: sourceID)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: UUID())
        _ = try runOnce(coordinator: coordinator, owner: "w2")
        let second = try FolderReconcileTestSupport.fetchAssetRows(database: database, sourceID: sourceID)
        XCTAssertEqual(second.filter { $0.locatorState == "current" }.count, 1)
        XCTAssertEqual(second[0].id, first[0].id)
        XCTAssertEqual(second[0].contentRevision, 1)
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
