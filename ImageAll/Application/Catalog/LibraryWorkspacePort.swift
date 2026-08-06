import Foundation

struct LibrarySourceSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: SourceKind
    let displayName: String
    let state: SourceState

    init(
        id: UUID,
        kind: SourceKind = .folder,
        displayName: String,
        state: SourceState
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.state = state
    }
}

struct CatalogReconcileProgress: Equatable, Sendable {
    let sourceKind: SourceKind
    /// Scanning source id when known; used to soft-reload only the visible scope.
    let sourceID: UUID?
    let sourceDisplayName: String?
    let completed: Int
    let total: Int?

    init(
        sourceKind: SourceKind,
        sourceID: UUID? = nil,
        sourceDisplayName: String?,
        completed: Int,
        total: Int?
    ) {
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.sourceDisplayName = sourceDisplayName
        self.completed = completed
        self.total = total
    }
}

enum ConnectPhotosOutcome: Equatable, Sendable {
    case connected(sourceID: UUID)
    case alreadyConnected(sourceID: UUID)
}

enum RebindPhotosOutcome: Equatable, Sendable {
    case rebound(previousSourceID: UUID, sourceID: UUID)
}

enum LibraryWorkspacePhase: Equatable, Sendable {
    case loading
    case empty
    case scanning
    case content
    case failed(LibraryWorkspaceSafeError)
}

enum LibraryWorkspaceSafeError: String, Equatable, Sendable {
    case connectionFailed
    case scanFailed
    case catalogFailed
}

enum AppStorageLocationSelectionResult: Equatable, Sendable {
    case cancelled
    case restartRequired(AppStorageLocationStatus)
}

enum SourceThumbnailPrewarmKind: Equatable, Sendable {
    case square
    case originalAspect
}

struct SourceThumbnailPrewarmProgress: Equatable, Sendable {
    let sourceID: UUID
    let sourceDisplayName: String
    let kind: SourceThumbnailPrewarmKind
    let completed: Int
    let total: Int
    let warmed: Int
    let failed: Int

    init(
        sourceID: UUID,
        sourceDisplayName: String,
        kind: SourceThumbnailPrewarmKind = .square,
        completed: Int,
        total: Int,
        warmed: Int,
        failed: Int
    ) {
        self.sourceID = sourceID
        self.sourceDisplayName = sourceDisplayName
        self.kind = kind
        self.completed = completed
        self.total = total
        self.warmed = warmed
        self.failed = failed
    }

    var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }
}

enum LibraryWorkspaceNotice: Equatable, Sendable {
    case selectionHiddenByFilter
    case presetTagsInstalled(createdCount: Int)
    case presetTagsAlreadyAvailable
    case invalidTagName
    case duplicateTag
    case invalidTagGroupName
    case duplicateTagGroup
    case systemTagGroupProtected
    case tagMutationFailed
    case tagSelectionRefreshFailed
    case sourceActionFailed
    case sourceDeletionBlockedByRecycle(
        sourceID: UUID,
        displayName: String,
        blockers: LibrarySourceDeletionBlockers
    )
    case sourceDeleted(displayName: String, assetCount: Int)
    case backgroundScanFailed
    case photosAuthorizationRequired
    case reviewActionFailed
    case reviewJobConflict
    case insufficientSuggestionSamples(positiveMissing: Int, negativeMissing: Int)
    case reviewMutationApplied(count: Int, tagName: String)
    case tagBatchMutationApplied(
        count: Int,
        tagDisplayName: String,
        action: LibraryTagMutationFeedbackKind
    )
    case photosAlreadyConnected
    case photosSyncQueued
    case photosFullRepairQueued
    case portableExportCompleted(bundleName: String, recordCount: Int)
    case portableExportDestinationOverlapsSource
    case portableExportIsolationIndeterminate
    case portableExportFailed
    case previewCacheCleared(removedEntries: Int, partialReclaim: Bool)
    case previewCacheActionFailed
    case photosOriginalStorageCleared(removedEntries: Int, partialReclaim: Bool)
    case photosOriginalStorageActionFailed
    case sourceThumbnailPrewarmCompleted(
        sourceDisplayName: String,
        warmed: Int,
        failed: Int,
        total: Int
    )
    case sourceThumbnailPrewarmCancelled(
        sourceDisplayName: String,
        completed: Int,
        total: Int
    )
    case sourceThumbnailPrewarmFailed
    case sourceOriginalAspectThumbnailPrewarmCompleted(
        sourceDisplayName: String,
        warmed: Int,
        failed: Int,
        total: Int
    )
    case sourceOriginalAspectThumbnailPrewarmCancelled(
        sourceDisplayName: String,
        completed: Int,
        total: Int
    )
    case sourceOriginalAspectThumbnailPrewarmFailed
    case appStorageLocationRequiresRestart
    case appStorageLocationActionFailed
    case jobActivityActionFailed
    case personalModelRebuildCompleted(tagCount: Int, sampleCount: Int)
    case personalModelRebuildTagSelectionRequired
    case personalModelRebuildNotReady
    case personalModelRebuildPreviewUnavailable
    case personalModelRebuildCacheUnavailable
    case personalModelRebuildServiceUnavailable
    case personalModelRebuildFailed
    case personalAdamWRebuildCompleted(tagCount: Int, sampleCount: Int)
    case personalAdamWRebuildTagSelectionRequired
    case personalAdamWRebuildNotReady
    case personalAdamWRebuildFailed
    case selectedAssetEmbeddingCached
    case selectedAssetEmbeddingBatchCompleted(
        prepared: Int,
        skipped: Int,
        cloudOnly: Int,
        failed: Int
    )
    case selectedAssetEmbeddingModelUnavailable
    case selectedAssetEmbeddingPreviewUnavailable
    case selectedAssetEmbeddingFailed
    case personalSampleSuggestionsCompleted(
        checked: Int,
        suggested: Int,
        skipped: Int
    )
    case personalSampleSuggestionsNotReady
    case personalSampleSuggestionsModelUnavailable
    case personalSampleSuggestionsFailed
    case featureKnnSuggestionsCompleted(
        tagName: String,
        candidates: Int,
        aboveThreshold: Int,
        reviewable: Int,
        skipped: Int
    )
    case personalTagLibrarySuggestionsCompleted(
        tagName: String,
        candidates: Int,
        aboveThreshold: Int,
        inserted: Int,
        skipped: Int
    )
    case personalTagLibrarySuggestionsNotReady
    case personalTagLibrarySuggestionsTagNotInModel
    case personalTagLibrarySuggestionsModelUnavailable
    case personalTagLibrarySuggestionsFailed
    case personalAdamWTagLibrarySuggestionsCompleted(
        tagName: String,
        candidates: Int,
        aboveThreshold: Int,
        inserted: Int,
        skipped: Int
    )
    case personalAdamWTagLibrarySuggestionsNotReady
    case personalAdamWTagLibrarySuggestionsTagNotInModel
    case personalAdamWTagLibrarySuggestionsFailed
    case suggestionThresholdPruned(tagName: String, methodName: String, deletedCount: Int)
    case suggestionThresholdUpdateFailed
    case originalOpenFailed
}

enum LibraryOriginalAssetOpenError: Error, Equatable, Sendable {
    case unavailable
    case unsafeLocator
    case previewUnavailable
}

@MainActor
protocol LibraryOriginalAssetOpening: Sendable {
    func openOriginalAsset(assetID: UUID) async throws
}

@MainActor
struct UnavailableLibraryOriginalAssetOpener: LibraryOriginalAssetOpening {
    func openOriginalAsset(assetID _: UUID) async throws {
        throw LibraryOriginalAssetOpenError.unavailable
    }
}

@MainActor
final class LibraryVideoPlaybackResource {
    let url: URL
    private var releaseAction: (@Sendable () -> Void)?

    init(url: URL, release: @escaping @Sendable () -> Void = {}) {
        self.url = url
        releaseAction = release
    }

    func release() {
        let action = releaseAction
        releaseAction = nil
        action?()
    }

    deinit {
        releaseAction?()
    }
}

@MainActor
protocol LibraryVideoPlaybackProviding: Sendable {
    func prepareVideoPlayback(assetID: UUID) async throws -> LibraryVideoPlaybackResource
}

@MainActor
struct UnavailableLibraryVideoPlaybackProvider: LibraryVideoPlaybackProviding {
    func prepareVideoPlayback(assetID _: UUID) async throws -> LibraryVideoPlaybackResource {
        throw LibraryOriginalAssetOpenError.unavailable
    }
}

enum CloudPreviewPresentationState: Equatable, Sendable {
    case hidden
    case available(assetID: UUID)
    case downloading(assetID: UUID, progress: Double)
    case downloaded(assetID: UUID, data: Data)
    case failed(assetID: UUID)

    var assetID: UUID? {
        switch self {
        case .hidden:
            nil
        case let .available(assetID),
             let .downloading(assetID, _),
             let .downloaded(assetID, _),
             let .failed(assetID):
            assetID
        }
    }
}

enum LibraryTagDecisionAction: Equatable, Sendable {
    case accept
    case reject
    case clear

    var decision: TagDecisionQueryState {
        switch self {
        case .accept: .accepted
        case .reject: .rejected
        case .clear: .unknown
        }
    }
}

enum LibraryTagMutationFeedbackKind: Equatable, Sendable {
    case accepted
    case rejected
    case cleared
    case createdAndApplied
}

struct LibrarySinglePhotoNavigationPresentation: Equatable, Sendable {
    let fileName: String
    let position: Int
    let loadedCount: Int
    let canMovePrevious: Bool
    let canMoveNext: Bool
}

struct LibraryInspectorTagPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let decision: LibraryInspectorTagDecisionState
}

enum LibraryInspectorTagDecisionState: Equatable, Sendable {
    case unknown
    case accepted
    case rejected
    case mixed

    init(_ state: TagDecisionQueryState) {
        switch state {
        case .unknown: self = .unknown
        case .accepted: self = .accepted
        case .rejected: self = .rejected
        }
    }
}

protocol LibraryWorkspacePort: Sendable {
    func startCatalogSourceMonitoring(onChange: @escaping @Sendable () -> Void) throws
    func stopCatalogSourceMonitoring()
    @MainActor func choosePortableExportDirectory() -> URL?
    func exportPortableUserData(to parentDirectoryURL: URL) throws -> PortableCatalogExportResult
    func fetchPreviewCacheUsage() throws -> DerivedImageCacheUsage
    func clearPreviewCache() async throws -> DerivedImageCacheClearResult
    func fetchPhotosOriginalStorageUsage() throws -> PhotosOriginalStorageUsage
    func clearPhotosOriginalStorage() throws -> PhotosOriginalStorageClearResult
    func fetchAppStorageLocation() -> AppStorageLocationStatus
    @MainActor
    func chooseExternalAppStorageLocation() async throws -> AppStorageLocationSelectionResult
    func fetchJobActivity() throws -> [JobActivityItem]
    func applyJobActivityAction(_ action: JobActivityAction, jobID: UUID) throws
    func fetchSources() throws -> [LibrarySourceSummary]
    func fetchGalleryOverview() throws -> GalleryOverviewSnapshot
    func cachedWorldMapSnapshot(query: WorldMapCatalogQuery) -> WorldMapCatalogSnapshot?
    func fetchWorldMapSnapshot(query: WorldMapCatalogQuery) throws -> WorldMapCatalogSnapshot
    func fetchWorldMapSelection(
        query: WorldMapCatalogSelectionQuery
    ) throws -> WorldMapCatalogSelection
    func fetchWorldMapLocationBackfillSnapshots() throws
        -> [WorldMapLocationBackfillSnapshot]
    func startWorldMapLocationBackfill(sourceID: UUID) throws
    func cancelWorldMapLocationBackfill(sourceID: UUID) throws
    func fetchWorldMapPlaceTagResolutions() throws -> [WorldMapPlaceTagResolution]
    func resolveWorldMapPlaceTag(tagID: UUID) async throws -> WorldMapPlaceTagResolution
    func searchWorldMapPlaceTag(
        tagID: UUID,
        query: String
    ) async throws -> WorldMapPlaceTagResolution
    func confirmWorldMapPlaceCandidate(
        tagID: UUID,
        placeID: String
    ) throws -> WorldMapPlaceTagResolution
    func ignoreWorldMapPlaceTag(tagID: UUID) throws -> WorldMapPlaceTagResolution
    func connectFolder() async throws -> ConnectFolderOutcome
    func connectPhotos() async throws -> ConnectPhotosOutcome
    func syncPhotosLibrary(sourceID: UUID) async throws
    func requestPhotosFullRepair(sourceID: UUID) async throws
    func photosLibrarySupportedImageCount() throws -> Int
    func photosCatalogAssetCount(sourceID: UUID) throws -> Int
    func reactivatePhotosLibrary(sourceID: UUID) async throws
    /// Restores authorization for existing sources when it can be done without a picker:
    /// Photos TCC + bookmark probe for folders marked `authorizationRequired`.
    func restoreDefaultSourceAuthorizations() async throws
    func rebindPhotos(unavailableSourceID: UUID) async throws -> RebindPhotosOutcome
    func reauthorizeFolder(sourceID: UUID) async throws -> ReauthorizeFolderOutcome
    func disableFolderSource(sourceID: UUID) async throws -> DisableFolderOutcome
    func deleteLibrarySource(sourceID: UUID) async throws -> DeleteLibrarySourceOutcome
    func enqueueReconcile(sourceIDs: [UUID]) throws
    func hasPendingCatalogReconcileJobs() throws -> Bool
    func sourceIsReconcileClean(sourceID: UUID) throws -> Bool
    func fetchCatalogReconcileProgress() throws -> CatalogReconcileProgress?
    func runPendingReconcileJobs(sourceIDs: Set<UUID>?) throws
    func runPendingPhotosReconcileJobs(sourceIDs: Set<UUID>?) throws
    func runPendingLibrarySlimmingJobs() throws
    func runPendingPersonalizationJobs() throws
    func fetchAssetPage(
        filter: AssetPageFilter,
        sort: AssetPageSort,
        cursor: AssetPageCursor?
    ) throws -> AssetPageResult
    func loadThumbnail(assetID: UUID) async throws -> Data
    func loadOriginalAspectThumbnailIfCached(assetID: UUID) async throws -> Data?
    func cachedOriginalAspectThumbnailAssetIDs(sourceID: UUID) async throws -> Set<UUID>
    func prewarmOriginalAspectThumbnail(assetID: UUID) async throws -> Data
    func loadPreview(assetID: UUID) async throws -> Data
    func downloadCloudPreview(
        assetID: UUID,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data
    func listTags() throws -> [TagListItem]
    func listTagGroups() throws -> [TagGroupListItem]
    func installPresetTags() throws -> TagPresetInstallResult
    func installStandardOntologyPackage(
        _ package: StandardOntologyPackageInput
    ) throws -> StandardOntologyInstallResult
    func fetchInspectorDetail(assetID: UUID) throws -> AssetInspectorDetail
    func selectionAggregate(tagIDs: [UUID], assetIDs: [UUID]) throws -> [TagSelectionAggregate]
    func mutateTag(
        tagID: UUID,
        assetIDs: [UUID],
        action: LibraryTagDecisionAction
    ) throws -> TagMutationPriorStateSnapshot
    func restoreTagMutation(_ snapshot: TagMutationPriorStateSnapshot) throws
    func createTagAndAccept(
        rawName: String,
        assetIDs: [UUID]
    ) throws -> TagCreateAndApplyResult
    func renameTag(tagID: UUID, rawName: String) throws -> TagListItem
    func archiveTag(tagID: UUID) throws
    func moveTag(tagID: UUID, toGroupID: UUID) throws -> TagListItem
    func createTagGroup(rawName: String) throws -> TagGroupListItem
    func renameTagGroup(groupID: UUID, rawName: String) throws -> TagGroupListItem
    func deleteTagGroup(groupID: UUID) throws
}

extension LibraryWorkspacePort {
    func startCatalogSourceMonitoring(onChange: @escaping @Sendable () -> Void) throws {}
    func stopCatalogSourceMonitoring() {}

    func fetchGalleryOverview() throws -> GalleryOverviewSnapshot {
        .empty
    }

    func cachedWorldMapSnapshot(query _: WorldMapCatalogQuery) -> WorldMapCatalogSnapshot? {
        nil
    }

    func fetchWorldMapSnapshot(query _: WorldMapCatalogQuery) throws -> WorldMapCatalogSnapshot {
        .empty
    }

    func fetchWorldMapSelection(
        query _: WorldMapCatalogSelectionQuery
    ) throws -> WorldMapCatalogSelection {
        .empty
    }

    func fetchWorldMapLocationBackfillSnapshots() throws
        -> [WorldMapLocationBackfillSnapshot]
    {
        []
    }

    func startWorldMapLocationBackfill(sourceID _: UUID) throws {}

    func cancelWorldMapLocationBackfill(sourceID _: UUID) throws {}

    func fetchWorldMapPlaceTagResolutions() throws -> [WorldMapPlaceTagResolution] {
        []
    }

    func resolveWorldMapPlaceTag(tagID _: UUID) async throws -> WorldMapPlaceTagResolution {
        throw WorldMapPlaceResolutionError.tagUnavailable
    }

    func searchWorldMapPlaceTag(
        tagID _: UUID,
        query _: String
    ) async throws -> WorldMapPlaceTagResolution {
        throw WorldMapPlaceResolutionError.tagUnavailable
    }

    func confirmWorldMapPlaceCandidate(
        tagID _: UUID,
        placeID _: String
    ) throws -> WorldMapPlaceTagResolution {
        throw WorldMapPlaceResolutionError.candidateUnavailable
    }

    func ignoreWorldMapPlaceTag(tagID _: UUID) throws -> WorldMapPlaceTagResolution {
        throw WorldMapPlaceResolutionError.tagUnavailable
    }

    func loadOriginalAspectThumbnailIfCached(assetID _: UUID) async throws -> Data? {
        nil
    }

    func cachedOriginalAspectThumbnailAssetIDs(sourceID _: UUID) async throws -> Set<UUID> {
        []
    }

    func prewarmOriginalAspectThumbnail(assetID _: UUID) async throws -> Data {
        throw DerivedImageError.derivedAssetIneligible
    }

    func fetchAppStorageLocation() -> AppStorageLocationStatus {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ImageAll", isDirectory: true)
        let directory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ImageAll", isDirectory: true)
        return AppStorageLocationStatus(
            applicationSupportDirectoryURL: applicationSupport,
            cachesDirectoryURL: directory,
            preferredExternalRootURL: nil,
            usesExternalStorage: false,
            requiresRestart: false
        )
    }

    @MainActor
    func chooseExternalAppStorageLocation() async throws -> AppStorageLocationSelectionResult {
        .cancelled
    }

}
