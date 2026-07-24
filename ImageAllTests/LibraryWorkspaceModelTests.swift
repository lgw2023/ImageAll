import Foundation
import SwiftUI
import XCTest
@testable import ImageAll

@MainActor
final class LibraryWorkspaceModelTests: XCTestCase {
    func testRefreshingLocalModelServiceHealthPublishesReadyProvider() async {
        let provider = PersonalTrainingEncoderIdentity(
            provider: "dinov2",
            modelID: "facebook/dinov2-small",
            modelRevision: "model-v1",
            preprocessingRevision: "preprocessing-v1",
            elementCount: 384
        )
        let client = FakeLocalModelSuggestionClient(
            result: .success([]),
            serviceHealthResult: .success(
                .ready(serviceVersion: "0.1.0", provider: provider)
            )
        )
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: UUID(),
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: []
            ),
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )

        XCTAssertEqual(model.localModelServiceHealthState, .unchecked)
        XCTAssertEqual(client.serviceHealthCallCount, 0)

        await model.refreshLocalModelServiceHealth()

        XCTAssertEqual(
            model.localModelServiceHealthState,
            .ready(serviceVersion: "0.1.0", provider: provider)
        )
        XCTAssertEqual(client.serviceHealthCallCount, 1)
    }

    func testRefreshingUnavailableLocalModelServicePublishesSafeState() async {
        let client = FakeLocalModelSuggestionClient(result: .success([]))
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: UUID(),
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: []
            ),
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )

        await model.refreshLocalModelServiceHealth()

        XCTAssertEqual(model.localModelServiceHealthState, .unavailable)
        XCTAssertEqual(client.serviceHealthCallCount, 1)
    }

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

    func testExternalAppStorageSelectionPublishesRestartRequirement() async {
        let internalSupport = URL(
            fileURLWithPath: "/Library/Application Support/ImageAll",
            isDirectory: true
        )
        let internalCaches = URL(
            fileURLWithPath: "/Library/Caches/ImageAll",
            isDirectory: true
        )
        let externalRoot = URL(
            fileURLWithPath: "/Volumes/SSD1",
            isDirectory: true
        )
        let pendingStatus = AppStorageLocationStatus(
            applicationSupportDirectoryURL: internalSupport,
            cachesDirectoryURL: internalCaches,
            preferredExternalRootURL: externalRoot,
            usesExternalStorage: false,
            requiresRestart: true
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: UUID(),
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [],
            previewCacheLocationSelectionResult: .restartRequired(pendingStatus)
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.chooseExternalAppStorageLocation()

        XCTAssertEqual(service.previewCacheLocationSelectionCallCount, 1)
        XCTAssertEqual(model.appStorageLocation, pendingStatus)
        XCTAssertEqual(model.notice, .appStorageLocationRequiresRestart)
        XCTAssertFalse(model.isChoosingAppStorageLocation)
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

    func testThumbnailCancellationIsNotSettledAsUnavailable() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "cancel-thumb.jpg")
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
            thumbnailData: Data("thumb".utf8),
            thumbnailCancelOnCall: 1
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.start()

        let result = await model.loadThumbnailResult(assetID: asset.assetID)

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(service.thumbnailLoadCallCount, 1)
    }

    func testThumbnailTransientFailuresRetryUntilSuccess() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "retry-thumb.jpg")
        let payload = Data("recovered-thumb".utf8)
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
            thumbnailData: payload,
            thumbnailFailureCount: 2,
            thumbnailFailureError: PhotosLibraryError.libraryUnavailable
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.start()

        let result = await model.loadThumbnailResultWithRetry(assetID: asset.assetID, maxAttempts: 4)

        XCTAssertEqual(result, .loaded(payload))
        XCTAssertEqual(service.thumbnailLoadCallCount, 3)
        XCTAssertEqual(model.cachedThumbnailData(for: asset.assetID), payload)
    }

    func testThumbnailExhaustedTransientFailuresBecomeUnavailable() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "fail-thumb.jpg")
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
            thumbnailFailureCount: 8,
            thumbnailFailureError: PhotosLibraryError.libraryUnavailable
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.start()

        let result = await model.loadThumbnailResultWithRetry(assetID: asset.assetID, maxAttempts: 3)

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(service.thumbnailLoadCallCount, 3)
    }

    func testCachedThumbnailSurvivesSoftFirstPageRefresh() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "cached-thumb.jpg")
        let payload = Data("cached-thumb".utf8)
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
        let model = LibraryWorkspaceModel(service: service)
        await model.start()

        let first = await model.loadThumbnailResult(assetID: asset.assetID)
        XCTAssertEqual(first, .loaded(payload))
        XCTAssertEqual(service.thumbnailLoadCallCount, 1)

        await model.applySearchText("")
        let second = await model.loadThumbnailResult(assetID: asset.assetID)

        XCTAssertEqual(second, .loaded(payload))
        XCTAssertEqual(service.thumbnailLoadCallCount, 1)
    }

    func testThumbnailAuthorizationFailuresAreUnavailableWithoutRetry() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "denied-thumb.jpg")
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
            thumbnailFailureCount: 5,
            thumbnailFailureError: PhotosLibraryError.authorizationDenied
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.start()

        let single = await model.loadThumbnailResult(assetID: asset.assetID)
        let retried = await model.loadThumbnailResultWithRetry(assetID: asset.assetID, maxAttempts: 4)

        XCTAssertEqual(single, .unavailable)
        XCTAssertEqual(retried, .unavailable)
        XCTAssertEqual(service.thumbnailLoadCallCount, 2)
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

    func testLocalModelSuggestionsRunOnlyAfterExplicitRequestForCurrentAsset() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "standard-preview.jpg")
        let previewData = Data("standard-preview".utf8)
        let suggestion = Self.makeStandardSuggestion(recommendedState: .autoAssigned)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            previewData: previewData
        )
        let client = FakeLocalModelSuggestionClient(result: .success([suggestion]))
        let review = FakePersonalizationReviewPort()
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )

        await model.start()
        await model.selectAsset(asset.assetID)

        XCTAssertEqual(client.callCount, 0)
        XCTAssertEqual(client.standardCapabilityCallCount, 0)
        XCTAssertEqual(model.localModelSuggestionState, .ready(assetID: asset.assetID))

        await model.requestLocalModelSuggestions()

        XCTAssertEqual(client.standardCapabilityCallCount, 1)
        XCTAssertEqual(client.callCount, 1)
        XCTAssertEqual(client.lastImageData, previewData)
        XCTAssertEqual(
            model.localModelSuggestionState,
            .results(assetID: asset.assetID, suggestions: [suggestion])
        )
        XCTAssertEqual(service.mutateTagCallCount, 0)
        XCTAssertEqual(service.standardOntologyInstallCallCount, 1)
        XCTAssertEqual(
            review.standardSuggestionReplacements,
            [
                FakeStandardSuggestionReplacement(
                    assetID: asset.assetID,
                    contentRevision: asset.contentRevision,
                    suggestions: [suggestion],
                    expectedTarget: StandardModelSuggestionTarget(
                        standardPackID: "imageall-public-fixture",
                        standardPackRevision: "pack-v1"
                    )
                ),
            ]
        )
    }

    func testMismatchedStandardCapabilityStopsBeforeInstallOrPreviewRead() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "mismatch.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            previewData: Data("must-not-read".utf8)
        )
        let fixture = StandardModelSuggestionCapability.fixture
        let client = FakeLocalModelSuggestionClient(
            result: .success([]),
            standardCapability: .available(
                StandardModelSuggestionCapability(
                    target: fixture.target,
                    manifestSHA256: fixture.manifestSHA256,
                    ontologyID: fixture.ontologyID,
                    ontologyRevision: fixture.ontologyRevision,
                    provider: fixture.provider,
                    modelID: "unapproved/model",
                    modelRevision: fixture.modelRevision,
                    preprocessingRevision: fixture.preprocessingRevision,
                    mappingRevision: fixture.mappingRevision,
                    policyRevision: fixture.policyRevision,
                    weightsSHA256: fixture.weightsSHA256
                )
            )
        )
        let review = FakePersonalizationReviewPort()
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )
        await model.start()
        await model.selectAsset(asset.assetID)

        await model.requestLocalModelSuggestions()

        XCTAssertEqual(client.standardCapabilityCallCount, 1)
        XCTAssertEqual(client.callCount, 0)
        XCTAssertEqual(service.standardOntologyInstallCallCount, 0)
        XCTAssertEqual(service.previewLoadCallCount, 0)
        XCTAssertTrue(review.standardSuggestionReplacements.isEmpty)
        XCTAssertEqual(model.localModelSuggestionState, .failed(assetID: asset.assetID))
    }

    func testOfflineLocalModelSuggestionServiceFailsClosedWithoutTagMutation() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "offline.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            previewData: Data("preview".utf8)
        )
        let client = FakeLocalModelSuggestionClient(
            result: .failure(.serviceUnavailable)
        )
        let model = LibraryWorkspaceModel(
            service: service,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )

        await model.start()
        await model.selectAsset(asset.assetID)
        await model.requestLocalModelSuggestions()

        XCTAssertEqual(
            model.localModelSuggestionState,
            .serviceUnavailable(assetID: asset.assetID)
        )
        XCTAssertEqual(service.mutateTagCallCount, 0)
        XCTAssertNil(model.notice)
    }

    func testStandardSuggestionPersistenceFailureDoesNotDisplayModelResult() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "publish-failure.jpg")
        let suggestion = Self.makeStandardSuggestion(recommendedState: .suggested)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            previewData: Data("preview".utf8)
        )
        let review = FakePersonalizationReviewPort(
            standardSuggestionReplacementFails: true
        )
        let client = FakeLocalModelSuggestionClient(result: .success([suggestion]))
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )

        await model.start()
        await model.selectAsset(asset.assetID)
        await model.requestLocalModelSuggestions()

        XCTAssertEqual(model.localModelSuggestionState, .failed(assetID: asset.assetID))
        XCTAssertTrue(review.standardSuggestionReplacements.isEmpty)
        XCTAssertEqual(service.mutateTagCallCount, 0)
    }

    func testLocalModelSuggestionResultIsDiscardedAfterSelectionChanges() async {
        let sourceID = UUID()
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "second.jpg")
        let suggestion = Self.makeStandardSuggestion(recommendedState: .suggested)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [first, second],
            initialItems: [first, second],
            startsConnected: true,
            previewData: Data("preview".utf8)
        )
        let client = FakeLocalModelSuggestionClient(
            result: .success([suggestion]),
            blocksRequests: true
        )
        let model = LibraryWorkspaceModel(
            service: service,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )
        await model.start()
        await model.selectAsset(first.assetID)

        let request = Task { await model.requestLocalModelSuggestions() }
        for _ in 0 ..< 10_000 where !client.hasBlockedRequest {
            await Task.yield()
        }
        XCTAssertTrue(client.hasBlockedRequest)

        await model.selectAsset(second.assetID)
        client.releaseBlockedRequest()
        await request.value

        XCTAssertEqual(
            model.localModelSuggestionState,
            .ready(assetID: second.assetID)
        )
    }

    func testStandardSuggestionResultIsDiscardedAfterContentRevisionChanges() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "changed.jpg")
        let suggestion = Self.makeStandardSuggestion(recommendedState: .suggested)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            previewData: Data("old-preview".utf8)
        )
        let client = FakeLocalModelSuggestionClient(
            result: .success([suggestion]),
            blocksRequests: true
        )
        let review = FakePersonalizationReviewPort()
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )
        await model.start()
        await model.selectAsset(asset.assetID)

        let request = Task { await model.requestLocalModelSuggestions() }
        for _ in 0 ..< 10_000 where !client.hasBlockedRequest {
            await Task.yield()
        }
        XCTAssertTrue(client.hasBlockedRequest)

        service.setContentRevision(assetID: asset.assetID, contentRevision: 2)
        client.releaseBlockedRequest()
        await request.value

        XCTAssertEqual(model.localModelSuggestionState, .failed(assetID: asset.assetID))
        XCTAssertTrue(review.standardSuggestionReplacements.isEmpty)
    }

    func testLocalModelSuggestionsReuseExplicitlyDownloadedCloudPreview() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "cloud-model.jpg")
        let downloaded = Data("downloaded-standard-preview".utf8)
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
            cloudPreviewData: downloaded
        )
        let client = FakeLocalModelSuggestionClient(result: .success([]))
        let review = FakePersonalizationReviewPort()
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )
        await model.start()
        await model.selectAsset(asset.assetID)
        _ = await model.previewData(assetID: asset.assetID)

        model.downloadCloudPreview(assetID: asset.assetID)
        await waitForCloudPreviewState(
            .downloaded(assetID: asset.assetID, data: downloaded),
            model: model
        )
        await model.requestLocalModelSuggestions()

        XCTAssertEqual(client.lastImageData, downloaded)
        XCTAssertEqual(service.cloudPreviewDownloadCallCount, 1)
        XCTAssertEqual(
            model.localModelSuggestionState,
            .results(assetID: asset.assetID, suggestions: [])
        )
    }

    func testCurrentCatalogPersonalSuggestionStaysTransientUntilExplicitAcceptance() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "personal-preview.jpg")
        let tag = TagListItem(id: UUID(), displayName: "旅行", state: .active)
        let capability = Self.makePersonalCapability(tagIDs: [tag.id])
        let suggestion = Self.makePersonalSuggestion(tagID: tag.id)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            tags: [tag],
            initialItems: [asset],
            startsConnected: true,
            previewData: Data("personal-preview".utf8)
        )
        let client = FakeLocalModelSuggestionClient(
            result: .success([suggestion]),
            personalCapability: .available(capability)
        )
        let model = LibraryWorkspaceModel(
            service: service,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )

        await model.start()
        await model.selectAsset(asset.assetID)
        await model.requestPersonalModelSuggestions()

        XCTAssertEqual(client.lastTarget, .personal(capability.target))
        XCTAssertEqual(
            model.localModelSuggestionState,
            .results(assetID: asset.assetID, suggestions: [suggestion])
        )
        XCTAssertEqual(service.mutateTagCallCount, 0)

        await model.applyLocalModelSuggestionDecision(suggestion, action: .accept)

        XCTAssertEqual(service.mutateTagCallCount, 1)
        XCTAssertEqual(
            model.inspectorTags.first(where: { $0.id == tag.id })?.decision,
            .accepted
        )
        XCTAssertEqual(
            model.localModelSuggestionState,
            .results(assetID: asset.assetID, suggestions: [])
        )
    }

    func testUserTriggeredPersonalLibraryScanEnqueuesVersionedPersistentJob() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "personal-library.jpg")
        let tag = TagListItem(id: UUID(), displayName: "旅行", state: .active)
        let secondTag = TagListItem(id: UUID(), displayName: "家人", state: .active)
        let capability = Self.makePersonalCapability(tagIDs: [tag.id, secondTag.id])
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            tags: [tag, secondTag],
            initialItems: [asset],
            startsConnected: true,
            previewData: Data("personal-library-preview".utf8)
        )
        let review = FakePersonalizationReviewPort()
        let client = FakeLocalModelSuggestionClient(
            result: .success([]),
            personalCapability: .available(capability)
        )
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )
        await model.start()

        await model.generatePersonalLibrarySuggestions()

        XCTAssertEqual(
            model.personalLibrarySuggestionState,
            .waiting(checked: 0, suggested: 0, skipped: 0)
        )
        XCTAssertEqual(review.activatedPersonalCapability, capability)
        XCTAssertEqual(review.enqueuedPersonalCapability, capability)
        XCTAssertEqual(client.personalCapabilityCallCount, 1)
        XCTAssertEqual(client.callCount, 0)
        XCTAssertEqual(service.previewLoadCallCount, 0)
        XCTAssertEqual(service.mutateTagCallCount, 0)
    }

    func testStartRestoresPendingPersonalLibrarySuggestionJobAndStartsWorker() async {
        let sourceID = UUID()
        let jobID = UUID()
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [],
            initialItems: [],
            startsConnected: true
        )
        let review = FakePersonalizationReviewPort(
            personalLibraryJob: PersonalLibrarySuggestionJobProjection(
                id: jobID,
                state: .pending,
                checkedCount: 7,
                totalCount: 20,
                suggestedCount: 3,
                skippedCount: 1,
                lastErrorCode: nil
            )
        )
        let client = FakeLocalModelSuggestionClient(result: .success([]))
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )

        await model.start()
        for _ in 0 ..< 40 where review.runPendingJobsCallCount == 0 {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(
            model.personalLibrarySuggestionState,
            .waiting(checked: 7, suggested: 3, skipped: 1)
        )
        XCTAssertGreaterThanOrEqual(review.runPendingJobsCallCount, 1)
    }

    func testReviewOverviewPausesPendingPersonalLibrarySuggestionJob() async {
        let jobID = UUID()
        let otherSuggestionJobID = UUID()
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: UUID(),
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [],
            jobActivityItems: [
                JobActivityItem(
                    id: otherSuggestionJobID,
                    kind: .personalizationSuggestions,
                    state: .running,
                    controlRequest: .none,
                    progress: JobProgress(completed: 8, total: 10)
                ),
                JobActivityItem(
                    id: jobID,
                    kind: .personalizationSuggestions,
                    state: .pending,
                    controlRequest: .none,
                    progress: JobProgress(completed: 4, total: 20)
                ),
            ]
        )
        let review = FakePersonalizationReviewPort(
            personalLibraryJob: PersonalLibrarySuggestionJobProjection(
                id: jobID,
                state: .pending,
                checkedCount: 4,
                totalCount: 20,
                suggestedCount: 2,
                skippedCount: 1,
                lastErrorCode: nil
            )
        )
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: Self.makeStandardRuntime(
                client: FakeLocalModelSuggestionClient(result: .success([]))
            )
        )

        await model.enterReviewOverview()

        XCTAssertEqual(
            model.personalLibrarySuggestionJobActivity?.availableActions,
            [.pause, .cancel]
        )

        await model.applyPersonalLibrarySuggestionAction(.pause)

        XCTAssertEqual(service.jobActivityActionCallCount, 1)
        XCTAssertEqual(model.personalLibrarySuggestionJobActivity?.id, jobID)
        XCTAssertEqual(model.jobActivityItems.first?.id, otherSuggestionJobID)
        XCTAssertEqual(model.jobActivityItems.first?.state, .running)
        XCTAssertEqual(model.personalLibrarySuggestionJobActivity?.state, .paused)
        XCTAssertEqual(
            model.personalLibrarySuggestionJobActivity?.availableActions,
            [.resume, .cancel]
        )
    }

    func testReviewOverviewPausesPendingStandardLibrarySuggestionJob() async {
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
                    kind: .standardSuggestions,
                    state: .pending,
                    controlRequest: .none,
                    progress: JobProgress(completed: 4, total: 20)
                ),
            ]
        )
        let review = FakePersonalizationReviewPort(
            standardLibraryJob: StandardLibrarySuggestionJobProjection(
                id: jobID,
                state: .pending,
                checkedCount: 4,
                totalCount: 20,
                suggestedCount: 2,
                skippedCount: 1,
                lastErrorCode: nil
            )
        )
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: Self.makeStandardRuntime(
                client: FakeLocalModelSuggestionClient(result: .success([]))
            )
        )

        await model.enterReviewOverview()
        XCTAssertEqual(
            model.standardLibrarySuggestionJobActivity?.availableActions,
            [.pause, .cancel]
        )

        await model.applyStandardLibrarySuggestionAction(.pause)

        XCTAssertEqual(service.jobActivityActionCallCount, 1)
        XCTAssertEqual(model.standardLibrarySuggestionJobActivity?.id, jobID)
        XCTAssertEqual(model.standardLibrarySuggestionJobActivity?.state, .paused)
        XCTAssertEqual(
            model.standardLibrarySuggestionJobActivity?.availableActions,
            [.resume, .cancel]
        )
    }

    func testReviewOverviewImmediatelyRetriesRetryablePersonalLibrarySuggestionJob() async {
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
                    kind: .personalizationSuggestions,
                    state: .retryableFailed,
                    controlRequest: .none,
                    progress: JobProgress(completed: 4, total: 20)
                ),
            ]
        )
        let review = FakePersonalizationReviewPort(
            personalLibraryJob: PersonalLibrarySuggestionJobProjection(
                id: jobID,
                state: .retryableFailed,
                checkedCount: 4,
                totalCount: 20,
                suggestedCount: 2,
                skippedCount: 1,
                lastErrorCode: .interrupted
            )
        )
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: Self.makeStandardRuntime(
                client: FakeLocalModelSuggestionClient(result: .success([]))
            )
        )

        await model.enterReviewOverview()

        XCTAssertEqual(
            model.personalLibrarySuggestionJobActivity?.availableActions,
            [.resume, .cancel]
        )

        await model.applyPersonalLibrarySuggestionAction(.resume)

        XCTAssertEqual(service.jobActivityActionCallCount, 1)
        XCTAssertEqual(model.personalLibrarySuggestionJobActivity?.id, jobID)
        XCTAssertEqual(model.personalLibrarySuggestionJobActivity?.state, .pending)
        XCTAssertEqual(
            model.personalLibrarySuggestionJobActivity?.availableActions,
            [.pause, .cancel]
        )
    }

    func testPersonalLibraryScanEnqueueDoesNotDownloadCloudOnlyAssets() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "cloud-only-personal.jpg")
        let tag = TagListItem(id: UUID(), displayName: "旅行", state: .active)
        let capability = Self.makePersonalCapability(tagIDs: [tag.id])
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .photos,
                displayName: "Apple Photos",
                state: .active
            ),
            reconciledItems: [asset],
            tags: [tag],
            initialItems: [asset],
            startsConnected: true,
            previewError: .cloudOnly
        )
        let review = FakePersonalizationReviewPort()
        let client = FakeLocalModelSuggestionClient(
            result: .success([]),
            personalCapability: .available(capability)
        )
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )
        await model.start()

        await model.generatePersonalLibrarySuggestions()

        XCTAssertEqual(
            model.personalLibrarySuggestionState,
            .waiting(checked: 0, suggested: 0, skipped: 0)
        )
        XCTAssertEqual(client.callCount, 0)
        XCTAssertEqual(service.previewLoadCallCount, 0)
        XCTAssertEqual(service.cloudPreviewDownloadCallCount, 0)
        XCTAssertEqual(review.enqueuedPersonalCapability, capability)
    }

    func testReviewOverviewEnqueuesStandardLibraryScanWithoutForegroundImageReads() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "standard-library.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            previewError: .cloudOnly
        )
        let review = FakePersonalizationReviewPort()
        let client = FakeLocalModelSuggestionClient(result: .success([]))
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )
        await model.start()

        await model.generateStandardLibrarySuggestions()

        XCTAssertEqual(client.standardCapabilityCallCount, 1)
        XCTAssertEqual(
            model.standardLibrarySuggestionState,
            .waiting(checked: 0, suggested: 0, skipped: 0)
        )
        XCTAssertEqual(service.standardOntologyInstallCallCount, 1)
        XCTAssertEqual(
            review.enqueuedStandardTarget,
            StandardModelSuggestionTarget(
                standardPackID: "imageall-public-fixture",
                standardPackRevision: "pack-v1"
            )
        )
        XCTAssertEqual(service.previewLoadCallCount, 0)
        XCTAssertEqual(service.cloudPreviewDownloadCallCount, 0)
    }

    func testUnavailableStandardCapabilityDoesNotInstallOrEnqueueLibraryScan() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "standard-unavailable.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true
        )
        let review = FakePersonalizationReviewPort()
        let client = FakeLocalModelSuggestionClient(
            result: .success([]),
            standardCapability: .unavailable
        )
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )
        await model.start()

        await model.generateStandardLibrarySuggestions()

        XCTAssertEqual(client.standardCapabilityCallCount, 1)
        XCTAssertEqual(model.standardLibrarySuggestionState, .serviceUnavailable)
        XCTAssertEqual(service.standardOntologyInstallCallCount, 0)
        XCTAssertNil(review.enqueuedStandardTarget)
        XCTAssertEqual(service.previewLoadCallCount, 0)
        XCTAssertEqual(service.cloudPreviewDownloadCallCount, 0)
    }

    func testUnavailablePersonalBundleInvalidatesPersistedPersonalSuggestions() async {
        let sourceID = UUID()
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [],
            startsConnected: true
        )
        let review = FakePersonalizationReviewPort()
        let client = FakeLocalModelSuggestionClient(result: .success([]))
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )
        await model.start()

        await model.generatePersonalLibrarySuggestions()

        XCTAssertEqual(model.personalLibrarySuggestionState, .personalUnavailable)
        XCTAssertEqual(review.personalSuggestionInvalidationCallCount, 1)
        XCTAssertEqual(client.callCount, 0)
        XCTAssertEqual(service.previewLoadCallCount, 0)
    }

    func testPersonalLibraryScanFreezesCapabilityWithoutForegroundRecheck() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "bundle-change.jpg")
        let tag = TagListItem(id: UUID(), displayName: "旅行", state: .active)
        let initialCapability = Self.makePersonalCapability(tagIDs: [tag.id])
        let changedCapability = PersonalModelSuggestionCapability(
            target: PersonalModelSuggestionTarget(
                catalogScopeID: initialCapability.target.catalogScopeID,
                bundleID: initialCapability.target.bundleID,
                bundleRevision: "bundle-v2",
                provider: initialCapability.target.provider,
                modelID: initialCapability.target.modelID,
                modelRevision: initialCapability.target.modelRevision,
                preprocessingRevision: initialCapability.target.preprocessingRevision,
                elementCount: initialCapability.target.elementCount,
                labelVocabularyRevision: initialCapability.target.labelVocabularyRevision,
                weightsSHA256: String(repeating: "c", count: 64),
                policyRevision: initialCapability.target.policyRevision
            ),
            tagIDs: initialCapability.tagIDs
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            tags: [tag],
            initialItems: [asset],
            startsConnected: true,
            previewData: Data("bundle-change-preview".utf8)
        )
        let review = FakePersonalizationReviewPort()
        let client = FakeLocalModelSuggestionClient(
            result: .success([Self.makePersonalSuggestion(tagID: tag.id)]),
            personalCapabilities: [
                .available(initialCapability),
                .available(changedCapability),
            ]
        )
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )
        await model.start()

        await model.generatePersonalLibrarySuggestions()

        XCTAssertEqual(
            model.personalLibrarySuggestionState,
            .waiting(checked: 0, suggested: 0, skipped: 0)
        )
        XCTAssertEqual(review.enqueuedPersonalCapability, initialCapability)
        XCTAssertEqual(client.personalCapabilityCallCount, 1)
        XCTAssertEqual(client.callCount, 0)
        XCTAssertEqual(service.mutateTagCallCount, 0)
    }

    func testUserTriggeredPersonalRebuildPublishesOnlyVersionedManualSnapshot() async throws {
        let sourceID = UUID()
        let tagID = UUID(uuidString: "2C000000-0000-4000-8000-000000000001")!
        let archivedTagID = UUID(uuidString: "2C000000-0000-4000-8000-000000000002")!
        let assetIDs = (1 ... 4).map { index in
            UUID(uuidString: String(format: "2D000000-0000-4000-8000-%012d", index))!
        }
        let decisions = Self.makePersonalTrainingDecisions(
            tagID: tagID,
            assetIDs: assetIDs
        )
        let tag = TagListItem(id: tagID, displayName: "旅行", state: .active)
        let items = assetIDs.map { assetID in
            AssetGridItemProjection(
                assetID: assetID,
                sourceID: sourceID,
                sourceDisplayName: "Fixture",
                sourceState: .active,
                relativePath: "\(assetID).jpg",
                fileName: "\(assetID).jpg",
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
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: items,
            tags: [
                tag,
                TagListItem(id: archivedTagID, displayName: "旧标签", state: .archived),
            ],
            initialItems: items,
            startsConnected: true,
            previewData: Data("personal-training-preview".utf8)
        )
        let snapshot = PersonalTrainingSnapshot(
            catalogScopeID: "catalog-fixture",
            personalTagIDs: [tagID],
            decisions: decisions
        )
        let review = FakePersonalizationReviewPort(trainingSnapshot: snapshot)
        let encoder = PersonalTrainingEncoderIdentity(
            provider: "dinov2",
            modelID: "facebook/dinov2-small",
            modelRevision: "model-v1",
            preprocessingRevision: "preprocessing-v1",
            elementCount: 2
        )
        let rebuiltCapability = PersonalModelSuggestionCapability(
            target: PersonalModelSuggestionTarget(
                catalogScopeID: "catalog-fixture",
                bundleID: PersonalSuggestionMethod.linearHeadBundleID,
                bundleRevision: "bundle-v2",
                provider: encoder.provider,
                modelID: encoder.modelID,
                modelRevision: encoder.modelRevision,
                preprocessingRevision: encoder.preprocessingRevision,
                elementCount: encoder.elementCount,
                labelVocabularyRevision: String(repeating: "c", count: 64),
                weightsSHA256: String(repeating: "d", count: 64),
                policyRevision: "personal-policy-v1"
            ),
            tagIDs: [tagID]
        )
        let existingCapability = PersonalModelSuggestionCapability(
            target: PersonalModelSuggestionTarget(
                catalogScopeID: "catalog-fixture",
                bundleID: PersonalSuggestionMethod.linearHeadBundleID,
                bundleRevision: "bundle-v1",
                provider: encoder.provider,
                modelID: encoder.modelID,
                modelRevision: encoder.modelRevision,
                preprocessingRevision: encoder.preprocessingRevision,
                elementCount: encoder.elementCount,
                labelVocabularyRevision: String(repeating: "a", count: 64),
                weightsSHA256: String(repeating: "b", count: 64),
                policyRevision: "personal-policy-v1"
            ),
            tagIDs: [tagID, archivedTagID]
        )
        let client = FakeLocalModelSuggestionClient(
            result: .success([]),
            personalCapabilities: [
                .available(existingCapability),
                .available(rebuiltCapability),
            ],
            embeddingResult: .success(
                PersonalTrainingEmbedding(encoder: encoder, values: [0.25, -0.5])
            ),
            rebuildResult: .success(rebuiltCapability)
        )
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )
        await model.start()

        await model.rebuildPersonalModel()

        let published = try XCTUnwrap(client.lastRebuildSnapshot)
        XCTAssertEqual(
            client.lastExpectedActiveBundle,
            PersonalModelActiveBundleIdentity(
                bundleRevision: "bundle-v1",
                weightsSHA256: String(repeating: "b", count: 64)
            )
        )
        XCTAssertEqual(client.embeddingCallCount, 4)
        let expectedEmbeddingCacheKeys: [PersonalTrainingEmbeddingCacheKey?] = assetIDs.map {
            PersonalTrainingEmbeddingCacheKey(
                catalogScopeID: "catalog-fixture",
                assetID: $0,
                contentRevision: 1
            )
        }
        XCTAssertEqual(client.embeddingCacheKeys, expectedEmbeddingCacheKeys)
        XCTAssertEqual(client.rebuildCallCount, 1)
        XCTAssertEqual(client.personalCapabilityCallCount, 2)
        XCTAssertEqual(published.catalogScopeID, "catalog-fixture")
        XCTAssertEqual(published.encoder, encoder)
        XCTAssertEqual(published.personalTagIDs, [tagID])
        XCTAssertEqual(published.decisions, decisions)
        XCTAssertEqual(Set(published.embeddings.map(\.assetID)), Set(assetIDs))
        XCTAssertEqual(published.embeddings.map(\.contentRevision), [1, 1, 1, 1])
        XCTAssertTrue(Self.isLowercaseSHA256(published.decisionSnapshotRevision))
        XCTAssertTrue(Self.isLowercaseSHA256(published.labelVocabularyRevision))
        XCTAssertFalse(model.isRebuildingPersonalModel)
        XCTAssertEqual(
            model.notice,
            .personalModelRebuildCompleted(tagCount: 1, sampleCount: 4)
        )
    }

    func testUserTriggeredPersonalRebuildUsesTheAppRuntimeWithoutLoopback() async {
        let tagID = UUID()
        let assetIDs = (0..<4).map { _ in UUID() }
        let snapshot = PersonalTrainingSnapshot(
            catalogScopeID: UUID().uuidString.lowercased(),
            personalTagIDs: [tagID],
            decisions: Self.makePersonalTrainingDecisions(
                tagID: tagID,
                assetIDs: assetIDs
            )
        )
        let rebuilder = FakeAppPersonalModelRebuilder(
            result: .success(
                AppPersonalLinearHeadIdentity(
                    catalogScopeID: snapshot.catalogScopeID,
                    decisionSnapshotRevision: String(repeating: "1", count: 64),
                    labelVocabularyRevision: String(repeating: "2", count: 64),
                    encoderIdentity: AppCoreMLModelIdentity(
                        provider: "dinov2",
                        modelID: "facebook/dinov2-small",
                        modelRevision: "model-v1",
                        preprocessingRevision: "preprocessing-v1",
                        embeddingSemantics: "dinov2-cls-token",
                        postprocessingRevision: "raw-float32-v1",
                        elementType: "float32",
                        elementCount: 384,
                        sourceModelSHA256: String(repeating: "3", count: 64),
                        artifactSHA256: String(repeating: "4", count: 64),
                        manifestSHA256: String(repeating: "5", count: 64),
                        licenseID: "Apache-2.0",
                        licenseSHA256: String(repeating: "6", count: 64)
                    ),
                    personalTagIDs: [tagID],
                    weightsSHA256: String(repeating: "7", count: 64)
                )
            )
        )
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: UUID(),
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: [],
                tags: [TagListItem(id: tagID, displayName: "旅行", state: .active)]
            ),
            review: FakePersonalizationReviewPort(trainingSnapshot: snapshot),
            appPersonalModelRebuilder: rebuilder
        )

        XCTAssertTrue(model.supportsPersonalModelRebuild)
        await model.start()
        await model.toggleIncludedTagFilter(tagID)
        await model.rebuildPersonalModel()

        let rebuildCallCount = await rebuilder.callCount()
        XCTAssertEqual(rebuildCallCount, 1)
        XCTAssertEqual(
            model.notice,
            // makePersonalTrainingDecisions seeds 2 accepted + 2 rejected; training uses accepted only.
            .personalModelRebuildCompleted(tagCount: 1, sampleCount: 2)
        )
        XCTAssertFalse(model.isRebuildingPersonalModel)
    }

    func testAppPersonalRebuildCacheMissLeavesBrowsingAndManualTagsAvailable() async {
        let sourceID = UUID()
        let assetA = Self.makeAsset(sourceID: sourceID, fileName: "cached-miss-a.jpg")
        let assetB = Self.makeAsset(sourceID: sourceID, fileName: "cached-miss-b.jpg")
        let tag = TagListItem(id: UUID(), displayName: "旅行", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [assetA, assetB],
            tags: [tag],
            initialItems: [assetA, assetB],
            startsConnected: true
        )
        let rebuilder = FakeAppPersonalModelRebuilder(
            result: .failure(AppPersonalModelRebuildError.embeddingUnavailable)
        )
        let model = LibraryWorkspaceModel(
            service: service,
            review: FakePersonalizationReviewPort(
                trainingSnapshot: PersonalTrainingSnapshot(
                    catalogScopeID: UUID().uuidString.lowercased(),
                    personalTagIDs: [tag.id],
                    decisions: [
                        PersonalTrainingDecision(
                            assetID: assetA.assetID,
                            contentRevision: 1,
                            tagID: tag.id,
                            state: .manualAccepted
                        ),
                        PersonalTrainingDecision(
                            assetID: assetB.assetID,
                            contentRevision: 1,
                            tagID: tag.id,
                            state: .manualAccepted
                        ),
                    ]
                )
            ),
            appPersonalModelRebuilder: rebuilder
        )
        await model.start()
        await model.toggleIncludedTagFilter(tag.id)

        await model.rebuildPersonalModel()

        XCTAssertEqual(Set(model.items.map(\.assetID)), [assetA.assetID, assetB.assetID])
        XCTAssertEqual(model.tags.map(\.id), [tag.id])
        XCTAssertEqual(service.mutateTagCallCount, 0)
        XCTAssertEqual(model.notice, .personalModelRebuildCacheUnavailable)
        XCTAssertFalse(model.isRebuildingPersonalModel)
    }

    func testAppPersonalRebuildRequiresIncludedTagFilter() async {
        let sourceID = UUID()
        let tagID = UUID()
        let assetIDs = [UUID(), UUID()]
        let tag = TagListItem(id: tagID, displayName: "旅行", state: .active)
        let assets = assetIDs.enumerated().map { index, assetID in
            Self.makeAsset(sourceID: sourceID, assetID: assetID, fileName: "asset-\(index).png")
        }
        let snapshot = PersonalTrainingSnapshot(
            catalogScopeID: UUID().uuidString.lowercased(),
            personalTagIDs: [tagID],
            decisions: assetIDs.map { assetID in
                PersonalTrainingDecision(
                    assetID: assetID,
                    contentRevision: 1,
                    tagID: tagID,
                    state: .manualAccepted
                )
            }
        )
        let rebuilder = FakeAppPersonalModelRebuilder(
            result: .success(
                AppPersonalLinearHeadIdentity(
                    catalogScopeID: snapshot.catalogScopeID,
                    decisionSnapshotRevision: String(repeating: "1", count: 64),
                    labelVocabularyRevision: String(repeating: "2", count: 64),
                    encoderIdentity: AppCoreMLModelIdentity(
                        provider: "dinov2",
                        modelID: "facebook/dinov2-small",
                        modelRevision: "model-v1",
                        preprocessingRevision: "preprocessing-v1",
                        embeddingSemantics: "dinov2-cls-token",
                        postprocessingRevision: "raw-float32-v1",
                        elementType: "float32",
                        elementCount: 384,
                        sourceModelSHA256: String(repeating: "3", count: 64),
                        artifactSHA256: String(repeating: "4", count: 64),
                        manifestSHA256: String(repeating: "5", count: 64),
                        licenseID: "Apache-2.0",
                        licenseSHA256: String(repeating: "6", count: 64)
                    ),
                    personalTagIDs: [tagID],
                    weightsSHA256: String(repeating: "7", count: 64)
                )
            )
        )
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: sourceID,
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: assets,
                tags: [tag],
                initialItems: assets,
                startsConnected: true
            ),
            review: FakePersonalizationReviewPort(trainingSnapshot: snapshot),
            appPersonalModelRebuilder: rebuilder
        )
        await model.start()
        XCTAssertTrue(model.selectedTagFilterIDs.isEmpty)

        await model.rebuildPersonalModel()

        let rebuildCallCount = await rebuilder.callCount()
        XCTAssertEqual(rebuildCallCount, 0)
        XCTAssertEqual(model.notice, .personalModelRebuildTagSelectionRequired)
        XCTAssertFalse(model.isRebuildingPersonalModel)
    }

    func testAppPersonalRebuildUsesAcceptedTagsOnSelectedAssetsOnly() async {
        let sourceID = UUID()
        let selectedTagID = UUID()
        let ignoredTagID = UUID()
        let selectedAssetIDs = [UUID(), UUID()]
        let historicalOnlyAssetID = UUID()
        let selectedAssets = selectedAssetIDs.enumerated().map { index, assetID in
            Self.makeAsset(
                sourceID: sourceID,
                assetID: assetID,
                fileName: "selected-\(index).png"
            )
        }
        let historicalOnlyAsset = Self.makeAsset(
            sourceID: sourceID,
            assetID: historicalOnlyAssetID,
            fileName: "historical-only.png"
        )
        let allAssets = selectedAssets + [historicalOnlyAsset]
        let selectedTag = TagListItem(id: selectedTagID, displayName: "板栗", state: .active)
        let ignoredTag = TagListItem(id: ignoredTagID, displayName: "新疆", state: .active)
        let previewData = Data("program-generated-selected-preview".utf8)
        let snapshot = PersonalTrainingSnapshot(
            catalogScopeID: UUID().uuidString.lowercased(),
            personalTagIDs: [selectedTagID, ignoredTagID],
            decisions: (selectedAssetIDs + [historicalOnlyAssetID]).flatMap { assetID in
                [
                    PersonalTrainingDecision(
                        assetID: assetID,
                        contentRevision: 1,
                        tagID: selectedTagID,
                        state: .manualAccepted
                    ),
                    PersonalTrainingDecision(
                        assetID: assetID,
                        contentRevision: 1,
                        tagID: ignoredTagID,
                        state: .manualAccepted
                    ),
                ]
            }
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: allAssets,
            tags: [selectedTag, ignoredTag],
            initialItems: allAssets,
            startsConnected: true,
            previewData: previewData
        )
        let cache = FakeSelectedAssetEmbeddingCache()
        let rebuilder = FakeAppPersonalModelRebuilder(
            result: .success(
                AppPersonalLinearHeadIdentity(
                    catalogScopeID: snapshot.catalogScopeID,
                    decisionSnapshotRevision: String(repeating: "1", count: 64),
                    labelVocabularyRevision: String(repeating: "2", count: 64),
                    encoderIdentity: AppCoreMLModelIdentity(
                        provider: "dinov2",
                        modelID: "facebook/dinov2-small",
                        modelRevision: "model-v1",
                        preprocessingRevision: "preprocessing-v1",
                        embeddingSemantics: "dinov2-cls-token",
                        postprocessingRevision: "raw-float32-v1",
                        elementType: "float32",
                        elementCount: 384,
                        sourceModelSHA256: String(repeating: "3", count: 64),
                        artifactSHA256: String(repeating: "4", count: 64),
                        manifestSHA256: String(repeating: "5", count: 64),
                        licenseID: "Apache-2.0",
                        licenseSHA256: String(repeating: "6", count: 64)
                    ),
                    personalTagIDs: [selectedTagID],
                    weightsSHA256: String(repeating: "7", count: 64)
                )
            )
        )
        let model = LibraryWorkspaceModel(
            service: service,
            review: FakePersonalizationReviewPort(trainingSnapshot: snapshot),
            appPersonalModelRebuilder: rebuilder,
            selectedAssetEmbeddingCache: cache
        )
        await model.start()
        await model.toggleIncludedTagFilter(selectedTagID)
        await model.selectAssets(Set(selectedAssetIDs))

        await model.rebuildPersonalModel()

        let requests = await cache.requests()
        XCTAssertEqual(Set(requests.map(\.assetID)), Set(selectedAssetIDs))
        XCTAssertFalse(requests.map(\.assetID).contains(historicalOnlyAssetID))
        XCTAssertEqual(service.previewLoadCallCount, 2)
        let rebuildSnapshots = await rebuilder.snapshots()
        XCTAssertEqual(rebuildSnapshots.count, 1)
        XCTAssertEqual(rebuildSnapshots[0].personalTagIDs, [selectedTagID])
        XCTAssertFalse(rebuildSnapshots[0].decisions.contains { $0.tagID == ignoredTagID })
        XCTAssertEqual(
            Set(rebuildSnapshots[0].decisions.map(\.assetID)),
            Set(selectedAssetIDs)
        )
        XCTAssertEqual(
            model.notice,
            .personalModelRebuildCompleted(tagCount: 1, sampleCount: 2)
        )
        XCTAssertFalse(model.isRebuildingPersonalModel)
    }

    func testAppPersonalRebuildWithoutSelectionUsesHistoricalAcceptedSamples() async {
        let sourceID = UUID()
        let tagID = UUID()
        let historicalAssetIDs = [UUID(), UUID()]
        let historicalAssets = historicalAssetIDs.enumerated().map { index, assetID in
            Self.makeAsset(
                sourceID: sourceID,
                assetID: assetID,
                fileName: "historical-\(index).png"
            )
        }
        let tag = TagListItem(id: tagID, displayName: "旅行", state: .active)
        let previewData = Data("program-generated-historical-preview".utf8)
        let snapshot = PersonalTrainingSnapshot(
            catalogScopeID: UUID().uuidString.lowercased(),
            personalTagIDs: [tagID],
            decisions: historicalAssetIDs.map { assetID in
                PersonalTrainingDecision(
                    assetID: assetID,
                    contentRevision: 1,
                    tagID: tagID,
                    state: .manualAccepted
                )
            }
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: historicalAssets,
            tags: [tag],
            initialItems: historicalAssets,
            startsConnected: true,
            previewData: previewData
        )
        let cache = FakeSelectedAssetEmbeddingCache()
        let rebuilder = FakeAppPersonalModelRebuilder(
            result: .success(
                AppPersonalLinearHeadIdentity(
                    catalogScopeID: snapshot.catalogScopeID,
                    decisionSnapshotRevision: String(repeating: "1", count: 64),
                    labelVocabularyRevision: String(repeating: "2", count: 64),
                    encoderIdentity: AppCoreMLModelIdentity(
                        provider: "dinov2",
                        modelID: "facebook/dinov2-small",
                        modelRevision: "model-v1",
                        preprocessingRevision: "preprocessing-v1",
                        embeddingSemantics: "dinov2-cls-token",
                        postprocessingRevision: "raw-float32-v1",
                        elementType: "float32",
                        elementCount: 384,
                        sourceModelSHA256: String(repeating: "3", count: 64),
                        artifactSHA256: String(repeating: "4", count: 64),
                        manifestSHA256: String(repeating: "5", count: 64),
                        licenseID: "Apache-2.0",
                        licenseSHA256: String(repeating: "6", count: 64)
                    ),
                    personalTagIDs: [tagID],
                    weightsSHA256: String(repeating: "7", count: 64)
                )
            )
        )
        let model = LibraryWorkspaceModel(
            service: service,
            review: FakePersonalizationReviewPort(trainingSnapshot: snapshot),
            appPersonalModelRebuilder: rebuilder,
            selectedAssetEmbeddingCache: cache
        )
        await model.start()
        await model.toggleIncludedTagFilter(tagID)
        XCTAssertTrue(model.selectedAssetIDs.isEmpty)

        await model.rebuildPersonalModel()

        let requests = await cache.requests()
        XCTAssertEqual(Set(requests.map(\.assetID)), Set(historicalAssetIDs))
        let rebuildSnapshots = await rebuilder.snapshots()
        XCTAssertEqual(rebuildSnapshots.count, 1)
        XCTAssertEqual(
            Set(rebuildSnapshots[0].decisions.map(\.assetID)),
            Set(historicalAssetIDs)
        )
        XCTAssertEqual(
            model.notice,
            .personalModelRebuildCompleted(tagCount: 1, sampleCount: 2)
        )
    }

    func testAppPersonalRebuildSelectedAssetsWithoutEnoughAcceptedTagsStayNotReady() async {
        let sourceID = UUID()
        let tagID = UUID()
        let selectedAssetID = UUID()
        let historicalAssetIDs = [UUID(), UUID()]
        let selectedAsset = Self.makeAsset(
            sourceID: sourceID,
            assetID: selectedAssetID,
            fileName: "selected-one.png"
        )
        let historicalAssets = historicalAssetIDs.enumerated().map { index, assetID in
            Self.makeAsset(
                sourceID: sourceID,
                assetID: assetID,
                fileName: "historical-\(index).png"
            )
        }
        let tag = TagListItem(id: tagID, displayName: "旅行", state: .active)
        let snapshot = PersonalTrainingSnapshot(
            catalogScopeID: UUID().uuidString.lowercased(),
            personalTagIDs: [tagID],
            decisions: (historicalAssetIDs + [selectedAssetID]).map { assetID in
                PersonalTrainingDecision(
                    assetID: assetID,
                    contentRevision: 1,
                    tagID: tagID,
                    state: .manualAccepted
                )
            }
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: historicalAssets + [selectedAsset],
            tags: [tag],
            initialItems: historicalAssets + [selectedAsset],
            startsConnected: true
        )
        let rebuilder = FakeAppPersonalModelRebuilder(
            result: .success(
                AppPersonalLinearHeadIdentity(
                    catalogScopeID: snapshot.catalogScopeID,
                    decisionSnapshotRevision: String(repeating: "1", count: 64),
                    labelVocabularyRevision: String(repeating: "2", count: 64),
                    encoderIdentity: AppCoreMLModelIdentity(
                        provider: "dinov2",
                        modelID: "facebook/dinov2-small",
                        modelRevision: "model-v1",
                        preprocessingRevision: "preprocessing-v1",
                        embeddingSemantics: "dinov2-cls-token",
                        postprocessingRevision: "raw-float32-v1",
                        elementType: "float32",
                        elementCount: 384,
                        sourceModelSHA256: String(repeating: "3", count: 64),
                        artifactSHA256: String(repeating: "4", count: 64),
                        manifestSHA256: String(repeating: "5", count: 64),
                        licenseID: "Apache-2.0",
                        licenseSHA256: String(repeating: "6", count: 64)
                    ),
                    personalTagIDs: [tagID],
                    weightsSHA256: String(repeating: "7", count: 64)
                )
            )
        )
        let model = LibraryWorkspaceModel(
            service: service,
            review: FakePersonalizationReviewPort(trainingSnapshot: snapshot),
            appPersonalModelRebuilder: rebuilder
        )
        await model.start()
        await model.toggleIncludedTagFilter(tagID)
        await model.selectAsset(selectedAssetID)

        await model.rebuildPersonalModel()

        let rebuildCallCount = await rebuilder.callCount()
        XCTAssertEqual(rebuildCallCount, 0)
        XCTAssertEqual(model.notice, .personalModelRebuildNotReady)
    }

    func testAppPersonalSampleSuggestionsUsesLibraryCandidatesWhenNothingSelected() async {
        let sourceID = UUID()
        let tagID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let assets = (0..<3).map { index in
            Self.makeAsset(sourceID: sourceID, fileName: "sample-\(index).png")
        }
        let candidates = assets.map {
            PersonalSuggestionCandidate(assetID: $0.assetID, contentRevision: $0.contentRevision)
        }
        let capability = PersonalModelSuggestionCapability(
            target: PersonalModelSuggestionTarget(
                catalogScopeID: "catalog-fixture",
                bundleID: AppPersonalSuggestionCapabilityMapper.bundleID,
                bundleRevision: String(repeating: "a", count: 64),
                provider: "dinov2",
                modelID: "facebook/dinov2-small",
                modelRevision: "fixture",
                preprocessingRevision: "fixture",
                elementCount: 1,
                labelVocabularyRevision: String(repeating: "b", count: 64),
                weightsSHA256: String(repeating: "c", count: 64),
                policyRevision: AppPersonalSuggestionCapabilityMapper.policyRevision
            ),
            tagIDs: [tagID]
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: assets,
            tags: [TagListItem(id: tagID, displayName: "旅行", state: .active)],
            initialItems: assets,
            startsConnected: true,
            previewData: Data("sample-preview".utf8)
        )
        let review = FakePersonalizationReviewPort(personalCandidates: candidates)
        let suggester = FakeAppPersonalSampleSuggester(
            batch: AppPersonalSampleSuggestionBatch(
                capability: capability,
                results: [
                    AppPersonalSampleSuggestionAssetResult(
                        candidate: candidates[0],
                        predictions: [PersonalSuggestionPrediction(tagID: tagID, score: 1.25)]
                    ),
                    AppPersonalSampleSuggestionAssetResult(
                        candidate: candidates[1],
                        predictions: [PersonalSuggestionPrediction(tagID: tagID, score: 0.75)]
                    ),
                ],
                skippedCount: 1
            )
        )
        let cache = FakeSelectedAssetEmbeddingCache()
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            selectedAssetEmbeddingCache: cache,
            appPersonalSampleSuggester: suggester
        )
        await model.start()

        await model.generateAppPersonalSampleSuggestions()

        let requested = await suggester.requestedCandidates()
        XCTAssertEqual(requested, candidates)
        XCTAssertEqual(review.activatedPersonalCapability, capability)
        XCTAssertEqual(review.personalSuggestionReplacements.count, 2)
        XCTAssertEqual(
            model.notice,
            .personalSampleSuggestionsCompleted(checked: 3, suggested: 2, skipped: 1)
        )
        XCTAssertEqual(
            model.personalLibrarySuggestionState,
            .completed(checked: 3, suggested: 2, skipped: 1)
        )
        XCTAssertTrue(model.supportsAppPersonalSampleSuggestions)
        XCTAssertTrue(model.usesAppPersonalSampleSuggestionsPath)
    }

    func testAppPersonalTagLibrarySuggestionsWritesTopHitsWithPersonalOriginPath() async {
        let sourceID = UUID()
        let tagID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
        let candidates = (0..<5).map { index in
            PersonalSuggestionCandidate(
                assetID: UUID(),
                contentRevision: index + 1
            )
        }
        let assets = candidates.map {
            Self.makeAsset(sourceID: sourceID, assetID: $0.assetID, fileName: "\($0.assetID.uuidString).png")
        }
        let capability = PersonalModelSuggestionCapability(
            target: PersonalModelSuggestionTarget(
                catalogScopeID: "catalog-fixture",
                bundleID: AppPersonalSuggestionCapabilityMapper.bundleID,
                bundleRevision: String(repeating: "a", count: 64),
                provider: "dinov2",
                modelID: "facebook/dinov2-small",
                modelRevision: "fixture",
                preprocessingRevision: "fixture",
                elementCount: 1,
                labelVocabularyRevision: String(repeating: "b", count: 64),
                weightsSHA256: String(repeating: "c", count: 64),
                policyRevision: AppPersonalSuggestionCapabilityMapper.policyRevision
            ),
            tagIDs: [tagID]
        )
        let hits = [
            AppPersonalTagLibrarySuggestionHit(candidate: candidates[0], score: 3.0),
            AppPersonalTagLibrarySuggestionHit(candidate: candidates[1], score: 2.0),
        ]
        let overview = SuggestionTagOverview(
            id: tagID,
            displayName: "板栗",
            acceptedSampleCount: 4,
            rejectedSampleCount: 0,
            pendingSuggestionCount: 0,
            taskStatus: .ready,
            checkedCount: 0,
            totalCount: nil,
            skippedCount: 0,
            missingPositiveCount: 0,
            missingNegativeCount: 2,
            canGenerate: false,
            canUpdate: false,
            canGeneratePersonalModel: true,
            canReview: false,
            canPause: false,
            canResume: false,
            canCancel: false,
            activeJobID: nil
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: assets,
            tags: [TagListItem(id: tagID, displayName: "板栗", state: .active)],
            initialItems: assets,
            startsConnected: true,
            previewData: Data("tag-library-preview".utf8)
        )
        let review = FakePersonalizationReviewPort(
            overviews: [overview],
            personalCandidates: candidates
        )
        let suggester = FakeAppPersonalTagLibrarySuggester(
            batch: AppPersonalTagLibrarySuggestionBatch(
                tagID: tagID,
                capability: capability,
                hits: hits,
                checkedCount: candidates.count,
                aboveThresholdCount: 3,
                skippedCount: 1
            )
        )
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            selectedAssetEmbeddingCache: FakeSelectedAssetEmbeddingCache(),
            appPersonalSampleSuggester: FakeAppPersonalSampleSuggester(
                batch: AppPersonalSampleSuggestionBatch(
                    capability: capability,
                    results: [],
                    skippedCount: 0
                )
            ),
            appPersonalTagLibrarySuggester: suggester
        )
        await model.start()
        await model.refreshReviewState()

        XCTAssertTrue(model.canGenerateAppPersonalTagLibrarySuggestions(for: overview))
        model.requestEnqueueSuggestions(
            tagID: tagID,
            displayName: "板栗",
            mode: .generate,
            method: .personalModel
        )
        let confirmed = await model.confirmPendingSuggestionEnqueue()

        XCTAssertTrue(confirmed)
        let requested = await suggester.requestedTagIDs()
        XCTAssertEqual(requested, [tagID])
        XCTAssertEqual(review.activatedPersonalCapability, capability)
        XCTAssertEqual(review.personalTagLibraryReplacements.count, 1)
        XCTAssertEqual(review.personalTagLibraryReplacements[0].hits, hits)
        XCTAssertEqual(
            model.notice,
            .personalTagLibrarySuggestionsCompleted(
                tagName: "板栗",
                candidates: candidates.count,
                aboveThreshold: 3,
                inserted: hits.count,
                skipped: 1
            )
        )

        let adamWReview = FakePersonalizationReviewPort(
            overviews: [overview],
            personalCandidates: candidates
        )
        let adamWModel = LibraryWorkspaceModel(
            service: service,
            review: adamWReview,
            selectedAssetEmbeddingCache: FakeSelectedAssetEmbeddingCache(),
            appPersonalSampleSuggester: FakeAppPersonalSampleSuggester(
                batch: AppPersonalSampleSuggestionBatch(
                    capability: capability,
                    results: [],
                    skippedCount: 0
                )
            ),
            appPersonalAdamWTagLibrarySuggester: suggester
        )
        await adamWModel.start()
        await adamWModel.refreshReviewState()

        adamWModel.requestEnqueueSuggestions(
            tagID: tagID,
            displayName: "板栗",
            mode: .generate,
            method: .personalAdamW
        )
        let adamWConfirmed = await adamWModel.confirmPendingSuggestionEnqueue()

        XCTAssertTrue(adamWConfirmed)
        XCTAssertEqual(
            adamWModel.notice,
            .personalAdamWTagLibrarySuggestionsCompleted(
                tagName: "板栗",
                candidates: candidates.count,
                aboveThreshold: 3,
                inserted: hits.count,
                skipped: 1
            )
        )
    }

    func testAppPersonalSampleSuggestionsPrefersCurrentSelectionUpToOneHundred() async {
        let sourceID = UUID()
        let tagID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let assets = (0..<5).map { index in
            Self.makeAsset(sourceID: sourceID, fileName: "selected-\(index).png")
        }
        let libraryCandidates = [
            PersonalSuggestionCandidate(
                assetID: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!,
                contentRevision: 9
            ),
        ]
        let capability = PersonalModelSuggestionCapability(
            target: PersonalModelSuggestionTarget(
                catalogScopeID: "catalog-fixture",
                bundleID: AppPersonalSuggestionCapabilityMapper.bundleID,
                bundleRevision: String(repeating: "d", count: 64),
                provider: "dinov2",
                modelID: "facebook/dinov2-small",
                modelRevision: "fixture",
                preprocessingRevision: "fixture",
                elementCount: 1,
                labelVocabularyRevision: String(repeating: "e", count: 64),
                weightsSHA256: String(repeating: "f", count: 64),
                policyRevision: AppPersonalSuggestionCapabilityMapper.policyRevision
            ),
            tagIDs: [tagID]
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: assets,
            tags: [TagListItem(id: tagID, displayName: "人像", state: .active)],
            initialItems: assets,
            startsConnected: true,
            previewData: Data("selected-preview".utf8)
        )
        let review = FakePersonalizationReviewPort(personalCandidates: libraryCandidates)
        let suggester = FakeAppPersonalSampleSuggester(
            batch: AppPersonalSampleSuggestionBatch(
                capability: capability,
                results: assets.prefix(2).map {
                    AppPersonalSampleSuggestionAssetResult(
                        candidate: PersonalSuggestionCandidate(
                            assetID: $0.assetID,
                            contentRevision: $0.contentRevision
                        ),
                        predictions: [PersonalSuggestionPrediction(tagID: tagID, score: 0.5)]
                    )
                },
                skippedCount: 0
            )
        )
        let cache = FakeSelectedAssetEmbeddingCache()
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            selectedAssetEmbeddingCache: cache,
            appPersonalSampleSuggester: suggester
        )
        await model.start()
        await model.selectAssets(Set(assets.prefix(2).map(\.assetID)))

        await model.generateAppPersonalSampleSuggestions()

        let requested = await suggester.requestedCandidates()
        XCTAssertEqual(
            requested.map(\.assetID),
            assets.prefix(2).map(\.assetID)
        )
        XCTAssertEqual(review.personalSuggestionReplacements.count, 2)
        XCTAssertNotEqual(
            requested.map(\.assetID),
            libraryCandidates.map(\.assetID)
        )
    }

    func testExplicitSelectedAssetEmbeddingCacheReadsOnlyTheCurrentPreview() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(
            sourceID: sourceID,
            fileName: "selected-cache.png"
        )
        let tag = TagListItem(id: UUID(), displayName: "旅行", state: .active)
        let previewData = Data("program-generated-preview".utf8)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            tags: [tag],
            initialItems: [asset],
            startsConnected: true,
            previewData: previewData
        )
        let cache = FakeSelectedAssetEmbeddingCache()
        let model = LibraryWorkspaceModel(
            service: service,
            selectedAssetEmbeddingCache: cache
        )
        await model.start()
        await model.selectAsset(asset.assetID)

        await model.cacheSelectedAssetEmbedding()

        let requests = await cache.requests()
        XCTAssertEqual(
            requests,
            [
                SelectedAssetEmbeddingCacheRequest(
                    assetID: asset.assetID,
                    contentRevision: asset.contentRevision,
                    imageData: previewData
                ),
            ]
        )
        XCTAssertEqual(service.previewLoadCallCount, 1)
        XCTAssertEqual(model.notice, .selectedAssetEmbeddingCached)
        XCTAssertFalse(model.isCachingSelectedAssetEmbedding)
        XCTAssertEqual(model.items.map(\.assetID), [asset.assetID])
        XCTAssertEqual(model.tags.map(\.id), [tag.id])
        XCTAssertEqual(service.mutateTagCallCount, 0)
    }

    func testUnavailableSelectedAssetModelFailsBeforePreviewRead() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "disabled-model.png")
        let tag = TagListItem(id: UUID(), displayName: "旅行", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            tags: [tag],
            initialItems: [asset],
            startsConnected: true
        )
        let cache = FakeSelectedAssetEmbeddingCache(
            failure: AppSelectedAssetEmbeddingCacheError.modelUnavailable
        )
        let model = LibraryWorkspaceModel(
            service: service,
            selectedAssetEmbeddingCache: cache
        )
        await model.start()
        await model.selectAsset(asset.assetID)

        await model.cacheSelectedAssetEmbedding()

        XCTAssertEqual(service.previewLoadCallCount, 0)
        let requests = await cache.requests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(model.notice, .selectedAssetEmbeddingModelUnavailable)
        XCTAssertFalse(model.isCachingSelectedAssetEmbedding)
        XCTAssertEqual(model.items.map(\.assetID), [asset.assetID])
        XCTAssertEqual(model.tags.map(\.id), [tag.id])
        XCTAssertEqual(service.mutateTagCallCount, 0)
    }

    func testSelectedAssetCloudOnlyPreviewFailsWithoutChangingBrowsingOrTags() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "cloud-only.png")
        let tag = TagListItem(id: UUID(), displayName: "旅行", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .photos,
                displayName: "Apple Photos",
                state: .active
            ),
            reconciledItems: [asset],
            tags: [tag],
            initialItems: [asset],
            startsConnected: true,
            previewError: .cloudOnly
        )
        let cache = FakeSelectedAssetEmbeddingCache()
        let model = LibraryWorkspaceModel(
            service: service,
            selectedAssetEmbeddingCache: cache
        )
        await model.start()
        await model.selectAsset(asset.assetID)

        await model.cacheSelectedAssetEmbedding()

        XCTAssertEqual(service.previewLoadCallCount, 1)
        let requests = await cache.requests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(model.notice, .selectedAssetEmbeddingPreviewUnavailable)
        XCTAssertFalse(model.isCachingSelectedAssetEmbedding)
        XCTAssertEqual(model.items.map(\.assetID), [asset.assetID])
        XCTAssertEqual(model.tags.map(\.id), [tag.id])
        XCTAssertEqual(service.mutateTagCallCount, 0)
    }

    func testSelectedAssetEmbeddingCacheActionAllowsMultiSelectionBatch() async {
        let sourceID = UUID()
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.png")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "second.png")
        let previewData = Data("program-generated-preview".utf8)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [first, second],
            initialItems: [first, second],
            startsConnected: true,
            previewData: previewData
        )
        let cache = FakeSelectedAssetEmbeddingCache()
        let model = LibraryWorkspaceModel(
            service: service,
            selectedAssetEmbeddingCache: cache
        )
        await model.start()

        XCTAssertFalse(model.canCacheSelectedAssetEmbedding)
        await model.selectAsset(first.assetID)
        XCTAssertTrue(model.canCacheSelectedAssetEmbedding)
        await model.selectAsset(second.assetID, additive: true)
        XCTAssertTrue(model.canCacheSelectedAssetEmbedding)

        await model.cacheSelectedAssetEmbedding()

        let requests = await cache.requests()
        XCTAssertEqual(
            requests.map(\.assetID),
            [first.assetID, second.assetID]
        )
        XCTAssertEqual(service.previewLoadCallCount, 2)
        XCTAssertEqual(
            model.notice,
            .selectedAssetEmbeddingBatchCompleted(
                prepared: 2,
                skipped: 0,
                cloudOnly: 0,
                failed: 0
            )
        )
        XCTAssertFalse(model.isCachingSelectedAssetEmbedding)
        XCTAssertEqual(service.mutateTagCallCount, 0)
    }

    func testSelectedAssetEmbeddingBatchSkipsIdentityMatchedCacheHitsWithoutRereadingPreview() async {
        let sourceID = UUID()
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.png")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "second.png")
        let previewData = Data("program-generated-preview".utf8)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [first, second],
            initialItems: [first, second],
            startsConnected: true,
            previewData: previewData
        )
        let cache = FakeSelectedAssetEmbeddingCache()
        let model = LibraryWorkspaceModel(
            service: service,
            selectedAssetEmbeddingCache: cache
        )
        await model.start()
        await model.selectAsset(first.assetID)
        await model.cacheSelectedAssetEmbedding()
        XCTAssertEqual(service.previewLoadCallCount, 1)

        await model.selectAsset(second.assetID, additive: true)
        await model.cacheSelectedAssetEmbedding()

        let requests = await cache.requests()
        XCTAssertEqual(requests.map(\.assetID), [first.assetID, second.assetID])
        XCTAssertEqual(service.previewLoadCallCount, 2)
        XCTAssertEqual(
            model.notice,
            .selectedAssetEmbeddingBatchCompleted(
                prepared: 1,
                skipped: 1,
                cloudOnly: 0,
                failed: 0
            )
        )
    }

    func testPersonalRebuildWithCloudOnlySampleFailsClosedBeforePublish() async {
        let sourceID = UUID()
        let tagID = UUID(uuidString: "2C000000-0000-4000-8000-000000000001")!
        let assetIDs = (1 ... 4).map { index in
            UUID(uuidString: String(format: "2D000000-0000-4000-8000-%012d", index))!
        }
        let tag = TagListItem(id: tagID, displayName: "旅行", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .photos,
                displayName: "Apple Photos",
                state: .active
            ),
            reconciledItems: [],
            tags: [tag],
            startsConnected: true,
            previewError: .cloudOnly
        )
        let review = FakePersonalizationReviewPort(
            trainingSnapshot: PersonalTrainingSnapshot(
                catalogScopeID: "catalog-fixture",
                personalTagIDs: [tagID],
                decisions: Self.makePersonalTrainingDecisions(
                    tagID: tagID,
                    assetIDs: assetIDs
                )
            )
        )
        let client = FakeLocalModelSuggestionClient(result: .success([]))
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )
        await model.start()

        await model.rebuildPersonalModel()

        XCTAssertEqual(client.personalCapabilityCallCount, 1)
        XCTAssertEqual(client.embeddingCallCount, 0)
        XCTAssertEqual(client.rebuildCallCount, 0)
        XCTAssertEqual(model.notice, .personalModelRebuildPreviewUnavailable)
        XCTAssertFalse(model.isRebuildingPersonalModel)
    }

    func testUnavailablePersonalRebuildServiceLeavesExistingAppFlowUntouched() async {
        let sourceID = UUID()
        let tagID = UUID(uuidString: "2C000000-0000-4000-8000-000000000001")!
        let assetIDs = (1 ... 4).map { index in
            UUID(uuidString: String(format: "2D000000-0000-4000-8000-%012d", index))!
        }
        let tag = TagListItem(id: tagID, displayName: "旅行", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [],
            tags: [tag],
            startsConnected: true,
            previewData: Data("training-preview".utf8)
        )
        let review = FakePersonalizationReviewPort(
            trainingSnapshot: PersonalTrainingSnapshot(
                catalogScopeID: "catalog-fixture",
                personalTagIDs: [tagID],
                decisions: Self.makePersonalTrainingDecisions(
                    tagID: tagID,
                    assetIDs: assetIDs
                )
            )
        )
        let encoder = PersonalTrainingEncoderIdentity(
            provider: "dinov2",
            modelID: "facebook/dinov2-small",
            modelRevision: "model-v1",
            preprocessingRevision: "preprocessing-v1",
            elementCount: 2
        )
        let client = FakeLocalModelSuggestionClient(
            result: .success([]),
            embeddingResult: .success(
                PersonalTrainingEmbedding(encoder: encoder, values: [0.25, -0.5])
            ),
            rebuildResult: .failure(
                .rejected(
                    statusCode: 503,
                    code: "personal_rebuild_unavailable"
                )
            )
        )
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )
        await model.start()

        await model.rebuildPersonalModel()

        XCTAssertEqual(client.rebuildCallCount, 1)
        XCTAssertEqual(client.callCount, 0)
        XCTAssertEqual(model.notice, .personalModelRebuildServiceUnavailable)
        XCTAssertFalse(model.isRebuildingPersonalModel)
    }

    func testPersonalSuggestionResponseWithStaleBundleFailsClosed() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "stale-personal-bundle.jpg")
        let tag = TagListItem(id: UUID(), displayName: "旅行", state: .active)
        let capability = Self.makePersonalCapability(tagIDs: [tag.id])
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            tags: [tag],
            initialItems: [asset],
            startsConnected: true,
            previewData: Data("personal-preview".utf8)
        )
        let client = FakeLocalModelSuggestionClient(
            result: .success([
                Self.makePersonalSuggestion(
                    tagID: tag.id,
                    bundleRevision: "stale-bundle"
                ),
            ]),
            personalCapability: .available(capability)
        )
        let model = LibraryWorkspaceModel(
            service: service,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )

        await model.start()
        await model.selectAsset(asset.assetID)
        await model.requestPersonalModelSuggestions()

        XCTAssertEqual(model.localModelSuggestionState, .failed(assetID: asset.assetID))
        XCTAssertEqual(client.callCount, 1)
        XCTAssertEqual(service.mutateTagCallCount, 0)
    }

    func testPersonalCapabilityWithUnknownTagFailsClosedBeforeInference() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "unknown-tag.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            previewData: Data("must-not-load".utf8)
        )
        let client = FakeLocalModelSuggestionClient(
            result: .success([]),
            personalCapability: .available(
                Self.makePersonalCapability(tagIDs: [UUID()])
            )
        )
        let model = LibraryWorkspaceModel(
            service: service,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )

        await model.start()
        await model.selectAsset(asset.assetID)
        await model.requestPersonalModelSuggestions()

        XCTAssertEqual(model.localModelSuggestionState, .failed(assetID: asset.assetID))
        XCTAssertEqual(client.callCount, 0)
        XCTAssertEqual(service.previewLoadCallCount, 0)
        XCTAssertEqual(service.mutateTagCallCount, 0)
    }

    func testUnavailablePersonalBundleDoesNotFallBackToStandardSuggestions() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "no-personal-bundle.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            previewData: Data("must-not-load".utf8)
        )
        let client = FakeLocalModelSuggestionClient(result: .success([]))
        let model = LibraryWorkspaceModel(
            service: service,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )

        await model.start()
        await model.selectAsset(asset.assetID)
        await model.requestPersonalModelSuggestions()

        XCTAssertEqual(
            model.localModelSuggestionState,
            .personalUnavailable(assetID: asset.assetID)
        )
        XCTAssertEqual(model.localModelSuggestionTrack, .personal)
        XCTAssertEqual(client.callCount, 0)
        XCTAssertEqual(service.previewLoadCallCount, 0)
    }

    func testPersonalBundleFromAnotherCatalogFailsClosedBeforeInference() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "other-catalog.jpg")
        let tag = TagListItem(id: UUID(), displayName: "旅行", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            tags: [tag],
            initialItems: [asset],
            startsConnected: true,
            previewData: Data("must-not-load".utf8)
        )
        let client = FakeLocalModelSuggestionClient(
            result: .success([]),
            personalCapability: .available(
                Self.makePersonalCapability(
                    tagIDs: [tag.id],
                    catalogScopeID: "another-catalog"
                )
            )
        )
        let model = LibraryWorkspaceModel(
            service: service,
            localModelSuggestions: Self.makeStandardRuntime(client: client)
        )

        await model.start()
        await model.selectAsset(asset.assetID)
        await model.requestPersonalModelSuggestions()

        XCTAssertEqual(model.localModelSuggestionState, .failed(assetID: asset.assetID))
        XCTAssertEqual(client.callCount, 0)
        XCTAssertEqual(service.previewLoadCallCount, 0)
        XCTAssertEqual(service.mutateTagCallCount, 0)
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

    func testRescanSelectedPhotosSourceQueuesIncrementalSync() async {
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
        await waitForCatalogScanToFinish(model)
        let syncCountAfterSelect = service.photosSyncCallCount
        await model.rescan()
        await waitForCatalogScanToFinish(model)

        // start() enqueues one quiet sync; selectSource must not enqueue another.
        XCTAssertEqual(syncCountAfterSelect, 1)
        XCTAssertEqual(service.photosSyncCallCount, 2)
        XCTAssertEqual(service.lastPhotosSyncSourceID, sourceID)
        XCTAssertEqual(service.photosConnectCallCount, 0)
    }

    func testLatestSidebarNavigationWinsWhenEarlierSourceTaskStartsLate() async {
        let folderSourceID = UUID()
        let photosSourceID = UUID()
        let folderAsset = Self.makeAsset(
            sourceID: folderSourceID,
            fileName: "folder.jpg"
        )
        let photosAsset = Self.makeAsset(
            sourceID: photosSourceID,
            fileName: "photos.heic"
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: photosSourceID,
                kind: .photos,
                displayName: "Apple Photos",
                state: .active
            ),
            reconciledItems: [folderAsset, photosAsset],
            initialItems: [folderAsset, photosAsset],
            startsConnected: true,
            photosLibrarySupportedImageCount: 1,
            photosCatalogAssetCount: 1,
            sourceIsReconcileClean: true,
            hasPendingCatalogReconcileJobs: false
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        let staleRequest = model.beginBrowsingNavigation()
        let latestRequest = model.beginBrowsingNavigation()

        await model.navigate(
            to: .source(photosSourceID),
            requestID: latestRequest
        )
        let fetchCountAfterLatestNavigation = service.assetPageFetchCallCount
        await model.navigate(
            to: .source(folderSourceID),
            requestID: staleRequest
        )

        XCTAssertEqual(model.items.map(\.assetID), [photosAsset.assetID])
        XCTAssertEqual(
            service.assetPageFetchCallCount,
            fetchCountAfterLatestNavigation,
            "a stale sidebar task must not issue another source query"
        )
    }

    func testPhotosNavigationPublishesSourceTitleAndExplicitSelectionCount() async {
        let photosSourceID = UUID()
        let photosAsset = Self.makeAsset(
            sourceID: photosSourceID,
            fileName: "photos.heic"
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: photosSourceID,
                kind: .photos,
                displayName: "Apple Photos",
                state: .active
            ),
            reconciledItems: [photosAsset],
            initialItems: [photosAsset],
            startsConnected: true,
            photosLibrarySupportedImageCount: 1,
            photosCatalogAssetCount: 1,
            sourceIsReconcileClean: true,
            hasPendingCatalogReconcileJobs: false
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        let requestID = model.beginBrowsingNavigation()
        await model.navigate(to: .source(photosSourceID), requestID: requestID)
        await model.selectAsset(photosAsset.assetID)

        XCTAssertEqual(model.browsingTitle, "Apple Photos")
        XCTAssertEqual(model.selectionSummaryTitle, "已选择 1 张照片")
    }

    func testStartupRequestsFullRepairWhenCatalogIsIncomplete() async {
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
            startsConnected: true,
            photosLibrarySupportedImageCount: 120,
            photosCatalogAssetCount: 40
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await waitForCatalogScanToFinish(model)
        let repairCountAfterStart = service.photosFullRepairCallCount
        await model.selectSource(sourceID)

        XCTAssertEqual(repairCountAfterStart, 1)
        XCTAssertEqual(service.photosFullRepairCallCount, 1)
        XCTAssertEqual(service.photosSyncCallCount, 0)
    }

    func testStartupSkipsPhotosSyncWhenSourceIsReconcileClean() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "cached.heic")
        let source = LibrarySourceSummary(
            id: sourceID,
            kind: .photos,
            displayName: "Apple Photos",
            state: .active
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: source,
            reconciledItems: [asset],
            initialItems: [asset],
            startsConnected: true,
            photosLibrarySupportedImageCount: 100,
            photosCatalogAssetCount: 100,
            sourceIsReconcileClean: true,
            hasPendingCatalogReconcileJobs: false
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()

        XCTAssertEqual(model.phase, .content)
        XCTAssertEqual(model.items.map(\.assetID), [asset.assetID])
        XCTAssertFalse(model.isCatalogScanning)
        XCTAssertEqual(service.photosSyncCallCount, 0)
        XCTAssertEqual(service.photosFullRepairCallCount, 0)
        XCTAssertEqual(service.reconcileRunCount, 0)
    }

    func testPhotosScanCompletionReloadsSelectedSourceGrid() async {
        let sourceID = UUID()
        let partial = Self.makeAsset(sourceID: sourceID, fileName: "icloud.heic")
        let complete = [
            partial,
            Self.makeAsset(sourceID: sourceID, fileName: "local-hdd2.heic"),
        ]
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                kind: .photos,
                displayName: "Apple Photos",
                state: .active
            ),
            reconciledItems: complete,
            initialItems: [partial],
            startsConnected: true,
            blocksReconcileRuns: true,
            photosLibrarySupportedImageCount: 2,
            photosCatalogAssetCount: 2
        )
        let model = LibraryWorkspaceModel(
            service: service,
            catalogProgressRefreshInterval: .milliseconds(1)
        )

        await model.start()
        while !service.hasStartedBlockedReconcile {
            await Task.yield()
        }
        await model.selectSource(sourceID)
        XCTAssertEqual(
            model.items.map(\.fileName),
            ["icloud.heic"],
            "after selectSource"
        )

        service.releaseBlockedReconcile()
        for _ in 0 ..< 10_000 {
            if model.items.count == 2 { break }
            await Task.yield()
        }
        XCTAssertEqual(
            model.items.count,
            2,
            "after scan completion, got \(model.items.map(\.fileName))"
        )
        XCTAssertEqual(
            Set(model.items.map(\.fileName)),
            Set(["icloud.heic", "local-hdd2.heic"])
        )
    }

    func testSelectPhotosSourceDoesNotRequeueSync() async {
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
        let syncCountAfterStart = service.photosSyncCallCount
        await model.selectSource(sourceID)
        await model.selectSource(nil)
        await model.selectSource(sourceID)

        XCTAssertTrue(model.selectedSourceIsPhotos)
        XCTAssertEqual(syncCountAfterStart, 1)
        XCTAssertEqual(service.photosSyncCallCount, 1)
        XCTAssertEqual(service.lastPhotosSyncSourceID, sourceID)
        XCTAssertEqual(service.photosConnectCallCount, 0)
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

        await model.requestTagDecision(tagID: tag.id, action: .accept)

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

    func testIncludedAndExcludedTagFiltersUpdateFilterState() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "photo.jpg")
        let family = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let work = TagListItem(id: UUID(), displayName: "Work", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            tags: [family, work]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)

        await model.toggleIncludedTagFilter(family.id, matchMode: .any)
        await model.toggleIncludedTagFilter(work.id, matchMode: .all)
        await model.toggleExcludedTagFilter(work.id)

        XCTAssertTrue(model.isTagFilterIncluded(family.id))
        XCTAssertFalse(model.isTagFilterIncluded(work.id))
        XCTAssertTrue(model.isTagFilterExcluded(work.id))
        XCTAssertEqual(model.tagMatchMode, .all)
        XCTAssertEqual(
            Set(service.lastFilter.tagDecisionFilters.map(\.tagID)),
            Set([family.id])
        )
        XCTAssertEqual(service.lastFilter.excludedTagIDs, [work.id])
    }

    func testSetTagDecisionFilterClearsExcludedStateForSameTag() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "photo.jpg")
        let family = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            tags: [family]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)

        await model.toggleExcludedTagFilter(family.id)
        XCTAssertTrue(model.isTagFilterExcluded(family.id))

        await model.setTagDecisionFilter(tagID: family.id, decision: .accepted)

        XCTAssertTrue(model.isTagFilterIncluded(family.id))
        XCTAssertFalse(model.isTagFilterExcluded(family.id))
        XCTAssertEqual(service.lastFilter.tagDecisionFilters.map(\.tagID), [family.id])
        XCTAssertTrue(service.lastFilter.excludedTagIDs.isEmpty)
    }

    func testUnionAndIntersectionTagFiltersSetMatchMode() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "photo.jpg")
        let family = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let work = TagListItem(id: UUID(), displayName: "Work", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            tags: [family, work]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)

        await model.toggleIncludedTagFilter(family.id, matchMode: .any)
        await model.toggleIncludedTagFilter(work.id, matchMode: .any)
        XCTAssertEqual(model.tagMatchMode, .any)
        XCTAssertEqual(model.selectedTagFilterIDs, Set([family.id, work.id]))

        await model.toggleIncludedTagFilter(family.id, matchMode: .all)
        await model.toggleIncludedTagFilter(work.id, matchMode: .all)
        XCTAssertTrue(model.selectedTagFilterIDs.isEmpty)

        await model.toggleIncludedTagFilter(family.id, matchMode: .all)
        await model.toggleIncludedTagFilter(work.id, matchMode: .all)
        XCTAssertEqual(model.tagMatchMode, .all)
        XCTAssertEqual(model.selectedTagFilterIDs, Set([family.id, work.id]))
    }

    func testFilterToSingleIncludedTagClearsOtherTagFilters() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "photo.jpg")
        let family = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let work = TagListItem(id: UUID(), displayName: "Work", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            tags: [family, work]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)

        await model.toggleIncludedTagFilter(family.id)
        await model.toggleExcludedTagFilter(work.id)
        await model.setTagMatchMode(.all)
        await model.filterToSingleIncludedTag(work.id)

        XCTAssertEqual(model.selectedTagFilterIDs, Set([work.id]))
        XCTAssertTrue(model.excludedTagFilterIDs.isEmpty)
        XCTAssertEqual(model.tagMatchMode, .all)
    }

    func testTagFilterSummaryTextFormatsIncludedExcludedAndMatchMode() {
        let family = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let work = TagListItem(id: UUID(), displayName: "Work", state: .active)
        let vacation = TagListItem(id: UUID(), displayName: "Vacation", state: .active)

        XCTAssertEqual(
            LibraryWorkspaceModel.makeTagFilterSummaryText(
                tags: [family, work, vacation],
                includedTagIDs: Set([family.id, work.id]),
                excludedTagIDs: Set([vacation.id]),
                matchMode: .any
            ),
            "Family 或 Work · 排除 Vacation"
        )
        XCTAssertEqual(
            LibraryWorkspaceModel.makeTagFilterSummaryText(
                tags: [family, work],
                includedTagIDs: Set([family.id, work.id]),
                excludedTagIDs: [],
                matchMode: .all
            ),
            "Family 且 Work"
        )
    }

    func testBulkTagDecisionShowsAppliedNotice() async throws {
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
        await model.selectAsset(second.assetID, additive: true)

        await model.requestTagDecision(tagID: family.id, action: .accept)

        let notice = try XCTUnwrap(model.notice)
        XCTAssertEqual(
            notice,
            .tagBatchMutationApplied(count: 2, tagDisplayName: "Family", action: .accepted)
        )
        XCTAssertTrue(model.canUndoTagMutation)
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

    func testSelectAssetsReplacesExistingSelection() async {
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
        await model.selectAsset(first.assetID)

        await model.selectAssets([second.assetID, third.assetID])

        XCTAssertEqual(model.selectedAssetIDs, Set([second.assetID, third.assetID]))
        XCTAssertEqual(model.selectionAnchorIDForTesting, second.assetID)
    }

    func testSelectAssetsAdditiveUnionsSelection() async {
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
        await model.selectAsset(first.assetID)

        await model.selectAssets([second.assetID, third.assetID], additive: true)

        XCTAssertEqual(model.selectedAssetIDs, Set([first.assetID, second.assetID, third.assetID]))
    }

    func testSelectAssetsEmptySelectionClearsSelection() async {
        let sourceID = UUID()
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [first]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(first.assetID)

        await model.selectAssets([])

        XCTAssertTrue(model.selectedAssetIDs.isEmpty)
        XCTAssertNil(model.selectionAnchorIDForTesting)
    }

    func testSelectAllVisibleAssetsSelectsLoadedItemsOnly() async {
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
        await model.selectAsset(first.assetID)

        await model.selectAllVisibleAssets()

        XCTAssertEqual(
            model.selectedAssetIDs,
            Set([first.assetID, second.assetID, third.assetID])
        )
        XCTAssertEqual(model.selectionAnchorIDForTesting, first.assetID)
    }

    func testReviewQueueShiftSelectionUsesReviewQueueOrder() async {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let assets = (0 ..< 4).map {
            Self.makeAsset(sourceID: sourceID, fileName: "item-\($0).jpg")
        }
        let queueItems = assets.map {
            ReviewQueueItemProjection(
                assetID: $0.assetID,
                fileName: $0.fileName,
                availability: $0.availability,
                acceptedTagCount: 0,
                rejectedTagCount: 0
            )
        }
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: assets,
            tags: [tag]
        )
        let model = LibraryWorkspaceModel(
            service: service,
            review: FakePersonalizationReviewPort(queueItems: queueItems)
        )

        await model.enterReviewQueue(tagID: tag.id, displayName: tag.displayName)
        await model.selectReviewItem(queueItems[1].id)
        await model.selectAsset(assets[3].assetID, extendRange: true)

        XCTAssertEqual(
            model.selectedAssetIDs,
            Set(assets[1 ... 3].map(\.assetID))
        )
        XCTAssertEqual(model.selectionAnchorIDForTesting, assets[1].assetID)
        XCTAssertNil(model.selectedReviewItemID)
    }

    func testSelectAssetsWithoutInspectorRefreshKeepsPriorInspectorAndSkipsFetches() async {
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
        await model.selectAsset(first.assetID)
        let fetchesAfterSelect = service.inspectorDetailFetchCallCount
        let aggregatesAfterSelect = service.selectionAggregateCallCount

        await model.selectAssets(
            [second.assetID, third.assetID],
            shouldRefreshInspector: false
        )

        XCTAssertEqual(model.selectedAssetIDs, Set([second.assetID, third.assetID]))
        XCTAssertEqual(model.inspectorDetail?.assetID, first.assetID)
        XCTAssertEqual(service.inspectorDetailFetchCallCount, fetchesAfterSelect)
        XCTAssertEqual(service.selectionAggregateCallCount, aggregatesAfterSelect)
    }

    func testStaleInspectorRefreshDoesNotOverwriteNewerSelection() async {
        let sourceID = UUID()
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "second.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [first, second],
            blocksInspectorDetailFetches: 1
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)

        let staleSelect = Task {
            await model.selectAsset(first.assetID)
        }
        for _ in 0 ..< 10_000 where !service.hasStartedBlockedInspectorDetailFetch {
            await Task.yield()
        }
        XCTAssertTrue(service.hasStartedBlockedInspectorDetailFetch)

        await model.selectAsset(second.assetID)
        XCTAssertEqual(model.inspectorDetail?.assetID, second.assetID)

        service.releaseBlockedInspectorDetailFetch()
        await staleSelect.value

        XCTAssertEqual(model.selectedAssetIDs, [second.assetID])
        XCTAssertEqual(
            model.inspectorDetail?.assetID,
            second.assetID,
            "stale refresh for first must not overwrite newer selection"
        )
    }

    func testMarqueeSelectionLogicResolvesAdditiveSelection() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        XCTAssertEqual(
            LibraryGridMarqueeSelectionLogic.resolvedSelection(
                baseSelection: [first],
                hitIDs: [second, third],
                additive: true
            ),
            Set([first, second, third])
        )
        XCTAssertEqual(
            LibraryGridMarqueeSelectionLogic.resolvedSelection(
                baseSelection: [first],
                hitIDs: [second],
                additive: false
            ),
            Set([second])
        )
    }

    func testMarqueeSelectionLogicIntersectingRects() {
        let first = UUID()
        let second = UUID()
        let frames = [
            first: CGRect(x: 0, y: 0, width: 100, height: 100),
            second: CGRect(x: 108, y: 0, width: 100, height: 100),
        ]

        XCTAssertEqual(
            LibraryGridMarqueeSelectionLogic.assetIDsIntersecting(
                CGRect(x: 20, y: 20, width: 10, height: 10),
                cellFrames: frames
            ),
            Set([first])
        )
        XCTAssertEqual(
            LibraryGridMarqueeSelectionLogic.assetIDsIntersecting(
                CGRect(x: 90, y: 0, width: 30, height: 100),
                cellFrames: frames
            ),
            Set([first, second])
        )
        XCTAssertTrue(
            LibraryGridMarqueeSelectionLogic.assetIDsIntersecting(
                CGRect(x: 104, y: 20, width: 2, height: 2),
                cellFrames: frames
            ).isEmpty
        )
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

    func testBulkNewTagRequestAppliesImmediatelyToAllSelectedAssets() async throws {
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
        await model.selectAsset(first.assetID)
        await model.selectAsset(second.assetID, additive: true)

        await model.requestCreateAndAcceptTag(named: "  Print  ")

        XCTAssertEqual(service.createTagAndAcceptCallCount, 1)
        XCTAssertEqual(service.lastCreateTagAssetIDs, Set([first.assetID, second.assetID]))
        XCTAssertEqual(model.tags.map(\.displayName), ["Print"])
    }

    func testSingleSelectionNewTagRequestAppliesImmediately() async {
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
        await model.selectAsset(asset.assetID)

        await model.requestCreateAndAcceptTag(named: "  Print  ")

        XCTAssertEqual(service.createTagAndAcceptCallCount, 1)
        XCTAssertEqual(model.tags.map(\.displayName), ["Print"])
    }

    func testCreatingTagKeepsCommittedSelectionVisibleWhenInspectorRefreshFails() async throws {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            inspectorDetailFails: true
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(asset.assetID)

        await model.requestCreateAndAcceptTag(named: "Print")

        let createdTag = try XCTUnwrap(model.tags.first)
        XCTAssertEqual(service.decidedAssetIDs(tagID: createdTag.id), [asset.assetID])
        XCTAssertEqual(model.selectedAssetIDs, [asset.assetID])
        XCTAssertEqual(
            model.inspectorTags,
            [
                LibraryInspectorTagPresentation(
                    id: createdTag.id,
                    displayName: "Print",
                    decision: .accepted
                ),
            ]
        )
    }

    func testCreatingTagClassifiesPostCommitInspectorRefreshFailure() async throws {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            inspectorDetailFails: true
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(asset.assetID)

        await model.requestCreateAndAcceptTag(named: "Print")

        let notice = try XCTUnwrap(model.notice)
        XCTAssertEqual(
            LibraryWorkspaceView.noticeText(notice),
            "标签已保存，但当前选择刷新失败；请重新选择照片后继续。"
        )
        XCTAssertNotEqual(notice, .tagMutationFailed)
    }

    func testReselectingAssetRecoversCommittedTagAfterRefreshFailure() async throws {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            inspectorDetailFailuresAfterTagCreation: 1
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(asset.assetID)

        await model.requestCreateAndAcceptTag(named: "Print")
        XCTAssertEqual(model.notice, .tagSelectionRefreshFailed)

        await model.selectAsset(asset.assetID)

        XCTAssertNil(model.notice)
        let createdTag = try XCTUnwrap(model.tags.first)
        XCTAssertEqual(model.selectedAssetIDs, [asset.assetID])
        XCTAssertEqual(
            model.inspectorTags,
            [
                LibraryInspectorTagPresentation(
                    id: createdTag.id,
                    displayName: "Print",
                    decision: .accepted
                ),
            ]
        )
    }

    func testCreatingTagPersistenceFailurePublishesNoTagOrDecision() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            tagMutationFails: true
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(asset.assetID)

        await model.requestCreateAndAcceptTag(named: "Print")

        XCTAssertEqual(model.notice, .tagMutationFailed)
        XCTAssertTrue(model.tags.isEmpty)
        XCTAssertTrue(model.inspectorTags.isEmpty)
        XCTAssertFalse(model.canUndoTagMutation)
        XCTAssertEqual(model.selectedAssetIDs, [asset.assetID])
    }

    func testBulkTagDecisionRequestAppliesImmediatelyToAllSelectedAssets() async throws {
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
        await model.selectAsset(second.assetID, additive: true)

        await model.requestTagDecision(tagID: family.id, action: .accept)

        XCTAssertEqual(service.mutateTagCallCount, 1)
        XCTAssertEqual(model.inspectorTags.first(where: { $0.id == family.id })?.decision, .accepted)
    }

    func testSuccessfulTagDecisionEnqueuesAutomaticPersonalRebuild() async throws {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "feedback.jpg")
        let family = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            tags: [family]
        )
        let review = FakePersonalizationReviewPort()
        let client = FakeLocalModelSuggestionClient(result: .success([]))
        let model = LibraryWorkspaceModel(
            service: service,
            review: review,
            localModelSuggestions: LocalModelSuggestionRuntime(
                client: client,
                catalogScopeID: "11111111-1111-4111-8111-111111111111"
            )
        )
        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(asset.assetID)

        await model.applyTagDecision(tagID: family.id, action: .accept)

        XCTAssertEqual(review.personalModelRebuildEnqueueCallCount, 1)
        XCTAssertEqual(service.mutateTagCallCount, 1)
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

    func testOpeningSinglePhotoSelectsTheRequestedAssetAndRefreshesInspector() async {
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
        await model.selectAsset(first.assetID)

        await model.openSinglePhotoView(assetID: second.assetID)

        XCTAssertTrue(model.isSinglePhotoPresented)
        XCTAssertEqual(model.selectedAssetIDs, [second.assetID])
        XCTAssertEqual(model.inspectorDetail?.assetID, second.assetID)
    }

    func testSinglePhotoNavigationDescribesCatalogPositionAndBoundaries() async {
        let sourceID = UUID()
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "second.jpg")
        let third = Self.makeAsset(sourceID: sourceID, fileName: "third.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [first, second, third]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.openSinglePhotoView(assetID: first.assetID)

        XCTAssertEqual(
            model.singlePhotoNavigation,
            LibrarySinglePhotoNavigationPresentation(
                fileName: "first.jpg",
                position: 1,
                loadedCount: 3,
                canMovePrevious: false,
                canMoveNext: true
            )
        )

        await model.moveSinglePhotoSelection(by: 1)

        XCTAssertEqual(
            model.singlePhotoNavigation,
            LibrarySinglePhotoNavigationPresentation(
                fileName: "second.jpg",
                position: 2,
                loadedCount: 3,
                canMovePrevious: true,
                canMoveNext: true
            )
        )
        XCTAssertEqual(model.inspectorDetail?.assetID, second.assetID)
    }

    func testSinglePhotoNavigationUsesReviewQueueAndLoadsItsNextPage() async {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let assets = (0 ..< 3).map {
            Self.makeAsset(sourceID: sourceID, fileName: "review-\($0).jpg")
        }
        let queueItems = assets.map {
            ReviewQueueItemProjection(
                assetID: $0.assetID,
                fileName: $0.fileName,
                availability: $0.availability,
                acceptedTagCount: 0,
                rejectedTagCount: 0
            )
        }
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: sourceID,
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: assets,
                tags: [tag]
            ),
            review: FakePersonalizationReviewPort(
                queueItems: queueItems,
                queuePageSize: 2
            )
        )

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.enterReviewQueue(tagID: tag.id, displayName: tag.displayName)
        await model.openSinglePhotoView(assetID: assets[1].assetID)

        XCTAssertEqual(
            model.singlePhotoNavigation,
            LibrarySinglePhotoNavigationPresentation(
                fileName: "review-1.jpg",
                position: 2,
                loadedCount: 2,
                canMovePrevious: true,
                canMoveNext: true
            )
        )

        await model.moveSinglePhotoSelection(by: 1)

        XCTAssertEqual(model.primarySelectedAssetID, assets[2].assetID)
        XCTAssertEqual(model.inspectorDetail?.assetID, assets[2].assetID)
        XCTAssertEqual(
            model.singlePhotoNavigation,
            LibrarySinglePhotoNavigationPresentation(
                fileName: "review-2.jpg",
                position: 3,
                loadedCount: 3,
                canMovePrevious: true,
                canMoveNext: false
            )
        )
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

    func testGridArrowNavigationStartsAtFirstItemWhenNothingIsSelected() async {
        let sourceID = UUID()
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "second.jpg")
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: sourceID,
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: [first, second]
            )
        )
        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        XCTAssertNil(model.primarySelectedAssetID)

        await model.movePrimarySelection(in: .down, columnCount: 3)

        XCTAssertEqual(model.primarySelectedAssetID, first.assetID)
        XCTAssertEqual(model.inspectorDetail?.assetID, first.assetID)
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

    func testPageNavigationMovesByVisiblePageAndClampsAtGridEdges() async {
        let sourceID = UUID()
        let assets = (0 ..< 10).map {
            Self.makeAsset(sourceID: sourceID, fileName: "photo-\($0).jpg")
        }
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: sourceID,
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: assets
            )
        )

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(assets[1].assetID)

        await model.movePrimarySelection(byPage: .down, pageItemCount: 6)
        XCTAssertEqual(model.primarySelectedAssetID, assets[7].assetID)

        await model.movePrimarySelection(byPage: .down, pageItemCount: 6)
        XCTAssertEqual(model.primarySelectedAssetID, assets[9].assetID)

        await model.movePrimarySelection(byPage: .up, pageItemCount: 6)
        XCTAssertEqual(model.primarySelectedAssetID, assets[3].assetID)
    }

    func testPageItemCountUsesAdaptiveColumnWidthAndVisibleHeight() {
        XCTAssertEqual(
            LibraryGridLayout.pageItemCount(
                containerWidth: 430,
                containerHeight: 500,
                density: .standard
            ),
            4
        )
        XCTAssertEqual(
            LibraryGridLayout.pageItemCount(
                containerWidth: 100,
                containerHeight: 100,
                density: .large
            ),
            1
        )
    }

    func testHoverDetailSummarizesIdentitySourceDimensionsSizeAndDates() {
        let item = AssetGridItemProjection(
            assetID: UUID(),
            sourceID: UUID(),
            sourceDisplayName: "家庭相册",
            sourceState: .active,
            relativePath: "2026/海边.jpg",
            fileName: "海边.jpg",
            mediaType: "public.jpeg",
            mediaCreatedAtMs: 1_752_854_400_000,
            mediaModifiedAtMs: 1_752_940_800_000,
            width: 4_032,
            height: 3_024,
            availability: .available,
            contentRevision: 1,
            acceptedTagCount: 2,
            rejectedTagCount: 1
        )

        let text = LibraryAssetDetailText.hoverText(item)

        XCTAssertTrue(text.contains("海边.jpg"))
        XCTAssertTrue(text.contains("家庭相册"))
        XCTAssertTrue(text.contains("4,032 × 3,024"))
        XCTAssertTrue(text.contains("已确认 2 · 已拒绝 1"))
        XCTAssertTrue(text.contains("拍摄时间"))
        XCTAssertTrue(text.contains("状态：可用"))
    }

    func testReviewHoverDetailKeepsRawSuggestionScoreOutOfUI() {
        let item = ReviewQueueItemProjection(
            assetID: UUID(),
            fileName: "待审核.jpg",
            availability: .available,
            acceptedTagCount: 1,
            rejectedTagCount: 2,
            suggestionOrigin: .standardModel,
            score: 0.987_654
        )

        let text = LibraryAssetDetailText.reviewHoverText(item)

        XCTAssertTrue(text.contains("待审核.jpg"))
        XCTAssertTrue(text.contains("建议来源：标准模型"))
        XCTAssertTrue(text.contains("已确认 1 · 已拒绝 2"))
        XCTAssertFalse(text.contains("0.98"))
        XCTAssertFalse(text.contains("分数"))
    }

    func testSemanticTagGroupingUsesStableMeaningOrderAndSortsWithinGroup() {
        let tags = [
            TagListItem(id: UUID(), displayName: "文档", state: .active),
            TagListItem(id: UUID(), displayName: "宠物", state: .active),
            TagListItem(id: UUID(), displayName: "人像", state: .active),
            TagListItem(id: UUID(), displayName: "生日", state: .active),
            TagListItem(id: UUID(), displayName: "建筑", state: .active),
            TagListItem(id: UUID(), displayName: "美食", state: .active),
            TagListItem(id: UUID(), displayName: "自定义", state: .active),
            TagListItem(id: UUID(), displayName: "风景", state: .active),
        ]

        let groups = LibraryTagSemanticGroup.group(tags)

        XCTAssertEqual(
            groups.map(\.group),
            [.people, .placesAndScenes, .activities, .food, .nature, .documents, .other]
        )
        XCTAssertEqual(groups[1].tags.map(\.displayName), ["风景", "建筑"])
        XCTAssertEqual(groups[6].tags.map(\.displayName), ["自定义"])
    }

    func testPersistedTagGroupSectionsKeepMembershipAndIncludeEmptyGroups() {
        let foodTag = TagListItem(
            id: UUID(),
            displayName: "板栗",
            state: .active,
            groupID: TagGroupSeed.food.id
        )
        let sections = LibraryTagGroupSection.build(
            groups: TagGroupSeed.allCases.map {
                TagGroupListItem(
                    id: $0.id,
                    displayName: $0.displayName,
                    sortOrder: $0.sortOrder,
                    isSystem: true
                )
            },
            tags: [foodTag]
        )
        XCTAssertEqual(sections.count, TagGroupSeed.allCases.count)
        XCTAssertEqual(
            sections.first(where: { $0.group.id == TagGroupSeed.food.id })?.tags.map(\.id),
            [foodTag.id]
        )
        XCTAssertTrue(
            sections.first(where: { $0.group.id == TagGroupSeed.people.id })?.tags.isEmpty == true
        )
    }

    @MainActor
    func testTagGroupCollapsePreferencesPersistToggleState() {
        let suiteName = "ImageAllTests.TagGroupCollapse.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = LibraryTagGroupCollapsePreferences(defaults: defaults)
        let groupID = TagGroupSeed.food.id
        XCTAssertFalse(preferences.isCollapsed(groupID))
        preferences.toggle(groupID)
        XCTAssertTrue(preferences.isCollapsed(groupID))
        let reopened = LibraryTagGroupCollapsePreferences(defaults: defaults)
        XCTAssertTrue(reopened.isCollapsed(groupID))
    }

    @MainActor
    func testMoveTagUpdatesPersistedGroupMembership() async {
        let source = LibrarySourceSummary(id: UUID(), displayName: "图库", state: .active)
        let tag = TagListItem(
            id: UUID(),
            displayName: "食物",
            state: .active,
            groupID: TagGroupSeed.food.id
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: source,
            reconciledItems: [],
            tags: [tag],
            startsConnected: true
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.start()
        XCTAssertEqual(model.tags.first?.groupID, TagGroupSeed.food.id)

        let moved = await model.moveTag(tag.id, toGroupID: TagGroupSeed.other.id)
        XCTAssertTrue(moved)
        XCTAssertEqual(model.tags.first?.groupID, TagGroupSeed.other.id)
    }

    @MainActor
    func testAcceptAndEnqueueMoveTagAppliesOptimisticMembership() async {
        let source = LibrarySourceSummary(id: UUID(), displayName: "图库", state: .active)
        let tag = TagListItem(
            id: UUID(),
            displayName: "食物",
            state: .active,
            groupID: TagGroupSeed.food.id
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: source,
            reconciledItems: [],
            tags: [tag],
            startsConnected: true
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.start()

        XCTAssertTrue(model.acceptAndEnqueueMoveTag(tag.id, toGroupID: TagGroupSeed.other.id))
        XCTAssertEqual(model.tags.first?.groupID, TagGroupSeed.other.id)

        // Allow the enqueued persistence task to settle.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.tags.first?.groupID, TagGroupSeed.other.id)
        XCTAssertNil(model.notice)
    }

    @MainActor
    func testCreateRenameDeleteCustomTagGroupRoundTrip() async {
        let source = LibrarySourceSummary(id: UUID(), displayName: "图库", state: .active)
        let tag = TagListItem(
            id: UUID(),
            displayName: "自定义",
            state: .active,
            groupID: TagGroupSeed.other.id
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: source,
            reconciledItems: [],
            tags: [tag],
            startsConnected: true
        )
        let model = LibraryWorkspaceModel(service: service)
        await model.start()

        let created = await model.createTagGroup(named: "旅行专题")
        XCTAssertTrue(created)
        guard let customID = model.tagGroups.first(where: { $0.displayName == "旅行专题" })?.id else {
            return XCTFail("expected custom tag group")
        }
        let renamed = await model.renameTagGroup(customID, to: "行程专题")
        XCTAssertTrue(renamed)
        XCTAssertEqual(
            model.tagGroups.first(where: { $0.id == customID })?.displayName,
            "行程专题"
        )
        let moved = await model.moveTag(tag.id, toGroupID: customID)
        XCTAssertTrue(moved)
        let deleted = await model.deleteTagGroup(customID)
        XCTAssertTrue(deleted)
        XCTAssertNil(model.tagGroups.first(where: { $0.id == customID }))
        XCTAssertEqual(model.tags.first?.groupID, TagGroupSeed.other.id)

        let renameSystem = await model.renameTagGroup(TagGroupSeed.food.id, to: "不可改")
        XCTAssertFalse(renameSystem)
        XCTAssertEqual(model.notice, .systemTagGroupProtected)
    }

    func testSourceOrderPreferencesPersistManualDragOrderAndAppendNewSources() {
        let suiteName = "ImageAllTests.SourceOrder.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = LibrarySourceSummary(id: UUID(), displayName: "一", state: .active)
        let second = LibrarySourceSummary(id: UUID(), displayName: "二", state: .active)
        let third = LibrarySourceSummary(id: UUID(), displayName: "三", state: .active)
        let later = LibrarySourceSummary(id: UUID(), displayName: "四", state: .active)

        let preferences = LibrarySourceOrderPreferences(defaults: defaults)
        preferences.move(sourceID: third.id, before: first.id, in: [first, second, third])

        let reopened = LibrarySourceOrderPreferences(defaults: defaults)
        XCTAssertEqual(
            reopened.ordered([first, second, third, later]).map(\.id),
            [third.id, first.id, second.id, later.id]
        )
    }

    func testSourceOrderPreferencesMoveListOffsetsToTail() {
        let suiteName = "ImageAllTests.SourceDropTail.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = LibrarySourceSummary(id: UUID(), displayName: "一", state: .active)
        let second = LibrarySourceSummary(id: UUID(), displayName: "二", state: .active)
        let third = LibrarySourceSummary(id: UUID(), displayName: "三", state: .active)
        let preferences = LibrarySourceOrderPreferences(defaults: defaults)

        preferences.move(
            fromOffsets: IndexSet(integer: 0),
            toOffset: 3,
            in: [first, second, third]
        )

        XCTAssertEqual(preferences.ordered([first, second, third]).map(\.id), [second.id, third.id, first.id])
    }

    func testSourceOrderPreferencesMoveListOffsetsToHead() {
        let suiteName = "ImageAllTests.SourceMoveOffsets.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = LibrarySourceSummary(id: UUID(), displayName: "一", state: .active)
        let second = LibrarySourceSummary(id: UUID(), displayName: "二", state: .active)
        let third = LibrarySourceSummary(id: UUID(), displayName: "三", state: .active)
        let preferences = LibrarySourceOrderPreferences(defaults: defaults)

        preferences.move(
            fromOffsets: IndexSet(integer: 2),
            toOffset: 0,
            in: [first, second, third]
        )

        XCTAssertEqual(preferences.ordered([first, second, third]).map(\.id), [third.id, first.id, second.id])
    }

    func testSourceReorderLayoutResolvesHeadGapsAndTailFromRowMidpoints() {
        let rowFrames = [
            CGRect(x: 0, y: 0, width: 180, height: 40),
            CGRect(x: 0, y: 48, width: 180, height: 40),
            CGRect(x: 0, y: 96, width: 180, height: 40),
        ]

        XCTAssertEqual(LibrarySourceReorderLayout.destinationOffset(pointerY: 8, rowFrames: rowFrames), 0)
        XCTAssertEqual(LibrarySourceReorderLayout.destinationOffset(pointerY: 44, rowFrames: rowFrames), 1)
        XCTAssertEqual(LibrarySourceReorderLayout.destinationOffset(pointerY: 92, rowFrames: rowFrames), 2)
        XCTAssertEqual(LibrarySourceReorderLayout.destinationOffset(pointerY: 148, rowFrames: rowFrames), 3)
        XCTAssertEqual(
            LibrarySourceReorderLayout.destinationOffset(
                pointerY: 92,
                rowFrames: [rowFrames[2], rowFrames[0], rowFrames[1]]
            ),
            2
        )
    }

    func testSourceReorderLayoutResolvesMoveFromGestureEndLocation() {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let rowFrames = [
            CGRect(x: 0, y: 227, width: 180, height: 40),
            CGRect(x: 0, y: 275, width: 180, height: 40),
            CGRect(x: 0, y: 323, width: 180, height: 40),
        ]

        XCTAssertEqual(
            LibrarySourceReorderLayout.moveRequest(
                sourceID: firstID,
                localPointerY: 93,
                sourceIDs: [firstID, secondID, thirdID],
                rowFrames: rowFrames
            ),
            LibrarySourceReorderMove(sourceOffset: 0, destinationOffset: 2)
        )
    }

    func testOpeningSelectedOriginalUsesInjectedPreviewOpener() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "original.jpg")
        let opener = FakeLibraryOriginalAssetOpener()
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: sourceID,
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: [asset]
            ),
            originalAssetOpener: opener
        )
        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.selectAsset(asset.assetID)

        await model.openSelectedOriginal()

        XCTAssertEqual(opener.openedAssetIDs, [asset.assetID])
        XCTAssertFalse(model.isOpeningOriginal)
        XCTAssertNil(model.notice)
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

    func testNarrowingWorkspaceCollapsesInspectorBeforeSidebar() {
        var layout = LibraryWorkspaceLayoutState()

        layout.updateWindowWidth(1_100)
        layout.updateWindowWidth(760)

        XCTAssertTrue(layout.isSidebarPresented)
        XCTAssertFalse(layout.isInspectorPresented)
    }

    func testWorkspacePanelsToggleIndependentlyAndManualInspectorRestorePersistsWhileNarrow() {
        var layout = LibraryWorkspaceLayoutState()
        layout.updateWindowWidth(760)

        layout.toggleInspector()
        layout.toggleSidebar()
        layout.updateWindowWidth(740)

        XCTAssertFalse(layout.isSidebarPresented)
        XCTAssertTrue(layout.isInspectorPresented)
    }

    func testCommandPalettePanelActionsDescribeCurrentVisibility() {
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: UUID(),
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: []
            )
        )
        var layout = LibraryWorkspaceLayoutState()

        var commands = model.workspaceCommands(matching: "", layout: layout)
        XCTAssertEqual(commands.first(where: { $0.command == .toggleSidebar })?.title, "隐藏侧栏")
        XCTAssertEqual(commands.first(where: { $0.command == .toggleInspector })?.title, "隐藏检查器")

        layout.toggleSidebar()
        layout.toggleInspector()
        commands = model.workspaceCommands(matching: "", layout: layout)
        XCTAssertEqual(commands.first(where: { $0.command == .toggleSidebar })?.title, "显示侧栏")
        XCTAssertEqual(commands.first(where: { $0.command == .toggleInspector })?.title, "显示检查器")
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
                .toggleSidebar,
                .toggleInspector,
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
        XCTAssertEqual(commands.first(where: { $0.command == .showTag(tag.id) })?.title, "筛选标签：Family")
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

    func testSelectAllReviewRejectionUsesSingleMutationForEveryVisibleAsset() async {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let assets = (0 ..< 3).map {
            Self.makeAsset(sourceID: sourceID, fileName: "item-\($0).jpg")
        }
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
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
        await model.selectAllVisibleAssets()
        await model.applyReviewDecision(action: .reject)

        XCTAssertEqual(service.mutateTagCallCount, 1)
        XCTAssertEqual(
            try service.selectionAggregate(
                tagIDs: [tag.id],
                assetIDs: assets.map(\.assetID)
            ).first?.rejectedCount,
            assets.count
        )
        XCTAssertEqual(model.notice, .reviewMutationApplied(count: 3, tagName: "Family"))
    }

    func testMarqueeStyleReviewSelectionAcceptanceMutatesEverySelectedAsset() async {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let assets = (0 ..< 4).map {
            Self.makeAsset(sourceID: sourceID, fileName: "item-\($0).jpg")
        }
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
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
        let marqueeSelection = Set(assets[1 ... 2].map(\.assetID))

        await model.enterReviewQueue(tagID: tag.id, displayName: tag.displayName)
        await model.selectAssets(marqueeSelection)
        await model.applyReviewDecision(action: .accept)

        XCTAssertEqual(service.mutateTagCallCount, 1)
        XCTAssertEqual(
            try service.selectionAggregate(
                tagIDs: [tag.id],
                assetIDs: Array(marqueeSelection)
            ).first?.acceptedCount,
            marqueeSelection.count
        )
        XCTAssertEqual(model.notice, .reviewMutationApplied(count: 2, tagName: "Family"))
    }

    func testDeferReviewSelectionAdvancesPreviewAndInspectorWithoutReorderingQueue() async {
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

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.enterReviewQueue(tagID: tag.id, displayName: tag.displayName)
        let originalOrder = model.reviewQueueItems.map(\.assetID)
        await model.openSinglePhotoView(assetID: first.assetID)
        await model.deferReviewSelection()

        XCTAssertEqual(service.mutateTagCallCount, 0)
        XCTAssertEqual(model.reviewQueueItems.map(\.assetID), originalOrder)
        XCTAssertEqual(model.selectedAssetIDs, [second.assetID])
        XCTAssertEqual(model.inspectorDetail?.assetID, second.assetID)
        XCTAssertTrue(model.isSinglePhotoPresented)
    }

    func testDeferReviewSelectionAdvancesAcrossOriginsForTheSameAsset() async {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let shared = Self.makeAsset(sourceID: sourceID, fileName: "shared.jpg")
        let next = Self.makeAsset(sourceID: sourceID, fileName: "next.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [shared, next],
            tags: [tag]
        )
        let queueItems = [
            ReviewQueueItemProjection(
                assetID: shared.assetID,
                fileName: shared.fileName,
                availability: shared.availability,
                acceptedTagCount: 0,
                rejectedTagCount: 0,
                suggestionOrigin: .personalAdamW,
                score: 0.9
            ),
            ReviewQueueItemProjection(
                assetID: shared.assetID,
                fileName: shared.fileName,
                availability: shared.availability,
                acceptedTagCount: 0,
                rejectedTagCount: 0,
                suggestionOrigin: .personalModel,
                score: 0.8
            ),
            ReviewQueueItemProjection(
                assetID: shared.assetID,
                fileName: shared.fileName,
                availability: shared.availability,
                acceptedTagCount: 0,
                rejectedTagCount: 0,
                suggestionOrigin: .featurePrint,
                score: 0.7
            ),
            ReviewQueueItemProjection(
                assetID: next.assetID,
                fileName: next.fileName,
                availability: next.availability,
                acceptedTagCount: 0,
                rejectedTagCount: 0,
                suggestionOrigin: .personalAdamW,
                score: 0.6
            ),
        ]
        let model = LibraryWorkspaceModel(
            service: service,
            review: FakePersonalizationReviewPort(queueItems: queueItems)
        )

        await model.enterReviewQueue(tagID: tag.id, displayName: tag.displayName)
        await model.selectReviewItem(queueItems[0].id)
        await model.deferReviewSelection()

        XCTAssertEqual(model.selectedReviewItemID, queueItems[1].id)
        XCTAssertEqual(model.selectedAssetIDs, [shared.assetID])
        XCTAssertEqual(service.mutateTagCallCount, 0)
        XCTAssertEqual(model.reviewQueueItems.map(\.id), queueItems.map(\.id))

        await model.deferReviewSelection()
        XCTAssertEqual(model.selectedReviewItemID, queueItems[2].id)

        await model.deferReviewSelection()
        XCTAssertEqual(model.selectedReviewItemID, queueItems[3].id)
        XCTAssertEqual(model.selectedAssetIDs, [next.assetID])
    }

    func testTrainingWorkspaceRefreshFiltersRunsAndFallsBackSelection() async {
        func run(
            _ id: UUID,
            method: TrainingRunMethod,
            createdAtMs: Int64
        ) -> TrainingRunRecord {
            TrainingRunRecord(
                id: id,
                method: method,
                state: .succeeded,
                createdAtMs: createdAtMs,
                startedAtMs: createdAtMs,
                finishedAtMs: createdAtMs + 1,
                catalogScopeID: "scope",
                jobID: nil,
                sampleSummaryJSON: "{}",
                sampleManifestSHA256: nil,
                configJSON: "{}",
                metricsJSON: "{}",
                artifactKind: "fixture",
                artifactRef: "fixture/\(id.uuidString.lowercased())",
                artifactSHA256: String(repeating: "a", count: 64),
                resultSummaryJSON: #"{"published":true}"#,
                errorCode: nil
            )
        }
        let centroidID = UUID()
        let adamWID = UUID()
        let featureID = UUID()
        let runs = [
            run(centroidID, method: .personalCentroid, createdAtMs: 300),
            run(adamWID, method: .personalAdamW, createdAtMs: 200),
            run(featureID, method: .featureKnn, createdAtMs: 100),
        ]
        let slots = TrainingRunMethod.allCases.map {
            TrainingWorkspaceSlot(
                method: $0,
                isPublished: $0 != .featureKnn,
                publishedRunID: $0 == .personalCentroid ? centroidID : nil,
                artifactRef: nil
            )
        }
        let workspace = FakeTrainingWorkspacePort(runs: runs, slots: slots)
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: UUID(),
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: []
            ),
            trainingWorkspace: workspace
        )

        await model.refreshTrainingWorkspace()

        XCTAssertEqual(model.trainingRuns.map(\.id), [centroidID, adamWID, featureID])
        XCTAssertEqual(model.selectedTrainingRunID, centroidID)
        XCTAssertEqual(model.trainingSlots, slots)

        model.selectTrainingRun(featureID)
        await model.setTrainingRunMethodFilter(.personalAdamW)

        XCTAssertEqual(model.trainingRunMethodFilter, .personalAdamW)
        XCTAssertEqual(model.trainingRuns.map(\.id), [adamWID])
        XCTAssertEqual(model.selectedTrainingRunID, adamWID)
        XCTAssertEqual(
            workspace.requestedMethods,
            [Optional<TrainingRunMethod>.none, .personalAdamW]
        )
    }

    func testTrainingWorkspaceAutomaticRefreshDoesNotAnimateManualRefreshControl() async {
        let workspace = BlockingTrainingWorkspacePort()
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: UUID(),
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: []
            ),
            trainingWorkspace: workspace
        )

        let refresh = Task {
            await model.refreshTrainingWorkspace(presentation: .automatic)
        }
        for _ in 0 ..< 100 where !workspace.didStart {
            await Task.yield()
        }

        XCTAssertTrue(workspace.didStart)
        XCTAssertFalse(
            model.isRefreshingTrainingWorkspace,
            "后台轮询不应让手动刷新按钮在图标和进度环之间频闪"
        )

        workspace.resume()
        await refresh.value
    }

    func testPersonalCentroidTrainingPublishesLiveWorkspaceActivityUntilCompletion() async throws {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "板栗", state: .active)
        let assetIDs = [UUID(), UUID()]
        let snapshot = PersonalTrainingSnapshot(
            catalogScopeID: UUID().uuidString.lowercased(),
            personalTagIDs: [tag.id],
            decisions: assetIDs.map {
                PersonalTrainingDecision(
                    assetID: $0,
                    contentRevision: 1,
                    tagID: tag.id,
                    state: .manualAccepted
                )
            }
        )
        let rebuilder = BlockingAppPersonalModelRebuilder(
            result: AppPersonalLinearHeadIdentity(
                catalogScopeID: snapshot.catalogScopeID,
                decisionSnapshotRevision: String(repeating: "1", count: 64),
                labelVocabularyRevision: String(repeating: "2", count: 64),
                encoderIdentity: AppCoreMLModelIdentity(
                    provider: "dinov2",
                    modelID: "facebook/dinov2-small",
                    modelRevision: "fixture",
                    preprocessingRevision: "fixture",
                    embeddingSemantics: "fixture",
                    postprocessingRevision: "fixture",
                    elementType: "float32",
                    elementCount: 1,
                    sourceModelSHA256: String(repeating: "3", count: 64),
                    artifactSHA256: String(repeating: "4", count: 64),
                    manifestSHA256: String(repeating: "5", count: 64),
                    licenseID: "Apache-2.0",
                    licenseSHA256: String(repeating: "6", count: 64)
                ),
                personalTagIDs: [tag.id],
                weightsSHA256: String(repeating: "7", count: 64)
            )
        )
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: sourceID,
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: [],
                tags: [tag]
            ),
            review: FakePersonalizationReviewPort(trainingSnapshot: snapshot),
            appPersonalModelRebuilder: rebuilder
        )
        await model.start()
        await model.toggleIncludedTagFilter(tag.id)

        let training = Task { await model.rebuildPersonalModel() }
        for _ in 0 ..< 100 where !(await rebuilder.didStart()) {
            await Task.yield()
        }

        let didStart = await rebuilder.didStart()
        XCTAssertTrue(didStart)
        XCTAssertEqual(
            model.trainingWorkspaceActivity,
            TrainingWorkspaceActivity(
                method: .personalCentroid,
                tagNames: ["板栗"],
                scope: .allSources,
                sampleCount: 2,
                phase: .trainingAndPublishing
            )
        )

        await rebuilder.resume()
        await training.value
        XCTAssertNil(model.trainingWorkspaceActivity)
    }

    func testTrainingWorkspaceStartsPersonalModelWithExplicitTagsAndPhotoScope() async throws {
        let sourceID = UUID()
        let hiddenFilterTag = TagListItem(id: UUID(), displayName: "旧筛选", state: .active)
        let requestedTag = TagListItem(id: UUID(), displayName: "板栗", state: .active)
        let hiddenAssetIDs = [UUID(), UUID()]
        let requestedAssetIDs = [UUID(), UUID()]
        let snapshot = PersonalTrainingSnapshot(
            catalogScopeID: UUID().uuidString.lowercased(),
            personalTagIDs: [hiddenFilterTag.id, requestedTag.id],
            decisions: [
                (hiddenFilterTag.id, hiddenAssetIDs[0]),
                (hiddenFilterTag.id, hiddenAssetIDs[1]),
                (requestedTag.id, requestedAssetIDs[0]),
                (requestedTag.id, requestedAssetIDs[1]),
            ].map { tagID, assetID in
                PersonalTrainingDecision(
                    assetID: assetID,
                    contentRevision: 1,
                    tagID: tagID,
                    state: .manualAccepted
                )
            }
        )
        let rebuilder = BlockingAppPersonalModelRebuilder(
            result: AppPersonalLinearHeadIdentity(
                catalogScopeID: snapshot.catalogScopeID,
                decisionSnapshotRevision: String(repeating: "1", count: 64),
                labelVocabularyRevision: String(repeating: "2", count: 64),
                encoderIdentity: AppCoreMLModelIdentity(
                    provider: "dinov2",
                    modelID: "facebook/dinov2-small",
                    modelRevision: "fixture",
                    preprocessingRevision: "fixture",
                    embeddingSemantics: "fixture",
                    postprocessingRevision: "fixture",
                    elementType: "float32",
                    elementCount: 1,
                    sourceModelSHA256: String(repeating: "3", count: 64),
                    artifactSHA256: String(repeating: "4", count: 64),
                    manifestSHA256: String(repeating: "5", count: 64),
                    licenseID: "Apache-2.0",
                    licenseSHA256: String(repeating: "6", count: 64)
                ),
                personalTagIDs: [requestedTag.id],
                weightsSHA256: String(repeating: "7", count: 64)
            )
        )
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: sourceID,
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: [],
                tags: [hiddenFilterTag, requestedTag]
            ),
            review: FakePersonalizationReviewPort(trainingSnapshot: snapshot),
            appPersonalModelRebuilder: rebuilder
        )
        await model.start()
        await model.toggleIncludedTagFilter(hiddenFilterTag.id)

        let training = Task {
            await model.rebuildPersonalModel(
                tagIDs: [requestedTag.id],
                assetIDs: Set(requestedAssetIDs)
            )
        }
        for _ in 0 ..< 100 where !(await rebuilder.didStart()) {
            await Task.yield()
        }

        let didStart = await rebuilder.didStart()
        XCTAssertTrue(didStart)
        XCTAssertEqual(
            model.trainingWorkspaceActivity,
            TrainingWorkspaceActivity(
                method: .personalCentroid,
                tagNames: ["板栗"],
                scope: .selectedAssets(count: 2),
                sampleCount: 2,
                phase: .trainingAndPublishing
            )
        )

        await rebuilder.resume()
        await training.value
    }

    func testTrainingWorkspaceActivityPresentationExplainsMethodTagsScopeAndProgress() {
        let activity = TrainingWorkspaceActivity(
            method: .personalCentroid,
            tagNames: ["板栗"],
            scope: .allSources,
            sampleCount: 2,
            phase: .preparingEmbeddings(completed: 1, total: 2)
        )

        XCTAssertEqual(
            TrainingWorkspaceActivityPresentation.title(activity),
            "快速个人模型正在训练"
        )
        XCTAssertEqual(
            TrainingWorkspaceActivityPresentation.detail(activity),
            "标签：板栗 · 范围：所有来源 · 样本：2 张"
        )
        XCTAssertEqual(
            TrainingWorkspaceActivityPresentation.phase(activity),
            "正在准备本地特征 1 / 2"
        )
    }

    func testTrainingWorkspaceMethodPresentationLeadsWithUserGoals() {
        XCTAssertEqual(
            TrainingWorkspaceMethodPresentation(method: .featureKnn),
            TrainingWorkspaceMethodPresentation(
                method: .featureKnn,
                title: "为标签寻找相似照片",
                shortTitle: "相似照片",
                technicalName: "特征向量近邻",
                detail: "用已确认属于和不属于该标签的照片作参考，找出新的相似照片并送去审核。",
                requirement: "每个标签至少 2 个属于、2 个不属于",
                systemImage: "sparkle.magnifyingglass"
            )
        )
        XCTAssertEqual(
            TrainingWorkspaceMethodPresentation(method: .personalCentroid),
            TrainingWorkspaceMethodPresentation(
                method: .personalCentroid,
                title: "更新快速个人模型",
                shortTitle: "快速个人模型",
                technicalName: "质心模型",
                detail: "快速汇总你确认过的标签样本，适合日常更新。",
                requirement: "每个标签至少 2 个已确认样本",
                systemImage: "brain.head.profile"
            )
        )
        XCTAssertEqual(
            TrainingWorkspaceMethodPresentation(method: .personalAdamW),
            TrainingWorkspaceMethodPresentation(
                method: .personalAdamW,
                title: "训练增强个人模型",
                shortTitle: "增强个人模型",
                technicalName: "AdamW 线性模型",
                detail: "进行更充分的本机训练，适合样本较多时获得更细致的个人结果。",
                requirement: "每个标签至少 2 个已确认样本",
                systemImage: "brain.head.profile.fill"
            )
        )
    }

    func testTrainingWorkspaceLaunchSummaryConfirmsMethodTagsAndPhotoScope() {
        let summary = TrainingWorkspaceLaunchSummary(
            method: .personalCentroid,
            tagNames: ["猫", "板栗"],
            photoScope: .selectedAssets(count: 12)
        )

        XCTAssertEqual(summary.methodText, "快速个人模型（质心模型）")
        XCTAssertEqual(summary.tagText, "板栗、猫")
        XCTAssertEqual(summary.photoScopeText, "当前选择的 12 张照片")
        XCTAssertEqual(summary.requirementText, "每个标签至少 2 个已确认样本")
    }

    func testTrainingWorkspaceJSONPresentationRedactsProtectedLocatorFields() throws {
        let rendered = try XCTUnwrap(
            TrainingWorkspaceJSONPresentation.pretty(
                #"{"scopeKind":"allActiveSources","path":"/protected/example.jpg","nested":{"bookmark":"secret","sampleCount":4}}"#
            )
        )

        XCTAssertTrue(rendered.contains("scopeKind"))
        XCTAssertTrue(rendered.contains("sampleCount"))
        XCTAssertFalse(rendered.contains("/protected/example.jpg"))
        XCTAssertFalse(rendered.lowercased().contains("bookmark"))
        let legacyMetrics = #"{"bestValidationLoss":0.2,"epochs":[{"validationLoss":0.3}]}"#
        XCTAssertTrue(
            try XCTUnwrap(
                TrainingWorkspaceJSONPresentation.metricsSummary(legacyMetrics)
            ).contains("切分未记录")
        )
        XCTAssertFalse(
            try XCTUnwrap(
                TrainingWorkspaceJSONPresentation.prettyMetrics(legacyMetrics)
            ).contains("validationLoss")
        )
        XCTAssertNil(
            TrainingWorkspaceJSONPresentation.safeArtifactReference(
                "/protected/model.json"
            )
        )
        XCTAssertEqual(
            TrainingWorkspaceJSONPresentation.safeArtifactReference(
                "PersonalModels/AdamWHead/v1/objects/model.json"
            ),
            "PersonalModels/AdamWHead/v1/objects/model.json"
        )
    }

    func testTrainingWorkspaceViewRendersSelectedRunDetailWithFixtureData() async {
        let run = TrainingRunRecord(
            id: UUID(),
            method: .personalAdamW,
            state: .succeeded,
            createdAtMs: 100,
            startedAtMs: 101,
            finishedAtMs: 102,
            catalogScopeID: "fixture-scope",
            jobID: nil,
            sampleSummaryJSON: #"{"scopeKind":"resolvedSnapshot","sampleCount":4}"#,
            sampleManifestSHA256: nil,
            configJSON: #"{"maxEpochs":10}"#,
            metricsJSON: #"{"schemaVersion":1,"evaluationSplit":"trainFallback","trainSampleCount":4,"validationSampleCount":0,"epochs":[]}"#,
            artifactKind: "personalAdamWHead",
            artifactRef: "PersonalModels/AdamWHead/v1/objects/fixture.json",
            artifactSHA256: String(repeating: "a", count: 64),
            resultSummaryJSON: #"{"published":true}"#,
            errorCode: nil
        )
        let workspace = FakeTrainingWorkspacePort(
            runs: [run],
            slots: TrainingRunMethod.allCases.map {
                TrainingWorkspaceSlot(
                    method: $0,
                    isPublished: $0 == .personalAdamW,
                    publishedRunID: $0 == .personalAdamW ? run.id : nil,
                    artifactRef: nil
                )
            }
        )
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: UUID(),
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: []
            ),
            trainingWorkspace: workspace
        )
        await model.refreshTrainingWorkspace()

        let host = NSHostingView(
            rootView: TrainingWorkspaceView(
                model: model,
                onReturnToLibrary: {}
            )
            .frame(width: 900, height: 650)
        )
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(model.selectedTrainingRunID, run.id)
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testReviewQueueGridNavigationMovesByRowsAndColumns() async {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let assets = (0 ..< 8).map {
            Self.makeAsset(sourceID: sourceID, fileName: "review-\($0).jpg")
        }
        let queueItems = assets.map {
            ReviewQueueItemProjection(
                assetID: $0.assetID,
                fileName: $0.fileName,
                availability: $0.availability,
                acceptedTagCount: 0,
                rejectedTagCount: 0
            )
        }
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: sourceID,
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: assets,
                tags: [tag]
            ),
            review: FakePersonalizationReviewPort(queueItems: queueItems)
        )

        await model.enterReviewQueue(tagID: tag.id, displayName: tag.displayName)
        await model.selectAsset(assets[4].assetID)

        await model.moveReviewPrimarySelection(in: .up, columnCount: 3)
        XCTAssertEqual(model.primarySelectedAssetID, assets[1].assetID)

        await model.moveReviewPrimarySelection(in: .down, columnCount: 3)
        XCTAssertEqual(model.primarySelectedAssetID, assets[4].assetID)

        await model.moveReviewPrimarySelection(in: .left, columnCount: 3)
        XCTAssertEqual(model.primarySelectedAssetID, assets[3].assetID)

        await model.moveReviewPrimarySelection(in: .right, columnCount: 3)
        XCTAssertEqual(model.primarySelectedAssetID, assets[4].assetID)
        XCTAssertEqual(model.selectedAssetIDs.count, 1)
    }

    func testReviewQueueArrowNavigationStartsAtFirstItemWhenNothingIsSelected() async {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "second.jpg")
        let queueItems = [first, second].map {
            ReviewQueueItemProjection(
                assetID: $0.assetID,
                fileName: $0.fileName,
                availability: $0.availability,
                acceptedTagCount: 0,
                rejectedTagCount: 0
            )
        }
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: sourceID,
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: [first, second],
                tags: [tag]
            ),
            review: FakePersonalizationReviewPort(queueItems: queueItems)
        )
        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.enterReviewQueue(tagID: tag.id, displayName: tag.displayName)
        XCTAssertNil(model.primarySelectedAssetID)

        await model.moveReviewPrimarySelection(in: .up, columnCount: 3)

        XCTAssertEqual(model.primarySelectedAssetID, first.assetID)
        XCTAssertEqual(model.inspectorDetail?.assetID, first.assetID)
    }

    func testReviewQueueGridNavigationLoadsNextPageBeforeMovingDown() async {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let assets = (0 ..< 6).map {
            Self.makeAsset(sourceID: sourceID, fileName: "review-\($0).jpg")
        }
        let queueItems = assets.map {
            ReviewQueueItemProjection(
                assetID: $0.assetID,
                fileName: $0.fileName,
                availability: $0.availability,
                acceptedTagCount: 0,
                rejectedTagCount: 0
            )
        }
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: sourceID,
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: assets,
                tags: [tag]
            ),
            review: FakePersonalizationReviewPort(
                queueItems: queueItems,
                queuePageSize: 4
            )
        )

        await model.enterReviewQueue(tagID: tag.id, displayName: tag.displayName)
        XCTAssertEqual(model.reviewQueueItems.map(\.assetID), Array(assets.prefix(4)).map(\.assetID))
        await model.selectAsset(assets[2].assetID)

        await model.moveReviewPrimarySelection(in: .down, columnCount: 3)

        XCTAssertEqual(model.primarySelectedAssetID, assets[5].assetID)
        XCTAssertEqual(model.reviewQueueItems.map(\.assetID), assets.map(\.assetID))
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
        await model.openSinglePhotoView(assetID: assets[2].assetID)
        await model.applyReviewDecision(action: .reject)

        XCTAssertEqual(model.reviewQueueItems.map(\.assetID), originalOrder.filter { $0 != assets[2].assetID })
        XCTAssertEqual(model.selectedAssetIDs, [assets[3].assetID])
        XCTAssertTrue(model.isSinglePhotoPresented)
        XCTAssertEqual(model.singlePhotoNavigation?.fileName, "item-3.jpg")
    }

    func testReviewDecisionOnLastQueueItemReturnsFromSinglePhoto() async {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let asset = Self.makeAsset(sourceID: sourceID, fileName: "last.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .active
            ),
            reconciledItems: [asset],
            tags: [tag]
        )
        let review = FakePersonalizationReviewPort(
            queueItems: [
                ReviewQueueItemProjection(
                    assetID: asset.assetID,
                    fileName: asset.fileName,
                    availability: asset.availability,
                    acceptedTagCount: 0,
                    rejectedTagCount: 0
                ),
            ]
        )
        review.decidedAssetIDsProvider = { [weak service] tagID in
            service?.decidedAssetIDs(tagID: tagID) ?? []
        }
        let model = LibraryWorkspaceModel(service: service, review: review)

        await model.start()
        await model.connectFolder()
        await waitForCatalogScanToFinish(model)
        await model.enterReviewQueue(tagID: tag.id, displayName: tag.displayName)
        await model.openSinglePhotoView(assetID: asset.assetID)

        await model.applyReviewDecision(action: .accept)

        XCTAssertTrue(model.reviewQueueItems.isEmpty)
        XCTAssertTrue(model.selectedAssetIDs.isEmpty)
        XCTAssertNil(model.inspectorDetail)
        XCTAssertFalse(model.isSinglePhotoPresented)
        XCTAssertNil(model.singlePhotoNavigation)
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
            tags: [tag],
            startsConnected: true
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
                    canGeneratePersonalModel: true,
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
        for _ in 0 ..< 100 where review.runPendingJobsCallCount == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(review.runPendingJobsCallCount, 1)
        review.releaseBlockedPendingJobs()
        for _ in 0 ..< 40 where PersonalizationSuggestionRunner.isWorkerInFlight {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(PersonalizationSuggestionRunner.isWorkerInFlight)
    }

    func testFeatureSuggestionCompletionNoticeUsesPersistedThresholdCounts() async {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [],
            tags: [tag],
            startsConnected: true
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
                    canGeneratePersonalModel: true,
                    canReview: false,
                    canPause: false,
                    canResume: false,
                    canCancel: false,
                    activeJobID: nil
                ),
            ],
            featureCompletion: (candidates: 12, aboveThreshold: 4, skipped: 3)
        )
        let model = LibraryWorkspaceModel(service: service, review: review)

        await model.start()
        model.requestEnqueueSuggestions(
            tagID: tag.id,
            displayName: tag.displayName,
            mode: .generate
        )
        let confirmed = await model.confirmPendingSuggestionEnqueue()
        XCTAssertTrue(confirmed)
        for _ in 0 ..< 100 where model.notice == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(
            model.notice,
            .featureKnnSuggestionsCompleted(
                tagName: "Family",
                candidates: 12,
                aboveThreshold: 4,
                skipped: 3
            )
        )
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
                reconciledItems: [],
                startsConnected: true
            ),
            review: review
        )
        let tagID = UUID()

        await model.start()

        model.requestEnqueueSuggestions(
            tagID: tagID,
            displayName: "Family",
            mode: .generate
        )
        let captured = try XCTUnwrap(model.pendingSuggestionConfirmation)
        XCTAssertEqual(captured.selectedSourceIDs, [sourceID])
        model.cancelPendingSuggestionEnqueue()

        let confirmed = await model.confirmPendingSuggestionEnqueue(captured)

        XCTAssertTrue(confirmed)
        XCTAssertEqual(review.enqueueCallCount, 1)
        XCTAssertEqual(review.lastEnqueuedSourceIDs, [sourceID])
    }

    func testReviewSourceFilterIsPassedToPendingCountsAndQueue() async throws {
        let tagID = UUID()
        let review = FakePersonalizationReviewPort(
            overviews: [
                SuggestionTagOverview(
                    id: tagID,
                    displayName: "Family",
                    acceptedSampleCount: 4,
                    rejectedSampleCount: 4,
                    pendingSuggestionCount: 2,
                    taskStatus: .completed,
                    checkedCount: 0,
                    totalCount: nil,
                    skippedCount: 0,
                    missingPositiveCount: 0,
                    missingNegativeCount: 0,
                    canGenerate: false,
                    canUpdate: true,
                    canGeneratePersonalModel: true,
                    canReview: true,
                    canPause: false,
                    canResume: false,
                    canCancel: false,
                    activeJobID: nil
                ),
            ]
        )
        let sourceID = UUID()
        let model = LibraryWorkspaceModel(
            service: FakeLibraryWorkspaceService(
                connectedSource: LibrarySourceSummary(
                    id: sourceID,
                    displayName: "Fixture",
                    state: .active
                ),
                reconciledItems: [],
                startsConnected: true
            ),
            review: review
        )
        await model.start()

        await model.refreshReviewState()
        XCTAssertNil(review.lastPendingCountSourceIDs)
        XCTAssertNil(review.lastOverviewSourceIDs)

        await model.setReviewSourceIncluded(sourceID, false)
        XCTAssertEqual(review.lastPendingCountSourceIDs, [])
        XCTAssertEqual(review.lastOverviewSourceIDs, [])

        await model.enterReviewQueue(tagID: tagID, displayName: "Family")
        XCTAssertEqual(review.lastQueueSourceIDs, [])

        await model.selectAllReviewSources()
        XCTAssertNil(review.lastPendingCountSourceIDs)
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

    private static func makeStandardRuntime(
        client: any LocalModelSuggestionClient
    ) -> LocalModelSuggestionRuntime {
        LocalModelSuggestionRuntime(
            client: client,
            catalogScopeID: "catalog-fixture"
        )
    }

    private static func makePersonalCapability(
        tagIDs: [UUID],
        catalogScopeID: String = "catalog-fixture"
    ) -> PersonalModelSuggestionCapability {
        PersonalModelSuggestionCapability(
            target: PersonalModelSuggestionTarget(
                catalogScopeID: catalogScopeID,
                bundleID: PersonalSuggestionMethod.linearHeadBundleID,
                bundleRevision: "bundle-v1",
                provider: "dinov2",
                modelID: "facebook/dinov2-small",
                modelRevision: "model-v1",
                preprocessingRevision: "preprocessing-v1",
                elementCount: 384,
                labelVocabularyRevision: String(repeating: "b", count: 64),
                weightsSHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                policyRevision: "personal-policy-v1"
            ),
            tagIDs: tagIDs
        )
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { ("0" ... "9").contains(String($0))
            || ("a" ... "f").contains(String($0))
        }
    }

    private static func makePersonalTrainingDecisions(
        tagID: UUID,
        assetIDs: [UUID]
    ) -> [PersonalTrainingDecision] {
        precondition(assetIDs.count == 4)
        return assetIDs.enumerated().map { index, assetID in
            PersonalTrainingDecision(
                assetID: assetID,
                contentRevision: 1,
                tagID: tagID,
                state: index < 2 ? .manualAccepted : .manualRejected
            )
        }
    }

    private static func makeStandardSuggestion(
        recommendedState: ModelSuggestionRecommendedState
    ) -> LocalModelSuggestion {
        LocalModelSuggestion(
            track: .standard,
            conceptID: "scene.water",
            tagID: nil,
            score: 0.9,
            recommendedState: recommendedState,
            catalogScopeID: nil,
            bundleID: nil,
            bundleRevision: nil,
            standardPackID: "imageall-public-fixture",
            standardPackRevision: "pack-v1",
            provider: "rgb-linear",
            modelID: "imageall/fixture-scene-linear",
            modelRevision: "model-v1",
            preprocessingRevision: "rgb-channel-mean-v1",
            elementCount: nil,
            labelVocabularyRevision: nil,
            weightsSHA256: nil,
            ontologyID: "imageall-public-fixture",
            ontologyRevision: "ontology-v1",
            mappingRevision: "mapping-v1",
            policyRevision: "policy-v1"
        )
    }

    private static func makePersonalSuggestion(
        tagID: UUID,
        bundleRevision: String = "bundle-v1"
    ) -> LocalModelSuggestion {
        LocalModelSuggestion(
            track: .personal,
            conceptID: nil,
            tagID: tagID,
            score: 1.25,
            recommendedState: .suggested,
            catalogScopeID: "catalog-fixture",
            bundleID: PersonalSuggestionMethod.linearHeadBundleID,
            bundleRevision: bundleRevision,
            standardPackID: nil,
            standardPackRevision: nil,
            provider: "dinov2",
            modelID: "facebook/dinov2-small",
            modelRevision: "model-v1",
            preprocessingRevision: "preprocessing-v1",
            elementCount: 384,
            labelVocabularyRevision: String(repeating: "b", count: 64),
            weightsSHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            ontologyID: nil,
            ontologyRevision: nil,
            mappingRevision: nil,
            policyRevision: "personal-policy-v1"
        )
    }

    private static func makeAsset(
        sourceID: UUID,
        assetID: UUID = UUID(),
        fileName: String = "sample.jpg",
        mediaType: String = "public.jpeg",
        availability: AssetAvailability = .available
    ) -> AssetGridItemProjection {
        AssetGridItemProjection(
            assetID: assetID,
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

@MainActor
private final class FakeLibraryOriginalAssetOpener: LibraryOriginalAssetOpening {
    private(set) var openedAssetIDs: [UUID] = []

    func openOriginalAsset(assetID: UUID) async throws {
        openedAssetIDs.append(assetID)
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
    private var storedPhotosSyncCallCount = 0
    private var storedPhotosFullRepairCallCount = 0
    private var storedPhotosReactivateCallCount = 0
    private var storedLastPhotosSyncSourceID: UUID?
    private var storedLastPhotosFullRepairSourceID: UUID?
    private var lastPhotosReactivateSourceID: UUID?
    private var storedPhotosLibrarySupportedImageCount = 0
    private var storedPhotosCatalogAssetCount = 0
    private var storedSourceIsReconcileClean = false
    private var storedHasPendingCatalogReconcileJobs = true
    private var storedPhotosRebindCallCount = 0
    private var storedPhotosReconcileRunCount = 0
    private var storedReauthorizeCallCount = 0
    private var storedDisableCallCount = 0
    private var storedMutateTagCallCount = 0
    private var storedLastFilter = AssetPageFilter()
    private var storedLastSort: AssetPageSort = .newest
    private let scanFails: Bool
    private let tagMutationFails: Bool
    private let inspectorDetailFails: Bool
    private var remainingInspectorDetailFailuresAfterTagCreation: Int
    private let sourceMutationFails: Bool
    private let blocksReconcileRuns: Bool
    private let photosAuthorizationFails: Bool
    private let reboundSource: LibrarySourceSummary?
    private let catalogReconcileProgress: CatalogReconcileProgress?
    private let previewError: PhotosLibraryError?
    private let previewData: Data
    private let thumbnailData: Data
    private let thumbnailFailureCount: Int
    private let thumbnailFailureError: Error
    private let thumbnailCancelOnCall: Int?
    private let cloudPreviewData: Data
    private let cloudPreviewProgress: [Double]
    private let cloudPreviewFailureCount: Int
    private var storedRemainingThumbnailFailures: Int
    private var storedThumbnailCancelConsumed = false
    private let reconcileGate = DispatchSemaphore(value: 0)
    private var storedHasStartedBlockedReconcile = false
    private let inspectorDetailGate = DispatchSemaphore(value: 0)
    private var remainingBlockedInspectorDetailFetches = 0
    private var storedHasStartedBlockedInspectorDetailFetch = false
    private var storedInspectorDetailFetchCallCount = 0
    private var storedSelectionAggregateCallCount = 0
    private var storedCloudPreviewDownloadCallCount = 0
    private var storedCloudPreviewCancellationCount = 0
    private var storedThumbnailLoadCallCount = 0
    private var storedPreviewLoadCallCount = 0
    private var storedPortableExportCallCount = 0
    private var storedPreviewCacheClearCallCount = 0
    private var storedCreateTagAndAcceptCallCount = 0
    private var storedLastCreateTagAssetIDs: Set<UUID> = []
    private var storedAssetPageFetchCallCount = 0
    private var storedJobActivityItems: [JobActivityItem]
    private var storedJobActivityFetchCallCount = 0
    private var storedJobActivityActionCallCount = 0
    private var folderMonitoringCallback: (@Sendable () -> Void)?
    private var storedTags: [TagListItem]
    private var storedTagGroups: [TagGroupListItem]
    private var storedStandardOntologyInstallCallCount = 0
    private var decisions: [UUID: [UUID: TagDecisionQueryState]] = [:]
    private let exportParentURL: URL?
    private let portableExportResult: PortableCatalogExportResult?
    private let portableExportFails: Bool
    private let portableExportError: Error?
    private var storedPreviewCacheUsage: DerivedImageCacheUsage
    private let previewCacheClearResult: DerivedImageCacheClearResult?
    private let previewCacheClearFails: Bool
    private let previewCacheLocationSelectionResult: AppStorageLocationSelectionResult
    private var storedPreviewCacheLocationSelectionCallCount = 0
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
        inspectorDetailFails: Bool = false,
        inspectorDetailFailuresAfterTagCreation: Int = 0,
        sourceMutationFails: Bool = false,
        initialItems: [AssetGridItemProjection] = [],
        startsConnected: Bool = false,
        blocksReconcileRuns: Bool = false,
        photosAuthorizationFails: Bool = false,
        reboundSource: LibrarySourceSummary? = nil,
        catalogReconcileProgress: CatalogReconcileProgress? = nil,
        previewError: PhotosLibraryError? = nil,
        previewData: Data = Data(),
        thumbnailData: Data = Data(),
        thumbnailFailureCount: Int = 0,
        thumbnailFailureError: Error = PhotosLibraryError.libraryUnavailable,
        thumbnailCancelOnCall: Int? = nil,
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
        previewCacheLocationSelectionResult: AppStorageLocationSelectionResult = .cancelled,
        jobActivityItems: [JobActivityItem] = [],
        jobActivityActionFails: Bool = false,
        jobActivityItemsAfterFailedAction: [JobActivityItem]? = nil,
        blockedSearchText: String? = nil,
        assetPageSize: Int? = nil,
        photosLibrarySupportedImageCount: Int = 0,
        photosCatalogAssetCount: Int = 0,
        sourceIsReconcileClean: Bool = false,
        hasPendingCatalogReconcileJobs: Bool? = nil,
        blocksInspectorDetailFetches: Int = 0
    ) {
        self.connectedSource = connectedSource
        self.reconciledItems = reconciledItems
        self.scanFails = scanFails
        self.tagMutationFails = tagMutationFails
        self.inspectorDetailFails = inspectorDetailFails
        remainingInspectorDetailFailuresAfterTagCreation = inspectorDetailFailuresAfterTagCreation
        self.sourceMutationFails = sourceMutationFails
        self.blocksReconcileRuns = blocksReconcileRuns
        self.photosAuthorizationFails = photosAuthorizationFails
        self.reboundSource = reboundSource
        self.catalogReconcileProgress = catalogReconcileProgress
        self.previewError = previewError
        self.previewData = previewData
        self.thumbnailData = thumbnailData
        self.thumbnailFailureCount = thumbnailFailureCount
        self.thumbnailFailureError = thumbnailFailureError
        self.thumbnailCancelOnCall = thumbnailCancelOnCall
        storedRemainingThumbnailFailures = thumbnailFailureCount
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
        self.previewCacheLocationSelectionResult = previewCacheLocationSelectionResult
        storedJobActivityItems = jobActivityItems
        self.jobActivityActionFails = jobActivityActionFails
        self.jobActivityItemsAfterFailedAction = jobActivityItemsAfterFailedAction
        self.blockedSearchText = blockedSearchText
        self.assetPageSize = assetPageSize
        storedPhotosLibrarySupportedImageCount = photosLibrarySupportedImageCount
        storedPhotosCatalogAssetCount = photosCatalogAssetCount
        storedSourceIsReconcileClean = sourceIsReconcileClean
        storedHasPendingCatalogReconcileJobs = hasPendingCatalogReconcileJobs ?? startsConnected
        remainingBlockedInspectorDetailFetches = blocksInspectorDetailFetches
        storedSources = startsConnected ? [connectedSource] : []
        storedItems = initialItems
        storedTags = tags.map { tag in
            TagListItem(
                id: tag.id,
                displayName: tag.displayName,
                state: tag.state,
                groupID: tag.groupID == TagGroupSeed.other.id
                    ? TagGroupSeed.classify(displayName: tag.displayName).id
                    : tag.groupID
            )
        }
        storedTagGroups = TagGroupSeed.allCases.map {
            TagGroupListItem(
                id: $0.id,
                displayName: $0.displayName,
                sortOrder: $0.sortOrder,
                isSystem: true
            )
        }
    }

    var hasStartedBlockedReconcile: Bool {
        lock.withLock { storedHasStartedBlockedReconcile }
    }

    var hasStartedBlockedInspectorDetailFetch: Bool {
        lock.withLock { storedHasStartedBlockedInspectorDetailFetch }
    }

    var inspectorDetailFetchCallCount: Int {
        lock.withLock { storedInspectorDetailFetchCallCount }
    }

    var selectionAggregateCallCount: Int {
        lock.withLock { storedSelectionAggregateCallCount }
    }

    func releaseBlockedReconcile() {
        reconcileGate.signal()
    }

    func releaseBlockedInspectorDetailFetch() {
        inspectorDetailGate.signal()
    }

    var reconcileRunCount: Int {
        lock.withLock { storedReconcileRunCount }
    }

    var photosConnectCallCount: Int {
        lock.withLock { storedPhotosConnectCallCount }
    }

    var photosSyncCallCount: Int {
        lock.withLock { storedPhotosSyncCallCount }
    }

    var photosFullRepairCallCount: Int {
        lock.withLock { storedPhotosFullRepairCallCount }
    }

    var lastPhotosSyncSourceID: UUID? {
        lock.withLock { storedLastPhotosSyncSourceID }
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

    var standardOntologyInstallCallCount: Int {
        lock.withLock { storedStandardOntologyInstallCallCount }
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

    var previewLoadCallCount: Int {
        lock.withLock { storedPreviewLoadCallCount }
    }

    var portableExportCallCount: Int {
        lock.withLock { storedPortableExportCallCount }
    }

    var previewCacheClearCallCount: Int {
        lock.withLock { storedPreviewCacheClearCallCount }
    }

    var previewCacheLocationSelectionCallCount: Int {
        lock.withLock { storedPreviewCacheLocationSelectionCallCount }
    }

    var createTagAndAcceptCallCount: Int {
        lock.withLock { storedCreateTagAndAcceptCallCount }
    }

    var lastCreateTagAssetIDs: Set<UUID> {
        lock.withLock { storedLastCreateTagAssetIDs }
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
        let callback = lock.withLock {
            storedHasPendingCatalogReconcileJobs = true
            return folderMonitoringCallback
        }
        callback?()
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

    func fetchAppStorageLocation() -> AppStorageLocationStatus {
        switch previewCacheLocationSelectionResult {
        case .cancelled:
            AppStorageLocationStatus(
                applicationSupportDirectoryURL: URL(
                    fileURLWithPath: "/Library/Application Support/ImageAll",
                    isDirectory: true
                ),
                cachesDirectoryURL: URL(
                    fileURLWithPath: "/Library/Caches/ImageAll",
                    isDirectory: true
                ),
                preferredExternalRootURL: nil,
                usesExternalStorage: false,
                requiresRestart: false
            )
        case let .restartRequired(status):
            status
        }
    }

    @MainActor
    func chooseExternalAppStorageLocation() async throws -> AppStorageLocationSelectionResult {
        lock.withLock {
            storedPreviewCacheLocationSelectionCallCount += 1
        }
        return previewCacheLocationSelectionResult
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
            case (.paused, .resume), (.retryableFailed, .resume):
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
        lock.withLock {
            storedSources = [connectedSource]
            storedHasPendingCatalogReconcileJobs = true
        }
        return .connected(sourceID: connectedSource.id)
    }

    func connectPhotos() async throws -> ConnectPhotosOutcome {
        lock.withLock {
            storedPhotosConnectCallCount += 1
            storedSources = [connectedSource]
            storedHasPendingCatalogReconcileJobs = true
        }
        return .connected(sourceID: connectedSource.id)
    }

    func syncPhotosLibrary(sourceID: UUID) async throws {
        lock.withLock {
            storedPhotosSyncCallCount += 1
            storedLastPhotosSyncSourceID = sourceID
            storedHasPendingCatalogReconcileJobs = true
        }
    }

    func photosLibrarySupportedImageCount() throws -> Int {
        lock.withLock { storedPhotosLibrarySupportedImageCount }
    }

    func photosCatalogAssetCount(sourceID _: UUID) throws -> Int {
        lock.withLock { storedPhotosCatalogAssetCount }
    }

    func requestPhotosFullRepair(sourceID: UUID) async throws {
        lock.withLock {
            storedPhotosFullRepairCallCount += 1
            storedLastPhotosFullRepairSourceID = sourceID
            storedHasPendingCatalogReconcileJobs = true
        }
    }

    func reactivatePhotosLibrary(sourceID: UUID) async throws {
        lock.withLock {
            storedPhotosReactivateCallCount += 1
            lastPhotosReactivateSourceID = sourceID
            storedHasPendingCatalogReconcileJobs = true
        }
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
            storedHasPendingCatalogReconcileJobs = true
            return .rebound(previousSourceID: unavailableSourceID, sourceID: reboundSource.id)
        }
    }

    func reauthorizeFolder(sourceID: UUID) async throws -> ReauthorizeFolderOutcome {
        if sourceMutationFails {
            throw FakeWorkspaceError.sourceActionFailed
        }
        lock.withLock {
            storedReauthorizeCallCount += 1
            storedHasPendingCatalogReconcileJobs = true
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

    func enqueueReconcile(sourceIDs: [UUID]) throws {
        guard !sourceIDs.isEmpty else { return }
        lock.withLock { storedHasPendingCatalogReconcileJobs = true }
    }

    func hasPendingCatalogReconcileJobs() throws -> Bool {
        lock.withLock { storedHasPendingCatalogReconcileJobs }
    }

    func sourceIsReconcileClean(sourceID: UUID) throws -> Bool {
        lock.withLock { storedSourceIsReconcileClean }
    }

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
            storedHasPendingCatalogReconcileJobs = false
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
            storedHasPendingCatalogReconcileJobs = false
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
                if !filter.sourceIDs.isEmpty,
                   !filter.sourceIDs.contains(item.sourceID)
                {
                    return false
                }
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
        let callCount = lock.withLock { () -> Int in
            storedThumbnailLoadCallCount += 1
            return storedThumbnailLoadCallCount
        }
        if let thumbnailCancelOnCall,
           callCount == thumbnailCancelOnCall,
           lock.withLock({
               guard !storedThumbnailCancelConsumed else { return false }
               storedThumbnailCancelConsumed = true
               return true
           })
        {
            throw CancellationError()
        }
        let shouldFail = lock.withLock { () -> Bool in
            guard storedRemainingThumbnailFailures > 0 else { return false }
            storedRemainingThumbnailFailures -= 1
            return true
        }
        if shouldFail {
            throw thumbnailFailureError
        }
        return thumbnailData
    }

    func loadPreview(assetID: UUID) async throws -> Data {
        lock.withLock { storedPreviewLoadCallCount += 1 }
        if let previewError {
            throw previewError
        }
        return previewData
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

    func listTagGroups() throws -> [TagGroupListItem] {
        lock.withLock { storedTagGroups }
    }

    func installPresetTags() throws -> TagPresetInstallResult {
        lock.withLock {
            let existingNames = Set(storedTags.map(\.displayName))
            let created: [TagListItem] = TagPresetCatalog.starterDisplayNames.compactMap { displayName in
                guard !existingNames.contains(displayName) else { return nil }
                return TagListItem(
                    id: UUID(),
                    displayName: displayName,
                    state: .active,
                    groupID: TagGroupSeed.classify(displayName: displayName).id
                )
            }
            storedTags.append(contentsOf: created)
            return TagPresetInstallResult(createdTags: created)
        }
    }

    func installStandardOntologyPackage(
        _ package: StandardOntologyPackageInput
    ) throws -> StandardOntologyInstallResult {
        lock.withLock {
            storedStandardOntologyInstallCallCount += 1
            let existingNames = Set(storedTags.map(\.displayName))
            let installed = package.concepts.map { concept in
                storedTags.first(where: { $0.displayName == concept.canonicalName })
                    ?? TagListItem(id: UUID(), displayName: concept.canonicalName, state: .active)
            }
            storedTags.append(contentsOf: installed.filter { !existingNames.contains($0.displayName) })
            return StandardOntologyInstallResult(
                installedTags: installed,
                wasAlreadyInstalled: installed.allSatisfy { existingNames.contains($0.displayName) }
            )
        }
    }

    func setContentRevision(assetID: UUID, contentRevision: Int) {
        lock.withLock {
            guard let index = storedItems.firstIndex(where: { $0.assetID == assetID }) else {
                return
            }
            let item = storedItems[index]
            storedItems[index] = AssetGridItemProjection(
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
                contentRevision: contentRevision,
                acceptedTagCount: item.acceptedTagCount,
                rejectedTagCount: item.rejectedTagCount
            )
        }
    }

    func fetchInspectorDetail(assetID: UUID) throws -> AssetInspectorDetail {
        let shouldBlock = lock.withLock { () -> Bool in
            storedInspectorDetailFetchCallCount += 1
            guard remainingBlockedInspectorDetailFetches > 0 else { return false }
            remainingBlockedInspectorDetailFetches -= 1
            storedHasStartedBlockedInspectorDetailFetch = true
            return true
        }
        if shouldBlock {
            inspectorDetailGate.wait()
        }
        if inspectorDetailFails {
            throw FakeWorkspaceError.notFound
        }
        return try lock.withLock {
            if storedCreateTagAndAcceptCallCount > 0,
               remainingInspectorDetailFailuresAfterTagCreation > 0
            {
                remainingInspectorDetailFailuresAfterTagCreation -= 1
                throw FakeWorkspaceError.notFound
            }
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
            storedSelectionAggregateCallCount += 1
            return tagIDs.map { tagID in
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
        if tagMutationFails {
            throw FakeWorkspaceError.tagMutationFailed
        }
        return lock.withLock {
            storedCreateTagAndAcceptCallCount += 1
            storedLastCreateTagAssetIDs = Set(assetIDs)
            let tag = TagListItem(
                id: UUID(),
                displayName: rawName,
                state: .active,
                groupID: TagGroupSeed.classify(displayName: rawName).id
            )
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
            let current = storedTags[index]
            let renamed = TagListItem(
                id: tagID,
                displayName: rawName,
                state: .active,
                groupID: current.groupID
            )
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

    func moveTag(tagID: UUID, toGroupID: UUID) throws -> TagListItem {
        if tagMutationFails {
            throw FakeWorkspaceError.tagMutationFailed
        }
        return try lock.withLock {
            guard storedTagGroups.contains(where: { $0.id == toGroupID }) else {
                throw FakeWorkspaceError.notFound
            }
            guard let index = storedTags.firstIndex(where: { $0.id == tagID }) else {
                throw FakeWorkspaceError.notFound
            }
            let current = storedTags[index]
            let moved = TagListItem(
                id: current.id,
                displayName: current.displayName,
                state: current.state,
                groupID: toGroupID
            )
            storedTags[index] = moved
            return moved
        }
    }

    func createTagGroup(rawName: String) throws -> TagGroupListItem {
        if tagMutationFails {
            throw FakeWorkspaceError.tagMutationFailed
        }
        return try lock.withLock {
            if storedTagGroups.contains(where: {
                $0.displayName.caseInsensitiveCompare(rawName) == .orderedSame
            }) {
                throw CatalogQueryError.duplicateTag
            }
            let nextSort = (storedTagGroups.map(\.sortOrder).max() ?? -1) + 1
            let created = TagGroupListItem(
                id: UUID(),
                displayName: rawName,
                sortOrder: nextSort,
                isSystem: false
            )
            storedTagGroups.append(created)
            return created
        }
    }

    func renameTagGroup(groupID: UUID, rawName: String) throws -> TagGroupListItem {
        if tagMutationFails {
            throw FakeWorkspaceError.tagMutationFailed
        }
        return try lock.withLock {
            guard let index = storedTagGroups.firstIndex(where: { $0.id == groupID }) else {
                throw FakeWorkspaceError.notFound
            }
            let current = storedTagGroups[index]
            guard !current.isSystem else {
                throw CatalogQueryError.systemGroupProtected
            }
            let renamed = TagGroupListItem(
                id: current.id,
                displayName: rawName,
                sortOrder: current.sortOrder,
                isSystem: current.isSystem
            )
            storedTagGroups[index] = renamed
            return renamed
        }
    }

    func deleteTagGroup(groupID: UUID) throws {
        if tagMutationFails {
            throw FakeWorkspaceError.tagMutationFailed
        }
        try lock.withLock {
            guard let group = storedTagGroups.first(where: { $0.id == groupID }) else {
                throw FakeWorkspaceError.notFound
            }
            guard !group.isSystem else {
                throw CatalogQueryError.systemGroupProtected
            }
            storedTagGroups.removeAll { $0.id == groupID }
            let fallback = TagGroupSeed.other.id
            storedTags = storedTags.map { tag in
                guard tag.groupID == groupID else { return tag }
                return TagListItem(
                    id: tag.id,
                    displayName: tag.displayName,
                    state: tag.state,
                    groupID: fallback
                )
            }
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

private extension StandardModelSuggestionCapability {
    static let fixture = StandardModelSuggestionCapability(
        target: StandardModelSuggestionTarget(
            standardPackID: "imageall-public-fixture",
            standardPackRevision: "pack-v1"
        ),
        manifestSHA256: "dc7b0a9a8391978a56b7e55f97c1abc73fe9e9834f1c2dd16152fc13883bd873",
        ontologyID: "imageall-public-fixture",
        ontologyRevision: "ontology-v1",
        provider: "rgb-linear",
        modelID: "imageall/fixture-scene-linear",
        modelRevision: "model-v1",
        preprocessingRevision: "rgb-channel-mean-v1",
        mappingRevision: "mapping-v1",
        policyRevision: "policy-v1",
        weightsSHA256: "4129427105a9392e02b5306b657a029f7d0034f05a10d1363254e5f3d579fce9"
    )
}

private final class FakeLocalModelSuggestionClient: LocalModelSuggestionClient, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<[LocalModelSuggestion], LocalModelSuggestionClientError>
    private let serviceHealthResult: Result<LocalModelServiceHealth, LocalModelSuggestionClientError>
    private let blocksRequests: Bool
    private let standardCapability: StandardModelSuggestionCapabilityAvailability
    private var storedPersonalCapabilities: [PersonalModelSuggestionCapabilityAvailability]
    private let embeddingResult: Result<PersonalTrainingEmbedding, LocalModelSuggestionClientError>
    private let rebuildResult: Result<PersonalModelSuggestionCapability, LocalModelSuggestionClientError>
    private var storedCallCount = 0
    private var storedServiceHealthCallCount = 0
    private var storedStandardCapabilityCallCount = 0
    private var storedEmbeddingCallCount = 0
    private var storedEmbeddingCacheKeys: [PersonalTrainingEmbeddingCacheKey?] = []
    private var storedRebuildCallCount = 0
    private var storedPersonalCapabilityCallCount = 0
    private var storedLastImageData: Data?
    private var storedLastTarget: ModelSuggestionTarget?
    private var storedLastExpectedActiveBundle: PersonalModelActiveBundleIdentity?
    private var storedLastRebuildSnapshot: PersonalModelRebuildSnapshot?
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    init(
        result: Result<[LocalModelSuggestion], LocalModelSuggestionClientError>,
        serviceHealthResult: Result<LocalModelServiceHealth, LocalModelSuggestionClientError> = .failure(.serviceUnavailable),
        standardCapability: StandardModelSuggestionCapabilityAvailability = .available(.fixture),
        personalCapability: PersonalModelSuggestionCapabilityAvailability = .unavailable,
        personalCapabilities: [PersonalModelSuggestionCapabilityAvailability]? = nil,
        embeddingResult: Result<PersonalTrainingEmbedding, LocalModelSuggestionClientError> = .failure(.serviceUnavailable),
        rebuildResult: Result<PersonalModelSuggestionCapability, LocalModelSuggestionClientError> = .failure(.serviceUnavailable),
        blocksRequests: Bool = false
    ) {
        self.result = result
        self.serviceHealthResult = serviceHealthResult
        self.standardCapability = standardCapability
        storedPersonalCapabilities = personalCapabilities ?? [personalCapability]
        self.embeddingResult = embeddingResult
        self.rebuildResult = rebuildResult
        self.blocksRequests = blocksRequests
    }

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    var serviceHealthCallCount: Int {
        lock.withLock { storedServiceHealthCallCount }
    }

    var standardCapabilityCallCount: Int {
        lock.withLock { storedStandardCapabilityCallCount }
    }

    var lastImageData: Data? {
        lock.withLock { storedLastImageData }
    }

    var lastTarget: ModelSuggestionTarget? {
        lock.withLock { storedLastTarget }
    }

    var embeddingCallCount: Int {
        lock.withLock { storedEmbeddingCallCount }
    }

    var embeddingCacheKeys: [PersonalTrainingEmbeddingCacheKey?] {
        lock.withLock { storedEmbeddingCacheKeys }
    }

    var rebuildCallCount: Int {
        lock.withLock { storedRebuildCallCount }
    }

    var personalCapabilityCallCount: Int {
        lock.withLock { storedPersonalCapabilityCallCount }
    }

    var lastExpectedActiveBundle: PersonalModelActiveBundleIdentity? {
        lock.withLock { storedLastExpectedActiveBundle }
    }

    var lastRebuildSnapshot: PersonalModelRebuildSnapshot? {
        lock.withLock { storedLastRebuildSnapshot }
    }

    var hasBlockedRequest: Bool {
        lock.withLock { blockedContinuation != nil }
    }

    func releaseBlockedRequest() {
        let continuation = lock.withLock {
            let continuation = blockedContinuation
            blockedContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func personalCapability() async throws -> PersonalModelSuggestionCapabilityAvailability {
        lock.withLock {
            let index = min(
                storedPersonalCapabilityCallCount,
                max(0, storedPersonalCapabilities.count - 1)
            )
            storedPersonalCapabilityCallCount += 1
            return storedPersonalCapabilities[index]
        }
    }

    func standardCapability() async throws -> StandardModelSuggestionCapabilityAvailability {
        lock.withLock { storedStandardCapabilityCallCount += 1 }
        return standardCapability
    }

    func serviceHealth() async throws -> LocalModelServiceHealth {
        lock.withLock { storedServiceHealthCallCount += 1 }
        return try serviceHealthResult.get()
    }

    func embedding(
        imageData: Data,
        requestID: String,
        cacheKey: PersonalTrainingEmbeddingCacheKey?
    ) async throws -> PersonalTrainingEmbedding {
        lock.withLock {
            storedEmbeddingCallCount += 1
            storedEmbeddingCacheKeys.append(cacheKey)
        }
        return try embeddingResult.get()
    }

    func rebuildPersonalModel(
        requestID: String,
        expectedActiveBundle: PersonalModelActiveBundleIdentity?,
        snapshot: PersonalModelRebuildSnapshot
    ) async throws -> PersonalModelSuggestionCapability {
        lock.withLock {
            storedRebuildCallCount += 1
            storedLastExpectedActiveBundle = expectedActiveBundle
            storedLastRebuildSnapshot = snapshot
        }
        return try rebuildResult.get()
    }

    func suggestions(
        imageData: Data,
        requestID: String,
        target: ModelSuggestionTarget
    ) async throws -> [LocalModelSuggestion] {
        lock.withLock {
            storedCallCount += 1
            storedLastImageData = imageData
            storedLastTarget = target
        }
        if blocksRequests {
            await withCheckedContinuation { continuation in
                lock.withLock { blockedContinuation = continuation }
            }
        }
        return try result.get()
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

private actor FakeAppPersonalModelRebuilder: AppPersonalModelRebuilding {
    private let result: Result<AppPersonalLinearHeadIdentity, Error>
    private var storedCallCount = 0
    private var storedSnapshots: [PersonalTrainingSnapshot] = []

    init(result: Result<AppPersonalLinearHeadIdentity, Error>) {
        self.result = result
    }

    func rebuild(
        snapshotSource: any AppPersonalTrainingSnapshotSource
    ) async throws -> AppPersonalLinearHeadIdentity {
        storedCallCount += 1
        storedSnapshots.append(try await snapshotSource.currentSnapshot())
        return try result.get()
    }

    func callCount() -> Int {
        storedCallCount
    }

    func snapshots() -> [PersonalTrainingSnapshot] {
        storedSnapshots
    }
}

private actor BlockingAppPersonalModelRebuilder: AppPersonalModelRebuilding {
    private let result: AppPersonalLinearHeadIdentity
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false

    init(result: AppPersonalLinearHeadIdentity) {
        self.result = result
    }

    func rebuild(
        snapshotSource: any AppPersonalTrainingSnapshotSource
    ) async throws -> AppPersonalLinearHeadIdentity {
        _ = try await snapshotSource.currentSnapshot()
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return result
    }

    func didStart() -> Bool {
        started
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor FakeAppPersonalSampleSuggester: AppPersonalSampleSuggesting {
    private let batch: AppPersonalSampleSuggestionBatch
    private var storedCandidates: [[PersonalSuggestionCandidate]] = []

    init(batch: AppPersonalSampleSuggestionBatch) {
        self.batch = batch
    }

    func suggest(
        candidates: [PersonalSuggestionCandidate],
        maximumSuggestionsPerAsset _: Int,
        embedding: @escaping @Sendable (PersonalSuggestionCandidate) async throws -> AppCoreMLEmbedding
    ) async throws -> AppPersonalSampleSuggestionBatch {
        storedCandidates.append(candidates)
        for candidate in candidates {
            _ = try await embedding(candidate)
        }
        return batch
    }

    func requestedCandidates() -> [PersonalSuggestionCandidate] {
        storedCandidates.last ?? []
    }
}

private actor FakeAppPersonalTagLibrarySuggester: AppPersonalTagLibrarySuggesting {
    private let batch: AppPersonalTagLibrarySuggestionBatch
    private var storedTagIDs: [UUID] = []
    private var storedCandidates: [[PersonalSuggestionCandidate]] = []

    init(batch: AppPersonalTagLibrarySuggestionBatch) {
        self.batch = batch
    }

    func suggest(
        tagID: UUID,
        candidates: [PersonalSuggestionCandidate],
        maximumPendingCount _: Int,
        minimumScore _: Double,
        embedding: @escaping @Sendable (PersonalSuggestionCandidate) async throws -> AppCoreMLEmbedding,
        progress: (@Sendable (Int, Int, Int) -> Void)?
    ) async throws -> AppPersonalTagLibrarySuggestionBatch {
        storedTagIDs.append(tagID)
        storedCandidates.append(candidates)
        for (index, candidate) in candidates.enumerated() {
            _ = try await embedding(candidate)
            progress?(index + 1, min(index + 1, batch.hits.count), batch.skippedCount)
        }
        return batch
    }

    func requestedTagIDs() -> [UUID] {
        storedTagIDs
    }
}

private struct SelectedAssetEmbeddingCacheRequest: Equatable {
    let assetID: UUID
    let contentRevision: Int
    let imageData: Data
}

private actor FakeSelectedAssetEmbeddingCache: AppSelectedAssetEmbeddingCaching {
    private var storedRequests: [SelectedAssetEmbeddingCacheRequest] = []
    private var cachedKeys: Set<String> = []
    private let failure: Error?

    init(failure: Error? = nil) {
        self.failure = failure
    }

    func cacheSelectedAsset(
        assetID: UUID,
        contentRevision: Int,
        imageData: @escaping @Sendable () async throws -> Data
    ) async throws -> AppCoreMLCachedEmbedding {
        if let failure { throw failure }
        let key = "\(assetID.uuidString.lowercased())|\(contentRevision)"
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
        if cachedKeys.contains(key) {
            return AppCoreMLCachedEmbedding(
                identity: identity,
                values: [0.5],
                vectorSHA256: String(repeating: "5", count: 64),
                origin: .cacheHit
            )
        }
        let data = try await imageData()
        cachedKeys.insert(key)
        storedRequests.append(
            SelectedAssetEmbeddingCacheRequest(
                assetID: assetID,
                contentRevision: contentRevision,
                imageData: data
            )
        )
        return AppCoreMLCachedEmbedding(
            identity: identity,
            values: [0.5],
            vectorSHA256: String(repeating: "5", count: 64),
            origin: .generated
        )
    }

    func requests() -> [SelectedAssetEmbeddingCacheRequest] {
        storedRequests
    }
}

private struct FakePersonalSuggestionReplacement: Equatable {
    let candidate: PersonalSuggestionCandidate
    let predictions: [PersonalSuggestionPrediction]
    let expectedCapability: PersonalModelSuggestionCapability
}

private struct FakePersonalTagLibraryReplacement: Equatable {
    let tagID: UUID
    let hits: [AppPersonalTagLibrarySuggestionHit]
    let expectedCapability: PersonalModelSuggestionCapability
    let maximumPendingCount: Int
}

private struct FakeStandardSuggestionReplacement: Equatable {
    let assetID: UUID
    let contentRevision: Int
    let suggestions: [LocalModelSuggestion]
    let expectedTarget: StandardModelSuggestionTarget
}

private final class FakeTrainingWorkspacePort: TrainingWorkspacePort, @unchecked Sendable {
    private let lock = NSLock()
    private let runs: [TrainingRunRecord]
    private let slots: [TrainingWorkspaceSlot]
    private var storedRequestedMethods: [TrainingRunMethod?] = []

    init(runs: [TrainingRunRecord], slots: [TrainingWorkspaceSlot]) {
        self.runs = runs
        self.slots = slots
    }

    var requestedMethods: [TrainingRunMethod?] {
        lock.withLock { storedRequestedMethods }
    }

    func snapshot(
        method: TrainingRunMethod?,
        limit: Int
    ) throws -> TrainingWorkspaceSnapshot {
        lock.withLock {
            storedRequestedMethods.append(method)
            return TrainingWorkspaceSnapshot(
                runs: Array(
                    runs
                        .filter { method == nil || $0.method == method }
                        .prefix(limit)
                ),
                slots: slots
            )
        }
    }
}

private final class BlockingTrainingWorkspacePort: TrainingWorkspacePort, @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var storedDidStart = false

    var didStart: Bool {
        lock.withLock { storedDidStart }
    }

    func snapshot(
        method _: TrainingRunMethod?,
        limit _: Int
    ) throws -> TrainingWorkspaceSnapshot {
        lock.withLock { storedDidStart = true }
        release.wait()
        return TrainingWorkspaceSnapshot(
            runs: [],
            slots: TrainingRunMethod.allCases.map {
                TrainingWorkspaceSlot(
                    method: $0,
                    isPublished: false,
                    publishedRunID: nil,
                    artifactRef: nil
                )
            }
        )
    }

    func resume() {
        release.signal()
    }
}

private final class FakePersonalizationReviewPort: PersonalizationReviewPort, @unchecked Sendable {
    private let lock = NSLock()
    private var storedOverviews: [SuggestionTagOverview]
    private var storedQueueItems: [ReviewQueueItemProjection]
    private var storedPendingByAsset: [UUID: [AssetPendingSuggestion]]
    private let personalCandidates: [PersonalSuggestionCandidate]
    private var storedActivatedPersonalCapability: PersonalModelSuggestionCapability?
    private var storedEnqueuedPersonalCapability: PersonalModelSuggestionCapability?
    private var storedEnqueuedStandardTarget: StandardModelSuggestionTarget?
    private var storedStandardLibraryJob: StandardLibrarySuggestionJobProjection?
    private var storedPersonalLibraryJob: PersonalLibrarySuggestionJobProjection?
    private var storedFeatureSuggestionJob: FeatureSuggestionJobProjection?
    private var storedPersonalSuggestionReplacements: [FakePersonalSuggestionReplacement] = []
    private var storedPersonalTagLibraryReplacements: [FakePersonalTagLibraryReplacement] = []
    private var storedStandardSuggestionReplacements: [FakeStandardSuggestionReplacement] = []
    private var storedPersonalSuggestionInvalidationCallCount = 0
    private var storedPersonalModelRebuildEnqueueCallCount = 0
    private let queuePageSize: Int?
    private let trainingSnapshot: PersonalTrainingSnapshot?
    private let standardSuggestionReplacementFails: Bool
    private let featureCompletion:
        (candidates: Int, aboveThreshold: Int, skipped: Int)?
    var decidedAssetIDsProvider: (@Sendable (UUID) -> Set<UUID>)?
    let blocksRunPendingJobs: Bool
    private let pendingJobsBlocker = DispatchSemaphore(value: 0)
    private(set) var enqueueCallCount = 0
    private(set) var runPendingJobsCallCount = 0

    init(
        overviews: [SuggestionTagOverview] = [],
        queueItems: [ReviewQueueItemProjection] = [],
        pendingByAsset: [UUID: [AssetPendingSuggestion]] = [:],
        personalCandidates: [PersonalSuggestionCandidate] = [],
        personalLibraryJob: PersonalLibrarySuggestionJobProjection? = nil,
        standardLibraryJob: StandardLibrarySuggestionJobProjection? = nil,
        trainingSnapshot: PersonalTrainingSnapshot? = nil,
        standardSuggestionReplacementFails: Bool = false,
        blocksRunPendingJobs: Bool = false,
        queuePageSize: Int? = nil,
        featureCompletion: (candidates: Int, aboveThreshold: Int, skipped: Int)? = nil
    ) {
        storedOverviews = overviews
        storedQueueItems = queueItems
        storedPendingByAsset = pendingByAsset
        self.personalCandidates = personalCandidates
        storedPersonalLibraryJob = personalLibraryJob
        storedStandardLibraryJob = standardLibraryJob
        self.trainingSnapshot = trainingSnapshot
        self.standardSuggestionReplacementFails = standardSuggestionReplacementFails
        self.featureCompletion = featureCompletion
        self.blocksRunPendingJobs = blocksRunPendingJobs
        self.queuePageSize = queuePageSize
    }

    var activatedPersonalCapability: PersonalModelSuggestionCapability? {
        lock.withLock { storedActivatedPersonalCapability }
    }

    var enqueuedPersonalCapability: PersonalModelSuggestionCapability? {
        lock.withLock { storedEnqueuedPersonalCapability }
    }

    var enqueuedStandardTarget: StandardModelSuggestionTarget? {
        lock.withLock { storedEnqueuedStandardTarget }
    }

    var personalSuggestionReplacements: [FakePersonalSuggestionReplacement] {
        lock.withLock { storedPersonalSuggestionReplacements }
    }

    var personalTagLibraryReplacements: [FakePersonalTagLibraryReplacement] {
        lock.withLock { storedPersonalTagLibraryReplacements }
    }

    var standardSuggestionReplacements: [FakeStandardSuggestionReplacement] {
        lock.withLock { storedStandardSuggestionReplacements }
    }

    var personalSuggestionInvalidationCallCount: Int {
        lock.withLock { storedPersonalSuggestionInvalidationCallCount }
    }

    var personalModelRebuildEnqueueCallCount: Int {
        lock.withLock { storedPersonalModelRebuildEnqueueCallCount }
    }

    private(set) var lastEnqueuedSourceIDs: [UUID]?
    private(set) var lastPendingCountSourceIDs: [UUID]?
    private(set) var lastOverviewSourceIDs: [UUID]?
    private(set) var lastQueueSourceIDs: [UUID]?

    func totalPendingSuggestionCount(sourceIDs: [UUID]?) throws -> Int {
        lock.withLock {
            lastPendingCountSourceIDs = sourceIDs
            return storedQueueItems.count
        }
    }

    func tagOverviews(sourceIDs: [UUID]?) throws -> [SuggestionTagOverview] {
        lock.withLock {
            lastOverviewSourceIDs = sourceIDs
            return storedOverviews
        }
    }

    func fetchReviewQueue(
        tagID: UUID,
        sourceIDs: [UUID]?,
        cursor: ReviewQueueCursor?,
        limit: Int
    ) throws -> ReviewQueuePage {
        lock.withLock {
            lastQueueSourceIDs = sourceIDs
            let excluded = decidedAssetIDsProvider?(tagID) ?? []
            let visible = storedQueueItems.filter { !excluded.contains($0.assetID) }
            let startIndex = cursor
                .flatMap { String(data: $0.token, encoding: .utf8) }
                .flatMap(Int.init) ?? 0
            let pageSize = min(queuePageSize ?? limit, limit)
            let items = Array(visible.dropFirst(startIndex).prefix(pageSize))
            let nextIndex = startIndex + items.count
            let nextCursor = nextIndex < visible.count
                ? ReviewQueueCursor(token: Data(String(nextIndex).utf8))
                : nil
            return ReviewQueuePage(items: items, nextCursor: nextCursor)
        }
    }

    func pendingSuggestionsForAsset(assetID: UUID) throws -> [AssetPendingSuggestion] {
        lock.withLock { storedPendingByAsset[assetID] ?? [] }
    }

    func personalTrainingSnapshot() throws -> PersonalTrainingSnapshot {
        guard let trainingSnapshot else {
            throw PersonalizationReviewError.persistenceFailure
        }
        return trainingSnapshot
    }

    func personalTrainingSnapshot(limitingToAssetIDs assetIDs: Set<UUID>) throws -> PersonalTrainingSnapshot {
        try personalTrainingSnapshot(limitingToTagIDs: nil, limitingToAssetIDs: assetIDs)
    }

    func personalTrainingSnapshot(
        limitingToTagIDs tagIDs: Set<UUID>,
        limitingToAssetIDs assetIDs: Set<UUID>?
    ) throws -> PersonalTrainingSnapshot {
        try personalTrainingSnapshot(limitingToTagIDs: Optional(tagIDs), limitingToAssetIDs: assetIDs)
    }

    private func personalTrainingSnapshot(
        limitingToTagIDs tagIDs: Set<UUID>?,
        limitingToAssetIDs assetIDs: Set<UUID>?
    ) throws -> PersonalTrainingSnapshot {
        let base = try personalTrainingSnapshot()
        if let tagIDs, tagIDs.isEmpty {
            return PersonalTrainingSnapshot(
                catalogScopeID: base.catalogScopeID,
                personalTagIDs: [],
                decisions: []
            )
        }
        if let assetIDs, assetIDs.isEmpty {
            return PersonalTrainingSnapshot(
                catalogScopeID: base.catalogScopeID,
                personalTagIDs: [],
                decisions: []
            )
        }
        var scopedDecisions = base.decisions
        if let tagIDs {
            scopedDecisions = scopedDecisions.filter { tagIDs.contains($0.tagID) }
        }
        if let assetIDs {
            scopedDecisions = scopedDecisions.filter { assetIDs.contains($0.assetID) }
        }
        let acceptedCounts = Dictionary(
            grouping: scopedDecisions.filter { $0.state == .manualAccepted },
            by: \.tagID
        ).mapValues(\.count)
        let trainableTagIDs = Set(
            acceptedCounts.compactMap { tagID, count in
                count >= 2 ? tagID : nil
            }
        )
        let decisions = scopedDecisions.filter {
            trainableTagIDs.contains($0.tagID) && $0.state == .manualAccepted
        }
        let resolvedTagIDs = Array(trainableTagIDs).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        return PersonalTrainingSnapshot(
            catalogScopeID: base.catalogScopeID,
            personalTagIDs: resolvedTagIDs,
            decisions: decisions
        )
    }

    func enqueuePersonalModelRebuildIfReady() throws -> UUID? {
        lock.withLock {
            storedPersonalModelRebuildEnqueueCallCount += 1
            return UUID()
        }
    }

    func personalSuggestionCandidates(
        afterAssetID: UUID?,
        limit: Int,
        sourceIDs _: [UUID]?,
        excludingDecisionsForTagID: UUID?
    ) throws -> [PersonalSuggestionCandidate] {
        lock.withLock {
            let decided = excludingDecisionsForTagID.flatMap { decidedAssetIDsProvider?($0) } ?? []
            let filtered = personalCandidates.filter { !decided.contains($0.assetID) }
            let startIndex = afterAssetID
                .flatMap { id in filtered.firstIndex(where: { $0.assetID == id }) }
                .map { $0 + 1 } ?? 0
            return Array(filtered.dropFirst(startIndex).prefix(limit))
        }
    }

    func activatePersonalSuggestionBundle(
        _ capability: PersonalModelSuggestionCapability
    ) throws {
        lock.withLock { storedActivatedPersonalCapability = capability }
    }

    func replacePersonalSuggestions(
        candidate: PersonalSuggestionCandidate,
        predictions: [PersonalSuggestionPrediction],
        expectedCapability: PersonalModelSuggestionCapability
    ) throws -> Int {
        lock.withLock {
            storedPersonalSuggestionReplacements.append(
                FakePersonalSuggestionReplacement(
                    candidate: candidate,
                    predictions: predictions,
                    expectedCapability: expectedCapability
                )
            )
            return predictions.count
        }
    }

    func replacePersonalTagLibrarySuggestions(
        tagID: UUID,
        hits: [AppPersonalTagLibrarySuggestionHit],
        expectedCapability: PersonalModelSuggestionCapability,
        maximumPendingCount: Int
    ) throws -> Int {
        lock.withLock {
            storedPersonalTagLibraryReplacements.append(
                FakePersonalTagLibraryReplacement(
                    tagID: tagID,
                    hits: hits,
                    expectedCapability: expectedCapability,
                    maximumPendingCount: maximumPendingCount
                )
            )
            return min(hits.count, maximumPendingCount)
        }
    }

    func replaceStandardSuggestions(
        assetID: UUID,
        contentRevision: Int,
        suggestions: [LocalModelSuggestion],
        expectedTarget: StandardModelSuggestionTarget
    ) throws -> Int {
        if standardSuggestionReplacementFails {
            throw PersonalizationReviewError.persistenceFailure
        }
        return lock.withLock {
            storedStandardSuggestionReplacements.append(
                FakeStandardSuggestionReplacement(
                    assetID: assetID,
                    contentRevision: contentRevision,
                    suggestions: suggestions,
                    expectedTarget: expectedTarget
                )
            )
            return suggestions.count
        }
    }

    func invalidateAllPersonalSuggestionBundles() throws {
        lock.withLock {
            storedPersonalSuggestionInvalidationCallCount += 1
            storedActivatedPersonalCapability = nil
            storedPersonalSuggestionReplacements = []
            storedPersonalTagLibraryReplacements = []
        }
    }

    func enqueueFullLibrarySuggestions(
        tagID: UUID,
        mode: PersonalizationReviewEnqueueMode,
        sourceIDs: [UUID]?
    ) throws -> UUID {
        lock.withLock {
            let jobID = UUID()
            enqueueCallCount += 1
            lastEnqueuedSourceIDs = sourceIDs
            if featureCompletion != nil {
                storedFeatureSuggestionJob = FeatureSuggestionJobProjection(
                    id: jobID,
                    state: .pending,
                    candidateCount: 0,
                    aboveThresholdCount: 0,
                    skippedCount: 0
                )
            }
            return jobID
        }
    }

    func featureSuggestionJob(jobID: UUID) throws -> FeatureSuggestionJobProjection? {
        lock.withLock {
            guard storedFeatureSuggestionJob?.id == jobID else { return nil }
            return storedFeatureSuggestionJob
        }
    }

    func enqueuePersonalLibrarySuggestions(
        capability: PersonalModelSuggestionCapability,
        sourceIDs: [UUID]?
    ) throws -> UUID {
        lock.withLock {
            let jobID = UUID()
            lastEnqueuedSourceIDs = sourceIDs
            storedActivatedPersonalCapability = capability
            storedEnqueuedPersonalCapability = capability
            storedPersonalLibraryJob = PersonalLibrarySuggestionJobProjection(
                id: jobID,
                state: .pending,
                checkedCount: 0,
                totalCount: nil,
                suggestedCount: 0,
                skippedCount: 0,
                lastErrorCode: nil
            )
            return jobID
        }
    }

    func enqueueStandardLibrarySuggestions(
        target: StandardModelSuggestionTarget,
        sourceIDs: [UUID]?
    ) throws -> UUID {
        lock.withLock {
            let jobID = UUID()
            lastEnqueuedSourceIDs = sourceIDs
            storedEnqueuedStandardTarget = target
            storedStandardLibraryJob = StandardLibrarySuggestionJobProjection(
                id: jobID,
                state: .pending,
                checkedCount: 0,
                totalCount: nil,
                suggestedCount: 0,
                skippedCount: 0,
                lastErrorCode: nil
            )
            return jobID
        }
    }

    func standardLibrarySuggestionJob() throws -> StandardLibrarySuggestionJobProjection? {
        lock.withLock { storedStandardLibraryJob }
    }

    func personalLibrarySuggestionJob() throws -> PersonalLibrarySuggestionJobProjection? {
        lock.withLock { storedPersonalLibraryJob }
    }

    func pauseSuggestionJob(jobID: UUID) throws {}
    func resumeSuggestionJob(jobID: UUID) throws {}
    func cancelSuggestionJob(jobID: UUID) throws {}

    func runPendingSuggestionJobs(maxSteps: Int?) throws -> Bool {
        let didWork = lock.withLock {
            runPendingJobsCallCount += 1
            guard let featureCompletion,
                  let job = storedFeatureSuggestionJob,
                  !job.state.isTerminal
            else {
                return false
            }
            storedFeatureSuggestionJob = FeatureSuggestionJobProjection(
                id: job.id,
                state: .completed,
                candidateCount: featureCompletion.candidates,
                aboveThresholdCount: featureCompletion.aboveThreshold,
                skippedCount: featureCompletion.skipped
            )
            return true
        }
        if blocksRunPendingJobs {
            _ = pendingJobsBlocker.wait(timeout: .now() + 5)
        }
        return didWork
    }

    func releaseBlockedPendingJobs() {
        pendingJobsBlocker.signal()
    }
}
