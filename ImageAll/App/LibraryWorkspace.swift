import AppKit
import Foundation
import SwiftUI

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
    @Published private(set) var inspectorDetail: AssetInspectorDetail?
    @Published private(set) var inspectorTags: [LibraryInspectorTagPresentation] = []
    @Published private(set) var tags: [TagListItem] = []
    @Published private(set) var searchText = ""
    @Published private(set) var selectedTagFilterIDs: Set<UUID> = []
    @Published private(set) var tagMatchMode: TagMatchMode = .all
    @Published private(set) var tagPresence: TagPresenceFilter = .any
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
        do {
            let page = try await Self.offMain {
                try service.fetchAssetPage(filter: filter, cursor: cursor)
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
        await refreshInspector()
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
        do {
            let page = try await Self.offMain {
                try service.fetchAssetPage(filter: filter, cursor: nil)
            }
            items = page.items
            nextCursor = page.nextCursor
            let hadSelection = !selectedAssetIDs.isEmpty
            let visibleIDs = Set(page.items.map(\.assetID))
            selectedAssetIDs.formIntersection(visibleIDs)
            if selectedAssetIDs.isEmpty {
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

struct LibraryWorkspaceView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    @State private var selection: LibrarySidebarSelection? = .all
    @State private var searchText = ""
    @State private var newTagName = ""
    @FocusState private var newTagFieldFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } content: {
            content
                .navigationTitle("全部照片")
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
                .disabled(model.isBusy || model.sources.isEmpty)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let notice = model.notice {
                noticeBar(notice)
            }
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
                    Label(source.displayName, systemImage: sourceIcon(source.state))
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
                    Label(tag.displayName, systemImage: "tag")
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
                ContentUnavailableView {
                    Label("没有支持的照片", systemImage: "photo")
                } description: {
                    Text("支持 JPEG、PNG、HEIC/HEIF、TIFF 和 WebP。")
                } actions: {
                    Button("立即重扫") {
                        Task { await model.rescan() }
                    }
                }
            } else {
                assetGrid
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
        } label: {
            Label(
                activeFilterCount == 0 ? "筛选" : "筛选 \(activeFilterCount)",
                systemImage: activeFilterCount == 0 ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
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
        model.selectedTagFilterIDs.count + (model.tagPresence == .any ? 0 : 1)
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

    private func errorTitle(_ error: LibraryWorkspaceSafeError) -> String {
        switch error {
        case .connectionFailed: return "无法连接文件夹"
        case .scanFailed: return "扫描未完成"
        case .catalogFailed: return "无法读取图库"
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
