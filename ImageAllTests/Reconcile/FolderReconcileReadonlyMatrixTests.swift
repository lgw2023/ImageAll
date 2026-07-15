import GRDB
import XCTest
@testable import ImageAll

/// Handoff 10.6 readonly snapshot matrix across representative paths.
final class FolderReconcileReadonlyMatrixTests: XCTestCase {
    func testSuccessScanPreservesTreeBytesAndMetadata() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "ok")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        _ = try fixture.writeFile(root: root, relativePath: "empty/a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let before = try fixture.snapshotDetailed(root: root)
        try assertScanPreserves(root: root, before: before)
    }

    func testCorruptClassificationPreservesSourceTree() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "corrupt")
        _ = try fixture.writeFile(root: root, relativePath: "bad.png", contents: Data([0x89, 0x50, 0x4E, 0x47]))
        let before = try fixture.snapshotDetailed(root: root)
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
        XCTAssertEqual(try fixture.snapshotDetailed(root: root), before)
    }

    func testEnumerationIncompletePreservesSourceTree() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "incomplete")
        _ = try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let before = try fixture.snapshotDetailed(root: root)
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let fileURL = root.appendingPathComponent("a.png")
        let (handler, _) = FolderReconcileTestSupport.makeHandler(
            database: database,
            root: root,
            bookmark: bookmark,
            enumerationResourceReader: FailingEnumerationResourceReader(failFor: fileURL)
        )
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        XCTAssertEqual(try fixture.snapshotDetailed(root: root), before)
    }

    func testCancelFinalPreservesSourceTree() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "cancel")
        _ = try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let before = try fixture.snapshotDetailed(root: root)
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        let jobID = UUID()
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: jobID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        try database.pool.write { db in
            try db.execute(sql: "UPDATE source SET state = 'disabled' WHERE id = ?", arguments: [sourceID.uuidString.lowercased()])
            try db.execute(sql: "UPDATE job SET control_request = 'cancel' WHERE id = ?", arguments: [jobID.uuidString.lowercased()])
        }
        _ = try repository.completeGeneration(
            FolderCompleteGenerationInput(
                lease: lease, sourceID: sourceID, generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch, checkpoint: begin.checkpoint, leaseDurationMs: 1000
            )
        )
        XCTAssertEqual(try fixture.snapshotDetailed(root: root), before)
    }

    private func assertScanPreserves(root: URL, before: [String: FolderReconcileTestSupport.TempFixtureRoot.FileSnapshot]) throws {
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
        XCTAssertEqual(try snapshotDetailed(root: root), before)
    }

    private func snapshotDetailed(root: URL) throws -> [String: FolderReconcileTestSupport.TempFixtureRoot.FileSnapshot] {
        let helper = FolderReconcileTestSupport.TempFixtureRoot()
        return try helper.snapshotDetailed(root: root)
    }
}
