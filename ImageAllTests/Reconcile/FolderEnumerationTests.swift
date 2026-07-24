import GRDB
import XCTest
@testable import ImageAll

final class FolderEnumerationTests: XCTestCase {
    func testRelativePathRulesRejectTraversal() {
        XCTAssertEqual(RelativePathRules.validate("../secret"), .failure(.invalidComponent))
        XCTAssertEqual(RelativePathRules.validate("a/../b"), .failure(.invalidComponent))
        XCTAssertEqual(RelativePathRules.validate("/abs"), .failure(.absolute))
    }

    func testStreamingBoundaryContinuesSameEnumeratorUntilExhausted() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "boundary")
        let limit = 5
        let totalFiles = limit * 2 + 3
        for index in 0 ..< totalFiles {
            try fixture.writeFile(root: root, relativePath: "f\(index).txt", contents: Data("x".utf8))
        }
        let config = FolderEnumerationConfig(workUnitLimit: limit, assetBatchLimit: limit)
        let session = FolderDirectoryEnumerator(rootURL: root, config: config).makeSession()
        var seen = 0
        while let _ = try session.nextEntry() {
            seen += 1
            if session.needsBoundaryFlush {
                session.markBoundaryFlushed()
            }
        }
        XCTAssertEqual(seen, totalFiles)
        XCTAssertTrue(session.isFinished)
        XCTAssertFalse(session.directoryHadError)
    }

    func testLargeDirectoryCompletesThroughHandler() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "large")
        let limit = 4
        let totalFiles = limit * 2 + 2
        for index in 0 ..< totalFiles {
            try fixture.writeFile(root: root, relativePath: "n\(index).txt", contents: Data("x".utf8))
        }
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(
            database: database,
            root: root,
            bookmark: bookmark,
            enumerationConfig: FolderEnumerationConfig(workUnitLimit: limit, assetBatchLimit: limit)
        )
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        let result = try XCTUnwrap(
            try coordinator.claimAndExecuteOnce(
                ClaimNextInput(owner: "worker", leaseDurationMs: FolderReconcileTestSupport.leaseDurationMs)
            )
        )
        XCTAssertEqual(result.snapshot.state, .completed)
        let checkpointData = try database.pool.read { db -> Data? in
            try Data.fetchOne(db, sql: "SELECT checkpoint FROM job WHERE source_id = ?", arguments: [sourceID.uuidString.lowercased()])
        }
        let decoded = try FolderReconcileCheckpointCodec.decode(XCTUnwrap(checkpointData))
        XCTAssertEqual(decoded.enumeratedEntries, totalFiles)
    }

    func testAllIgnoredStillProducesCheckpointBoundary() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "ignored")
        for index in 0 ..< 8 {
            try fixture.writeFile(root: root, relativePath: "n\(index).txt", contents: Data("x".utf8))
        }
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(
            database: database,
            root: root,
            bookmark: bookmark,
            enumerationConfig: FolderEnumerationConfig(workUnitLimit: 4, assetBatchLimit: 4)
        )
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try XCTUnwrap(
            try coordinator.claimAndExecuteOnce(
                ClaimNextInput(owner: "worker", leaseDurationMs: FolderReconcileTestSupport.leaseDurationMs)
            )
        )
        let checkpointData = try database.pool.read { db -> Data? in
            try Data.fetchOne(db, sql: "SELECT checkpoint FROM job WHERE source_id = ?", arguments: [sourceID.uuidString.lowercased()])
        }
        let decoded = try FolderReconcileCheckpointCodec.decode(XCTUnwrap(checkpointData))
        XCTAssertGreaterThanOrEqual(decoded.enumeratedEntries, 4)
    }

    func testHiddenFilesSkippedByEnumeration() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "hidden")
        _ = try fixture.writeFile(root: root, relativePath: ".secret.png", contents: FolderReconcileTestSupport.minimalPNGData())
        _ = try fixture.writeFile(root: root, relativePath: "visible.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let session = FolderDirectoryEnumerator(rootURL: root).makeSession()
        var paths: [String] = []
        while let entry = try session.nextEntry() {
            if case let .candidateFile(relativePath, _) = entry {
                paths.append(relativePath)
            }
        }
        XCTAssertEqual(paths, ["visible.png"])
    }

    func testUnicodeRelativePathPreservedThroughHandler() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "unicode")
        let relative = "日本語/写真.png"
        try fixture.writeFile(root: root, relativePath: relative, contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let stored = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT relative_path FROM asset WHERE locator_state = 'current'")
        }
        XCTAssertEqual(stored, relative)
    }

    func testSymlinkAndPackageIgnored() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "skip")
        let real = try fixture.writeFile(root: root, relativePath: "real.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let package = root.appendingPathComponent("Bundle.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        var candidates: [String] = []
        let session = FolderDirectoryEnumerator(rootURL: root).makeSession()
        while let entry = try session.nextEntry() {
            if case let .candidateFile(path, _) = entry { candidates.append(path) }
        }
        XCTAssertEqual(candidates, ["real.png"])
    }

    func testVideoAndNonImageFilesSkippedBeforeCandidate() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "nonimage")
        _ = try fixture.writeFile(
            root: root,
            relativePath: "keep.png",
            contents: FolderReconcileTestSupport.minimalPNGData()
        )
        _ = try fixture.writeFile(root: root, relativePath: "clip.mov", contents: Data("mov".utf8))
        _ = try fixture.writeFile(root: root, relativePath: "clip.mp4", contents: Data("mp4".utf8))
        _ = try fixture.writeFile(root: root, relativePath: "notes.txt", contents: Data("txt".utf8))
        var candidates: [String] = []
        var ignored = 0
        let session = FolderDirectoryEnumerator(rootURL: root).makeSession()
        while let entry = try session.nextEntry() {
            switch entry {
            case let .candidateFile(path, _):
                candidates.append(path)
            case .ignored:
                ignored += 1
            case .unsafeRelativePath:
                XCTFail("unexpected unsafe path")
            }
        }
        XCTAssertEqual(Set(candidates), ["keep.png"])
        XCTAssertGreaterThanOrEqual(ignored, 3)
    }

    func testPurgeRemovesVideoAssetsAndTagDecisionsOnly() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let sourceID = UUID()
        let imageID = UUID()
        let videoID = UUID()
        let tagID = UUID()
        let now = Int64(1_700_000_000_000)
        try FolderReconcileTestSupport.seedActiveFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: Data("bookmark".utf8)
        )
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, file_name, media_type, width, height,
                    media_created_at_ms, media_modified_at_ms, content_revision,
                    last_seen_generation, availability, record_created_at_ms, record_updated_at_ms
                ) VALUES
                (?, ?, 'file', 'keep.png', NULL, 'current', 'keep.png', 'public.jpeg',
                 10, 10, NULL, NULL, 1, 1, 'available', ?, ?),
                (?, ?, 'file', 'clip.mov', NULL, 'current', 'clip.mov', 'com.apple.quicktime-movie',
                 NULL, NULL, NULL, NULL, 1, 1, 'unsupported', ?, ?)
                """,
                arguments: [
                    imageID.uuidString.lowercased(), sourceID.uuidString.lowercased(), now, now,
                    videoID.uuidString.lowercased(), sourceID.uuidString.lowercased(), now, now,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms, group_id)
                VALUES (?, '家庭', '家庭', 'active', ?, ?, ?)
                """,
                arguments: [
                    tagID.uuidString.lowercased(),
                    now,
                    now,
                    TagGroupSeed.classify(displayName: "家庭").id.uuidString.lowercased(),
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'accepted', ?), (?, ?, 'accepted', ?)
                """,
                arguments: [
                    imageID.uuidString.lowercased(), tagID.uuidString.lowercased(), now,
                    videoID.uuidString.lowercased(), tagID.uuidString.lowercased(), now,
                ]
            )
        }

        let result = try CatalogExcludedVideoPurger.purge(in: database)
        XCTAssertEqual(result.removedAssetCount, 1)
        XCTAssertEqual(result.removedDecisionCount, 1)

        let remaining = try database.pool.read { db -> (Int, Int, Int) in
            let assets = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? -1
            let decisions = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tag_decision") ?? -1
            let videoLeft = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM asset WHERE id = ?",
                arguments: [videoID.uuidString.lowercased()]
            ) ?? -1
            return (assets, decisions, videoLeft)
        }
        XCTAssertEqual(remaining.0, 1)
        XCTAssertEqual(remaining.1, 1)
        XCTAssertEqual(remaining.2, 0)
    }

    func testScopeStartStopPairedOnSuccess() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "scope")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, bookmarkPort) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        XCTAssertEqual(bookmarkPort.scopeStartCount, 1)
        XCTAssertEqual(bookmarkPort.scopeStopCount, 1)
    }
}
