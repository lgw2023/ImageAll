import GRDB
import XCTest
@testable import ImageAll

/// Handoff 10.2 enumeration and path matrix.
final class FolderReconcileEnumerationMatrixTests: XCTestCase {
    func testRelativePathRejectionMatrix() {
        XCTAssertEqual(RelativePathRules.validate(""), .failure(.empty))
        XCTAssertEqual(RelativePathRules.validate("."), .failure(.invalidComponent))
        XCTAssertEqual(RelativePathRules.validate(".."), .failure(.invalidComponent))
        XCTAssertEqual(RelativePathRules.validate("a/../b"), .failure(.invalidComponent))
        XCTAssertEqual(RelativePathRules.validate("/abs"), .failure(.absolute))
        XCTAssertEqual(RelativePathRules.validate("a\0b"), .failure(.containsNUL))
    }

    func testHiddenAndPhotosLibraryVariantsIgnored() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "enum")
        _ = try fixture.writeFile(root: root, relativePath: ".hidden.png", contents: FolderReconcileTestSupport.minimalPNGData())
        _ = try fixture.writeFile(root: root, relativePath: "visible.png", contents: FolderReconcileTestSupport.minimalPNGData())
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Lib.PHOTOSLIBRARY"), withIntermediateDirectories: true)
        _ = try fixture.writeFile(root: root, relativePath: "Lib.PHOTOSLIBRARY/x.jpg", contents: FolderReconcileTestSupport.minimalJPEGData())
        let session = FolderDirectoryEnumerator(rootURL: root).makeSession()
        var paths: [String] = []
        while let entry = try session.nextEntry() {
            if case let .candidateFile(path, _) = entry { paths.append(path) }
        }
        XCTAssertEqual(paths, ["visible.png"])
    }

    func testWorkUnitAndBatchLimitsObservable() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "limits")
        for i in 0 ..< 7 {
            try fixture.writeFile(root: root, relativePath: "f\(i).png", contents: FolderReconcileTestSupport.minimalPNGData())
        }
        let config = FolderEnumerationConfig(workUnitLimit: 3, assetBatchLimit: 2)
        let session = FolderDirectoryEnumerator(rootURL: root, config: config).makeSession()
        var maxWorkBurst = 0
        var workBurst = 0
        while let _ = try session.nextEntry() {
            workBurst += 1
            if session.needsBoundaryFlush {
                maxWorkBurst = max(maxWorkBurst, workBurst)
                session.markBoundaryFlushed()
                workBurst = 0
            }
        }
        XCTAssertLessThanOrEqual(maxWorkBurst, config.workUnitLimit)
    }

    func testUnicodePathPreservedWithoutNormalization() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "unicode")
        let relative = "日本語/写真.png"
        try fixture.writeFile(root: root, relativePath: relative, contents: FolderReconcileTestSupport.minimalPNGData())
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
        let stored = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT relative_path FROM asset WHERE locator_state = 'current'")
        }
        XCTAssertEqual(stored, relative)
    }

    func testEnumerationIncompleteScopeStartStopPaired() throws {
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
        let injection = FolderEnumerationErrorInjection(resourceValueFailureRelativePaths: ["a.png"])
        let config = FolderEnumerationConfig(workUnitLimit: 256, assetBatchLimit: 256, errorInjection: injection)
        let (handler, port) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark, enumerationConfig: config)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        XCTAssertEqual(port.scopeStartCount, port.scopeStopCount)
        XCTAssertGreaterThan(port.scopeStartCount, 0)
    }
}
