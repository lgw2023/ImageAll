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
    let sourceDisplayName: String?
    let completed: Int
    let total: Int?
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

enum LibraryWorkspaceNotice: Equatable, Sendable {
    case selectionHiddenByFilter
    case presetTagsInstalled(createdCount: Int)
    case presetTagsAlreadyAvailable
    case invalidTagName
    case duplicateTag
    case tagMutationFailed
    case tagSelectionRefreshFailed
    case sourceActionFailed
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
    func fetchJobActivity() throws -> [JobActivityItem]
    func applyJobActivityAction(_ action: JobActivityAction, jobID: UUID) throws
    func fetchSources() throws -> [LibrarySourceSummary]
    func connectFolder() async throws -> ConnectFolderOutcome
    func connectPhotos() async throws -> ConnectPhotosOutcome
    func syncPhotosLibrary(sourceID: UUID) async throws
    func requestPhotosFullRepair(sourceID: UUID) async throws
    func photosLibrarySupportedImageCount() throws -> Int
    func photosCatalogAssetCount(sourceID: UUID) throws -> Int
    func reactivatePhotosLibrary(sourceID: UUID) async throws
    func rebindPhotos(unavailableSourceID: UUID) async throws -> RebindPhotosOutcome
    func reauthorizeFolder(sourceID: UUID) async throws -> ReauthorizeFolderOutcome
    func disableFolderSource(sourceID: UUID) async throws -> DisableFolderOutcome
    func enqueueReconcile(sourceIDs: [UUID]) throws
    func hasPendingCatalogReconcileJobs() throws -> Bool
    func sourceIsReconcileClean(sourceID: UUID) throws -> Bool
    func fetchCatalogReconcileProgress() throws -> CatalogReconcileProgress?
    func runPendingReconcileJobs() throws
    func runPendingPhotosReconcileJobs() throws
    func runPendingPersonalizationJobs() throws
    func fetchAssetPage(
        filter: AssetPageFilter,
        sort: AssetPageSort,
        cursor: AssetPageCursor?
    ) throws -> AssetPageResult
    func loadThumbnail(assetID: UUID) async throws -> Data
    func loadPreview(assetID: UUID) async throws -> Data
    func downloadCloudPreview(
        assetID: UUID,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data
    func listTags() throws -> [TagListItem]
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
}

extension LibraryWorkspacePort {
    func startCatalogSourceMonitoring(onChange: @escaping @Sendable () -> Void) throws {}
    func stopCatalogSourceMonitoring() {}
}
