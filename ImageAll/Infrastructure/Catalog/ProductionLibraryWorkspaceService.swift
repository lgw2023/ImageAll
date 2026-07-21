import Foundation
import GRDB

enum ProductionLibraryWorkspaceError: Error {
    case reconcileFailed
}

struct ProductionLibraryWorkspaceService: LibraryWorkspacePort, Sendable {
    let sourceRepository: GRDBFolderSourceAuthorizationRepository
    let folderSourceMonitor: FolderSourceMonitoringCoordinator
    let photosSourceMonitor: PhotosLibraryChangeObserverCoordinator
    let authorization: any FolderAuthorizationCommandPort
    let photosConnection: PhotosLibraryConnectionService
    let queue: GRDBJobQueue
    let executionCoordinator: JobExecutionCoordinator
    let query: GRDBAssetCatalogQueryRepository
    let tags: GRDBTagCatalogRepository
    let assetImages: LibraryAssetImageLoader
    let personalizationReview: PersonalizationReviewService
    let derivedImageCache: DerivedImageCacheService
    let portableExportDestinationPicker: any PortableExportDestinationPicking
    let portableExportSourceIsolation: PortableExportSourceIsolationValidator
    let portableExporter: PortableCatalogExporter
    let appVersion: String
    let clock: any JobClock

    func startCatalogSourceMonitoring(onChange: @escaping @Sendable () -> Void) throws {
        try folderSourceMonitor.start(onChange: onChange)
        photosSourceMonitor.start(onChange: onChange)
    }

    func stopCatalogSourceMonitoring() {
        folderSourceMonitor.stop()
        photosSourceMonitor.stop()
    }

    @MainActor
    func choosePortableExportDirectory() -> URL? {
        portableExportDestinationPicker.chooseParentDirectory()
    }

    func exportPortableUserData(to parentDirectoryURL: URL) throws -> PortableCatalogExportResult {
        try portableExportSourceIsolation.validate(parentDirectoryURL: parentDirectoryURL)
        let createdAtMs = clock.nowMs
        return try portableExporter.export(
            PortableCatalogExportRequest(
                parentDirectoryURL: parentDirectoryURL,
                bundleName: PortableExportBundleNamer.bundleName(createdAtMs: createdAtMs),
                createdAtMs: createdAtMs,
                appVersion: appVersion
            )
        )
    }

    func fetchPreviewCacheUsage() throws -> DerivedImageCacheUsage {
        try derivedImageCache.cacheUsage()
    }

    func clearPreviewCache() async throws -> DerivedImageCacheClearResult {
        try await derivedImageCache.clearCache()
    }

    func fetchJobActivity() throws -> [JobActivityItem] {
        try queue.fetchActivityItems()
    }

    func applyJobActivityAction(_ action: JobActivityAction, jobID: UUID) throws {
        let operation: JobStateCommand.Operation
        switch action {
        case .pause:
            operation = .pause
        case .resume:
            operation = .resume(notBeforeMs: clock.nowMs)
        case .cancel:
            operation = .cancel
        }
        _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: operation))
    }

    func fetchSources() throws -> [LibrarySourceSummary] {
        try photosConnection.fetchSources()
    }

    func connectFolder() async throws -> ConnectFolderOutcome {
        let outcome = try await authorization.connectFolder()
        try folderSourceMonitor.synchronize()
        return outcome
    }

    func connectPhotos() async throws -> ConnectPhotosOutcome {
        try await photosConnection.connect()
    }

    func syncPhotosLibrary(sourceID: UUID) async throws {
        try photosConnection.syncNow(sourceID: sourceID)
    }

    func requestPhotosFullRepair(sourceID: UUID) async throws {
        try photosConnection.requestFullRepair(sourceID: sourceID)
    }

    func photosLibrarySupportedImageCount() throws -> Int {
        try photosConnection.supportedStaticImageCount()
    }

    func photosCatalogAssetCount(sourceID: UUID) throws -> Int {
        try query.fetchPhotosCatalogAssetCount(sourceID: sourceID)
    }

    func reactivatePhotosLibrary(sourceID: UUID) async throws {
        try photosConnection.reactivate(sourceID: sourceID)
    }

    func rebindPhotos(unavailableSourceID: UUID) async throws -> RebindPhotosOutcome {
        try await photosConnection.rebind(unavailableSourceID: unavailableSourceID)
    }

    func reauthorizeFolder(sourceID: UUID) async throws -> ReauthorizeFolderOutcome {
        let outcome = try await authorization.reauthorizeFolder(sourceID: sourceID)
        try folderSourceMonitor.synchronize()
        return outcome
    }

    func disableFolderSource(sourceID: UUID) async throws -> DisableFolderOutcome {
        if try photosConnection.fetchSources().first(where: { $0.id == sourceID })?.kind == .photos {
            return try photosConnection.disable(sourceID: sourceID)
        }
        let outcome = try await authorization.disableFolderSource(sourceID: sourceID)
        try folderSourceMonitor.synchronize()
        return outcome
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

    func fetchCatalogReconcileProgress() throws -> CatalogReconcileProgress? {
        try queue.database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT job.kind, job.progress_completed, job.progress_total,
                       source.display_name
                FROM job
                LEFT JOIN source ON source.id = job.source_id
                WHERE job.kind IN (?, ?)
                    AND job.state IN ('pending', 'running')
                ORDER BY
                    CASE job.state WHEN 'running' THEN 0 ELSE 1 END,
                    CASE job.kind WHEN ? THEN 0 ELSE 1 END,
                    job.priority DESC,
                    job.created_at_ms ASC
                LIMIT 1
                """,
                arguments: [
                    FolderReconcileJobFactory.kind,
                    PhotosReconcileJobFactory.kind,
                    FolderReconcileJobFactory.kind,
                ]
            ) else {
                return nil
            }
            let kind: String = row["kind"]
            return CatalogReconcileProgress(
                sourceKind: kind == PhotosReconcileJobFactory.kind ? .photos : .folder,
                sourceDisplayName: row["display_name"],
                completed: row["progress_completed"],
                total: row["progress_total"]
            )
        }
    }

    func runPendingReconcileJobs() throws {
        defer { try? folderSourceMonitor.synchronize() }
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

    func downloadCloudPreview(
        assetID: UUID,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        try await assetImages.downloadCloudPreview(assetID: assetID, onProgress: onProgress)
    }

    func listTags() throws -> [TagListItem] {
        try tags.listTags(includeArchived: false)
    }

    func installPresetTags() throws -> TagPresetInstallResult {
        let created = try tags.createMissingTags(
            rawNames: TagPresetCatalog.starterDisplayNames,
            timestampMs: clock.nowMs
        )
        return TagPresetInstallResult(
            createdTags: created.map {
                TagListItem(id: $0.id, displayName: $0.displayName, state: $0.state)
            }
        )
    }

    func installStandardOntologyPackage(
        _ package: StandardOntologyPackageInput
    ) throws -> StandardOntologyInstallResult {
        try tags.installStandardOntologyPackage(package, timestampMs: clock.nowMs)
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
