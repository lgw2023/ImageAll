import XCTest
@testable import ImageAll

final class FolderEnumerationTests: XCTestCase {
    func testRelativePathRulesRejectTraversal() {
        XCTAssertEqual(RelativePathRules.validate("../secret"), .failure(.invalidComponent))
        XCTAssertEqual(RelativePathRules.validate("a/../b"), .failure(.invalidComponent))
        XCTAssertEqual(RelativePathRules.validate("/abs"), .failure(.absolute))
    }

    func testStreamingBoundaryDoesNotExceedInjectedLimit() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "boundary")
        for index in 0 ..< 20 {
            try fixture.writeFile(root: root, relativePath: "f\(index).txt", contents: Data("x".utf8))
        }
        let config = FolderEnumerationConfig(workUnitLimit: 5, assetBatchLimit: 5)
        let enumerator = FolderDirectoryEnumerator(rootURL: root, config: config)
        var seen = 0
        let (_, finished) = try enumerator.enumerate { _ in seen += 1 }
        XCTAssertEqual(seen, 5)
        XCTAssertFalse(finished)
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
        let handler = FolderReconcileHandler(
            rootAccess: FolderReconcileRootAccessAdapter(
                repository: GRDBFolderSourceAuthorizationRepository(database: database),
                bookmarkPort: FolderReconcileTestSupport.TestBookmarkPort(rootByBookmark: [bookmark: root])
            ),
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
        let enumerator = FolderDirectoryEnumerator(rootURL: root)
        _ = try enumerator.enumerate { entry in
            if case let .candidateFile(path, _) = entry { candidates.append(path) }
        }
        XCTAssertEqual(candidates, ["real.png"])
    }
}
