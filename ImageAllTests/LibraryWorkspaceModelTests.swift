import Foundation
import XCTest
@testable import ImageAll

@MainActor
final class LibraryWorkspaceModelTests: XCTestCase {
    func testPortableExportPublishesVisibleSuccessNotice() async {
        let sourceID = UUID()
        let parentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAll-Export-Parent", isDirectory: true)
        let bundleURL = parentURL.appendingPathComponent("ImageAll-Export-20260717-010203Z")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [],
            exportParentURL: parentURL,
            portableExportResult: PortableCatalogExportResult(
                bundleURL: bundleURL,
                totalRecordCount: 12
            )
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.exportPortableUserData()

        XCTAssertEqual(service.portableExportCallCount, 1)
        XCTAssertEqual(
            model.notice,
            .portableExportCompleted(
                bundleName: "ImageAll-Export-20260717-010203Z",
                recordCount: 12
            )
        )
        XCTAssertFalse(model.isExportingPortableData)
    }

    func testPortableExportCancellationIsSilent() async {
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: UUID(),
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: []
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.exportPortableUserData()

        XCTAssertEqual(service.portableExportCallCount, 0)
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.isExportingPortableData)
    }

    func testPortableExportFailurePublishesSafeNotice() async {
        let parentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAll-Export-Parent", isDirectory: true)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: UUID(),
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [],
            exportParentURL: parentURL,
            portableExportFails: true
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.exportPortableUserData()

        XCTAssertEqual(model.notice, .portableExportFailed)
        XCTAssertFalse(model.isExportingPortableData)
    }

    func testPortableExportSourceOverlapPublishesActionableNotice() async {
        let parentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAll-Export-Parent", isDirectory: true)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: UUID(),
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [],
            exportParentURL: parentURL,
            portableExportError: PortableCatalogExportError.destinationOverlapsSource
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.exportPortableUserData()

        XCTAssertEqual(model.notice, .portableExportDestinationOverlapsSource)
        XCTAssertFalse(model.isExportingPortableData)
    }

    func testPortableExportIndeterminateIsolationPublishesActionableNotice() async {
        let parentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAll-Export-Parent", isDirectory: true)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: UUID(),
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [],
            exportParentURL: parentURL,
            portableExportError: PortableCatalogExportError.destinationIsolationIndeterminate
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.exportPortableUserData()

        XCTAssertEqual(model.notice, .portableExportIsolationIndeterminate)
        XCTAssertFalse(model.isExportingPortableData)
    }

    func testPortableExportSourceOverlapNoticeExplainsSafeRecovery() {
        XCTAssertEqual(
            LibraryWorkspaceView.noticeText(.portableExportDestinationOverlapsSource),
            "导出位置不能与已添加的文件夹来源重叠，请选择其他文件夹。"
        )
    }

    func testPortableExportIndeterminateIsolationNoticeFailsClosed() {
        XCTAssertEqual(
            LibraryWorkspaceView.noticeText(.portableExportIsolationIndeterminate),
            "无法确认导出位置与来源隔离，尚未开始导出。请重新授权来源或选择其他位置；仍失败时请停止导出。"
        )
    }

    func testPreviewCacheClearRefreshesUsageAndPublishesSuccess() async {
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: UUID(),
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [],
            previewCacheUsage: DerivedImageCacheUsage(
                entryCount: 2,
                registeredBytes: 300
            ),
            previewCacheClearResult: DerivedImageCacheClearResult(
                removedEntries: 2,
                registeredBytesInvalidated: 300,
                removedObjects: 2,
                removedBytes: 300,
                partialReclaim: false
            )
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.refreshPreviewCacheUsage()
        XCTAssertEqual(
            model.previewCacheUsage,
            DerivedImageCacheUsage(entryCount: 2, registeredBytes: 300)
        )

        await model.clearPreviewCache()

        XCTAssertEqual(service.previewCacheClearCallCount, 1)
        XCTAssertEqual(model.previewCacheUsage, .zero)
        XCTAssertEqual(
            model.notice,
            .previewCacheCleared(removedEntries: 2, partialReclaim: false)
        )
        XCTAssertFalse(model.isClearingPreviewCache)
    }

    func testPreviewCacheClearFailureKeepsUsageAndPublishesSafeNotice() async {
        let usage = DerivedImageCacheUsage(entryCount: 2, registeredBytes: 300)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: UUID(),
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [],
            previewCacheUsage: usage,
            previewCacheClearFails: true
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.refreshPreviewCacheUsage()

        await model.clearPreviewCache()

        XCTAssertEqual(model.previewCacheUsage, usage)
        XCTAssertEqual(model.notice, .previewCacheActionFailed)
        XCTAssertFalse(model.isClearingPreviewCache)
    }

    func testJobActivityActionRefreshesRowsAfterSuccess() async {
        let jobID = UUID()
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: UUID(),
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [],
            jobActivityItems: [
                JobActivityItem(
                    id: jobID,
                    kind: .folderReconcile,
                    state: .pending,
                    controlRequest: .none,
                    progress: JobProgress(completed: 2, total: 10)
                ),
            ]
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.refreshJobActivity()

        await model.applyJobActivityAction(.pause, to: jobID)

        XCTAssertEqual(service.jobActivityActionCallCount, 1)
        XCTAssertGreaterThanOrEqual(service.jobActivityFetchCallCount, 2)
        XCTAssertEqual(model.jobActivityItems.first?.state, .paused)
        XCTAssertEqual(model.jobActivityItems.first?.availableActions, [.resume, .cancel])
        XCTAssertFalse(model.isApplyingJobActivityAction(jobID))
        XCTAssertNil(model.notice)
    }

    func testJobActivityActionFailureRequeriesCurrentFactsAndPublishesSafeNotice() async {
        let jobID = UUID()
        let completed = JobActivityItem(
            id: jobID,
            kind: .personalizationSuggestions,
            state: .completed,
            controlRequest: .none,
            progress: JobProgress(completed: 10, total: 10)
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: UUID(),
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [],
            jobActivityItems: [
                JobActivityItem(
                    id: jobID,
                    kind: .personalizationSuggestions,
                    state: .running,
                    controlRequest: .none,
                    progress: JobProgress(completed: 9, total: 10)
                ),
            ],
            jobActivityActionFails: true,
            jobActivityItemsAfterFailedAction: [completed]
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.refreshJobActivity()

        await model.applyJobActivityAction(.cancel, to: jobID)

        XCTAssertEqual(service.jobActivityActionCallCount, 1)
        XCTAssertGreaterThanOrEqual(service.jobActivityFetchCallCount, 2)
        XCTAssertEqual(model.jobActivityItems, [completed])
        XCTAssertEqual(model.notice, .jobActivityActionFailed)
        XCTAssertFalse(model.isApplyingJobActivityAction(jobID))
    }

    func testStartupShowsExistingCatalogBeforePendingReconcileFinishes() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "already-indexed.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            blocksReconcileRuns: true
        )
        let model = LibraryWorkspaceModel(service: service)

        let startup = Task { await model.start() }
        while !service.hasStartedBlockedReconcile {
            await Task.yield()
        }

        XCTAssertEqual(model.phase, .content)
        XCTAssertEqual(model.items.map(\.assetID), [asset.assetID])

        service.releaseBlockedReconcile()
        await startup.value
        await waitForCatalogScanToFinish(model)
    }

    func testFolderMonitoringChangeRunsAutomaticReconcile() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "auto-added.png")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            startsConnected: true
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.start()
        await waitForCatalogScanToFinish(model)
        XCTAssertEqual(service.reconcileRunCount, 1)

        service.triggerFolderMonitoringChange()

        for _ in 0 ..< 10_000 where service.reconcileRunCount < 2 {
            await Task.yield()
        }
        await waitForCatalogScanToFinish(model)
        XCTAssertEqual(service.reconcileRunCount, 2)
        XCTAssertEqual(model.items.map(\.assetID), [asset.assetID])
    }

    func testBackgroundScanPublishesProgressAndFirstBatchBeforeCompletion() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "first-photo.jpg")
        let progress = CatalogReconcileProgress(
            sourceKind: .photos,
            sourceDisplayName: "Apple Photos",
            completed: 200,
            total: 9_480
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .photos,
                displayName: "Apple Photos",
                state: .active
            ),
            reconciledItems: [asset],
            startsConnected: true,
            blocksReconcileRuns: true,
            catalogReconcileProgress: progress
        )
        let model = LibraryWorkspaceModel(
            service: service,
            catalogProgressRefreshInterval: .milliseconds(1)
        )

        await model.start()
        while !service.hasStartedBlockedReconcile {
            await Task.yield()
        }
        service.publishReconciledItems()
        await waitForCatalogProgress(progress, model: model)
        await waitForItems([asset.assetID], model: model)

        XCTAssertTrue(model.isCatalogScanning)
        service.releaseBlockedReconcile()
        await waitForCatalogScanToFinish(model)
    }

    func testConnectPhotosRunsPhotosReconcileAndLoadsUnifiedGrid() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "IMG_0001.HEIC")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .photos,
                displayName: "Apple Photos",
                state: .active
            ),
            reconciledItems: [asset]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        XCTAssertEqual(model.phase, .empty)

        await model.connectPhotos()
        await waitForCatalogScanToFinish(model)

        XCTAssertEqual(model.phase, .content)
        XCTAssertEqual(model.sources.map(\.kind), [.photos])
        XCTAssertEqual(model.items.map(\.assetID), [asset.assetID])
        XCTAssertEqual(service.photosConnectCallCount, 1)
        XCTAssertEqual(service.photosReconcileRunCount, 1)
    }

    func testExplicitPhotosRebindKeepsHistoricalSourceAndRunsNewSourceReconcile() async {
        let historicalSourceID = UUID()
        let activeSourceID = UUID()
        let activeAsset = Self.makeAsset(sourceID: activeSourceID, fileName: "Current.HEIC")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: historicalSourceID,
                kind: .photos,
                displayName: "Apple Photos",
                state: .unavailable
            ),
            reconciledItems: [activeAsset],
            startsConnected: true,
            reboundSource: LibrarySourceSummary(
                id: activeSourceID,
                kind: .photos,
                displayName: "Apple Photos",
                state: .active
            )
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.start()
        await waitForCatalogScanToFinish(model)
        let reconcileRunsBeforeRebind = service.photosReconcileRunCount

        await model.rebindPhotos(from: historicalSourceID)
        await waitForCatalogScanToFinish(model)

        XCTAssertEqual(model.sources.map(\.id), [historicalSourceID, activeSourceID])
        XCTAssertEqual(model.sources.map(\.state), [.unavailable, .active])
        XCTAssertEqual(model.items.map(\.assetID), [activeAsset.assetID])
        XCTAssertEqual(service.photosRebindCallCount, 1)
        XCTAssertEqual(service.photosConnectCallCount, 0)
        XCTAssertEqual(service.photosReconcileRunCount, reconcileRunsBeforeRebind + 1)
    }

    func testSelectedPhotosSourceIsExposedForEmptyStateGuidance() async {
        let sourceID = UUID()
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .photos,
                displayName: "Apple Photos",
                state: .active
            ),
            reconciledItems: [],
            startsConnected: true
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.selectSource(sourceID)

        XCTAssertTrue(model.selectedSourceIsPhotos)
    }

    func testExplicitCloudPreviewDownloadPublishesProgressAndBecomesGridThumbnail() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "cloud.jpg")
        let downloaded = Data("downloaded-preview".utf8)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .photos,
                displayName: "Apple Photos",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            previewError: .cloudOnly,
            cloudPreviewData: downloaded,
            cloudPreviewProgress: [0.4, 1.0]
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.start()
        await model.selectAsset(asset.assetID)

        let localPreview = await model.previewData(assetID: asset.assetID)
        XCTAssertNil(localPreview)
        XCTAssertEqual(model.cloudPreviewState, .available(assetID: asset.assetID))
        XCTAssertEqual(service.cloudPreviewDownloadCallCount, 0)

        model.downloadCloudPreview(assetID: asset.assetID)
        await waitForCloudPreviewState(
            .downloading(assetID: asset.assetID, progress: 0.4),
            model: model
        )
        await waitForCloudPreviewState(
            .downloaded(assetID: asset.assetID, data: downloaded),
            model: model
        )

        let gridThumbnail = await model.thumbnailData(assetID: asset.assetID)

        XCTAssertEqual(gridThumbnail, downloaded)
        XCTAssertEqual(service.thumbnailLoadCallCount, 0)
        XCTAssertEqual(service.cloudPreviewDownloadCallCount, 1)
    }

    func testCloudPreviewFailureCanRetryTheCurrentAsset() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "retry-cloud.jpg")
        let downloaded = Data("retried-preview".utf8)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .photos,
                displayName: "Apple Photos",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            previewError: .cloudOnly,
            cloudPreviewData: downloaded,
            cloudPreviewProgress: [0.25],
            cloudPreviewFailureCount: 1
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.start()
        await model.selectAsset(asset.assetID)
        _ = await model.previewData(assetID: asset.assetID)

        model.downloadCloudPreview(assetID: asset.assetID)
        await waitForCloudPreviewState(.failed(assetID: asset.assetID), model: model)

        model.retryCloudPreviewDownload(assetID: asset.assetID)
        await waitForCloudPreviewState(
            .downloaded(assetID: asset.assetID, data: downloaded),
            model: model
        )
        XCTAssertEqual(service.cloudPreviewDownloadCallCount, 2)
    }

    func testCloudPreviewDownloadCanBeCancelledWithoutChangingSelection() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "cancel-cloud.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .photos,
                displayName: "Apple Photos",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            previewError: .cloudOnly,
            cloudPreviewData: Data("should-not-publish".utf8),
            cloudPreviewProgress: [0.2, 0.6, 1.0]
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.start()
        await model.selectAsset(asset.assetID)
        _ = await model.previewData(assetID: asset.assetID)

        model.downloadCloudPreview(assetID: asset.assetID)
        await waitForCloudPreviewState(
            .downloading(assetID: asset.assetID, progress: 0.2),
            model: model
        )
        model.cancelCloudPreviewDownload(assetID: asset.assetID)
        await waitForCloudPreviewState(.available(assetID: asset.assetID), model: model)
        for _ in 0 ..< 10_000 where service.cloudPreviewCancellationCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(model.primarySelectedAssetID, asset.assetID)
        XCTAssertEqual(service.cloudPreviewCancellationCount, 1)
    }

    func testConnectFolderRunsReconcileAndLoadsFirstPage() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        XCTAssertEqual(model.phase, .empty)

        await model.connectFolder()
        await waitForCatalogScanToFinish(model)

        XCTAssertEqual(model.phase, .content)
        XCTAssertEqual(model.sources.map(\.id), [sourceID])
        XCTAssertEqual(model.items.map(\.assetID), [asset.assetID])
        XCTAssertEqual(service.reconcileRunCount, 1)
    }

    func testFirstUseGuideAppearsOnlyUntilTheNewCatalogGetsItsFirstSetupFact() async {
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: UUID(),
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: []
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()

        XCTAssertTrue(model.showsFirstUseGuide)

        await model.installPresetTags()

        XCTAssertFalse(model.showsFirstUseGuide)
    }

    func testRescanSelectedPhotosSourceRevalidatesAuthorizationBeforeSync() async {
        let sourceID = UUID()
        let source = LibrarySourceSummary(
            id: sourceID,
            kind: .photos,
            displayName: "Apple Photos",
            state: .active
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: source,
            reconciledItems: [],
            startsConnected: true
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await waitForCatalogScanToFinish(model)
        await model.selectSource(sourceID)
        await model.rescan()
        await waitForCatalogScanToFinish(model)

        XCTAssertEqual(service.photosConnectCallCount, 1)
    }

    func testPhotosAuthorizationFailureRefreshesSourceAndShowsAuthorizationNotice() async {
        let sourceID = UUID()
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .photos,
                displayName: "Apple Photos",
                state: .active
            ),
            reconciledItems: [],
            startsConnected: true,
            photosAuthorizationFails: true
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await waitForCatalogScanToFinish(model)

        XCTAssertEqual(model.phase, .content)
        XCTAssertEqual(model.sources.first?.state, .authorizationRequired)
        XCTAssertEqual(model.notice, .photosAuthorizationRequired)
    }

    func testReauthorizingSourceRestoresActiveStateAndRunsReconcile() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .authorizationRequired
            ),
            reconciledItems: [asset]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        XCTAssertEqual(model.sources.first?.state, .authorizationRequired)

        await model.reauthorizeSource(sourceID)
        await waitForCatalogScanToFinish(model)

        XCTAssertEqual(model.sources.first?.state, .active)
        XCTAssertEqual(model.items.map(\.assetID), [asset.assetID])
        XCTAssertEqual(service.reauthorizeCallCount, 1)
        XCTAssertEqual(service.reconcileRunCount, 2)
    }

    func testDisablingSourceKeepsCatalogItemsAndMarksSourceDisabled() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.disableSource(sourceID)

        XCTAssertEqual(model.sources.first?.state, .disabled)
        XCTAssertEqual(model.items.map(\.assetID), [asset.assetID])
        XCTAssertEqual(service.disableCallCount, 1)
        XCTAssertEqual(service.reconcileRunCount, 1)
    }

    func testSourceActionFailureKeepsVisibleCatalogAndShowsNotice() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            sourceMutationFails: true
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.disableSource(sourceID)

        XCTAssertEqual(model.phase, .content)
        XCTAssertEqual(model.sources.first?.state, .active)
        XCTAssertEqual(model.items.map(\.assetID), [asset.assetID])
        XCTAssertEqual(model.notice, .sourceActionFailed)
    }

    func testScanFailureIsVisibleInsteadOfLookingLikeAnEmptyLibrary() async {
        let sourceID = UUID()
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [],
            scanFails: true
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)

        XCTAssertEqual(model.phase, .failed(.scanFailed))
        XCTAssertEqual(model.sources.map(\.id), [sourceID])
    }

    func testSelectedAssetCanBeAcceptedAndUndoneFromInspector() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            tags: [tag]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(asset.assetID)

        XCTAssertEqual(model.inspectorTags.first?.decision, .unknown)

        await model.applyTagDecision(tagID: tag.id, action: .accept)

        XCTAssertEqual(model.inspectorTags.first?.decision, .accepted)
        XCTAssertEqual(model.items.first?.acceptedTagCount, 1)
        XCTAssertTrue(model.canUndoTagMutation)

        await model.undoLastTagMutation()

        XCTAssertEqual(model.inspectorTags.first?.decision, .unknown)
        XCTAssertEqual(model.items.first?.acceptedTagCount, 0)
        XCTAssertFalse(model.canUndoTagMutation)
    }

    func testSearchAndTagFiltersUseExplicitAnyAndClearHiddenSelection() async {
        let sourceID = UUID()
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "beach.jpg")
        let family = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let print = TagListItem(id: UUID(), displayName: "Print", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [first, second],
            tags: [family, print]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(first.assetID)

        await model.applySearchText("beach")
        await model.toggleAcceptedTagFilter(family.id)
        await model.toggleAcceptedTagFilter(print.id)
        await model.setTagMatchMode(.any)

        XCTAssertTrue(model.selectedAssetIDs.isEmpty)
        XCTAssertEqual(model.items.map(\.assetID), [second.assetID])
        XCTAssertEqual(service.lastFilter.searchText, "beach")
        XCTAssertEqual(service.lastFilter.tagMatchMode, .any)
        XCTAssertEqual(
            Set(service.lastFilter.tagDecisionFilters.map(\.tagID)),
            Set([family.id, print.id])
        )
        XCTAssertTrue(service.lastFilter.tagDecisionFilters.allSatisfy { $0.decision == .accepted })
    }

    func testTypingSearchDebouncesToLatestText() async {
        let sourceID = UUID()
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "beach.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [first, second],
            initialItems: [first, second],
            startsConnected: true
        )
        let model = LibraryWorkspaceModel(
            service: service,
            searchDebounceInterval: .milliseconds(20)
        )

        await model.start()
        await waitForCatalogScanToFinish(model)
        let initialFetchCount = service.assetPageFetchCallCount

        model.scheduleSearchText("first")
        model.scheduleSearchText("beach")
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(model.searchText, "beach")
        XCTAssertEqual(model.items.map(\.assetID), [second.assetID])
        XCTAssertEqual(service.assetPageFetchCallCount, initialFetchCount + 1)
    }

    func testSubmittingSearchRunsImmediatelyAndCancelsDebouncedSearch() async {
        let sourceID = UUID()
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "beach.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [first, second],
            initialItems: [first, second],
            startsConnected: true
        )
        let model = LibraryWorkspaceModel(
            service: service,
            searchDebounceInterval: .milliseconds(20)
        )

        await model.start()
        await waitForCatalogScanToFinish(model)
        let initialFetchCount = service.assetPageFetchCallCount

        model.scheduleSearchText("first")
        await model.submitSearchText("beach")

        XCTAssertEqual(model.searchText, "beach")
        XCTAssertEqual(model.items.map(\.assetID), [second.assetID])
        XCTAssertEqual(service.assetPageFetchCallCount, initialFetchCount + 1)

        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(service.assetPageFetchCallCount, initialFetchCount + 1)
    }

    func testOlderSearchResultCannotReplaceNewerSearch() async {
        let sourceID = UUID()
        let old = Self.makeAsset(sourceID: sourceID, fileName: "old.jpg")
        let new = Self.makeAsset(sourceID: sourceID, fileName: "new.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [old, new],
            initialItems: [old, new],
            startsConnected: true,
            blockedSearchText: "old"
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await waitForCatalogScanToFinish(model)

        let olderSearch = Task { await model.submitSearchText("old") }
        await waitForAssetPageFetchToBlock(service)

        await model.submitSearchText("new")
        XCTAssertEqual(model.items.map(\.assetID), [new.assetID])

        service.releaseBlockedAssetPageFetch()
        await olderSearch.value

        XCTAssertEqual(model.searchText, "new")
        XCTAssertEqual(model.items.map(\.assetID), [new.assetID])
    }

    func testClearingSearchSkipsDebounceDelay() async {
        let sourceID = UUID()
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "beach.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [first, second],
            initialItems: [first, second],
            startsConnected: true
        )
        let model = LibraryWorkspaceModel(
            service: service,
            searchDebounceInterval: .seconds(5)
        )

        await model.start()
        await waitForCatalogScanToFinish(model)
        await model.applySearchText("beach")
        let filteredFetchCount = service.assetPageFetchCallCount

        model.scheduleSearchText("")
        await waitForItems([first.assetID, second.assetID], model: model)

        XCTAssertEqual(model.searchText, "")
        XCTAssertEqual(service.assetPageFetchCallCount, filteredFetchCount + 1)
    }

    func testMultiSelectionShowsMixedStateAndCreatesAcceptedTag() async {
        let sourceID = UUID()
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "second.jpg")
        let family = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [first, second],
            tags: [family]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(first.assetID)
        await model.applyTagDecision(tagID: family.id, action: .accept)
        await model.selectAsset(second.assetID, additive: true)

        XCTAssertEqual(model.inspectorTags.first?.decision, .mixed)

        await model.createAndAcceptTag(named: "Print")

        XCTAssertEqual(model.selectedAssetIDs, Set([first.assetID, second.assetID]))
        XCTAssertEqual(model.tags.map(\.displayName), ["Family", "Print"])
        XCTAssertEqual(
            model.inspectorTags.first(where: { $0.displayName == "Print" })?.decision,
            .accepted
        )
        XCTAssertTrue(model.canUndoTagMutation)
    }

    func testInstallPresetTagsAddsMissingCatalogEntriesAndReportsIdempotence() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let existing = TagListItem(id: UUID(), displayName: "人像", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            tags: [existing]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.installPresetTags()

        XCTAssertEqual(
            Set(model.tags.map(\.displayName)),
            Set(["人像", "风景", "美食", "动物", "植物", "建筑", "旅行", "截图", "文档"])
        )
        XCTAssertEqual(model.notice, .presetTagsInstalled(createdCount: 8))
        XCTAssertEqual(
            LibraryWorkspaceView.noticeText(.presetTagsInstalled(createdCount: 8)),
            "已添加 8 个常用标签；未给照片应用标签。"
        )

        await model.installPresetTags()

        XCTAssertEqual(model.tags.count, 9)
        XCTAssertEqual(model.notice, .presetTagsAlreadyAvailable)
    }

    func testRenameTagRefreshesSidebarAndInspectorPresentation() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            tags: [tag]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(asset.assetID)

        let succeeded = await model.renameTag(tag.id, to: "Loved")

        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.tags.map(\.displayName), ["Loved"])
        XCTAssertEqual(model.inspectorTags.map(\.displayName), ["Loved"])
    }

    func testArchiveTagClearsItsFilterAndKeepsCatalogVisible() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            tags: [tag]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(asset.assetID)
        await model.showAcceptedTag(tag.id)

        let succeeded = await model.archiveTag(tag.id)

        XCTAssertTrue(succeeded)
        XCTAssertTrue(model.tags.isEmpty)
        XCTAssertTrue(model.selectedTagFilterIDs.isEmpty)
        XCTAssertTrue(service.lastFilter.tagDecisionFilters.isEmpty)
        XCTAssertEqual(model.items.map(\.assetID), [asset.assetID])
        XCTAssertTrue(model.inspectorTags.isEmpty)
    }

    func testRenameTagFailureKeepsExistingPresentationAndShowsNotice() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            tags: [tag],
            tagMutationFails: true
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(asset.assetID)

        let succeeded = await model.renameTag(tag.id, to: "Loved")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(model.tags.map(\.displayName), ["Family"])
        XCTAssertEqual(model.inspectorTags.map(\.displayName), ["Family"])
        XCTAssertEqual(model.notice, .tagMutationFailed)
    }

    func testTagMutationFailureIsVisibleAndDoesNotCreateUndoHistory() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            tags: [tag],
            tagMutationFails: true
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(asset.assetID)
        await model.applyTagDecision(tagID: tag.id, action: .accept)

        XCTAssertEqual(model.notice, .tagMutationFailed)
        XCTAssertFalse(model.canUndoTagMutation)
        XCTAssertEqual(model.inspectorTags.first?.decision, .unknown)
    }

    func testSinglePhotoModeMovesPrimarySelectionAndReturnsToGrid() async {
        let sourceID = UUID()
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "second.jpg")
        let third = Self.makeAsset(sourceID: sourceID, fileName: "third.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [first, second, third]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(second.assetID)

        model.toggleSinglePhotoView()
        XCTAssertTrue(model.isSinglePhotoPresented)
        XCTAssertEqual(model.primarySelectedAssetID, second.assetID)

        await model.movePrimarySelection(by: 1)
        XCTAssertTrue(model.isSinglePhotoPresented)
        XCTAssertEqual(model.selectedAssetIDs, [third.assetID])
        XCTAssertEqual(model.inspectorDetail?.assetID, third.assetID)

        await model.movePrimarySelection(by: -1)
        XCTAssertEqual(model.selectedAssetIDs, [second.assetID])
        XCTAssertEqual(model.inspectorDetail?.assetID, second.assetID)

        model.closeSinglePhotoView()
        XCTAssertFalse(model.isSinglePhotoPresented)
        XCTAssertEqual(model.selectedAssetIDs, [second.assetID])
    }

    func testGridNavigationMovesPrimarySelectionByRowsAndColumns() async {
        let sourceID = UUID()
        let assets = (0 ..< 8).map {
            Self.makeAsset(sourceID: sourceID, fileName: "photo-\($0).jpg")
        }
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: assets
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(assets[4].assetID)

        await model.movePrimarySelection(in: .up, columnCount: 3)
        XCTAssertEqual(model.primarySelectedAssetID, assets[1].assetID)

        await model.movePrimarySelection(in: .down, columnCount: 3)
        XCTAssertEqual(model.primarySelectedAssetID, assets[4].assetID)

        await model.movePrimarySelection(in: .left, columnCount: 3)
        XCTAssertEqual(model.primarySelectedAssetID, assets[3].assetID)

        await model.movePrimarySelection(in: .right, columnCount: 3)
        XCTAssertEqual(model.primarySelectedAssetID, assets[4].assetID)
        XCTAssertEqual(model.selectedAssetIDs.count, 1)
    }

    func testGridNavigationLoadsNextPageBeforeMovingDownPastLoadedItems() async {
        let sourceID = UUID()
        let assets = (0 ..< 6).map {
            Self.makeAsset(sourceID: sourceID, fileName: "photo-\($0).jpg")
        }
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: assets,
            assetPageSize: 4
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        XCTAssertEqual(model.items.map(\.assetID), Array(assets.prefix(4)).map(\.assetID))
        await model.selectAsset(assets[2].assetID)

        await model.movePrimarySelection(in: .down, columnCount: 3)

        XCTAssertEqual(model.primarySelectedAssetID, assets[5].assetID)
        XCTAssertEqual(model.items.map(\.assetID), assets.map(\.assetID))
    }

    func testAdaptiveGridColumnCountTracksAvailableWidthAndDensity() {
        XCTAssertEqual(
            LibraryGridLayout.columnCount(containerWidth: 900, density: .standard),
            6
        )
        XCTAssertEqual(
            LibraryGridLayout.columnCount(containerWidth: 430, density: .standard),
            2
        )
        XCTAssertEqual(
            LibraryGridLayout.columnCount(containerWidth: 100, density: .large),
            1
        )
    }

    func testCommandPaletteListsOnlyImplementedCoreAndLibraryActions() async {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [],
            tags: [tag],
            startsConnected: true
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await waitForCatalogScanToFinish(model)

        let commands = model.workspaceCommands(matching: "")

        XCTAssertEqual(
            Set(commands.map(\.command)),
            [
                .showAllPhotos,
                .showReviewSuggestions,
                .showActivity,
                .showSource(sourceID),
                .showTag(tag.id),
                .acceptTag(tag.id),
                .rejectTag(tag.id),
                .clearTagDecision(tag.id),
                .createTag,
                .connectFolder,
                .rescanCurrentSource,
                .toggleSinglePhoto,
                .showKeyboardShortcuts,
            ]
        )
        XCTAssertEqual(commands.first(where: { $0.command == .showSource(sourceID) })?.title, "前往来源：Fixture")
        XCTAssertEqual(commands.first(where: { $0.command == .showTag(tag.id) })?.title, "前往标签：Family")
    }

    func testCommandPaletteSearchMatchesDynamicCommandTitles() async {
        let sourceID = UUID()
        let family = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let travel = TagListItem(id: UUID(), displayName: "Travel", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [],
            tags: [family, travel],
            startsConnected: true
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await waitForCatalogScanToFinish(model)

        XCTAssertEqual(
            Set(model.workspaceCommands(matching: "family").map(\.command)),
            [
                .showTag(family.id),
                .acceptTag(family.id),
                .rejectTag(family.id),
                .clearTagDecision(family.id),
            ]
        )
    }

    func testCommandPaletteDisablesSelectionActionsUntilOnePhotoIsSelected() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            tags: [tag],
            startsConnected: true
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await waitForCatalogScanToFinish(model)

        let initialCommands = model.workspaceCommands(matching: "")
        XCTAssertFalse(initialCommands.first(where: { $0.command == .acceptTag(tag.id) })?.isEnabled ?? true)
        XCTAssertFalse(initialCommands.first(where: { $0.command == .createTag })?.isEnabled ?? true)
        XCTAssertFalse(initialCommands.first(where: { $0.command == .toggleSinglePhoto })?.isEnabled ?? true)
        XCTAssertTrue(initialCommands.first(where: { $0.command == .rescanCurrentSource })?.isEnabled ?? false)

        await model.selectAsset(asset.assetID)

        let selectedCommands = model.workspaceCommands(matching: "")
        XCTAssertTrue(selectedCommands.first(where: { $0.command == .acceptTag(tag.id) })?.isEnabled ?? false)
        XCTAssertTrue(selectedCommands.first(where: { $0.command == .createTag })?.isEnabled ?? false)
        XCTAssertTrue(selectedCommands.first(where: { $0.command == .toggleSinglePhoto })?.isEnabled ?? false)
    }

    func testChangingGridDensityPreservesLoadedCatalogSelectionAndSinglePhotoState() async {
        let sourceID = UUID()
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "second.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [first, second]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(second.assetID)
        model.toggleSinglePhotoView()

        XCTAssertEqual(model.gridDensity, .standard)

        model.setGridDensity(.compact)

        XCTAssertEqual(model.gridDensity, .compact)
        XCTAssertEqual(model.items.map(\.assetID), [first.assetID, second.assetID])
        XCTAssertEqual(model.selectedAssetIDs, [second.assetID])
        XCTAssertTrue(model.isSinglePhotoPresented)

        model.setGridDensity(.large)

        XCTAssertEqual(model.gridDensity, .large)
        XCTAssertEqual(model.items.map(\.assetID), [first.assetID, second.assetID])
        XCTAssertEqual(model.selectedAssetIDs, [second.assetID])
        XCTAssertTrue(model.isSinglePhotoPresented)
    }

    func testAvailabilityFormatAndSortControlsReloadCatalogAndClearHiddenSelection() async {
        let sourceID = UUID()
        let availableJPEG = Self.makeAsset(
            sourceID: sourceID,
            fileName: "available.jpg",
            mediaType: "public.jpeg",
            availability: .available
        )
        let missingPNG = Self.makeAsset(
            sourceID: sourceID,
            fileName: "missing.png",
            mediaType: "public.png",
            availability: .missing
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [availableJPEG, missingPNG]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(availableJPEG.assetID)

        await model.toggleAvailabilityFilter(.missing)
        await model.toggleMediaTypeFilterGroup(["public.png"])
        await model.setSort(.oldest)

        XCTAssertEqual(model.selectedAvailabilities, [.missing])
        XCTAssertEqual(model.selectedMediaTypes, ["public.png"])
        XCTAssertEqual(model.sort, .oldest)
        XCTAssertEqual(service.lastFilter.availabilities, [.missing])
        XCTAssertEqual(service.lastFilter.mediaTypes, ["public.png"])
        XCTAssertEqual(service.lastSort, .oldest)
        XCTAssertEqual(model.items.map(\.assetID), [missingPNG.assetID])
        XCTAssertTrue(model.selectedAssetIDs.isEmpty)
        XCTAssertEqual(model.notice, .selectionHiddenByFilter)
    }

    func testClearingAssetPropertyFiltersRestoresAllFormatsAndStates() async {
        let sourceID = UUID()
        let availableJPEG = Self.makeAsset(sourceID: sourceID, fileName: "available.jpg")
        let missingPNG = Self.makeAsset(
            sourceID: sourceID,
            fileName: "missing.png",
            mediaType: "public.png",
            availability: .missing
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [availableJPEG, missingPNG]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.toggleAvailabilityFilter(.missing)
        await model.toggleMediaTypeFilterGroup(["public.png"])
        XCTAssertEqual(model.items.map(\.assetID), [missingPNG.assetID])

        await model.clearAssetPropertyFilters()

        XCTAssertTrue(model.selectedAvailabilities.isEmpty)
        XCTAssertTrue(model.selectedMediaTypes.isEmpty)
        XCTAssertEqual(model.items.map(\.assetID), [availableJPEG.assetID, missingPNG.assetID])
    }

    func testBulkReviewAcceptanceUsesSingleMutationAndUndoRestoresAll() async {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let assets = (0 ..< 3).map { _ in Self.makeAsset(sourceID: sourceID) }
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: assets,
            tags: [tag]
        )
        let review = FakePersonalizationReviewPort(
            queueItems: assets.map {
                ReviewQueueItemProjection(
                    assetID: $0.assetID,
                    fileName: $0.fileName,
                    availability: $0.availability,
                    acceptedTagCount: 0,
                    rejectedTagCount: 0
                )
            }
        )
        let model = LibraryWorkspaceModel(service: service, review: review)

        await model.enterReviewQueue(tagID: tag.id, displayName: tag.displayName)
        await model.selectAsset(assets[0].assetID)
        await model.selectAsset(assets[1].assetID, additive: true)
        await model.selectAsset(assets[2].assetID, additive: true)
        await model.applyReviewDecision(action: .accept)

        XCTAssertEqual(service.mutateTagCallCount, 1)
        XCTAssertTrue(model.canUndoReviewMutation)
        await model.undoLastReviewMutation()
        XCTAssertEqual(
            try service.selectionAggregate(tagIDs: [tag.id], assetIDs: assets.map(\.assetID)).first?.unknownCount,
            3
        )
    }

    func testDeferReviewSelectionAdvancesSelectionWithoutReorderingQueue() async {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "second.jpg")
        let third = Self.makeAsset(sourceID: sourceID, fileName: "third.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [first, second, third],
            tags: [tag]
        )
        let queueItems = [first, second, third].map {
            ReviewQueueItemProjection(
                assetID: $0.assetID,
                fileName: $0.fileName,
                availability: $0.availability,
                acceptedTagCount: 0,
                rejectedTagCount: 0
            )
        }
        let review = FakePersonalizationReviewPort(queueItems: queueItems)
        let model = LibraryWorkspaceModel(service: service, review: review)

        await model.enterReviewQueue(tagID: tag.id, displayName: tag.displayName)
        let originalOrder = model.reviewQueueItems.map(\.assetID)
        await model.selectAsset(first.assetID)
        model.deferReviewSelection()

        XCTAssertEqual(service.mutateTagCallCount, 0)
        XCTAssertEqual(model.reviewQueueItems.map(\.assetID), originalOrder)
        XCTAssertEqual(model.selectedAssetIDs, [second.assetID])
    }

    func testReviewDecisionFromMiddleOfQueueSelectsNextOriginalItem() async {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let assets = (0 ..< 5).map { Self.makeAsset(sourceID: sourceID, fileName: "item-\($0).jpg") }
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: assets,
            tags: [tag]
        )
        let review = FakePersonalizationReviewPort(
            queueItems: assets.map {
                ReviewQueueItemProjection(
                    assetID: $0.assetID,
                    fileName: $0.fileName,
                    availability: $0.availability,
                    acceptedTagCount: 0,
                    rejectedTagCount: 0
                )
            }
        )
        review.decidedAssetIDsProvider = { [weak service] tagID in
            service?.decidedAssetIDs(tagID: tagID) ?? []
        }
        let model = LibraryWorkspaceModel(service: service, review: review)

        await model.enterReviewQueue(tagID: tag.id, displayName: tag.displayName)
        let originalOrder = model.reviewQueueItems.map(\.assetID)
        await model.selectAsset(assets[2].assetID)
        await model.applyReviewDecision(action: .reject)

        XCTAssertEqual(model.reviewQueueItems.map(\.assetID), originalOrder.filter { $0 != assets[2].assetID })
        XCTAssertEqual(model.selectedAssetIDs, [assets[3].assetID])
    }

    func testInspectorClearsSuggestionsWhenMultiSelect() async {
        let sourceID = UUID()
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "second.jpg")
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [first, second],
            tags: [tag]
        )
        let review = FakePersonalizationReviewPort(
            pendingByAsset: [
                first.assetID: [AssetPendingSuggestion(tagID: tag.id, displayName: tag.displayName)],
            ]
        )
        let model = LibraryWorkspaceModel(service: service, review: review)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(first.assetID)
        XCTAssertEqual(model.assetPendingSuggestions.map(\.tagID), [tag.id])

        await model.selectAsset(second.assetID, additive: true)
        XCTAssertTrue(model.assetPendingSuggestions.isEmpty)
    }

    func testApplyReviewDecisionIgnoredOutsideReviewQueue() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset]
        )
        let model = LibraryWorkspaceModel(service: service, review: FakePersonalizationReviewPort())

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(asset.assetID)
        await model.applyReviewDecision(action: .accept)

        XCTAssertEqual(service.mutateTagCallCount, 0)
    }

    func testConfirmSuggestionEnqueueReturnsWithoutDrainingJobs() async {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [Self.makeAsset(sourceID: sourceID)],
            tags: [tag]
        )
        let review = FakePersonalizationReviewPort(
            overviews: [
                SuggestionTagOverview(
                    id: tag.id,
                    displayName: tag.displayName,
                    acceptedSampleCount: 4,
                    rejectedSampleCount: 4,
                    pendingSuggestionCount: 0,
                    taskStatus: .ready,
                    checkedCount: 0,
                    totalCount: nil,
                    skippedCount: 0,
                    missingPositiveCount: 0,
                    missingNegativeCount: 0,
                    canGenerate: true,
                    canUpdate: false,
                    canReview: false,
                    canPause: false,
                    canResume: false,
                    canCancel: false,
                    activeJobID: nil
                ),
            ],
            blocksRunPendingJobs: true
        )
        let model = LibraryWorkspaceModel(service: service, review: review)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.refreshReviewState()
        _ = await model.enqueueSuggestions(tagID: tag.id, mode: .generate)
        let start = ContinuousClock.now
        let confirmed = await model.confirmPendingSuggestionEnqueue()
        let elapsed = start.duration(to: .now)
        XCTAssertTrue(confirmed)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(review.enqueueCallCount, 1)
    }

    func testConfirmSuggestionEnqueueUsesCapturedConfirmationAfterDialogDismissal() async throws {
        let review = FakePersonalizationReviewPort()
        let sourceID = UUID()
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: sourceID,
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: []
            ),
            review: review
        )
        let tagID = UUID()

        model.requestEnqueueSuggestions(
            tagID: tagID,
            displayName: "Family",
            mode: .generate,
            sourceCount: 1
        )
        let captured = try XCTUnwrap(model.pendingSuggestionConfirmation)
        model.cancelPendingSuggestionEnqueue()

        let confirmed = await model.confirmPendingSuggestionEnqueue(captured)

        XCTAssertTrue(confirmed)
        XCTAssertEqual(review.enqueueCallCount, 1)
    }

    private func waitForCatalogScanToFinish(_ model: LibraryWorkspaceModel) async {
        for _ in 0 ..< 10_000 {
            if !model.isCatalogScanning { return }
            await Task.yield()
        }
        XCTFail("catalog scan did not finish")
    }

    private func waitForCatalogProgress(
        _ progress: CatalogReconcileProgress,
        model: LibraryWorkspaceModel
    ) async {
        for _ in 0 ..< 10_000 {
            if model.catalogReconcileProgress == progress { return }
            await Task.yield()
        }
        XCTFail("catalog progress did not publish")
    }

    private func waitForItems(_ assetIDs: [UUID], model: LibraryWorkspaceModel) async {
        for _ in 0 ..< 10_000 {
            if model.items.map(\.assetID) == assetIDs { return }
            await Task.yield()
        }
        XCTFail("catalog items did not publish")
    }

    private func waitForCloudPreviewState(
        _ expected: CloudPreviewPresentationState,
        model: LibraryWorkspaceModel
    ) async {
        for _ in 0 ..< 10_000 {
            if model.cloudPreviewState == expected { return }
            await Task.yield()
        }
        XCTFail("cloud preview state did not become \(expected)")
    }

    private func waitForAssetPageFetchToBlock(_ service: FakeLibraryWorkspaceService) async {
        for _ in 0 ..< 10_000 {
            if service.hasStartedBlockedAssetPageFetch { return }
            await Task.yield()
        }
        XCTFail("asset page fetch did not block")
    }

    private static func makeAsset(
        sourceID: UUID,
        fileName: String = "sample.jpg",
        mediaType: String = "public.jpeg",
        availability: AssetAvailability = .available
    ) -> AssetGridItemProjection {
        AssetGridItemProjection(
            assetID: UUID(),
            sourceID: sourceID,
            sourceDisplayName: "Fixture",
            sourceState: .active,
            relativePath: fileName,
            fileName: fileName,
            mediaType: mediaType,
            mediaCreatedAtMs: 1,
            mediaModifiedAtMs: 1,
            width: 32,
            height: 32,
            availability: availability,
            contentRevision: 1,
            acceptedTagCount: 0,
            rejectedTagCount: 0
        )
    }
}

private final class FakeLibraryWorkspaceService: LibraryWorkspacePort, @unchecked Sendable {
    private let lock = NSLock()
    private let connectedSource: LibrarySourceSummary
    private let reconciledItems: [AssetGridItemProjection]
    private var storedSources: [LibrarySourceSummary] = []
    private var storedItems: [AssetGridItemProjection] = []
    private var storedReconcileRunCount = 0
    private var storedPhotosConnectCallCount = 0
    private var storedPhotosRebindCallCount = 0
    private var storedPhotosReconcileRunCount = 0
    private var storedReauthorizeCallCount = 0
    private var storedDisableCallCount = 0
    private var storedMutateTagCallCount = 0
    private var storedLastFilter = AssetPageFilter()
    private var storedLastSort: AssetPageSort = .newest
    private let scanFails: Bool
    private let tagMutationFails: Bool
    private let sourceMutationFails: Bool
    private let blocksReconcileRuns: Bool
    private let photosAuthorizationFails: Bool
    private let reboundSource: LibrarySourceSummary?
    private let catalogReconcileProgress: CatalogReconcileProgress?
    private let previewError: PhotosLibraryError?
    private let cloudPreviewData: Data
    private let cloudPreviewProgress: [Double]
    private let cloudPreviewFailureCount: Int
    private let reconcileGate = DispatchSemaphore(value: 0)
    private var storedHasStartedBlockedReconcile = false
    private var storedCloudPreviewDownloadCallCount = 0
    private var storedCloudPreviewCancellationCount = 0
    private var storedThumbnailLoadCallCount = 0
    private var storedPortableExportCallCount = 0
    private var storedPreviewCacheClearCallCount = 0
    private var storedAssetPageFetchCallCount = 0
    private var storedJobActivityItems: [JobActivityItem]
    private var storedJobActivityFetchCallCount = 0
    private var storedJobActivityActionCallCount = 0
    private var folderMonitoringCallback: (@Sendable () -> Void)?
    private var storedTags: [TagListItem]
    private var decisions: [UUID: [UUID: TagDecisionQueryState]] = [:]
    private let exportParentURL: URL?
    private let portableExportResult: PortableCatalogExportResult?
    private let portableExportFails: Bool
    private let portableExportError: Error?
    private var storedPreviewCacheUsage: DerivedImageCacheUsage
    private let previewCacheClearResult: DerivedImageCacheClearResult?
    private let previewCacheClearFails: Bool
    private let jobActivityActionFails: Bool
    private let jobActivityItemsAfterFailedAction: [JobActivityItem]?
    private let blockedSearchText: String?
    private let assetPageSize: Int?
    private let assetPageFetchGate = DispatchSemaphore(value: 0)
    private var storedHasStartedBlockedAssetPageFetch = false

    init(
        connectedSource: LibrarySourceSummary,
        reconciledItems: [AssetGridItemProjection],
        scanFails: Bool = false,
        tags: [TagListItem] = [],
        tagMutationFails: Bool = false,
        sourceMutationFails: Bool = false,
        initialItems: [AssetGridItemProjection] = [],
        startsConnected: Bool = false,
        blocksReconcileRuns: Bool = false,
        photosAuthorizationFails: Bool = false,
        reboundSource: LibrarySourceSummary? = nil,
        catalogReconcileProgress: CatalogReconcileProgress? = nil,
        previewError: PhotosLibraryError? = nil,
        cloudPreviewData: Data = Data(),
        cloudPreviewProgress: [Double] = [],
        cloudPreviewFailureCount: Int = 0,
        exportParentURL: URL? = nil,
        portableExportResult: PortableCatalogExportResult? = nil,
        portableExportFails: Bool = false,
        portableExportError: Error? = nil,
        previewCacheUsage: DerivedImageCacheUsage = .zero,
        previewCacheClearResult: DerivedImageCacheClearResult? = nil,
        previewCacheClearFails: Bool = false,
        jobActivityItems: [JobActivityItem] = [],
        jobActivityActionFails: Bool = false,
        jobActivityItemsAfterFailedAction: [JobActivityItem]? = nil,
        blockedSearchText: String? = nil,
        assetPageSize: Int? = nil
    ) {
        self.connectedSource = connectedSource
        self.reconciledItems = reconciledItems
        self.scanFails = scanFails
        self.tagMutationFails = tagMutationFails
        self.sourceMutationFails = sourceMutationFails
        self.blocksReconcileRuns = blocksReconcileRuns
        self.photosAuthorizationFails = photosAuthorizationFails
        self.reboundSource = reboundSource
        self.catalogReconcileProgress = catalogReconcileProgress
        self.previewError = previewError
        self.cloudPreviewData = cloudPreviewData
        self.cloudPreviewProgress = cloudPreviewProgress
        self.cloudPreviewFailureCount = cloudPreviewFailureCount
        self.exportParentURL = exportParentURL
        self.portableExportResult = portableExportResult
        self.portableExportFails = portableExportFails
        self.portableExportError = portableExportError
        storedPreviewCacheUsage = previewCacheUsage
        self.previewCacheClearResult = previewCacheClearResult
        self.previewCacheClearFails = previewCacheClearFails
        storedJobActivityItems = jobActivityItems
        self.jobActivityActionFails = jobActivityActionFails
        self.jobActivityItemsAfterFailedAction = jobActivityItemsAfterFailedAction
        self.blockedSearchText = blockedSearchText
        self.assetPageSize = assetPageSize
        storedSources = startsConnected ? [connectedSource] : []
        storedItems = initialItems
        storedTags = tags
    }

    var hasStartedBlockedReconcile: Bool {
        lock.withLock { storedHasStartedBlockedReconcile }
    }

    func releaseBlockedReconcile() {
        reconcileGate.signal()
    }

    var reconcileRunCount: Int {
        lock.withLock { storedReconcileRunCount }
    }

    var photosConnectCallCount: Int {
        lock.withLock { storedPhotosConnectCallCount }
    }

    var photosRebindCallCount: Int {
        lock.withLock { storedPhotosRebindCallCount }
    }

    var photosReconcileRunCount: Int {
        lock.withLock { storedPhotosReconcileRunCount }
    }

    var lastFilter: AssetPageFilter {
        lock.withLock { storedLastFilter }
    }

    var reauthorizeCallCount: Int {
        lock.withLock { storedReauthorizeCallCount }
    }

    var disableCallCount: Int {
        lock.withLock { storedDisableCallCount }
    }

    var mutateTagCallCount: Int {
        lock.withLock { storedMutateTagCallCount }
    }

    var lastSort: AssetPageSort {
        lock.withLock { storedLastSort }
    }

    var cloudPreviewDownloadCallCount: Int {
        lock.withLock { storedCloudPreviewDownloadCallCount }
    }

    var cloudPreviewCancellationCount: Int {
        lock.withLock { storedCloudPreviewCancellationCount }
    }

    var thumbnailLoadCallCount: Int {
        lock.withLock { storedThumbnailLoadCallCount }
    }

    var portableExportCallCount: Int {
        lock.withLock { storedPortableExportCallCount }
    }

    var previewCacheClearCallCount: Int {
        lock.withLock { storedPreviewCacheClearCallCount }
    }

    var assetPageFetchCallCount: Int {
        lock.withLock { storedAssetPageFetchCallCount }
    }

    var hasStartedBlockedAssetPageFetch: Bool {
        lock.withLock { storedHasStartedBlockedAssetPageFetch }
    }

    func releaseBlockedAssetPageFetch() {
        assetPageFetchGate.signal()
    }

    var jobActivityFetchCallCount: Int {
        lock.withLock { storedJobActivityFetchCallCount }
    }

    var jobActivityActionCallCount: Int {
        lock.withLock { storedJobActivityActionCallCount }
    }

    func startCatalogSourceMonitoring(onChange: @escaping @Sendable () -> Void) throws {
        lock.withLock { folderMonitoringCallback = onChange }
    }

    func stopCatalogSourceMonitoring() {
        lock.withLock { folderMonitoringCallback = nil }
    }

    func triggerFolderMonitoringChange() {
        lock.withLock { folderMonitoringCallback }?()
    }

    func fetchPreviewCacheUsage() throws -> DerivedImageCacheUsage {
        lock.withLock { storedPreviewCacheUsage }
    }

    func clearPreviewCache() async throws -> DerivedImageCacheClearResult {
        if previewCacheClearFails {
            throw FakeWorkspaceError.previewCacheClearFailed
        }
        return try lock.withLock {
            storedPreviewCacheClearCallCount += 1
            guard let previewCacheClearResult else {
                throw FakeWorkspaceError.previewCacheClearFailed
            }
            storedPreviewCacheUsage = .zero
            return previewCacheClearResult
        }
    }

    func fetchJobActivity() throws -> [JobActivityItem] {
        lock.withLock {
            storedJobActivityFetchCallCount += 1
            return storedJobActivityItems
        }
    }

    func applyJobActivityAction(_ action: JobActivityAction, jobID: UUID) throws {
        try lock.withLock {
            storedJobActivityActionCallCount += 1
            if jobActivityActionFails {
                if let jobActivityItemsAfterFailedAction {
                    storedJobActivityItems = jobActivityItemsAfterFailedAction
                }
                throw FakeWorkspaceError.jobActivityActionFailed
            }
            guard let index = storedJobActivityItems.firstIndex(where: { $0.id == jobID }) else {
                throw FakeWorkspaceError.notFound
            }
            let item = storedJobActivityItems[index]
            guard item.availableActions.contains(action) else {
                throw FakeWorkspaceError.jobActivityActionFailed
            }
            let nextState: JobState
            let nextControl: JobControlRequest
            switch (item.state, action) {
            case (.pending, .pause):
                (nextState, nextControl) = (.paused, .none)
            case (.pending, .cancel), (.paused, .cancel), (.retryableFailed, .cancel):
                (nextState, nextControl) = (.cancelled, .none)
            case (.running, .pause):
                (nextState, nextControl) = (.running, .pause)
            case (.running, .cancel):
                (nextState, nextControl) = (.running, .cancel)
            case (.paused, .resume):
                (nextState, nextControl) = (.pending, .none)
            default:
                throw FakeWorkspaceError.jobActivityActionFailed
            }
            storedJobActivityItems[index] = JobActivityItem(
                id: item.id,
                kind: item.kind,
                state: nextState,
                controlRequest: nextControl,
                progress: item.progress
            )
        }
    }

    @MainActor
    func choosePortableExportDirectory() -> URL? {
        exportParentURL
    }

    func exportPortableUserData(to parentDirectoryURL: URL) throws -> PortableCatalogExportResult {
        if let portableExportError {
            throw portableExportError
        }
        if portableExportFails {
            throw FakeWorkspaceError.portableExportFailed
        }
        return try lock.withLock {
            storedPortableExportCallCount += 1
            guard let portableExportResult else {
                throw FakeWorkspaceError.portableExportFailed
            }
            return portableExportResult
        }
    }

    func fetchSources() throws -> [LibrarySourceSummary] {
        lock.withLock { storedSources }
    }

    func connectFolder() async throws -> ConnectFolderOutcome {
        lock.withLock { storedSources = [connectedSource] }
        return .connected(sourceID: connectedSource.id)
    }

    func connectPhotos() async throws -> ConnectPhotosOutcome {
        lock.withLock {
            storedPhotosConnectCallCount += 1
            storedSources = [connectedSource]
        }
        return .connected(sourceID: connectedSource.id)
    }

    func rebindPhotos(unavailableSourceID: UUID) async throws -> RebindPhotosOutcome {
        try lock.withLock {
            guard let reboundSource,
                  storedSources.contains(where: {
                      $0.id == unavailableSourceID && $0.kind == .photos && $0.state == .unavailable
                  })
            else {
                throw FakeWorkspaceError.sourceActionFailed
            }
            storedPhotosRebindCallCount += 1
            storedSources.append(reboundSource)
            return .rebound(previousSourceID: unavailableSourceID, sourceID: reboundSource.id)
        }
    }

    func reauthorizeFolder(sourceID: UUID) async throws -> ReauthorizeFolderOutcome {
        if sourceMutationFails {
            throw FakeWorkspaceError.sourceActionFailed
        }
        lock.withLock {
            storedReauthorizeCallCount += 1
            storedSources = storedSources.map {
                guard $0.id == sourceID else { return $0 }
                return LibrarySourceSummary(id: $0.id, displayName: $0.displayName, state: .active)
            }
        }
        return .reauthorized(sourceID: sourceID)
    }

    func disableFolderSource(sourceID: UUID) async throws -> DisableFolderOutcome {
        if sourceMutationFails {
            throw FakeWorkspaceError.sourceActionFailed
        }
        lock.withLock {
            storedDisableCallCount += 1
            storedSources = storedSources.map {
                guard $0.id == sourceID else { return $0 }
                return LibrarySourceSummary(id: $0.id, displayName: $0.displayName, state: .disabled)
            }
        }
        return .disabled(sourceID: sourceID)
    }

    func enqueueReconcile(sourceIDs: [UUID]) throws {}

    func fetchCatalogReconcileProgress() throws -> CatalogReconcileProgress? {
        catalogReconcileProgress
    }

    func publishReconciledItems() {
        lock.withLock { storedItems = reconciledItems }
    }

    func runPendingReconcileJobs() throws {
        if scanFails {
            throw FakeWorkspaceError.scanFailed
        }
        if blocksReconcileRuns {
            lock.withLock { storedHasStartedBlockedReconcile = true }
            reconcileGate.wait()
        }
        lock.withLock {
            storedReconcileRunCount += 1
            storedItems = reconciledItems
        }
    }

    func runPendingPhotosReconcileJobs() throws {
        if photosAuthorizationFails {
            lock.withLock {
                storedSources = storedSources.map {
                    guard $0.kind == .photos else { return $0 }
                    return LibrarySourceSummary(
                        id: $0.id,
                        kind: .photos,
                        displayName: $0.displayName,
                        state: .authorizationRequired
                    )
                }
            }
            throw PhotosLibraryError.authorizationDenied
        }
        if scanFails {
            throw FakeWorkspaceError.scanFailed
        }
        lock.withLock {
            storedPhotosReconcileRunCount += 1
            storedItems = reconciledItems
        }
    }

    func runPendingPersonalizationJobs() throws {}

    func fetchAssetPage(
        filter: AssetPageFilter,
        sort: AssetPageSort,
        cursor: AssetPageCursor?
    ) throws -> AssetPageResult {
        if filter.searchText == blockedSearchText {
            lock.withLock { storedHasStartedBlockedAssetPageFetch = true }
            assetPageFetchGate.wait()
        }
        return lock.withLock {
            storedAssetPageFetchCallCount += 1
            storedLastFilter = filter
            storedLastSort = sort
            let search = filter.searchText?.lowercased()
            let filtered = storedItems.filter { item in
                if !filter.availabilities.isEmpty,
                   !filter.availabilities.contains(item.availability)
                {
                    return false
                }
                if !filter.mediaTypes.isEmpty,
                   !filter.mediaTypes.contains(item.mediaType)
                {
                    return false
                }
                guard let search, !search.isEmpty else { return true }
                return item.fileName?.lowercased().contains(search) == true
            }
            let cursorAssetID: UUID? = cursor.map {
                switch $0.payload {
                case let .timeSort(_, _, assetID), let .fileNameSort(_, _, assetID):
                    assetID
                }
            }
            let startIndex = cursorAssetID
                .flatMap { id in filtered.firstIndex(where: { $0.assetID == id }) }
                .map { $0 + 1 } ?? 0
            let pageItems = Array(
                filtered.dropFirst(startIndex).prefix(assetPageSize ?? filtered.count)
            )
            let hasNextPage = startIndex + pageItems.count < filtered.count
            let nextCursor = hasNextPage ? pageItems.last.map {
                AssetPageCursor(
                    sort: sort,
                    payload: .timeSort(
                        timeEmptyMarker: 0,
                        coalescedTimeMs: $0.mediaModifiedAtMs,
                        assetID: $0.assetID
                    )
                )
            } : nil
            return AssetPageResult(items: pageItems, nextCursor: nextCursor)
        }
    }

    func loadThumbnail(assetID: UUID) async throws -> Data {
        lock.withLock { storedThumbnailLoadCallCount += 1 }
        return Data()
    }

    func loadPreview(assetID: UUID) async throws -> Data {
        if let previewError {
            throw previewError
        }
        return Data()
    }

    func downloadCloudPreview(
        assetID: UUID,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        let callCount = lock.withLock {
            storedCloudPreviewDownloadCallCount += 1
            return storedCloudPreviewDownloadCallCount
        }
        do {
            for progress in cloudPreviewProgress {
                try Task.checkCancellation()
                onProgress(progress)
                for _ in 0 ..< 100 {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }
            if callCount <= cloudPreviewFailureCount {
                throw FakeWorkspaceError.cloudPreviewFailed
            }
            return cloudPreviewData
        } catch is CancellationError {
            lock.withLock { storedCloudPreviewCancellationCount += 1 }
            throw CancellationError()
        }
    }

    func listTags() throws -> [TagListItem] {
        lock.withLock { storedTags }
    }

    func installPresetTags() throws -> TagPresetInstallResult {
        lock.withLock {
            let existingNames = Set(storedTags.map(\.displayName))
            let created: [TagListItem] = TagPresetCatalog.starterDisplayNames.compactMap { displayName in
                guard !existingNames.contains(displayName) else { return nil }
                return TagListItem(id: UUID(), displayName: displayName, state: .active)
            }
            storedTags.append(contentsOf: created)
            return TagPresetInstallResult(createdTags: created)
        }
    }

    func fetchInspectorDetail(assetID: UUID) throws -> AssetInspectorDetail {
        try lock.withLock {
            guard let item = storedItems.first(where: { $0.assetID == assetID }) else {
                throw FakeWorkspaceError.notFound
            }
            return AssetInspectorDetail(
                assetID: item.assetID,
                sourceID: item.sourceID,
                sourceDisplayName: item.sourceDisplayName,
                sourceState: item.sourceState,
                relativePath: item.relativePath,
                fileName: item.fileName,
                mediaType: item.mediaType,
                mediaCreatedAtMs: item.mediaCreatedAtMs,
                mediaModifiedAtMs: item.mediaModifiedAtMs,
                width: item.width,
                height: item.height,
                availability: item.availability,
                contentRevision: item.contentRevision,
                acceptedTagCount: item.acceptedTagCount,
                rejectedTagCount: item.rejectedTagCount,
                fingerprintSizeBytes: nil,
                fingerprintModifiedAtNs: nil,
                tags: storedTags.map {
                    InspectorTagState(
                        tagID: $0.id,
                        displayName: $0.displayName,
                        tagState: $0.state,
                        decision: decisions[assetID]?[$0.id] ?? .unknown
                    )
                }
            )
        }
    }

    func selectionAggregate(tagIDs: [UUID], assetIDs: [UUID]) throws -> [TagSelectionAggregate] {
        lock.withLock {
            tagIDs.map { tagID in
                let states = assetIDs.map { decisions[$0]?[tagID] ?? .unknown }
                return TagSelectionAggregate(
                    tagID: tagID,
                    acceptedCount: states.filter { $0 == .accepted }.count,
                    rejectedCount: states.filter { $0 == .rejected }.count,
                    unknownCount: states.filter { $0 == .unknown }.count
                )
            }
        }
    }

    func mutateTag(
        tagID: UUID,
        assetIDs: [UUID],
        action: LibraryTagDecisionAction
    ) throws -> TagMutationPriorStateSnapshot {
        if tagMutationFails {
            throw FakeWorkspaceError.tagMutationFailed
        }
        return lock.withLock {
            storedMutateTagCallCount += 1
            let priorStates = assetIDs.map {
                TagMutationPriorState(assetID: $0, priorState: decisions[$0]?[tagID] ?? .unknown)
            }
            for assetID in assetIDs {
                decisions[assetID, default: [:]][tagID] = action.decision
            }
            return TagMutationPriorStateSnapshot(tagID: tagID, priorStates: priorStates)
        }
    }

    func restoreTagMutation(_ snapshot: TagMutationPriorStateSnapshot) throws {
        lock.withLock {
            for prior in snapshot.priorStates {
                decisions[prior.assetID, default: [:]][snapshot.tagID] = prior.priorState
            }
        }
    }


    func createTagAndAccept(
        rawName: String,
        assetIDs: [UUID]
    ) throws -> TagCreateAndApplyResult {
        lock.withLock {
            let tag = TagListItem(id: UUID(), displayName: rawName, state: .active)
            storedTags.append(tag)
            for assetID in assetIDs {
                decisions[assetID, default: [:]][tag.id] = .accepted
            }
            return TagCreateAndApplyResult(
                tagID: tag.id,
                displayName: rawName,
                normalizedName: rawName.lowercased(),
                priorStates: assetIDs.map { TagMutationPriorState(assetID: $0, priorState: .unknown) }
            )
        }
    }

    func renameTag(tagID: UUID, rawName: String) throws -> TagListItem {
        if tagMutationFails {
            throw FakeWorkspaceError.tagMutationFailed
        }
        return try lock.withLock {
            guard let index = storedTags.firstIndex(where: { $0.id == tagID }) else {
                throw FakeWorkspaceError.notFound
            }
            let renamed = TagListItem(id: tagID, displayName: rawName, state: .active)
            storedTags[index] = renamed
            return renamed
        }
    }

    func archiveTag(tagID: UUID) throws {
        if tagMutationFails {
            throw FakeWorkspaceError.tagMutationFailed
        }
        lock.withLock {
            storedTags.removeAll { $0.id == tagID }
        }
    }

    func decidedAssetIDs(tagID: UUID) -> Set<UUID> {
        lock.withLock {
            Set(
                decisions.compactMap { assetID, tagStates in
                    guard let state = tagStates[tagID], state != .unknown else { return nil }
                    return assetID
                }
            )
        }
    }
}

private enum FakeWorkspaceError: Error {
    case scanFailed
    case notFound
    case tagMutationFailed
    case sourceActionFailed
    case cloudPreviewFailed
    case portableExportFailed
    case previewCacheClearFailed
    case jobActivityActionFailed
}

private final class FakePersonalizationReviewPort: PersonalizationReviewPort, @unchecked Sendable {
    private let lock = NSLock()
    private var storedOverviews: [SuggestionTagOverview]
    private var storedQueueItems: [ReviewQueueItemProjection]
    private var storedPendingByAsset: [UUID: [AssetPendingSuggestion]]
    var decidedAssetIDsProvider: (@Sendable (UUID) -> Set<UUID>)?
    let blocksRunPendingJobs: Bool
    private(set) var enqueueCallCount = 0
    private(set) var runPendingJobsCallCount = 0

    init(
        overviews: [SuggestionTagOverview] = [],
        queueItems: [ReviewQueueItemProjection] = [],
        pendingByAsset: [UUID: [AssetPendingSuggestion]] = [:],
        blocksRunPendingJobs: Bool = false
    ) {
        storedOverviews = overviews
        storedQueueItems = queueItems
        storedPendingByAsset = pendingByAsset
        self.blocksRunPendingJobs = blocksRunPendingJobs
    }

    func totalPendingSuggestionCount() throws -> Int {
        lock.withLock { storedQueueItems.count }
    }

    func tagOverviews() throws -> [SuggestionTagOverview] {
        lock.withLock { storedOverviews }
    }

    func fetchReviewQueue(tagID: UUID, cursor: ReviewQueueCursor?, limit: Int) throws -> ReviewQueuePage {
        lock.withLock {
            let excluded = decidedAssetIDsProvider?(tagID) ?? []
            let visible = storedQueueItems.filter { !excluded.contains($0.assetID) }
            return ReviewQueuePage(items: Array(visible.prefix(limit)), nextCursor: nil)
        }
    }

    func pendingSuggestionsForAsset(assetID: UUID) throws -> [AssetPendingSuggestion] {
        lock.withLock { storedPendingByAsset[assetID] ?? [] }
    }

    func enqueueFullLibrarySuggestions(tagID: UUID, mode: PersonalizationReviewEnqueueMode) throws -> UUID {
        lock.withLock { enqueueCallCount += 1 }
        return UUID()
    }

    func pauseSuggestionJob(jobID: UUID) throws {}
    func resumeSuggestionJob(jobID: UUID) throws {}
    func cancelSuggestionJob(jobID: UUID) throws {}

    func runPendingSuggestionJobs(maxSteps: Int?) throws -> Bool {
        lock.withLock { runPendingJobsCallCount += 1 }
        if blocksRunPendingJobs {
            Thread.sleep(forTimeInterval: 5)
        }
        return false
    }
}
