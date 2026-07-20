import CoreGraphics
import CryptoKit
import XCTest
@testable import ImageAll

final class AppCoreMLEmbeddingCacheTests: XCTestCase {
    func testExactIdentityEmbeddingPersistsAcrossCacheInstances() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AppCoreMLEmbeddingService(
            isEnabled: true,
            artifactDirectory: projectArtifactDirectory()
        )
        let key = AppCoreMLEmbeddingCacheKey(
            catalogScopeID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            assetID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            contentRevision: 7
        )

        let generated = try AppCoreMLEmbeddingCache(
            cachesDirectory: root,
            service: service
        ).embedding(for: generatedImage(), key: key)
        let persisted = try AppCoreMLEmbeddingCache(
            cachesDirectory: root,
            service: service
        ).embedding(for: generatedImage(), key: key)

        XCTAssertEqual(generated.origin, .generated)
        XCTAssertEqual(persisted.origin, .cacheHit)
        XCTAssertEqual(persisted.identity, generated.identity)
        XCTAssertEqual(persisted.values, generated.values)
        XCTAssertEqual(persisted.vectorSHA256, generated.vectorSHA256)
        XCTAssertEqual(persisted.vectorSHA256.count, 64)
    }

    func testConcurrentExactIdentityRequestsGenerateOnlyOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AppCoreMLEmbeddingCache(
            cachesDirectory: root,
            service: AppCoreMLEmbeddingService(
                isEnabled: true,
                artifactDirectory: projectArtifactDirectory()
            )
        )
        let key = AppCoreMLEmbeddingCacheKey(
            catalogScopeID: UUID(),
            assetID: UUID(),
            contentRevision: 1
        )
        let image = SendableImage(try generatedImage())
        let results = ConcurrentResults()
        let group = DispatchGroup()
        let start = DispatchSemaphore(value: 0)

        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                start.wait()
                do {
                    results.append(
                        try cache.embedding(for: image.value, key: key).origin
                    )
                } catch {
                    results.append(error)
                }
            }
        }
        for _ in 0..<8 { start.signal() }

        XCTAssertEqual(group.wait(timeout: .now() + 15), .success)
        XCTAssertTrue(results.errors.isEmpty)
        XCTAssertEqual(results.origins.filter { $0 == .generated }.count, 1)
        XCTAssertEqual(results.origins.filter { $0 == .cacheHit }.count, 7)
    }

    func testContentRevisionChangeMissesWithoutInvalidatingTheOlderRevision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AppCoreMLEmbeddingCache(
            cachesDirectory: root,
            service: AppCoreMLEmbeddingService(
                isEnabled: true,
                artifactDirectory: projectArtifactDirectory()
            )
        )
        let catalogID = UUID()
        let assetID = UUID()
        let firstKey = AppCoreMLEmbeddingCacheKey(
            catalogScopeID: catalogID,
            assetID: assetID,
            contentRevision: 1
        )
        let secondKey = AppCoreMLEmbeddingCacheKey(
            catalogScopeID: catalogID,
            assetID: assetID,
            contentRevision: 2
        )

        XCTAssertEqual(
            try cache.embedding(for: generatedImage(), key: firstKey).origin,
            .generated
        )
        XCTAssertEqual(
            try cache.embedding(for: generatedImage(), key: secondKey).origin,
            .generated
        )
        XCTAssertEqual(
            try cache.embedding(for: generatedImage(), key: firstKey).origin,
            .cacheHit
        )
    }

    func testVectorChecksumMismatchRegeneratesAndRepairsTheEntry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AppCoreMLEmbeddingCache(
            cachesDirectory: root,
            service: AppCoreMLEmbeddingService(
                isEnabled: true,
                artifactDirectory: projectArtifactDirectory()
            )
        )
        let key = AppCoreMLEmbeddingCacheKey(
            catalogScopeID: UUID(),
            assetID: UUID(),
            contentRevision: 1
        )
        let first = try cache.embedding(for: generatedImage(), key: key)
        let file = try XCTUnwrap(cacheFiles(under: root).only)
        var record = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        record["vectorSHA256"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: record).write(to: file, options: .atomic)

        let repaired = try cache.embedding(for: generatedImage(), key: key)
        let hit = try cache.embedding(for: generatedImage(), key: key)

        XCTAssertEqual(repaired.origin, .generated)
        XCTAssertEqual(repaired.vectorSHA256, first.vectorSHA256)
        XCTAssertEqual(hit.origin, .cacheHit)
        XCTAssertEqual(hit.vectorSHA256, first.vectorSHA256)
        XCTAssertEqual(cacheFiles(under: root).count, 1)
    }

    func testNonFiniteVectorWithMatchingChecksumRegeneratesTheEntry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AppCoreMLEmbeddingCache(
            cachesDirectory: root,
            service: AppCoreMLEmbeddingService(
                isEnabled: true,
                artifactDirectory: projectArtifactDirectory()
            )
        )
        let key = AppCoreMLEmbeddingCacheKey(
            catalogScopeID: UUID(),
            assetID: UUID(),
            contentRevision: 1
        )
        _ = try cache.embedding(for: generatedImage(), key: key)
        let file = try XCTUnwrap(cacheFiles(under: root).only)
        var record = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        var vectorData = try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(record["vectorData"] as? String))
        )
        vectorData.replaceSubrange(0..<4, with: [0x00, 0x00, 0xC0, 0x7F])
        record["vectorData"] = vectorData.base64EncodedString()
        record["vectorSHA256"] = SHA256.hash(data: vectorData)
            .map { String(format: "%02x", $0) }
            .joined()
        try JSONSerialization.data(withJSONObject: record).write(to: file, options: .atomic)

        let repaired = try cache.embedding(for: generatedImage(), key: key)
        let hit = try cache.embedding(for: generatedImage(), key: key)

        XCTAssertEqual(repaired.origin, .generated)
        XCTAssertTrue(repaired.values.allSatisfy(\.isFinite))
        XCTAssertEqual(hit.origin, .cacheHit)
        XCTAssertTrue(hit.values.allSatisfy(\.isFinite))
    }

    func testDisabledModelDoesNotCreateCacheState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = AppCoreMLEmbeddingCache(
            cachesDirectory: root,
            service: AppCoreMLEmbeddingService(
                isEnabled: false,
                artifactDirectory: URL(fileURLWithPath: "/definitely/missing/coreml-artifact")
            )
        )

        XCTAssertThrowsError(
            try cache.embedding(
                for: generatedImage(),
                key: AppCoreMLEmbeddingCacheKey(
                    catalogScopeID: UUID(),
                    assetID: UUID(),
                    contentRevision: 1
                )
            )
        ) { error in
            XCTAssertEqual(error as? AppCoreMLEmbeddingError, .unavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testCachePersistenceFailureReturnsGeneratedEmbeddingAndPreservesSentinel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sentinel = Data("owned outside the cache".utf8)
        try sentinel.write(to: root, options: .atomic)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AppCoreMLEmbeddingCache(
            cachesDirectory: root,
            service: AppCoreMLEmbeddingService(
                isEnabled: true,
                artifactDirectory: projectArtifactDirectory()
            )
        )

        let result = try cache.embedding(
            for: generatedImage(),
            key: AppCoreMLEmbeddingCacheKey(
                catalogScopeID: UUID(),
                assetID: UUID(),
                contentRevision: 1
            )
        )

        XCTAssertEqual(result.origin, .generated)
        XCTAssertEqual(result.values.count, 384)
        XCTAssertTrue(result.values.allSatisfy(\.isFinite))
        XCTAssertEqual(try Data(contentsOf: root), sentinel)
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

    private func cacheFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else {
                return nil
            }
            return url
        }
    }

    private enum TestImageError: Error {
        case creationFailed
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}

private final class SendableImage: @unchecked Sendable {
    let value: CGImage

    init(_ value: CGImage) {
        self.value = value
    }
}

private final class ConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOrigins: [AppCoreMLEmbeddingOrigin] = []
    private var storedErrors: [Error] = []

    var origins: [AppCoreMLEmbeddingOrigin] {
        lock.withLock { storedOrigins }
    }

    var errors: [Error] {
        lock.withLock { storedErrors }
    }

    func append(_ origin: AppCoreMLEmbeddingOrigin) {
        lock.withLock { storedOrigins.append(origin) }
    }

    func append(_ error: Error) {
        lock.withLock { storedErrors.append(error) }
    }
}
