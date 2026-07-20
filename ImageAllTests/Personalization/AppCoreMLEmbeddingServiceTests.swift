import CoreGraphics
import XCTest
@testable import ImageAll

final class AppCoreMLEmbeddingServiceTests: XCTestCase {
    func testDisabledServiceDoesNotRequireAnArtifact() {
        let service = AppCoreMLEmbeddingService(
            isEnabled: false,
            artifactDirectory: URL(fileURLWithPath: "/definitely/missing/coreml-artifact")
        )

        XCTAssertEqual(service.availability, .disabled)
        XCTAssertThrowsError(try service.embedding(for: generatedImage())) { error in
            XCTAssertEqual(error as? AppCoreMLEmbeddingError, .unavailable)
        }
    }

    func testEnabledServiceReportsMissingArtifactWithoutCrashing() {
        let service = AppCoreMLEmbeddingService(
            isEnabled: true,
            artifactDirectory: URL(fileURLWithPath: "/definitely/missing/coreml-artifact")
        )

        XCTAssertEqual(service.availability, .unavailable(.artifactMissing))
        XCTAssertThrowsError(try service.embedding(for: generatedImage())) { error in
            XCTAssertEqual(error as? AppCoreMLEmbeddingError, .unavailable)
        }
    }

    func testEnabledServiceReportsDamagedManifestWithoutCrashing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{".utf8).write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        let service = AppCoreMLEmbeddingService(
            isEnabled: true,
            artifactDirectory: directory
        )

        XCTAssertEqual(service.availability, .unavailable(.manifestInvalid))
        XCTAssertThrowsError(try service.embedding(for: generatedImage())) { error in
            XCTAssertEqual(error as? AppCoreMLEmbeddingError, .unavailable)
        }
    }

    func testEnabledServiceRejectsDamagedModelBytesBeforeLoading() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modelDirectory = directory.appendingPathComponent(
            "encoder.mlmodelc",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = projectArtifactDirectory()
        try FileManager.default.copyItem(
            at: source.appendingPathComponent("manifest.json"),
            to: directory.appendingPathComponent("manifest.json")
        )
        try FileManager.default.copyItem(
            at: source.appendingPathComponent("LICENSE.txt"),
            to: directory.appendingPathComponent("LICENSE.txt")
        )
        try Data("damaged model bytes".utf8).write(
            to: modelDirectory.appendingPathComponent("model.mil"),
            options: .atomic
        )

        let service = AppCoreMLEmbeddingService(
            isEnabled: true,
            artifactDirectory: directory
        )

        XCTAssertEqual(service.availability, .unavailable(.checksumMismatch))
        XCTAssertThrowsError(try service.embedding(for: generatedImage())) { error in
            XCTAssertEqual(error as? AppCoreMLEmbeddingError, .unavailable)
        }
    }

    func testEnabledFixedArtifactReturnsAFiniteIdentityMatchedEmbedding() throws {
        let service = AppCoreMLEmbeddingService(
            isEnabled: true,
            artifactDirectory: projectArtifactDirectory()
        )
        guard case let .ready(identity) = service.availability else {
            return XCTFail("expected the fixed Core ML artifact to be ready")
        }

        let embedding = try service.embedding(for: try generatedImage())

        XCTAssertEqual(embedding.identity, identity)
        XCTAssertEqual(identity.provider, "dinov2")
        XCTAssertEqual(identity.modelID, "facebook/dinov2-small")
        XCTAssertEqual(identity.elementCount, 384)
        XCTAssertEqual(embedding.values.count, 384)
        XCTAssertTrue(embedding.values.allSatisfy { $0.isFinite })
    }

    private func projectArtifactDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ImageAll/Resources/Models/DINOv2Small")
    }

    private func generatedImage() throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: 320,
            height: 240,
            bitsPerComponent: 8,
            bytesPerRow: 320 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestImageError.creationFailed
        }
        context.setFillColor(red: 0.125, green: 0.5, blue: 0.875, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        guard let image = context.makeImage() else {
            throw TestImageError.creationFailed
        }
        return image
    }

    private enum TestImageError: Error {
        case creationFailed
    }
}
