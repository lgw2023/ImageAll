import XCTest
@testable import ImageAll

@MainActor
final class SourceThumbnailPrewarmTests: XCTestCase {
    func testSourcePrewarmPagesThroughAllAssetsAndLoadsThumbnails() async {
        let sourceID = UUID()
        let assets = (0 ..< 5).map { makeAsset(sourceID: sourceID, fileName: "prewarm-\($0).jpg") }
        let payload = Data("source-prewarm".utf8)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .folder,
                displayName: "Fixture Source",
                state: .active
            ),
            reconciledItems: assets,
            initialItems: assets,
            startsConnected: true,
            thumbnailData: payload,
            assetPageSize: 2,
            hasPendingCatalogReconcileJobs: false
        )
        let model = LibraryWorkspaceModel(
            service: service,
            idlePrewarmInstallEventMonitor: false
        )
        await model.start()
        XCTAssertEqual(model.sources.map(\.id), [sourceID])

        let fetchesBefore = service.assetPageFetchCallCount
        model.prewarmSourceThumbnails(sourceID: sourceID)

        let deadline = Date().addingTimeInterval(5)
        while model.isPrewarmingSourceThumbnails, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(model.isPrewarmingSourceThumbnails)
        XCTAssertGreaterThanOrEqual(service.assetPageFetchCallCount - fetchesBefore, 3)
        XCTAssertEqual(service.thumbnailLoadCallCount, assets.count)
        XCTAssertEqual(
            model.notice,
            .sourceThumbnailPrewarmCompleted(
                sourceDisplayName: "Fixture Source",
                warmed: assets.count,
                failed: 0,
                total: assets.count
            )
        )
        for asset in assets {
            XCTAssertEqual(model.cachedThumbnailData(for: asset.assetID), payload)
        }
    }

    func testCancelStopsFurtherSourcePrewarmLoads() async {
        let sourceID = UUID()
        let assets = (0 ..< 6).map { makeAsset(sourceID: sourceID, fileName: "cancel-\($0).jpg") }
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .folder,
                displayName: "Cancel Source",
                state: .active
            ),
            reconciledItems: assets,
            initialItems: assets,
            startsConnected: true,
            thumbnailData: Data("source-prewarm".utf8),
            thumbnailLoadDelayNanoseconds: 40_000_000,
            hasPendingCatalogReconcileJobs: false
        )
        let model = LibraryWorkspaceModel(
            service: service,
            idlePrewarmInstallEventMonitor: false
        )
        await model.start()

        model.prewarmSourceThumbnails(sourceID: sourceID)
        let startDeadline = Date().addingTimeInterval(2)
        while service.thumbnailLoadCallCount == 0, Date() < startDeadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(service.thumbnailLoadCallCount, 1)

        model.cancelSourceThumbnailPrewarm()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(model.isPrewarmingSourceThumbnails)
        guard case let .sourceThumbnailPrewarmCancelled(name, _, _)? = model.notice else {
            return XCTFail("expected cancelled notice, got \(String(describing: model.notice))")
        }
        XCTAssertEqual(name, "Cancel Source")
        XCTAssertLessThan(service.thumbnailLoadCallCount, assets.count)
    }

    func testSecondPrewarmIgnoredWhileFirstRunning() async {
        let sourceID = UUID()
        let otherSourceID = UUID()
        let assets = (0 ..< 3).map { makeAsset(sourceID: sourceID, fileName: "once-\($0).jpg") }
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .folder,
                displayName: "Primary",
                state: .active
            ),
            reconciledItems: assets,
            initialItems: assets,
            startsConnected: true,
            additionalSources: [
                LibrarySourceSummary(
                    id: otherSourceID,
                    kind: .folder,
                    displayName: "Secondary",
                    state: .active
                ),
            ],
            thumbnailData: Data("source-prewarm".utf8),
            thumbnailLoadDelayNanoseconds: 30_000_000,
            hasPendingCatalogReconcileJobs: false
        )
        let model = LibraryWorkspaceModel(
            service: service,
            idlePrewarmInstallEventMonitor: false
        )
        await model.start()

        model.prewarmSourceThumbnails(sourceID: sourceID)
        let startDeadline = Date().addingTimeInterval(2)
        while !model.isPrewarmingSourceThumbnails || service.thumbnailLoadCallCount == 0,
              Date() < startDeadline
        {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(model.isPrewarmingSourceThumbnails)

        model.prewarmSourceThumbnails(sourceID: otherSourceID)
        XCTAssertEqual(model.sourceThumbnailPrewarmProgress?.sourceID, sourceID)

        let doneDeadline = Date().addingTimeInterval(3)
        while model.isPrewarmingSourceThumbnails, Date() < doneDeadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(model.isPrewarmingSourceThumbnails)
        XCTAssertEqual(service.thumbnailLoadCallCount, assets.count)
        XCTAssertEqual(
            model.notice,
            .sourceThumbnailPrewarmCompleted(
                sourceDisplayName: "Primary",
                warmed: assets.count,
                failed: 0,
                total: assets.count
            )
        )
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
            width: 100,
            height: 100,
            availability: .available,
            contentRevision: 1,
            acceptedTagCount: 0,
            rejectedTagCount: 0
        )
    }
}
