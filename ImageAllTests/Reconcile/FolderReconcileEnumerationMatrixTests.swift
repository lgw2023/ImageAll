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

    func testHiddenNestedPhotosLibraryAndSpecialFilesIgnored() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "enum")
        _ = try fixture.writeFile(root: root, relativePath: ".hidden.png", contents: FolderReconcileTestSupport.minimalPNGData())
        _ = try fixture.writeFile(root: root, relativePath: "visible.png", contents: FolderReconcileTestSupport.minimalPNGData())
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Lib.PHOTOSLIBRARY"), withIntermediateDirectories: true)
        _ = try fixture.writeFile(root: root, relativePath: "Lib.PHOTOSLIBRARY/x.jpg", contents: FolderReconcileTestSupport.minimalJPEGData())
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested/Case.PhotosLibrary"), withIntermediateDirectories: true)
        _ = try fixture.writeFile(root: root, relativePath: "nested/Case.PhotosLibrary/y.jpg", contents: FolderReconcileTestSupport.minimalJPEGData())
        let fifo = root.appendingPathComponent("pipe.fifo")
        try ShellFixtureSupport.makeFIFO(at: fifo)
        let socketPath = root.appendingPathComponent("sock.socket")
        try ShellFixtureSupport.makeUnixSocket(at: socketPath)
        let symlink = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root.appendingPathComponent("visible.png"))
        let session = FolderDirectoryEnumerator(rootURL: root).makeSession()
        var paths: [String] = []
        while let entry = try session.nextEntry() {
            if case let .candidateFile(path, _) = entry { paths.append(path) }
        }
        XCTAssertEqual(paths, ["visible.png"])
    }

    func testCombiningMarkPathPreservedWithoutNormalization() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "unicode")
        let nfdName = "caf\u{0065}\u{0301}.png"
        let nfcName = "caf\u{00E9}.png"
        XCTAssertNotEqual(Array(nfdName.unicodeScalars), Array(nfcName.unicodeScalars))
        try fixture.writeFile(root: root, relativePath: nfdName, contents: FolderReconcileTestSupport.minimalPNGData())
        let session = FolderDirectoryEnumerator(rootURL: root).makeSession()
        var enumeratedPath: String?
        while let entry = try session.nextEntry() {
            if case let .candidateFile(path, _) = entry {
                enumeratedPath = path
            }
        }
        let actualPath = try XCTUnwrap(enumeratedPath)
        let expectedScalars = Array(actualPath.unicodeScalars)
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
        let storedPath = try XCTUnwrap(stored)
        XCTAssertEqual(Array(storedPath.unicodeScalars), expectedScalars)
    }

    func testHandlerBatchSpyRespectsWorkUnitAndAssetBatchLimits() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "limits")
        for i in 0 ..< 5 {
            try fixture.writeFile(root: root, relativePath: "p\(i).png", contents: FolderReconcileTestSupport.minimalPNGData())
        }
        for i in 0 ..< 8 {
            try fixture.writeFile(root: root, relativePath: "note\(i).txt", contents: Data("x".utf8))
        }
        let config = FolderEnumerationConfig(workUnitLimit: 3, assetBatchLimit: 2)
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let spy = RecordingReconcileBatchPort(queue: queue)
        let sourceID = UUID()
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(
            database: database,
            root: root,
            bookmark: bookmark,
            enumerationConfig: config
        )
        let coordinator = FolderReconcileTestSupport.makeCoordinator(
            queue: queue,
            handler: handler,
            leaseContextProvider: SpyJobLeaseContextProvider(queue: queue, batchPort: spy)
        )
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        XCTAssertFalse(spy.committedBatchSizes.isEmpty)
        XCTAssertTrue(spy.committedBatchSizes.allSatisfy { $0 <= config.assetBatchLimit })
        XCTAssertTrue(spy.committedBatchSizes.contains(0), "ignored-only work-unit boundaries must flush empty batches")
    }

    func testRootInvalidationDuringScanMarksIncompleteWithPairedScope() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "root-inval")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let validator = FolderRootValidator(resourceReader: FlippingFolderRootResourceReader(failAfterCall: 1))
        let (handler, port) = FolderReconcileTestSupport.makeHandler(
            database: database,
            root: root,
            bookmark: bookmark,
            rootValidator: validator
        )
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        let result = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        XCTAssertEqual(result.snapshot.state, .retryableFailed)
        XCTAssertEqual(result.snapshot.lastErrorCode, .folderEnumerationIncomplete)
        XCTAssertEqual(port.scopeStartCount, port.scopeStopCount)
    }

    func testEnumerationResourceFailureMarksIncompleteWithPairedScope() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "scope")
        let fileURL = try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let reader = FailingEnumerationResourceReader(failFor: fileURL)
        let (handler, port) = FolderReconcileTestSupport.makeHandler(
            database: database,
            root: root,
            bookmark: bookmark,
            enumerationResourceReader: reader
        )
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        XCTAssertEqual(port.scopeStartCount, port.scopeStopCount)
        XCTAssertGreaterThan(port.scopeStartCount, 0)
    }
}

enum ShellFixtureSupport {
    static func makeFIFO(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try runShell("mkfifo", url.path)
    }

    static func makeUnixSocket(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try runShell("python3", "-c", "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()", url.path)
    }

    private static func runShell(_ launchPath: String, _ args: String...) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath == "python3" ? "/usr/bin/python3" : "/usr/bin/\(launchPath)")
        if launchPath == "python3" {
            process.arguments = Array(args)
        } else {
            process.arguments = args
        }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
