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
    case invalidTagName
    case duplicateTag
    case tagMutationFailed
    case sourceActionFailed
    case backgroundScanFailed
    case photosAuthorizationRequired
    case reviewActionFailed
    case reviewJobConflict
    case insufficientSuggestionSamples(positiveMissing: Int, negativeMissing: Int)
    case reviewMutationApplied(count: Int, tagName: String)
    case portableExportCompleted(bundleName: String, recordCount: Int)
    case portableExportDestinationOverlapsSource
    case portableExportIsolationIndeterminate
    case portableExportFailed
    case previewCacheCleared(removedEntries: Int, partialReclaim: Bool)
    case previewCacheActionFailed
    case jobActivityActionFailed
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
    @MainActor func choosePortableExportDirectory() -> URL?
    func exportPortableUserData(to parentDirectoryURL: URL) throws -> PortableCatalogExportResult
    func fetchPreviewCacheUsage() throws -> DerivedImageCacheUsage
    func clearPreviewCache() async throws -> DerivedImageCacheClearResult
    func fetchJobActivity() throws -> [JobActivityItem]
    func applyJobActivityAction(_ action: JobActivityAction, jobID: UUID) throws
    func fetchSources() throws -> [LibrarySourceSummary]
    func connectFolder() async throws -> ConnectFolderOutcome
    func connectPhotos() async throws -> ConnectPhotosOutcome
    func reauthorizeFolder(sourceID: UUID) async throws -> ReauthorizeFolderOutcome
    func disableFolderSource(sourceID: UUID) async throws -> DisableFolderOutcome
    func enqueueReconcile(sourceIDs: [UUID]) throws
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
