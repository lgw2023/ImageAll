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

    func fetchAssetPage(sourceID: UUID?, cursor: AssetPageCursor?) throws -> AssetPageResult {
        try query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(sourceIDs: sourceID.map { [$0] } ?? []),
                sort: .newest,
                cursor: cursor,
                limit: 100
            )
        )
    }

    func loadThumbnail(assetID: UUID) async throws -> Data {
        try await derivedImages.loadOrGenerate(
            DerivedImageRequest(assetID: assetID, variant: .gridRegular)
        ).encodedBytes
    }
}

struct SingleJobHandlerRegistry: JobHandlerRegistry, Sendable {
    let registeredHandler: any JobHandler

    func handler(forKind kind: String) -> (any JobHandler)? {
        registeredHandler.kind == kind ? registeredHandler : nil
    }
}
