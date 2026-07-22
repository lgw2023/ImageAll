import CoreGraphics
import CryptoKit
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

final class DerivedImageRenderingTests: XCTestCase {
    private let renderer = DerivedImageRenderer()
    private typealias Fixtures = DerivedImageTestSupport.DerivedImageRenderingTestFixtures

    private func assertFormatGenerates(expectedUTI: String, sourceData: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Fixtures.canonicalUTI(for: sourceData), expectedUTI, file: file, line: line)
        let artifact = try renderer.render(sourceBytes: sourceData, variant: .gridSmall)
        try Fixtures.assertArtifactSelfConsistent(artifact, file: file, line: line)
        XCTAssertEqual(artifact.pixelWidth, 256, file: file, line: line)
        XCTAssertEqual(artifact.pixelHeight, 256, file: file, line: line)
    }

    func testStaticJPEGInputGeneratesConsistentArtifact() throws {
        let data = try Fixtures.requireEncodedData(uti: UTType.jpeg.identifier)
        try assertFormatGenerates(expectedUTI: UTType.jpeg.identifier, sourceData: data)
    }

    func testStaticPNGInputGeneratesConsistentArtifact() throws {
        let data = try Fixtures.requireEncodedData(uti: UTType.png.identifier)
        try assertFormatGenerates(expectedUTI: UTType.png.identifier, sourceData: data)
    }

    func testStaticHEICInputGeneratesConsistentArtifact() throws {
        guard let data = FolderReconcileTestSupport.minimalHEICData(), !data.isEmpty else {
            return XCTFail("host must encode HEIC")
        }
        try assertFormatGenerates(expectedUTI: UTType.heic.identifier, sourceData: data)
    }

    func testStaticHEIFInputGeneratesConsistentArtifact() throws {
        let data = FolderReconcileTestSupport.minimalHEIFData()
        XCTAssertFalse(data.isEmpty)
        try assertFormatGenerates(expectedUTI: UTType.heif.identifier, sourceData: data)
    }

    func testStaticTIFFInputGeneratesConsistentArtifact() throws {
        guard let data = FolderReconcileTestSupport.minimalTIFFData(), !data.isEmpty else {
            return XCTFail("host must encode TIFF")
        }
        try assertFormatGenerates(expectedUTI: UTType.tiff.identifier, sourceData: data)
    }

    func testStaticWebPInputGeneratesConsistentArtifact() throws {
        let data = FolderReconcileTestSupport.minimalWebPData()
        XCTAssertFalse(data.isEmpty)
        try assertFormatGenerates(expectedUTI: UTType.webP.identifier, sourceData: data)
    }

    func testOrientationOneThroughEightPreserveQuadrantVisualPixels() throws {
        let rawWidth = 80
        let rawHeight = 40
        let quadrantImage = Fixtures.makeQuadrantImage(width: rawWidth, height: rawHeight)
        let red = Fixtures.RGBA(r: 255, g: 0, b: 0, a: 255)
        let green = Fixtures.RGBA(r: 0, g: 255, b: 0, a: 255)
        let blue = Fixtures.RGBA(r: 0, g: 0, b: 255, a: 255)
        let yellow = Fixtures.RGBA(r: 255, g: 255, b: 0, a: 255)
        let expectedCornersByOrientation: [Int: [Fixtures.RGBA]] = [
            1: [red, green, blue, yellow],
            2: [green, red, yellow, blue],
            3: [yellow, blue, green, red],
            4: [blue, yellow, red, green],
            5: [red, blue, green, yellow],
            6: [blue, red, yellow, green],
            7: [yellow, green, blue, red],
            8: [green, yellow, red, blue],
        ]

        try Fixtures.probePNGOrientationRoundTrip(width: rawWidth, height: rawHeight)

        let baselineSource = try Fixtures.pngData(from: quadrantImage, orientation: 1)
        guard let baselineOrientation = Fixtures.sourceOrientation(for: baselineSource) else {
            XCTFail("orientation 1 PNG baseline must expose ImageIO orientation property")
            return
        }
        XCTAssertEqual(baselineOrientation, 1, "orientation 1 PNG baseline property")
        let rawBaselineImage = try Fixtures.decodeRawImageWithoutOrientationTransform(from: baselineSource)
        try Fixtures.assertInteriorQuadrantCornersMatch(
            image: rawBaselineImage,
            width: rawWidth,
            height: rawHeight,
            expected: [red, green, blue, yellow],
            context: "orientation 1 raw baseline"
        )

        let cornerLabels = ["TL", "TR", "BL", "BR"]
        for orientation in 1 ... 8 {
            let source = try Fixtures.pngData(from: quadrantImage, orientation: orientation)
            guard let readOrientation = Fixtures.sourceOrientation(for: source) else {
                XCTFail("PNG orientation \(orientation) must round-trip via ImageIO properties")
                return
            }
            XCTAssertEqual(readOrientation, orientation, "orientation \(orientation)")

            let artifact = try renderer.render(sourceBytes: source, variant: .preview)
            let image = try Fixtures.decodeImage(from: artifact)
            let displayWidth = artifact.pixelWidth
            let displayHeight = artifact.pixelHeight
            if (5 ... 8).contains(orientation) {
                XCTAssertEqual(displayWidth, rawHeight, "orientation \(orientation)")
                XCTAssertEqual(displayHeight, rawWidth, "orientation \(orientation)")
            } else {
                XCTAssertEqual(displayWidth, rawWidth, "orientation \(orientation)")
                XCTAssertEqual(displayHeight, rawHeight, "orientation \(orientation)")
            }

            let samplePoints: [(Int, Int)] = [
                (displayWidth / 4, displayHeight / 4),
                (displayWidth * 3 / 4, displayHeight / 4),
                (displayWidth / 4, displayHeight * 3 / 4),
                (displayWidth * 3 / 4, displayHeight * 3 / 4),
            ]
            let expectedCorners = try XCTUnwrap(expectedCornersByOrientation[orientation], "orientation \(orientation)")
            for (index, point) in samplePoints.enumerated() {
                let actual = try Fixtures.rgbaPixel(in: image, x: point.0, y: point.1)
                Fixtures.assertColorsClose(
                    actual,
                    expectedCorners[index],
                    tolerance: 48,
                    message: "orientation \(orientation) corner \(cornerLabels[index])",
                    file: #filePath,
                    line: #line
                )
            }
        }
    }

    func testGridSmallCenterAspectFillPreservesSymmetricStripeCrop() throws {
        let source = try Fixtures.jpegData(from: Fixtures.makeHorizontalStripeImage(width: 400, height: 200))
        let artifact = try renderer.render(sourceBytes: source, variant: .gridSmall)
        XCTAssertEqual(artifact.pixelWidth, 256)
        XCTAssertEqual(artifact.pixelHeight, 256)
        let image = try Fixtures.decodeImage(from: artifact)
        let left = try Fixtures.rgbaPixel(in: image, x: 8, y: 128)
        let right = try Fixtures.rgbaPixel(in: image, x: 247, y: 128)
        XCTAssertGreaterThan(left.r, left.b + 40)
        XCTAssertGreaterThan(right.b, right.r + 40)
    }

    func testGridRegularCenterAspectFillPreservesSymmetricStripeCrop() throws {
        let source = try Fixtures.jpegData(from: Fixtures.makeHorizontalStripeImage(width: 400, height: 200))
        let artifact = try renderer.render(sourceBytes: source, variant: .gridRegular)
        XCTAssertEqual(artifact.pixelWidth, 512)
        XCTAssertEqual(artifact.pixelHeight, 512)
        let image = try Fixtures.decodeImage(from: artifact)
        let left = try Fixtures.rgbaPixel(in: image, x: 16, y: 256)
        let right = try Fixtures.rgbaPixel(in: image, x: 495, y: 256)
        XCTAssertGreaterThan(left.r, left.b + 40)
        XCTAssertGreaterThan(right.b, right.r + 40)
    }

    func testGridUpscalesSmallSourceToExactSquareWithoutLetterbox() throws {
        let source = try Fixtures.jpegData(from: Fixtures.makeSolidImage(
            width: 32,
            height: 32,
            rgba: Fixtures.RGBA(r: 180, g: 40, b: 200, a: 255)
        ))
        let artifact = try renderer.render(sourceBytes: source, variant: .gridSmall)
        XCTAssertEqual(artifact.pixelWidth, 256)
        XCTAssertEqual(artifact.pixelHeight, 256)
        let image = try Fixtures.decodeImage(from: artifact)
        let center = try Fixtures.rgbaPixel(in: image, x: 128, y: 128)
        XCTAssertGreaterThan(center.r, 100)
        XCTAssertGreaterThan(center.b, 100)
        let corner = try Fixtures.rgbaPixel(in: image, x: 4, y: 4)
        XCTAssertGreaterThan(Int(corner.r) + Int(corner.g) + Int(corner.b), 0)
    }

    func testPreviewLandscapeLongEdgeReaches2048WithoutUpscale() throws {
        let source = try Fixtures.jpegData(from: Fixtures.makeSolidImage(
            width: 3000,
            height: 1500,
            rgba: Fixtures.RGBA(r: 50, g: 100, b: 150, a: 255)
        ))
        let artifact = try renderer.render(sourceBytes: source, variant: .preview)
        XCTAssertEqual(max(artifact.pixelWidth, artifact.pixelHeight), 2048)
        XCTAssertEqual(artifact.pixelWidth, 2048)
        XCTAssertEqual(artifact.pixelHeight, 1024)
    }

    func testPreviewPortraitLongEdgeReaches2048WithoutUpscale() throws {
        let source = try Fixtures.jpegData(from: Fixtures.makeSolidImage(
            width: 1500,
            height: 3000,
            rgba: Fixtures.RGBA(r: 50, g: 100, b: 150, a: 255)
        ))
        let artifact = try renderer.render(sourceBytes: source, variant: .preview)
        XCTAssertEqual(max(artifact.pixelWidth, artifact.pixelHeight), 2048)
        XCTAssertEqual(artifact.pixelWidth, 1024)
        XCTAssertEqual(artifact.pixelHeight, 2048)
    }

    func testPreviewSquareLongEdgeReaches2048WithoutUpscale() throws {
        let source = try Fixtures.jpegData(from: Fixtures.makeSolidImage(
            width: 2500,
            height: 2500,
            rgba: Fixtures.RGBA(r: 50, g: 100, b: 150, a: 255)
        ))
        let artifact = try renderer.render(sourceBytes: source, variant: .preview)
        XCTAssertEqual(artifact.pixelWidth, 2048)
        XCTAssertEqual(artifact.pixelHeight, 2048)
    }

    func testPreviewSmallSourceDoesNotUpscale() throws {
        let source = try Fixtures.pngData(from: Fixtures.makeSolidImage(
            width: 100,
            height: 50,
            rgba: Fixtures.RGBA(r: 10, g: 20, b: 30, a: 255)
        ))
        let artifact = try renderer.render(sourceBytes: source, variant: .preview)
        XCTAssertEqual(artifact.pixelWidth, 100)
        XCTAssertEqual(artifact.pixelHeight, 50)
    }

    func testMeaningfulAlphaOutsideLegacySampleRegionOutputsPNG() throws {
        let source = try Fixtures.pngData(from: Fixtures.makeAlphaPatchImage(size: 128))
        let artifact = try renderer.render(sourceBytes: source, variant: .gridSmall)
        XCTAssertEqual(artifact.storageFormat, .png)
        let image = try Fixtures.decodeImage(from: artifact)
        let sample = try Fixtures.rgbaPixel(in: image, x: 220, y: 220)
        XCTAssertLessThan(sample.a, 250)
    }

    func testFullyOpaqueAlphaChannelInputOutputsJPEG() throws {
        let source = try Fixtures.pngData(from: Fixtures.makeSolidImage(
            width: 16,
            height: 16,
            rgba: Fixtures.RGBA(r: 200, g: 100, b: 50, a: 255)
        ))
        let artifact = try renderer.render(sourceBytes: source, variant: .gridSmall)
        XCTAssertEqual(artifact.storageFormat, .jpeg)
    }

    func testOutputUsesEightBitSRGBColorSpace() throws {
        let source = try Fixtures.jpegData(from: Fixtures.makeSolidImage(
            width: 16,
            height: 16,
            rgba: Fixtures.RGBA(r: 120, g: 130, b: 140, a: 255)
        ))
        let artifact = try renderer.render(sourceBytes: source, variant: .preview)
        let image = try Fixtures.decodeImage(from: artifact)
        guard let space = image.colorSpace, let name = space.name as String? else {
            return XCTFail("missing color space")
        }
        XCTAssertTrue(name.contains("RGB"))
        XCTAssertEqual(image.bitsPerComponent, 8)
    }

    func testArtifactBytesHashFormatAndDecodeStayConsistent() throws {
        let source = try Fixtures.requireEncodedData(uti: UTType.jpeg.identifier, width: 24, height: 18)
        let artifact = try renderer.render(sourceBytes: source, variant: .gridRegular)
        try Fixtures.assertArtifactSelfConsistent(artifact)
        let digest = SHA256.hash(data: artifact.bytes)
        XCTAssertEqual(Data(digest), artifact.sha256)
        XCTAssertEqual(Int64(artifact.bytes.count), artifact.byteSize)
    }

    func testOutputStripsSourceMetadataSentinels() throws {
        let source = try Fixtures.metadataSentinelJPEGData()
        try Fixtures.proveSourceMetadataSentinelsPresent(source)
        let artifact = try renderer.render(sourceBytes: source, variant: .preview)
        try Fixtures.assertOutputMetadataSentinelsAbsent(artifact.bytes)
    }

    func testMultiFrameTIFFReturnsDerivedDecodeFailed() throws {
        guard let data = FolderReconcileTestSupport.minimalMultiFrameTIFFData() else {
            return XCTFail("host must encode multi-frame TIFF")
        }
        XCTAssertEqual(try Fixtures.canonicalUTI(for: data), UTType.tiff.identifier)
        XCTAssertThrowsError(try renderer.render(sourceBytes: data, variant: .preview)) { error in
            XCTAssertEqual(error as? DerivedImageError, .derivedDecodeFailed)
        }
    }

    func testStaticGIFRendersPreview() throws {
        let gif = Data([
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x21, 0xF9, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x4C, 0x01, 0x00, 0x3B,
        ])
        let artifact = try renderer.render(sourceBytes: gif, variant: .preview)
        XCTAssertGreaterThan(artifact.bytes.count, 0)
    }

    func testMultiFrameGIFReturnsDerivedDecodeFailed() throws {
        // Two 1x1 frames.
        let gif = Data([
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00,
            0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF,
            0x21, 0xF9, 0x04, 0x00, 0x0A, 0x00, 0x00, 0x00,
            0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
            0x02, 0x02, 0x44, 0x01, 0x00,
            0x21, 0xF9, 0x04, 0x00, 0x0A, 0x00, 0x00, 0x00,
            0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
            0x02, 0x02, 0x44, 0x01, 0x00,
            0x3B,
        ])
        XCTAssertThrowsError(try renderer.render(sourceBytes: gif, variant: .preview)) { error in
            XCTAssertEqual(error as? DerivedImageError, .derivedDecodeFailed)
        }
    }

    func testServiceActualUTIDriftReturnsSourceChanged() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "render-uti-drift")
        defer { env.cleanup() }
        let fileURL = try env.writeSource(relativePath: "photos/sample.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let (sizeBytes, modifiedAtNs, resourceID) = env.productionFingerprint(for: fileURL)
        let actualUTI = try Fixtures.canonicalUTI(for: try Data(contentsOf: fileURL))
        XCTAssertEqual(actualUTI, UTType.png.identifier)
        let sourceSnapshot = try env.sourceFileSnapshot(for: fileURL)

        try await env.database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'folder', 'Fixture', ?, 0, 0, 'active', ?, ?)
                """,
                arguments: [env.sourceID.uuidString.lowercased(), env.bookmark, FolderReconcileTestSupport.baseTimeMs, FolderReconcileTestSupport.baseTimeMs]
            )
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, content_revision, availability,
                    record_created_at_ms, record_updated_at_ms, file_name
                ) VALUES (?, ?, 'file', ?, NULL, 'current', ?, ?, 'available', ?, ?, ?)
                """,
                arguments: [
                    env.assetID.uuidString.lowercased(),
                    env.sourceID.uuidString.lowercased(),
                    "photos/sample.png",
                    UTType.jpeg.identifier,
                    1,
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                    "sample.png",
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO file_fingerprint (asset_id, size_bytes, modified_at_ns, resource_id, sha256)
                VALUES (?, ?, ?, ?, NULL)
                """,
                arguments: [env.assetID.uuidString.lowercased(), sizeBytes, modifiedAtNs, resourceID]
            )
        }

        let factsBefore = try await env.generationCatalogFacts()
        let jobCountBefore = try await env.jobRecordCount()
        let tagCountBefore = try await env.tagRecordCount()
        let (service, bookmarkPort) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)

        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected source changed")
        } catch DerivedImageError.derivedSourceChanged {
        } catch let error as DerivedImageError {
            XCTFail("expected derivedSourceChanged, got \(error)")
        }

        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 0)
        XCTAssertEqual(counts.objects, 0)
        XCTAssertEqual(counts.stagingFiles, 0)
        XCTAssertEqual(try Data(contentsOf: fileURL), sourceSnapshot.bytes)
        let (_, actualMtime, _) = env.productionFingerprint(for: fileURL)
        XCTAssertEqual(actualMtime, sourceSnapshot.modifiedAtNs)
        let factsAfter = try await env.generationCatalogFacts()
        XCTAssertEqual(factsAfter, factsBefore)
        let jobCountAfter = try await env.jobRecordCount()
        let tagCountAfter = try await env.tagRecordCount()
        XCTAssertEqual(jobCountAfter, jobCountBefore)
        XCTAssertEqual(tagCountAfter, tagCountBefore)
    }
}
