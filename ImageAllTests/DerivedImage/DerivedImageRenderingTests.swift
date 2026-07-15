import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

final class DerivedImageRenderingTests: XCTestCase {
    private let renderer = DerivedImageRenderer()

    func testSupportedFormatsGenerate() throws {
        let fixtures: [(String, () -> Data?)] = [
            ("jpeg", { FolderReconcileTestSupport.minimalJPEGData() }),
            ("png", { FolderReconcileTestSupport.minimalPNGData() }),
            ("heic", { FolderReconcileTestSupport.minimalHEICData() }),
            ("heif", { FolderReconcileTestSupport.minimalHEIFData() }),
            ("tiff", { FolderReconcileTestSupport.minimalTIFFData() }),
            ("webp", { FolderReconcileTestSupport.minimalWebPData() }),
        ]
        for (label, supplier) in fixtures {
            guard let data = supplier(), !data.isEmpty else {
                XCTFail("host must provide \(label) fixture")
                continue
            }
            let artifact = try renderer.render(sourceBytes: data, variant: .gridSmall)
            XCTAssertEqual(artifact.pixelWidth, 256)
            XCTAssertEqual(artifact.pixelHeight, 256)
        }
    }

    func testOrientationEightProducesExpectedVisualGeometry() throws {
        for orientation in 1 ... 8 {
            guard let data = FolderReconcileTestSupport.minimalOrientedJPEGData(orientation: orientation) else {
                return XCTFail("missing oriented jpeg \(orientation)")
            }
            let artifact = try renderer.render(sourceBytes: data, variant: .preview)
            if (5 ... 8).contains(orientation) {
                XCTAssertEqual(artifact.pixelWidth, 2, "orientation \(orientation)")
                XCTAssertEqual(artifact.pixelHeight, 4, "orientation \(orientation)")
            } else {
                XCTAssertEqual(artifact.pixelWidth, 4, "orientation \(orientation)")
                XCTAssertEqual(artifact.pixelHeight, 2, "orientation \(orientation)")
            }
        }
    }

    func testAlphaOutputsPNG() throws {
        let data = FolderReconcileTestSupport.minimalPNGData()
        let artifact = try renderer.render(sourceBytes: data, variant: .gridSmall)
        XCTAssertEqual(artifact.storageFormat, .png)
    }

    func testOpaqueOutputsJPEG() throws {
        let data = FolderReconcileTestSupport.minimalJPEGData()
        let artifact = try renderer.render(sourceBytes: data, variant: .gridSmall)
        XCTAssertEqual(artifact.storageFormat, .jpeg)
    }

    func testPreviewDoesNotUpscaleSmallSource() throws {
        let data = FolderReconcileTestSupport.minimalPNGData()
        let artifact = try renderer.render(sourceBytes: data, variant: .preview)
        XCTAssertLessThanOrEqual(max(artifact.pixelWidth, artifact.pixelHeight), 2048)
        XCTAssertEqual(artifact.pixelWidth, 2)
        XCTAssertEqual(artifact.pixelHeight, 1)
    }

    func testMetadataStrippedFromOutput() throws {
        guard let source = FolderReconcileTestSupport.minimalExifJPEGData(dateTimeOriginal: "2020:01:01 00:00:00") else {
            return XCTFail("host must encode EXIF jpeg")
        }
        let artifact = try renderer.render(sourceBytes: source, variant: .preview)
        guard let outSource = CGImageSourceCreateWithData(artifact.bytes as CFData, nil),
              let outProps = CGImageSourceCopyPropertiesAtIndex(outSource, 0, nil) as? [CFString: Any],
              let outExif = outProps[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else {
            return
        }
        XCTAssertNil(outExif[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(outExif[kCGImagePropertyExifOffsetTimeOriginal])
    }

    func testAnimatedGIFRejected() throws {
        let gif = Data([
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00,
            0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x21, 0xFF, 0x0B, 0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45, 0x32, 0x2E, 0x30, 0x03,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
            0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
        ])
        XCTAssertThrowsError(try renderer.render(sourceBytes: gif, variant: .preview)) { error in
            XCTAssertEqual(error as? DerivedImageError, .derivedDecodeFailed)
        }
    }
}