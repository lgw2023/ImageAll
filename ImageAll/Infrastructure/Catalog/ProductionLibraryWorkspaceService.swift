import Foundation

enum ProductionLibraryWorkspaceError: Error {
    case reconcileFailed
}

struct ProductionLibraryWorkspaceService: LibraryWorkspacePort, Sendable {
    let sourceRepository: GRDBFolderSourceAuthorizationRepository
    let authorization: any FolderAuthorizationCommandPort
    let queue: GRDBJobQueue
    let executionCoordinator: JobExecutionCoordinator
    let query: GRDBAssetCatalogQueryRepository
    let tags: GRDBTagCatalogRepository
    let derivedImages: any DerivedImageCachePort
    let clock: any JobClock

    func fetchSources() throws -> [LibrarySourceSummary] {
        try sourceRepository.fetchAllFolderSources().map {
            LibrarySourceSummary(id: $0.id, displayName: $0.displayName, state: $0.state)
        }
    }

    func connectFolder() async throws -> ConnectFolderOutcome {
        try await authorization.connectFolder()
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
    }

    func runPendingReconcileJobs() throws {
        let claim = ClaimNextInput(
            owner: "imageall-app-\(UUID().uuidString.lowercased())",
            leaseDurationMs: 60_000
        )
        while let result = try executionCoordinator.claimAndExecuteOnce(claim) {
            guard result.snapshot.state == .completed else {
                throw ProductionLibraryWorkspaceError.reconcileFailed
            }
        }
    }

    func fetchAssetPage(filter: AssetPageFilter, cursor: AssetPageCursor?) throws -> AssetPageResult {
        try query.fetchAssetPage(
            AssetPageRequest(
                filter: filter,
                sort: .newest,
                cursor: cursor,
                limit: 100
            )
        )
    }

    func loadThumbnail(assetID: UUID) async throws -> Data {
        try await derivedImages.loadOrGenerate(
            DerivedImageRequest(
                assetID: assetID,
                variant: .gridRegular,
                persistence: .memoryFallbackAllowed
            )
        ).encodedBytes
    }

    func loadPreview(assetID: UUID) async throws -> Data {
        try await derivedImages.loadOrGenerate(
            DerivedImageRequest(
                assetID: assetID,
                variant: .preview,
                persistence: .memoryFallbackAllowed
            )
        ).encodedBytes
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
}

struct SingleJobHandlerRegistry: JobHandlerRegistry, Sendable {
    let registeredHandler: any JobHandler

    func handler(forKind kind: String) -> (any JobHandler)? {
        registeredHandler.kind == kind ? registeredHandler : nil
    }
}
