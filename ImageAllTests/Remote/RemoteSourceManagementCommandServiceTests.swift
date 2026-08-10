import Foundation
import XCTest
@testable import ImageAll

@MainActor
final class RemoteSourceManagementCommandServiceTests: XCTestCase {
    func testSquarePrewarmReportsProgressCompletesAndReplaysOnce() async throws {
        let workspace = RemoteSourcePrewarmWorkspaceStub(assetCount: 3)
        workspace.failingAssetIDs = [workspace.assetIDs[1]]
        let service = RemoteSourceManagementCommandService(
            workspace: workspace,
            approvalPresenter: RemoteSourceApprovalStub(),
            clock: FixedJobClock(nowMs: 123)
        )
        let command = SourceManagementCommandRequest(
            operationID: UUID(),
            action: .prewarmThumbnails,
            sourceID: workspace.source.id
        )

        let accepted = try await service.submit(command)
        XCTAssertEqual(accepted.phase, .running)
        let terminal = try await waitForTerminalRequest(service, id: accepted.id)

        XCTAssertEqual(terminal.phase, .completed)
        XCTAssertEqual(terminal.completedCount, 3)
        XCTAssertEqual(terminal.totalCount, 3)
        XCTAssertEqual(terminal.warmedCount, 2)
        XCTAssertEqual(terminal.failedCount, 1)
        XCTAssertEqual(workspace.squarePrewarmAssetIDs.count, 3)

        let replay = try await service.submit(command)
        XCTAssertEqual(replay, terminal)
        XCTAssertEqual(workspace.squarePrewarmAssetIDs.count, 3)
    }

    func testOriginalAspectPrewarmSkipsCachedAssetAndCanBeCancelled() async throws {
        let workspace = RemoteSourcePrewarmWorkspaceStub(assetCount: 3)
        workspace.cachedOriginalAssetIDs = [workspace.assetIDs[0]]
        workspace.originalDelayNanoseconds = 2_000_000_000
        let service = RemoteSourceManagementCommandService(
            workspace: workspace,
            approvalPresenter: RemoteSourceApprovalStub(),
            clock: FixedJobClock(nowMs: 456)
        )
        let start = SourceManagementCommandRequest(
            operationID: UUID(),
            action: .prewarmOriginalAspect,
            sourceID: workspace.source.id
        )

        let accepted = try await service.submit(start)
        try await waitForProgress(service, id: accepted.id, total: 2)
        let cancel = SourceManagementCommandRequest(
            operationID: UUID(),
            action: .cancelPrewarm,
            sourceID: workspace.source.id
        )
        let cancelled = try await service.submit(cancel)

        XCTAssertEqual(cancelled.id, accepted.id)
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertEqual(cancelled.totalCount, 2)
        XCTAssertFalse(workspace.originalPrewarmAssetIDs.contains(workspace.assetIDs[0]))

        let replay = try await service.submit(cancel)
        XCTAssertEqual(replay.phase, .cancelled)
        XCTAssertEqual(replay.id, accepted.id)
    }

    func testPhotosWriteAuthorizationCompletesOnlyAfterMacAuthorization() async throws {
        let workspace = RemoteSourcePrewarmWorkspaceStub(assetCount: 0, kind: .photos)
        let service = RemoteSourceManagementCommandService(
            workspace: workspace,
            photosMutation: RemotePhotosMutationAuthorizationStub(state: .authorized),
            approvalPresenter: RemoteSourceApprovalStub(),
            clock: FixedJobClock(nowMs: 789)
        )
        let accepted = try await service.submit(SourceManagementCommandRequest(
            operationID: UUID(),
            action: .requestPhotosWriteAuthorization,
            sourceID: workspace.source.id
        ))

        XCTAssertEqual(accepted.phase, .awaitingMac)
        let terminal = try await waitForTerminalRequest(service, id: accepted.id)
        XCTAssertEqual(terminal.phase, .completed)
        XCTAssertTrue(terminal.message.contains("写入权限"))
    }

    func testPhotosPrivacySettingsOpenOnMacAndReplayOnlyOnce() async throws {
        let workspace = RemoteSourcePrewarmWorkspaceStub(assetCount: 0, kind: .photos)
        let service = RemoteSourceManagementCommandService(
            workspace: workspace,
            approvalPresenter: RemoteSourceApprovalStub(),
            clock: FixedJobClock(nowMs: 790)
        )
        let command = SourceManagementCommandRequest(
            operationID: UUID(),
            action: .openPhotosPrivacySettings,
            sourceID: workspace.source.id
        )

        let accepted = try await service.submit(command)
        XCTAssertEqual(accepted.phase, .awaitingMac)
        let terminal = try await waitForTerminalRequest(service, id: accepted.id)
        XCTAssertEqual(terminal.phase, .completed)
        XCTAssertTrue(terminal.message.contains("照片权限设置"))
        XCTAssertEqual(workspace.photosPrivacySettingsOpenCount, 1)

        let replay = try await service.submit(command)
        XCTAssertEqual(replay, terminal)
        XCTAssertEqual(workspace.photosPrivacySettingsOpenCount, 1)
    }

    func testFolderRecycleAuthorizationCancellationIsReportedWithoutMutation() async throws {
        let workspace = RemoteSourcePrewarmWorkspaceStub(assetCount: 0, kind: .folder)
        let service = RemoteSourceManagementCommandService(
            workspace: workspace,
            mutationAuthorization: RemoteFolderMutationAuthorizationStub(outcome: .cancelled),
            approvalPresenter: RemoteSourceApprovalStub(),
            clock: FixedJobClock(nowMs: 987)
        )
        let accepted = try await service.submit(SourceManagementCommandRequest(
            operationID: UUID(),
            action: .refreshFolderMutationAuthorization,
            sourceID: workspace.source.id
        ))

        XCTAssertEqual(accepted.phase, .awaitingMac)
        let terminal = try await waitForTerminalRequest(service, id: accepted.id)
        XCTAssertEqual(terminal.phase, .cancelled)
        XCTAssertTrue(terminal.message.contains("取消更新回收权限"))
    }

    func testRefreshAllQueuesEveryActiveSourceAndSkipsUnavailableSources() async throws {
        let workspace = RemoteSourceRefreshAllWorkspaceStub()
        let service = RemoteSourceManagementCommandService(
            workspace: workspace,
            approvalPresenter: RemoteSourceApprovalStub(),
            clock: FixedJobClock(nowMs: 1_234)
        )
        let command = SourceManagementCommandRequest(
            operationID: UUID(),
            action: .refreshAll,
            sourceID: nil
        )

        let accepted = try await service.submit(command)
        XCTAssertEqual(accepted.phase, .running)
        XCTAssertEqual(accepted.sourceDisplayName, "全部来源")
        let terminal = try await waitForTerminalRequest(service, id: accepted.id)

        XCTAssertEqual(terminal.phase, .completed)
        XCTAssertTrue(terminal.message.contains("2 个活跃来源"))
        XCTAssertEqual(Set(workspace.enqueuedFolderSourceIDs), Set([workspace.folderSource.id]))
        XCTAssertEqual(Set(workspace.syncedPhotosSourceIDs), Set([workspace.photosSource.id]))
        XCTAssertFalse(workspace.enqueuedFolderSourceIDs.contains(workspace.unavailableSource.id))

        let replay = try await service.submit(command)
        XCTAssertEqual(replay, terminal)
        XCTAssertEqual(workspace.enqueuedFolderSourceIDs.count, 1)
        XCTAssertEqual(workspace.syncedPhotosSourceIDs.count, 1)
    }

    func testAllSourceSquarePrewarmReusesCacheSkipsIneligibleAndReplaysOnce() async throws {
        let workspace = RemoteAllSourcePrewarmWorkspaceStub()
        workspace.cachedSquareAssetIDs = [workspace.firstAssetIDs[0]]
        workspace.failingSquareAssetIDs = [workspace.secondAssetIDs[0]]
        let service = RemoteSourceManagementCommandService(
            workspace: workspace,
            approvalPresenter: RemoteSourceApprovalStub(),
            clock: FixedJobClock(nowMs: 2_000)
        )
        let command = SourceManagementCommandRequest(
            operationID: UUID(),
            action: .prewarmAllThumbnails,
            sourceID: nil
        )

        let accepted = try await service.submit(command)
        XCTAssertEqual(accepted.phase, .running)
        XCTAssertEqual(accepted.sourceDisplayName, "全部来源")
        let terminal = try await waitForTerminalRequest(service, id: accepted.id)

        XCTAssertEqual(terminal.phase, .completed)
        XCTAssertEqual(terminal.completedCount, 4)
        XCTAssertEqual(terminal.totalCount, 4)
        XCTAssertEqual(terminal.warmedCount, 1)
        XCTAssertEqual(terminal.reusedCount, 1)
        XCTAssertEqual(terminal.ineligibleCount, 1)
        XCTAssertEqual(terminal.failedCount, 1)
        XCTAssertEqual(terminal.completedSourceCount, 3)
        XCTAssertEqual(terminal.totalSourceCount, 3)
        XCTAssertTrue(terminal.message.contains("3 个来源"))
        XCTAssertTrue(terminal.message.contains("复用 1"))
        XCTAssertEqual(
            workspace.squarePrewarmAssetIDs,
            [workspace.firstAssetIDs[1], workspace.secondAssetIDs[0]]
        )
        XCTAssertFalse(workspace.squarePrewarmAssetIDs.contains(workspace.unavailableAssetID))
        XCTAssertFalse(workspace.squarePrewarmAssetIDs.contains(workspace.disabledAssetID))

        let replay = try await service.submit(command)
        XCTAssertEqual(replay, terminal)
        XCTAssertEqual(workspace.squarePrewarmAssetIDs.count, 2)
    }

    func testAllSourceOriginalAspectPrewarmSkipsCachedAssets() async throws {
        let workspace = RemoteAllSourcePrewarmWorkspaceStub()
        workspace.cachedOriginalAssetIDs = [
            workspace.firstAssetIDs[0],
            workspace.secondAssetIDs[0],
        ]
        let service = RemoteSourceManagementCommandService(
            workspace: workspace,
            approvalPresenter: RemoteSourceApprovalStub(),
            clock: FixedJobClock(nowMs: 2_100)
        )

        let accepted = try await service.submit(SourceManagementCommandRequest(
            operationID: UUID(),
            action: .prewarmAllOriginalAspect,
            sourceID: nil
        ))
        let terminal = try await waitForTerminalRequest(service, id: accepted.id)

        XCTAssertEqual(terminal.phase, .completed)
        XCTAssertEqual(terminal.warmedCount, 1)
        XCTAssertEqual(terminal.reusedCount, 2)
        XCTAssertEqual(terminal.ineligibleCount, 1)
        XCTAssertEqual(terminal.failedCount, 0)
        XCTAssertEqual(workspace.originalPrewarmAssetIDs, [workspace.firstAssetIDs[1]])
    }

    func testCancelAllSourcePrewarmUsesNilSourceAndStopsRemainingSources() async throws {
        let workspace = RemoteAllSourcePrewarmWorkspaceStub()
        workspace.squareDelayNanoseconds = 2_000_000_000
        let service = RemoteSourceManagementCommandService(
            workspace: workspace,
            approvalPresenter: RemoteSourceApprovalStub(),
            clock: FixedJobClock(nowMs: 2_200)
        )
        let accepted = try await service.submit(SourceManagementCommandRequest(
            operationID: UUID(),
            action: .prewarmAllThumbnails,
            sourceID: nil
        ))
        try await waitForBatchProgress(service, id: accepted.id, totalSources: 3)

        let cancelled = try await service.submit(SourceManagementCommandRequest(
            operationID: UUID(),
            action: .cancelPrewarm,
            sourceID: nil
        ))

        XCTAssertEqual(cancelled.id, accepted.id)
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertNil(cancelled.sourceID)
        XCTAssertTrue(cancelled.message.contains("0/3 个来源"))
        XCTAssertTrue(cancelled.message.contains("已生成的缓存仍会保留"))
        XCTAssertFalse(workspace.squarePrewarmAssetIDs.isEmpty)
        XCTAssertTrue(workspace.squarePrewarmAssetIDs.allSatisfy {
            workspace.firstAssetIDs.contains($0)
        })
    }

    func testBatchAccessAuthorizationProcessesEveryEligibleSource() async throws {
        let workspace = RemoteBatchAuthorizationWorkspaceStub()
        let service = RemoteSourceManagementCommandService(
            workspace: workspace,
            approvalPresenter: RemoteSourceApprovalStub(),
            clock: FixedJobClock(nowMs: 2_300)
        )

        let accepted = try await service.submit(SourceManagementCommandRequest(
            operationID: UUID(),
            action: .reauthorizeAll,
            sourceID: nil
        ))
        XCTAssertEqual(accepted.phase, .awaitingMac)
        XCTAssertEqual(accepted.sourceDisplayName, "全部来源")
        let terminal = try await waitForTerminalRequest(service, id: accepted.id)

        XCTAssertEqual(terminal.phase, .completed)
        XCTAssertEqual(terminal.completedSourceCount, 2)
        XCTAssertEqual(terminal.totalSourceCount, 2)
        XCTAssertEqual(workspace.reauthorizedFolderSourceIDs, [workspace.unavailableFolder.id])
        XCTAssertEqual(workspace.reactivatedPhotosSourceIDs, [workspace.disabledPhotos.id])
        XCTAssertTrue(terminal.message.contains("2 个来源"))
    }

    @MainActor
    func testBatchFolderMutationAuthorizationCompletesEveryActiveFolder() async throws {
        let workspace = RemoteBatchAuthorizationWorkspaceStub()
        let authorization = RemoteSequenceFolderMutationAuthorizationStub(
            authorizes: [true, true]
        )
        let service = RemoteSourceManagementCommandService(
            workspace: workspace,
            mutationAuthorization: authorization,
            approvalPresenter: RemoteSourceApprovalStub(),
            clock: FixedJobClock(nowMs: 2_400)
        )

        let accepted = try await service.submit(SourceManagementCommandRequest(
            operationID: UUID(),
            action: .refreshAllFolderMutationAuthorizations,
            sourceID: nil
        ))
        let terminal = try await waitForTerminalRequest(service, id: accepted.id)

        XCTAssertEqual(terminal.phase, .completed)
        XCTAssertEqual(terminal.completedSourceCount, 2)
        XCTAssertEqual(terminal.totalSourceCount, 2)
        XCTAssertEqual(
            authorization.authorizedSourceIDs,
            [workspace.firstActiveFolder.id, workspace.secondActiveFolder.id]
        )
        XCTAssertTrue(terminal.message.contains("没有立即修改任何照片"))
    }

    @MainActor
    func testBatchFolderMutationAuthorizationStopsAfterMacCancellation() async throws {
        let workspace = RemoteBatchAuthorizationWorkspaceStub()
        let authorization = RemoteSequenceFolderMutationAuthorizationStub(
            authorizes: [true, false]
        )
        let service = RemoteSourceManagementCommandService(
            workspace: workspace,
            mutationAuthorization: authorization,
            approvalPresenter: RemoteSourceApprovalStub(),
            clock: FixedJobClock(nowMs: 2_500)
        )

        let accepted = try await service.submit(SourceManagementCommandRequest(
            operationID: UUID(),
            action: .refreshAllFolderMutationAuthorizations,
            sourceID: nil
        ))
        let terminal = try await waitForTerminalRequest(service, id: accepted.id)

        XCTAssertEqual(terminal.phase, .cancelled)
        XCTAssertEqual(terminal.completedSourceCount, 1)
        XCTAssertEqual(terminal.totalSourceCount, 2)
        XCTAssertEqual(authorization.authorizedSourceIDs.count, 2)
        XCTAssertTrue(terminal.message.contains("完成 1/2 个来源"))
        XCTAssertTrue(terminal.message.contains("没有立即修改任何照片"))
    }

    func testDeleteBlockedByRecyclePublishesMacWorkspaceNotice() async throws {
        let workspace = RemoteSourcePrewarmWorkspaceStub(assetCount: 0)
        let blockers = LibrarySourceDeletionBlockers(
            recycledItemCount: 2,
            discardableAuthorizationFailureCount: 1,
            inspectionRequiredCount: 3
        )
        workspace.deleteError = .unresolvedRecycleEntries(blockers: blockers)
        let noticeRecorder = RemoteWorkspaceNoticeRecorderStub()
        let service = RemoteSourceManagementCommandService(
            workspace: workspace,
            workspaceNoticeRecorder: noticeRecorder,
            approvalPresenter: RemoteSourceApprovalStub(),
            clock: FixedJobClock(nowMs: 2_600)
        )

        let accepted = try await service.submit(SourceManagementCommandRequest(
            operationID: UUID(),
            action: .delete,
            sourceID: workspace.source.id
        ))
        XCTAssertEqual(accepted.phase, .awaitingMac)

        let terminal = try await waitForTerminalRequest(service, id: accepted.id)
        XCTAssertEqual(terminal.phase, .failed)
        XCTAssertTrue(terminal.message.contains("6 条回收记录"))
        XCTAssertEqual(workspace.deletedSourceIDs, [])
        let recorded = await noticeRecorder.snapshot()
        XCTAssertEqual(recorded?.sourceID, workspace.source.id)
        XCTAssertEqual(recorded?.displayName, workspace.source.displayName)
        XCTAssertEqual(recorded?.blockers, blockers)
    }

    private func waitForProgress(
        _ service: RemoteSourceManagementCommandService,
        id: UUID,
        total: Int
    ) async throws {
        for _ in 0..<200 {
            let request = try await service.snapshot().requests.first(where: { $0.id == id })
            if request?.totalCount == total { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for source prewarm progress")
    }

    @MainActor
    private func waitForTerminalRequest(
        _ service: RemoteSourceManagementCommandService,
        id: UUID
    ) async throws -> SourceManagementCommandRequestSnapshot {
        for _ in 0..<200 {
            let snapshot = try await service.snapshot()
            if let request = snapshot.requests.first(where: { $0.id == id }),
               ![.awaitingMac, .running].contains(request.phase) {
                return request
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let snapshot = try await service.snapshot()
        return try XCTUnwrap(snapshot.requests.first(where: { $0.id == id }))
    }

    private func waitForBatchProgress(
        _ service: RemoteSourceManagementCommandService,
        id: UUID,
        totalSources: Int
    ) async throws {
        for _ in 0..<200 {
            let request = try await service.snapshot().requests.first(where: { $0.id == id })
            if request?.totalSourceCount == totalSources,
               request?.totalCount != nil {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for all-source prewarm progress")
    }
}

@MainActor
final class RemoteLibrarySlimmingSourceMaintenanceServiceTests: XCTestCase {
    func testRefreshCatalogAcceptsOnlyActiveSubsetAndStartsBothRunners() async throws {
        let workspace = RemoteSlimmingMaintenanceWorkspaceStub()
        let service = makeService(workspace: workspace)

        let setup = try await service.setup(mediaKind: .image)
        XCTAssertEqual(Set(setup.sources.map(\.id)), Set(workspace.activeSources.map(\.id)))
        XCTAssertTrue(setup.sourceSimilarityIndexAvailable)

        _ = try await service.maintainSources(
            LibrarySlimmingSourceMaintenanceCommand(
                action: .refreshCatalog,
                mediaKind: .image,
                sourceIDs: [
                    workspace.activeSources[1].id,
                    workspace.activeSources[0].id,
                    workspace.activeSources[0].id,
                ]
            )
        )
        await waitUntil {
            workspace.folderRunnerCount == 1 && workspace.photosRunnerCount == 1
        }
        XCTAssertEqual(Set(workspace.enqueuedSourceIDs), Set(workspace.activeSources.map(\.id)))

        do {
            _ = try await service.maintainSources(
                LibrarySlimmingSourceMaintenanceCommand(
                    action: .refreshCatalog,
                    mediaKind: .image,
                    sourceIDs: [workspace.unavailableSource.id]
                )
            )
            XCTFail("Unavailable sources must be rejected")
        } catch {
            XCTAssertEqual(error as? LibrarySlimmingCommandError, .invalidSelection)
        }
    }

    func testInitializeSourceIndexRequiresOneActiveSourceAndPublishesReadyStatus() async throws {
        let workspace = RemoteSlimmingMaintenanceWorkspaceStub()
        let index = RemoteSlimmingSourceIndexStub()
        let service = makeService(workspace: workspace, sourceIndex: index)
        let sourceID = workspace.activeSources[0].id

        do {
            _ = try await service.maintainSources(
                LibrarySlimmingSourceMaintenanceCommand(
                    action: .initializeSimilarityIndex,
                    mediaKind: .video,
                    sourceIDs: workspace.activeSources.map(\.id)
                )
            )
            XCTFail("Index initialization must target exactly one source")
        } catch {
            XCTAssertEqual(error as? LibrarySlimmingCommandError, .invalidSelection)
        }

        _ = try await service.maintainSources(
            LibrarySlimmingSourceMaintenanceCommand(
                action: .initializeSimilarityIndex,
                mediaKind: .video,
                sourceIDs: [sourceID]
            )
        )
        await waitUntil { index.runCount == 1 }
        let setup = try await service.setup(mediaKind: .video)
        XCTAssertEqual(index.enqueuedSourceIDs, [sourceID])
        XCTAssertEqual(setup.sourceSimilarityIndexStatuses[sourceID]?.state, .ready)
        XCTAssertEqual(setup.sourceSimilarityIndexStatuses[sourceID]?.mediaKind, .video)
    }

    private func makeService(
        workspace: RemoteSlimmingMaintenanceWorkspaceStub,
        sourceIndex: RemoteSlimmingSourceIndexStub = RemoteSlimmingSourceIndexStub()
    ) -> RemoteLibrarySlimmingCommandService {
        RemoteLibrarySlimmingCommandService(
            catalog: workspace,
            workspace: workspace,
            analysis: RemoteSlimmingAnalysisStub(),
            thresholds: RemoteSlimmingThresholdStoreStub(),
            sourceSimilarityIndex: sourceIndex,
            recycle: RemoteSlimmingRecycleStub(),
            mutationAuthorization: RemoteFolderMutationAuthorizationStub(outcome: .cancelled),
            photosMutation: RemotePhotosMutationAuthorizationStub(state: .authorized),
            approvalPresenter: RemoteSlimmingApprovalStub(),
            clock: FixedJobClock(nowMs: 456)
        )
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<100 where !predicate() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate())
    }
}

private final class RemoteSourceRefreshAllWorkspaceStub:
    RemoteSourceManagementWorkspacePort,
    @unchecked Sendable
{
    private let lock = NSLock()
    let folderSource = LibrarySourceSummary(
        id: UUID(),
        kind: .folder,
        displayName: "Synthetic Folder",
        state: .active
    )
    let photosSource = LibrarySourceSummary(
        id: UUID(),
        kind: .photos,
        displayName: "Synthetic Photos",
        state: .active
    )
    let unavailableSource = LibrarySourceSummary(
        id: UUID(),
        kind: .folder,
        displayName: "Offline Archive",
        state: .unavailable
    )
    private var storedEnqueuedFolderSourceIDs: [UUID] = []
    private var storedSyncedPhotosSourceIDs: [UUID] = []

    var enqueuedFolderSourceIDs: [UUID] {
        lock.withLock { storedEnqueuedFolderSourceIDs }
    }

    var syncedPhotosSourceIDs: [UUID] {
        lock.withLock { storedSyncedPhotosSourceIDs }
    }

    func fetchSources() throws -> [LibrarySourceSummary] {
        [folderSource, photosSource, unavailableSource]
    }

    func enqueueReconcile(sourceIDs: [UUID]) throws {
        lock.withLock { storedEnqueuedFolderSourceIDs.append(contentsOf: sourceIDs) }
    }

    func syncPhotosLibrary(sourceID: UUID) async throws {
        lock.withLock { storedSyncedPhotosSourceIDs.append(sourceID) }
    }
}

private final class RemoteSourcePrewarmWorkspaceStub:
    RemoteSourceManagementWorkspacePort,
    @unchecked Sendable
{
    private let lock = NSLock()
    let source: LibrarySourceSummary
    let assetIDs: [UUID]
    var failingAssetIDs = Set<UUID>()
    var cachedOriginalAssetIDs = Set<UUID>()
    var deleteError: DeleteLibrarySourceError?
    var originalDelayNanoseconds: UInt64 = 0
    private var storedSquarePrewarmAssetIDs: [UUID] = []
    private var storedOriginalPrewarmAssetIDs: [UUID] = []
    private var storedPhotosPrivacySettingsOpenCount = 0
    private var storedDeletedSourceIDs: [UUID] = []

    init(assetCount: Int, kind: SourceKind = .folder) {
        source = LibrarySourceSummary(
            id: UUID(),
            kind: kind,
            displayName: kind == .photos ? "Synthetic Photos" : "Synthetic Archive",
            state: .active
        )
        assetIDs = (0..<assetCount).map { _ in UUID() }
    }

    var squarePrewarmAssetIDs: [UUID] {
        lock.withLock { storedSquarePrewarmAssetIDs }
    }

    var originalPrewarmAssetIDs: [UUID] {
        lock.withLock { storedOriginalPrewarmAssetIDs }
    }

    var photosPrivacySettingsOpenCount: Int {
        lock.withLock { storedPhotosPrivacySettingsOpenCount }
    }

    var deletedSourceIDs: [UUID] {
        lock.withLock { storedDeletedSourceIDs }
    }

    func fetchSources() throws -> [LibrarySourceSummary] {
        [source]
    }

    @MainActor
    func openPhotosPrivacySettings() -> Bool {
        lock.withLock { storedPhotosPrivacySettingsOpenCount += 1 }
        return true
    }

    func fetchAssetPage(
        filter: AssetPageFilter,
        sort _: AssetPageSort,
        cursor _: AssetPageCursor?
    ) throws -> AssetPageResult {
        XCTAssertEqual(filter.sourceIDs, [source.id])
        return AssetPageResult(
            items: assetIDs.enumerated().map { index, assetID in
                AssetGridItemProjection(
                    assetID: assetID,
                    sourceID: source.id,
                    sourceDisplayName: source.displayName,
                    sourceState: source.state,
                    relativePath: "synthetic-\(index).jpg",
                    fileName: "synthetic-\(index).jpg",
                    mediaType: "public.jpeg",
                    mediaCreatedAtMs: nil,
                    mediaModifiedAtMs: nil,
                    width: 1200,
                    height: 900,
                    availability: .available,
                    contentRevision: 1,
                    acceptedTagCount: 0,
                    rejectedTagCount: 0
                )
            },
            nextCursor: nil
        )
    }

    func loadThumbnail(assetID: UUID) async throws -> Data {
        lock.withLock { storedSquarePrewarmAssetIDs.append(assetID) }
        if failingAssetIDs.contains(assetID) {
            throw SourceManagementCommandError.unavailable
        }
        return Data([0xFF, 0xD8, 0xFF])
    }

    func deleteLibrarySource(sourceID: UUID) async throws -> DeleteLibrarySourceOutcome {
        if let deleteError { throw deleteError }
        lock.withLock { storedDeletedSourceIDs.append(sourceID) }
        return DeleteLibrarySourceOutcome(sourceID: sourceID, deletedAssetCount: assetIDs.count)
    }

    func cachedOriginalAspectThumbnailAssetIDs(sourceID: UUID) async throws -> Set<UUID> {
        XCTAssertEqual(sourceID, source.id)
        return cachedOriginalAssetIDs
    }

    func prewarmOriginalAspectThumbnail(assetID: UUID) async throws -> Data {
        lock.withLock { storedOriginalPrewarmAssetIDs.append(assetID) }
        if originalDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: originalDelayNanoseconds)
        }
        return Data([0xFF, 0xD8, 0xFF])
    }
}

private actor RemoteWorkspaceNoticeRecorderStub: RemoteWorkspaceNoticeRecording {
    struct Record: Equatable, Sendable {
        let sourceID: UUID
        let displayName: String
        let blockers: LibrarySourceDeletionBlockers
    }

    private var record: Record?

    func recordSourceDeletionBlocked(
        sourceID: UUID,
        displayName: String,
        blockers: LibrarySourceDeletionBlockers
    ) async {
        record = Record(
            sourceID: sourceID,
            displayName: displayName,
            blockers: blockers
        )
    }

    func snapshot() -> Record? { record }
}

private final class RemoteAllSourcePrewarmWorkspaceStub:
    RemoteSourceManagementWorkspacePort,
    @unchecked Sendable
{
    private let lock = NSLock()
    let firstSource = LibrarySourceSummary(
        id: UUID(),
        kind: .folder,
        displayName: "First",
        state: .active
    )
    let secondSource = LibrarySourceSummary(
        id: UUID(),
        kind: .photos,
        displayName: "Second",
        state: .active
    )
    let unavailableSource = LibrarySourceSummary(
        id: UUID(),
        kind: .folder,
        displayName: "Offline",
        state: .unavailable
    )
    let disabledSource = LibrarySourceSummary(
        id: UUID(),
        kind: .folder,
        displayName: "Disabled",
        state: .disabled
    )
    let firstAssetIDs = [UUID(), UUID()]
    let secondAssetIDs = [UUID()]
    let unavailableAssetID = UUID()
    let disabledAssetID = UUID()
    var cachedSquareAssetIDs = Set<UUID>()
    var cachedOriginalAssetIDs = Set<UUID>()
    var failingSquareAssetIDs = Set<UUID>()
    var squareDelayNanoseconds: UInt64 = 0
    private var storedSquarePrewarmAssetIDs: [UUID] = []
    private var storedOriginalPrewarmAssetIDs: [UUID] = []

    var squarePrewarmAssetIDs: [UUID] {
        lock.withLock { storedSquarePrewarmAssetIDs }
    }

    var originalPrewarmAssetIDs: [UUID] {
        lock.withLock { storedOriginalPrewarmAssetIDs }
    }

    func fetchSources() throws -> [LibrarySourceSummary] {
        [firstSource, secondSource, unavailableSource, disabledSource]
    }

    func fetchAssetPage(
        filter: AssetPageFilter,
        sort _: AssetPageSort,
        cursor _: AssetPageCursor?
    ) throws -> AssetPageResult {
        let sourceIDs = try XCTUnwrap(filter.sourceIDs)
        XCTAssertEqual(sourceIDs.count, 1)
        let sourceID = try XCTUnwrap(sourceIDs.first)
        let source = try XCTUnwrap(fetchSources().first(where: { $0.id == sourceID }))
        let assetIDs: [UUID] = switch sourceID {
        case firstSource.id: firstAssetIDs
        case secondSource.id: secondAssetIDs
        case unavailableSource.id: [unavailableAssetID]
        case disabledSource.id: [disabledAssetID]
        default: []
        }
        return AssetPageResult(
            items: assetIDs.enumerated().map { index, assetID in
                AssetGridItemProjection(
                    assetID: assetID,
                    sourceID: source.id,
                    sourceDisplayName: source.displayName,
                    sourceState: source.state,
                    relativePath: "synthetic-\(index).jpg",
                    fileName: "synthetic-\(index).jpg",
                    mediaType: "public.jpeg",
                    mediaCreatedAtMs: nil,
                    mediaModifiedAtMs: nil,
                    width: 1200,
                    height: 900,
                    availability: .available,
                    contentRevision: 1,
                    acceptedTagCount: 0,
                    rejectedTagCount: 0
                )
            },
            nextCursor: nil
        )
    }

    func cachedSquareThumbnailAssetIDs(sourceID _: UUID) async throws -> Set<UUID> {
        cachedSquareAssetIDs
    }

    func cachedOriginalAspectThumbnailAssetIDs(sourceID _: UUID) async throws -> Set<UUID> {
        cachedOriginalAssetIDs
    }

    func loadThumbnail(assetID: UUID) async throws -> Data {
        lock.withLock { storedSquarePrewarmAssetIDs.append(assetID) }
        if squareDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: squareDelayNanoseconds)
        }
        if failingSquareAssetIDs.contains(assetID) {
            throw SourceManagementCommandError.unavailable
        }
        return Data([0xFF, 0xD8, 0xFF])
    }

    func prewarmOriginalAspectThumbnail(assetID: UUID) async throws -> Data {
        lock.withLock { storedOriginalPrewarmAssetIDs.append(assetID) }
        return Data([0xFF, 0xD8, 0xFF])
    }
}

private final class RemoteBatchAuthorizationWorkspaceStub:
    RemoteSourceManagementWorkspacePort,
    @unchecked Sendable
{
    private let lock = NSLock()
    let unavailableFolder = LibrarySourceSummary(
        id: UUID(),
        kind: .folder,
        displayName: "Unavailable Folder",
        state: .unavailable
    )
    let disabledPhotos = LibrarySourceSummary(
        id: UUID(),
        kind: .photos,
        displayName: "Disabled Photos",
        state: .disabled
    )
    let firstActiveFolder = LibrarySourceSummary(
        id: UUID(),
        kind: .folder,
        displayName: "First Active Folder",
        state: .active
    )
    let secondActiveFolder = LibrarySourceSummary(
        id: UUID(),
        kind: .folder,
        displayName: "Second Active Folder",
        state: .active
    )
    private var storedReauthorizedFolderSourceIDs: [UUID] = []
    private var storedReactivatedPhotosSourceIDs: [UUID] = []

    var reauthorizedFolderSourceIDs: [UUID] {
        lock.withLock { storedReauthorizedFolderSourceIDs }
    }

    var reactivatedPhotosSourceIDs: [UUID] {
        lock.withLock { storedReactivatedPhotosSourceIDs }
    }

    func fetchSources() throws -> [LibrarySourceSummary] {
        [unavailableFolder, disabledPhotos, firstActiveFolder, secondActiveFolder]
    }

    func reauthorizeFolder(sourceID: UUID) async throws -> ReauthorizeFolderOutcome {
        lock.withLock { storedReauthorizedFolderSourceIDs.append(sourceID) }
        return .reauthorized(sourceID: sourceID)
    }

    func reactivatePhotosLibrary(sourceID: UUID) async throws {
        lock.withLock { storedReactivatedPhotosSourceIDs.append(sourceID) }
    }
}

private struct RemoteSourceApprovalStub: RemoteSourceNativeApprovalPresenting {
    @MainActor
    func confirm(_: RemoteSourceNativeApproval) -> Bool { true }
}

private struct RemoteFolderMutationAuthorizationStub: FolderMutationAuthorizationPort {
    let outcome: FolderMutationAuthorizationOutcome

    @MainActor
    func authorizeMutation(sourceID _: UUID) async throws -> FolderMutationAuthorizationOutcome {
        outcome
    }
}

private final class RemoteSequenceFolderMutationAuthorizationStub:
    FolderMutationAuthorizationPort,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var authorizes: [Bool]
    private var storedAuthorizedSourceIDs: [UUID] = []

    init(authorizes: [Bool]) {
        self.authorizes = authorizes
    }

    var authorizedSourceIDs: [UUID] {
        lock.withLock { storedAuthorizedSourceIDs }
    }

    @MainActor
    func authorizeMutation(sourceID: UUID) async throws -> FolderMutationAuthorizationOutcome {
        lock.withLock {
            storedAuthorizedSourceIDs.append(sourceID)
            let authorizesCurrent = authorizes.isEmpty ? true : authorizes.removeFirst()
            return authorizesCurrent ? .authorized(sourceID: sourceID) : .cancelled
        }
    }
}

private struct RemotePhotosMutationAuthorizationStub: PhotosLibraryMutationPort {
    let state: PhotosAuthorizationState

    func authorizationState() -> PhotosAuthorizationState { state }
    func requestAuthorization() async -> PhotosAuthorizationState { state }

    func moveToRecentlyDeleted(localIdentifiers _: [String]) throws -> [String] { [] }
    func presence(localIdentifier _: String) throws -> PhotosAssetPresence { .missing }
    func presences(localIdentifiers: [String]) throws -> [String: PhotosAssetPresence] {
        Dictionary(uniqueKeysWithValues: localIdentifiers.map { ($0, .missing) })
    }
}

private final class RemoteSlimmingMaintenanceWorkspaceStub:
    RemoteCatalogServing,
    RemoteSourceManagementWorkspacePort,
    @unchecked Sendable
{
    private let lock = NSLock()
    let activeSources = [
        LibrarySourceSummary(
            id: UUID(uuidString: "71000000-0000-0000-0000-000000000001")!,
            kind: .folder,
            displayName: "Folder",
            state: .active
        ),
        LibrarySourceSummary(
            id: UUID(uuidString: "71000000-0000-0000-0000-000000000002")!,
            kind: .photos,
            displayName: "Photos",
            state: .active
        ),
    ]
    let unavailableSource = LibrarySourceSummary(
        id: UUID(uuidString: "71000000-0000-0000-0000-000000000003")!,
        kind: .folder,
        displayName: "Unavailable",
        state: .unavailable
    )
    private var storedEnqueuedSourceIDs: [UUID] = []
    private var storedFolderRunnerCount = 0
    private var storedPhotosRunnerCount = 0

    var enqueuedSourceIDs: [UUID] { lock.withLock { storedEnqueuedSourceIDs } }
    var folderRunnerCount: Int { lock.withLock { storedFolderRunnerCount } }
    var photosRunnerCount: Int { lock.withLock { storedPhotosRunnerCount } }

    func fetchSources() throws -> [LibrarySourceSummary] {
        activeSources + [unavailableSource]
    }

    func enqueueReconcile(sourceIDs: [UUID]) throws {
        lock.withLock { storedEnqueuedSourceIDs = sourceIDs }
    }

    func runPendingReconcileJobs(sourceIDs _: Set<UUID>?) throws {
        lock.withLock { storedFolderRunnerCount += 1 }
    }

    func runPendingPhotosReconcileJobs(sourceIDs _: Set<UUID>?) throws {
        lock.withLock { storedPhotosRunnerCount += 1 }
    }

    func listTags() throws -> [TagListItem] { [] }

    func fetchAssetPage(
        filter _: AssetPageFilter,
        sort _: AssetPageSort,
        cursor _: AssetPageCursor?,
        limit _: Int
    ) throws -> AssetPageResult {
        throw CatalogQueryError.notFound
    }

    func loadThumbnail(assetID _: UUID) async throws -> Data {
        throw CatalogQueryError.notFound
    }

    func loadOriginalAspectThumbnailIfCached(assetID _: UUID) async throws -> Data? {
        nil
    }

    func loadPreview(assetID _: UUID) async throws -> Data {
        throw CatalogQueryError.notFound
    }

    func fetchInspectorDetail(assetID _: UUID) throws -> AssetInspectorDetail {
        throw CatalogQueryError.notFound
    }

    func selectionAggregate(
        tagIDs _: [UUID],
        assetIDs _: [UUID]
    ) throws -> [TagSelectionAggregate] {
        throw CatalogQueryError.notFound
    }

    func mutateTag(
        tagID _: UUID,
        assetIDs _: [UUID],
        action _: LibraryTagDecisionAction
    ) throws -> TagMutationPriorStateSnapshot {
        throw CatalogQueryError.notFound
    }

    func createTagAndAccept(
        rawName _: String,
        assetIDs _: [UUID]
    ) throws -> TagCreateAndApplyResult {
        throw CatalogQueryError.notFound
    }

    func fetchJobActivity() throws -> [JobActivityItem] { [] }

    func applyJobActivityAction(_ action: JobActivityAction, jobID: UUID) throws {
        _ = action
        _ = jobID
    }
}

private final class RemoteSlimmingSourceIndexStub:
    SourceSimilarityIndexPort,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var statuses: [UUID: SourceSimilarityIndexStatus] = [:]
    private var storedEnqueuedSourceIDs: [UUID] = []
    private var storedRunCount = 0

    var enqueuedSourceIDs: [UUID] { lock.withLock { storedEnqueuedSourceIDs } }
    var runCount: Int { lock.withLock { storedRunCount } }

    func status(sourceID: UUID) throws -> SourceSimilarityIndexStatus? {
        lock.withLock { statuses[sourceID] }
    }

    func enqueueBuild(sourceID: UUID) throws -> UUID {
        try enqueueBuild(sourceID: sourceID, mediaKind: .image)
    }

    func enqueueBuild(sourceID: UUID, mediaKind: MediaKind) throws -> UUID {
        lock.withLock {
            storedEnqueuedSourceIDs.append(sourceID)
            statuses[sourceID] = SourceSimilarityIndexStatus(
                sourceID: sourceID,
                mediaKind: mediaKind,
                state: .building,
                assetCount: 20,
                indexedCount: 0,
                clusterCount: 0,
                pendingCount: 20,
                updatedAtMs: 100,
                lastError: nil
            )
        }
        return UUID()
    }

    func runPending() throws {
        lock.withLock {
            storedRunCount += 1
            for (sourceID, status) in statuses {
                statuses[sourceID] = SourceSimilarityIndexStatus(
                    sourceID: sourceID,
                    mediaKind: status.mediaKind,
                    state: .ready,
                    assetCount: status.assetCount,
                    indexedCount: status.assetCount,
                    clusterCount: 4,
                    pendingCount: 0,
                    updatedAtMs: 200,
                    lastError: nil
                )
            }
        }
    }

    func candidateAssetIDs(
        seedAssetIDs _: [UUID],
        universeAssetIDs _: [UUID]
    ) throws -> SourceSimilarityCandidatePlan {
        .fullUniverse
    }
}

private final class RemoteSlimmingThresholdStoreStub:
    NearDuplicateSceneThresholdWriting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var value = NearDuplicateSceneThresholds.factory

    func thresholds() -> NearDuplicateSceneThresholds { lock.withLock { value } }
    func setThresholds(_ thresholds: NearDuplicateSceneThresholds) {
        lock.withLock { value = thresholds }
    }
    func resetToFactory() { lock.withLock { value = .factory } }
}

private struct RemoteSlimmingAnalysisStub: LibrarySlimmingAnalysisJobPort {
    func enqueue(
        mode _: LibrarySlimmingAnalyzeMode,
        assetIDs _: [UUID],
        seedAssetIDs _: [UUID]
    ) throws -> LibrarySlimmingAnalysisJobSnapshot {
        throw LibrarySlimmingCommandError.unavailable
    }
    func runPending() throws {}
    func pause(jobID _: UUID) throws -> LibrarySlimmingAnalysisJobSnapshot {
        throw LibrarySlimmingCommandError.jobNotFound
    }
    func resume(jobID _: UUID) throws -> LibrarySlimmingAnalysisJobSnapshot {
        throw LibrarySlimmingCommandError.jobNotFound
    }
    func snapshot(jobID _: UUID) throws -> LibrarySlimmingAnalysisJobSnapshot {
        throw LibrarySlimmingCommandError.jobNotFound
    }
    func latestActiveOrCompleted() throws -> LibrarySlimmingAnalysisJobSnapshot? { nil }
    func listJobs() throws -> [LibrarySlimmingAnalysisJobSummary] { [] }
    func delete(jobID _: UUID) throws {}
}

private struct RemoteSlimmingRecycleStub: LibrarySlimmingRecyclePort {
    func moveAssetsToRecycle(assetIDs _: [UUID]) throws -> LibrarySlimmingRecycleMoveOutcome {
        throw LibrarySlimmingRecycleError.invalidState
    }
    func listRecycledEntries() throws -> [RecycleEntryRecord] { [] }
    func restore(entryID _: UUID) throws { throw LibrarySlimmingRecycleError.invalidState }
    func purgeNow(entryID _: UUID) throws { throw LibrarySlimmingRecycleError.invalidState }
    func purgeExpired(nowMs _: Int64) throws -> Int { 0 }
    func enqueuePurgeExpired() throws {}
    func recoverInterruptedOperations() throws -> Int { 0 }
    func reconcilePhotosRecycleEntries() throws -> Int { 0 }
    func slimmingHiddenAssetIDs(from _: [UUID]) throws -> Set<UUID> { [] }
    func restoredAssetReplacements(from _: [UUID]) throws -> [UUID: UUID] { [:] }
}

private struct RemoteSlimmingApprovalStub: RemoteLibrarySlimmingNativeApprovalPresenting {
    @MainActor
    func confirm(_: RemoteLibrarySlimmingNativeApproval) -> Bool { false }
}
