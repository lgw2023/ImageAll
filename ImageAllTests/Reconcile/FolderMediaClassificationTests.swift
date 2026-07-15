import UniformTypeIdentifiers
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
        guard case .unreadable = result else {
            return XCTFail("corrupt png must be unreadable, got \(result)")
        }
    }

    func testJPEGAvailable() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "jpeg")
        let file = try fixture.writeFile(root: root, relativePath: "x.jpg", contents: FolderReconcileTestSupport.minimalJPEGData())
        guard case let .available(metadata) = FolderMediaClassifier().classify(fileURL: file, fileName: "x.jpg") else {
            return XCTFail("jpeg must be available")
        }
        XCTAssertEqual(metadata.mediaType, UTType.jpeg.identifier)
    }

    func testTIFFAvailableWhenImageIOSupportsEncoding() throws {
        guard let data = FolderReconcileTestSupport.minimalTIFFData() else {
            throw XCTSkip("Image I/O cannot encode TIFF fixtures on this host")
        }
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "tiff")
        let file = try fixture.writeFile(root: root, relativePath: "x.tiff", contents: data)
        guard case let .available(metadata) = FolderMediaClassifier().classify(fileURL: file, fileName: "x.tiff") else {
            return XCTFail("tiff must be available when encodable")
        }
        XCTAssertEqual(metadata.mediaType, UTType.tiff.identifier)
    }

    func testWebPAvailableWhenImageIOSupportsEncoding() throws {
        guard let data = FolderReconcileTestSupport.minimalWebPData() else {
            throw XCTSkip("Image I/O cannot encode WebP fixtures on this host")
        }
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "webp")
        let file = try fixture.writeFile(root: root, relativePath: "x.webp", contents: data)
        guard case let .available(metadata) = FolderMediaClassifier().classify(fileURL: file, fileName: "x.webp") else {
            return XCTFail("webp must be available when encodable")
        }
        XCTAssertEqual(metadata.mediaType, UTType.webP.identifier)
    }

    func testHEICAvailableWhenImageIOSupportsEncoding() throws {
        guard let data = FolderReconcileTestSupport.minimalHEICData() else {
            throw XCTSkip("Image I/O cannot encode HEIC fixtures on this host")
        }
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "heic")
        let file = try fixture.writeFile(root: root, relativePath: "x.heic", contents: data)
        guard case .available = FolderMediaClassifier().classify(fileURL: file, fileName: "x.heic") else {
            return XCTFail("heic must be available when encodable")
        }
    }

    func testScanPreservesDetailedSourceSnapshot() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "readonly")
        _ = try fixture.writeFile(root: root, relativePath: "photo.png", contents: FolderReconcileTestSupport.minimalPNGData())
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
        _ = try XCTUnwrap(
            try coordinator.claimAndExecuteOnce(
                ClaimNextInput(owner: "worker", leaseDurationMs: FolderReconcileTestSupport.leaseDurationMs)
            )
        )
        let after = try fixture.snapshotDetailed(root: root)
        XCTAssertEqual(before, after)
    }
}
