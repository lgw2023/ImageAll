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

    func testRescanWithoutChangesRetainsRevision() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "idem")
        try fixture.writeFile(root: root, relativePath: "stable.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))

        let assetID = try XCTUnwrap(try database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT id FROM asset WHERE source_id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            )
        })
        let placeID = "manual-place"
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO place (
                    id, canonical_name, subtitle, latitude, longitude, kind,
                    created_at_ms, updated_at_ms
                ) VALUES (?, 'Manual place', NULL, 31.2304, 121.4737, 'city', 7, 7)
                """,
                arguments: [placeID]
            )
            try db.execute(
                sql: """
                UPDATE asset_location SET
                    latitude = 31.2304,
                    longitude = 121.4737,
                    source_kind = 'placeTag',
                    updated_at_ms = 7,
                    place_id = ?
                WHERE asset_id = ?
                """,
                arguments: [placeID, assetID]
            )
        }

        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: UUID())
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w2", leaseDurationMs: 1000)))

        let count = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE source_id = ?", arguments: [sourceID.uuidString.lowercased()])
        }
        XCTAssertEqual(count, 1)
        let revision = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT content_revision FROM asset WHERE source_id = ?", arguments: [sourceID.uuidString.lowercased()])
        }
        XCTAssertEqual(revision, 1)
        let location = try database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT latitude, longitude, source_kind, updated_at_ms, place_id
                FROM asset_location WHERE asset_id = ?
                """,
                arguments: [assetID]
            )
        }
        XCTAssertEqual(location?["latitude"] as Double?, 31.2304)
        XCTAssertEqual(location?["longitude"] as Double?, 121.4737)
        XCTAssertEqual(location?["source_kind"] as String?, "placeTag")
        XCTAssertEqual(location?["updated_at_ms"] as Int64?, 7)
        XCTAssertEqual(location?["place_id"] as String?, placeID)
    }

    func testMoveReconnectPreservesAssetIdentity() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "move")
        let oldURL = try fixture.writeFile(root: root, relativePath: "old/photo.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))

        let assetID = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM asset WHERE relative_path = 'old/photo.png' AND locator_state = 'current'")
        }
        XCTAssertNotNil(assetID)

        let newURL = root.appendingPathComponent("new/photo.png")
        try FileManager.default.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: oldURL, to: newURL)

        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: UUID())
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w2", leaseDurationMs: 1000)))

        let rows = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE source_id = ?", arguments: [sourceID.uuidString.lowercased()])
        }
        XCTAssertEqual(rows, 1)
        let current = try database.pool.read { db in
            try Row.fetchOne(db, sql: "SELECT id, relative_path FROM asset WHERE locator_state = 'current'")
        }
        XCTAssertEqual(current?["id"] as? String, assetID)
        XCTAssertEqual(current?["relative_path"] as? String, "new/photo.png")
    }

    func testHardlinkAtOldPathCountsConflict() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "hardlink")
        let primary = try fixture.writeFile(root: root, relativePath: "primary.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))

        let linkURL = root.appendingPathComponent("link.png")
        try FileManager.default.linkItem(at: primary, to: linkURL)

        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: UUID())
        let result = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w2", leaseDurationMs: 1000)))

        let currentCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE locator_state = 'current'")
        }
        XCTAssertEqual(currentCount, 2)
        let decoded = try FolderReconcileCheckpointCodec.decode(XCTUnwrap(result.snapshot.checkpoint?.data))
        XCTAssertGreaterThanOrEqual(decoded.identityConflicts, 1)
    }
}
