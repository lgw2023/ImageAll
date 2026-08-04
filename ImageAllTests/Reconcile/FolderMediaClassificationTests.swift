import AVFoundation
import Darwin
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

final class FolderMediaClassificationTests: XCTestCase {
    func testProductionMOVMetadataAndPosterExtraction() async throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "production-mov")
        let file = root.appendingPathComponent("clip.mov")
        try await Self.writeSyntheticMOV(to: file)

        guard case let .available(metadata) = FolderMediaClassifier()
            .classify(fileURL: file, fileName: "clip.mov")
        else {
            return XCTFail("production AVFoundation reader must classify the synthetic MOV")
        }
        XCTAssertEqual(metadata.mediaKind, .video)
        XCTAssertEqual(metadata.mediaType, "com.apple.quicktime-movie")
        XCTAssertEqual(metadata.width, 64)
        XCTAssertEqual(metadata.height, 48)
        XCTAssertGreaterThan(metadata.durationMs ?? 0, 0)

        let fd = Darwin.open(file.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        let poster = try AVFoundationDerivedVideoPosterGenerator().makePosterBytes(
            sourceFileDescriptorURL: URL(fileURLWithPath: "/dev/fd/\(fd)"),
            mediaType: metadata.mediaType,
            durationMs: try XCTUnwrap(metadata.durationMs),
            maximumPixelSize: 512
        )
        XCTAssertEqual(
            FolderReconcileTestSupport.imageIOActualType(for: poster),
            UTType.png.identifier
        )
    }

    func testProductionVideoMetadataReaderDoesNotAccumulateFileDescriptors() async throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "video-fd-release")
        let original = root.appendingPathComponent("clip-0.mov")
        try await Self.writeSyntheticMOV(to: original)
        let copies = try (1 ... 12).map { index in
            let copy = root.appendingPathComponent("clip-\(index).mov")
            try FileManager.default.copyItem(at: original, to: copy)
            return copy
        }
        let reader = AVFoundationFolderVideoMetadataReader()
        XCTAssertNotNil(
            reader.metadata(
                fileURL: original,
                declaredType: "com.apple.quicktime-movie"
            )
        )
        let baseline = try Self.openFileDescriptorCount()

        for copy in copies {
            XCTAssertNotNil(
                reader.metadata(
                    fileURL: copy,
                    declaredType: "com.apple.quicktime-movie"
                )
            )
        }

        XCTAssertLessThanOrEqual(
            try Self.openFileDescriptorCount(),
            baseline + 2,
            "per-file AVURLAsset handles must be released before a long folder scan continues"
        )
    }

    func testMOVUsesVideoMetadataReaderAndBecomesAvailable() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "mov")
        let file = try fixture.writeFile(
            root: root,
            relativePath: "clip.mov",
            contents: Data("synthetic-video".utf8)
        )
        let reader = StubFolderVideoMetadataReader(
            result: FolderVideoMetadata(
                mediaType: "com.apple.quicktime-movie",
                width: 1_920,
                height: 1_080,
                durationMs: 12_345,
                mediaCreatedAtMs: nil
            )
        )

        guard case let .available(metadata) = FolderMediaClassifier(
            videoMetadataReader: reader
        ).classify(fileURL: file, fileName: "clip.mov") else {
            return XCTFail("MOV must be available when AV metadata is readable")
        }

        XCTAssertEqual(metadata.mediaKind, .video)
        XCTAssertEqual(metadata.mediaType, "com.apple.quicktime-movie")
        XCTAssertEqual(metadata.width, 1_920)
        XCTAssertEqual(metadata.height, 1_080)
        XCTAssertEqual(metadata.durationMs, 12_345)
        XCTAssertTrue(metadata.hasProvenFingerprint)
    }

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

    func testJPEGExtractsEmbeddedGPSWithoutMutatingFixture() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "jpeg-gps")
        let file = root.appendingPathComponent("gps.jpg")
        try Self.writeJPEGWithGPS(
            to: file,
            latitude: 31.2304,
            longitude: 121.4737
        )
        let before = try Data(contentsOf: file)

        guard case let .available(metadata) = FolderMediaClassifier()
            .classify(fileURL: file, fileName: "gps.jpg")
        else {
            return XCTFail("JPEG with GPS must remain a supported image")
        }

        XCTAssertEqual(metadata.location?.latitude ?? 0, 31.2304, accuracy: 0.000_001)
        XCTAssertEqual(metadata.location?.longitude ?? 0, 121.4737, accuracy: 0.000_001)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testTIFFAvailableFromEncodedFixture() throws {
        guard let data = FolderReconcileTestSupport.minimalTIFFData() else {
            return XCTFail("host must encode minimal TIFF fixture")
        }
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "tiff")
        let file = try fixture.writeFile(root: root, relativePath: "x.tiff", contents: data)
        guard case let .available(metadata) = FolderMediaClassifier().classify(fileURL: file, fileName: "x.tiff") else {
            return XCTFail("tiff must be available")
        }
        XCTAssertEqual(metadata.mediaType, UTType.tiff.identifier)
    }

    func testWebPAvailableFromStaticFixture() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "webp")
        let file = try fixture.writeFile(
            root: root,
            relativePath: "x.webp",
            contents: FolderReconcileTestSupport.minimalStaticWebPData
        )
        guard case let .available(metadata) = FolderMediaClassifier().classify(fileURL: file, fileName: "x.webp") else {
            return XCTFail("webp must be available from static fixture")
        }
        XCTAssertEqual(metadata.mediaType, UTType.webP.identifier)
    }

    func testHEICAvailableFromEncodedFixture() throws {
        guard let data = FolderReconcileTestSupport.minimalHEICData() else {
            return XCTFail("host must encode minimal HEIC fixture")
        }
        XCTAssertEqual(FolderReconcileTestSupport.imageIOActualType(for: data), UTType.heic.identifier)
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "heic")
        let file = try fixture.writeFile(root: root, relativePath: "x.heic", contents: data)
        guard case let .available(metadata) = FolderMediaClassifier().classify(fileURL: file, fileName: "x.heic") else {
            return XCTFail("heic must be available")
        }
        XCTAssertEqual(metadata.mediaType, UTType.heic.identifier)
    }

    func testHEIFAvailableFromStaticFixtureSeparateFromHEIC() throws {
        let data = FolderReconcileTestSupport.minimalHEIFData()
        XCTAssertEqual(FolderReconcileTestSupport.imageIOActualType(for: data), UTType.heif.identifier)
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "heif")
        let file = try fixture.writeFile(root: root, relativePath: "x.heif", contents: data)
        guard case let .available(metadata) = FolderMediaClassifier().classify(fileURL: file, fileName: "x.heif") else {
            return XCTFail("heif must be available from static fixture")
        }
        XCTAssertEqual(metadata.mediaType, UTType.heif.identifier)
        XCTAssertNotEqual(metadata.mediaType, UTType.heic.identifier)
    }

    func testStaticGIFAvailable() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "gif")
        let gif = Data([
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x21, 0xF9, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x4C, 0x01, 0x00, 0x3B,
        ])
        let file = try fixture.writeFile(root: root, relativePath: "static.gif", contents: gif)
        guard case let .available(metadata) = FolderMediaClassifier().classify(fileURL: file, fileName: "static.gif") else {
            return XCTFail("static gif must be available under ADR-041")
        }
        XCTAssertEqual(metadata.mediaType, UTType.gif.identifier)
    }

    func testPDFWithPDFExtensionIgnored() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "pdf")
        let file = try fixture.writeFile(root: root, relativePath: "doc.pdf", contents: Data("%PDF-1.4".utf8))
        XCTAssertEqual(FolderMediaClassifier().classify(fileURL: file, fileName: "doc.pdf"), .ignored)
    }

    func testScanPreservesDetailedSourceSnapshot() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "readonly")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        _ = try fixture.writeFile(root: root, relativePath: "subdir/photo.png", contents: FolderReconcileTestSupport.minimalPNGData())
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

    func testFolderReconcilePersistsEmbeddedGPSForWorldMap() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "world-map-gps")
        let file = root.appendingPathComponent("photo.jpg")
        try Self.writeJPEGWithGPS(to: file, latitude: -33.8688, longitude: 151.2093)
        let before = try fixture.snapshotDetailed(root: root)
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: bookmark
        )
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(
            queue: queue,
            sourceID: sourceID
        )
        let (handler, _) = FolderReconcileTestSupport.makeHandler(
            database: database,
            root: root,
            bookmark: bookmark
        )
        let coordinator = FolderReconcileTestSupport.makeCoordinator(
            queue: queue,
            handler: handler
        )

        XCTAssertEqual(
            try coordinator.claimAndExecuteOnce(
                ClaimNextInput(
                    owner: "world-map-gps",
                    leaseDurationMs: FolderReconcileTestSupport.leaseDurationMs
                )
            )?.snapshot.state,
            .completed
        )
        let row = try database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT latitude, longitude, source_kind FROM asset_location"
            )
        }
        XCTAssertEqual((row?["latitude"] as Double?) ?? 0, -33.8688, accuracy: 0.000_001)
        XCTAssertEqual((row?["longitude"] as Double?) ?? 0, 151.2093, accuracy: 0.000_001)
        XCTAssertEqual(row?["source_kind"] as String?, "embeddedGPS")
        XCTAssertEqual(try fixture.snapshotDetailed(root: root), before)
    }

    private static func writeSyntheticMOV(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 48,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 48,
            ]
        )
        guard writer.canAdd(input) else {
            throw NSError(domain: "FolderMediaClassificationTests", code: 1)
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "FolderMediaClassificationTests", code: 2)
        }
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            64,
            48,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "FolderMediaClassificationTests", code: 3)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, 0x7F, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        while !input.isReadyForMoreMediaData {
            await Task.yield()
        }
        guard adaptor.append(pixelBuffer, withPresentationTime: .zero),
              adaptor.append(
                  pixelBuffer,
                  withPresentationTime: CMTime(seconds: 1, preferredTimescale: 600)
              )
        else {
            throw writer.error ?? NSError(domain: "FolderMediaClassificationTests", code: 4)
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "FolderMediaClassificationTests", code: 5)
        }
    }

    private static func writeJPEGWithGPS(
        to url: URL,
        latitude: Double,
        longitude: Double
    ) throws {
        let sourceData = FolderReconcileTestSupport.minimalJPEGData()
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.jpeg.identifier as CFString,
                  1,
                  nil
              )
        else {
            throw NSError(domain: "FolderMediaClassificationTests", code: 10)
        }
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(latitude),
            kCGImagePropertyGPSLatitudeRef: latitude < 0 ? "S" : "N",
            kCGImagePropertyGPSLongitude: abs(longitude),
            kCGImagePropertyGPSLongitudeRef: longitude < 0 ? "W" : "E",
        ]
        CGImageDestinationAddImageFromSource(
            destination,
            source,
            0,
            [kCGImagePropertyGPSDictionary: gps] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "FolderMediaClassificationTests", code: 11)
        }
    }

    private static func openFileDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }
}

private struct StubFolderVideoMetadataReader: FolderVideoMetadataReading {
    let result: FolderVideoMetadata?

    func metadata(fileURL _: URL, declaredType _: String) -> FolderVideoMetadata? {
        result
    }
}
