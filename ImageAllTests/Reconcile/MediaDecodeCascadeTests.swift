import CoreGraphics
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

final class MediaDecodeCascadeTests: XCTestCase {
    func testApprovedTypesIncludeRasterRawAndSupportedVectorDocuments() {
        XCTAssertTrue(ApprovedSourceMediaTypes.contains(ApprovedSourceMediaTypes.fujiRawIdentifier))
        XCTAssertTrue(ApprovedSourceMediaTypes.contains(ApprovedSourceMediaTypes.adobeRawIdentifier))
        XCTAssertTrue(ApprovedSourceMediaTypes.contains(ApprovedSourceMediaTypes.jpeg2000Identifier))
        XCTAssertTrue(ApprovedSourceMediaTypes.contains(UTType.gif.identifier))
        XCTAssertTrue(ApprovedSourceMediaTypes.isCameraRaw(ApprovedSourceMediaTypes.fujiRawIdentifier))
        XCTAssertTrue(ApprovedSourceMediaTypes.contains(ApprovedSourceMediaTypes.svgIdentifier))
        XCTAssertTrue(ApprovedSourceMediaTypes.contains(ApprovedSourceMediaTypes.pdfIdentifier))
        XCTAssertTrue(ApprovedSourceMediaTypes.contains(ApprovedSourceMediaTypes.illustratorIdentifier))
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

    func testValidSVGIsAvailableWithLogicalCanvasDimensions() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "svg")
        let svg = Data(
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80" viewBox="0 0 120 80">
              <rect width="120" height="80" fill="#336699"/>
            </svg>
            """.utf8
        )
        let file = try fixture.writeFile(root: root, relativePath: "vector.svg", contents: svg)

        guard case let .available(metadata) = FolderMediaClassifier().classify(
            fileURL: file,
            fileName: "vector.svg"
        ) else {
            return XCTFail("valid SVG must be available")
        }
        XCTAssertEqual(metadata.mediaType, "public.svg-image")
        XCTAssertEqual(metadata.width, 120)
        XCTAssertEqual(metadata.height, 80)
        XCTAssertNil(metadata.classificationFailureReason)
    }

    func testSinglePagePDFIsAvailableWithPageDimensions() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "pdf")
        let data = try XCTUnwrap(FolderReconcileTestSupport.minimalPDFData())
        let file = try fixture.writeFile(root: root, relativePath: "document.pdf", contents: data)

        guard case let .available(metadata) = FolderMediaClassifier().classify(
            fileURL: file,
            fileName: "document.pdf"
        ) else {
            return XCTFail("single-page PDF must be available")
        }
        XCTAssertEqual(metadata.mediaType, UTType.pdf.identifier)
        XCTAssertEqual(metadata.width, 200)
        XCTAssertEqual(metadata.height, 100)
        XCTAssertNil(metadata.classificationFailureReason)
    }

    func testMultiPagePDFIsUnsupportedInsteadOfSilentlyUsingFirstPage() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "multi-page-pdf")
        let data = try XCTUnwrap(FolderReconcileTestSupport.minimalPDFData(pageCount: 2))
        let file = try fixture.writeFile(root: root, relativePath: "document.pdf", contents: data)

        guard case let .unsupported(metadata) = FolderMediaClassifier().classify(
            fileURL: file,
            fileName: "document.pdf"
        ) else {
            return XCTFail("multi-page PDF must be explicitly unsupported")
        }
        XCTAssertEqual(metadata.mediaType, UTType.pdf.identifier)
        XCTAssertNil(metadata.width)
        XCTAssertNil(metadata.height)
    }

    func testPDFCompatibleSinglePageAIIsAvailableAsIllustratorMedia() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "pdf-compatible-ai")
        let data = try XCTUnwrap(FolderReconcileTestSupport.minimalPDFData(width: 180, height: 120))
        let file = try fixture.writeFile(root: root, relativePath: "vector.ai", contents: data)

        guard case let .available(metadata) = FolderMediaClassifier().classify(
            fileURL: file,
            fileName: "vector.ai"
        ) else {
            return XCTFail("single-page PDF-compatible AI must be available")
        }
        XCTAssertEqual(metadata.mediaType, "com.adobe.illustrator.ai-image")
        XCTAssertEqual(metadata.width, 180)
        XCTAssertEqual(metadata.height, 120)
    }

    func testMultiPagePDFCompatibleAIIsUnsupported() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "multi-page-ai")
        let data = try XCTUnwrap(FolderReconcileTestSupport.minimalPDFData(pageCount: 2))
        let file = try fixture.writeFile(root: root, relativePath: "vector.ai", contents: data)

        guard case let .unsupported(metadata) = FolderMediaClassifier().classify(
            fileURL: file,
            fileName: "vector.ai"
        ) else {
            return XCTFail("multi-page PDF-compatible AI must be unsupported")
        }
        XCTAssertEqual(metadata.mediaType, ApprovedSourceMediaTypes.illustratorIdentifier)
    }

    func testLegacyAIWithoutPDFPayloadIsUnreadable() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "legacy-ai")
        let file = try fixture.writeFile(
            root: root,
            relativePath: "legacy.ai",
            contents: Data("%!PS-Adobe-3.0\n%%Creator: Illustrator".utf8)
        )

        guard case let .unreadable(metadata) = FolderMediaClassifier().classify(
            fileURL: file,
            fileName: "legacy.ai"
        ) else {
            return XCTFail("legacy non-PDF AI must remain visible as unreadable")
        }
        XCTAssertEqual(metadata.mediaType, ApprovedSourceMediaTypes.illustratorIdentifier)
        XCTAssertEqual(metadata.classificationFailureReason, .cascadeProbeFailed)
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
