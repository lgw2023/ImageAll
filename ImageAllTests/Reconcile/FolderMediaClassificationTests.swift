import XCTest
@testable import ImageAll

final class FolderMediaClassificationTests: XCTestCase {
    func testPNGAvailableAndSHAUnset() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "png")
        let file = try fixture.writeFile(root: root, relativePath: "x.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let result = FolderMediaClassifier().classify(fileURL: file, fileName: "x.png")
        guard case let .available(metadata) = result else {
            return XCTFail("expected available")
        }
        XCTAssertEqual(metadata.mediaType, "public.png")
        XCTAssertNotNil(metadata.width)
    }

    func testTextWithJPEGBytesIgnored() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "txt")
        let file = try fixture.writeFile(root: root, relativePath: "hidden.jpg.txt", contents: FolderReconcileTestSupport.minimalJPEGData())
        let result = FolderMediaClassifier().classify(fileURL: file, fileName: "hidden.jpg.txt")
        XCTAssertEqual(result, .ignored)
    }

    func testCorruptPNGUnreadable() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "bad")
        let file = try fixture.writeFile(
            root: root,
            relativePath: "bad.png",
            contents: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        )
        let result = FolderMediaClassifier().classify(fileURL: file, fileName: "bad.png")
        if case .available = result {
            XCTFail("corrupt png must not be available")
        }
    }

    func testScanLeavesSourceBytesUntouched() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "readonly")
        _ = try fixture.writeFile(root: root, relativePath: "photo.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let before = try fixture.snapshotTree(root: root)
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let handler = FolderReconcileHandler(
            rootAccess: FolderReconcileRootAccessAdapter(
                repository: GRDBFolderSourceAuthorizationRepository(database: database),
                bookmarkPort: FolderReconcileTestSupport.TestBookmarkPort(rootByBookmark: [bookmark: root])
            )
        )
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try XCTUnwrap(
            try coordinator.claimAndExecuteOnce(
                ClaimNextInput(owner: "worker", leaseDurationMs: FolderReconcileTestSupport.leaseDurationMs)
            )
        )
        let after = try fixture.snapshotTree(root: root)
        XCTAssertEqual(before, after)
    }
}
