import GRDB
import XCTest
@testable import ImageAll

final class FolderAssetIdentityTests: XCTestCase {
    func testContentRevisionAdvancesOnFingerprintChange() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "rev")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))

        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData() + Data([0xFF]))
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: UUID())
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w2", leaseDurationMs: 1000)))

        let revision = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT content_revision FROM asset WHERE source_id = ?", arguments: [sourceID.uuidString.lowercased()])
        }
        XCTAssertEqual(revision, 2)
    }

    func testMissingThenReappearCreatesNewAsset() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "missing")
        try fixture.writeFile(root: root, relativePath: "gone.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))

        let firstID = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM asset WHERE relative_path = 'gone.png' AND locator_state = 'current'")
        }

        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.png"))
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: UUID())
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w2", leaseDurationMs: 1000)))

        try fixture.writeFile(root: root, relativePath: "gone.png", contents: FolderReconcileTestSupport.minimalPNGData())
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: UUID())
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w3", leaseDurationMs: 1000)))

        let rows = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE relative_path = 'gone.png'")
        }
        XCTAssertEqual(rows, 2)
        let currentID = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM asset WHERE relative_path = 'gone.png' AND locator_state = 'current'")
        }
        XCTAssertNotEqual(firstID, currentID)
    }
}
