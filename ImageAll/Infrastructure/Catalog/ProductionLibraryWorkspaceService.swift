import Foundation

enum ProductionLibraryWorkspaceError: Error {
    case reconcileFailed
}

struct ProductionLibraryWorkspaceService: LibraryWorkspacePort, Sendable {
    let sourceRepository: GRDBFolderSourceAuthorizationRepository
    let authorization: any FolderAuthorizationCommandPort
    let photosConnection: PhotosLibraryConnectionService
    let queue: GRDBJobQueue
    let executionCoordinator: JobExecutionCoordinator
    let query: GRDBAssetCatalogQueryRepository
    let tags: GRDBTagCatalogRepository
    let assetImages: LibraryAssetImageLoader
    let personalizationReview: PersonalizationReviewService
    let clock: any JobClock

    func fetchSources() throws -> [LibrarySourceSummary] {
        try photosConnection.fetchSources()
    }

    func connectFolder() async throws -> ConnectFolderOutcome {
        try await authorization.connectFolder()
    }

    func connectPhotos() async throws -> ConnectPhotosOutcome {
        try await photosConnection.connect()
    }

    func reauthorizeFolder(sourceID: UUID) async throws -> ReauthorizeFolderOutcome {
        try await authorization.reauthorizeFolder(sourceID: sourceID)
    }

    func disableFolderSource(sourceID: UUID) async throws -> DisableFolderOutcome {
        if try photosConnection.fetchSources().first(where: { $0.id == sourceID })?.kind == .photos {
            return try photosConnection.disable(sourceID: sourceID)
        }
        return try await authorization.disableFolderSource(sourceID: sourceID)
    }

    func enqueueReconcile(sourceIDs: [UUID]) throws {
        let requested = Set(sourceIDs)
        for source in try sourceRepository.fetchAllFolderSources()
            where source.state == .active && requested.contains(source.id)
        {
            let command = try FolderReconcileJobFactory.makeEnqueueCommand(
                jobID: UUID(),
                sourceID: source.id,
                notBeforeMs: clock.nowMs
            )
            _ = try queue.enqueue(command)
        }
        for source in try photosConnection.fetchSources()
            where source.kind == .photos && source.state == .active && requested.contains(source.id)
        {
            try photosConnection.enqueueReconcile(sourceID: source.id)
        }
    }

    func runPendingReconcileJobs() throws {
        let claim = ClaimNextInput(
            owner: "imageall-reconcile-\(UUID().uuidString.lowercased())",
            leaseDurationMs: 60_000,
            allowedKinds: [FolderReconcileJobFactory.kind]
        )
        while let result = try executionCoordinator.claimAndExecuteOnce(claim) {
            guard result.snapshot.state == .completed else {
                throw ProductionLibraryWorkspaceError.reconcileFailed
            }
        }
    }

    func runPendingPhotosReconcileJobs() throws {
        let claim = ClaimNextInput(
            owner: "imageall-photos-reconcile-\(UUID().uuidString.lowercased())",
            leaseDurationMs: 60_000,
            allowedKinds: [PhotosReconcileJobFactory.kind]
        )
        while let result = try executionCoordinator.claimAndExecuteOnce(claim) {
            guard result.snapshot.state == .completed else {
                throw ProductionLibraryWorkspaceError.reconcileFailed
            }
        }
    }

    func runPendingPersonalizationJobs() throws {
        _ = try personalizationReview.runPendingSuggestionJobs(maxSteps: nil)
    }

    func fetchAssetPage(
        filter: AssetPageFilter,
        sort: AssetPageSort,
        cursor: AssetPageCursor?
    ) throws -> AssetPageResult {
        try query.fetchAssetPage(
            AssetPageRequest(
                filter: filter,
                sort: sort,
                cursor: cursor,
                limit: 100
            )
        )
    }

    func loadThumbnail(assetID: UUID) async throws -> Data {
        try await assetImages.load(assetID: assetID, variant: .grid)
    }

    func loadPreview(assetID: UUID) async throws -> Data {
        try await assetImages.load(assetID: assetID, variant: .preview)
    }

    func listTags() throws -> [TagListItem] {
        try tags.listTags(includeArchived: false)
    }

    func fetchInspectorDetail(assetID: UUID) throws -> AssetInspectorDetail {
        try query.fetchInspectorDetail(assetID: assetID)
    }

    func selectionAggregate(tagIDs: [UUID], assetIDs: [UUID]) throws -> [TagSelectionAggregate] {
        try tags.selectionAggregate(tagIDs: tagIDs, assetIDs: assetIDs)
    }

    func mutateTag(
        tagID: UUID,
        assetIDs: [UUID],
        action: LibraryTagDecisionAction
    ) throws -> TagMutationPriorStateSnapshot {
        let result: TagMutationResult
        switch action {
        case .accept:
            result = try tags.batchAccept(tagID: tagID, assetIDs: assetIDs, timestampMs: clock.nowMs)
        case .reject:
            result = try tags.batchReject(tagID: tagID, assetIDs: assetIDs, timestampMs: clock.nowMs)
        case .clear:
            result = try tags.batchClear(tagID: tagID, assetIDs: assetIDs, timestampMs: clock.nowMs)
        }
        return TagMutationPriorStateSnapshot(tagID: tagID, priorStates: result.priorStates)
    }

    func restoreTagMutation(_ snapshot: TagMutationPriorStateSnapshot) throws {
        try tags.restorePriorStates(snapshot, timestampMs: clock.nowMs)
    }

    func createTagAndAccept(
        rawName: String,
        assetIDs: [UUID]
    ) throws -> TagCreateAndApplyResult {
        try tags.createTagAndApply(
            rawName: rawName,
            assetIDs: assetIDs,
            decision: .accepted,
            timestampMs: clock.nowMs
        )
    }

    func renameTag(tagID: UUID, rawName: String) throws -> TagListItem {
        let tag = try tags.renameTag(tagID: tagID, rawName: rawName, timestampMs: clock.nowMs)
        return TagListItem(id: tag.id, displayName: tag.displayName, state: tag.state)
    }

    func archiveTag(tagID: UUID) throws {
        _ = try tags.archiveTag(tagID: tagID, timestampMs: clock.nowMs)
    }
}
