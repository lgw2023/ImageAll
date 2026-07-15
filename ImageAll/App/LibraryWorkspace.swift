import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private struct LibraryTagUndoRecord {
    let snapshot: TagMutationPriorStateSnapshot
    let appliedDecision: TagDecisionQueryState
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
    @Published private(set) var notice: LibraryWorkspaceNotice?

    private let service: any LibraryWorkspacePort
    private var lastTagMutation: LibraryTagUndoRecord?
    private var selectionAnchorID: UUID?
    private var selectedTagFilterDecisions: [UUID: PersistableTagDecision] = [:]
    private var selectedSourceID: UUID?
    private var nextCursor: AssetPageCursor?
    private var started = false
    private var isLoadingMore = false

    init(service: any LibraryWorkspacePort) {
        self.service = service
    }

    var isBusy: Bool {
        phase == .loading || phase == .scanning
    }

    var canUndoTagMutation: Bool {
        lastTagMutation != nil
    }

    var primarySelectedAssetID: UUID? {
        guard selectedAssetIDs.count == 1 else { return nil }
        return selectedAssetIDs.first
    }

    var hasAssetPropertyFilters: Bool {
        !selectedAvailabilities.isEmpty || !selectedMediaTypes.isEmpty
    }

    var canRescan: Bool {
        if let selectedSourceID {
            return sources.first(where: { $0.id == selectedSourceID })?.state == .active
        }
        return sources.contains { $0.state == .active }
    }

    func start() async {
        guard !started else { return }
        started = true
        await reload(runPendingJobs: true)
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

    func reauthorizeSource(_ sourceID: UUID) async {
        guard !isBusy else { return }
        let previousPhase = phase
        notice = nil
        do {
            switch try await service.reauthorizeFolder(sourceID: sourceID) {
            case .cancelled:
                return
            case .reauthorized:
                break
            }

            let service = service
            sources = try await Self.offMain { try service.fetchSources() }
            phase = .scanning
            try await Self.offMain { try service.runPendingReconcileJobs() }
            await loadFirstPage()
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
        phase = .scanning
        let service = service
        let sourceIDs = selectedSourceID.map { [$0] } ?? sources.map(\.id)
        do {
            try await Self.offMain {
                try service.enqueueReconcile(sourceIDs: sourceIDs)
                try service.runPendingReconcileJobs()
            }
        } catch {
            phase = .failed(.scanFailed)
            return
        }
        await loadFirstPage()
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
        do {
            let page = try await Self.offMain {
                try service.fetchAssetPage(filter: filter, sort: sort, cursor: cursor)
            }
            items.append(contentsOf: page.items)
            nextCursor = page.nextCursor
        } catch {
            phase = .failed(.catalogFailed)
        }
    }

    func thumbnailData(assetID: UUID) async -> Data? {
        try? await service.loadThumbnail(assetID: assetID)
    }

    func previewData(assetID: UUID) async -> Data? {
        try? await service.loadPreview(assetID: assetID)
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
        await refreshInspector()
    }

    func toggleSinglePhotoView() {
        guard primarySelectedAssetID != nil else { return }
        isSinglePhotoPresented.toggle()
    }

    func closeSinglePhotoView() {
        isSinglePhotoPresented = false
    }

    func movePrimarySelection(by offset: Int) async {
        guard offset != 0, let currentID = primarySelectedAssetID else { return }

        if offset > 0, currentID == items.last?.assetID {
            await loadMoreIfNeeded(currentAssetID: currentID)
        }

        guard let currentIndex = items.firstIndex(where: { $0.assetID == currentID }) else {
            return
        }
        let targetIndex = min(max(currentIndex + offset, 0), items.count - 1)
        guard targetIndex != currentIndex else { return }
        await selectAsset(items[targetIndex].assetID)
    }

    func applyTagDecision(tagID: UUID, action: LibraryTagDecisionAction) async {
        let assetIDs = Array(selectedAssetIDs)
        guard !assetIDs.isEmpty else { return }
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
        } catch {
            notice = tagNotice(for: error)
        }
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

        if runPendingJobs {
            phase = .scanning
            do {
                try await Self.offMain { try service.runPendingReconcileJobs() }
            } catch {
                phase = .failed(.scanFailed)
                return
            }
        }
        await loadFirstPage()
    }

    private func loadFirstPage() async {
        let service = service
        let filter = currentFilter
        let sort = sort
        do {
            let page = try await Self.offMain {
                try service.fetchAssetPage(filter: filter, sort: sort, cursor: nil)
            }
            items = page.items
            nextCursor = page.nextCursor
            let hadSelection = !selectedAssetIDs.isEmpty
            let visibleIDs = Set(page.items.map(\.assetID))
            selectedAssetIDs.formIntersection(visibleIDs)
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
            phase = .failed(.catalogFailed)
        }
    }

    func applySearchText(_ text: String) async {
        searchText = text
        await loadFirstPage()
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
        let assetIDs = Array(selectedAssetIDs)
        guard !assetIDs.isEmpty else {
            inspectorDetail = nil
            inspectorTags = []
            return
        }

        let service = service
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
            } else {
                let aggregates = try await Self.offMain {
                    try service.selectionAggregate(tagIDs: availableTags.map(\.id), assetIDs: assetIDs)
                }
                let aggregateByTagID = Dictionary(uniqueKeysWithValues: aggregates.map { ($0.tagID, $0) })
                inspectorDetail = nil
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
        }
    }

    private static func offMain<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: operation).value
    }
}

private enum LibrarySidebarSelection: Hashable {
    case all
    case untagged
    case source(UUID)
    case tag(UUID)
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
    @State private var tagPendingRename: TagListItem?
    @State private var renamedTagName = ""
    @State private var tagPendingArchive: TagListItem?
    @FocusState private var newTagFieldFocused: Bool
    @FocusState private var contentFocused: Bool

    private var workspaceWithSourceControls: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } content: {
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
                .onKeyPress(keys: [.leftArrow, .rightArrow]) { keyPress in
                    guard model.primarySelectedAssetID != nil else { return .ignored }
                    let offset = keyPress.key == .leftArrow ? -1 : 1
                    Task { await model.movePrimarySelection(by: offset) }
                    return .handled
                }
        } detail: {
            inspector
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
        }
        .frame(minWidth: 900, minHeight: 560)
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: "搜索文件名、路径、标签或来源"
        )
        .onSubmit(of: .search) {
            Task { await model.applySearchText(searchText) }
        }
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty, !model.searchText.isEmpty {
                Task { await model.applySearchText("") }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                filterMenu
                sortMenu

                Button {
                    Task { await model.undoLastTagMutation() }
                } label: {
                    Label("撤销标签操作", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canUndoTagMutation)

                Button {
                    Task { await model.connectFolder() }
                } label: {
                    Label("连接文件夹", systemImage: "folder.badge.plus")
                }
                .disabled(model.isBusy)

                Button {
                    Task { await model.rescan() }
                } label: {
                    Label("立即重扫", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy || !model.canRescan)
            }
        }
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
        .task { await model.start() }
        .onChange(of: selection) { _, newValue in
            Task {
                switch newValue {
                case .all, .none:
                    await model.setTagPresence(.any)
                    await model.selectSource(nil)
                case .untagged:
                    await model.selectSource(nil)
                    await model.setTagPresence(.untagged)
                case let .source(sourceID):
                    await model.setTagPresence(.any)
                    await model.selectSource(sourceID)
                case let .tag(tagID):
                    await model.selectSource(nil)
                    await model.showAcceptedTag(tagID)
                }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("图库") {
                Label("全部照片", systemImage: "photo.on.rectangle.angled")
                    .tag(LibrarySidebarSelection.all)
                Label("无标签", systemImage: "tag.slash")
                    .tag(LibrarySidebarSelection.untagged)
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
            }
            Section("标签") {
                ForEach(model.tags, id: \.id) { tag in
                    tagRow(tag)
                        .tag(LibrarySidebarSelection.tag(tag.id))
                }
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
            Label(source.displayName, systemImage: sourceIcon(source.state))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let status = sourceStatusText(source.state) {
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
            Button("立即重扫") {
                selection = .source(source.id)
                Task {
                    await model.selectSource(source.id)
                    await model.rescan()
                }
            }
            .disabled(model.isBusy || source.state != .active)

            Button("重新授权…") {
                Task { await model.reauthorizeSource(source.id) }
            }
            .disabled(
                model.isBusy ||
                (source.state != .unavailable && source.state != .authorizationRequired)
            )

            Divider()

            Button("停用来源", role: .destructive) {
                sourcePendingDisable = source
            }
            .disabled(model.isBusy || source.state == .disabled)
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
            ContentUnavailableView {
                Label("ImageAll 在原位置读取照片", systemImage: "photo.stack")
            } description: {
                Text("不会导入、移动、重命名或删除原图。索引、标签和缩略图保存在 ImageAll 自己的应用容器中。")
            } actions: {
                Button("连接照片文件夹…") {
                    Task { await model.connectFolder() }
                }
                .buttonStyle(.borderedProminent)
            }
        case .content:
            if model.items.isEmpty {
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
                Text("原照片没有被修改。请检查文件夹是否仍在线并重试。")
            } actions: {
                Button("重试") {
                    Task { await model.rescan() }
                }
                .disabled(model.sources.isEmpty)
            }
        }
    }

    private var assetGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132, maximum: 220), spacing: 8)],
                spacing: 8
            ) {
                ForEach(model.items, id: \.assetID) { item in
                    AssetThumbnailView(
                        item: item,
                        model: model,
                        isSelected: model.selectedAssetIDs.contains(item.assetID)
                    ) {
                        contentFocused = true
                        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        Task {
                            await model.selectAsset(
                                item.assetID,
                                additive: flags.contains(.command),
                                extendRange: flags.contains(.shift)
                            )
                        }
                    }
                        .task {
                            await model.loadMoreIfNeeded(currentAssetID: item.assetID)
                        }
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { contentFocused = true }
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
                            metadata(detail)
                        }

                        Divider()
                        tagEditor
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
                await model.applyTagDecision(tagID: tag.id, action: .accept)
            }
            tagDecisionButton(
                systemImage: "xmark",
                label: "拒绝 \(tag.displayName)",
                isActive: tag.decision == .rejected
            ) {
                await model.applyTagDecision(tagID: tag.id, action: .reject)
            }
            tagDecisionButton(
                systemImage: "minus",
                label: "清除 \(tag.displayName) 的决定",
                isActive: tag.decision == .unknown
            ) {
                await model.applyTagDecision(tagID: tag.id, action: .clear)
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
            await model.createAndAcceptTag(named: candidate)
            if model.notice == nil {
                newTagName = ""
            }
        }
    }

    private func noticeBar(_ notice: LibraryWorkspaceNotice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: notice == .selectionHiddenByFilter ? "line.3.horizontal.decrease.circle" : "exclamationmark.triangle")
            Text(noticeText(notice))
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

    private func noticeText(_ notice: LibraryWorkspaceNotice) -> String {
        switch notice {
        case .selectionHiddenByFilter: "当前选择已被筛选条件隐藏，因此已清除。"
        case .invalidTagName: "标签名称无效。"
        case .duplicateTag: "已有同名标签。"
        case .tagMutationFailed: "标签操作未保存，请重试。"
        case .sourceActionFailed: "来源操作未完成。原照片没有被修改，请重试。"
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

    private func errorTitle(_ error: LibraryWorkspaceSafeError) -> String {
        switch error {
        case .connectionFailed: return "无法连接文件夹"
        case .scanFailed: return "扫描未完成"
        case .catalogFailed: return "无法读取图库"
        }
    }
}

private struct SinglePhotoView: View {
    let item: AssetGridItemProjection
    @ObservedObject var model: LibraryWorkspaceModel
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
            } else {
                Image(systemName: placeholderIcon)
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private struct AssetThumbnailView: View {
    let item: AssetGridItemProjection
    @ObservedObject var model: LibraryWorkspaceModel
    let isSelected: Bool
    let onSelect: () -> Void
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
                    Image(systemName: placeholderIcon)
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
        .onTapGesture(perform: onSelect)
        .task(id: item.assetID) {
            guard item.availability == .available,
                  let data = await model.thumbnailData(assetID: item.assetID)
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

private struct InspectorPreview: View {
    let assetID: UUID
    @ObservedObject var model: LibraryWorkspaceModel
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(4 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .task(id: assetID) {
            guard let data = await model.previewData(assetID: assetID) else { return }
            image = NSImage(data: data)
        }
    }
}
