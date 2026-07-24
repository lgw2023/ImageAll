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
