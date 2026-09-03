import AppKit
import SwiftUI

enum ReviewWorkspaceMode: Equatable {
    case overview
    case tagQueue(tagID: UUID, displayName: String)
}

struct ContextualTagFeedView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let onLater: () -> Void
    let onShowScopeInspector: () -> Void
    @State private var cellFrames = LibraryGridCellFrameStore()
    @State private var isMarqueeSelecting = false

    private var group: ContextualTagFeedGroup? { model.currentContextualTagFeed }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isLoadingContextualTagFeed, group == nil {
                ProgressView("正在根据时间、位置和文件序列整理候选…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let group {
                groupContent(group)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("智能推流")
        .contextualTagFeedKeyboardShortcutHandling(
            isEnabled: group != nil || model.canUndoContextualTagFeedMutation
        ) { action in
            switch action {
            case .selectAll:
                model.selectAllContextualTagFeedCandidates()
            case .clearSelection:
                model.clearContextualTagFeedSelection()
            case .accept:
                Task { await model.resolveCurrentContextualTagFeed(decision: .accepted) }
            case .reject:
                Task { await model.resolveCurrentContextualTagFeed(decision: .rejected) }
            case .ignoreGroup:
                Task { await model.dismissCurrentContextualTagFeed() }
            case .later:
                onLater()
            case .undo:
                Task { await model.undoLastContextualTagFeedMutation() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("智能标签照片推流")
                    .font(.title2.weight(.semibold))
                Text("默认优先推送依赖时间、位置和事件上下文的标签；不会自动写标签。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if model.contextualTagFeedPendingCount > 0 {
                Text("\(model.contextualTagFeedPendingCount) 组待确认")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            Button(action: onShowScopeInspector) {
                Label(
                    model.contextualTagFeedScopeTitle,
                    systemImage: "line.3.horizontal.decrease.circle"
                )
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .persistentHelp("打开右侧检查器，为锚点或候选照片修改标签，并设置推流范围。")
            Button("刷新", systemImage: "arrow.clockwise") {
                Task { await model.refreshContextualTagFeed(generateRecentAnchors: true) }
            }
            .disabled(model.isLoadingContextualTagFeed)
        }
        .padding(16)
    }

    private func groupContent(_ group: ContextualTagFeedGroup) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("这些照片也属于“\(group.tagDisplayName)”吗？")
                        .font(.headline)
                    Text(groupEvidenceSummary(group))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("锚点与候选都可在右侧修改标签；P/X 会给未选候选写入与选中候选相反的决定，一次完成整组。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !model.isCurrentContextualTagFeedAnchorValid {
                        Label(
                            "锚点已不再属于“\(group.tagDisplayName)”；请在右侧补充正确标签后舍弃这组。",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(
                        "\(group.members.count) 张 · 已选 \(model.selectedContextualTagFeedAssetIDs.count)"
                            + " · 可确认 \(model.selectedContextualTagFeedCandidateAssetIDs.count)"
                    )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("全选") {
                            model.selectAllContextualTagFeedCandidates()
                        }
                        .disabled(model.areAllContextualTagFeedCandidatesSelected)
                        .persistentHelp("选择当前组的全部候选照片（⌘A）。")
                        Button("清除选择") {
                            model.clearContextualTagFeedSelection()
                        }
                        .disabled(model.selectedContextualTagFeedAssetIDs.isEmpty)
                        .persistentHelp("取消当前组的全部候选选择（⇧⌘A）。")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            GeometryReader { proxy in
                let layoutWidth = LibraryGridLayout.layoutWidth(
                    containerWidth: proxy.size.width
                )
                ScrollView {
                    LibraryGridMarqueeContainer(
                        cellFrames: cellFrames,
                        isMarqueeSelecting: $isMarqueeSelecting,
                        viewportHeight: proxy.size.height,
                        contentWidth: layoutWidth,
                        currentSelection: model.selectedContextualTagFeedAssetIDs,
                        onSelectionChange: { assetIDs, _ in
                            model.selectContextualTagFeedCandidates(assetIDs)
                        }
                    ) {
                        LazyVGrid(
                            columns: LibraryGridLayout.gridItems(
                                containerWidth: proxy.size.width,
                                density: model.gridDensity
                            ),
                            spacing: LibraryGridLayout.spacing
                        ) {
                            ForEach(group.members) { member in
                                ContextualTagFeedThumbnail(
                                    member: member,
                                    model: model,
                                    isSelected: model.selectedContextualTagFeedAssetIDs.contains(
                                        member.assetID
                                    ),
                                    onSelect: { additive, extendRange in
                                        guard !isMarqueeSelecting else { return }
                                        model.selectContextualTagFeedCandidate(
                                            member.assetID,
                                            additive: additive,
                                            extendRange: extendRange
                                        )
                                    }
                                )
                                .libraryGridCellFrameReporter(assetID: member.assetID)
                            }
                        }
                        .padding(.horizontal, LibraryGridLayout.horizontalPadding)
                        .padding(.vertical, 12)
                    }
                }
                .scrollDisabled(isMarqueeSelecting)
            }

            Divider()
            HStack(spacing: 10) {
                if let message = model.contextualTagFeedStatusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if model.canUndoContextualTagFeedMutation {
                    Button("撤销上一步 (⌘Z)") {
                        Task { await model.undoLastContextualTagFeedMutation() }
                    }
                    .buttonStyle(.bordered)
                    .persistentHelp("撤销最近一次智能推流确认或拒绝，恢复照片原标签状态并重新打开该候选组。")
                }
                Button("稍后处理 (U)", action: onLater)
                    .buttonStyle(.bordered)
                    .persistentHelp("保留当前组为待确认并返回图库；快捷键 U。")
                Button("忽略该组 (I)") {
                    Task { await model.dismissCurrentContextualTagFeed() }
                }
                .buttonStyle(.bordered)
                .persistentHelp("只忽略当前候选组，不会把照片写成“不属于”或训练负样本；快捷键 I。")
                Button(rejectButtonTitle(group), role: .destructive) {
                    Task { await model.resolveCurrentContextualTagFeed(decision: .rejected) }
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(
                    model.selectedContextualTagFeedCandidateAssetIDs.isEmpty ||
                        !model.isCurrentContextualTagFeedAnchorValid
                )
                .persistentHelp(
                    "把选中候选标为不属于当前标签，并把其余候选标为属于；一次完成整组。快捷键 X。"
                )
                Button(confirmButtonTitle(group)) {
                    Task { await model.resolveCurrentContextualTagFeed(decision: .accepted) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.selectedContextualTagFeedCandidateAssetIDs.isEmpty ||
                        !model.isCurrentContextualTagFeedAnchorValid
                )
                .persistentHelp(
                    "把选中候选标为属于当前标签，并把其余候选标为不属于；一次完成整组。快捷键 P。"
                )
            }
            .padding(12)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("暂无智能推流", systemImage: "sparkles.rectangle.stack")
        } description: {
            Text("确认照片标签后，ImageAll 会从近期已确认记录中寻找时间、位置或文件序列共同支持的候选组。")
        } actions: {
            Button("检查近期标签") {
                Task { await model.refreshContextualTagFeed(generateRecentAnchors: true) }
            }
            .buttonStyle(.borderedProminent)
            Button("返回图库", action: onLater)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func confirmButtonTitle(_ group: ContextualTagFeedGroup) -> String {
        let selectedCount = model.selectedContextualTagFeedCandidateAssetIDs.count
        let remainingCount = max(0, model.contextualTagFeedCandidateAssetIDs.count - selectedCount)
        return "选中 \(selectedCount) 张属于“\(group.tagDisplayName)”，其余 \(remainingCount) 张不属于 (P)"
    }

    private func rejectButtonTitle(_ group: ContextualTagFeedGroup) -> String {
        let selectedCount = model.selectedContextualTagFeedCandidateAssetIDs.count
        let remainingCount = max(0, model.contextualTagFeedCandidateAssetIDs.count - selectedCount)
        return "选中 \(selectedCount) 张不属于“\(group.tagDisplayName)”，其余 \(remainingCount) 张属于 (X)"
    }

    private func groupEvidenceSummary(_ group: ContextualTagFeedGroup) -> String {
        let evidenceKinds = Set(group.members.flatMap { $0.evidence.map(\.kind) })
        let labels = [
            evidenceKinds.contains(.captureTime) ? "拍摄时间相近" : nil,
            evidenceKinds.contains(.spatialProximity) ? "拍摄位置相近" : nil,
            evidenceKinds.contains(.filenameSequence) ? "文件名连续" : nil,
            evidenceKinds.contains(.sourceContext) ? "来源上下文一致" : nil,
        ].compactMap { $0 }
        return labels.isEmpty ? "当前组缺少可显示的上下文证据" : labels.joined(separator: " · ")
    }
}

struct ContextualTagFeedInspectorView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    @State private var newTagName = ""
    @State private var isScopeExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                photoTagEditor

                Divider()

                DisclosureGroup(isExpanded: $isScopeExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("直接点击标签加入或移出范围；选中一个或多个标签后，只生成、统计并显示这些标签的推流。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        recommendedScopeButton

                        if model.tags.isEmpty {
                            Text("尚无可用于智能推流的标签。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.tagGroupSections) { section in
                                tagGroupSection(section)
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("推流标签范围")
                            .font(.headline)
                        Text(model.contextualTagFeedScopeTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if model.isLoadingContextualTagFeed {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在刷新推流范围…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
        .scrollIndicators(.visible, axes: .vertical)
        .navigationTitle("照片标签与推流范围")
        .accessibilityIdentifier("contextualTagFeedScopeInspector")
    }

    private var photoTagEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("所选照片标签")
                    .font(.headline)
                Text(selectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("与图库一致：左键打上标签，右键取消。锚点和候选照片都可以选择。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let group = model.currentContextualTagFeed,
               !model.isCurrentContextualTagFeedAnchorValid
            {
                VStack(alignment: .leading, spacing: 7) {
                    Label(
                        "锚点已不再属于“\(group.tagDisplayName)”，当前推流依据已经失效。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    Text("可继续为锚点补充正确标签；完成后舍弃这组，不会产生负样本。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("舍弃错误锚点组") {
                        Task { await model.dismissCurrentContextualTagFeed() }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 6) {
                TextField("新标签名称", text: $newTagName)
                    .onSubmit { createTag() }
                Button {
                    createTag()
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(
                    model.selectedContextualTagFeedAssetIDs.isEmpty ||
                        TagNameNormalizer.trimUnicodeWhiteSpace(newTagName).isEmpty
                )
                .persistentHelp("创建新标签，并应用到当前选中的锚点或候选照片。")
            }

            if model.canUndoTagMutation {
                Button("撤销最近标签修改", systemImage: "arrow.uturn.backward") {
                    Task { await model.undoLastTagMutation() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if model.tags.isEmpty {
                Text("尚无标签。可在上方创建并应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.tagGroupSections) { section in
                    photoTagGroupSection(section)
                }
            }
        }
    }

    private var selectionSummary: String {
        let count = model.selectedContextualTagFeedAssetIDs.count
        guard count > 0 else { return "未选择照片；请先在左侧点选锚点或候选照片。" }
        if model.isContextualTagFeedAnchorSelected {
            return "已选择 \(count) 张，其中包含锚点照片。"
        }
        return "已选择 \(count) 张候选照片。"
    }

    private func photoTagGroupSection(_ section: LibraryTagGroupSection) -> some View {
        let isCollapsed = model.isTagGroupCollapsed(section.group.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                model.toggleTagGroupCollapsed(section.group.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(section.group.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(section.tags.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                LibraryTagFlowLayout {
                    ForEach(section.tags, id: \.id) { tag in
                        photoTagChip(tag)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .padding(4)
    }

    private func photoTagChip(_ tag: TagListItem) -> some View {
        let decision = model.contextualTagFeedInspectorTags
            .first(where: { $0.id == tag.id })?.decision ?? .unknown
        return LibraryInspectorTagDecisionChip(
            tag: tag,
            decision: decision,
            isEnabled: !model.selectedContextualTagFeedAssetIDs.isEmpty,
            onAccept: {
                Task {
                    await model.requestContextualTagFeedTagDecision(
                        tagID: tag.id,
                        action: .accept
                    )
                }
            },
            onClear: {
                Task {
                    await model.requestContextualTagFeedTagDecision(
                        tagID: tag.id,
                        action: .clear
                    )
                }
            }
        )
    }

    private func createTag() {
        let candidate = TagNameNormalizer.trimUnicodeWhiteSpace(newTagName)
        guard !candidate.isEmpty, !model.selectedContextualTagFeedAssetIDs.isEmpty else { return }
        newTagName = ""
        Task { await model.createAndAcceptContextualTagFeedTag(named: candidate) }
    }

    private var recommendedScopeButton: some View {
        let isSelected = model.contextualTagFeedTagScope == .recommended
        return Button {
            Task { await model.useRecommendedContextualTagFeedScope() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("智能推荐")
                        .font(.callout.weight(.medium))
                    Text("全部标签参与，上下文标签优先")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.16)
                            : Color(nsColor: .controlBackgroundColor).opacity(0.75)
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isLoadingContextualTagFeed || isSelected)
        .accessibilityIdentifier("contextualTagFeedRecommendedScopeButton")
        .persistentHelp("恢复智能推荐，让全部标签参与并优先显示依赖时间、位置和事件上下文的标签。")
    }

    private func tagGroupSection(_ section: LibraryTagGroupSection) -> some View {
        let isCollapsed = model.isTagGroupCollapsed(section.group.id)
        let selectedCount = section.tags.count { model.isInContextualTagFeedScope($0.id) }
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                model.toggleTagGroupCollapsed(section.group.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(section.group.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(
                        selectedCount > 0
                            ? "\(selectedCount)/\(section.tags.count)"
                            : "\(section.tags.count)"
                    )
                    .font(.caption2)
                    .foregroundStyle(selectedCount > 0 ? Color.accentColor : Color.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .persistentHelp(
                isCollapsed
                    ? "展开“\(section.group.displayName)”分组，显示其中标签。"
                    : "折叠“\(section.group.displayName)”分组，暂时隐藏其中标签。"
            )

            if !isCollapsed {
                LibraryTagFlowLayout {
                    ForEach(section.tags, id: \.id) { tag in
                        scopeTagChip(tag)
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .padding(4)
    }

    private func scopeTagChip(_ tag: TagListItem) -> some View {
        let isSelected = model.isInContextualTagFeedScope(tag.id)
        return Button {
            Task { await model.toggleContextualTagFeedScopeTag(tag.id) }
        } label: {
            HStack(spacing: 5) {
                Label {
                    Text(tag.displayName)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "tag")
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: 180, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.18)
                            : Color(nsColor: .controlBackgroundColor).opacity(0.75)
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isLoadingContextualTagFeed)
        .accessibilityLabel(tag.displayName)
        .accessibilityValue(isSelected ? "已加入推流范围" : "未加入推流范围")
        .accessibilityIdentifier("contextualTagFeedScopeTag-\(tag.id.uuidString)")
        .persistentHelp(isSelected ? "点击移出智能推流范围。" : "点击加入智能推流范围。")
    }
}

private struct ContextualTagFeedThumbnail: View {
    let member: ContextualTagFeedMember
    @ObservedObject var model: LibraryWorkspaceModel
    let isSelected: Bool
    let onSelect: (_ additive: Bool, _ extendRange: Bool) -> Void
    @State private var image: NSImage?
    @State private var loadState: ContextualTagFeedThumbnailLoadState = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { proxy in
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: model.thumbnailAspectMode.imageContentMode)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    } else {
                        switch loadState {
                        case .loading:
                            ProgressView()
                                .controlSize(.small)
                        case let .placeholder(systemImage):
                            Image(systemName: systemImage)
                                .font(.title)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                }
                .overlay(alignment: .topLeading) {
                    if member.role == .anchor {
                        Text("已确认锚点")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.68), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(7)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .padding(7)
                }
            }
            .aspectRatio(thumbnailFrameAspectRatio, contentMode: .fit)

            Text(member.fileName ?? (member.mediaKind == .video ? "视频" : "照片"))
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(evidenceText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(8)
        .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            onSelect(flags.contains(.command), flags.contains(.shift))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(member.fileName ?? "候选媒体")
        .accessibilityValue(
            member.role == .anchor
                ? "已确认锚点，\(isSelected ? "已选择" : "未选择")"
                : (isSelected ? "已选择" : "未选择")
        )
        .task(id: thumbnailLoadID) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        image = nil
        loadState = .loading
        switch await model.loadThumbnailResultWithRetry(
            assetID: member.assetID,
            aspectMode: model.thumbnailAspectMode
        ) {
        case let .loaded(data):
            guard !Task.isCancelled else { return }
            if let decoded = LibraryGridThumbnailImageFactory.image(from: data) {
                image = decoded
            } else {
                loadState = .placeholder(systemImage: "exclamationmark.triangle")
            }
        case .cloudOnly:
            guard !Task.isCancelled else { return }
            loadState = .placeholder(systemImage: "icloud.and.arrow.down")
        case .unavailable:
            loadState = .placeholder(systemImage: mediaPlaceholderSystemImage)
        case .failed:
            loadState = .placeholder(systemImage: "exclamationmark.triangle")
        case .cancelled:
            guard !Task.isCancelled else { return }
            loadState = .placeholder(systemImage: mediaPlaceholderSystemImage)
        }
    }

    private var thumbnailLoadID: ContextualTagFeedThumbnailLoadID {
        ContextualTagFeedThumbnailLoadID(
            assetID: member.assetID,
            aspectMode: model.thumbnailAspectMode,
            cacheVersion: model.thumbnailCacheVersion(for: member.assetID),
            originalAspectCacheGeneration: model.thumbnailAspectMode == .original
                ? model.originalAspectThumbnailCacheGeneration
                : 0,
            recoveryGeneration: model.thumbnailRecoveryGeneration
        )
    }

    private var thumbnailFrameAspectRatio: CGFloat {
        model.thumbnailAspectMode.frameAspectRatio(imageSize: image?.size)
    }

    private var mediaPlaceholderSystemImage: String {
        member.mediaKind == .video ? "video" : "photo"
    }

    private var evidenceText: String {
        let parts = member.evidence.compactMap { evidence -> String? in
            switch evidence.kind {
            case .filenameSequence:
                guard let offset = evidence.sequenceOffset else { return "文件名连续" }
                return offset == 0 ? "文件名连续" : "序号相差 \(abs(offset))"
            case .captureTime:
                guard let delta = evidence.deltaMs else { return "时间相近" }
                return "相隔 \(max(1, delta / 60_000)) 分钟"
            case .spatialProximity:
                guard let distance = evidence.distanceM else { return "位置相近" }
                return distance < 1_000
                    ? "约 \(Int(distance.rounded())) 米"
                    : String(format: "约 %.1f 公里", distance / 1_000)
            case .sourceContext:
                return "同一来源"
            case .captureDevice:
                return "同一设备"
            }
        }
        return parts.isEmpty ? "锚点照片" : parts.joined(separator: " · ")
    }
}

private enum ContextualTagFeedThumbnailLoadState: Equatable {
    case loading
    case placeholder(systemImage: String)
}

private struct ContextualTagFeedThumbnailLoadID: Hashable {
    let assetID: UUID
    let aspectMode: LibraryThumbnailAspectMode
    let cacheVersion: Int
    let originalAspectCacheGeneration: Int
    let recoveryGeneration: Int
}

enum ReviewOverviewLayout {
    static let localModelPanelMinimumWidth: CGFloat = 248
    static let localModelPanelIdealWidth: CGFloat = 288
    static let localModelPanelMaximumWidth: CGFloat = 320
    static let sectionSpacing: CGFloat = 22
    static let cardSpacing: CGFloat = 12
    static let cardMinimumWidth: CGFloat = 310
    static let cardMaximumWidth: CGFloat = 440
}

private enum ReviewWorkspacePalette {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
}

struct ReviewSuggestionGroupSection: Identifiable, Equatable, Sendable {
    let group: TagGroupListItem
    let overviews: [SuggestionTagOverview]

    var id: UUID { group.id }

    static func build(
        tagSections: [LibraryTagGroupSection],
        overviews: [SuggestionTagOverview]
    ) -> [ReviewSuggestionGroupSection] {
        var remaining: [UUID: SuggestionTagOverview] = [:]
        for overview in overviews {
            remaining[overview.id] = overview
        }

        var result = tagSections.compactMap { section -> ReviewSuggestionGroupSection? in
            let ordered = section.tags.compactMap { remaining.removeValue(forKey: $0.id) }
            guard !ordered.isEmpty else { return nil }
            return ReviewSuggestionGroupSection(group: section.group, overviews: ordered)
        }

        let unmatched = remaining.values.sorted(by: alphabetical)
        guard !unmatched.isEmpty else { return result }

        if let otherIndex = result.firstIndex(where: { $0.group.id == TagGroupSeed.other.id }) {
            let current = result[otherIndex]
            result[otherIndex] = ReviewSuggestionGroupSection(
                group: current.group,
                overviews: current.overviews + unmatched
            )
        } else {
            let fallback = tagSections.first(where: { $0.group.id == TagGroupSeed.other.id })?.group
                ?? TagGroupListItem(
                    id: TagGroupSeed.other.id,
                    displayName: TagGroupSeed.other.displayName,
                    sortOrder: TagGroupSeed.other.sortOrder,
                    isSystem: true
                )
            result.append(ReviewSuggestionGroupSection(group: fallback, overviews: unmatched))
        }
        return result
    }

    private static func alphabetical(
        _ lhs: SuggestionTagOverview,
        _ rhs: SuggestionTagOverview
    ) -> Bool {
        let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if comparison == .orderedSame {
            return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
        return comparison == .orderedAscending
    }
}

struct ReviewOverviewView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let onOpenQueue: (UUID, String) -> Void
    let onBack: () -> Void

    private var showsLocalModelPanel: Bool {
        model.supportsPersonalLibrarySuggestions || model.supportsStandardLibrarySuggestions
    }

    private var groupedOverviews: [ReviewSuggestionGroupSection] {
        ReviewSuggestionGroupSection.build(
            tagSections: model.tagGroupSections,
            overviews: model.suggestionOverviews
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ReviewOverviewHeader(model: model, onBack: onBack)
            Divider()
            if model.suggestionOverviews.isEmpty, !showsLocalModelPanel {
                ContentUnavailableView {
                    Label("暂无待审核标签", systemImage: "sparkles")
                } description: {
                    Text("先在图库中为\(model.selectedMediaKind.displayName)打标签并积累确认/拒绝样本，再回来生成建议。")
                } actions: {
                    Button("返回图库", action: onBack)
                        .buttonStyle(.borderedProminent)
                        .persistentHelp(
                            "返回\(model.selectedMediaKind.displayName)图库，为\(model.selectedMediaKind.displayName)添加标签或积累更多确认和拒绝样本。"
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    if showsLocalModelPanel {
                        ReviewLocalModelPanel(model: model)
                            .frame(
                                minWidth: ReviewOverviewLayout.localModelPanelMinimumWidth,
                                idealWidth: ReviewOverviewLayout.localModelPanelIdealWidth,
                                maxWidth: ReviewOverviewLayout.localModelPanelMaximumWidth
                            )
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: ReviewOverviewLayout.sectionSpacing) {
                            ForEach(groupedOverviews) { section in
                                ReviewSuggestionGroupView(
                                    model: model,
                                    section: section,
                                    onOpenQueue: onOpenQueue
                                )
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(ReviewWorkspacePalette.canvas)
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("待审核建议")
        .sheet(
            item: Binding(
                get: { model.pendingSuggestionConfirmation },
                set: { model.pendingSuggestionConfirmation = $0 }
            )
        ) { pending in
            SuggestionEnqueueConfirmationSheet(model: model, pending: pending)
        }
    }
}

private struct ReviewSuggestionGroupView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let section: ReviewSuggestionGroupSection
    let onOpenQueue: (UUID, String) -> Void

    private var isCollapsed: Bool {
        model.isTagGroupCollapsed(section.id)
    }

    private var pendingCount: Int {
        section.overviews.reduce(0) { $0 + $1.pendingSuggestionCount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                model.toggleTagGroupCollapsed(section.id)
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                        Image(systemName: "square.grid.2x2")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(section.group.displayName)
                            .font(.headline)
                        Text("\(section.overviews.count) 个标签")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if pendingCount > 0 {
                        Text("\(pendingCount) 条待审")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .persistentHelp(
                isCollapsed
                    ? "展开“\(section.group.displayName)”分组。"
                    : "折叠“\(section.group.displayName)”分组。"
            )

            if !isCollapsed {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(
                                minimum: ReviewOverviewLayout.cardMinimumWidth,
                                maximum: ReviewOverviewLayout.cardMaximumWidth
                            ),
                            spacing: ReviewOverviewLayout.cardSpacing,
                            alignment: .top
                        ),
                    ],
                    alignment: .leading,
                    spacing: ReviewOverviewLayout.cardSpacing
                ) {
                    ForEach(section.overviews) { overview in
                        ReviewTagOverviewCard(
                            model: model,
                            overview: overview,
                            onOpenQueue: onOpenQueue
                        )
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }
}

private struct ReviewOverviewHeader: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button("返回图库", systemImage: "chevron.left", action: onBack)
                    .buttonStyle(.bordered)
                    .persistentHelp(
                        "退出待审核建议工作区并返回\(model.selectedMediaKind.displayName)图库。"
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("建议工作台")
                        .font(.title2.weight(.semibold))
                    Text("按标签生成、校准并审核模型建议")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Label("门槛以上全部保留", systemImage: "infinity")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.secondary.opacity(0.1), in: Capsule())
                if model.pendingSuggestionTotal > 0 {
                    Label("\(model.pendingSuggestionTotal) 条待审", systemImage: "checklist")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            }
            ReviewSourceFilterMenu(model: model)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

private struct ReviewSourceFilterMenu: View {
    @ObservedObject var model: LibraryWorkspaceModel

    var body: some View {
        Menu {
            Button("全选来源") {
                Task { await model.selectAllReviewSources() }
            }
            .disabled(model.reviewFilterSourceIDs == nil)
            .persistentHelp(
                "恢复使用所有已启用来源生成建议并显示待审\(model.selectedMediaKind.displayName)。"
            )
            Divider()
            ForEach(model.activeReviewSources) { source in
                Toggle(
                    source.displayName,
                    isOn: Binding(
                        get: { model.isReviewSourceIncluded(source.id) },
                        set: { included in
                            Task { await model.setReviewSourceIncluded(source.id, included) }
                        }
                    )
                )
            }
        } label: {
            Label {
                Text(model.reviewSourceFilterSummaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: "folder.badge.gearshape")
            }
            .font(.subheadline)
            .frame(maxWidth: 360, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .persistentHelp(
            "选择建议生成和待审列表要覆盖的\(model.selectedMediaKind.displayName)来源；不会改变图库侧栏当前浏览位置。"
        )
    }
}

private struct ReviewLocalModelPanel: View {
    @ObservedObject var model: LibraryWorkspaceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("生成中心", systemImage: "sparkles.rectangle.stack")
                        .font(.title3.weight(.semibold))
                    Text("模型任务在后台运行，审核列表保持可操作。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(localModelServiceStatusText)
                        .font(.caption)
                        .foregroundStyle(localModelServiceStatusColor)
                    Button {
                        Task { await model.refreshLocalModelServiceHealth() }
                    } label: {
                        if model.localModelServiceHealthState == .checking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在检查")
                            }
                        } else {
                            Label("刷新服务状态", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(model.localModelServiceHealthState == .checking)
                    .persistentHelp(
                        "重新检查本机模型服务是否可用；不会启动服务、下载模型或读取\(model.selectedMediaKind.displayName)。"
                    )
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    ReviewWorkspacePalette.card,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(ReviewWorkspacePalette.separator.opacity(0.55))
                }

                if model.supportsStandardLibrarySuggestions {
                    localModelActionCard(
                        title: "标准模型",
                        statusText: standardLibraryStatusText,
                        statusColor: standardLibraryStatusColor,
                        actionTitle: model.isGeneratingStandardLibrarySuggestions
                            ? "正在扫描全库"
                            : "扫描全库",
                        actionIcon: "sparkles.rectangle.stack",
                        isRunning: model.isGeneratingStandardLibrarySuggestions,
                        isDisabled:
                            model.isGeneratingStandardLibrarySuggestions
                            || model.isGeneratingPersonalLibrarySuggestions
                            || model.isRebuildingPersonalModel,
                        help: "按顶部来源筛选扫描；仅分析当前可本地读取的预览；iCloud 云端\(model.selectedMediaKind.displayName)会跳过",
                        action: { Task { await model.generateStandardLibrarySuggestions() } },
                        jobActivity: model.standardLibrarySuggestionJobActivity,
                        applyAction: { await model.applyStandardLibrarySuggestionAction($0) }
                    )
                }

                if model.supportsPersonalLibrarySuggestions {
                    localModelActionCard(
                        title: "个人模型",
                        statusText: personalLibraryStatusText,
                        statusColor: personalLibraryStatusColor,
                        actionTitle: personalLibraryActionTitle,
                        actionIcon: "brain.head.profile",
                        isRunning: model.isGeneratingPersonalLibrarySuggestions,
                        isDisabled:
                            model.isGeneratingPersonalLibrarySuggestions
                            || model.isGeneratingStandardLibrarySuggestions
                            || model.isRebuildingPersonalModel,
                        help: personalLibraryActionHelp,
                        action: { Task { await model.generatePersonalLibrarySuggestions() } },
                        jobActivity: model.personalLibrarySuggestionJobActivity,
                        applyAction: { await model.applyPersonalLibrarySuggestionAction($0) }
                    )
                }
            }
            .padding(16)
        }
        .background(ReviewWorkspacePalette.canvas)
    }

    private var personalLibraryActionTitle: String {
        if model.isGeneratingPersonalLibrarySuggestions {
            return "扫描中…"
        }
        return "扫描全部"
    }

    private var personalLibraryActionHelp: String {
        model.usesAppPersonalSampleSuggestionsPath
            ? "有多选时使用全部选中\(model.selectedMediaKind.displayName)；无多选时扫描全部可用照片。仅用本机预览；云端未下载\(model.selectedMediaKind.displayName)会跳过"
            : "按顶部来源筛选扫描；仅分析当前可本地读取的预览；iCloud 云端\(model.selectedMediaKind.displayName)会跳过"
    }

    @ViewBuilder
    private func localModelActionCard(
        title: String,
        statusText: String,
        statusColor: Color,
        actionTitle: String,
        actionIcon: String,
        isRunning: Bool,
        isDisabled: Bool,
        help: String,
        action: @escaping () -> Void,
        jobActivity: JobActivityItem?,
        applyAction: @escaping (JobActivityAction) async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                if isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(actionTitle)
                    }
                } else {
                    Label(actionTitle, systemImage: actionIcon)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isDisabled)
            .persistentHelp(help)
            if let jobActivity, !jobActivity.availableActions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(jobActivity.availableActions, id: \.self) { jobAction in
                        Button(reviewJobActionTitle(jobAction), role: jobAction == .cancel ? .destructive : nil) {
                            Task { await applyAction(jobAction) }
                        }
                        .font(.caption)
                        .disabled(model.isApplyingJobActivityAction(jobActivity.id))
                        .persistentHelp(reviewJobActionHelp(jobAction))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ReviewWorkspacePalette.card,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(ReviewWorkspacePalette.separator.opacity(0.55))
        }
    }

    private var localModelServiceStatusText: String {
        switch model.localModelServiceHealthState {
        case .unchecked:
            "本地模型服务尚未检查。"
        case .checking:
            "正在检查本地模型服务…"
        case let .ready(serviceVersion, provider):
            "已就绪 · \(provider.provider) / \(provider.modelID) · v\(serviceVersion)"
        case let .degraded(serviceVersion):
            "已连接，模型未加载 · v\(serviceVersion)"
        case .unavailable:
            "服务未运行；现有\(model.selectedMediaKind.displayName)、标签和 Feature Print 不受影响。"
        }
    }

    private var localModelServiceStatusColor: Color {
        switch model.localModelServiceHealthState {
        case .ready: .green
        case .degraded: .orange
        case .unavailable: .red
        case .unchecked, .checking: .secondary
        }
    }

    private var personalLibraryStatusText: String {
        switch model.personalLibrarySuggestionState {
        case .idle:
            "扫描当前来源，并保留全部高于门槛的个人模型建议。"
        case let .waiting(checked, suggested, skipped):
            "等待 · 已检 \(checked) · 建议 \(suggested) · 跳过 \(skipped)"
        case let .running(checked, suggested, skipped):
            "已检 \(checked) · 建议 \(suggested) · 跳过 \(skipped)"
        case let .paused(checked, suggested, skipped):
            "已暂停 · 已检 \(checked) · 建议 \(suggested) · 跳过 \(skipped)"
        case let .retryableFailure(checked, suggested, skipped):
            "将重试 · 已检 \(checked) · 建议 \(suggested) · 跳过 \(skipped)"
        case let .completed(checked, suggested, skipped):
            "完成 · 检 \(checked) · 写入 \(suggested) · 跳过 \(skipped)"
        case let .cancelled(checked, suggested, skipped):
            "已取消 · 检 \(checked) · 写入 \(suggested) · 跳过 \(skipped)"
        case .personalUnavailable:
            "无可用个人模型，请先重建。"
        case .serviceUnavailable:
            "本地服务不可用。"
        case .failed:
            "结果未通过校验，已安全忽略。"
        }
    }

    private var standardLibraryStatusText: String {
        switch model.standardLibrarySuggestionState {
        case .idle:
            "把标准模型建议加入审核队列。"
        case let .waiting(checked, suggested, skipped):
            "等待 · 已检 \(checked) · 建议 \(suggested) · 跳过 \(skipped)"
        case let .running(checked, suggested, skipped):
            "已检 \(checked) · 建议 \(suggested) · 跳过 \(skipped)"
        case let .paused(checked, suggested, skipped):
            "已暂停 · 已检 \(checked) · 建议 \(suggested) · 跳过 \(skipped)"
        case let .retryableFailure(checked, suggested, skipped):
            "将重试 · 已检 \(checked) · 建议 \(suggested) · 跳过 \(skipped)"
        case let .completed(checked, suggested, skipped):
            "完成 · 检 \(checked) · 写入 \(suggested) · 跳过 \(skipped)"
        case let .cancelled(checked, suggested, skipped):
            "已取消 · 检 \(checked) · 写入 \(suggested) · 跳过 \(skipped)"
        case .serviceUnavailable:
            "本地服务不可用。"
        case .failed:
            "结果未通过校验，已安全忽略。"
        }
    }

    private var standardLibraryStatusColor: Color {
        switch model.standardLibrarySuggestionState {
        case .failed, .serviceUnavailable, .retryableFailure: .red
        case .paused: .orange
        default: .secondary
        }
    }

    private var personalLibraryStatusColor: Color {
        switch model.personalLibrarySuggestionState {
        case .failed, .serviceUnavailable, .retryableFailure: .red
        case .personalUnavailable, .paused: .orange
        default: .secondary
        }
    }
}

private struct ReviewTagOverviewCard: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let overview: SuggestionTagOverview
    let onOpenQueue: (UUID, String) -> Void
    @State private var showsGenerationControls = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(overview.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if overview.pendingSuggestionCount > 0 {
                    Text("\(overview.pendingSuggestionCount) 待审")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }

            HStack(spacing: 8) {
                Label(reviewTagStatusText(overview), systemImage: reviewTagStatusIcon(overview))
                    .lineLimit(1)
                    .foregroundStyle(reviewTagStatusColor(overview))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(reviewTagStatusColor(overview).opacity(0.1), in: Capsule())
                Spacer(minLength: 4)
                Label("\(overview.acceptedSampleCount)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("\(overview.rejectedSampleCount)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            if overview.pendingSuggestionCount > 0 {
                ReviewOriginCountBadges(
                    counts: overview.pendingSuggestionCounts,
                    mediaKind: model.selectedMediaKind,
                    onOpenQueue: { onOpenQueue(overview.id, overview.displayName) }
                )
            }

            if overview.missingPositiveCount > 0 || overview.missingNegativeCount > 0 {
                Text("还需确认 \(overview.missingPositiveCount) 张、拒绝 \(overview.missingNegativeCount) 张")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if overview.recommendedPositiveSampleGap > 0
                || overview.recommendedNegativeSampleGap > 0
            {
                Text("建议正反样本各至少 4 张（当前 \(overview.acceptedSampleCount)/\(overview.rejectedSampleCount)）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if overview.canReview {
                Button {
                    onOpenQueue(overview.id, overview.displayName)
                } label: {
                    Label("审核 \(overview.pendingSuggestionCount) 条建议", systemImage: "checklist")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .persistentHelp(
                    "打开“\(overview.displayName)”的待审核\(model.selectedMediaKind.displayName)队列，逐个确认、拒绝或稍后处理。"
                )
            }

            DisclosureGroup(isExpanded: $showsGenerationControls) {
                VStack(alignment: .leading, spacing: 8) {
                    TagSuggestionThresholdControls(
                        model: model,
                        tagID: overview.id,
                        displayName: overview.displayName,
                        rejectedSampleCount: overview.rejectedSampleCount
                    )
                    Divider()
                    ReviewTagGenerateActions(model: model, overview: overview)
                }
                .padding(.top, 6)
            } label: {
                Label("调整门槛与生成", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ReviewWorkspacePalette.card,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    overview.pendingSuggestionCount > 0
                        ? Color.accentColor.opacity(0.32)
                        : ReviewWorkspacePalette.separator.opacity(0.55),
                    lineWidth: 1
                )
        }
    }
}

private func reviewTagStatusColor(_ overview: SuggestionTagOverview) -> Color {
    switch overview.taskStatus {
    case .running, .waiting: .blue
    case .paused, .retryableFailure, .notReady: .orange
    case .terminalFailure: .red
    case .completed where overview.pendingSuggestionCount > 0: .accentColor
    case .ready, .completed: .secondary
    case .cancelled: .secondary
    }
}

private struct ReviewOriginCountBadges: View {
    let counts: SuggestionOriginCounts
    let mediaKind: MediaKind
    let onOpenQueue: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            originBadge("超级个人", count: counts.personalAdamW)
            originBadge("个人模型", count: counts.personalModel)
            originBadge("特征向量", count: counts.featurePrint)
            originBadge("标准模型", count: counts.standardModel)
        }
    }

    @ViewBuilder
    private func originBadge(_ title: String, count: Int) -> some View {
        if count > 0 {
            Button(action: onOpenQueue) {
                Text("\(title) \(count)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .persistentHelp("打开这个标签的待审核\(mediaKind.displayName)队列。")
        }
    }
}

private struct ReviewTagGenerateActions: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let overview: SuggestionTagOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if overview.canGenerate || overview.canUpdate {
                Text("生成建议")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 6, alignment: .leading)],
                alignment: .leading,
                spacing: 6
            ) {
                if overview.canGenerate {
                    generateButton(
                        title: "生成全部特征建议",
                        icon: "wand.and.stars",
                        method: .featureKnn,
                        mode: .generate
                    )
                }
                if overview.canUpdate {
                    generateButton(
                        title: "更新特征向量",
                        icon: "arrow.triangle.2.circlepath",
                        method: .featureKnn,
                        mode: .update
                    )
                }
                if model.canGenerateAppPersonalTagLibrarySuggestions(for: overview) {
                    generateButton(
                        title: "生成全部个人建议",
                        icon: "brain.head.profile",
                        method: .personalModel,
                        mode: overview.canUpdate ? .update : .generate,
                        isBusy: model.isGeneratingAppPersonalTagLibrarySuggestions
                    )
                    .disabled(model.isGeneratingAppPersonalTagLibrarySuggestions)
                }
                if model.canGenerateAppPersonalAdamWTagLibrarySuggestions(for: overview) {
                    generateButton(
                        title: "生成全部超级个人建议",
                        icon: "brain.head.profile.fill",
                        method: .personalAdamW,
                        mode: overview.canUpdate ? .update : .generate,
                        isBusy: model.isGeneratingAppPersonalTagLibrarySuggestions
                    )
                    .disabled(model.isGeneratingAppPersonalTagLibrarySuggestions)
                }
            }

            if overview.canPause || overview.canResume || overview.canCancel,
               let jobID = overview.activeJobID
            {
                HStack(spacing: 8) {
                    if overview.canPause {
                        Button {
                            Task { await model.pauseSuggestionJob(jobID) }
                        } label: {
                            Label("暂停", systemImage: "pause.fill")
                        }
                        .controlSize(.small)
                        .persistentHelp("暂停这个标签的建议生成任务，并保存当前进度。")
                    }
                    if overview.canResume {
                        Button {
                            Task { await model.resumeSuggestionJob(jobID) }
                        } label: {
                            Label("继续", systemImage: "play.fill")
                        }
                        .controlSize(.small)
                        .persistentHelp("从保存的进度继续这个标签的建议生成任务。")
                    }
                    if overview.canCancel {
                        Button(role: .destructive) {
                            Task { await model.cancelSuggestionJob(jobID) }
                        } label: {
                            Label("取消", systemImage: "xmark")
                        }
                        .controlSize(.small)
                        .persistentHelp("取消这个标签的建议生成任务；已经生成的待审建议会保留。")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func generateButton(
        title: String,
        icon: String,
        method: SuggestionGenerationMethod,
        mode: PersonalizationReviewEnqueueMode,
        isBusy: Bool = false
    ) -> some View {
        Button {
            model.requestEnqueueSuggestions(
                tagID: overview.id,
                displayName: overview.displayName,
                mode: mode,
                method: method
            )
        } label: {
            if isBusy {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("扫描中…")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label(title, systemImage: icon)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.bordered)
        .persistentHelp(
            "\(title)：按顶部选择的来源生成或更新“\(overview.displayName)”的待审核建议。"
        )
        .controlSize(.small)
    }
}

private func reviewJobActionTitle(_ action: JobActivityAction) -> String {
    switch action {
    case .pause: "暂停"
    case .resume: "继续"
    case .cancel: "取消"
    }
}

private func reviewJobActionHelp(_ action: JobActivityAction) -> String {
    switch action {
    case .pause:
        "暂停当前建议生成任务，并保存已完成的进度。"
    case .resume:
        "从保存的进度继续当前建议生成任务。"
    case .cancel:
        "取消当前建议生成任务；已经写入的待审建议会保留。"
    }
}

private func reviewTagStatusText(_ overview: SuggestionTagOverview) -> String {
    switch overview.taskStatus {
    case .notReady: "样本不足"
    case .ready: "可生成建议"
    case .waiting: "等待运行"
    case .running:
        if let total = overview.totalCount, total > 0 {
            "正在分析 \(overview.checkedCount)/\(total)，跳过 \(overview.skippedCount)"
        } else {
            "正在分析"
        }
    case .paused: "已暂停"
    case .retryableFailure: "暂时失败，将重试"
    case .completed: overview.pendingSuggestionCount > 0 ? "有待审核建议" : "本轮已完成"
    case .terminalFailure: "任务失败"
    case .cancelled: "已取消"
    }
}

private func reviewTagStatusIcon(_ overview: SuggestionTagOverview) -> String {
    switch overview.taskStatus {
    case .notReady: "exclamationmark.circle"
    case .ready: "sparkles"
    case .waiting: "clock"
    case .running: "progress.indicator"
    case .paused: "pause.circle"
    case .retryableFailure: "arrow.clockwise.circle"
    case .completed: overview.pendingSuggestionCount > 0 ? "tray.full" : "checkmark.circle"
    case .terminalFailure: "xmark.octagon"
    case .cancelled: "xmark.circle"
    }
}


struct TagSuggestionThresholdControls: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let tagID: UUID
    let displayName: String
    let rejectedSampleCount: Int
    @State private var references:
        [SuggestionScoreThresholdMethod: SuggestionThresholdReference] = [:]
    @State private var drafts: [SuggestionScoreThresholdMethod: Double] = [:]
    @State private var draftTexts: [SuggestionScoreThresholdMethod: String] = [:]
    @FocusState private var focusedMethodRaw: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("生效门槛")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(SuggestionScoreThresholdMethod.allCases, id: \.rawValue) { method in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(SuggestionScoreThresholdMethodPresentation.displayName(method))
                            .font(.caption2)
                            .frame(width: 72, alignment: .leading)
                            .lineLimit(1)
                        TextField(
                            "",
                            text: textBinding(for: method),
                            prompt: Text("0.00")
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.caption2.monospacedDigit())
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedMethodRaw, equals: method.rawValue)
                        .onSubmit { commitText(for: method) }
                        Stepper(
                            "",
                            value: stepperBinding(for: method),
                            step: 0.05
                        )
                        .labelsHidden()
                        .controlSize(.mini)
                        .persistentHelp("以 0.05 为步长调整这条建议轨道的最低分数。")
                        Button("刷新") {
                            commitText(for: method)
                            model.prunePendingSuggestionsBelowThreshold(
                                tagID: tagID,
                                displayName: displayName,
                                method: method
                            )
                        }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                        .persistentHelp("按当前门槛移除分数过低的待审建议；不会重新扫描图库。")
                    }
                    if let reference = references[method] {
                        HStack(spacing: 4) {
                            Text(referenceLabel(reference))
                                .foregroundStyle(.secondary)
                            Button("采用") {
                                apply(method: method, minScore: reference.minScore)
                            }
                            .buttonStyle(.borderless)
                            .persistentHelp("采用根据近期样本计算出的参考分数，作为这条建议轨道的最低门槛。")
                        }
                        .font(.caption2)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .task(id: "\(tagID.uuidString.lowercased()):\(rejectedSampleCount)") {
            await reloadThresholdDrafts()
        }
        .onChange(of: model.suggestionThresholdEpoch) { _, _ in
            syncDraftsFromModel()
        }
        .onChange(of: focusedMethodRaw) { oldValue, newValue in
            guard let oldValue, oldValue != newValue,
                  let method = SuggestionScoreThresholdMethod(rawValue: oldValue)
            else { return }
            commitText(for: method)
        }
    }

    private func textBinding(for method: SuggestionScoreThresholdMethod) -> Binding<String> {
        Binding(
            get: {
                draftTexts[method]
                    ?? String(
                        format: "%.2f",
                        drafts[method]
                            ?? model.effectiveSuggestionMinScore(tagID: tagID, method: method)
                    )
            },
            set: { draftTexts[method] = $0 }
        )
    }

    private func stepperBinding(for method: SuggestionScoreThresholdMethod) -> Binding<Double> {
        Binding(
            get: {
                drafts[method]
                    ?? model.effectiveSuggestionMinScore(tagID: tagID, method: method)
            },
            set: { apply(method: method, minScore: $0) }
        )
    }

    private func apply(method: SuggestionScoreThresholdMethod, minScore: Double) {
        guard minScore.isFinite else { return }
        drafts[method] = minScore
        draftTexts[method] = String(format: "%.2f", minScore)
        model.setSuggestionThresholdOverride(
            tagID: tagID,
            method: method,
            minScore: minScore
        )
    }

    private func commitText(for method: SuggestionScoreThresholdMethod) {
        let raw = (draftTexts[method] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(raw), value.isFinite else {
            let current = drafts[method]
                ?? model.effectiveSuggestionMinScore(tagID: tagID, method: method)
            draftTexts[method] = String(format: "%.2f", current)
            return
        }
        apply(method: method, minScore: value)
    }

    private func referenceLabel(_ reference: SuggestionThresholdReference) -> String {
        var parts = ["参考 " + String(format: "%.2f", reference.minScore)]
        if reference.acceptedSampleCount > 0 {
            parts.append(String(reference.acceptedSampleCount) + " 确认")
        }
        if reference.rejectedSampleCount > 0 {
            parts.append(String(reference.rejectedSampleCount) + " 拒绝")
        }
        return parts.joined(separator: " · ")
    }

    private func syncDraftsFromModel() {
        for method in SuggestionScoreThresholdMethod.allCases {
            let value = model.effectiveSuggestionMinScore(tagID: tagID, method: method)
            drafts[method] = value
            // Keep in-progress typing unless the field matches the previous draft.
            if draftTexts[method] == nil
                || Double(draftTexts[method] ?? "") == nil
                || abs((Double(draftTexts[method] ?? "") ?? value) - value) < 0.000_001
            {
                draftTexts[method] = String(format: "%.2f", value)
            }
        }
    }

    private func reloadThresholdDrafts() async {
        let loaded = await model.suggestionThresholdReferences(tagID: tagID)
        references = loaded
        for method in SuggestionScoreThresholdMethod.allCases {
            if model.suggestionThresholdOverride(tagID: tagID, method: method) == nil,
               let reference = loaded[method]
            {
                // No tag override yet: seed from sample-based reference as the default.
                model.setSuggestionThresholdOverride(
                    tagID: tagID,
                    method: method,
                    minScore: reference.minScore
                )
                drafts[method] = reference.minScore
                draftTexts[method] = String(format: "%.2f", reference.minScore)
            } else {
                let value = model.effectiveSuggestionMinScore(tagID: tagID, method: method)
                drafts[method] = value
                draftTexts[method] = String(format: "%.2f", value)
            }
        }
    }
}

struct SuggestionEnqueueConfirmationSheet: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let pending: SuggestionEnqueueConfirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("扫描来源")
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(pending.availableSources) { source in
                    Toggle(
                        source.displayName,
                        isOn: Binding(
                            get: { model.pendingSuggestionConfirmation?.selectedSourceIDs.contains(source.id) ?? false },
                            set: { _ in model.toggleSuggestionEnqueueSource(source.id) }
                        )
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !pending.canStart {
                Text("请至少选择一个来源。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("取消") {
                    model.cancelPendingSuggestionEnqueue()
                }
                .keyboardShortcut(.cancelAction)
                .persistentHelp("关闭确认窗口，不创建本次建议生成任务。")
                Button("开始") {
                    let captured = model.pendingSuggestionConfirmation ?? pending
                    Task { _ = await model.confirmPendingSuggestionEnqueue(captured) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!(model.pendingSuggestionConfirmation?.canStart ?? pending.canStart))
                .persistentHelp("使用当前选择的来源创建建议生成任务。")
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }

    private var title: String {
        switch (pending.method, pending.mode) {
        case (.featureKnn, .generate):
            "生成“\(pending.displayName)”特征向量建议"
        case (.featureKnn, .update):
            "更新“\(pending.displayName)”特征向量建议"
        case (.personalModel, _):
            "用个人模型生成“\(pending.displayName)”建议"
        case (.personalAdamW, _):
            "用超级个人模型生成“\(pending.displayName)”建议"
        }
    }

    private var message: String {
        let thresholdText = String(format: "%.2f", pending.effectiveMinScore)
        let mediaName = pending.mediaKind.displayName
        switch pending.method {
        case .featureKnn:
            switch pending.mode {
            case .generate:
                return "将用特征向量近邻检查所选来源中已入库的\(mediaName)，保留全部分数高于 \(thresholdText) 的待审核建议。训练样本仍来自全部来源；人工标签不会丢失。"
            case .update:
                return "将用最新确认/拒绝样本重新扫描所选来源，保留全部分数高于 \(thresholdText) 的建议；人工标签不会改变。"
            }
        case .personalModel:
            return "将用当前人脑质心个人模型扫描所选来源，保留全部分数高于 \(thresholdText) 的“\(pending.displayName)”待审核建议。需要该标签已在人脑模型中；不要求拒绝样本。人工标签不会丢失。"
        case .personalAdamW:
            return "将用当前超级人脑 AdamW 个人模型扫描所选来源，保留全部分数高于 \(thresholdText) 的“\(pending.displayName)”待审核建议。需要该标签已在超级模型中；不要求拒绝样本。人工标签不会丢失。"
        }
    }
}

struct ReviewQueueContentView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let tagID: UUID
    let displayName: String
    @FocusState.Binding var contentFocused: Bool
    @State private var gridColumnCount = 1
    @State private var gridPageItemCount = 1
    @State private var gridCellFrames = LibraryGridCellFrameStore()
    @State private var isMarqueeSelecting = false
    @State private var gridScrollTargetID: ReviewQueueItemID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(displayName, systemImage: "checklist")
                        .font(.headline)
                    if let overview = model.suggestionOverviews.first(where: { $0.id == tagID }) {
                        Text(statusHeader(overview))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                ReviewSourceFilterMenu(model: model)
                if !model.reviewQueueItems.isEmpty {
                    Text("已载入 \(model.reviewQueueItems.count)")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.secondary.opacity(0.1), in: Capsule())
                }
                if !model.reviewQueueItems.isEmpty {
                    LibraryGridDensityPicker(
                        selection: Binding(
                            get: { model.gridDensity },
                            set: { model.setGridDensity($0) }
                        ),
                        help: "调整待审核建议网格缩略图大小"
                    )
                    LibraryThumbnailAspectModeButton(
                        selection: Binding(
                            get: { model.thumbnailAspectMode },
                            set: { model.setThumbnailAspectMode($0) }
                        )
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            Divider()
            if model.reviewQueueItems.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "sparkles")
                } description: {
                    Text(emptyDescription)
                }
            } else {
                reviewGrid
            }
        }
        .navigationTitle("审核“\(displayName)”建议")
        .focusable()
        .focused($contentFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard model.primarySelectedAssetID != nil else { return .ignored }
            model.toggleSinglePhotoView()
            return .handled
        }
        .onKeyPress(keys: [.init("a")], action: handleSelectAllKeyPress)
        .onKeyPress(
            keys: [.leftArrow, .rightArrow, .upArrow, .downArrow],
            action: handleNavigationKey
        )
    }

    private var reviewGrid: some View {
        GeometryReader { proxy in
            let layoutWidth = LibraryGridLayout.layoutWidth(containerWidth: proxy.size.width)
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LibraryGridMarqueeContainer(
                        cellFrames: gridCellFrames,
                        isMarqueeSelecting: $isMarqueeSelecting,
                        viewportHeight: proxy.size.height,
                        contentWidth: layoutWidth,
                        currentSelection: model.selectedAssetIDs,
                        onSelectionChange: { assetIDs, isFinal in
                            contentFocused = true
                            Task {
                                await model.selectAssets(
                                    assetIDs,
                                    shouldRefreshInspector: isFinal
                                )
                            }
                        }
                    ) {
                        LazyVGrid(
                            columns: LibraryGridLayout.gridItems(
                                containerWidth: proxy.size.width,
                                density: model.gridDensity
                            ),
                            spacing: LibraryGridLayout.spacing
                        ) {
                            ForEach(model.reviewQueueItems) { item in
                                ReviewThumbnailView(
                                    state: ReviewThumbnailPresentationState(
                                        item: item,
                                        isSelected: model.selectedReviewItemID == item.id
                                            || (
                                                model.selectedReviewItemID == nil
                                                    && model.selectedAssetIDs.contains(item.assetID)
                                            ),
                                        favoriteState: model.favoriteState(for: item.assetID),
                                        aspectMode: model.thumbnailAspectMode,
                                        cacheVersion: model.thumbnailCacheVersion(for: item.assetID),
                                        originalAspectGeneration: model.thumbnailAspectMode == .original
                                            ? model.originalAspectThumbnailCacheGeneration
                                            : 0,
                                        recoveryGeneration: model.thumbnailRecoveryGeneration,
                                        mediaKind: model.selectedMediaKind
                                    ),
                                    model: model,
                                    onSelect: {
                                        guard !isMarqueeSelecting else { return }
                                        contentFocused = true
                                        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                                        Task {
                                            if flags.contains(.command) || flags.contains(.shift) {
                                                await model.selectAsset(
                                                    item.assetID,
                                                    additive: flags.contains(.command),
                                                    extendRange: flags.contains(.shift)
                                                )
                                            } else {
                                                await model.selectReviewItem(item.id)
                                            }
                                        }
                                    },
                                    onOpen: {
                                        contentFocused = true
                                        Task {
                                            await model.openSinglePhotoView(reviewItemID: item.id)
                                        }
                                    }
                                )
                                .equatable()
                                .libraryGridCellFrameReporter(assetID: item.assetID)
                                .id(item.id)
                                .task {
                                    await model.loadMoreReviewQueueIfNeeded(
                                        currentAssetID: item.assetID,
                                        tagID: tagID
                                    )
                                }
                            }
                        }
                        .padding(LibraryGridLayout.horizontalPadding)
                    }
                }
                .scrollDisabled(isMarqueeSelecting)
                .libraryGridPageKeyHandling(
                    isEnabled: reviewPageKeyHandlingEnabled,
                    onPageKey: handleReviewPageNavigation
                )
                .background(Color(nsColor: .windowBackgroundColor))
                .accessibilityLabel("待审核建议网格")
                .onAppear {
                    updateGridMetrics(containerSize: proxy.size)
                    contentFocused = true
                    gridScrollTargetID = model.selectedReviewItemID
                }
                .onChange(of: proxy.size) { _, size in
                    updateGridMetrics(containerSize: size)
                }
                .onChange(of: model.gridDensity) { _, _ in
                    updateGridMetrics(containerSize: proxy.size)
                }
                .onChange(of: model.thumbnailAspectMode) { _, _ in
                    updateGridMetrics(containerSize: proxy.size)
                }
                .onChange(of: gridScrollTargetID) { _, itemID in
                    guard let itemID else { return }
                    scrollProxy.scrollTo(itemID, anchor: .center)
                    gridScrollTargetID = nil
                }
            }
        }
    }

    private func handleSelectAllKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard keyPress.modifiers.contains(.command) else { return .ignored }
        return handleSelectAllKey()
    }

    private func handleSelectAllKey() -> KeyPress.Result {
        guard contentFocused, !model.isSinglePhotoPresented, !model.reviewQueueItems.isEmpty else {
            return .ignored
        }
        Task { await model.selectAllVisibleAssets() }
        return .handled
    }

    private func handleNavigationKey(_ keyPress: KeyPress) -> KeyPress.Result {
        guard contentFocused, !model.reviewQueueItems.isEmpty else { return .ignored }
        let direction: LibraryGridNavigationDirection
        switch keyPress.key {
        case .leftArrow: direction = .left
        case .rightArrow: direction = .right
        case .upArrow: direction = .up
        case .downArrow: direction = .down
        default: return .ignored
        }

        Task {
            await model.moveReviewPrimarySelection(
                in: direction,
                columnCount: gridColumnCount
            )
            gridScrollTargetID = model.selectedReviewItemID
        }
        return .handled
    }

    private var reviewPageKeyHandlingEnabled: Bool {
        !model.isSinglePhotoPresented && !model.reviewQueueItems.isEmpty
    }

    private func handleReviewPageNavigation(_ direction: LibraryGridPageDirection) {
        guard reviewPageKeyHandlingEnabled else { return }
        contentFocused = true
        Task {
            await model.moveReviewPrimarySelection(
                byPage: direction,
                pageItemCount: gridPageItemCount
            )
            gridScrollTargetID = model.selectedReviewItemID
        }
    }

    private func updateGridMetrics(containerSize: CGSize) {
        gridColumnCount = LibraryGridLayout.columnCount(
            containerWidth: containerSize.width,
            density: model.gridDensity
        )
        gridPageItemCount = LibraryGridLayout.pageItemCount(
            containerWidth: containerSize.width,
            containerHeight: containerSize.height,
            density: model.gridDensity
        )
    }

    private var emptyTitle: String {
        guard let overview = model.suggestionOverviews.first(where: { $0.id == tagID }) else {
            return "暂无建议"
        }
        switch overview.taskStatus {
        case .notReady: return "样本不足"
        case .waiting, .running: return "正在生成建议"
        case .completed: return "已全部审核"
        case .terminalFailure: return "任务失败"
        default: return "暂无建议"
        }
    }

    private var emptyDescription: String {
        "按 P 确认属于、X 不属于、U 稍后。快捷键仅在审核网格焦点内生效。"
    }

    private func statusHeader(_ overview: SuggestionTagOverview) -> String {
        switch overview.taskStatus {
        case .running:
            if let total = overview.totalCount, total > 0 {
                "正在分析 · 已检查 \(overview.checkedCount)/\(total) · 跳过 \(overview.skippedCount)"
            } else {
                "正在分析"
            }
        case .paused: "已暂停"
        case .waiting: "等待运行"
        default: "\(overview.pendingSuggestionCount) 条待审核"
        }
    }
}

private extension ReviewQueueSuggestionOrigin {
    var reviewDisplayName: String {
        switch self {
        case .featurePrint: "特征向量"
        case .standardModel: "标准模型"
        case .personalModel: "个人模型"
        case .personalAdamW: "超级个人"
        }
    }
}

private struct ReviewThumbnailLoadID: Hashable {
    let assetID: UUID
    let cacheVersion: Int
    let aspectMode: LibraryThumbnailAspectMode
    let originalAspectCacheGeneration: Int
    let recoveryGeneration: Int
}

private struct ReviewThumbnailPresentationState: Equatable {
    let item: ReviewQueueItemProjection
    let isSelected: Bool
    let favoriteState: MediaFavoriteState
    let aspectMode: LibraryThumbnailAspectMode
    let cacheVersion: Int
    let originalAspectGeneration: Int
    let recoveryGeneration: Int
    let mediaKind: MediaKind
}

@MainActor
private struct ReviewThumbnailView: View, @MainActor Equatable {
    let state: ReviewThumbnailPresentationState
    let model: LibraryWorkspaceModel
    let onSelect: () -> Void
    let onOpen: () -> Void
    @State private var image: NSImage?
    @State private var isCloudOnly = false
    @State private var isHovered = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: state.aspectMode.imageContentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    Image(systemName: emptyThumbnailSymbol)
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    Spacer()
                    HStack {
                        Text(item.suggestionOrigin.reviewDisplayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.65), in: Capsule())
                        if item.score.isFinite {
                            Text(String(format: "%.2f", item.score))
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.65), in: Capsule())
                        }
                        Spacer()
                    }
                    .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            }
            .overlay(alignment: .topTrailing) {
                MediaFavoriteButton(
                    state: state.favoriteState,
                    isVisible: isHovered || isSelected
                ) {
                    Task { await model.toggleFavorite(assetID: item.assetID) }
                }
                .padding(6)
            }
        }
        .aspectRatio(
            state.aspectMode.frameAspectRatio(imageSize: image?.size),
            contentMode: .fit
        )
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2)
                .onEnded { onOpen() }
                .exclusively(
                    before: TapGesture().onEnded { onSelect() }
                )
        )
        .accessibilityLabel(item.fileName ?? state.mediaKind.displayName)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(
            "\(isSelected ? "已选择" : "未选择")，\(item.suggestionOrigin.reviewDisplayName)建议，分数 \(String(format: "%.2f", item.score))"
        )
        .accessibilityHint(
            "选择待审核\(state.mediaKind.displayName)；双击可预览，也可按 P、X 或 U 处理"
        )
        .persistentHelp(LibraryAssetDetailText.reviewHoverText(item))
        .accessibilityAction {
            onSelect()
        }
        .accessibilityAction(named: "打开单图预览") {
            onOpen()
        }
        .contextMenu {
            Button(state.favoriteState.isFavorite ? "取消红心" : "加入红心") {
                Task { await model.toggleFavorite(assetID: item.assetID) }
            }
        }
        .onHover { isHovered = $0 }
        .task(id: ReviewThumbnailLoadID(
            assetID: item.assetID,
            cacheVersion: state.cacheVersion,
            aspectMode: state.aspectMode,
            originalAspectCacheGeneration: state.originalAspectGeneration,
            recoveryGeneration: state.recoveryGeneration
        )) {
            await loadReviewThumbnailWhileVisible()
        }
    }

    private func loadReviewThumbnailWhileVisible() async {
        isCloudOnly = false
        image = nil
        guard item.availability == .available else {
            return
        }

        let aspectMode = state.aspectMode
        if let cachedImage = model.cachedThumbnailImage(
            for: item.assetID,
            aspectMode: aspectMode
        ) {
            image = cachedImage
            return
        }
        if aspectMode == .square,
           let cached = model.cachedThumbnailData(for: item.assetID),
           let cachedImage = LibraryGridThumbnailImageFactory.image(from: cached)
        {
            model.rememberThumbnailImage(
                cachedImage,
                for: item.assetID,
                aspectMode: aspectMode
            )
            image = cachedImage
            return
        }

        var transientAttempts = 0
        while !Task.isCancelled {
            switch await model.loadThumbnailResultWithRetry(
                assetID: item.assetID,
                aspectMode: aspectMode
            ) {
            case let .loaded(data):
                guard !Task.isCancelled else { return }
                if let decoded = LibraryGridThumbnailImageFactory.image(from: data) {
                    if aspectMode == .square {
                        model.rememberThumbnailData(data, for: item.assetID)
                    }
                    model.rememberThumbnailImage(
                        decoded,
                        for: item.assetID,
                        aspectMode: aspectMode
                    )
                    image = decoded
                    return
                }
                transientAttempts += 1
                if transientAttempts >= 4 {
                    return
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            case .cloudOnly:
                guard !Task.isCancelled else { return }
                isCloudOnly = true
                return
            case .unavailable:
                return
            case .cancelled:
                try? await Task.sleep(nanoseconds: 120_000_000)
            case .failed:
                transientAttempts += 1
                if transientAttempts >= 2 {
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private var emptyThumbnailSymbol: String {
        if isCloudOnly {
            return "icloud.and.arrow.down"
        }
        return state.mediaKind == .video ? "play.rectangle" : "photo"
    }

    private var item: ReviewQueueItemProjection { state.item }
    private var isSelected: Bool { state.isSelected }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state == rhs.state
    }
}

struct InspectorSuggestionSection: View {
    @ObservedObject var model: LibraryWorkspaceModel
    @State private var expanded = false

    var body: some View {
        if !model.assetPendingSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("AI 建议")
                    .font(.headline)
                let visible = expanded ? model.assetPendingSuggestions : Array(model.assetPendingSuggestions.prefix(5))
                ForEach(visible) { suggestion in
                    HStack {
                        Text(suggestion.displayName)
                        Text(suggestion.suggestionOrigin.reviewDisplayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: Capsule())
                        Spacer()
                        Button("属于") {
                            Task {
                                await model.applyInspectorSuggestion(tagID: suggestion.tagID, action: .accept)
                            }
                        }
                        .persistentHelp(
                            "确认这个\(model.selectedMediaKind.displayName)属于“\(suggestion.displayName)”标签，并写入人工决定。"
                        )
                        Button("不属于") {
                            Task {
                                await model.applyInspectorSuggestion(tagID: suggestion.tagID, action: .reject)
                            }
                        }
                        .persistentHelp(
                            "确认这个\(model.selectedMediaKind.displayName)不属于“\(suggestion.displayName)”标签，并写入人工决定。"
                        )
                    }
                    .font(.caption)
                }
                if model.assetPendingSuggestions.count > 5, !expanded {
                    Button("另外 \(model.assetPendingSuggestions.count - 5) 条建议") {
                        expanded = true
                    }
                    .font(.caption)
                    .persistentHelp(
                        "展开并显示这个\(model.selectedMediaKind.displayName)剩余的全部模型建议。"
                    )
                }
            }
            .onChange(of: model.primarySelectedAssetID) { _, _ in
                expanded = false
            }
        }
    }
}

struct InspectorLocalModelSuggestionSection: View {
    @ObservedObject var model: LibraryWorkspaceModel

    var body: some View {
        switch model.localModelSuggestionState {
        case .hidden:
            EmptyView()
        case .ready:
            container {
                HStack {
                    standardRequestButton("标准场景")
                    personalRequestButton("个人标签")
                }
            }
        case .loading:
            container {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在分析当前\(model.selectedMediaKind.displayName)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case let .results(_, suggestions):
            container {
                if suggestions.isEmpty {
                    Text("当前模型没有给出建议。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
                        HStack {
                            Text(displayName(for: suggestion))
                            Spacer()
                            if suggestion.track == .personal {
                                Button {
                                    Task {
                                        await model.applyLocalModelSuggestionDecision(
                                            suggestion,
                                            action: .reject
                                        )
                                    }
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.borderless)
                                .persistentHelp(
                                    "拒绝这条模型建议，不把该标签添加到\(model.selectedMediaKind.displayName)。"
                                )
                                Button {
                                    Task {
                                        await model.applyLocalModelSuggestionDecision(
                                            suggestion,
                                            action: .accept
                                        )
                                    }
                                } label: {
                                    Image(systemName: "checkmark")
                                }
                                .buttonStyle(.borderless)
                                .persistentHelp(
                                    "接受这条模型建议，并把对应标签添加到\(model.selectedMediaKind.displayName)。"
                                )
                            } else {
                                Text(suggestion.recommendedState == .autoAssigned ? "自动匹配" : "建议复核")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                }
                retryButton("重新分析")
                    .font(.caption)
            }
        case .previewUnavailable:
            container {
                Text("请先在上方获取这个\(model.selectedMediaKind.displayName)的 iCloud 预览。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .personalUnavailable:
            container {
                Text("当前目录没有可用的个人模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                personalRequestButton("重试")
                    .font(.caption)
            }
        case .serviceUnavailable:
            container {
                Text(
                    "本地模型服务当前不可用，\(model.selectedMediaKind.displayName)与人工标签不受影响。"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                retryButton("重试")
                    .font(.caption)
            }
        case .failed:
            container {
                Text("模型结果未通过校验，已安全忽略。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                retryButton("重试")
                    .font(.caption)
            }
        }
    }

    private func container<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本地模型预览")
                .font(.headline)
            content()
        }
    }

    private func standardRequestButton(_ title: String) -> some View {
        Button(title) {
            Task { await model.requestLocalModelSuggestions() }
        }
        .buttonStyle(.bordered)
        .persistentHelp(
            "使用标准场景模型分析当前\(model.selectedMediaKind.displayName)，并显示建议标签。"
        )
    }

    private func personalRequestButton(_ title: String) -> some View {
        Button(title) {
            Task { await model.requestPersonalModelSuggestions() }
        }
        .buttonStyle(.bordered)
        .persistentHelp(
            "使用你的个人模型分析当前\(model.selectedMediaKind.displayName)，并显示建议标签。"
        )
    }

    @ViewBuilder
    private func retryButton(_ title: String) -> some View {
        if model.localModelSuggestionTrack == .personal {
            personalRequestButton(title)
        } else {
            standardRequestButton(title)
        }
    }

    private func displayName(for suggestion: LocalModelSuggestion) -> String {
        if let tagID = suggestion.tagID,
           let tag = model.tags.first(where: { $0.id == tagID })
        {
            return tag.displayName
        }
        guard suggestion.ontologyID == "imageall-public-fixture",
              suggestion.ontologyRevision == "ontology-v1"
        else {
            return "标准场景建议"
        }
        return switch suggestion.conceptID {
        case "scene.environment": "环境"
        case "scene.outdoor": "户外"
        case "scene.water": "水域"
        default: "标准场景建议"
        }
    }
}
