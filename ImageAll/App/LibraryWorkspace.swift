import AppKit
import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private struct LibraryTagUndoRecord {
    let snapshot: TagMutationPriorStateSnapshot
    let appliedDecision: TagDecisionQueryState
}

private struct ReviewMutationUndoRecord {
    let snapshot: TagMutationPriorStateSnapshot
    let appliedDecision: TagDecisionQueryState
    let tagDisplayName: String
    let affectedCount: Int
}

enum LibraryGridDensity: String, CaseIterable, Sendable {
    case compact
    case standard
    case large

    var displayName: String {
        switch self {
        case .compact: "紧凑"
        case .standard: "标准"
        case .large: "大图"
        }
    }

    var cellWidthRange: ClosedRange<CGFloat> {
        switch self {
        case .compact: 96 ... 160
        case .standard: 132 ... 220
        case .large: 180 ... 300
        }
    }
}

enum LibraryGridNavigationDirection: Equatable, Sendable {
    case left
    case right
    case up
    case down
}

enum LibraryGridLayout {
    static let spacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 12

    static func columnCount(
        containerWidth: CGFloat,
        density: LibraryGridDensity
    ) -> Int {
        let availableWidth = max(containerWidth - horizontalPadding * 2, 0)
        let minimumWidth = density.cellWidthRange.lowerBound
        return max(Int((availableWidth + spacing) / (minimumWidth + spacing)), 1)
    }
}

struct LibraryWorkspaceLayoutState: Equatable {
    static let inspectorCollapseWidth: CGFloat = 840

    private(set) var isSidebarPresented = true
    private(set) var isInspectorPresented = true
    private var hasAppliedNarrowInspectorCollapse = false

    mutating func updateWindowWidth(_ width: CGFloat) {
        if width >= Self.inspectorCollapseWidth {
            hasAppliedNarrowInspectorCollapse = false
        } else if !hasAppliedNarrowInspectorCollapse {
            isInspectorPresented = false
            hasAppliedNarrowInspectorCollapse = true
        }
    }

    mutating func toggleSidebar() {
        setSidebarPresented(!isSidebarPresented)
    }

    mutating func toggleInspector() {
        setInspectorPresented(!isInspectorPresented)
    }

    mutating func setSidebarPresented(_ isPresented: Bool) {
        isSidebarPresented = isPresented
    }

    mutating func setInspectorPresented(_ isPresented: Bool) {
        isInspectorPresented = isPresented
    }
}

enum LibraryWorkspaceCommand: Hashable {
    case showAllPhotos
    case showReviewSuggestions
    case showActivity
    case toggleSidebar
    case toggleInspector
    case showSource(UUID)
    case showTag(UUID)
    case acceptTag(UUID)
    case rejectTag(UUID)
    case clearTagDecision(UUID)
    case createTag
    case connectFolder
    case rescanCurrentSource
    case toggleSinglePhoto
    case showKeyboardShortcuts
}

struct LibraryWorkspaceCommandItem: Identifiable, Equatable {
    let command: LibraryWorkspaceCommand
    let title: String
    let systemImage: String
    let isEnabled: Bool

    var id: LibraryWorkspaceCommand { command }
}

@MainActor
final class LibraryWorkspaceModel: ObservableObject {
    @Published private(set) var phase: LibraryWorkspacePhase = .loading
    @Published private(set) var sources: [LibrarySourceSummary] = []
    @Published private(set) var items: [AssetGridItemProjection] = []
    @Published private(set) var selectedAssetIDs: Set<UUID> = []
    @Published private(set) var isSinglePhotoPresented = false
    @Published private(set) var inspectorDetail: AssetInspectorDetail?
    @Published private(set) var inspectorTags: [LibraryInspectorTagPresentation] = []
    @Published private(set) var tags: [TagListItem] = []
    @Published private(set) var searchText = ""
    @Published private(set) var selectedTagFilterIDs: Set<UUID> = []
    @Published private(set) var tagMatchMode: TagMatchMode = .all
    @Published private(set) var tagPresence: TagPresenceFilter = .any
    @Published private(set) var selectedAvailabilities: [AssetAvailability] = []
    @Published private(set) var selectedMediaTypes: [String] = []
    @Published private(set) var sort: AssetPageSort = .newest
    @Published private(set) var gridDensity: LibraryGridDensity = .standard
    @Published private(set) var notice: LibraryWorkspaceNotice?
    @Published private(set) var pendingSuggestionTotal = 0
    @Published private(set) var isCatalogScanning = false
    @Published private(set) var catalogReconcileProgress: CatalogReconcileProgress?
    @Published private(set) var suggestionOverviews: [SuggestionTagOverview] = []
    @Published private(set) var reviewMode: ReviewWorkspaceMode?
    @Published private(set) var reviewQueueItems: [ReviewQueueItemProjection] = []
    @Published fileprivate(set) var reviewNextCursor: ReviewQueueCursor?
    @Published var pendingSuggestionConfirmation: SuggestionEnqueueConfirmation?
    @Published private(set) var pendingTagDecisionConfirmation: LibraryTagDecisionConfirmation?
    @Published private(set) var pendingNewTagConfirmation: LibraryNewTagConfirmation?
    @Published private(set) var assetPendingSuggestions: [AssetPendingSuggestion] = []
    @Published private(set) var cloudPreviewState: CloudPreviewPresentationState = .hidden
    @Published private(set) var localModelSuggestionState: LocalModelSuggestionPresentationState = .hidden
    @Published private(set) var localModelSuggestionTrack: ModelSuggestionTrack = .standard
    @Published private(set) var personalLibrarySuggestionState: PersonalLibrarySuggestionPresentationState = .idle
    @Published private(set) var isRebuildingPersonalModel = false
    @Published private(set) var isExportingPortableData = false
    @Published private(set) var previewCacheUsage = DerivedImageCacheUsage.zero
    @Published private(set) var isClearingPreviewCache = false
    @Published private(set) var jobActivityItems: [JobActivityItem] = []
    @Published private(set) var jobActivityActionInFlightIDs: Set<UUID> = []

    fileprivate let review: any PersonalizationReviewPort
    private let service: any LibraryWorkspacePort
    private let localModelSuggestions: LocalModelSuggestionRuntime?
    private var lastTagMutation: LibraryTagUndoRecord?
    fileprivate var lastReviewMutation: ReviewMutationUndoRecord?
    private var personalizationRunnerTask: Task<Void, Never>?
    private var catalogReconcileTask: Task<Void, Never>?
    private var catalogReconcileRunRequested = false
    private var cloudPreviewTask: Task<Void, Never>?
    private var cloudPreviewRequestID: UUID?
    private var localModelSuggestionRequestID: UUID?
    private var searchDebounceTask: Task<Void, Never>?
    private var assetPageRequestID: UUID?
    private var selectionAnchorID: UUID?
    private var selectedTagFilterDecisions: [UUID: PersistableTagDecision] = [:]
    private var selectedSourceID: UUID?
    private var nextCursor: AssetPageCursor?
    private var started = false
    private var isLoadingMore = false
    fileprivate var isLoadingMoreReviewQueue = false
    private let catalogProgressRefreshInterval: Duration
    private let searchDebounceInterval: Duration

    init(
        service: any LibraryWorkspacePort,
        review: any PersonalizationReviewPort = EmptyPersonalizationReviewPort(),
        localModelSuggestions: LocalModelSuggestionRuntime? = nil,
        catalogProgressRefreshInterval: Duration = .milliseconds(750),
        searchDebounceInterval: Duration = .milliseconds(300)
    ) {
        self.service = service
        self.review = review
        self.localModelSuggestions = localModelSuggestions
        self.catalogProgressRefreshInterval = catalogProgressRefreshInterval
        self.searchDebounceInterval = searchDebounceInterval
    }

    deinit {
        searchDebounceTask?.cancel()
        service.stopCatalogSourceMonitoring()
    }

    var isBusy: Bool {
        phase == .loading || phase == .scanning || isCatalogScanning
    }

    var supportsPersonalModelRebuild: Bool {
        localModelSuggestions != nil
    }

    var supportsPersonalLibrarySuggestions: Bool {
        localModelSuggestions != nil
    }

    var isGeneratingPersonalLibrarySuggestions: Bool {
        switch personalLibrarySuggestionState {
        case .waiting, .running, .paused, .retryableFailure:
            return true
        default:
            return false
        }
    }

    var showsFirstUseGuide: Bool {
        phase == .empty && sources.isEmpty && items.isEmpty && tags.isEmpty
    }

    var canUndoTagMutation: Bool {
        lastTagMutation != nil
    }

    var primarySelectedAssetID: UUID? {
        guard selectedAssetIDs.count == 1 else { return nil }
        return selectedAssetIDs.first
    }

    var singlePhotoNavigation: LibrarySinglePhotoNavigationPresentation? {
        guard isSinglePhotoPresented, let assetID = primarySelectedAssetID else {
            return nil
        }
        if case .tagQueue = reviewMode {
            guard let index = reviewQueueItems.firstIndex(where: { $0.assetID == assetID }) else {
                return nil
            }
            return LibrarySinglePhotoNavigationPresentation(
                fileName: reviewQueueItems[index].fileName ?? "照片",
                position: index + 1,
                loadedCount: reviewQueueItems.count,
                canMovePrevious: index > 0,
                canMoveNext: index < reviewQueueItems.count - 1 || reviewNextCursor != nil
            )
        }
        guard let index = items.firstIndex(where: { $0.assetID == assetID }) else {
            return nil
        }
        return LibrarySinglePhotoNavigationPresentation(
            fileName: items[index].fileName ?? "照片",
            position: index + 1,
            loadedCount: items.count,
            canMovePrevious: index > 0,
            canMoveNext: index < items.count - 1 || nextCursor != nil
        )
    }

    var hasAssetPropertyFilters: Bool {
        !selectedAvailabilities.isEmpty || !selectedMediaTypes.isEmpty
    }

    var selectedSourceIsPhotos: Bool {
        guard let selectedSourceID else { return false }
        return isPhotosSource(selectedSourceID)
    }

    var selectedPhotosSourceNeedsAuthorization: Bool {
        guard let selectedSourceID else { return false }
        return sources.first(where: { $0.id == selectedSourceID })?.state == .authorizationRequired
    }

    var selectedUnavailablePhotosSource: LibrarySourceSummary? {
        guard let selectedSourceID else { return nil }
        return sources.first(where: {
            $0.id == selectedSourceID && $0.kind == .photos && $0.state == .unavailable
        })
    }

    var canRescan: Bool {
        if let selectedSourceID {
            return sources.first(where: { $0.id == selectedSourceID })?.state == .active
        }
        return sources.contains { $0.state == .active }
    }

    func workspaceCommands(
        matching query: String,
        layout: LibraryWorkspaceLayoutState = LibraryWorkspaceLayoutState()
    ) -> [LibraryWorkspaceCommandItem] {
        let hasSelection = !selectedAssetIDs.isEmpty
        var commands = [
            LibraryWorkspaceCommandItem(
                command: .showAllPhotos,
                title: "前往全部照片",
                systemImage: "photo.on.rectangle.angled",
                isEnabled: true
            ),
            LibraryWorkspaceCommandItem(
                command: .showReviewSuggestions,
                title: "前往待审核建议",
                systemImage: "sparkles",
                isEnabled: true
            ),
            LibraryWorkspaceCommandItem(
                command: .showActivity,
                title: "显示活动",
                systemImage: "clock.arrow.circlepath",
                isEnabled: true
            ),
            LibraryWorkspaceCommandItem(
                command: .toggleSidebar,
                title: layout.isSidebarPresented ? "隐藏侧栏" : "显示侧栏",
                systemImage: "sidebar.left",
                isEnabled: true
            ),
            LibraryWorkspaceCommandItem(
                command: .toggleInspector,
                title: layout.isInspectorPresented ? "隐藏检查器" : "显示检查器",
                systemImage: "sidebar.right",
                isEnabled: true
            ),
        ]

        commands.append(contentsOf: sources.map { source in
            LibraryWorkspaceCommandItem(
                command: .showSource(source.id),
                title: "前往来源：\(source.displayName)",
                systemImage: source.kind == .photos ? "photo.on.rectangle" : "externaldrive",
                isEnabled: true
            )
        })
        commands.append(contentsOf: tags.map { tag in
            LibraryWorkspaceCommandItem(
                command: .showTag(tag.id),
                title: "前往标签：\(tag.displayName)",
                systemImage: "tag",
                isEnabled: true
            )
        })
        for tag in tags {
            commands.append(contentsOf: [
                LibraryWorkspaceCommandItem(
                    command: .acceptTag(tag.id),
                    title: "确认标签：\(tag.displayName)",
                    systemImage: "checkmark.circle",
                    isEnabled: hasSelection
                ),
                LibraryWorkspaceCommandItem(
                    command: .rejectTag(tag.id),
                    title: "拒绝标签：\(tag.displayName)",
                    systemImage: "xmark.circle",
                    isEnabled: hasSelection
                ),
                LibraryWorkspaceCommandItem(
                    command: .clearTagDecision(tag.id),
                    title: "清除标签决定：\(tag.displayName)",
                    systemImage: "minus.circle",
                    isEnabled: hasSelection
                ),
            ])
        }
        commands.append(contentsOf: [
            LibraryWorkspaceCommandItem(
                command: .createTag,
                title: "新建标签",
                systemImage: "tag.badge.plus",
                isEnabled: hasSelection
            ),
            LibraryWorkspaceCommandItem(
                command: .connectFolder,
                title: "连接文件夹",
                systemImage: "folder.badge.plus",
                isEnabled: !isBusy
            ),
            LibraryWorkspaceCommandItem(
                command: .rescanCurrentSource,
                title: "重扫当前来源",
                systemImage: "arrow.clockwise",
                isEnabled: !isBusy && canRescan
            ),
            LibraryWorkspaceCommandItem(
                command: .toggleSinglePhoto,
                title: isSinglePhotoPresented ? "返回照片网格" : "切换单图查看",
                systemImage: isSinglePhotoPresented ? "square.grid.2x2" : "photo",
                isEnabled: primarySelectedAssetID != nil
            ),
            LibraryWorkspaceCommandItem(
                command: .showKeyboardShortcuts,
                title: "显示快捷键",
                systemImage: "keyboard",
                isEnabled: true
            ),
        ])

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return commands }
        return commands.filter { $0.title.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    func isPhotosSource(_ sourceID: UUID) -> Bool {
        sources.first(where: { $0.id == sourceID })?.kind == .photos
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            try service.startCatalogSourceMonitoring { [weak self] in
                Task { @MainActor [weak self] in
                    self?.startCatalogReconcileRunnerIfNeeded()
                }
            }
        } catch {
            notice = .backgroundScanFailed
        }
        await reload(runPendingJobs: true)
    }

    func exportPortableUserData() async {
        guard !isExportingPortableData else { return }
        notice = nil
        guard let parentDirectoryURL = service.choosePortableExportDirectory() else { return }

        isExportingPortableData = true
        defer { isExportingPortableData = false }
        let service = service
        do {
            let result = try await Self.offMain {
                try service.exportPortableUserData(to: parentDirectoryURL)
            }
            notice = .portableExportCompleted(
                bundleName: result.bundleURL.lastPathComponent,
                recordCount: result.totalRecordCount
            )
        } catch PortableCatalogExportError.destinationOverlapsSource {
            notice = .portableExportDestinationOverlapsSource
        } catch PortableCatalogExportError.destinationIsolationIndeterminate {
            notice = .portableExportIsolationIndeterminate
        } catch {
            notice = .portableExportFailed
        }
    }

    func refreshPreviewCacheUsage() async {
        let service = service
        do {
            previewCacheUsage = try await Self.offMain {
                try service.fetchPreviewCacheUsage()
            }
        } catch {
            notice = .previewCacheActionFailed
        }
    }

    func clearPreviewCache() async {
        guard !isClearingPreviewCache else { return }
        isClearingPreviewCache = true
        notice = nil
        defer { isClearingPreviewCache = false }
        let service = service
        do {
            let result = try await service.clearPreviewCache()
            previewCacheUsage = try await Self.offMain {
                try service.fetchPreviewCacheUsage()
            }
            notice = .previewCacheCleared(
                removedEntries: result.removedEntries,
                partialReclaim: result.partialReclaim
            )
        } catch {
            notice = .previewCacheActionFailed
            await refreshPreviewCacheUsage()
        }
    }

    func refreshJobActivity() async {
        let service = service
        do {
            jobActivityItems = try await Self.offMain {
                try service.fetchJobActivity()
            }
        } catch {
            notice = .jobActivityActionFailed
        }
    }

    func isApplyingJobActivityAction(_ jobID: UUID) -> Bool {
        jobActivityActionInFlightIDs.contains(jobID)
    }

    func applyJobActivityAction(_ action: JobActivityAction, to jobID: UUID) async {
        guard let item = jobActivityItems.first(where: { $0.id == jobID }),
              item.availableActions.contains(action),
              !jobActivityActionInFlightIDs.contains(jobID)
        else {
            return
        }
        jobActivityActionInFlightIDs.insert(jobID)
        notice = nil
        defer { jobActivityActionInFlightIDs.remove(jobID) }
        let service = service
        do {
            jobActivityItems = try await Self.offMain {
                try service.applyJobActivityAction(action, jobID: jobID)
                return try service.fetchJobActivity()
            }
            if action == .resume {
                startPersonalizationRunnerIfNeeded()
            }
            await refreshReviewState()
        } catch {
            if let refreshed = try? await Self.offMain({ try service.fetchJobActivity() }) {
                jobActivityItems = refreshed
            }
            notice = .jobActivityActionFailed
        }
    }

    func connectFolder() async {
        guard !isBusy else { return }
        phase = .scanning
        do {
            switch try await service.connectFolder() {
            case .cancelled:
                await reload(runPendingJobs: false)
            case .connected:
                await reload(runPendingJobs: true)
            }
        } catch {
            phase = .failed(.connectionFailed)
        }
    }

    func connectPhotos() async {
        guard !isBusy else { return }
        notice = nil
        phase = .scanning
        do {
            _ = try await service.connectPhotos()
            let service = service
            sources = try await Self.offMain { try service.fetchSources() }
            await loadFirstPage()
            startCatalogReconcileRunnerIfNeeded()
        } catch PhotosLibraryError.authorizationDenied, PhotosLibraryError.authorizationRestricted {
            let service = service
            if let refreshed = try? await Self.offMain({ try service.fetchSources() }) {
                sources = refreshed
            }
            phase = sources.isEmpty ? .empty : .content
            notice = .photosAuthorizationRequired
        } catch {
            phase = .failed(.connectionFailed)
        }
    }

    func rebindPhotos(from unavailableSourceID: UUID) async {
        guard !isBusy,
              sources.contains(where: {
                  $0.id == unavailableSourceID && $0.kind == .photos && $0.state == .unavailable
              })
        else {
            return
        }
        let previousPhase = phase
        notice = nil
        phase = .scanning
        do {
            _ = try await service.rebindPhotos(unavailableSourceID: unavailableSourceID)
            let service = service
            sources = try await Self.offMain { try service.fetchSources() }
            await loadFirstPage()
            startCatalogReconcileRunnerIfNeeded()
        } catch PhotosLibraryError.authorizationDenied, PhotosLibraryError.authorizationRestricted {
            phase = previousPhase
            notice = .photosAuthorizationRequired
        } catch {
            phase = previousPhase
            notice = .sourceActionFailed
        }
    }

    func reauthorizeSource(_ sourceID: UUID) async {
        guard !isBusy else { return }
        let previousPhase = phase
        notice = nil
        do {
            if sources.first(where: { $0.id == sourceID })?.kind == .photos {
                _ = try await service.connectPhotos()
                let service = service
                sources = try await Self.offMain { try service.fetchSources() }
                await loadFirstPage()
                startCatalogReconcileRunnerIfNeeded()
                return
            }
            switch try await service.reauthorizeFolder(sourceID: sourceID) {
            case .cancelled:
                return
            case .reauthorized:
                break
            }

            let service = service
            sources = try await Self.offMain { try service.fetchSources() }
            await loadFirstPage()
            startCatalogReconcileRunnerIfNeeded()
        } catch {
            phase = previousPhase
            notice = .sourceActionFailed
        }
    }

    func disableSource(_ sourceID: UUID) async {
        guard !isBusy else { return }
        notice = nil
        do {
            _ = try await service.disableFolderSource(sourceID: sourceID)
            let service = service
            sources = try await Self.offMain { try service.fetchSources() }
            await loadFirstPage()
        } catch {
            notice = .sourceActionFailed
        }
    }

    func rescan() async {
        guard !isBusy, !sources.isEmpty else { return }
        if let selectedSourceID, isPhotosSource(selectedSourceID) {
            await connectPhotos()
            return
        }
        let service = service
        let sourceIDs = selectedSourceID.map { [$0] } ?? sources.map(\.id)
        do {
            try await Self.offMain {
                try service.enqueueReconcile(sourceIDs: sourceIDs)
            }
        } catch {
            if items.isEmpty {
                phase = .failed(.scanFailed)
            } else {
                notice = .backgroundScanFailed
            }
            return
        }
        startCatalogReconcileRunnerIfNeeded()
    }

    func selectSource(_ sourceID: UUID?) async {
        guard selectedSourceID != sourceID else { return }
        selectedSourceID = sourceID
        await loadFirstPage()
    }

    func loadMoreIfNeeded(currentAssetID: UUID) async {
        guard currentAssetID == items.last?.assetID,
              let cursor = nextCursor,
              !isLoadingMore
        else {
            return
        }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let service = service
        let filter = currentFilter
        let sort = sort
        let requestID = assetPageRequestID
        do {
            let page = try await Self.offMain {
                try service.fetchAssetPage(filter: filter, sort: sort, cursor: cursor)
            }
            guard assetPageRequestID == requestID else { return }
            items.append(contentsOf: page.items)
            nextCursor = page.nextCursor
        } catch {
            guard assetPageRequestID == requestID else { return }
            phase = .failed(.catalogFailed)
        }
    }

    func thumbnailData(assetID: UUID) async -> Data? {
        if case let .downloaded(downloadedAssetID, data) = cloudPreviewState,
           downloadedAssetID == assetID
        {
            return data
        }
        return try? await service.loadThumbnail(assetID: assetID)
    }

    func previewData(assetID: UUID) async -> Data? {
        do {
            let data = try await service.loadPreview(assetID: assetID)
            if primarySelectedAssetID == assetID,
               cloudPreviewState.assetID == assetID
            {
                cloudPreviewState = .hidden
            }
            return data
        } catch PhotosLibraryError.cloudOnly {
            if primarySelectedAssetID == assetID {
                cloudPreviewState = .available(assetID: assetID)
            }
            return nil
        } catch {
            return nil
        }
    }

    func downloadCloudPreview(assetID: UUID) {
        guard primarySelectedAssetID == assetID else { return }
        cancelCloudPreviewTask(resetToAvailable: false)
        let requestID = UUID()
        cloudPreviewRequestID = requestID
        cloudPreviewState = .downloading(assetID: assetID, progress: 0)
        let service = service
        let model = self
        cloudPreviewTask = Task {
            do {
                let data = try await service.downloadCloudPreview(assetID: assetID) { progress in
                    Task { @MainActor in
                        guard model.cloudPreviewRequestID == requestID,
                              model.primarySelectedAssetID == assetID
                        else {
                            return
                        }
                        model.cloudPreviewState = .downloading(
                            assetID: assetID,
                            progress: min(max(progress, 0), 1)
                        )
                    }
                }
                try Task.checkCancellation()
                guard model.cloudPreviewRequestID == requestID,
                      model.primarySelectedAssetID == assetID
                else {
                    return
                }
                model.cloudPreviewState = .downloaded(assetID: assetID, data: data)
                model.cloudPreviewRequestID = nil
                model.cloudPreviewTask = nil
            } catch is CancellationError {
                guard model.cloudPreviewRequestID == requestID else { return }
                model.cloudPreviewState = .available(assetID: assetID)
                model.cloudPreviewRequestID = nil
                model.cloudPreviewTask = nil
            } catch {
                guard model.cloudPreviewRequestID == requestID else { return }
                model.cloudPreviewState = .failed(assetID: assetID)
                model.cloudPreviewRequestID = nil
                model.cloudPreviewTask = nil
            }
        }
    }

    func cancelCloudPreviewDownload(assetID: UUID) {
        guard cloudPreviewState.assetID == assetID else { return }
        cancelCloudPreviewTask(resetToAvailable: true)
    }

    func retryCloudPreviewDownload(assetID: UUID) {
        guard cloudPreviewState == .failed(assetID: assetID) else { return }
        downloadCloudPreview(assetID: assetID)
    }

    func selectAsset(
        _ assetID: UUID,
        additive: Bool = false,
        extendRange: Bool = false
    ) async {
        if extendRange,
           let anchorID = selectionAnchorID,
           let anchorIndex = items.firstIndex(where: { $0.assetID == anchorID }),
           let targetIndex = items.firstIndex(where: { $0.assetID == assetID })
        {
            let range = min(anchorIndex, targetIndex) ... max(anchorIndex, targetIndex)
            let rangeIDs = Set(range.map { items[$0].assetID })
            selectedAssetIDs = additive ? selectedAssetIDs.union(rangeIDs) : rangeIDs
        } else if additive {
            if selectedAssetIDs.contains(assetID) {
                selectedAssetIDs.remove(assetID)
            } else {
                selectedAssetIDs.insert(assetID)
            }
            selectionAnchorID = assetID
        } else {
            selectedAssetIDs = [assetID]
            selectionAnchorID = assetID
        }
        if selectedAssetIDs.count != 1 {
            isSinglePhotoPresented = false
        }
        resetCloudPreviewIfSelectionChanged()
        resetLocalModelSuggestionsForSelection()
        await refreshInspector()
    }

    func requestLocalModelSuggestions() async {
        guard let runtime = localModelSuggestions,
              let assetID = primarySelectedAssetID
        else {
            return
        }
        let requestID = UUID()
        localModelSuggestionTrack = .standard
        localModelSuggestionRequestID = requestID
        localModelSuggestionState = .loading(assetID: assetID)

        do {
            let imageData: Data
            if case let .downloaded(downloadedAssetID, data) = cloudPreviewState,
               downloadedAssetID == assetID
            {
                imageData = data
            } else {
                imageData = try await service.loadPreview(assetID: assetID)
            }
            let suggestions = try await runtime.client.suggestions(
                imageData: imageData,
                requestID: requestID.uuidString.lowercased(),
                target: runtime.target
            )
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            localModelSuggestionState = .results(assetID: assetID, suggestions: suggestions)
            localModelSuggestionRequestID = nil
        } catch PhotosLibraryError.cloudOnly {
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            localModelSuggestionState = .previewUnavailable(assetID: assetID)
            localModelSuggestionRequestID = nil
        } catch LocalModelSuggestionClientError.serviceUnavailable {
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            localModelSuggestionState = .serviceUnavailable(assetID: assetID)
            localModelSuggestionRequestID = nil
        } catch {
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            localModelSuggestionState = .failed(assetID: assetID)
            localModelSuggestionRequestID = nil
        }
    }

    func requestPersonalModelSuggestions() async {
        guard let runtime = localModelSuggestions,
              let assetID = primarySelectedAssetID
        else {
            return
        }
        let requestID = UUID()
        localModelSuggestionTrack = .personal
        localModelSuggestionRequestID = requestID
        localModelSuggestionState = .loading(assetID: assetID)

        do {
            let availability = try await runtime.client.personalCapability()
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            guard case let .available(capability) = availability else {
                localModelSuggestionState = .personalUnavailable(assetID: assetID)
                localModelSuggestionRequestID = nil
                return
            }
            let activeTagIDs = Set(tags.filter { $0.state == .active }.map(\.id))
            try Self.validatePersonalCapability(
                capability,
                catalogScopeID: runtime.catalogScopeID,
                activeTagIDs: activeTagIDs
            )

            let imageData: Data
            if case let .downloaded(downloadedAssetID, data) = cloudPreviewState,
               downloadedAssetID == assetID
            {
                imageData = data
            } else {
                imageData = try await service.loadPreview(assetID: assetID)
            }
            let suggestions = try await runtime.client.suggestions(
                imageData: imageData,
                requestID: requestID.uuidString.lowercased(),
                target: .personal(capability.target)
            )
            let currentActiveTagIDs = Set(tags.filter { $0.state == .active }.map(\.id))
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            _ = try Self.personalPredictions(
                suggestions,
                capability: capability,
                activeTagIDs: currentActiveTagIDs
            )
            localModelSuggestionState = .results(assetID: assetID, suggestions: suggestions)
            localModelSuggestionRequestID = nil
        } catch PhotosLibraryError.cloudOnly {
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            localModelSuggestionState = .previewUnavailable(assetID: assetID)
            localModelSuggestionRequestID = nil
        } catch LocalModelSuggestionClientError.serviceUnavailable {
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            localModelSuggestionState = .serviceUnavailable(assetID: assetID)
            localModelSuggestionRequestID = nil
        } catch {
            guard localModelSuggestionRequestID == requestID,
                  primarySelectedAssetID == assetID
            else {
                return
            }
            localModelSuggestionState = .failed(assetID: assetID)
            localModelSuggestionRequestID = nil
        }
    }

    func generatePersonalLibrarySuggestions() async {
        guard !isGeneratingPersonalLibrarySuggestions,
              !isRebuildingPersonalModel
        else { return }
        guard let runtime = localModelSuggestions else {
            personalLibrarySuggestionState = .serviceUnavailable
            return
        }

        personalLibrarySuggestionState = .waiting(checked: 0, suggested: 0, skipped: 0)

        do {
            let availability = try await runtime.client.personalCapability()
            guard case let .available(capability) = availability else {
                let reviewPort = review
                try await Self.offMain {
                    try reviewPort.invalidatePersonalSuggestionBundle()
                }
                await refreshReviewState()
                personalLibrarySuggestionState = .personalUnavailable
                return
            }
            try Self.validatePersonalCapability(
                capability,
                catalogScopeID: runtime.catalogScopeID,
                activeTagIDs: Set(tags.filter { $0.state == .active }.map(\.id))
            )

            let reviewPort = review
            try await Self.offMain {
                _ = try reviewPort.enqueuePersonalLibrarySuggestions(capability: capability)
            }
            await refreshReviewState()
            startPersonalizationRunnerIfNeeded()
        } catch PersonalizationReviewError.activeJobConflict {
            await refreshReviewState()
            startPersonalizationRunnerIfNeeded()
        } catch LocalModelSuggestionClientError.identityMismatch {
            await invalidatePersonalLibrarySuggestionBundle()
            personalLibrarySuggestionState = .failed
        } catch let LocalModelSuggestionClientError.rejected(statusCode, code)
            where statusCode == 409 && code == "personal_bundle_mismatch"
        {
            await invalidatePersonalLibrarySuggestionBundle()
            personalLibrarySuggestionState = .failed
        } catch let LocalModelSuggestionClientError.rejected(statusCode, code)
            where statusCode == 503 && code == "personal_bundle_unavailable"
        {
            await invalidatePersonalLibrarySuggestionBundle()
            personalLibrarySuggestionState = .personalUnavailable
        } catch LocalModelSuggestionClientError.serviceUnavailable {
            personalLibrarySuggestionState = .serviceUnavailable
        } catch let LocalModelSuggestionClientError.rejected(statusCode, _)
            where statusCode == 503
        {
            personalLibrarySuggestionState = .serviceUnavailable
        } catch is CancellationError {
            personalLibrarySuggestionState = .idle
        } catch {
            personalLibrarySuggestionState = .failed
        }
    }

    private func invalidatePersonalLibrarySuggestionBundle() async {
        let reviewPort = review
        try? await Self.offMain {
            try reviewPort.invalidatePersonalSuggestionBundle()
        }
        await refreshReviewState()
    }

    private static func validatePersonalCapability(
        _ capability: PersonalModelSuggestionCapability,
        catalogScopeID: String,
        activeTagIDs: Set<UUID>
    ) throws {
        let target = capability.target
        guard target.catalogScopeID == catalogScopeID,
              !target.bundleID.isEmpty,
              !target.bundleRevision.isEmpty,
              !target.provider.isEmpty,
              !target.modelID.isEmpty,
              !target.modelRevision.isEmpty,
              !target.preprocessingRevision.isEmpty,
              target.elementCount > 0,
              isLowercaseSHA256(target.labelVocabularyRevision),
              isLowercaseSHA256(target.weightsSHA256),
              !target.policyRevision.isEmpty,
              !capability.tagIDs.isEmpty,
              Set(capability.tagIDs).count == capability.tagIDs.count,
              Set(capability.tagIDs).isSubset(of: activeTagIDs)
        else {
            throw LocalModelSuggestionClientError.identityMismatch
        }
    }

    private static func personalPredictions(
        _ suggestions: [LocalModelSuggestion],
        capability: PersonalModelSuggestionCapability,
        activeTagIDs: Set<UUID>
    ) throws -> [PersonalSuggestionPrediction] {
        let tagIDs = suggestions.compactMap(\.tagID)
        guard tagIDs.count == suggestions.count,
              Set(tagIDs).count == tagIDs.count,
              suggestions.allSatisfy({ suggestion in
                  guard let tagID = suggestion.tagID else { return false }
                  return suggestion.score.isFinite
                      && suggestion.track == .personal
                      && suggestion.conceptID == nil
                      && suggestion.recommendedState == .suggested
                      && capability.tagIDs.contains(tagID)
                      && activeTagIDs.contains(tagID)
                      && suggestion.catalogScopeID == capability.target.catalogScopeID
                      && suggestion.bundleID == capability.target.bundleID
                      && suggestion.bundleRevision == capability.target.bundleRevision
                      && suggestion.provider == capability.target.provider
                      && suggestion.modelID == capability.target.modelID
                      && suggestion.modelRevision == capability.target.modelRevision
                      && suggestion.preprocessingRevision == capability.target.preprocessingRevision
                      && suggestion.elementCount == capability.target.elementCount
                      && suggestion.labelVocabularyRevision == capability.target.labelVocabularyRevision
                      && suggestion.weightsSHA256 == capability.target.weightsSHA256
                      && suggestion.policyRevision == capability.target.policyRevision
                      && suggestion.standardPackID == nil
                      && suggestion.standardPackRevision == nil
              })
        else {
            throw LocalModelSuggestionClientError.identityMismatch
        }
        return suggestions.compactMap { suggestion in
            suggestion.tagID.map {
                PersonalSuggestionPrediction(tagID: $0, score: suggestion.score)
            }
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            ("0" ... "9").contains(String($0)) || ("a" ... "f").contains(String($0))
        }
    }

    func applyLocalModelSuggestionDecision(
        _ suggestion: LocalModelSuggestion,
        action: LibraryTagDecisionAction
    ) async {
        guard suggestion.track == .personal,
              let tagID = suggestion.tagID,
              tags.contains(where: { $0.id == tagID && $0.state == .active }),
              case let .results(assetID, suggestions) = localModelSuggestionState,
              primarySelectedAssetID == assetID,
              suggestions.contains(suggestion),
              action == .accept || action == .reject
        else {
            return
        }
        guard await applyTagDecision(tagID: tagID, action: action, assetIDs: [assetID]) else {
            return
        }
        localModelSuggestionState = .results(
            assetID: assetID,
            suggestions: suggestions.filter { $0 != suggestion }
        )
    }

    func rebuildPersonalModel() async {
        guard !isRebuildingPersonalModel,
              !isGeneratingPersonalLibrarySuggestions
        else { return }
        guard let runtime = localModelSuggestions else {
            notice = .personalModelRebuildServiceUnavailable
            return
        }
        isRebuildingPersonalModel = true
        notice = nil
        defer { isRebuildingPersonalModel = false }

        do {
            let snapshot = try review.personalTrainingSnapshot()
            let activeTagIDs = Set(tags.filter { $0.state == .active }.map(\.id))
            guard snapshot.catalogScopeID == runtime.catalogScopeID,
                  !snapshot.personalTagIDs.isEmpty,
                  Set(snapshot.personalTagIDs).count == snapshot.personalTagIDs.count,
                  Set(snapshot.personalTagIDs).isSubset(of: activeTagIDs),
                  Self.hasMinimumPersonalTrainingSamples(snapshot)
            else {
                notice = .personalModelRebuildNotReady
                return
            }

            let expectedActiveBundle: PersonalModelActiveBundleIdentity?
            switch try await runtime.client.personalCapability() {
            case .unavailable:
                expectedActiveBundle = nil
            case let .available(capability):
                guard capability.target.catalogScopeID == runtime.catalogScopeID else {
                    throw LocalModelSuggestionClientError.identityMismatch
                }
                expectedActiveBundle = PersonalModelActiveBundleIdentity(
                    bundleRevision: capability.target.bundleRevision,
                    weightsSHA256: capability.target.weightsSHA256
                )
            }

            let revisions = Set(snapshot.decisions.map {
                PersonalTrainingAssetRevision(
                    assetID: $0.assetID,
                    contentRevision: $0.contentRevision
                )
            }).sorted(by: PersonalTrainingAssetRevision.isOrderedBefore)
            var encoder: PersonalTrainingEncoderIdentity?
            var embeddings: [PersonalTrainingEmbeddingRow] = []
            for revision in revisions {
                try Task.checkCancellation()
                let imageData = try await service.loadPreview(assetID: revision.assetID)
                let embedding = try await runtime.client.embedding(
                    imageData: imageData,
                    requestID: UUID().uuidString.lowercased(),
                    cacheKey: PersonalTrainingEmbeddingCacheKey(
                        catalogScopeID: runtime.catalogScopeID,
                        assetID: revision.assetID,
                        contentRevision: revision.contentRevision
                    )
                )
                if let encoder {
                    guard encoder == embedding.encoder else {
                        throw LocalModelSuggestionClientError.identityMismatch
                    }
                } else {
                    encoder = embedding.encoder
                }
                embeddings.append(
                    PersonalTrainingEmbeddingRow(
                        assetID: revision.assetID,
                        contentRevision: revision.contentRevision,
                        values: embedding.values
                    )
                )
            }

            try Task.checkCancellation()
            guard try review.personalTrainingSnapshot() == snapshot,
                  let encoder
            else {
                throw LocalModelSuggestionClientError.identityMismatch
            }
            let tagIDs = snapshot.personalTagIDs.sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }
            let rebuildSnapshot = PersonalModelRebuildSnapshot(
                catalogScopeID: snapshot.catalogScopeID,
                decisionSnapshotRevision: Self.decisionSnapshotRevision(snapshot),
                encoder: encoder,
                personalTagIDs: tagIDs,
                labelVocabularyRevision: Self.labelVocabularyRevision(tagIDs),
                embeddings: embeddings,
                decisions: snapshot.decisions
            )
            let requestID = UUID().uuidString.lowercased()
            let rebuilt = try await runtime.client.rebuildPersonalModel(
                requestID: requestID,
                expectedActiveBundle: expectedActiveBundle,
                snapshot: rebuildSnapshot
            )
            guard case let .available(confirmed) = try await runtime.client.personalCapability(),
                  confirmed == rebuilt
            else {
                throw LocalModelSuggestionClientError.identityMismatch
            }
            notice = .personalModelRebuildCompleted(
                tagCount: tagIDs.count,
                sampleCount: embeddings.count
            )
        } catch PhotosLibraryError.cloudOnly {
            notice = .personalModelRebuildPreviewUnavailable
        } catch LocalModelSuggestionClientError.serviceUnavailable {
            notice = .personalModelRebuildServiceUnavailable
        } catch let LocalModelSuggestionClientError.rejected(statusCode, code)
            where statusCode == 503
                && (code == "model_unavailable" || code == "personal_rebuild_unavailable")
        {
            notice = .personalModelRebuildServiceUnavailable
        } catch is CancellationError {
            notice = nil
        } catch {
            notice = .personalModelRebuildFailed
        }
    }

    private struct PersonalTrainingAssetRevision: Hashable {
        let assetID: UUID
        let contentRevision: Int

        static func isOrderedBefore(
            _ lhs: PersonalTrainingAssetRevision,
            _ rhs: PersonalTrainingAssetRevision
        ) -> Bool {
            let lhsID = lhs.assetID.uuidString.lowercased()
            let rhsID = rhs.assetID.uuidString.lowercased()
            return lhsID == rhsID
                ? lhs.contentRevision < rhs.contentRevision
                : lhsID < rhsID
        }
    }

    private static func hasMinimumPersonalTrainingSamples(
        _ snapshot: PersonalTrainingSnapshot
    ) -> Bool {
        snapshot.personalTagIDs.allSatisfy { tagID in
            snapshot.decisions.filter {
                $0.tagID == tagID && $0.state == .manualAccepted
            }.count >= 2 && snapshot.decisions.filter {
                $0.tagID == tagID && $0.state == .manualRejected
            }.count >= 2
        }
    }

    private static func labelVocabularyRevision(_ tagIDs: [UUID]) -> String {
        sha256(tagIDs.map { $0.uuidString.lowercased() }.joined(separator: "\n"))
    }

    private static func decisionSnapshotRevision(_ snapshot: PersonalTrainingSnapshot) -> String {
        let decisions = snapshot.decisions.sorted { lhs, rhs in
            let lhsKey = "\(lhs.tagID.uuidString.lowercased())|\(lhs.assetID.uuidString.lowercased())|\(lhs.contentRevision)|\(lhs.state.rawValue)"
            let rhsKey = "\(rhs.tagID.uuidString.lowercased())|\(rhs.assetID.uuidString.lowercased())|\(rhs.contentRevision)|\(rhs.state.rawValue)"
            return lhsKey < rhsKey
        }
        let lines = ["catalog|\(snapshot.catalogScopeID)"]
            + snapshot.personalTagIDs.map { "tag|\($0.uuidString.lowercased())" }.sorted()
            + decisions.map {
                "decision|\($0.assetID.uuidString.lowercased())|\($0.contentRevision)|\($0.tagID.uuidString.lowercased())|\($0.state.rawValue)"
            }
        return sha256(lines.joined(separator: "\n"))
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func toggleSinglePhotoView() {
        guard primarySelectedAssetID != nil else { return }
        isSinglePhotoPresented.toggle()
    }

    func openSinglePhotoView(assetID: UUID) async {
        guard items.contains(where: { $0.assetID == assetID })
            || reviewQueueItems.contains(where: { $0.assetID == assetID })
        else { return }
        await selectAsset(assetID)
        isSinglePhotoPresented = true
    }

    func closeSinglePhotoView() {
        isSinglePhotoPresented = false
    }

    func moveSinglePhotoSelection(by offset: Int) async {
        guard isSinglePhotoPresented, offset != 0 else { return }
        if reviewMode != nil {
            await moveReviewPrimarySelection(
                in: offset > 0 ? .right : .left,
                columnCount: abs(offset)
            )
        } else {
            await movePrimarySelection(by: offset)
        }
    }

    func movePrimarySelection(by offset: Int) async {
        guard offset != 0, let currentID = primarySelectedAssetID else { return }

        if offset > 0,
           let currentIndex = items.firstIndex(where: { $0.assetID == currentID }),
           currentIndex + offset >= items.count,
           let lastLoadedID = items.last?.assetID
        {
            await loadMoreIfNeeded(currentAssetID: lastLoadedID)
        }

        guard let currentIndex = items.firstIndex(where: { $0.assetID == currentID }) else {
            return
        }
        let targetIndex = min(max(currentIndex + offset, 0), items.count - 1)
        guard targetIndex != currentIndex else { return }
        await selectAsset(items[targetIndex].assetID)
    }

    func movePrimarySelection(
        in direction: LibraryGridNavigationDirection,
        columnCount: Int
    ) async {
        if primarySelectedAssetID == nil {
            guard let firstAssetID = items.first?.assetID else { return }
            await selectAsset(firstAssetID)
            return
        }
        let columns = max(columnCount, 1)
        let offset = switch direction {
        case .left: -1
        case .right: 1
        case .up: -columns
        case .down: columns
        }
        await movePrimarySelection(by: offset)
    }

    func applyTagDecision(tagID: UUID, action: LibraryTagDecisionAction) async {
        let assetIDs = Array(selectedAssetIDs)
        _ = await applyTagDecision(tagID: tagID, action: action, assetIDs: assetIDs)
    }

    @discardableResult
    private func applyTagDecision(
        tagID: UUID,
        action: LibraryTagDecisionAction,
        assetIDs: [UUID]
    ) async -> Bool {
        guard !assetIDs.isEmpty else { return false }
        let service = service
        do {
            notice = nil
            let snapshot = try await Self.offMain {
                try service.mutateTag(tagID: tagID, assetIDs: assetIDs, action: action)
            }
            lastTagMutation = LibraryTagUndoRecord(snapshot: snapshot, appliedDecision: action.decision)
            applyGridDecision(snapshot: snapshot, newDecision: action.decision)
            if mutationAffectsCurrentFilter(tagID: tagID) {
                await loadFirstPage()
            }
            await refreshInspector()
            await refreshReviewState()
            return true
        } catch {
            notice = tagNotice(for: error)
            return false
        }
    }

    func requestTagDecision(tagID: UUID, action: LibraryTagDecisionAction) async {
        guard selectedAssetIDs.count > 1 else {
            await applyTagDecision(tagID: tagID, action: action)
            return
        }
        guard let displayName = tags.first(where: { $0.id == tagID })?.displayName else {
            return
        }
        pendingTagDecisionConfirmation = LibraryTagDecisionConfirmation(
            tagID: tagID,
            tagDisplayName: displayName,
            action: action,
            assetIDs: selectedAssetIDs
        )
    }

    func confirmPendingTagDecision(
        _ capturedConfirmation: LibraryTagDecisionConfirmation? = nil
    ) async {
        guard let pending = capturedConfirmation ?? pendingTagDecisionConfirmation else { return }
        pendingTagDecisionConfirmation = nil
        await applyTagDecision(
            tagID: pending.tagID,
            action: pending.action,
            assetIDs: Array(pending.assetIDs)
        )
    }

    func cancelPendingTagDecision() {
        pendingTagDecisionConfirmation = nil
    }

    func undoLastTagMutation() async {
        guard let undo = lastTagMutation else { return }
        let service = service
        do {
            notice = nil
            try await Self.offMain { try service.restoreTagMutation(undo.snapshot) }
            restoreGridDecision(undo)
            lastTagMutation = nil
            if mutationAffectsCurrentFilter(tagID: undo.snapshot.tagID) {
                await loadFirstPage()
            }
            await refreshInspector()
        } catch {
            notice = .tagMutationFailed
            return
        }
    }

    func createAndAcceptTag(named rawName: String) async {
        let assetIDs = Array(selectedAssetIDs)
        await createAndAcceptTag(named: rawName, assetIDs: assetIDs)
    }

    private func createAndAcceptTag(named rawName: String, assetIDs: [UUID]) async {
        guard !assetIDs.isEmpty else { return }
        let service = service
        do {
            notice = nil
            let result = try await Self.offMain {
                try service.createTagAndAccept(rawName: rawName, assetIDs: assetIDs)
            }
            let snapshot = result.restoreSnapshot()
            lastTagMutation = LibraryTagUndoRecord(snapshot: snapshot, appliedDecision: .accepted)
            applyGridDecision(snapshot: snapshot, newDecision: .accepted)
            tags.append(TagListItem(id: result.tagID, displayName: result.displayName, state: .active))
            tags.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            if tagPresence != .any || !TagNameNormalizer.trimUnicodeWhiteSpace(searchText).isEmpty {
                await loadFirstPage()
            }
            await refreshInspector()
        } catch {
            notice = tagNotice(for: error)
        }
    }

    func requestCreateAndAcceptTag(named rawName: String) async {
        guard case let .success(name) = TagNameNormalizer.validateAndNormalize(rawName) else {
            return
        }
        guard selectedAssetIDs.count > 1 else {
            await createAndAcceptTag(named: name.displayName)
            return
        }
        pendingNewTagConfirmation = LibraryNewTagConfirmation(
            tagDisplayName: name.displayName,
            assetIDs: selectedAssetIDs
        )
    }

    func confirmPendingNewTag(
        _ capturedConfirmation: LibraryNewTagConfirmation? = nil
    ) async {
        guard let pending = capturedConfirmation ?? pendingNewTagConfirmation else { return }
        pendingNewTagConfirmation = nil
        await createAndAcceptTag(
            named: pending.tagDisplayName,
            assetIDs: Array(pending.assetIDs)
        )
    }

    func cancelPendingNewTag() {
        pendingNewTagConfirmation = nil
    }

    func installPresetTags() async {
        let service = service
        do {
            notice = nil
            let result = try await Self.offMain { try service.installPresetTags() }
            guard !result.createdTags.isEmpty else {
                notice = .presetTagsAlreadyAvailable
                return
            }
            tags.append(contentsOf: result.createdTags)
            tags.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            lastTagMutation = nil
            notice = .presetTagsInstalled(createdCount: result.createdTags.count)
            await refreshInspector()
        } catch {
            notice = tagNotice(for: error)
        }
    }

    func renameTag(_ tagID: UUID, to rawName: String) async -> Bool {
        let service = service
        do {
            notice = nil
            let renamed = try await Self.offMain {
                try service.renameTag(tagID: tagID, rawName: rawName)
            }
            guard let index = tags.firstIndex(where: { $0.id == tagID }) else {
                notice = .tagMutationFailed
                return false
            }
            tags[index] = renamed
            tags.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            lastTagMutation = nil
            await loadFirstPage()
            await refreshInspector()
            return true
        } catch {
            notice = tagNotice(for: error)
            return false
        }
    }

    func archiveTag(_ tagID: UUID) async -> Bool {
        let service = service
        do {
            notice = nil
            try await Self.offMain { try service.archiveTag(tagID: tagID) }
            tags.removeAll { $0.id == tagID }
            selectedTagFilterDecisions.removeValue(forKey: tagID)
            selectedTagFilterIDs.remove(tagID)
            lastTagMutation = nil
            await loadFirstPage()
            await refreshInspector()
            return true
        } catch {
            notice = tagNotice(for: error)
            return false
        }
    }

    private func reload(runPendingJobs: Bool) async {
        phase = .loading
        let service = service
        do {
            sources = try await Self.offMain { try service.fetchSources() }
            tags = try await Self.offMain { try service.listTags() }
        } catch {
            phase = .failed(.catalogFailed)
            return
        }

        guard !sources.isEmpty else {
            items = []
            nextCursor = nil
            phase = .empty
            return
        }

        await loadFirstPage()
        await refreshReviewState()
        if runPendingJobs {
            startCatalogReconcileRunnerIfNeeded()
            startPersonalizationRunnerIfNeeded()
        }
    }

    private func startCatalogReconcileRunnerIfNeeded() {
        catalogReconcileRunRequested = true
        guard catalogReconcileTask == nil else { return }
        isCatalogScanning = true
        let service = service
        catalogReconcileTask = Task { [weak self] in
            guard let self else { return }
            let progressMonitor = Task { [weak self] in
                await self?.monitorCatalogReconcileProgress()
            }
            repeat {
                self.catalogReconcileRunRequested = false
                do {
                    try await Self.offMain {
                        try service.runPendingReconcileJobs()
                        try service.runPendingPhotosReconcileJobs()
                    }
                    if let refreshed = try? await Self.offMain({ try service.fetchSources() }) {
                        self.sources = refreshed
                    }
                    await self.loadFirstPage()
                    await self.refreshReviewState()
                    self.startPersonalizationRunnerIfNeeded()
                } catch {
                    self.catalogReconcileRunRequested = false
                    if let refreshed = try? await Self.offMain({ try service.fetchSources() }) {
                        self.sources = refreshed
                    }
                    if self.sources.contains(where: { $0.kind == .photos && $0.state == .authorizationRequired }) {
                        self.phase = .content
                        self.notice = .photosAuthorizationRequired
                    } else if self.items.isEmpty {
                        self.phase = .failed(.scanFailed)
                    } else {
                        self.notice = .backgroundScanFailed
                    }
                }
            } while self.catalogReconcileRunRequested
            progressMonitor.cancel()
            await progressMonitor.value
            self.catalogReconcileProgress = nil
            self.catalogReconcileTask = nil
            if self.catalogReconcileRunRequested {
                self.startCatalogReconcileRunnerIfNeeded()
            } else {
                self.isCatalogScanning = false
            }
        }
    }

    private func monitorCatalogReconcileProgress() async {
        let service = service
        var publishedFirstBatch = !items.isEmpty
        while !Task.isCancelled {
            if let progress = try? await Self.offMain({
                try service.fetchCatalogReconcileProgress()
            }) {
                catalogReconcileProgress = progress
                if !publishedFirstBatch, progress.completed > 0 {
                    await loadFirstPage()
                    publishedFirstBatch = !items.isEmpty
                }
            }
            do {
                try await Task.sleep(for: catalogProgressRefreshInterval)
            } catch {
                return
            }
        }
    }

    private func loadFirstPage() async {
        let requestID = UUID()
        assetPageRequestID = requestID
        let service = service
        let filter = currentFilter
        let sort = sort
        do {
            let page = try await Self.offMain {
                try service.fetchAssetPage(filter: filter, sort: sort, cursor: nil)
            }
            guard assetPageRequestID == requestID else { return }
            items = page.items
            nextCursor = page.nextCursor
            let hadSelection = !selectedAssetIDs.isEmpty
            let visibleIDs = Set(page.items.map(\.assetID))
            selectedAssetIDs.formIntersection(visibleIDs)
            resetCloudPreviewIfSelectionChanged()
            if selectedAssetIDs.isEmpty {
                isSinglePhotoPresented = false
                inspectorDetail = nil
                inspectorTags = []
                if hadSelection {
                    notice = .selectionHiddenByFilter
                }
            }
            phase = .content
        } catch {
            guard assetPageRequestID == requestID else { return }
            phase = .failed(.catalogFailed)
        }
    }

    func applySearchText(_ text: String) async {
        searchText = text
        await loadFirstPage()
    }

    func scheduleSearchText(_ text: String) {
        searchDebounceTask?.cancel()
        let interval = text.isEmpty ? Duration.zero : searchDebounceInterval
        searchDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            await self?.applySearchText(text)
        }
    }

    func submitSearchText(_ text: String) async {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        await applySearchText(text)
    }

    func toggleAcceptedTagFilter(_ tagID: UUID) async {
        if selectedTagFilterDecisions[tagID] == .accepted {
            selectedTagFilterDecisions.removeValue(forKey: tagID)
            selectedTagFilterIDs.remove(tagID)
        } else {
            selectedTagFilterDecisions[tagID] = .accepted
            selectedTagFilterIDs.insert(tagID)
            tagPresence = .any
        }
        await loadFirstPage()
    }

    func setTagMatchMode(_ mode: TagMatchMode) async {
        tagMatchMode = mode
        await loadFirstPage()
    }

    func setTagPresence(_ presence: TagPresenceFilter) async {
        tagPresence = presence
        if presence != .any {
            selectedTagFilterDecisions = [:]
            selectedTagFilterIDs = []
        }
        await loadFirstPage()
    }

    func setGridDensity(_ density: LibraryGridDensity) {
        gridDensity = density
    }

    func toggleAvailabilityFilter(_ availability: AssetAvailability) async {
        if let index = selectedAvailabilities.firstIndex(of: availability) {
            selectedAvailabilities.remove(at: index)
        } else {
            selectedAvailabilities.append(availability)
        }
        await loadFirstPage()
    }

    func clearAvailabilityFilters() async {
        guard !selectedAvailabilities.isEmpty else { return }
        selectedAvailabilities = []
        await loadFirstPage()
    }

    func toggleMediaTypeFilterGroup(_ mediaTypes: [String]) async {
        let mediaTypes = mediaTypes.filter { !$0.isEmpty }
        guard !mediaTypes.isEmpty else { return }

        if mediaTypes.allSatisfy(selectedMediaTypes.contains) {
            selectedMediaTypes.removeAll { mediaTypes.contains($0) }
        } else {
            for mediaType in mediaTypes where !selectedMediaTypes.contains(mediaType) {
                selectedMediaTypes.append(mediaType)
            }
        }
        await loadFirstPage()
    }

    func clearMediaTypeFilters() async {
        guard !selectedMediaTypes.isEmpty else { return }
        selectedMediaTypes = []
        await loadFirstPage()
    }

    func clearAssetPropertyFilters() async {
        guard hasAssetPropertyFilters else { return }
        selectedAvailabilities = []
        selectedMediaTypes = []
        await loadFirstPage()
    }

    func isMediaTypeFilterGroupSelected(_ mediaTypes: [String]) -> Bool {
        !mediaTypes.isEmpty && mediaTypes.allSatisfy(selectedMediaTypes.contains)
    }

    func setSort(_ newSort: AssetPageSort) async {
        guard sort != newSort else { return }
        sort = newSort
        await loadFirstPage()
    }

    func setTagDecisionFilter(
        tagID: UUID,
        decision: PersistableTagDecision?
    ) async {
        selectedTagFilterDecisions[tagID] = decision
        selectedTagFilterIDs = Set(selectedTagFilterDecisions.keys)
        if decision != nil {
            tagPresence = .any
        }
        await loadFirstPage()
    }

    func showAcceptedTag(_ tagID: UUID) async {
        selectedTagFilterDecisions = [tagID: .accepted]
        selectedTagFilterIDs = [tagID]
        tagPresence = .any
        tagMatchMode = .all
        await loadFirstPage()
    }

    func tagFilterDecision(for tagID: UUID) -> PersistableTagDecision? {
        selectedTagFilterDecisions[tagID]
    }

    private var currentFilter: AssetPageFilter {
        AssetPageFilter(
            sourceIDs: selectedSourceID.map { [$0] } ?? [],
            tagDecisionFilters: tags
                .filter { selectedTagFilterIDs.contains($0.id) }
                .compactMap { tag in
                    selectedTagFilterDecisions[tag.id].map {
                        TagDecisionFilter(tagID: tag.id, decision: $0)
                    }
                },
            tagMatchMode: tagMatchMode,
            availabilities: selectedAvailabilities,
            mediaTypes: selectedMediaTypes,
            tagPresence: tagPresence,
            searchText: searchText
        )
    }

    func dismissNotice() {
        notice = nil
    }

    private func tagNotice(for error: Error) -> LibraryWorkspaceNotice {
        switch error as? CatalogQueryError {
        case .invalidTagName:
            .invalidTagName
        case .duplicateTag:
            .duplicateTag
        default:
            .tagMutationFailed
        }
    }

    private func mutationAffectsCurrentFilter(tagID: UUID) -> Bool {
        selectedTagFilterIDs.contains(tagID) ||
        tagPresence != .any ||
        !TagNameNormalizer.trimUnicodeWhiteSpace(searchText).isEmpty
    }

    private func applyGridDecision(
        snapshot: TagMutationPriorStateSnapshot,
        newDecision: TagDecisionQueryState
    ) {
        for prior in snapshot.priorStates {
            replaceGridDecision(
                assetID: prior.assetID,
                oldDecision: prior.priorState,
                newDecision: newDecision
            )
        }
    }

    private func restoreGridDecision(_ undo: LibraryTagUndoRecord) {
        for prior in undo.snapshot.priorStates {
            replaceGridDecision(
                assetID: prior.assetID,
                oldDecision: undo.appliedDecision,
                newDecision: prior.priorState
            )
        }
    }

    private func replaceGridDecision(
        assetID: UUID,
        oldDecision: TagDecisionQueryState,
        newDecision: TagDecisionQueryState
    ) {
        guard let index = items.firstIndex(where: { $0.assetID == assetID }) else { return }
        switch oldDecision {
        case .accepted:
            items[index].acceptedTagCount = max(0, items[index].acceptedTagCount - 1)
        case .rejected:
            items[index].rejectedTagCount = max(0, items[index].rejectedTagCount - 1)
        case .unknown:
            break
        }
        switch newDecision {
        case .accepted:
            items[index].acceptedTagCount += 1
        case .rejected:
            items[index].rejectedTagCount += 1
        case .unknown:
            break
        }
    }


    private func refreshInspector() async {
        resetCloudPreviewIfSelectionChanged()
        let assetIDs = Array(selectedAssetIDs)
        guard !assetIDs.isEmpty else {
            inspectorDetail = nil
            inspectorTags = []
            assetPendingSuggestions = []
            return
        }

        let service = service
        let reviewPort = review
        let availableTags = tags
        do {
            if assetIDs.count == 1, let assetID = assetIDs.first {
                let detail = try await Self.offMain {
                    try service.fetchInspectorDetail(assetID: assetID)
                }
                inspectorDetail = detail
                inspectorTags = detail.tags
                    .filter { $0.tagState == .active }
                    .map {
                        LibraryInspectorTagPresentation(
                            id: $0.tagID,
                            displayName: $0.displayName,
                            decision: LibraryInspectorTagDecisionState($0.decision)
                        )
                    }
                assetPendingSuggestions = try await Self.offMain {
                    try reviewPort.pendingSuggestionsForAsset(assetID: assetID)
                }
            } else {
                let aggregates = try await Self.offMain {
                    try service.selectionAggregate(tagIDs: availableTags.map(\.id), assetIDs: assetIDs)
                }
                let aggregateByTagID = Dictionary(uniqueKeysWithValues: aggregates.map { ($0.tagID, $0) })
                inspectorDetail = nil
                assetPendingSuggestions = []
                inspectorTags = availableTags.compactMap { tag in
                    guard let aggregate = aggregateByTagID[tag.id] else { return nil }
                    let decision: LibraryInspectorTagDecisionState
                    if aggregate.acceptedCount == assetIDs.count {
                        decision = .accepted
                    } else if aggregate.rejectedCount == assetIDs.count {
                        decision = .rejected
                    } else if aggregate.unknownCount == assetIDs.count {
                        decision = .unknown
                    } else {
                        decision = .mixed
                    }
                    return LibraryInspectorTagPresentation(
                        id: tag.id,
                        displayName: tag.displayName,
                        decision: decision
                    )
                }
            }
        } catch {
            inspectorDetail = nil
            inspectorTags = []
            assetPendingSuggestions = []
        }
    }

    private static func offMain<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: operation).value
    }

    private func resetCloudPreviewIfSelectionChanged() {
        guard cloudPreviewState.assetID != nil,
              cloudPreviewState.assetID != primarySelectedAssetID
        else {
            return
        }
        cancelCloudPreviewTask(resetToAvailable: false)
        cloudPreviewState = .hidden
    }

    private func resetLocalModelSuggestionsForSelection() {
        localModelSuggestionRequestID = nil
        localModelSuggestionTrack = .standard
        guard localModelSuggestions != nil,
              let assetID = primarySelectedAssetID
        else {
            localModelSuggestionState = .hidden
            return
        }
        localModelSuggestionState = .ready(assetID: assetID)
    }

    private func cancelCloudPreviewTask(resetToAvailable: Bool) {
        let assetID = cloudPreviewState.assetID
        cloudPreviewRequestID = nil
        cloudPreviewTask?.cancel()
        cloudPreviewTask = nil
        if resetToAvailable, let assetID {
            cloudPreviewState = .available(assetID: assetID)
        }
    }
}

extension LibraryWorkspaceModel {
    var isReviewMode: Bool { reviewMode != nil }

    var canUndoReviewMutation: Bool { lastReviewMutation != nil }

    func refreshReviewState() async {
        let reviewPort = review
        do {
            pendingSuggestionTotal = try await Self.offMain { try reviewPort.totalPendingSuggestionCount() }
            suggestionOverviews = try await Self.offMain { try reviewPort.tagOverviews() }
            let personalJob = try await Self.offMain {
                try reviewPort.personalLibrarySuggestionJob()
            }
            if let personalJob {
                personalLibrarySuggestionState = Self.personalLibraryPresentation(
                    for: personalJob
                )
            }
            if case let .tagQueue(tagID, _) = reviewMode {
                await loadReviewQueueFirstPage(tagID: tagID)
            }
            if let assetID = primarySelectedAssetID, reviewMode == nil {
                assetPendingSuggestions = try await Self.offMain {
                    try reviewPort.pendingSuggestionsForAsset(assetID: assetID)
                }
            } else {
                assetPendingSuggestions = []
            }
        } catch {
            suggestionOverviews = []
            pendingSuggestionTotal = 0
        }
    }

    private static func personalLibraryPresentation(
        for job: PersonalLibrarySuggestionJobProjection
    ) -> PersonalLibrarySuggestionPresentationState {
        let counts = (
            checked: job.checkedCount,
            suggested: job.suggestedCount,
            skipped: job.skippedCount
        )
        switch job.state {
        case .pending:
            return .waiting(
                checked: counts.checked,
                suggested: counts.suggested,
                skipped: counts.skipped
            )
        case .running:
            return .running(
                checked: counts.checked,
                suggested: counts.suggested,
                skipped: counts.skipped
            )
        case .paused:
            return .paused(
                checked: counts.checked,
                suggested: counts.suggested,
                skipped: counts.skipped
            )
        case .retryableFailed:
            return .retryableFailure(
                checked: counts.checked,
                suggested: counts.suggested,
                skipped: counts.skipped
            )
        case .completed:
            return .completed(
                checked: counts.checked,
                suggested: counts.suggested,
                skipped: counts.skipped
            )
        case .cancelled:
            return .cancelled(
                checked: counts.checked,
                suggested: counts.suggested,
                skipped: counts.skipped
            )
        case .terminalFailed:
            return job.lastErrorCode == .personalLibraryBundleUnavailable
                ? .personalUnavailable
                : .failed
        }
    }

    func enterReviewOverview() async {
        reviewMode = .overview
        selectedAssetIDs = []
        isSinglePhotoPresented = false
        await refreshReviewState()
    }

    func enterReviewQueue(tagID: UUID, displayName: String) async {
        reviewMode = .tagQueue(tagID: tagID, displayName: displayName)
        selectedAssetIDs = []
        isSinglePhotoPresented = false
        await loadReviewQueueFirstPage(tagID: tagID)
    }

    func exitReviewMode() async {
        reviewMode = nil
        reviewQueueItems = []
        reviewNextCursor = nil
        await loadFirstPage()
        await refreshReviewState()
    }

    func loadReviewQueueFirstPage(tagID: UUID) async {
        let reviewPort = review
        do {
            let page = try await Self.offMain {
                try reviewPort.fetchReviewQueue(tagID: tagID, cursor: nil, limit: 100)
            }
            reviewQueueItems = page.items
            reviewNextCursor = page.nextCursor
        } catch {
            reviewQueueItems = []
            reviewNextCursor = nil
        }
    }

    func loadMoreReviewQueueIfNeeded(currentAssetID: UUID, tagID: UUID) async {
        guard currentAssetID == reviewQueueItems.last?.assetID,
              let cursor = reviewNextCursor,
              !isLoadingMoreReviewQueue
        else { return }
        isLoadingMoreReviewQueue = true
        defer { isLoadingMoreReviewQueue = false }
        let reviewPort = review
        do {
            let page = try await Self.offMain {
                try reviewPort.fetchReviewQueue(tagID: tagID, cursor: cursor, limit: 100)
            }
            reviewQueueItems.append(contentsOf: page.items)
            reviewNextCursor = page.nextCursor
        } catch {}
    }

    func moveReviewPrimarySelection(
        in direction: LibraryGridNavigationDirection,
        columnCount: Int
    ) async {
        guard case let .tagQueue(tagID, _) = reviewMode else { return }
        guard let currentID = primarySelectedAssetID else {
            guard let firstAssetID = reviewQueueItems.first?.assetID else { return }
            await selectAsset(firstAssetID)
            return
        }

        let columns = max(columnCount, 1)
        let offset = switch direction {
        case .left: -1
        case .right: 1
        case .up: -columns
        case .down: columns
        }

        if offset > 0,
           let currentIndex = reviewQueueItems.firstIndex(where: { $0.assetID == currentID }),
           currentIndex + offset >= reviewQueueItems.count,
           let lastLoadedID = reviewQueueItems.last?.assetID
        {
            await loadMoreReviewQueueIfNeeded(
                currentAssetID: lastLoadedID,
                tagID: tagID
            )
        }

        guard let currentIndex = reviewQueueItems.firstIndex(where: { $0.assetID == currentID }) else {
            return
        }
        let targetIndex = min(max(currentIndex + offset, 0), reviewQueueItems.count - 1)
        guard targetIndex != currentIndex else { return }
        await selectAsset(reviewQueueItems[targetIndex].assetID)
    }

    func requestEnqueueSuggestions(
        tagID: UUID,
        displayName: String,
        mode: PersonalizationReviewEnqueueMode,
        sourceCount: Int
    ) {
        pendingSuggestionConfirmation = SuggestionEnqueueConfirmation(
            tagID: tagID,
            displayName: displayName,
            mode: mode,
            sourceCount: sourceCount
        )
    }

    func confirmPendingSuggestionEnqueue(
        _ capturedConfirmation: SuggestionEnqueueConfirmation? = nil
    ) async -> Bool {
        guard let pending = capturedConfirmation ?? pendingSuggestionConfirmation else {
            return false
        }
        pendingSuggestionConfirmation = nil
        let reviewPort = review
        do {
            notice = nil
            _ = try await Self.offMain {
                try reviewPort.enqueueFullLibrarySuggestions(tagID: pending.tagID, mode: pending.mode)
            }
            startPersonalizationRunnerIfNeeded()
            await refreshReviewState()
            return true
        } catch let error as PersonalizationReviewError {
            notice = reviewNotice(for: error)
            return false
        } catch {
            notice = .reviewActionFailed
            return false
        }
    }

    func cancelPendingSuggestionEnqueue() {
        pendingSuggestionConfirmation = nil
    }

    private func startPersonalizationRunnerIfNeeded() {
        guard personalizationRunnerTask == nil else { return }
        let reviewPort = review
        let worker = PersonalizationSuggestionRunner.startLoop(review: reviewPort) { [weak self] in
            guard let self else { return }
            await self.refreshReviewState()
            if case let .tagQueue(tagID, _) = self.reviewMode {
                await self.loadReviewQueueFirstPage(tagID: tagID)
            }
        }
        personalizationRunnerTask = Task { [weak self] in
            await worker.value
            self?.personalizationRunnerTask = nil
        }
    }

    func enqueueSuggestions(tagID: UUID, mode: PersonalizationReviewEnqueueMode) async -> Bool {
        guard let overview = suggestionOverviews.first(where: { $0.id == tagID }) else { return false }
        requestEnqueueSuggestions(
            tagID: tagID,
            displayName: overview.displayName,
            mode: mode,
            sourceCount: sources.filter { $0.state == .active }.count
        )
        return true
    }

    func pauseSuggestionJob(_ jobID: UUID) async {
        let reviewPort = review
        try? await Self.offMain { try reviewPort.pauseSuggestionJob(jobID: jobID) }
        await refreshReviewState()
    }

    func resumeSuggestionJob(_ jobID: UUID) async {
        let reviewPort = review
        try? await Self.offMain { try reviewPort.resumeSuggestionJob(jobID: jobID) }
        startPersonalizationRunnerIfNeeded()
        await refreshReviewState()
    }

    func cancelSuggestionJob(_ jobID: UUID) async {
        let reviewPort = review
        try? await Self.offMain { try reviewPort.cancelSuggestionJob(jobID: jobID) }
        await refreshReviewState()
    }

    func applyReviewDecision(action: LibraryTagDecisionAction) async {
        guard case let .tagQueue(tagID, displayName) = reviewMode else { return }
        let assetIDs = Array(selectedAssetIDs)
        guard !assetIDs.isEmpty else { return }
        let workspace = service
        do {
            notice = nil
            let snapshot = try await Self.offMain {
                try workspace.mutateTag(tagID: tagID, assetIDs: assetIDs, action: action)
            }
            lastReviewMutation = ReviewMutationUndoRecord(
                snapshot: snapshot,
                appliedDecision: action.decision,
                tagDisplayName: displayName,
                affectedCount: assetIDs.count
            )
            notice = .reviewMutationApplied(count: assetIDs.count, tagName: displayName)
            let queueBefore = reviewQueueItems
            let selected = selectedAssetIDs
            reviewQueueItems.removeAll { selected.contains($0.assetID) }
            if let next = Self.nextReviewQueueSelection(
                in: reviewQueueItems,
                afterRemoving: selected,
                from: queueBefore
            ) {
                selectedAssetIDs = [next]
            } else {
                selectedAssetIDs = []
                isSinglePhotoPresented = false
            }
            await refreshReviewState()
            await refreshInspector()
        } catch {
            notice = .tagMutationFailed
        }
    }

    func deferReviewSelection() async {
        guard case .tagQueue = reviewMode,
              !selectedAssetIDs.isEmpty,
              !reviewQueueItems.isEmpty
        else { return }
        let selected = selectedAssetIDs
        if let next = Self.deferredReviewSelection(in: reviewQueueItems, selected: selected) {
            selectedAssetIDs = next
            resetCloudPreviewIfSelectionChanged()
            await refreshInspector()
        }
    }

    private static func deferredReviewSelection(
        in queue: [ReviewQueueItemProjection],
        selected: Set<UUID>
    ) -> Set<UUID>? {
        guard let lastSelectedIndex = queue.enumerated()
            .filter({ selected.contains($0.element.assetID) })
            .map(\.offset)
            .max()
        else { return nil }

        if let next = queue.enumerated()
            .first(where: { $0.offset > lastSelectedIndex && !selected.contains($0.element.assetID) }) {
            return [next.element.assetID]
        }
        if let wrap = queue.enumerated()
            .first(where: { !selected.contains($0.element.assetID) }) {
            return [wrap.element.assetID]
        }
        return nil
    }

    private static func nextReviewQueueSelection(
        in queue: [ReviewQueueItemProjection],
        afterRemoving selected: Set<UUID>,
        from original: [ReviewQueueItemProjection]
    ) -> UUID? {
        guard let lastSelectedIndex = original.enumerated()
            .filter({ selected.contains($0.element.assetID) })
            .map(\.offset)
            .max()
        else { return queue.first?.assetID }

        if let next = original.enumerated()
            .first(where: { $0.offset > lastSelectedIndex && !selected.contains($0.element.assetID) })?
            .element.assetID,
            queue.contains(where: { $0.assetID == next })
        {
            return next
        }
        return queue.first?.assetID
    }

    func undoLastReviewMutation() async {
        guard let undo = lastReviewMutation else { return }
        let workspace = service
        do {
            notice = nil
            try await Self.offMain { try workspace.restoreTagMutation(undo.snapshot) }
            lastReviewMutation = nil
            if case let .tagQueue(tagID, _) = reviewMode {
                await loadReviewQueueFirstPage(tagID: tagID)
            }
            await refreshReviewState()
            await refreshInspector()
        } catch {
            notice = .tagMutationFailed
        }
    }

    func applyInspectorSuggestion(tagID: UUID, action: LibraryTagDecisionAction) async {
        guard let assetID = primarySelectedAssetID else { return }
        let workspace = service
        do {
            notice = nil
            _ = try await Self.offMain {
                try workspace.mutateTag(tagID: tagID, assetIDs: [assetID], action: action)
            }
            assetPendingSuggestions.removeAll { $0.tagID == tagID }
            await refreshInspector()
            await refreshReviewState()
        } catch {
            notice = .tagMutationFailed
        }
    }

    private func reviewNotice(for error: PersonalizationReviewError) -> LibraryWorkspaceNotice {
        switch error {
        case let .insufficientSamples(positive, negative):
            .insufficientSuggestionSamples(positiveMissing: positive, negativeMissing: negative)
        case .activeJobConflict:
            .reviewJobConflict
        default:
            .reviewActionFailed
        }
    }
}

private enum LibrarySidebarSelection: Hashable {
    case all
    case untagged
    case reviewSuggestions
    case source(UUID)
    case tag(UUID)
}

private enum LibraryWorkspaceSheet: String, Identifiable {
    case commandPalette
    case keyboardShortcuts

    var id: String { rawValue }
}

private struct LibraryMediaFormatFilterOption {
    let title: String
    let mediaTypes: [String]
}

struct LibraryWorkspaceView: View {
    private static let mediaFormatFilterOptions = [
        LibraryMediaFormatFilterOption(title: "JPEG", mediaTypes: [UTType.jpeg.identifier]),
        LibraryMediaFormatFilterOption(title: "PNG", mediaTypes: [UTType.png.identifier]),
        LibraryMediaFormatFilterOption(
            title: "HEIC / HEIF",
            mediaTypes: [UTType.heic.identifier, UTType.heif.identifier]
        ),
        LibraryMediaFormatFilterOption(title: "TIFF", mediaTypes: [UTType.tiff.identifier]),
        LibraryMediaFormatFilterOption(title: "WebP", mediaTypes: [UTType.webP.identifier]),
    ]

    @ObservedObject var model: LibraryWorkspaceModel
    @State private var selection: LibrarySidebarSelection? = .all
    @State private var searchText = ""
    @State private var newTagName = ""
    @State private var sourcePendingDisable: LibrarySourceSummary?
    @State private var photosSourcePendingRebind: LibrarySourceSummary?
    @State private var tagPendingRename: TagListItem?
    @State private var renamedTagName = ""
    @State private var tagPendingArchive: TagListItem?
    @State private var showPhotosConnectionExplanation = false
    @State private var showPreviewCachePanel = false
    @State private var showPreviewCacheClearConfirmation = false
    @State private var showJobActivityPanel = false
    @State private var activeSheet: LibraryWorkspaceSheet?
    @State private var commandSearchText = ""
    @State private var gridColumnCount = 1
    @State private var gridScrollTargetID: UUID?
    @State private var layoutState = LibraryWorkspaceLayoutState()
    @FocusState private var newTagFieldFocused: Bool
    @FocusState private var contentFocused: Bool
    @FocusState private var commandSearchFieldFocused: Bool

    private var workspaceWithSourceControls: some View {
        NavigationSplitView(columnVisibility: sidebarColumnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            content
                .navigationTitle("全部照片")
                .focusable()
                .focused($contentFocused)
                .focusEffectDisabled()
                .onKeyPress(.space) {
                    guard model.primarySelectedAssetID != nil else { return .ignored }
                    model.toggleSinglePhotoView()
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard model.isSinglePhotoPresented else { return .ignored }
                    model.closeSinglePhotoView()
                    return .handled
                }
                .onKeyPress("p") {
                    handleSinglePhotoReviewDecisionKey(.accept)
                }
                .onKeyPress("x") {
                    handleSinglePhotoReviewDecisionKey(.reject)
                }
                .onKeyPress("u") {
                    handleSinglePhotoReviewDeferKey()
                }
                .onKeyPress(
                    keys: [.leftArrow, .rightArrow, .upArrow, .downArrow],
                    action: handleGridNavigationKey
                )
        }
        .inspector(isPresented: inspectorVisibility) {
            inspector
                .inspectorColumnWidth(min: 240, ideal: 300, max: 380)
        }
        .frame(minWidth: 640, minHeight: 560)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        layoutState.updateWindowWidth(proxy.size.width)
                    }
                    .onChange(of: proxy.size.width) { _, width in
                        layoutState.updateWindowWidth(width)
                    }
            }
        }
        .confirmationDialog(
            suggestionConfirmationTitle(model.pendingSuggestionConfirmation),
            isPresented: Binding(
                get: { model.pendingSuggestionConfirmation != nil },
                set: { if !$0 { model.cancelPendingSuggestionEnqueue() } }
            ),
            titleVisibility: .visible
        ) {
            if let pending = model.pendingSuggestionConfirmation {
                Button("开始") {
                    Task { _ = await model.confirmPendingSuggestionEnqueue(pending) }
                }
            }
            Button("取消", role: .cancel) {
                model.cancelPendingSuggestionEnqueue()
            }
        } message: {
            if let pending = model.pendingSuggestionConfirmation {
                Text(suggestionConfirmationMessage(pending))
            }
        }
        .confirmationDialog(
            tagDecisionConfirmationTitle(model.pendingTagDecisionConfirmation),
            isPresented: Binding(
                get: { model.pendingTagDecisionConfirmation != nil },
                set: { if !$0 { model.cancelPendingTagDecision() } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingTagDecisionConfirmation
        ) { pending in
            Button(tagDecisionConfirmationActionTitle(pending.action)) {
                Task { await model.confirmPendingTagDecision(pending) }
            }
            Button("取消", role: .cancel) {
                model.cancelPendingTagDecision()
            }
        } message: { pending in
            Text("这会修改 \(pending.affectedCount) 张照片的人工标签决定；完成后仍可撤销一次。原照片不会被修改。")
        }
        .confirmationDialog(
            newTagConfirmationTitle(model.pendingNewTagConfirmation),
            isPresented: Binding(
                get: { model.pendingNewTagConfirmation != nil },
                set: { if !$0 { model.cancelPendingNewTag() } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingNewTagConfirmation
        ) { pending in
            Button("创建并应用") {
                Task { await model.confirmPendingNewTag(pending) }
            }
            Button("取消", role: .cancel) {
                model.cancelPendingNewTag()
            }
        } message: { pending in
            Text("这会创建“\(pending.tagDisplayName)”并应用到 \(pending.affectedCount) 张照片；完成后仍可撤销一次。原照片不会被修改。")
        }
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: "搜索文件名、路径、标签或来源"
        )
        .onSubmit(of: .search) {
            Task { await model.submitSearchText(searchText) }
        }
        .onChange(of: searchText) { _, newValue in
            model.scheduleSearchText(newValue)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    layoutState.toggleSidebar()
                } label: {
                    Label(
                        layoutState.isSidebarPresented ? "隐藏侧栏" : "显示侧栏",
                        systemImage: "sidebar.left"
                    )
                }
                .help(layoutState.isSidebarPresented ? "隐藏侧栏" : "显示侧栏")

                Button {
                    layoutState.toggleInspector()
                } label: {
                    Label(
                        layoutState.isInspectorPresented ? "隐藏检查器" : "显示检查器",
                        systemImage: "sidebar.right"
                    )
                }
                .help(layoutState.isInspectorPresented ? "隐藏检查器" : "显示检查器")

                if model.isCatalogScanning {
                    HStack(spacing: 6) {
                        if let progress = model.catalogReconcileProgress,
                           let total = progress.total,
                           total > 0
                        {
                            ProgressView(value: Double(progress.completed), total: Double(total))
                                .frame(width: 42)
                                .controlSize(.small)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(catalogProgressTitle(model.catalogReconcileProgress))
                            .font(.caption)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(catalogProgressTitle(model.catalogReconcileProgress))
                }

                if model.supportsPersonalModelRebuild {
                    Button {
                        Task { await model.rebuildPersonalModel() }
                    } label: {
                        if model.isRebuildingPersonalModel {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("重建个人模型", systemImage: "brain.head.profile")
                        }
                    }
                    .disabled(
                        model.isRebuildingPersonalModel
                            || model.isGeneratingPersonalLibrarySuggestions
                    )
                    .help("使用当前人工确认与拒绝样本重建个人模型")
                }

                filterMenu
                sortMenu

                if !model.items.isEmpty, model.reviewMode == nil {
                    Picker(
                        "缩略图大小",
                        selection: Binding(
                            get: { model.gridDensity },
                            set: { model.setGridDensity($0) }
                        )
                    ) {
                        ForEach(LibraryGridDensity.allCases, id: \.self) { density in
                            Text(density.displayName).tag(density)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("缩略图大小")
                    .help("调整照片网格缩略图大小")
                }

                Button {
                    Task { await model.undoLastTagMutation() }
                } label: {
                    Label("撤销标签操作", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canUndoTagMutation)

                if model.canUndoReviewMutation {
                    Button {
                        Task { await model.undoLastReviewMutation() }
                    } label: {
                        Label("撤销审核操作", systemImage: "arrow.uturn.backward.circle")
                    }
                }

                Button {
                    Task { await model.connectFolder() }
                } label: {
                    Label("连接文件夹", systemImage: "folder.badge.plus")
                }
                .disabled(model.isBusy)

                Button {
                    Task { await model.exportPortableUserData() }
                } label: {
                    Label("导出用户数据", systemImage: "square.and.arrow.up")
                }
                .disabled(model.isBusy || model.isExportingPortableData)

                Button {
                    showPreviewCachePanel = true
                    Task { await model.refreshPreviewCacheUsage() }
                } label: {
                    Label("预览缓存", systemImage: "internaldrive")
                }
                .popover(isPresented: $showPreviewCachePanel) {
                    previewCachePanel
                }

                Button {
                    activeSheet = .commandPalette
                } label: {
                    Label("命令", systemImage: "command")
                }
                .keyboardShortcut("k", modifiers: .command)
                .help("打开命令面板（⌘K）")

                Button {
                    showJobActivityPanel = true
                    Task { await model.refreshJobActivity() }
                } label: {
                    Label("活动", systemImage: "clock.arrow.circlepath")
                }
                .popover(isPresented: $showJobActivityPanel) {
                    jobActivityPanel
                }

                Button {
                    Task { await model.rescan() }
                } label: {
                    Label("立即重扫", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy || !model.canRescan)
            }
        }
        .toolbar(removing: .sidebarToggle)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let notice = model.notice {
                noticeBar(notice)
            }
        }
        .confirmationDialog(
            sourcePendingDisable.map { "停用“\($0.displayName)”来源？" } ?? "停用来源？",
            isPresented: Binding(
                get: { sourcePendingDisable != nil },
                set: { if !$0 { sourcePendingDisable = nil } }
            ),
            titleVisibility: .visible,
            presenting: sourcePendingDisable
        ) { source in
            Button("停用来源", role: .destructive) {
                sourcePendingDisable = nil
                Task { await model.disableSource(source.id) }
            }
            Button("取消", role: .cancel) {
                sourcePendingDisable = nil
            }
        } message: { _ in
            Text("ImageAll 会停止该来源的扫描任务，但保留已索引的照片、人工标签和历史；原照片不会被修改。")
        }
        .confirmationDialog(
            "连接当前系统照片图库？",
            isPresented: Binding(
                get: { photosSourcePendingRebind != nil },
                set: { if !$0 { photosSourcePendingRebind = nil } }
            ),
            titleVisibility: .visible,
            presenting: photosSourcePendingRebind
        ) { source in
            Button("保留历史并连接") {
                photosSourcePendingRebind = nil
                Task { await model.rebindPhotos(from: source.id) }
            }
            Button("取消", role: .cancel) {
                photosSourcePendingRebind = nil
            }
        } message: { _ in
            Text("ImageAll 会保留旧图库的索引、人工标签和历史，并为当前系统照片图库创建一个新的来源。不会迁移或合并无法确认身份的照片，也不会修改 Apple Photos 中的原图。")
        }
        .confirmationDialog(
            "连接 Apple Photos？",
            isPresented: $showPhotosConnectionExplanation,
            titleVisibility: .visible
        ) {
            Button("继续并请求照片权限") {
                Task { await model.connectPhotos() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("ImageAll 会只读访问静态照片和元数据，在自身容器保存索引、标签和缓存；不会修改、移动或删除 Apple Photos 中的照片。iCloud 原图不会自动下载。")
        }
    }

    private var previewCachePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("预览缓存")
                .font(.headline)
            LabeledContent("条目", value: "\(model.previewCacheUsage.entryCount)")
            LabeledContent(
                "已登记用量",
                value: formattedByteCount(model.previewCacheUsage.registeredBytes)
            )
            Divider()
            Button("清理预览缓存", role: .destructive) {
                showPreviewCacheClearConfirmation = true
            }
            .disabled(
                model.previewCacheUsage.entryCount == 0 || model.isClearingPreviewCache
            )
        }
        .padding()
        .frame(width: 280)
        .confirmationDialog(
            "清理预览缓存？",
            isPresented: $showPreviewCacheClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清理预览缓存", role: .destructive) {
                showPreviewCachePanel = false
                Task { await model.clearPreviewCache() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除可重建的网格缩略图和单图预览；不会删除原照片、人工标签、Feature Print 或个性化模型。iCloud 预览之后需要再次手动获取。")
        }
    }

    private var jobActivityPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("活动")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await model.refreshJobActivity() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新活动")
            }

            if model.jobActivityItems.isEmpty {
                ContentUnavailableView(
                    "暂无活动",
                    systemImage: "clock",
                    description: Text("同步和个性化任务会显示在这里。")
                )
                .frame(height: 150)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.jobActivityItems) { item in
                            jobActivityRow(item)
                            if item.id != model.jobActivityItems.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .padding()
        .frame(width: 380)
    }

    private func jobActivityRow(_ item: JobActivityItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(jobActivityTitle(item.kind))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(jobActivityStateText(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(jobActivityProgressText(item.progress))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if !item.availableActions.isEmpty {
                HStack {
                    ForEach(item.availableActions, id: \.self) { action in
                        Button(jobActivityActionTitle(action), role: action == .cancel ? .destructive : nil) {
                            Task { await model.applyJobActivityAction(action, to: item.id) }
                        }
                        .disabled(model.isApplyingJobActivityAction(item.id))
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 10)
    }

    private func jobActivityTitle(_ kind: JobActivityKind) -> String {
        switch kind {
        case .folderReconcile: "文件夹同步"
        case .photosReconcile: "Apple Photos 同步"
        case .personalizationSuggestions: "个性化建议"
        case .background: "后台任务"
        }
    }

    private func jobActivityStateText(_ item: JobActivityItem) -> String {
        switch (item.state, item.controlRequest) {
        case (.running, .pause): "正在暂停"
        case (.running, .cancel): "正在取消"
        case (.pending, _): "等待中"
        case (.running, _): "运行中"
        case (.paused, _): "已暂停"
        case (.retryableFailed, _): "等待重试"
        case (.completed, _): "已完成"
        case (.terminalFailed, _): "失败"
        case (.cancelled, _): "已取消"
        }
    }

    private func jobActivityProgressText(_ progress: JobProgress) -> String {
        if let total = progress.total {
            return "进度 \(progress.completed) / \(total)"
        }
        return "已处理 \(progress.completed)"
    }

    private func jobActivityActionTitle(_ action: JobActivityAction) -> String {
        switch action {
        case .pause: "暂停"
        case .resume: "继续"
        case .cancel: "取消"
        }
    }

    private func formattedByteCount(_ bytes: UInt64) -> String {
        guard let signedBytes = Int64(exactly: bytes) else { return "超过可显示范围" }
        return ByteCountFormatter.string(fromByteCount: signedBytes, countStyle: .file)
    }

    var body: some View {
        workspaceWithSourceControls
        .alert(
            "重命名标签",
            isPresented: Binding(
                get: { tagPendingRename != nil },
                set: {
                    if !$0 {
                        tagPendingRename = nil
                        renamedTagName = ""
                    }
                }
            ),
            presenting: tagPendingRename
        ) { tag in
            TextField("标签名称", text: $renamedTagName)
            Button("重命名") {
                let candidate = renamedTagName
                tagPendingRename = nil
                renamedTagName = ""
                Task { _ = await model.renameTag(tag.id, to: candidate) }
            }
            .disabled(TagNameNormalizer.trimUnicodeWhiteSpace(renamedTagName).isEmpty)
            Button("取消", role: .cancel) {
                tagPendingRename = nil
                renamedTagName = ""
            }
        } message: { tag in
            Text("为“\(tag.displayName)”输入新名称。现有人工标签决定会保留。")
        }
        .confirmationDialog(
            tagPendingArchive.map { "归档“\($0.displayName)”标签？" } ?? "归档标签？",
            isPresented: Binding(
                get: { tagPendingArchive != nil },
                set: { if !$0 { tagPendingArchive = nil } }
            ),
            titleVisibility: .visible,
            presenting: tagPendingArchive
        ) { tag in
            Button("归档标签", role: .destructive) {
                let shouldReturnToAllPhotos = selection == .tag(tag.id)
                tagPendingArchive = nil
                Task {
                    if await model.archiveTag(tag.id), shouldReturnToAllPhotos {
                        selection = .all
                    }
                }
            }
            Button("取消", role: .cancel) {
                tagPendingArchive = nil
            }
        } message: { _ in
            Text("标签会从侧栏和编辑器隐藏，但已保存的人工确认、拒绝和历史都会保留。")
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .commandPalette:
                commandPalette
            case .keyboardShortcuts:
                keyboardShortcuts
            }
        }
        .task { await model.start() }
        .onChange(of: selection) { _, newValue in
            Task {
                switch newValue {
                case .all, .none:
                    await model.exitReviewMode()
                    await model.setTagPresence(.any)
                    await model.selectSource(nil)
                case .untagged:
                    await model.exitReviewMode()
                    await model.selectSource(nil)
                    await model.setTagPresence(.untagged)
                case .reviewSuggestions:
                    await model.enterReviewOverview()
                case let .source(sourceID):
                    await model.exitReviewMode()
                    await model.setTagPresence(.any)
                    await model.selectSource(sourceID)
                case let .tag(tagID):
                    await model.exitReviewMode()
                    await model.selectSource(nil)
                    await model.showAcceptedTag(tagID)
                }
            }
        }
    }

    private var sidebarColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { layoutState.isSidebarPresented ? .all : .detailOnly },
            set: { layoutState.setSidebarPresented($0 != .detailOnly) }
        )
    }

    private var inspectorVisibility: Binding<Bool> {
        Binding(
            get: { layoutState.isInspectorPresented },
            set: { layoutState.setInspectorPresented($0) }
        )
    }

    private var commandPalette: some View {
        let commands = model.workspaceCommands(matching: commandSearchText, layout: layoutState)
        return VStack(alignment: .leading, spacing: 12) {
            Text("命令")
                .font(.headline)
            TextField("搜索命令", text: $commandSearchText)
                .textFieldStyle(.roundedBorder)
                .focused($commandSearchFieldFocused)
                .onSubmit {
                    if let command = commands.first(where: \.isEnabled) {
                        execute(command.command)
                    }
                }

            if commands.isEmpty {
                ContentUnavailableView.search(text: commandSearchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(commands) { item in
                    Button {
                        execute(item.command)
                    } label: {
                        Label(item.title, systemImage: item.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.isEnabled)
                }
                .listStyle(.inset)
            }
        }
        .padding()
        .frame(width: 460, height: 500)
        .accessibilityIdentifier("libraryCommandPalette")
        .onAppear {
            commandSearchText = ""
            commandSearchFieldFocused = true
        }
        .onExitCommand {
            activeSheet = nil
        }
    }

    private var keyboardShortcuts: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("快捷键")
                    .font(.title2.bold())
                Spacer()
                Button("完成") {
                    activeSheet = nil
                }
                .keyboardShortcut(.defaultAction)
            }
            shortcutRow("打开命令面板", keys: "⌘K")
            shortcutRow("切换单图查看", keys: "Space")
            shortcutRow("返回照片网格", keys: "Esc")
            shortcutRow("移动照片选择", keys: "←  ↑  ↓  →")
            Spacer()
        }
        .padding(24)
        .frame(width: 420, height: 280)
        .onExitCommand {
            activeSheet = nil
        }
    }

    private func shortcutRow(_ title: String, keys: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(keys)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func execute(_ command: LibraryWorkspaceCommand) {
        if command == .showKeyboardShortcuts {
            activeSheet = .keyboardShortcuts
            return
        }

        activeSheet = nil
        switch command {
        case .showAllPhotos:
            selection = .all
        case .showReviewSuggestions:
            selection = .reviewSuggestions
        case .showActivity:
            Task { @MainActor in
                await Task.yield()
                showJobActivityPanel = true
                await model.refreshJobActivity()
            }
        case .toggleSidebar:
            layoutState.toggleSidebar()
        case .toggleInspector:
            layoutState.toggleInspector()
        case let .showSource(sourceID):
            selection = .source(sourceID)
        case let .showTag(tagID):
            selection = .tag(tagID)
        case let .acceptTag(tagID):
            Task { await model.requestTagDecision(tagID: tagID, action: .accept) }
        case let .rejectTag(tagID):
            Task { await model.requestTagDecision(tagID: tagID, action: .reject) }
        case let .clearTagDecision(tagID):
            Task { await model.requestTagDecision(tagID: tagID, action: .clear) }
        case .createTag:
            newTagFieldFocused = true
        case .connectFolder:
            Task { await model.connectFolder() }
        case .rescanCurrentSource:
            Task { await model.rescan() }
        case .toggleSinglePhoto:
            model.toggleSinglePhotoView()
        case .showKeyboardShortcuts:
            break
        }
    }

    private func handleGridNavigationKey(_ keyPress: KeyPress) -> KeyPress.Result {
        let hasNavigableItems = model.reviewMode == nil
            ? !model.items.isEmpty
            : !model.reviewQueueItems.isEmpty
        guard hasNavigableItems else { return .ignored }
        let direction: LibraryGridNavigationDirection
        switch keyPress.key {
        case .leftArrow: direction = .left
        case .rightArrow: direction = .right
        case .upArrow: direction = .up
        case .downArrow: direction = .down
        default: return .ignored
        }

        if model.isSinglePhotoPresented, direction == .up || direction == .down {
            return .ignored
        }
        if model.reviewMode != nil {
            guard direction == .left || direction == .right else { return .ignored }
            Task {
                await model.moveReviewPrimarySelection(in: direction, columnCount: 1)
            }
            return .handled
        }

        Task {
            await model.movePrimarySelection(in: direction, columnCount: gridColumnCount)
            gridScrollTargetID = model.primarySelectedAssetID
        }
        return .handled
    }

    private func handleSinglePhotoReviewDecisionKey(
        _ action: LibraryTagDecisionAction
    ) -> KeyPress.Result {
        guard contentFocused,
              model.isSinglePhotoPresented,
              model.reviewMode != nil,
              !model.selectedAssetIDs.isEmpty
        else { return .ignored }
        Task { await model.applyReviewDecision(action: action) }
        return .handled
    }

    private func handleSinglePhotoReviewDeferKey() -> KeyPress.Result {
        guard contentFocused,
              model.isSinglePhotoPresented,
              model.reviewMode != nil,
              !model.selectedAssetIDs.isEmpty
        else { return .ignored }
        Task { await model.deferReviewSelection() }
        return .handled
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("图库") {
                Label("全部照片", systemImage: "photo.on.rectangle.angled")
                    .tag(LibrarySidebarSelection.all)
                Label("无标签", systemImage: "tag.slash")
                    .tag(LibrarySidebarSelection.untagged)
                HStack {
                    Label("待审核建议", systemImage: "sparkles")
                    Spacer()
                    if model.pendingSuggestionTotal > 0 {
                        Text("\(model.pendingSuggestionTotal)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(LibrarySidebarSelection.reviewSuggestions)
            }
            Section("来源") {
                ForEach(model.sources) { source in
                    sourceRow(source)
                        .tag(LibrarySidebarSelection.source(source.id))
                }
                Button {
                    Task { await model.connectFolder() }
                } label: {
                    Label("连接文件夹…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                if !model.sources.contains(where: { $0.kind == .photos }) {
                    Button {
                        showPhotosConnectionExplanation = true
                    } label: {
                        Label("连接 Apple Photos…", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy)
                }
            }
            Section("标签") {
                ForEach(model.tags, id: \.id) { tag in
                    tagRow(tag)
                        .tag(LibrarySidebarSelection.tag(tag.id))
                }
                Button {
                    Task { await model.installPresetTags() }
                } label: {
                    Label("添加常用标签", systemImage: "tag.badge.plus")
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                Button {
                    newTagFieldFocused = true
                } label: {
                    Label("新建标签…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .disabled(model.selectedAssetIDs.isEmpty)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("ImageAll")
    }

    private func tagRow(_ tag: TagListItem) -> some View {
        Label(tag.displayName, systemImage: "tag")
            .contextMenu {
                Button("在图库中查看") {
                    selection = .tag(tag.id)
                }
                Button("重命名…") {
                    renamedTagName = tag.displayName
                    tagPendingRename = tag
                }

                Divider()

                Button("归档标签", role: .destructive) {
                    tagPendingArchive = tag
                }
            }
    }

    private func sourceRow(_ source: LibrarySourceSummary) -> some View {
        HStack(spacing: 8) {
            Label(
                source.displayName,
                systemImage: source.kind == .photos ? "photo.on.rectangle" : sourceIcon(source.state)
            )
                .lineLimit(1)
            Spacer(minLength: 4)
            if let status = source.kind == .photos && source.state == .unavailable
                ? "历史"
                : sourceStatusText(source.state)
            {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .help(sourceHelpText(source.state))
        .contextMenu {
            Button("在图库中查看") {
                selection = .source(source.id)
            }
            Button(source.kind == .photos ? "立即同步" : "立即重扫") {
                selection = .source(source.id)
                Task {
                    await model.selectSource(source.id)
                    await model.rescan()
                }
            }
            .disabled(model.isBusy || source.state != .active)

            if source.kind == .photos && source.state == .unavailable {
                Button("连接当前系统图库…") {
                    photosSourcePendingRebind = source
                }
                .disabled(model.isBusy)
            } else {
                Button(source.kind == .photos && source.state == .disabled ? "重新启用…" : "重新授权…") {
                    Task { await model.reauthorizeSource(source.id) }
                }
                .disabled(
                    model.isBusy ||
                    (source.kind == .folder && source.state != .unavailable && source.state != .authorizationRequired) ||
                    (source.kind == .photos && source.state != .authorizationRequired && source.state != .disabled)
                )
            }

            Divider()

            Button("停用来源", role: .destructive) {
                sourcePendingDisable = source
            }
            .disabled(
                model.isBusy || source.state == .disabled ||
                (source.kind == .photos && source.state == .unavailable)
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("正在打开图库…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .scanning:
            ProgressView("正在扫描照片…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            if model.showsFirstUseGuide {
                ContentUnavailableView {
                    Label("开始建立你的照片资料库", systemImage: "photo.stack")
                } description: {
                    Text("连接一个照片来源，也可以添加一组可编辑的常用标签。常用标签不会分析照片，也不会自动应用到任何照片。")
                } actions: {
                    Button("连接照片文件夹…") {
                        Task { await model.connectFolder() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("连接 Apple Photos…") {
                        showPhotosConnectionExplanation = true
                    }
                    .buttonStyle(.bordered)
                    Button("添加常用标签") {
                        Task { await model.installPresetTags() }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                ContentUnavailableView {
                    Label("ImageAll 在原位置读取照片", systemImage: "photo.stack")
                } description: {
                    Text("不会导入、移动、重命名或删除原图。索引、标签和缩略图保存在 ImageAll 自己的应用容器中。")
                } actions: {
                    Button("连接照片文件夹…") {
                        Task { await model.connectFolder() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("连接 Apple Photos…") {
                        showPhotosConnectionExplanation = true
                    }
                    .buttonStyle(.bordered)
                }
            }
        case .content:
            if case .overview = model.reviewMode {
                ReviewOverviewView(
                    model: model,
                    onOpenQueue: { tagID, name in
                        Task { await model.enterReviewQueue(tagID: tagID, displayName: name) }
                    },
                    onBack: {
                        selection = .all
                    }
                )
            } else if case let .tagQueue(tagID, displayName) = model.reviewMode {
                if model.isSinglePhotoPresented,
                   let assetID = model.primarySelectedAssetID,
                   let item = model.reviewQueueItems.first(where: { $0.assetID == assetID })
                {
                    SinglePhotoReviewView(item: item, model: model)
                        .onAppear { contentFocused = true }
                } else {
                    ReviewQueueContentView(
                        model: model,
                        tagID: tagID,
                        displayName: displayName,
                        contentFocused: $contentFocused
                    )
                }
            } else if model.items.isEmpty {
                if model.hasAssetPropertyFilters {
                    ContentUnavailableView {
                        Label("没有符合筛选的照片", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("请调整可用状态或文件格式筛选。")
                    } actions: {
                        Button("清除状态和格式筛选") {
                            Task { await model.clearAssetPropertyFilters() }
                        }
                    }
                } else {
                    if model.selectedSourceIsPhotos {
                        if let unavailableSource = model.selectedUnavailablePhotosSource {
                            ContentUnavailableView {
                                Label("系统照片图库已更换", systemImage: "photo.badge.exclamationmark")
                            } description: {
                                Text("旧来源的索引、人工标签和历史仍保留。确认后可为当前系统照片图库创建一个新的来源。")
                            } actions: {
                                Button("保留历史并连接当前图库…") {
                                    photosSourcePendingRebind = unavailableSource
                                }
                            }
                        } else if model.selectedPhotosSourceNeedsAuthorization || model.notice == .photosAuthorizationRequired {
                            ContentUnavailableView {
                                Label("需要照片访问权限", systemImage: "lock.trianglebadge.exclamationmark")
                            } description: {
                                Text("请允许 ImageAll 访问照片。Debug App 重新构建后，macOS 可能要求再次授权。")
                            } actions: {
                                Button("重新检查并同步") {
                                    Task { await model.connectPhotos() }
                                }
                                Button("打开照片权限设置…") {
                                    openPhotosPrivacySettings()
                                }
                            }
                        } else {
                            ContentUnavailableView {
                                Label("系统照片图库中没有可访问的照片", systemImage: "photo.on.rectangle")
                            } description: {
                                Text("ImageAll 只能读取 Mac 的系统照片图库。如果 Photos 当前打开的是另一个图库，请先在 Photos > 设置 > 通用中确认系统照片图库。更改系统图库可能影响 iCloud Photos。")
                            } actions: {
                                Button("立即同步") {
                                    Task { await model.connectPhotos() }
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView {
                            Label("没有支持的照片", systemImage: "photo")
                        } description: {
                            Text("支持 JPEG、PNG、HEIC/HEIF、TIFF 和 WebP。")
                        } actions: {
                            Button("立即重扫") {
                                Task { await model.rescan() }
                            }
                        }
                    }
                }
            } else {
                if model.isSinglePhotoPresented,
                   let assetID = model.primarySelectedAssetID,
                   let item = model.items.first(where: { $0.assetID == assetID })
                {
                    SinglePhotoView(item: item, model: model)
                        .onAppear { contentFocused = true }
                } else {
                    assetGrid
                }
            }
        case let .failed(error):
            ContentUnavailableView {
                Label(errorTitle(error), systemImage: "exclamationmark.triangle")
            } description: {
                Text("原照片没有被修改。请检查来源是否仍可用、授权是否有效，然后重试。")
            } actions: {
                Button("重试") {
                    Task { await model.rescan() }
                }
                .disabled(model.sources.isEmpty)
            }
        }
    }

    private var assetGrid: some View {
        let widthRange = model.gridDensity.cellWidthRange
        return GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(
                                    minimum: widthRange.lowerBound,
                                    maximum: widthRange.upperBound
                                ),
                                spacing: LibraryGridLayout.spacing
                            ),
                        ],
                        spacing: LibraryGridLayout.spacing
                    ) {
                        ForEach(model.items, id: \.assetID) { item in
                            AssetThumbnailView(
                                item: item,
                                model: model,
                                isSelected: model.selectedAssetIDs.contains(item.assetID),
                                onSelect: {
                                    contentFocused = true
                                    let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                                    Task {
                                        await model.selectAsset(
                                            item.assetID,
                                            additive: flags.contains(.command),
                                            extendRange: flags.contains(.shift)
                                        )
                                    }
                                },
                                onOpen: {
                                    contentFocused = true
                                    Task {
                                        await model.openSinglePhotoView(assetID: item.assetID)
                                    }
                                }
                            )
                                .id(item.assetID)
                                .task {
                                    await model.loadMoreIfNeeded(currentAssetID: item.assetID)
                                }
                        }
                    }
                    .padding(LibraryGridLayout.horizontalPadding)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .accessibilityLabel("照片网格")
                .onAppear {
                    updateGridColumnCount(containerWidth: proxy.size.width)
                    contentFocused = true
                    gridScrollTargetID = model.primarySelectedAssetID
                }
                .onChange(of: proxy.size.width) { _, width in
                    updateGridColumnCount(containerWidth: width)
                }
                .onChange(of: model.gridDensity) { _, _ in
                    updateGridColumnCount(containerWidth: proxy.size.width)
                }
                .onChange(of: gridScrollTargetID) { _, assetID in
                    guard let assetID else { return }
                    scrollProxy.scrollTo(assetID, anchor: .center)
                    gridScrollTargetID = nil
                }
            }
        }
    }

    private func updateGridColumnCount(containerWidth: CGFloat) {
        gridColumnCount = LibraryGridLayout.columnCount(
            containerWidth: containerWidth,
            density: model.gridDensity
        )
    }

    private var inspector: some View {
        Group {
            if model.selectedAssetIDs.isEmpty {
                ContentUnavailableView(
                    "未选择照片",
                    systemImage: "sidebar.right",
                    description: Text("选择一张或多张照片以查看信息并编辑人工标签。")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(model.selectedAssetIDs.count == 1 ? "1 张照片" : "\(model.selectedAssetIDs.count) 张照片")
                            .font(.headline)

                        if let detail = model.inspectorDetail {
                            InspectorPreview(assetID: detail.assetID, model: model)
                            if model.reviewMode == nil {
                                InspectorLocalModelSuggestionSection(model: model)
                                InspectorSuggestionSection(model: model)
                            } else if case let .tagQueue(tagID, displayName) = model.reviewMode {
                                reviewInspectorActions(tagID: tagID, displayName: displayName)
                            }
                        } else if !model.assetPendingSuggestions.isEmpty {
                            InspectorSuggestionSection(model: model)
                        }

                        Divider()
                        tagEditor

                        if let detail = model.inspectorDetail {
                            Divider()
                            metadata(detail)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("检查器")
    }

    private var tagEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("人工标签")
                .font(.headline)

            HStack(spacing: 6) {
                TextField("新标签名称", text: $newTagName)
                    .focused($newTagFieldFocused)
                    .onSubmit { createTag() }
                Button {
                    createTag()
                } label: {
                    Image(systemName: "plus")
                }
                .help("创建标签并确认应用到所选照片")
                .disabled(
                    model.selectedAssetIDs.isEmpty ||
                    TagNameNormalizer.trimUnicodeWhiteSpace(newTagName).isEmpty
                )
            }

            if model.inspectorTags.isEmpty {
                Text("尚无标签。可在上方创建并应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.inspectorTags) { tag in
                    inspectorTagRow(tag)
                }
            }
        }
    }

    private func inspectorTagRow(_ tag: LibraryInspectorTagPresentation) -> some View {
        HStack(spacing: 6) {
            Text(tag.displayName)
                .lineLimit(1)
            Spacer(minLength: 4)
            if tag.decision == .mixed {
                Text("混合")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            tagDecisionButton(
                systemImage: "checkmark",
                label: "确认 \(tag.displayName)",
                isActive: tag.decision == .accepted
            ) {
                await model.requestTagDecision(tagID: tag.id, action: .accept)
            }
            tagDecisionButton(
                systemImage: "xmark",
                label: "拒绝 \(tag.displayName)",
                isActive: tag.decision == .rejected
            ) {
                await model.requestTagDecision(tagID: tag.id, action: .reject)
            }
            tagDecisionButton(
                systemImage: "minus",
                label: "清除 \(tag.displayName) 的决定",
                isActive: tag.decision == .unknown
            ) {
                await model.requestTagDecision(tagID: tag.id, action: .clear)
            }
        }
    }

    private func tagDecisionButton(
        systemImage: String,
        label: String,
        isActive: Bool,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: systemImage)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.bordered)
        .tint(isActive ? .accentColor : .secondary)
        .background(
            isActive ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .help(label)
        .accessibilityLabel(label)
    }

    private func metadata(_ detail: AssetInspectorDetail) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("信息")
                .font(.headline)
            LabeledContent("文件名", value: detail.fileName ?? "—")
            LabeledContent("来源", value: detail.sourceDisplayName)
            LabeledContent("相对位置", value: detail.relativePath ?? "—")
            LabeledContent("格式", value: detail.mediaType)
            if let width = detail.width, let height = detail.height {
                LabeledContent("尺寸", value: "\(width) × \(height)")
            }
            if let bytes = detail.fingerprintSizeBytes {
                LabeledContent(
                    "文件大小",
                    value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                )
            }
            LabeledContent("状态", value: availabilityText(detail.availability))
        }
        .font(.caption)
    }

    private var filterMenu: some View {
        Menu {
            Button {
                Task { await model.setTagPresence(.any) }
            } label: {
                Label("全部照片", systemImage: model.tagPresence == .any ? "checkmark" : "circle")
            }
            Button {
                Task { await model.setTagPresence(.untagged) }
            } label: {
                Label("无标签", systemImage: model.tagPresence == .untagged ? "checkmark" : "circle")
            }

            if !model.tags.isEmpty {
                Divider()
                ForEach(model.tags, id: \.id) { tag in
                    Menu(tag.displayName) {
                        tagFilterButton(tag: tag, decision: .accepted, title: "已确认")
                        tagFilterButton(tag: tag, decision: .rejected, title: "已拒绝")
                        Button("不筛选此标签") {
                            Task { await model.setTagDecisionFilter(tagID: tag.id, decision: nil) }
                        }
                    }
                }
            }

            if model.selectedTagFilterIDs.count > 1 {
                Divider()
                Button {
                    Task { await model.setTagMatchMode(.all) }
                } label: {
                    Label("全部标签（ALL）", systemImage: model.tagMatchMode == .all ? "checkmark" : "circle")
                }
                Button {
                    Task { await model.setTagMatchMode(.any) }
                } label: {
                    Label("任一标签（ANY）", systemImage: model.tagMatchMode == .any ? "checkmark" : "circle")
                }
            }

            Divider()
            Menu("可用状态") {
                Button {
                    Task { await model.clearAvailabilityFilters() }
                } label: {
                    Label(
                        "全部状态",
                        systemImage: model.selectedAvailabilities.isEmpty ? "checkmark" : "circle"
                    )
                }
                Divider()
                availabilityFilterButton(.available, title: "可用")
                availabilityFilterButton(.missing, title: "文件缺失")
                availabilityFilterButton(.unreadable, title: "不可读取")
                availabilityFilterButton(.unsupported, title: "格式不支持")
            }
            Menu("文件格式") {
                Button {
                    Task { await model.clearMediaTypeFilters() }
                } label: {
                    Label(
                        "全部格式",
                        systemImage: model.selectedMediaTypes.isEmpty ? "checkmark" : "circle"
                    )
                }
                Divider()
                ForEach(Self.mediaFormatFilterOptions, id: \.title) { option in
                    Button {
                        Task { await model.toggleMediaTypeFilterGroup(option.mediaTypes) }
                    } label: {
                        Label(
                            option.title,
                            systemImage: model.isMediaTypeFilterGroupSelected(option.mediaTypes)
                                ? "checkmark"
                                : "circle"
                        )
                    }
                }
            }
        } label: {
            Label(
                activeFilterCount == 0 ? "筛选" : "筛选 \(activeFilterCount)",
                systemImage: activeFilterCount == 0 ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
            )
        }
    }

    private var sortMenu: some View {
        Menu {
            sortButton(.newest, title: "最新优先")
            sortButton(.oldest, title: "最早优先")
            sortButton(.fileNameAscending, title: "文件名升序")
        } label: {
            Label(sortTitle(model.sort), systemImage: "arrow.up.arrow.down")
        }
        .help("更改照片排序")
    }

    private func sortButton(_ sort: AssetPageSort, title: String) -> some View {
        Button {
            Task { await model.setSort(sort) }
        } label: {
            Label(title, systemImage: model.sort == sort ? "checkmark" : "circle")
        }
    }

    private func sortTitle(_ sort: AssetPageSort) -> String {
        switch sort {
        case .newest: "最新优先"
        case .oldest: "最早优先"
        case .fileNameAscending: "文件名升序"
        }
    }

    private func catalogProgressTitle(_ progress: CatalogReconcileProgress?) -> String {
        guard let progress else { return "正在准备扫描" }
        let source = progress.sourceDisplayName
            ?? (progress.sourceKind == .photos ? "Apple Photos" : "文件夹")
        if let total = progress.total, total > 0 {
            return "\(source) \(progress.completed.formatted()) / \(total.formatted())"
        }
        if progress.completed > 0 {
            return "\(source) 已检查 \(progress.completed.formatted()) 张"
        }
        return "正在扫描 \(source)"
    }

    private func availabilityFilterButton(
        _ availability: AssetAvailability,
        title: String
    ) -> some View {
        Button {
            Task { await model.toggleAvailabilityFilter(availability) }
        } label: {
            Label(
                title,
                systemImage: model.selectedAvailabilities.contains(availability) ? "checkmark" : "circle"
            )
        }
    }

    private func tagFilterButton(
        tag: TagListItem,
        decision: PersistableTagDecision,
        title: String
    ) -> some View {
        Button {
            Task { await model.setTagDecisionFilter(tagID: tag.id, decision: decision) }
        } label: {
            Label(
                title,
                systemImage: model.tagFilterDecision(for: tag.id) == decision ? "checkmark" : "circle"
            )
        }
    }

    private var activeFilterCount: Int {
        model.selectedTagFilterIDs.count +
        (model.tagPresence == .any ? 0 : 1) +
        model.selectedAvailabilities.count +
        Self.mediaFormatFilterOptions.filter {
            model.isMediaTypeFilterGroupSelected($0.mediaTypes)
        }.count
    }

    private func createTag() {
        let candidate = newTagName
        guard !TagNameNormalizer.trimUnicodeWhiteSpace(candidate).isEmpty else { return }
        Task {
            await model.requestCreateAndAcceptTag(named: candidate)
            if model.notice == nil {
                newTagName = ""
            }
        }
    }

    private func noticeBar(_ notice: LibraryWorkspaceNotice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: noticeIcon(notice))
            Text(Self.noticeText(notice))
                .font(.caption)
            Spacer()
            Button("关闭") { model.dismissNotice() }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func noticeIcon(_ notice: LibraryWorkspaceNotice) -> String {
        switch notice {
        case .selectionHiddenByFilter:
            "line.3.horizontal.decrease.circle"
        case .presetTagsInstalled, .presetTagsAlreadyAvailable,
             .portableExportCompleted, .previewCacheCleared,
             .personalModelRebuildCompleted:
            "checkmark.circle"
        default:
            "exclamationmark.triangle"
        }
    }

    static func noticeText(_ notice: LibraryWorkspaceNotice) -> String {
        switch notice {
        case .selectionHiddenByFilter: "当前选择已被筛选条件隐藏，因此已清除。"
        case let .presetTagsInstalled(createdCount): "已添加 " + String(createdCount) + " 个常用标签；未给照片应用标签。"
        case .presetTagsAlreadyAvailable: "常用标签已经齐全；未修改照片或人工标签。"
        case .invalidTagName: "标签名称无效。"
        case .duplicateTag: "已有同名标签。"
        case .tagMutationFailed: "标签操作未保存，请重试。"
        case .sourceActionFailed: "来源操作未完成。原照片没有被修改，请重试。"
        case .backgroundScanFailed: "后台扫描未完成，已索引的照片仍可继续浏览。"
        case .photosAuthorizationRequired: "ImageAll 当前没有照片访问权限。授权后请重新检查并同步。"
        case .reviewActionFailed: "建议任务操作未完成，请重试。"
        case .reviewJobConflict: "该标签已有进行中的建议任务。"
        case let .insufficientSuggestionSamples(positive, negative):
            "还需确认 \(positive) 张、标记不属于 \(negative) 张。"
        case let .reviewMutationApplied(count, tagName):
            "已处理 \(count) 条“\(tagName)”建议"
        case let .portableExportCompleted(bundleName, recordCount):
            "已导出 \(recordCount) 条记录到“\(bundleName)”。"
        case .portableExportDestinationOverlapsSource:
            "导出位置不能与已添加的文件夹来源重叠，请选择其他文件夹。"
        case .portableExportIsolationIndeterminate:
            "无法确认导出位置与来源隔离，尚未开始导出。请重新授权来源或选择其他位置；仍失败时请停止导出。"
        case .portableExportFailed:
            "用户数据导出未完成，现有资料没有被修改。请重试。"
        case let .previewCacheCleared(removedEntries, partialReclaim):
            partialReclaim
                ? "已使 \(removedEntries) 个预览缓存条目失效，部分磁盘空间待后续回收。"
                : "已清理 \(removedEntries) 个预览缓存条目。"
        case .previewCacheActionFailed:
            "预览缓存操作未完成。原照片、人工标签和个性化数据没有被修改。"
        case .jobActivityActionFailed:
            "任务操作未完成，已重新读取当前状态。请重试。"
        case let .personalModelRebuildCompleted(tagCount, sampleCount):
            "个人模型已从 \(tagCount) 个标签的 \(sampleCount) 张人工样本重建并确认生效。"
        case .personalModelRebuildNotReady:
            "尚无可训练标签；每个标签至少需要 2 张确认和 2 张拒绝样本。"
        case .personalModelRebuildPreviewUnavailable:
            "训练样本中有照片尚未在本机可用；未下载云端原图，也未替换现有个人模型。"
        case .personalModelRebuildServiceUnavailable:
            "个人模型服务当前不可用；现有模型和标准建议不受影响。"
        case .personalModelRebuildFailed:
            "个人模型重建未完成；现有模型保持不变，请核对样本后重试。"
        }
    }

    private func reviewInspectorActions(tagID: UUID, displayName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI 建议")
                .font(.headline)
            Text("当前标签：\(displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("确认属于 (P)") {
                    Task { await model.applyReviewDecision(action: .accept) }
                }
                Button("不属于 (X)") {
                    Task { await model.applyReviewDecision(action: .reject) }
                }
                Button("稍后 (U)") {
                    Task { await model.deferReviewSelection() }
                }
            }
            .disabled(model.selectedAssetIDs.isEmpty)
        }
    }

    private func availabilityText(_ availability: AssetAvailability) -> String {
        switch availability {
        case .available: "可用"
        case .missing: "文件缺失"
        case .unreadable: "不可读取"
        case .unsupported: "格式不支持"
        }
    }

    private func sourceIcon(_ state: SourceState) -> String {
        switch state {
        case .active: return "folder"
        case .unavailable: return "externaldrive.badge.exclamationmark"
        case .authorizationRequired: return "lock.trianglebadge.exclamationmark"
        case .disabled: return "pause.circle"
        }
    }

    private func sourceStatusText(_ state: SourceState) -> String? {
        switch state {
        case .active: return nil
        case .unavailable: return "离线"
        case .authorizationRequired: return "需授权"
        case .disabled: return "已停用"
        }
    }

    private func sourceHelpText(_ state: SourceState) -> String {
        switch state {
        case .active: return "来源可用"
        case .unavailable: return "来源当前离线"
        case .authorizationRequired: return "需要重新授权此来源"
        case .disabled: return "来源已停用，已索引照片和人工标签仍保留"
        }
    }

    private func suggestionConfirmationTitle(_ pending: SuggestionEnqueueConfirmation?) -> String {
        guard let pending else { return "确认建议任务" }
        switch pending.mode {
        case .generate: return "生成“\(pending.displayName)”建议"
        case .update: return "更新“\(pending.displayName)”建议"
        }
    }

    private func tagDecisionConfirmationTitle(
        _ pending: LibraryTagDecisionConfirmation?
    ) -> String {
        guard let pending else { return "确认批量标签操作？" }
        return switch pending.action {
        case .accept:
            "为 \(pending.affectedCount) 张照片确认“\(pending.tagDisplayName)”？"
        case .reject:
            "为 \(pending.affectedCount) 张照片拒绝“\(pending.tagDisplayName)”？"
        case .clear:
            "清除 \(pending.affectedCount) 张照片的“\(pending.tagDisplayName)”决定？"
        }
    }

    private func tagDecisionConfirmationActionTitle(_ action: LibraryTagDecisionAction) -> String {
        switch action {
        case .accept: "确认并应用"
        case .reject: "拒绝并应用"
        case .clear: "清除决定"
        }
    }

    private func newTagConfirmationTitle(_ pending: LibraryNewTagConfirmation?) -> String {
        guard let pending else { return "确认批量新建标签？" }
        return "为 \(pending.affectedCount) 张照片新建“\(pending.tagDisplayName)”？"
    }

    private func suggestionConfirmationMessage(_ pending: SuggestionEnqueueConfirmation) -> String {
        switch pending.mode {
        case .generate:
            return "将检查 \(pending.sourceCount) 个 active 来源中已入库的照片，并生成待审核建议。"
        case .update:
            return "将检查 \(pending.sourceCount) 个 active 来源中已入库的照片。未审核建议会在第一批新结果成功后刷新；人工标签不会改变。"
        }
    }

    private func errorTitle(_ error: LibraryWorkspaceSafeError) -> String {
        switch error {
        case .connectionFailed: return "无法连接照片来源"
        case .scanFailed: return "扫描未完成"
        case .catalogFailed: return "无法读取图库"
        }
    }

    private func openPhotosPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct SinglePhotoReviewView: View {
    let item: ReviewQueueItemProjection
    @ObservedObject var model: LibraryWorkspaceModel
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            SinglePhotoNavigationBar(model: model)
            Divider()
            HStack(spacing: 12) {
                Button("属于 (P)", systemImage: "checkmark.circle") {
                    Task { await model.applyReviewDecision(action: .accept) }
                }
                Button("不属于 (X)", systemImage: "xmark.circle") {
                    Task { await model.applyReviewDecision(action: .reject) }
                }
                Button("稍后 (U)", systemImage: "arrow.right.circle") {
                    Task { await model.deferReviewSelection() }
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .disabled(model.selectedAssetIDs.isEmpty)
            .accessibilityIdentifier("singlePhotoReviewActions")
            Divider()
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(24)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("singlePhotoView")
        .accessibilityLabel(item.fileName ?? "照片")
        .task(id: item.assetID) {
            image = nil
            guard item.availability == .available,
                  let data = await model.previewData(assetID: item.assetID)
            else { return }
            image = NSImage(data: data)
        }
    }
}

private struct SinglePhotoView: View {
    let item: AssetGridItemProjection
    @ObservedObject var model: LibraryWorkspaceModel
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            SinglePhotoNavigationBar(model: model)
            Divider()
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(24)
                } else {
                    Image(systemName: model.isPhotosSource(item.sourceID) ? "icloud.and.arrow.down" : placeholderIcon)
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("singlePhotoView")
        .accessibilityLabel(item.fileName ?? "照片")
        .task(id: item.assetID) {
            image = nil
            guard item.availability == .available,
                  let data = await model.previewData(assetID: item.assetID)
            else {
                return
            }
            image = NSImage(data: data)
        }
    }

    private var placeholderIcon: String {
        switch item.availability {
        case .available: return "photo"
        case .missing: return "questionmark.folder"
        case .unreadable: return "exclamationmark.triangle"
        case .unsupported: return "nosign"
        }
    }
}

private struct SinglePhotoNavigationBar: View {
    @ObservedObject var model: LibraryWorkspaceModel

    var body: some View {
        if let navigation = model.singlePhotoNavigation {
            HStack(spacing: 12) {
                Button("返回网格", systemImage: "square.grid.2x2") {
                    model.closeSinglePhotoView()
                }

                Spacer()

                VStack(spacing: 2) {
                    Text(navigation.fileName)
                        .font(.headline)
                        .lineLimit(1)
                        .help(navigation.fileName)
                    Text("\(navigation.position) / \(navigation.loadedCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            "第 \(navigation.position) 张，已载入 \(navigation.loadedCount) 张"
                        )
                }

                Spacer()

                Button("上一张", systemImage: "chevron.left") {
                    Task { await model.moveSinglePhotoSelection(by: -1) }
                }
                .disabled(!navigation.canMovePrevious)

                Button("下一张", systemImage: "chevron.right") {
                    Task { await model.moveSinglePhotoSelection(by: 1) }
                }
                .disabled(!navigation.canMoveNext)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityIdentifier("singlePhotoNavigationBar")
        }
    }
}

private struct AssetThumbnailView: View {
    let item: AssetGridItemProjection
    @ObservedObject var model: LibraryWorkspaceModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    Image(systemName: model.isPhotosSource(item.sourceID) ? "icloud.and.arrow.down" : placeholderIcon)
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            }
            .overlay(alignment: .bottomTrailing) {
                let decisionCount = item.acceptedTagCount + item.rejectedTagCount
                if decisionCount > 0 {
                    Label("\(decisionCount)", systemImage: "tag.fill")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .padding(6)
                }
            }
            .accessibilityLabel(item.fileName ?? "照片")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2)
                .onEnded { onOpen() }
                .exclusively(
                    before: TapGesture().onEnded { onSelect() }
                )
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityHint("选择照片；双击或选择后按空格查看单张照片")
        .accessibilityAction {
            onSelect()
        }
        .accessibilityAction(named: "打开单图预览") {
            onOpen()
        }
        .task(id: thumbnailLoadID) {
            guard item.availability == .available,
                  let data = await model.thumbnailData(assetID: item.assetID)
            else {
                return
            }
            image = NSImage(data: data)
        }
    }

    private var thumbnailLoadID: AssetThumbnailLoadID {
        let usesDownloadedCloudPreview: Bool
        if case let .downloaded(assetID, _) = model.cloudPreviewState {
            usesDownloadedCloudPreview = assetID == item.assetID
        } else {
            usesDownloadedCloudPreview = false
        }
        return AssetThumbnailLoadID(
            assetID: item.assetID,
            usesDownloadedCloudPreview: usesDownloadedCloudPreview
        )
    }

    private var placeholderIcon: String {
        switch item.availability {
        case .available: return "photo"
        case .missing: return "questionmark.folder"
        case .unreadable: return "exclamationmark.triangle"
        case .unsupported: return "nosign"
        }
    }
}

private struct AssetThumbnailLoadID: Hashable {
    let assetID: UUID
    let usesDownloadedCloudPreview: Bool
}

private struct InspectorPreview: View {
    let assetID: UUID
    @ObservedObject var model: LibraryWorkspaceModel
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let displayedImage {
                Image(nsImage: displayedImage)
                    .resizable()
                    .scaledToFit()
            } else {
                cloudPreviewControls
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(4 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .task(id: assetID) {
            image = nil
            guard let data = await model.previewData(assetID: assetID) else { return }
            image = NSImage(data: data)
        }
    }

    private var displayedImage: NSImage? {
        if case let .downloaded(downloadedAssetID, data) = model.cloudPreviewState,
           downloadedAssetID == assetID
        {
            return NSImage(data: data)
        }
        return image
    }

    @ViewBuilder
    private var cloudPreviewControls: some View {
        switch model.cloudPreviewState {
        case let .available(cloudAssetID) where cloudAssetID == assetID:
            VStack(spacing: 10) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("此照片仅存储在 iCloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("从 iCloud 获取预览") {
                    model.downloadCloudPreview(assetID: assetID)
                }
                .buttonStyle(.borderedProminent)
            }
        case let .downloading(cloudAssetID, progress) where cloudAssetID == assetID:
            VStack(spacing: 10) {
                ProgressView(value: progress)
                    .frame(maxWidth: 180)
                Text("正在从 iCloud 获取预览 · \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("取消") {
                    model.cancelCloudPreviewDownload(assetID: assetID)
                }
            }
        case let .failed(cloudAssetID) where cloudAssetID == assetID:
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("无法获取 iCloud 预览")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("重试") {
                    model.retryCloudPreviewDownload(assetID: assetID)
                }
                .buttonStyle(.borderedProminent)
            }
        default:
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }
}
