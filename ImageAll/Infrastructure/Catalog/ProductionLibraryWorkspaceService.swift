import AppKit
import Foundation
import GRDB

enum ProductionLibraryWorkspaceError: Error {
    case reconcileFailed
    case librarySlimmingMaintenanceFailed
    case librarySlimmingAnalysisInProgress
}

struct ProductionLibraryWorkspaceService: LibraryWorkspacePort, RemoteCatalogServing, Sendable {
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
    let photosOriginalCache: PhotosOriginalCacheService
    let appStorageLocationController: AppStorageLocationController
    let portableExportDestinationPicker: any PortableExportDestinationPicking
    let portableExportSourceIsolation: PortableExportSourceIsolationValidator
    let portableExporter: PortableCatalogExporter
    let appVersion: String
    let clock: any JobClock

    func startCatalogSourceMonitoring(onChange: @escaping @Sendable () -> Void) throws {
        // Startup restores event streams only. A full reconcile for every active
        // external source would monopolize mechanical disks before the user asks
        // to refresh a source; persisted jobs and later FSEvents still reconcile.
        try folderSourceMonitor.start(
            onChange: onChange,
            enqueueInitialReconciles: false
        )
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

    func fetchPhotosOriginalStorageUsage() throws -> PhotosOriginalStorageUsage {
        try photosOriginalCache.storageUsage()
    }

    func clearPhotosOriginalStorage() throws -> PhotosOriginalStorageClearResult {
        let hasActiveAnalysis = try queue.database.pool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM job
                    WHERE kind = ?
                      AND state IN ('pending', 'running')
                )
                """,
                arguments: [LibrarySlimmingAnalysisJobFactory.kind]
            ) ?? false
        }
        guard !hasActiveAnalysis else {
            throw ProductionLibraryWorkspaceError.librarySlimmingAnalysisInProgress
        }
        return try photosOriginalCache.clearAll()
    }

    func fetchAppStorageLocation() -> AppStorageLocationStatus {
        appStorageLocationController.activeStatus
    }

    @MainActor
    func chooseExternalAppStorageLocation() async throws -> AppStorageLocationSelectionResult {
        try await appStorageLocationController.chooseExternalLocation()
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

    func restoreDefaultSourceAuthorizations() async throws {
        // Only soft-reactivate existing authorizationRequired sources.
        // Do not call photos connect() here — that can kick off heavy library
        // work during startup and freeze sidebar navigation.
        for source in try photosConnection.fetchSources()
            where source.kind == .photos && source.state == .authorizationRequired
        {
            try? photosConnection.reactivate(sourceID: source.id)
        }

        let folderSources = try sourceRepository.fetchAllFolderSources()
        for source in folderSources where source.state == .authorizationRequired {
            _ = try? authorization.attemptRestoreFolderAuthorization(sourceID: source.id)
        }
        // Restore security-scoped sessions for reads without enqueueing a
        // full-library reconcile for every newly activated folder source.
        try folderSourceMonitor.synchronize(enqueueInitialReconciles: false)
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
            _ = try queue.enqueueOrReuseActive(command)
        }
        for source in try photosConnection.fetchSources()
            where source.kind == .photos && source.state == .active && requested.contains(source.id)
        {
            try photosConnection.enqueueReconcile(sourceID: source.id)
        }
    }

    func hasPendingCatalogReconcileJobs() throws -> Bool {
        try queue.hasBlockingReconcileWork(nowMs: clock.nowMs)
    }

    func sourceIsReconcileClean(sourceID: UUID) throws -> Bool {
        try queue.isSourceReconcileClean(sourceID: sourceID)
    }

    func fetchCatalogReconcileProgress() throws -> CatalogReconcileProgress? {
        try queue.database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT job.kind, job.source_id, job.progress_completed, job.progress_total,
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
            let sourceIDString: String? = row["source_id"]
            return CatalogReconcileProgress(
                sourceKind: kind == PhotosReconcileJobFactory.kind ? .photos : .folder,
                sourceID: sourceIDString.flatMap(UUID.init(uuidString:)),
                sourceDisplayName: row["display_name"],
                completed: row["progress_completed"],
                total: row["progress_total"]
            )
        }
    }

    func runPendingReconcileJobs(sourceIDs: Set<UUID>?) throws {
        defer { try? folderSourceMonitor.synchronize() }
        let claim = ClaimNextInput(
            owner: "imageall-reconcile-\(UUID().uuidString.lowercased())",
            leaseDurationMs: FolderReconcileJobFactory.leaseDurationMs,
            allowedKinds: [FolderReconcileJobFactory.kind],
            allowedSourceIDs: sourceIDs
        )
        while let result = try executionCoordinator.claimAndExecuteOnce(claim) {
            guard result.snapshot.state == .completed else {
                throw ProductionLibraryWorkspaceError.reconcileFailed
            }
        }
    }

    func runPendingPhotosReconcileJobs(sourceIDs: Set<UUID>?) throws {
        let claim = ClaimNextInput(
            owner: "imageall-photos-reconcile-\(UUID().uuidString.lowercased())",
            leaseDurationMs: 60_000,
            allowedKinds: [PhotosReconcileJobFactory.kind],
            allowedSourceIDs: sourceIDs
        )
        while let result = try executionCoordinator.claimAndExecuteOnce(claim) {
            guard result.snapshot.state == .completed else {
                throw ProductionLibraryWorkspaceError.reconcileFailed
            }
        }
    }

    func runPendingLibrarySlimmingJobs() throws {
        let claim = ClaimNextInput(
            owner: "imageall-library-slimming-\(UUID().uuidString.lowercased())",
            leaseDurationMs: 60_000,
            allowedKinds: [LibrarySlimmingPurgeJobFactory.kind]
        )
        while let result = try executionCoordinator.claimAndExecuteOnce(claim) {
            guard result.snapshot.state == .completed else {
                throw ProductionLibraryWorkspaceError.librarySlimmingMaintenanceFailed
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

    func fetchAssetPage(
        filter: AssetPageFilter,
        sort: AssetPageSort,
        cursor: AssetPageCursor?,
        limit: Int
    ) throws -> AssetPageResult {
        try query.fetchAssetPage(
            AssetPageRequest(
                filter: filter,
                sort: sort,
                cursor: cursor,
                limit: limit
            )
        )
    }

    func loadThumbnail(assetID: UUID) async throws -> Data {
        try await assetImages.load(assetID: assetID, variant: .grid)
    }

    func loadOriginalAspectThumbnailIfCached(assetID: UUID) async throws -> Data? {
        try await assetImages.loadOriginalAspectThumbnailIfCached(assetID: assetID)
    }

    func cachedOriginalAspectThumbnailAssetIDs(sourceID: UUID) async throws -> Set<UUID> {
        let database = queue.database
        return try await Task.detached(priority: .utility) {
            try database.pool.read { db in
                let rows = try String.fetchAll(
                    db,
                    sql: """
                    SELECT a.id
                    FROM asset a
                    JOIN derived_image_cache_entry e
                      ON e.asset_id = a.id
                     AND e.content_revision = a.content_revision
                    WHERE a.source_id = ?
                      AND a.locator_state = 'current'
                      AND e.representation_version = ?
                      AND e.variant = ?
                    ORDER BY a.id
                    """,
                    arguments: [
                        sourceID.uuidString.lowercased(),
                        DerivedImageRepresentationVersion.production,
                        DerivedImageVariant.gridOriginal.rawValue,
                    ]
                )
                return Set(rows.compactMap(UUID.init(uuidString:)))
            }
        }.value
    }

    func prewarmOriginalAspectThumbnail(assetID: UUID) async throws -> Data {
        try await assetImages.prewarmOriginalAspectThumbnail(assetID: assetID)
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

    func listTagGroups() throws -> [TagGroupListItem] {
        try tags.listTagGroups()
    }

    func installPresetTags() throws -> TagPresetInstallResult {
        let created = try tags.createMissingTags(
            rawNames: TagPresetCatalog.starterDisplayNames,
            timestampMs: clock.nowMs
        )
        return TagPresetInstallResult(
            createdTags: created.map {
                TagListItem(
                    id: $0.id,
                    displayName: $0.displayName,
                    state: $0.state,
                    groupID: TagGroupSeed.classify(displayName: $0.displayName).id
                )
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
        _ = try tags.renameTag(tagID: tagID, rawName: rawName, timestampMs: clock.nowMs)
        let listed = try tags.listTags(includeArchived: true)
        guard let item = listed.first(where: { $0.id == tagID }) else {
            throw CatalogQueryError.notFound
        }
        return item
    }

    func archiveTag(tagID: UUID) throws {
        _ = try tags.archiveTag(tagID: tagID, timestampMs: clock.nowMs)
    }

    func moveTag(tagID: UUID, toGroupID: UUID) throws -> TagListItem {
        try tags.moveTag(tagID: tagID, toGroupID: toGroupID, timestampMs: clock.nowMs)
    }

    func createTagGroup(rawName: String) throws -> TagGroupListItem {
        try tags.createTagGroup(rawName: rawName, timestampMs: clock.nowMs)
    }

    func renameTagGroup(groupID: UUID, rawName: String) throws -> TagGroupListItem {
        try tags.renameTagGroup(groupID: groupID, rawName: rawName, timestampMs: clock.nowMs)
    }

    func deleteTagGroup(groupID: UUID) throws {
        try tags.deleteTagGroup(groupID: groupID, timestampMs: clock.nowMs)
    }
}

private struct LibraryOriginalAssetLocator: Sendable {
    let sourceID: UUID
    let sourceKind: SourceKind
    let locatorKind: AssetLocatorKind
    let mediaKind: MediaKind
    let relativePath: String?
    let photosLocalIdentifier: String?
    let availability: AssetAvailability
}

@MainActor
struct AppKitLibraryOriginalAssetOpener: LibraryOriginalAssetOpening {
    let database: CatalogDatabase
    let folderAuthorization: FolderAuthorizationCoordinator
    let photosLibrary: PhotoKitPhotosLibraryAdapter

    func openOriginalAsset(assetID: UUID) async throws {
        let locator = try fetchLibraryOriginalAssetLocator(
            database: database,
            assetID: assetID
        )
        guard locator.availability == .available else {
            throw LibraryOriginalAssetOpenError.unavailable
        }

        switch (locator.sourceKind, locator.locatorKind) {
        case (.folder, .file):
            guard let relativePath = locator.relativePath,
                  case let .success(validatedPath) = RelativePathRules.validate(relativePath)
            else {
                throw LibraryOriginalAssetOpenError.unsafeLocator
            }
            try folderAuthorization.accessFolderSource(sourceID: locator.sourceID) { rootURL in
                let url = rootURL.appendingPathComponent(validatedPath, isDirectory: false)
                if locator.mediaKind == .video {
                    try openWithSystemDefault(url)
                } else {
                    try openWithPreview(url)
                }
            }
        case (.photos, .photos):
            guard let localIdentifier = locator.photosLocalIdentifier else {
                throw LibraryOriginalAssetOpenError.unsafeLocator
            }
            if locator.mediaKind == .video {
                let originalURL = try await photosLibrary.requestOriginalVideoURL(
                    localIdentifier: localIdentifier
                )
                try openWithSystemDefault(originalURL)
            } else {
                let originalURL = try await photosLibrary.requestOriginalImageURL(
                    localIdentifier: localIdentifier
                )
                try openWithPreview(originalURL)
            }
        default:
            throw LibraryOriginalAssetOpenError.unsafeLocator
        }
    }

    private func openWithPreview(_ url: URL) throws {
        guard let previewURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Preview"
        ) else {
            throw LibraryOriginalAssetOpenError.previewUnavailable
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.promptsUserIfNeeded = true
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: previewURL,
            configuration: configuration,
            completionHandler: nil
        )
    }

    private func openWithSystemDefault(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw LibraryOriginalAssetOpenError.previewUnavailable
        }
    }
}

@MainActor
struct AppKitLibraryVideoPlaybackProvider: LibraryVideoPlaybackProviding {
    let database: CatalogDatabase
    let folderAuthorization: FolderAuthorizationCoordinator
    let photosLibrary: PhotoKitPhotosLibraryAdapter

    func prepareVideoPlayback(assetID: UUID) async throws -> LibraryVideoPlaybackResource {
        let locator = try fetchLibraryOriginalAssetLocator(
            database: database,
            assetID: assetID
        )
        guard locator.availability == .available, locator.mediaKind == .video else {
            throw LibraryOriginalAssetOpenError.unavailable
        }

        switch (locator.sourceKind, locator.locatorKind) {
        case (.folder, .file):
            guard let relativePath = locator.relativePath,
                  case let .success(validatedPath) = RelativePathRules.validate(relativePath)
            else {
                throw LibraryOriginalAssetOpenError.unsafeLocator
            }
            let accessLease = try folderAuthorization.acquireFolderSourceAccess(
                sourceID: locator.sourceID
            )
            let url = accessLease.rootURL.appendingPathComponent(
                validatedPath,
                isDirectory: false
            )
            return LibraryVideoPlaybackResource(url: url) {
                accessLease.release()
            }
        case (.photos, .photos):
            guard let localIdentifier = locator.photosLocalIdentifier else {
                throw LibraryOriginalAssetOpenError.unsafeLocator
            }
            let url = try await photosLibrary.requestOriginalVideoURL(
                localIdentifier: localIdentifier
            )
            return LibraryVideoPlaybackResource(url: url)
        default:
            throw LibraryOriginalAssetOpenError.unsafeLocator
        }
    }
}

private func fetchLibraryOriginalAssetLocator(
    database: CatalogDatabase,
    assetID: UUID
) throws -> LibraryOriginalAssetLocator {
    try database.pool.read { db in
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT
                asset.source_id,
                source.kind AS source_kind,
                asset.locator_kind,
                asset.media_kind,
                asset.relative_path,
                asset.photos_local_identifier,
                asset.availability
            FROM asset
            INNER JOIN source ON source.id = asset.source_id
            WHERE asset.id = ? AND asset.locator_state = 'current'
            """,
            arguments: [assetID.uuidString.lowercased()]
        ),
            let sourceID = UUID(uuidString: row["source_id"]),
            let sourceKind = SourceKind(rawValue: row["source_kind"]),
            let locatorKind = AssetLocatorKind(rawValue: row["locator_kind"]),
            let mediaKind = MediaKind(rawValue: row["media_kind"]),
            let availability = AssetAvailability(rawValue: row["availability"])
        else {
            throw LibraryOriginalAssetOpenError.unavailable
        }
        return LibraryOriginalAssetLocator(
            sourceID: sourceID,
            sourceKind: sourceKind,
            locatorKind: locatorKind,
            mediaKind: mediaKind,
            relativePath: row["relative_path"],
            photosLocalIdentifier: row["photos_local_identifier"],
            availability: availability
        )
    }
}
