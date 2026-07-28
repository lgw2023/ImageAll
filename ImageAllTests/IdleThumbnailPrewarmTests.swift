import XCTest
@testable import ImageAll

@MainActor
final class IdleThumbnailPrewarmTests: XCTestCase {
    func testPreferenceDefaultsToEnabledWhenUnset() {
        let suiteName = "IdlePrewarmPrefs.default.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsIdleThumbnailPrewarmPreferenceStore(defaults: defaults)

        XCTAssertTrue(store.isEnabled)

        store.isEnabled = false
        XCTAssertFalse(store.isEnabled)
        store.isEnabled = true
        XCTAssertTrue(store.isEnabled)
    }

    func testIdleThresholdTriggersPrewarmViaInjectableClock() async {
        let sourceID = UUID()
        let asset = makeAsset(sourceID: sourceID, fileName: "idle-a.jpg")
        let payload = Data("idle-thumb".utf8)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .folder,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            thumbnailData: payload
        )
        let preference = InMemoryIdleThumbnailPrewarmPreferenceStore(isEnabled: true)
        let clock = ManualIdlePrewarmClock(now: 0)
        let model = LibraryWorkspaceModel(
            service: service,
            idleThumbnailPrewarmPreferenceStore: preference,
            idlePrewarmClock: clock,
            idlePrewarmThresholdSeconds: 0.05,
            idlePrewarmMonitorTickSeconds: 60,
            idlePrewarmInstallEventMonitor: false
        )
        await model.start()
        XCTAssertEqual(model.items.map(\.assetID), [asset.assetID])
        XCTAssertEqual(service.thumbnailLoadCallCount, 0)

        clock.now = 1
        model.evaluateIdleThumbnailPrewarmForTesting()

        let deadline = Date().addingTimeInterval(3)
        while model.cachedThumbnailData(for: asset.assetID) == nil, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThanOrEqual(service.thumbnailLoadCallCount, 1)
        XCTAssertEqual(model.cachedThumbnailData(for: asset.assetID), payload)
    }

    func testUserInteractionCancelsIdlePrewarm() async {
        let sourceID = UUID()
        let assets = (0 ..< 4).map { makeAsset(sourceID: sourceID, fileName: "idle-\($0).jpg") }
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .folder,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: assets,
            initialItems: assets,
            startsConnected: true,
            thumbnailData: Data("idle-thumb".utf8),
            thumbnailLoadDelayNanoseconds: 200_000_000
        )
        let preference = InMemoryIdleThumbnailPrewarmPreferenceStore(isEnabled: true)
        let clock = ManualIdlePrewarmClock(now: 0)
        let model = LibraryWorkspaceModel(
            service: service,
            idleThumbnailPrewarmPreferenceStore: preference,
            idlePrewarmClock: clock,
            idlePrewarmThresholdSeconds: 0.1,
            idlePrewarmMonitorTickSeconds: 60,
            idlePrewarmInstallEventMonitor: false
        )
        await model.start()

        clock.now = 0.2
        model.evaluateIdleThumbnailPrewarmForTesting()
        XCTAssertTrue(model.isIdleThumbnailPrewarmingForTesting)

        let deadline = Date().addingTimeInterval(1)
        while service.thumbnailLoadCallCount == 0, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(service.thumbnailLoadCallCount, 1)

        model.noteUserInteractionForIdlePrewarm()
        XCTAssertFalse(model.isIdleThumbnailPrewarmingForTesting)

        let countAfterCancel = service.thumbnailLoadCallCount
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(
            service.thumbnailLoadCallCount,
            countAfterCancel,
            "interaction should stop further idle prewarm loads"
        )
        XCTAssertLessThan(service.thumbnailLoadCallCount, assets.count)
    }

    func testDisabledPreferenceDoesNotPrewarm() async {
        let sourceID = UUID()
        let asset = makeAsset(sourceID: sourceID, fileName: "idle-off.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .folder,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            thumbnailData: Data("idle-thumb".utf8)
        )
        let preference = InMemoryIdleThumbnailPrewarmPreferenceStore(isEnabled: false)
        let clock = ManualIdlePrewarmClock(now: 0)
        let model = LibraryWorkspaceModel(
            service: service,
            idleThumbnailPrewarmPreferenceStore: preference,
            idlePrewarmClock: clock,
            idlePrewarmThresholdSeconds: 0.05,
            idlePrewarmMonitorTickSeconds: 60,
            idlePrewarmInstallEventMonitor: false
        )
        await model.start()
        clock.now = 1
        model.evaluateIdleThumbnailPrewarmForTesting()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.isIdleThumbnailPrewarmingForTesting)
        XCTAssertEqual(service.thumbnailLoadCallCount, 0)
    }

    func testIdlePrewarmGeneratesMissingFeaturePrintCache() async {
        let sourceID = UUID()
        let asset = makeAsset(sourceID: sourceID, fileName: "idle-fp.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .folder,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            thumbnailData: Data("idle-thumb".utf8)
        )
        let featureLoader = RecordingIdleFeaturePrintLoader()
        let preference = InMemoryIdleThumbnailPrewarmPreferenceStore(isEnabled: true)
        let clock = ManualIdlePrewarmClock(now: 0)
        let model = LibraryWorkspaceModel(
            service: service,
            idleFeaturePrintCache: featureLoader,
            idleThumbnailPrewarmPreferenceStore: preference,
            idlePrewarmClock: clock,
            idlePrewarmThresholdSeconds: 0.05,
            idlePrewarmMonitorTickSeconds: 60,
            idlePrewarmInstallEventMonitor: false
        )
        await model.start()
        clock.now = 1
        model.evaluateIdleThumbnailPrewarmForTesting()

        let deadline = Date().addingTimeInterval(3)
        while featureLoader.generateCallCount == 0, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(featureLoader.generateCallCount, 1)
        XCTAssertEqual(featureLoader.generatedAssetIDs, [asset.assetID])
    }

    func testIdlePrewarmSkipsCachedFeaturePrint() async {
        let sourceID = UUID()
        let asset = makeAsset(sourceID: sourceID, fileName: "idle-fp-hit.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .folder,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            thumbnailData: Data("idle-thumb".utf8)
        )
        let featureLoader = RecordingIdleFeaturePrintLoader(cachedAssetIDs: [asset.assetID])
        let preference = InMemoryIdleThumbnailPrewarmPreferenceStore(isEnabled: true)
        let clock = ManualIdlePrewarmClock(now: 0)
        let model = LibraryWorkspaceModel(
            service: service,
            idleFeaturePrintCache: featureLoader,
            idleThumbnailPrewarmPreferenceStore: preference,
            idlePrewarmClock: clock,
            idlePrewarmThresholdSeconds: 0.05,
            idlePrewarmMonitorTickSeconds: 60,
            idlePrewarmInstallEventMonitor: false
        )
        await model.start()
        clock.now = 1
        model.evaluateIdleThumbnailPrewarmForTesting()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(featureLoader.generateCallCount, 0)
    }

    func testIdlePrewarmGeneratesMissingEmbeddingCache() async {
        let sourceID = UUID()
        let asset = makeAsset(sourceID: sourceID, fileName: "idle-embed.jpg")
        let previewData = Data("idle-preview".utf8)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .folder,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            previewData: previewData,
            thumbnailData: Data("idle-thumb".utf8)
        )
        let embeddingCache = RecordingIdleEmbeddingCache()
        let preference = InMemoryIdleThumbnailPrewarmPreferenceStore(isEnabled: true)
        let clock = ManualIdlePrewarmClock(now: 0)
        let model = LibraryWorkspaceModel(
            service: service,
            selectedAssetEmbeddingCache: embeddingCache,
            idleThumbnailPrewarmPreferenceStore: preference,
            idlePrewarmClock: clock,
            idlePrewarmThresholdSeconds: 0.05,
            idlePrewarmMonitorTickSeconds: 60,
            idlePrewarmInstallEventMonitor: false
        )
        await model.start()
        clock.now = 1
        model.evaluateIdleThumbnailPrewarmForTesting()

        let deadline = Date().addingTimeInterval(3)
        while embeddingCache.cacheCallCount == 0, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(embeddingCache.cacheCallCount, 1)
        XCTAssertEqual(embeddingCache.cachedAssetIDsCalled, [asset.assetID])
        XCTAssertEqual(embeddingCache.lastPreviewData, previewData)
    }

    func testIdlePrewarmSkipsCachedEmbedding() async {
        let sourceID = UUID()
        let asset = makeAsset(sourceID: sourceID, fileName: "idle-embed-hit.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .folder,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            previewData: Data("idle-preview".utf8),
            thumbnailData: Data("idle-thumb".utf8)
        )
        let embeddingCache = RecordingIdleEmbeddingCache(cachedAssetIDs: [asset.assetID])
        let preference = InMemoryIdleThumbnailPrewarmPreferenceStore(isEnabled: true)
        let clock = ManualIdlePrewarmClock(now: 0)
        let model = LibraryWorkspaceModel(
            service: service,
            selectedAssetEmbeddingCache: embeddingCache,
            idleThumbnailPrewarmPreferenceStore: preference,
            idlePrewarmClock: clock,
            idlePrewarmThresholdSeconds: 0.05,
            idlePrewarmMonitorTickSeconds: 60,
            idlePrewarmInstallEventMonitor: false
        )
        await model.start()
        clock.now = 1
        model.evaluateIdleThumbnailPrewarmForTesting()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(embeddingCache.cacheCallCount, 1)
        XCTAssertEqual(service.previewLoadCallCount, 0)
    }

    func testIdlePrewarmSkipsEmbeddingWhenModelUnavailable() async {
        let sourceID = UUID()
        let asset = makeAsset(sourceID: sourceID, fileName: "idle-embed-off.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .folder,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            previewData: Data("idle-preview".utf8),
            thumbnailData: Data("idle-thumb".utf8)
        )
        let embeddingCache = RecordingIdleEmbeddingCache(
            failure: AppSelectedAssetEmbeddingCacheError.modelUnavailable
        )
        let preference = InMemoryIdleThumbnailPrewarmPreferenceStore(isEnabled: true)
        let clock = ManualIdlePrewarmClock(now: 0)
        let model = LibraryWorkspaceModel(
            service: service,
            selectedAssetEmbeddingCache: embeddingCache,
            idleThumbnailPrewarmPreferenceStore: preference,
            idlePrewarmClock: clock,
            idlePrewarmThresholdSeconds: 0.05,
            idlePrewarmMonitorTickSeconds: 60,
            idlePrewarmInstallEventMonitor: false
        )
        await model.start()
        clock.now = 1
        model.evaluateIdleThumbnailPrewarmForTesting()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(embeddingCache.cacheCallCount, 1)
        XCTAssertEqual(service.previewLoadCallCount, 0)
    }

    func testUserInteractionCancelsIdleFeaturePrintPrewarm() async {
        let sourceID = UUID()
        let assets = (0 ..< 4).map { makeAsset(sourceID: sourceID, fileName: "idle-fp-\($0).jpg") }
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .folder,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: assets,
            initialItems: assets,
            startsConnected: true,
            thumbnailData: Data("idle-thumb".utf8)
        )
        let featureLoader = RecordingIdleFeaturePrintLoader(generateDelayNanoseconds: 200_000_000)
        let preference = InMemoryIdleThumbnailPrewarmPreferenceStore(isEnabled: true)
        let clock = ManualIdlePrewarmClock(now: 0)
        let model = LibraryWorkspaceModel(
            service: service,
            idleFeaturePrintCache: featureLoader,
            idleThumbnailPrewarmPreferenceStore: preference,
            idlePrewarmClock: clock,
            idlePrewarmThresholdSeconds: 0.1,
            idlePrewarmMonitorTickSeconds: 60,
            idlePrewarmInstallEventMonitor: false
        )
        await model.start()

        clock.now = 0.2
        model.evaluateIdleThumbnailPrewarmForTesting()
        XCTAssertTrue(model.isIdleThumbnailPrewarmingForTesting)

        let deadline = Date().addingTimeInterval(1)
        while featureLoader.generateCallCount == 0, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(featureLoader.generateCallCount, 1)

        model.noteUserInteractionForIdlePrewarm()
        XCTAssertFalse(model.isIdleThumbnailPrewarmingForTesting)

        let countAfterCancel = featureLoader.generateCallCount
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(
            featureLoader.generateCallCount,
            countAfterCancel,
            "interaction should stop further idle feature-print loads"
        )
        XCTAssertLessThan(featureLoader.generateCallCount, assets.count)
    }

    func testUserInteractionCancelsIdleEmbeddingPrewarm() async {
        let sourceID = UUID()
        let assets = (0 ..< 4).map { makeAsset(sourceID: sourceID, fileName: "idle-embed-\($0).jpg") }
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .folder,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: assets,
            initialItems: assets,
            startsConnected: true,
            previewData: Data("idle-preview".utf8),
            thumbnailData: Data("idle-thumb".utf8)
        )
        let embeddingCache = RecordingIdleEmbeddingCache(cacheDelayNanoseconds: 200_000_000)
        let preference = InMemoryIdleThumbnailPrewarmPreferenceStore(isEnabled: true)
        let clock = ManualIdlePrewarmClock(now: 0)
        let model = LibraryWorkspaceModel(
            service: service,
            selectedAssetEmbeddingCache: embeddingCache,
            idleThumbnailPrewarmPreferenceStore: preference,
            idlePrewarmClock: clock,
            idlePrewarmThresholdSeconds: 0.1,
            idlePrewarmMonitorTickSeconds: 60,
            idlePrewarmInstallEventMonitor: false
        )
        await model.start()

        clock.now = 0.2
        model.evaluateIdleThumbnailPrewarmForTesting()
        XCTAssertTrue(model.isIdleThumbnailPrewarmingForTesting)

        let deadline = Date().addingTimeInterval(1)
        while embeddingCache.cacheCallCount == 0, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(embeddingCache.cacheCallCount, 1)

        model.noteUserInteractionForIdlePrewarm()
        XCTAssertFalse(model.isIdleThumbnailPrewarmingForTesting)

        let countAfterCancel = embeddingCache.cacheCallCount
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(
            embeddingCache.cacheCallCount,
            countAfterCancel,
            "interaction should stop further idle embedding loads"
        )
        XCTAssertLessThan(embeddingCache.cacheCallCount, assets.count)
    }

    private func makeAsset(sourceID: UUID, fileName: String) -> AssetGridItemProjection {
        AssetGridItemProjection(
            assetID: UUID(),
            sourceID: sourceID,
            sourceDisplayName: "Fixture",
            sourceState: .active,
            relativePath: fileName,
            fileName: fileName,
            mediaType: "public.jpeg",
            mediaCreatedAtMs: 1,
            mediaModifiedAtMs: 1,
            width: 32,
            height: 32,
            availability: .available,
            contentRevision: 1,
            acceptedTagCount: 0,
            rejectedTagCount: 0
        )
    }
}

private final class InMemoryIdleThumbnailPrewarmPreferenceStore:
    IdleThumbnailPrewarmPreferenceStore,
    @unchecked Sendable
{
    var isEnabled: Bool

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }
}

private final class ManualIdlePrewarmClock: IdlePrewarmClock, @unchecked Sendable {
    var now: TimeInterval

    init(now: TimeInterval) {
        self.now = now
    }
}

private final class RecordingIdleFeaturePrintLoader: SyncFeatureVectorLoading, @unchecked Sendable {
    private let lock = NSLock()
    private let cachedAssetIDs: Set<UUID>
    private let generateDelayNanoseconds: UInt64
    private(set) var generateCallCount = 0
    private(set) var generatedAssetIDs: [UUID] = []

    init(cachedAssetIDs: Set<UUID> = [], generateDelayNanoseconds: UInt64 = 0) {
        self.cachedAssetIDs = cachedAssetIDs
        self.generateDelayNanoseconds = generateDelayNanoseconds
    }

    func loadCachedSync(assetID: UUID) throws -> FeatureVectorPayload? {
        guard cachedAssetIDs.contains(assetID) else { return nil }
        return FeatureVectorPayload(
            identity: FeatureIdentity(assetID: assetID, contentRevision: 1),
            elementCount: 1,
            vectorData: Data([0]),
            vectorSHA256: Data([0]),
            origin: .cacheHit
        )
    }

    func loadOrGenerateSync(assetID: UUID) throws -> FeatureVectorPayload {
        if let cached = try loadCachedSync(assetID: assetID) {
            return cached
        }
        lock.lock()
        generateCallCount += 1
        generatedAssetIDs.append(assetID)
        lock.unlock()
        if generateDelayNanoseconds > 0 {
            Thread.sleep(forTimeInterval: Double(generateDelayNanoseconds) / 1_000_000_000)
        }
        return FeatureVectorPayload(
            identity: FeatureIdentity(assetID: assetID, contentRevision: 1),
            elementCount: 1,
            vectorData: Data([1]),
            vectorSHA256: Data([1]),
            origin: .generated
        )
    }
}

private final class RecordingIdleEmbeddingCache: AppSelectedAssetEmbeddingCaching, @unchecked Sendable {
    private struct State {
        var cacheCallCount = 0
        var cachedAssetIDsCalled: [UUID] = []
        var lastPreviewData: Data?
    }

    private let lock = NSLock()
    private var state = State()
    private let cachedAssetIDs: Set<UUID>
    private let cacheDelayNanoseconds: UInt64
    private let failure: Error?

    init(
        cachedAssetIDs: Set<UUID> = [],
        cacheDelayNanoseconds: UInt64 = 0,
        failure: Error? = nil
    ) {
        self.cachedAssetIDs = cachedAssetIDs
        self.cacheDelayNanoseconds = cacheDelayNanoseconds
        self.failure = failure
    }

    var cacheCallCount: Int {
        lock.withLock { state.cacheCallCount }
    }

    var cachedAssetIDsCalled: [UUID] {
        lock.withLock { state.cachedAssetIDsCalled }
    }

    var lastPreviewData: Data? {
        lock.withLock { state.lastPreviewData }
    }

    func cacheSelectedAsset(
        assetID: UUID,
        contentRevision: Int,
        imageData: @escaping @Sendable () async throws -> Data
    ) async throws -> AppCoreMLCachedEmbedding {
        if cacheDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: cacheDelayNanoseconds)
        }
        lock.withLock {
            state.cacheCallCount += 1
            state.cachedAssetIDsCalled.append(assetID)
        }

        if let failure { throw failure }

        let identity = AppCoreMLModelIdentity(
            provider: "dinov2",
            modelID: "facebook/dinov2-small",
            modelRevision: "fixture",
            preprocessingRevision: "fixture",
            embeddingSemantics: "fixture",
            postprocessingRevision: "fixture",
            elementType: "float32",
            elementCount: 1,
            sourceModelSHA256: String(repeating: "1", count: 64),
            artifactSHA256: String(repeating: "2", count: 64),
            manifestSHA256: String(repeating: "3", count: 64),
            licenseID: "Apache-2.0",
            licenseSHA256: String(repeating: "4", count: 64)
        )
        if cachedAssetIDs.contains(assetID) {
            return AppCoreMLCachedEmbedding(
                identity: identity,
                values: [0.5],
                vectorSHA256: String(repeating: "5", count: 64),
                origin: .cacheHit
            )
        }
        let data = try await imageData()
        lock.withLock {
            state.lastPreviewData = data
        }
        return AppCoreMLCachedEmbedding(
            identity: identity,
            values: [0.5],
            vectorSHA256: String(repeating: "5", count: 64),
            origin: .generated
        )
    }
}
