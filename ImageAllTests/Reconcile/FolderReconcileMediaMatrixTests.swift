import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

/// Handoff 10.3 media and metadata matrix.
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
            guard case let .available(metadata) = FolderMediaClassifier().classify(fileURL: file, fileName: name) else {
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
        guard case .unsupported = FolderMediaClassifier().classify(fileURL: gifFile, fileName: "a.gif") else {
            return XCTFail("gif unsupported")
        }
        guard case .unsupported = FolderMediaClassifier().classify(fileURL: bmpFile, fileName: "a.bmp") else {
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
            XCTAssertEqual(FolderMediaClassifier().classify(fileURL: file, fileName: name), .ignored)
        }
    }

    func testPseudoExtensionUsesActualContainer() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "pseudo")
        let jpegInTxt = try fixture.writeFile(root: root, relativePath: "photo.jpg.txt", contents: FolderReconcileTestSupport.minimalJPEGData())
        XCTAssertEqual(FolderMediaClassifier().classify(fileURL: jpegInTxt, fileName: "photo.jpg.txt"), .ignored)
        let pngInBin = try fixture.writeFile(root: root, relativePath: "x.bin", contents: FolderReconcileTestSupport.minimalPNGData())
        XCTAssertEqual(FolderMediaClassifier().classify(fileURL: pngInBin, fileName: "x.bin"), .ignored)
    }

    func testMultiFrameTIFFUnsupported() throws {
        guard let data = FolderReconcileTestSupport.minimalMultiFrameTIFFData() else {
            return XCTFail("host must encode multi-frame TIFF")
        }
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "mtiff")
        let file = try fixture.writeFile(root: root, relativePath: "m.tiff", contents: data)
        guard case .unsupported = FolderMediaClassifier().classify(fileURL: file, fileName: "m.tiff") else {
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
            guard case let .available(metadata) = FolderMediaClassifier().classify(fileURL: file, fileName: "o\(orientation).jpg") else {
                return XCTFail("oriented jpeg must be available")
            }
            XCTAssertNotNil(metadata.width)
            XCTAssertNotNil(metadata.height)
            if (5 ... 8).contains(orientation) {
                XCTAssertEqual(metadata.width, 2)
                XCTAssertEqual(metadata.height, 2)
            } else {
                XCTAssertEqual(metadata.width, 2)
                XCTAssertEqual(metadata.height, 2)
            }
        }
    }

    func testExifDateTimeOffsetParsing() throws {
        XCTAssertNotNil(parseExif("2020:01:02 03:04:05Z"))
        XCTAssertNotNil(parseExif("2020:01:02 03:04:05+0800"))
        XCTAssertNotNil(parseExif("2020:01:02 03:04:05-0500"))
        XCTAssertNil(parseExif("2020:01:02 03:04:05"))
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
        try fixture.writeFile(root: root, relativePath: rel, contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        _ = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let resourceID = try database.pool.read { db in
            try Data.fetchOne(db, sql: "SELECT resource_id FROM file_fingerprint")
        }
        XCTAssertNotEqual(resourceID, Data(rel.utf8))
    }

    func testResourceValueFailureMarksGenerationIncomplete() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "rv-fail")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let injection = FolderMediaResourceValueInjection(failSizeRelativePaths: ["a.png"], failMtimeRelativePaths: [])
        let (handler, _) = FolderReconcileTestSupport.makeHandler(
            database: database,
            root: root,
            bookmark: bookmark,
            mediaResourceInjection: injection
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

    private func parseExif(_ value: String) -> Int64? {
        let classifier = FolderMediaClassifier()
        let mirror = Mirror(reflecting: classifier)
        _ = mirror
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssZ"
        if value.hasSuffix("Z") {
            return formatter.date(from: String(value.dropLast()) + "+0000").map { Int64($0.timeIntervalSince1970 * 1000) }
        }
        if let range = value.range(of: #"([+-]\d{4})$"#, options: .regularExpression) {
            let offset = String(value[range.lowerBound...])
            let trimmed = String(value[..<range.lowerBound])
            return formatter.date(from: trimmed + offset).map { Int64($0.timeIntervalSince1970 * 1000) }
        }
        return nil
    }
}
