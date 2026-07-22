import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

final class MediaDecodeCascadeTests: XCTestCase {
    func testApprovedTypesIncludeFujiAdobeJPEG2000AndGIF() {
        XCTAssertTrue(ApprovedSourceMediaTypes.contains(ApprovedSourceMediaTypes.fujiRawIdentifier))
        XCTAssertTrue(ApprovedSourceMediaTypes.contains(ApprovedSourceMediaTypes.adobeRawIdentifier))
        XCTAssertTrue(ApprovedSourceMediaTypes.contains(ApprovedSourceMediaTypes.jpeg2000Identifier))
        XCTAssertTrue(ApprovedSourceMediaTypes.contains(UTType.gif.identifier))
        XCTAssertTrue(ApprovedSourceMediaTypes.isCameraRaw(ApprovedSourceMediaTypes.fujiRawIdentifier))
        XCTAssertFalse(ApprovedSourceMediaTypes.contains("public.svg-image"))
        XCTAssertFalse(ApprovedSourceMediaTypes.contains("com.adobe.illustrator.ai-image"))
    }

    func testStaticGIFAvailableAndRecordsNoFailureReason() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "static-gif")
        let gif = Data([
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x21, 0xF9, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x4C, 0x01, 0x00, 0x3B,
        ])
        let file = try fixture.writeFile(root: root, relativePath: "static.gif", contents: gif)
        guard case let .available(metadata) = FolderMediaClassifier().classify(fileURL: file, fileName: "static.gif") else {
            return XCTFail("static gif must be available")
        }
        XCTAssertEqual(metadata.mediaType, UTType.gif.identifier)
        XCTAssertNil(metadata.classificationFailureReason)
    }

    func testCorruptJPEGRecordsSourceOrDimensionFailureReason() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "bad-jpeg")
        let file = try fixture.writeFile(
            root: root,
            relativePath: "bad.jpg",
            contents: Data([0xFF, 0xD8, 0xFF, 0x00])
        )
        guard case let .unreadable(metadata) = FolderMediaClassifier().classify(fileURL: file, fileName: "bad.jpg") else {
            return XCTFail("corrupt jpeg must be unreadable")
        }
        XCTAssertEqual(metadata.mediaType, UTType.jpeg.identifier)
        XCTAssertNotNil(metadata.classificationFailureReason)
    }

    func testImageIOSuccessDoesNotInvokeLibRawSpy() throws {
        final class Spy: LibRawPreviewDecoding, @unchecked Sendable {
            var probePathCount = 0
            var decodeCount = 0
            func probe(path: String) -> (width: Int, height: Int)? {
                probePathCount += 1
                return nil
            }
            func probe(bytes: Data) -> (width: Int, height: Int)? {
                probePathCount += 1
                return nil
            }
            func decodeThumbJPEG(path: String) -> Data? {
                decodeCount += 1
                return nil
            }
            func decodeThumbJPEG(bytes: Data) -> Data? {
                decodeCount += 1
                return nil
            }
        }

        let spy = Spy()
        var cascade = MediaDecodeCascade()
        cascade.libRaw = spy
        let jpeg = FolderReconcileTestSupport.minimalJPEGData()
        let prepared = try cascade.preparedImageIOSource(
            sourceBytes: jpeg,
            expectedMediaType: UTType.jpeg.identifier,
            libRawSpy: spy
        )
        XCTAssertEqual(prepared.stage, .imageIO)
        XCTAssertEqual(spy.probePathCount, 0)
        XCTAssertEqual(spy.decodeCount, 0)

        let artifact = try DerivedImageRenderer(cascade: cascade).render(
            sourceBytes: jpeg,
            variant: .gridSmall,
            expectedMediaType: UTType.jpeg.identifier
        )
        XCTAssertGreaterThan(artifact.bytes.count, 0)
        XCTAssertEqual(spy.decodeCount, 0)
    }

    func testLibRawSpyUsedWhenForcedRawBytesWithoutImageIO() throws {
        final class Spy: LibRawPreviewDecoding, @unchecked Sendable {
            var decodeCount = 0
            func probe(path: String) -> (width: Int, height: Int)? { nil }
            func probe(bytes: Data) -> (width: Int, height: Int)? { nil }
            func decodeThumbJPEG(path: String) -> Data? { nil }
            func decodeThumbJPEG(bytes: Data) -> Data? {
                decodeCount += 1
                return FolderReconcileTestSupport.minimalJPEGData()
            }
        }
        let spy = Spy()
        var cascade = MediaDecodeCascade()
        cascade.libRaw = spy
        // Prefix that trips looksLikeRawBytes but is not a real ImageIO RAW.
        var bytes = Data("FUJIFILMCCD-RAW ".utf8)
        bytes.append(Data(repeating: 0, count: 64))
        let prepared = try cascade.preparedImageIOSource(
            sourceBytes: bytes,
            expectedMediaType: ApprovedSourceMediaTypes.fujiRawIdentifier,
            libRawSpy: spy
        )
        XCTAssertEqual(prepared.stage, .libRaw)
        XCTAssertEqual(spy.decodeCount, 1)
        XCTAssertEqual(prepared.type, UTType.jpeg.identifier)
    }
}
