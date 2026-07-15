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
