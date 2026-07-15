import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

/// Handoff 10.3 media and metadata matrix — production classifier paths only.
final class FolderReconcileMediaMatrixTests: XCTestCase {
    func testSixAllowedStaticFormatsAvailable() throws {
        let cases: [(String, String, Data)] = [
            ("a.jpg", "jpeg", FolderReconcileTestSupport.minimalJPEGData()),
            ("a.png", "png", FolderReconcileTestSupport.minimalPNGData()),
            ("a.heic", "heic", try XCTUnwrap(FolderReconcileTestSupport.minimalHEICData())),
            ("a.heif", "heif", FolderReconcileTestSupport.minimalHEIFData()),
            ("a.tiff", "tiff", try XCTUnwrap(FolderReconcileTestSupport.minimalTIFFData())),
            ("a.webp", "webp", FolderReconcileTestSupport.minimalStaticWebPData),
        ]
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "six")
        for (name, _, data) in cases {
            let file = try fixture.writeFile(root: root, relativePath: name, contents: data)
            guard case let .available(metadata) = FolderReconcileTestSupport.classifyMedia(at: file, fileName: name) else {
                return XCTFail("\(name) must be available")
            }
            XCTAssertTrue(metadata.hasProvenFingerprint)
        }
        XCTAssertEqual(FolderReconcileTestSupport.imageIOActualType(for: cases[3].2), UTType.heif.identifier)
        XCTAssertEqual(FolderReconcileTestSupport.imageIOActualType(for: cases[2].2), UTType.heic.identifier)
    }

    func testGIFAndBMPUnsupported() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "unsupported")
        let gif = Data([
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x21, 0xF9, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x4C, 0x01, 0x00, 0x3B,
        ])
        let bmp = try XCTUnwrap(FolderReconcileTestSupport.minimalBMPData())
        let gifFile = try fixture.writeFile(root: root, relativePath: "a.gif", contents: gif)
        let bmpFile = try fixture.writeFile(root: root, relativePath: "a.bmp", contents: bmp)
        guard case .unsupported = FolderReconcileTestSupport.classifyMedia(at: gifFile, fileName: "a.gif") else {
            return XCTFail("gif unsupported")
        }
        guard case .unsupported = FolderReconcileTestSupport.classifyMedia(at: bmpFile, fileName: "a.bmp") else {
            return XCTFail("bmp unsupported")
        }
    }

    func testPDFVideoTextIgnored() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "ignored")
        _ = try fixture.writeFile(root: root, relativePath: "d.pdf", contents: Data("%PDF-1.4".utf8))
        _ = try fixture.writeFile(root: root, relativePath: "v.mov", contents: Data([0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70]))
        _ = try fixture.writeFile(root: root, relativePath: "n.txt", contents: Data("hello".utf8))
        for name in ["d.pdf", "v.mov", "n.txt"] {
            let file = root.appendingPathComponent(name)
            XCTAssertEqual(FolderReconcileTestSupport.classifyMedia(at: file, fileName: name), .ignored)
        }
    }

    func testPseudoExtensionUsesActualContainer() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "pseudo")
        let pngInJpg = try fixture.writeFile(
            root: root,
            relativePath: "photo.jpg",
            contents: FolderReconcileTestSupport.minimalPNGData()
        )
        guard case let .available(metadata) = FolderReconcileTestSupport.classifyMedia(at: pngInJpg, fileName: "photo.jpg") else {
            return XCTFail(".jpg with PNG bytes must be available via actual container")
        }
        XCTAssertEqual(metadata.mediaType, UTType.png.identifier)

        let corruptJpg = try fixture.writeFile(
            root: root,
            relativePath: "bad.jpg",
            contents: Data([0xFF, 0xD8, 0xFF, 0x00])
        )
        guard case .unreadable = FolderReconcileTestSupport.classifyMedia(at: corruptJpg, fileName: "bad.jpg") else {
            return XCTFail("corrupt .jpg must be unreadable")
        }

        let jpegInTxt = try fixture.writeFile(
            root: root,
            relativePath: "photo.jpg.txt",
            contents: FolderReconcileTestSupport.minimalJPEGData()
        )
        XCTAssertEqual(FolderReconcileTestSupport.classifyMedia(at: jpegInTxt, fileName: "photo.jpg.txt"), .ignored)
    }

    func testMultiFrameTIFFUnsupported() throws {
        guard let data = FolderReconcileTestSupport.minimalMultiFrameTIFFData() else {
            return XCTFail("host must encode multi-frame TIFF")
        }
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "mtiff")
        let file = try fixture.writeFile(root: root, relativePath: "m.tiff", contents: data)
        guard case .unsupported = FolderReconcileTestSupport.classifyMedia(at: file, fileName: "m.tiff") else {
            return XCTFail("multi-frame tiff must be unsupported")
        }
    }

    func testOrientationLogicalDimensions() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "orient")
        for orientation in 1 ... 8 {
            guard let data = FolderReconcileTestSupport.minimalOrientedJPEGData(orientation: orientation) else {
                return XCTFail("host must encode oriented jpeg \(orientation)")
            }
            let file = try fixture.writeFile(root: root, relativePath: "o\(orientation).jpg", contents: data)
            guard case let .available(metadata) = FolderReconcileTestSupport.classifyMedia(at: file, fileName: "o\(orientation).jpg") else {
                return XCTFail("oriented jpeg must be available")
            }
            if (5 ... 8).contains(orientation) {
                XCTAssertEqual(metadata.width, 2, "orientation \(orientation) swaps width")
                XCTAssertEqual(metadata.height, 4, "orientation \(orientation) swaps height")
            } else {
                XCTAssertEqual(metadata.width, 4, "orientation \(orientation) keeps width")
                XCTAssertEqual(metadata.height, 2, "orientation \(orientation) keeps height")
            }
        }
    }

    func testExifDateTimeOffsetParsingViaClassifier() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "exif")
        let zData = try XCTUnwrap(FolderReconcileTestSupport.minimalExifJPEGData(
            dateTimeOriginal: "2020:01:02 03:04:05",
            offsetTimeOriginal: "+00:00"
        ))
        let plusData = try XCTUnwrap(FolderReconcileTestSupport.minimalExifJPEGData(
            dateTimeOriginal: "2020:01:02 03:04:05",
            offsetTimeOriginal: "+08:00"
        ))
        let minusData = try XCTUnwrap(FolderReconcileTestSupport.minimalExifJPEGData(
            dateTimeOriginal: "2020:01:02 03:04:05",
            offsetTimeOriginal: "-05:00"
        ))
        let noneData = try XCTUnwrap(FolderReconcileTestSupport.minimalExifJPEGData(dateTimeOriginal: "2020:01:02 03:04:05"))
        let cases: [(String, Data)] = [
            ("z.jpg", zData),
            ("plus.jpg", plusData),
            ("minus.jpg", minusData),
            ("none.jpg", noneData),
        ]
        for (name, data) in cases {
            let file = try fixture.writeFile(root: root, relativePath: name, contents: data)
            guard case let .available(metadata) = FolderReconcileTestSupport.classifyMedia(at: file, fileName: name) else {
                return XCTFail("\(name) must be available")
            }
            switch name {
            case "z.jpg":
                XCTAssertNotNil(metadata.mediaCreatedAtMs)
            case "plus.jpg", "minus.jpg":
                XCTAssertNotNil(metadata.mediaCreatedAtMs)
            case "none.jpg":
                XCTAssertNil(metadata.mediaCreatedAtMs)
            default:
                XCTFail("unexpected case")
            }
        }
    }

    func testDatabaseSHA256RemainsNullAfterScan() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "sha")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let sha = try database.pool.read { db in
            try Data.fetchOne(db, sql: "SELECT sha256 FROM file_fingerprint")
        }
        XCTAssertNil(sha)
    }

    func testResourceIDIsNotPathDerived() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "rid")
        let rel = "folder/photo.png"
        let fileURL = try fixture.writeFile(root: root, relativePath: rel, contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let resourceID = try XCTUnwrap(try database.pool.read { db in
            try Data.fetchOne(db, sql: "SELECT resource_id FROM file_fingerprint")
        })
        XCTAssertNotEqual(resourceID, Data(rel.utf8))
        XCTAssertNotEqual(resourceID, Data(fileURL.path.utf8))
    }

    func testResourceValueFailureMarksGenerationIncomplete() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "rv-fail")
        let fileURL = try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let reader = FailingFileResourceReader(failSizeFor: fileURL)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(
            database: database,
            root: root,
            bookmark: bookmark,
            fileResourceReader: reader
        )
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        let result = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        XCTAssertEqual(result.snapshot.state, .retryableFailed)
        XCTAssertEqual(result.snapshot.lastErrorCode, .folderEnumerationIncomplete)
        let count = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset")
        }
        XCTAssertEqual(count, 0)
    }
}
