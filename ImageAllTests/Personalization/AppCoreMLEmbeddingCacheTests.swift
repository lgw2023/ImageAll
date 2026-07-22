import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

final class AppCoreMLEmbeddingCacheTests: XCTestCase {
    func testSelectedAssetRuntimeCachesOneGeneratedImageWithActivatedIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogID = UUID()
        let assetID = UUID()
        let defaults = UserDefaults(
            suiteName: "AppCoreMLEmbeddingCacheTests.\(UUID().uuidString)"
        )!
        let artifactDirectory = projectArtifactDirectory()
        let coordinator = AppModelActivationCoordinator(
            preferenceStore: UserDefaultsModelEnablementPreferenceStore(defaults: defaults),
            serviceFactory: {
                AppCoreMLEmbeddingService(
                    isEnabled: true,
                    artifactDirectory: artifactDirectory
                )
            }
        )
        guard case let .ready(expectedIdentity) = await coordinator.setEnabled(true) else {
            return XCTFail("expected fixed Core ML artifact to activate")
        }
        let runtime = AppSelectedAssetEmbeddingCacheRuntime(
            catalogScopeID: catalogID,
            activationCoordinator: coordinator,
            cachesDirectory: root
        )
        let imageData = try generatedPNGData()

        let result = try await runtime.cacheSelectedAsset(
            assetID: assetID,
            contentRevision: 7,
            imageData: { imageData }
        )

        XCTAssertEqual(result.origin, .generated)
        XCTAssertEqual(result.identity, expectedIdentity)
        XCTAssertEqual(result.values.count, 384)
        XCTAssertTrue(result.values.allSatisfy(\.isFinite))
        XCTAssertEqual(cacheFiles(under: root).count, 1)
    }

    func testSelectedAssetRuntimeSkipsImageLoadOnIdentityMatchedCacheHit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogID = UUID()
        let assetID = UUID()
        let defaults = UserDefaults(
            suiteName: "AppCoreMLEmbeddingCacheTests.\(UUID().uuidString)"
        )!
        let artifactDirectory = projectArtifactDirectory()
        let coordinator = AppModelActivationCoordinator(
            preferenceStore: UserDefaultsModelEnablementPreferenceStore(defaults: defaults),
            serviceFactory: {
                AppCoreMLEmbeddingService(
                    isEnabled: true,
                    artifactDirectory: artifactDirectory
                )
            }
        )
        guard case let .ready(expectedIdentity) = await coordinator.setEnabled(true) else {
            return XCTFail("expected fixed Core ML artifact to activate")
        }
        let runtime = AppSelectedAssetEmbeddingCacheRuntime(
            catalogScopeID: catalogID,
            activationCoordinator: coordinator,
            cachesDirectory: root
        )
        let imageData = try generatedPNGData()
        _ = try await runtime.cacheSelectedAsset(
            assetID: assetID,
            contentRevision: 7,
            imageData: { imageData }
        )

        final class ImageLoadCounter: @unchecked Sendable {
            var count = 0
        }
        let imageLoadCounter = ImageLoadCounter()
        let hit = try await runtime.cacheSelectedAsset(
            assetID: assetID,
            contentRevision: 7,
            imageData: {
                imageLoadCounter.count += 1
                return imageData
            }
        )

        XCTAssertEqual(hit.origin, .cacheHit)
        XCTAssertEqual(hit.identity, expectedIdentity)
        XCTAssertEqual(imageLoadCounter.count, 0)
        XCTAssertEqual(cacheFiles(under: root).count, 1)
    }

    func testSelectedAssetRuntimeDoesNotReportSuccessWhenCacheCannotPersist() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sentinel = Data("not a cache directory".utf8)
        try sentinel.write(to: root, options: .atomic)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(
            suiteName: "AppCoreMLEmbeddingCacheTests.\(UUID().uuidString)"
        )!
        let artifactDirectory = projectArtifactDirectory()
        let coordinator = AppModelActivationCoordinator(
            preferenceStore: UserDefaultsModelEnablementPreferenceStore(defaults: defaults),
            serviceFactory: {
                AppCoreMLEmbeddingService(
                    isEnabled: true,
                    artifactDirectory: artifactDirectory
                )
            }
        )
        guard case .ready = await coordinator.setEnabled(true) else {
            return XCTFail("expected fixed Core ML artifact to activate")
        }
        let runtime = AppSelectedAssetEmbeddingCacheRuntime(
            catalogScopeID: UUID(),
            activationCoordinator: coordinator,
            cachesDirectory: root
        )
        let imageData = try generatedPNGData()

        do {
            _ = try await runtime.cacheSelectedAsset(
                assetID: UUID(),
                contentRevision: 1,
                imageData: { imageData }
            )
            XCTFail("expected explicit cache fill to fail when persistence is unavailable")
        } catch {
            XCTAssertEqual(
                error as? AppSelectedAssetEmbeddingCacheError,
                .persistenceFailed
            )
        }
        XCTAssertEqual(try Data(contentsOf: root), sentinel)
    }

    func testPersonalTrainingSourceMapsOnlyExactCachedEmbeddingIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogID = UUID()
        let assetID = UUID()
        let key = AppCoreMLEmbeddingCacheKey(
            catalogScopeID: catalogID,
            assetID: assetID,
            contentRevision: 5
        )
        let cache = AppCoreMLEmbeddingCache(
            cachesDirectory: root,
            service: AppCoreMLEmbeddingService(
                isEnabled: true,
                artifactDirectory: projectArtifactDirectory()
            )
        )
        let generated = try cache.embedding(for: generatedImage(), key: key)
        let source = AppPersonalTrainingEmbeddingCacheSource(cache: cache)

        let cached = try await source.cachedEmbedding(
            for: PersonalTrainingEmbeddingCacheKey(
                catalogScopeID: catalogID.uuidString.lowercased(),
                assetID: assetID,
                contentRevision: Int(key.contentRevision)
            )
        )
        let invalidCatalog = try await source.cachedEmbedding(
            for: PersonalTrainingEmbeddingCacheKey(
                catalogScopeID: "not-a-catalog-uuid",
                assetID: assetID,
                contentRevision: Int(key.contentRevision)
            )
        )

        XCTAssertEqual(cached?.values, generated.values)
        XCTAssertEqual(cached?.encoder.modelID, generated.identity.modelID)
        XCTAssertEqual(cached?.encoder.elementCount, generated.identity.elementCount)
        XCTAssertNil(invalidCatalog)
        XCTAssertEqual(cacheFiles(under: root).count, 1)
    }

    func testCacheOnlyLookupReturnsExistingExactIdentityWithoutGeneratingOnMiss() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AppCoreMLEmbeddingService(
            isEnabled: true,
            artifactDirectory: projectArtifactDirectory()
        )
        let key = AppCoreMLEmbeddingCacheKey(
            catalogScopeID: UUID(),
            assetID: UUID(),
            contentRevision: 7
        )
        let cache = AppCoreMLEmbeddingCache(
            cachesDirectory: root,
            service: service
        )
        let generated = try cache.embedding(for: generatedImage(), key: key)

        let hit = try AppCoreMLEmbeddingCache(
            cachesDirectory: root,
            service: service
        ).cachedEmbedding(for: key)
        let miss = try cache.cachedEmbedding(
            for: AppCoreMLEmbeddingCacheKey(
                catalogScopeID: key.catalogScopeID,
                assetID: UUID(),
                contentRevision: key.contentRevision
            )
        )

        XCTAssertEqual(hit?.origin, .cacheHit)
        XCTAssertEqual(hit?.identity, generated.identity)
        XCTAssertEqual(hit?.values, generated.values)
        XCTAssertNil(miss)
        XCTAssertEqual(cacheFiles(under: root).count, 1)
    }

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

    func testConcurrentRequestsAcrossCacheInstancesGenerateOnlyOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AppCoreMLEmbeddingService(
            isEnabled: true,
            artifactDirectory: projectArtifactDirectory()
        )
        let caches = (0..<8).map { _ in
            AppCoreMLEmbeddingCache(cachesDirectory: root, service: service)
        }
        let key = AppCoreMLEmbeddingCacheKey(
            catalogScopeID: UUID(),
            assetID: UUID(),
            contentRevision: 1
        )
        let image = SendableImage(try generatedImage())
        let results = ConcurrentResults()
        let group = DispatchGroup()
        let start = DispatchSemaphore(value: 0)

        for cache in caches {
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
        for _ in caches { start.signal() }

        XCTAssertEqual(group.wait(timeout: .now() + 15), .success)
        XCTAssertTrue(results.errors.isEmpty)
        XCTAssertEqual(results.origins.filter { $0 == .generated }.count, 1)
        XCTAssertEqual(results.origins.filter { $0 == .cacheHit }.count, 7)
        XCTAssertEqual(cacheFiles(under: root).count, 1)
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

    func testCapacityLimitEvictsOnlyOwnedOlderObjects() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinelURL = root.appendingPathComponent("unrelated-cache.bin")
        let sentinel = Data("not owned by ModelEmbeddings".utf8)
        try sentinel.write(to: sentinelURL, options: .atomic)
        let service = AppCoreMLEmbeddingService(
            isEnabled: true,
            artifactDirectory: projectArtifactDirectory()
        )
        let catalogID = UUID()
        let firstKey = AppCoreMLEmbeddingCacheKey(
            catalogScopeID: catalogID,
            assetID: UUID(),
            contentRevision: 1
        )
        let secondKey = AppCoreMLEmbeddingCacheKey(
            catalogScopeID: catalogID,
            assetID: UUID(),
            contentRevision: 1
        )
        _ = try AppCoreMLEmbeddingCache(
            cachesDirectory: root,
            service: service
        ).embedding(for: generatedImage(), key: firstKey)
        let firstFile = try XCTUnwrap(cacheFiles(under: root).only)
        let budget = try XCTUnwrap(
            firstFile.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: firstFile.path
        )
        let boundedCache = AppCoreMLEmbeddingCache(
            cachesDirectory: root,
            service: service,
            maximumCacheBytes: budget
        )

        let second = try boundedCache.embedding(for: generatedImage(), key: secondKey)
        let remaining = cacheFiles(under: root)

        XCTAssertEqual(second.origin, .generated)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(remaining.only?.resourceValues(forKeys: [.fileSizeKey]).fileSize),
            budget
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.path))
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        XCTAssertEqual(
            try boundedCache.embedding(for: generatedImage(), key: secondKey).origin,
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

    func testFirstUseRemovesOwnedObjectsWithOldRecordSchema() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AppCoreMLEmbeddingService(
            isEnabled: true,
            artifactDirectory: projectArtifactDirectory()
        )
        let key = AppCoreMLEmbeddingCacheKey(
            catalogScopeID: UUID(),
            assetID: UUID(),
            contentRevision: 1
        )
        _ = try AppCoreMLEmbeddingCache(
            cachesDirectory: root,
            service: service
        ).embedding(for: generatedImage(), key: key)
        let current = try XCTUnwrap(cacheFiles(under: root).only)
        let stale = current.deletingLastPathComponent()
            .appendingPathComponent("old-schema.embedding")
        var record = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: current)) as? [String: Any]
        )
        record["schemaRevision"] = 0
        try JSONSerialization.data(withJSONObject: record).write(to: stale, options: .atomic)

        let result = try AppCoreMLEmbeddingCache(
            cachesDirectory: root,
            service: service
        ).embedding(for: generatedImage(), key: key)

        XCTAssertEqual(result.origin, .cacheHit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertEqual(cacheFiles(under: root).count, 1)
    }

    func testFirstUseRemovesOwnedObjectsWithStaleModelIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AppCoreMLEmbeddingService(
            isEnabled: true,
            artifactDirectory: projectArtifactDirectory()
        )
        let key = AppCoreMLEmbeddingCacheKey(
            catalogScopeID: UUID(),
            assetID: UUID(),
            contentRevision: 1
        )
        _ = try AppCoreMLEmbeddingCache(
            cachesDirectory: root,
            service: service
        ).embedding(for: generatedImage(), key: key)
        let current = try XCTUnwrap(cacheFiles(under: root).only)
        let stale = current.deletingLastPathComponent()
            .appendingPathComponent("stale-identity.embedding")
        var record = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: current)) as? [String: Any]
        )
        var address = try XCTUnwrap(record["address"] as? [String: Any])
        address["modelRevision"] = "obsolete-revision"
        record["address"] = address
        try JSONSerialization.data(withJSONObject: record).write(to: stale, options: .atomic)

        let result = try AppCoreMLEmbeddingCache(
            cachesDirectory: root,
            service: service
        ).embedding(for: generatedImage(), key: key)

        XCTAssertEqual(result.origin, .cacheHit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
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

    private func generatedPNGData() throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw TestImageError.creationFailed
        }
        CGImageDestinationAddImage(destination, try generatedImage(), nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestImageError.creationFailed
        }
        return data as Data
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
                  url.pathExtension == "embedding",
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
