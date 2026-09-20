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
    private enum ScopeTagAction: String, CaseIterable, Identifiable {
        case include
        case exclude

        var id: Self { self }
    }

    @ObservedObject var model: LibraryWorkspaceModel
    @State private var newTagName = ""
    @State private var isScopeExpanded = false
    @State private var scopeTagAction: ScopeTagAction = .include

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                photoTagEditor

                Divider()

                DisclosureGroup(isExpanded: $isScopeExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("选择点击操作后再点标签；也可随时用 ⌘⌥ 点击反选排除。反选标签不会参与智能推荐、自选生成、统计或展示。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        recommendedScopeButton

                        HStack(spacing: 8) {
                            Picker("标签点击操作", selection: $scopeTagAction) {
                                Label("加入范围", systemImage: "checkmark.circle")
                                    .tag(ScopeTagAction.include)
                                Label("反选排除", systemImage: "minus.circle")
                                    .tag(ScopeTagAction.exclude)
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("contextualTagFeedScopeTagAction")

                            if !model.excludedContextualTagFeedTagIDs.isEmpty {
                                Button("清除反选") {
                                    Task { await model.clearExcludedContextualTagFeedTags() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(model.isLoadingContextualTagFeed)
                                .persistentHelp("让所有标签重新参与智能推荐；不改变自选标签范围。")
                            }
                        }

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
                    Text(recommendedScopeSubtitle)
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
        .persistentHelp("恢复智能推荐，让未被反选的标签参与并优先显示依赖时间、位置和事件上下文的标签。")
    }

    private var recommendedScopeSubtitle: String {
        let excludedCount = model.excludedContextualTagFeedTagIDs.count
        return excludedCount == 0
            ? "全部标签参与，上下文标签优先"
            : "已反选排除 \(excludedCount) 个标签，其余按上下文优先"
    }

    private func tagGroupSection(_ section: LibraryTagGroupSection) -> some View {
        let isExpanded = model.isContextualTagFeedScopeGroupExpanded(section.group.id)
        let selectedCount = section.tags.count { model.isInContextualTagFeedScope($0.id) }
        let excludedCount = section.tags.count {
            model.isExcludedFromContextualTagFeed($0.id)
        }
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                model.toggleContextualTagFeedScopeGroupExpanded(section.group.id)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(section.group.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(scopeGroupCountText(
                        selectedCount: selectedCount,
                        excludedCount: excludedCount,
                        totalCount: section.tags.count
                    ))
                    .font(.caption2)
                    .foregroundStyle(
                        excludedCount > 0
                            ? Color.red
                            : selectedCount > 0 ? Color.accentColor : Color.secondary
                    )
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .persistentHelp(
                isExpanded
                    ? "折叠“\(section.group.displayName)”分组，暂时隐藏其中标签。"
                    : "展开“\(section.group.displayName)”分组，显示其中标签。"
            )

            if isExpanded {
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
        let isExcluded = model.isExcludedFromContextualTagFeed(tag.id)
        return Button {
            applyScopeTagAction(tag)
        } label: {
            HStack(spacing: 5) {
                Label {
                    Text(tag.displayName)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: isExcluded ? "tag.slash" : "tag")
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if isExcluded {
                    Image(systemName: "minus.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
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
                            : isExcluded
                                ? Color.red.opacity(0.12)
                            : Color(nsColor: .controlBackgroundColor).opacity(0.75)
                    )
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isExcluded ? Color.red : Color.primary)
        .disabled(model.isLoadingContextualTagFeed)
        .accessibilityLabel(tag.displayName)
        .accessibilityValue(
            isSelected
                ? "已加入推流范围"
                : isExcluded ? "已反选排除" : "未加入推流范围"
        )
        .accessibilityIdentifier("contextualTagFeedScopeTag-\(tag.id.uuidString)")
        .persistentHelp(scopeTagHelp(isSelected: isSelected, isExcluded: isExcluded))
        .contextMenu {
            Button(isSelected ? "移出自选范围" : "加入自选范围") {
                Task { await model.toggleContextualTagFeedScopeTag(tag.id) }
            }
            Button(isExcluded ? "取消反选" : "反选排除此标签") {
                Task { await model.toggleExcludedContextualTagFeedTag(tag.id) }
            }
        }
    }

    private func applyScopeTagAction(_ tag: TagListItem) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let action: ScopeTagAction = flags.contains(.command) && flags.contains(.option)
            ? .exclude
            : scopeTagAction
        Task {
            switch action {
            case .include:
                await model.toggleContextualTagFeedScopeTag(tag.id)
            case .exclude:
                await model.toggleExcludedContextualTagFeedTag(tag.id)
            }
        }
    }

    private func scopeTagHelp(isSelected: Bool, isExcluded: Bool) -> String {
        if scopeTagAction == .exclude {
            return isExcluded
                ? "点击取消反选；该标签将重新参与推流。"
                : "点击反选排除；智能推荐也不会再推送该标签。"
        }
        if isExcluded {
            return "点击改为只推此标签；⌘⌥ 点击可取消反选。"
        }
        return isSelected
            ? "点击移出自选范围；⌘⌥ 点击反选排除。"
            : "点击加入自选范围；⌘⌥ 点击反选排除。"
    }

    private func scopeGroupCountText(
        selectedCount: Int,
        excludedCount: Int,
        totalCount: Int
    ) -> String {
        let selectedText = selectedCount > 0 ? "已选 \(selectedCount) · " : ""
        let excludedText = excludedCount > 0 ? "反选 \(excludedCount) · " : ""
        return "\(selectedText)\(excludedText)共 \(totalCount)"
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
    static let sectionSpacing: CGFloat = 22
    static let cardSpacing: CGFloat = 12
    static let cardMinimumWidth: CGFloat = 350
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

// The overview owns a bounded viewport. SwiftUI can leave HostingScrollView's
// indicator inset at an intermediate inspector-animation value after dismissal.
// Observe the public AppKit inset so late layout updates cannot detach the
// indicator from that viewport. This does not change the document or scroll offset.
private struct ReviewScrollIndicatorBoundary: NSViewRepresentable {
    func makeNSView(context: Context) -> BoundaryView { BoundaryView() }

    func updateNSView(_ nsView: BoundaryView, context: Context) {
        nsView.refreshAfterLayout()
    }

    static func dismantleNSView(_ nsView: BoundaryView, coordinator: ()) {
        nsView.detach()
    }

    final class BoundaryView: NSView {
        private weak var observedScrollView: NSScrollView?
        private var insetObservation: NSKeyValueObservation?
        private var windowResizeObservation: NSObjectProtocol?
        private var refreshScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() } else { refreshAfterLayout() }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            refreshAfterLayout()
        }

        func detach() {
            insetObservation?.invalidate()
            insetObservation = nil
            if let windowResizeObservation {
                NotificationCenter.default.removeObserver(windowResizeObservation)
            }
            windowResizeObservation = nil
            observedScrollView = nil
        }

        func refreshAfterLayout() {
            guard !refreshScheduled else { return }
            refreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                guard self.window != nil, let scroll = self.enclosingScrollView else { return }
                if self.observedScrollView !== scroll {
                    self.detach()
                    self.observedScrollView = scroll
                    self.insetObservation = scroll.observe(\.scrollerInsets, options: [.new]) { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.refreshAfterLayout() }
                    }
                    self.windowResizeObservation = NotificationCenter.default.addObserver(
                        forName: NSWindow.didResizeNotification, object: self.window, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.refreshAfterLayout() }
                    }
                }
                guard self.bounds.width > 0, let windowContent = self.window?.contentView else { return }
                let contentRight = self.convert(self.bounds, to: scroll).maxX
                let reservedScrollerWidth = max(0, scroll.bounds.maxX - scroll.contentView.frame.maxX)
                let visibleRight = min(
                    scroll.visibleRect.maxX,
                    scroll.convert(windowContent.bounds, from: windowContent).maxX
                )
                let indicatorRight = min(contentRight + reservedScrollerWidth, visibleRight)
                let rightInset = max(0, scroll.bounds.maxX - indicatorRight)
                var insets = scroll.scrollerInsets
                guard abs(insets.right - rightInset) > 0.5 else { return }
                insets.right = rightInset
                scroll.scrollerInsets = insets
            }
        }
    }
}

struct ReviewOverviewView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let onOpenQueue: (UUID, String) -> Void
    let onBack: () -> Void
    @State private var searchText = ""
    @State private var pendingOnly = false

    private var supportsBatchGeneration: Bool {
        model.supportsPersonalLibrarySuggestions || model.supportsStandardLibrarySuggestions
    }

    private var groupedOverviews: [ReviewSuggestionGroupSection] {
        ReviewSuggestionGroupSection.build(
            tagSections: model.tagGroupSections,
            overviews: model.suggestionOverviews.filter {
                (!pendingOnly || $0.pendingSuggestionCount > 0)
                    && (searchText.isEmpty || $0.displayName.localizedCaseInsensitiveContains(searchText))
            }
        ).filter { !$0.overviews.isEmpty }
    }

    var body: some View {
        GeometryReader { workspace in
            overviewContent
                .frame(width: workspace.size.width, height: workspace.size.height)
        }
    }

    private var overviewContent: some View {
        VStack(spacing: 0) {
            ReviewOverviewHeader(model: model, onBack: onBack)
            HStack(spacing: 12) {
                TextField("搜索标签", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Toggle("仅有待审", isOn: $pendingOnly)
                    .toggleStyle(.button)
                Spacer()
                if supportsBatchGeneration {
                    ReviewGenerationActions(model: model)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .background(.bar)
            ReviewGenerationStatusView(model: model)
            if let error = model.reviewOverviewError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Button("重试") { Task { await model.refreshReviewState(reloadActiveQueue: false) } }
                }.padding(12)
            }
            Divider()
            if model.suggestionOverviews.isEmpty, !supportsBatchGeneration {
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
                GeometryReader { viewport in
                    reviewScrollContent(width: viewport.size.width)
                        .frame(width: viewport.size.width)
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

    private func reviewScrollContent(width: CGFloat) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ReviewOverviewLayout.sectionSpacing) {
                if groupedOverviews.isEmpty {
                    ContentUnavailableView("没有匹配标签", systemImage: "magnifyingglass",
                        description: Text("调整搜索词或关闭“仅有待审”。"))
                }
                ForEach(groupedOverviews) { section in
                    ReviewSuggestionGroupView(
                        model: model,
                        section: section,
                        cardMinimumWidth: min(
                            ReviewOverviewLayout.cardMinimumWidth,
                            max(160, width - 40 - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
                        ),
                        revealsSearchMatches: !searchText.isEmpty || pendingOnly,
                        onOpenQueue: onOpenQueue
                    )
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ReviewScrollIndicatorBoundary()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background(ReviewWorkspacePalette.canvas)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }


}

private struct ReviewSuggestionGroupView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let section: ReviewSuggestionGroupSection
    var cardMinimumWidth: CGFloat = ReviewOverviewLayout.cardMinimumWidth
    var revealsSearchMatches = false
    @State private var collapsedWhileFiltering = false
    let onOpenQueue: (UUID, String) -> Void

    private var isCollapsed: Bool {
        revealsSearchMatches ? collapsedWhileFiltering : model.isTagGroupCollapsed(section.id)
    }

    private var pendingCount: Int {
        section.overviews.reduce(0) { $0 + $1.pendingSuggestionCount }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if revealsSearchMatches { collapsedWhileFiltering.toggle() }
                else { model.toggleTagGroupCollapsed(section.id) }
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
                                minimum: cardMinimumWidth,
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
                    Text("标签建议")
                        .font(.system(size: 26, weight: .bold))
                    Text("让每一次确认，成为更懂你的下一次推荐。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
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
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
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

private struct ReviewGenerationActions: View {
    @ObservedObject var model: LibraryWorkspaceModel

    private var isDisabled: Bool {
        model.usesAppPersonalSampleSuggestionsPath
            ? !model.canGenerateAppPersonalSampleSuggestions
            : model.isGeneratingPersonalLibrarySuggestions
                || model.isGeneratingStandardLibrarySuggestions
                || model.isRebuildingPersonalModel
                || model.isRebuildingPersonalAdamWModel
    }

    var body: some View {
        Menu {
            if model.supportsPersonalLibrarySuggestions {
                if model.usesAppPersonalSampleSuggestionsPath {
                    Text(model.selectedAssetIDs.isEmpty
                         ? "范围：全部可用来源（仅本机预览）"
                         : "范围：选中的 \(model.selectedAssetIDs.count) 项（仅本机预览）")
                } else {
                    Text("范围：顶部所选来源（仅本机预览）")
                }
                Button("生成样本匹配模型建议", systemImage: "brain.head.profile") {
                    Task { await model.generatePersonalLibrarySuggestions() }
                }
                .disabled(isDisabled)
            }
            if model.supportsStandardLibrarySuggestions {
                Divider()
                Text("标准模型范围：顶部所选来源（仅本机预览）")
                Button("生成标准模型建议", systemImage: "sparkles.rectangle.stack") {
                    Task { await model.generateStandardLibrarySuggestions() }
                }
                .disabled(isDisabled)
            }
        } label: {
            Label("批量生成建议", systemImage: "wand.and.stars")
        }
        .fixedSize()
        .persistentHelp("选择模型并核对扫描范围；结果写入待审核队列，云端未下载的照片会跳过。")
    }
}

/// The overview shows actionable states and fresh results only. Activity retains the
/// current in-process scan result even after the compact completion strip disappears.
struct ReviewGenerationStatusView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    var showsHistory = false
    @State private var showsPersonalResult = false
    @State private var showsStandardResult = false
    @State private var showsServiceDiagnostics = false

    private var hasPersonalStatus: Bool {
        switch model.personalLibrarySuggestionState {
        case .idle: false
        case .completed, .cancelled: showsHistory || showsPersonalResult
        default: true
        }
    }

    private var hasStandardStatus: Bool {
        switch model.standardLibrarySuggestionState {
        case .idle: false
        case .completed, .cancelled: showsHistory || showsStandardResult
        default: true
        }
    }

    private var needsServiceDiagnostics: Bool {
        model.supportsStandardLibrarySuggestions
            && (model.personalLibrarySuggestionState == .serviceUnavailable
                || model.standardLibrarySuggestionState == .serviceUnavailable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.supportsPersonalLibrarySuggestions && hasPersonalStatus {
                statusRow(title: "样本匹配模型", text: personalLibraryStatusText,
                          color: personalLibraryStatusColor,
                          isRunning: personalIsWorking,
                          activity: model.personalLibrarySuggestionJobActivity,
                          applyAction: { await model.applyPersonalLibrarySuggestionAction($0) })
            }
            if model.supportsStandardLibrarySuggestions && hasStandardStatus {
                statusRow(title: "标准模型", text: standardLibraryStatusText,
                          color: standardLibraryStatusColor,
                          isRunning: standardIsWorking,
                          activity: model.standardLibrarySuggestionJobActivity,
                          applyAction: { await model.applyStandardLibrarySuggestionAction($0) })
            }
            if needsServiceDiagnostics {
                Button("检查本地服务", systemImage: "stethoscope") {
                    showsServiceDiagnostics = true
                    Task { await model.refreshLocalModelServiceHealth() }
                }
                .padding(.horizontal, showsHistory ? 0 : 16)
                .padding(.bottom, 8)
                .popover(isPresented: $showsServiceDiagnostics) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(localModelServiceStatusText)
                            .foregroundStyle(localModelServiceStatusColor)
                        Button("重新检查") {
                            Task { await model.refreshLocalModelServiceHealth() }
                        }
                        .disabled(model.localModelServiceHealthState == .checking)
                    }
                    .padding(16)
                    .frame(width: 300)
                }
            }
        }
        .onChange(of: model.personalLibrarySuggestionState) { _, state in
            switch state {
            case .completed, .cancelled: showsPersonalResult = true
            default: showsPersonalResult = false
            }
        }
        .onChange(of: model.standardLibrarySuggestionState) { _, state in
            switch state {
            case .completed, .cancelled: showsStandardResult = true
            default: showsStandardResult = false
            }
        }
        .task(id: personalLibraryStatusText) {
            guard !showsHistory else { return }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            showsPersonalResult = false
        }
        .task(id: standardLibraryStatusText) {
            guard !showsHistory else { return }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            showsStandardResult = false
        }
    }

    private var personalIsWorking: Bool {
        switch model.personalLibrarySuggestionState {
        case .waiting, .running: true
        default: false
        }
    }

    private var standardIsWorking: Bool {
        switch model.standardLibrarySuggestionState {
        case .waiting, .running: true
        default: false
        }
    }

    private func statusRow(
        title: String, text: String, color: Color, isRunning: Bool,
        activity: JobActivityItem?,
        applyAction: @escaping (JobActivityAction) async -> Void
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                statusLabel(title: title, text: text, color: color, isRunning: isRunning)
                Spacer(minLength: 0)
                jobActions(activity, applyAction: applyAction)
            }
            VStack(alignment: .leading, spacing: 6) {
                statusLabel(title: title, text: text, color: color, isRunning: isRunning)
                jobActions(activity, applyAction: applyAction)
            }
        }
        .font(.caption)
        .padding(.horizontal, showsHistory ? 0 : 16)
        .padding(.vertical, 8)
    }

    private func statusLabel(title: String, text: String, color: Color, isRunning: Bool) -> some View {
        HStack(spacing: 8) {
            if isRunning { ProgressView().controlSize(.small) }
            Text("\(title) · \(text)")
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func jobActions(_ activity: JobActivityItem?,
                            applyAction: @escaping (JobActivityAction) async -> Void) -> some View {
        if let activity, !activity.availableActions.isEmpty {
            HStack(spacing: 8) {
                ForEach(activity.availableActions, id: \.self) { action in
                    Button(reviewJobActionTitle(action), role: action == .cancel ? .destructive : nil) {
                        Task { await applyAction(action) }
                    }
                    .disabled(model.isApplyingJobActivityAction(activity.id))
                    .persistentHelp(reviewJobActionHelp(action))
                }
            }
            .controlSize(.small)
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
            "扫描当前来源，并保留全部高于门槛的样本匹配模型建议。"
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
            "无可用样本匹配模型，请先重建。"
        case .serviceUnavailable:
            model.usesAppPersonalSampleSuggestionsPath
                ? "本机模型不可用，请在设置中检查模型。"
                : "本地服务不可用。"
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
    private var showsGenerationControls: Bool { model.expandedReviewTagIDs.contains(overview.id) }
    private func toggleExpanded() {
        if showsGenerationControls { model.expandedReviewTagIDs.remove(overview.id) }
        else { model.expandedReviewTagIDs.insert(overview.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(overview.displayName)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)

                }
                Spacer(minLength: 0)
                if overview.pendingSuggestionCount > 0 {
                    Text("\(overview.pendingSuggestionCount)")
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.tint)
                        .accessibilityLabel("\(overview.pendingSuggestionCount) 条待审")
                }
            }
            HStack(spacing: 10) {
                Button(action: toggleExpanded) {
                    Label("门槛", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .foregroundStyle(showsGenerationControls ? Color.accentColor : .secondary)
                .accessibilityLabel("\(overview.displayName)，\(showsGenerationControls ? "收起门槛" : "展开门槛")")
                .accessibilityValue(showsGenerationControls ? "已展开" : "已收起")
                Spacer(minLength: 0)
                if overview.canReview {
                    Button("审核") { onOpenQueue(overview.id, overview.displayName) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("审核\(overview.displayName)的\(overview.pendingSuggestionCount)条建议")
                }
            }
            .controlSize(.regular)

            ReviewTagGenerateActions(model: model, overview: overview)

            if showsGenerationControls {
                Divider()
                if overview.pendingSuggestionCount > 0 {
                    ReviewOriginCountBadges(counts: overview.pendingSuggestionCounts)
                }
                TagSuggestionThresholdControls(
                    model: model, tagID: overview.id, displayName: overview.displayName,
                    rejectedSampleCount: overview.rejectedSampleCount
                )
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReviewWorkspacePalette.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(overview.canReview ? Color.accentColor.opacity(0.3) : ReviewWorkspacePalette.separator.opacity(0.35))
        }
        .shadow(color: .black.opacity(0.025), radius: 8, y: 3)
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

    var body: some View {
        HStack(spacing: 6) {
            originBadge("学习识别", count: counts.personalAdamW)
            originBadge("样本匹配模型", count: counts.personalModel)
            originBadge("正反对比", count: counts.featurePrint)
            originBadge("标准模型", count: counts.standardModel)
        }
    }

    @ViewBuilder
    private func originBadge(_ title: String, count: Int) -> some View {
        if count > 0 {
            Text("\(title) \(count)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.1), in: Capsule())
                .accessibilityLabel("\(title)来源 \(count) 条待审建议")
        }
    }
}

private struct ReviewTagGenerateActions: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let overview: SuggestionTagOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            generateButton(
                title: "按样本匹配", icon: "brain.head.profile", method: .personalModel,
                mode: overview.canUpdate ? .update : .generate
            )
            generateButton(
                title: "用模型识别", icon: "brain.head.profile.fill", method: .personalAdamW,
                mode: overview.canUpdate ? .update : .generate
            )
            generateButton(
                title: "正反样本对比（可选）",
                icon: "wand.and.stars", method: .featureKnn,
                mode: overview.canUpdate ? .update : .generate
            )

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
                        .controlSize(.regular)
                        .persistentHelp("暂停这个标签的建议生成任务，并保存当前进度。")
                    }
                    if overview.canResume {
                        Button {
                            Task { await model.resumeSuggestionJob(jobID) }
                        } label: {
                            Label("继续", systemImage: "play.fill")
                        }
                        .controlSize(.regular)
                        .persistentHelp("从保存的进度继续这个标签的建议生成任务。")
                    }
                    if overview.canCancel {
                        Button(role: .destructive) {
                            Task { await model.cancelSuggestionJob(jobID) }
                        } label: {
                            Label("取消", systemImage: "xmark")
                        }
                        .controlSize(.regular)
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
        mode: PersonalizationReviewEnqueueMode
    ) -> some View {
        let reason = model.reviewGenerationDisabledReason(for: overview, method: method)
        let explanation: String = switch method {
        case .featureKnn: "可选方法：对比已确认和已拒绝的照片，寻找相似照片。此方法需要双方各至少 2 张；不影响另外两种方法。"
        case .personalModel: "根据已确认照片归纳出的标签样本，寻找匹配照片。"
        case .personalAdamW: "使用已训练的分类模型，识别可能属于这个标签的照片。"
        }
        let help = reason ?? "\(explanation) 选择照片来源后，结果进入待审核列表。"
        return HStack(spacing: 0) {
            Button {
                model.requestEnqueueSuggestions(
                    tagID: overview.id, displayName: overview.displayName,
                    mode: mode, method: method
                )
            } label: {
                Label(title, systemImage: icon)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(reason != nil)
            .accessibilityLabel("\(overview.displayName)：\(title)")
            .accessibilityHint(help)
        }
        .contentShape(Rectangle())
        .persistentHelp(help)
        .controlSize(.regular)
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


enum TagSuggestionThresholdEditorPolicy {
    static func initialDraft(
        effectiveMinScore: Double,
        reference _: SuggestionThresholdReference?
    ) -> Double {
        // References are presentation-only until the user explicitly chooses “采用”.
        return effectiveMinScore
    }

    static func shouldPersist(draft: Double, effectiveMinScore: Double) -> Bool {
        draft.isFinite && abs(draft - effectiveMinScore) >= 0.000_001
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
                    HStack(spacing: 8) {
                        Text(SuggestionScoreThresholdMethodPresentation.displayName(method))
                            .font(.caption)
                            .frame(width: 72, alignment: .leading)
                            .lineLimit(1)
                        TextField(
                            "",
                            text: textBinding(for: method),
                            prompt: Text("0.00")
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.caption2.monospacedDigit())
                        .frame(width: 72)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedMethodRaw, equals: method.rawValue)
                        .onSubmit { commitText(for: method) }
                        Stepper(
                            "",
                            value: stepperBinding(for: method),
                            step: 0.05
                        )
                        .labelsHidden()
                        .controlSize(.regular)
                        .persistentHelp("以 0.05 为步长调整这条建议轨道的最低分数。")
                        Button("刷新") {
                            commitText(for: method)
                            model.prunePendingSuggestionsBelowThreshold(
                                tagID: tagID,
                                displayName: displayName,
                                method: method
                            )
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .persistentHelp("按当前门槛移除分数过低的待审建议；不会重新扫描图库。")
                    }
                    if let reference = references[method] {
                        HStack(spacing: 4) {
                            Text(referenceLabel(reference))
                                .foregroundStyle(.secondary)
                            Button("采用") {
                                apply(method: method, minScore: reference.minScore)
                            }
                            .buttonStyle(.bordered)
                            .persistentHelp("采用根据近期样本计算出的参考分数，作为这条建议轨道的最低门槛。")
                        }
                        .font(.caption)
                    }
                    HStack(spacing: 4) {
                        if model.suggestionThresholdOverride(tagID: tagID, method: method) == nil {
                            Text("继承全局默认")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("使用标签覆盖")
                                .foregroundStyle(.secondary)
                            Button("恢复继承") {
                                model.clearSuggestionThresholdOverride(
                                    tagID: tagID,
                                    method: method
                                )
                                syncDraft(for: method)
                            }
                            .buttonStyle(.bordered)
                            .persistentHelp("清除这个标签的覆盖值，重新继承全局默认门槛。")
                        }
                    }
                    .font(.caption)
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
        let current = model.effectiveSuggestionMinScore(tagID: tagID, method: method)
        guard TagSuggestionThresholdEditorPolicy.shouldPersist(
            draft: value,
            effectiveMinScore: current
        ) else {
            drafts[method] = current
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
            syncDraft(for: method)
        }
    }

    private func syncDraft(for method: SuggestionScoreThresholdMethod) {
        let value = TagSuggestionThresholdEditorPolicy.initialDraft(
            effectiveMinScore: model.effectiveSuggestionMinScore(tagID: tagID, method: method),
            reference: references[method]
        )
        drafts[method] = value
        guard focusedMethodRaw != method.rawValue else { return }
        draftTexts[method] = String(format: "%.2f", value)
    }

    private func reloadThresholdDrafts() async {
        let loaded = await model.suggestionThresholdReferences(tagID: tagID)
        references = loaded
        for method in SuggestionScoreThresholdMethod.allCases {
            syncDraft(for: method)
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
            "为“\(pending.displayName)”生成正反对比建议"
        case (.featureKnn, .update):
            "更新“\(pending.displayName)”正反对比建议"
        case (.personalModel, _):
            "用样本匹配模型生成“\(pending.displayName)”建议"
        case (.personalAdamW, _):
            "用学习识别模型生成“\(pending.displayName)”建议"
        }
    }

    private var message: String {
        let thresholdText = String(format: "%.2f", pending.effectiveMinScore)
        let mediaName = pending.mediaKind.displayName
        switch pending.method {
        case .featureKnn:
            switch pending.mode {
            case .generate:
                return "此可选方法需要至少 2 张确认、2 张拒绝样本。将对比正反样本，检查所选来源中已入库的\(mediaName)，保留全部分数高于 \(thresholdText) 的待审核建议。训练样本仍来自全部来源；人工标签不会丢失。"
            case .update:
                return "将用最新确认/拒绝样本重新扫描所选来源，保留全部分数高于 \(thresholdText) 的建议；人工标签不会改变。"
            }
        case .personalModel:
            return "将用当前样本匹配模型扫描所选来源，保留全部分数高于 \(thresholdText) 的“\(pending.displayName)”待审核建议。需要该标签已在样本匹配模型中；不要求拒绝样本。人工标签不会丢失。"
        case .personalAdamW:
            return "将用当前学习识别模型扫描所选来源，保留全部分数高于 \(thresholdText) 的“\(pending.displayName)”待审核建议。需要该标签已在学习识别模型中；不要求拒绝样本。人工标签不会丢失。"
        }
    }
}

struct ReviewDecisionBar: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let displayName: String

    private var selectionLabel: some View {
        Text("已选 \(model.selectedAssetIDs.count) 张").font(.callout.monospacedDigit())
    }

    private var undoButton: some View {
        Button("撤销", systemImage: "arrow.uturn.backward") {
            Task { await model.undoLastReviewMutation() }
        }.disabled(!model.canUndoReviewMutation || model.isApplyingReviewDecision)
    }

    private var decisionButtons: some View {
        HStack(spacing: 10) {
            Button("属于 (P)", systemImage: "checkmark.circle") {
                Task { await model.applyReviewDecision(action: .accept) }
            }
            Button("不属于 (X)", systemImage: "xmark.circle") {
                Task { await model.applyReviewDecision(action: .reject) }
            }
            Button("跳过 (U)", systemImage: "arrow.right.circle") {
                Task { await model.deferReviewSelection() }
            }
        }
        .disabled(model.selectedAssetIDs.isEmpty || model.isApplyingReviewDecision || model.isLoadingReviewQueue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    selectionLabel
                    decisionButtons
                    Spacer(minLength: 0)
                    undoButton
                }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) {
                    HStack { selectionLabel; Spacer(); undoButton }
                    decisionButtons
                }
            }
            if let feedback = model.reviewFeedback {
                Text(feedback).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("审核“\(displayName)” · Space 查看大图，跳过不记录决定。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(12)
        .background(.bar)
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
                Picker("查看方式", selection: Binding(
                    get: { model.reviewGroupsPhotos }, set: { model.setReviewGroupsPhotos($0) }
                )) {
                    Text("按照片").tag(true)
                    Text("按模型").tag(false)
                }
                .frame(width: 130)
                ReviewSourceFilterMenu(model: model)
                if !model.reviewQueueItems.isEmpty {
                    Text("已载入 \(Set(model.reviewQueueItems.map(\.assetID)).count) 张 · \(model.reviewQueueItems.count) 条建议")
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
            if let summary = model.tagFilterSummaryText() {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.secondary)
                    Text("标签筛选：\(summary)")
                        .font(.callout)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if model.selectedTagFilterIDs.count > 1 {
                        Picker("标签关系", selection: Binding(
                            get: { model.tagMatchMode },
                            set: { mode in Task { await model.setTagMatchMode(mode) } }
                        )) {
                            Text("或").tag(TagMatchMode.any)
                            Text("且").tag(TagMatchMode.all)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 100)
                    }
                    Button("清除") { Task { await model.clearTagFilters() } }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
                Divider()
            }
            if let error = model.reviewQueueError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Button("重试") {
                        Task {
                            if model.reviewNextCursor != nil { await model.loadNextReviewQueuePage(tagID: tagID) }
                            else { await model.loadReviewQueueFirstPage(tagID: tagID) }
                        }
                    }
                }.padding(12)
            }
            if model.isLoadingReviewQueue && model.reviewQueueItems.isEmpty {
                ProgressView("正在载入建议…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.reviewQueueItems.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "sparkles")
                } description: {
                    Text(emptyDescription)
                } actions: {
                    Button("返回建议总览") { Task { await model.enterReviewOverview() } }
                    ReviewSourceFilterMenu(model: model)
                }
            } else {
                reviewGrid
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ReviewDecisionBar(model: model, displayName: displayName)
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
            let originsByAsset = Dictionary(grouping: model.reviewQueueItems, by: \.assetID)
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
                            ForEach(model.displayedReviewQueueItems) { item in
                                ReviewThumbnailView(
                                    state: ReviewThumbnailPresentationState(
                                        item: item,
                                        origins: model.reviewGroupsPhotos
                                            ? (originsByAsset[item.assetID] ?? [item])
                                            : [item],
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
                                    if item.id == model.displayedReviewQueueItems.last?.id,
                                       model.reviewQueueError == nil {
                                        await model.loadNextReviewQueuePage(tagID: tagID)
                                    }
                                }
                            }
                        }
                        .padding(LibraryGridLayout.horizontalPadding)
                    }
                    if model.reviewNextCursor != nil {
                        Button("载入更多建议") {
                            Task { await model.loadNextReviewQueuePage(tagID: tagID) }
                        }
                        .padding(12)
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
                .onChange(of: model.reviewRestoreAnchorID) { _, itemID in
                    if let itemID { scrollProxy.scrollTo(itemID, anchor: .center) }
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
        if model.reviewQueueError != nil { return "建议读取失败" }
        if model.resolvedReviewSourceFilter?.isEmpty == true { return "尚未选择来源" }
        if model.hasActiveTagFilters { return "当前标签筛选没有待审建议" }
        guard let overview = model.suggestionOverviews.first(where: { $0.id == tagID }) else {
            return "暂无建议"
        }
        switch overview.taskStatus {
        case .notReady: return "样本不足"
        case .waiting, .running: return "正在生成建议"
        case .completed: return overview.pendingSuggestionCount == 0 ? "当前没有待审建议" : "建议尚未载入"
        case .terminalFailure: return "任务失败"
        default: return "暂无建议"
        }
    }

    private var emptyDescription: String {
        if model.reviewQueueError != nil { return "请重试载入；读取失败不代表已经审核完成。" }
        if model.resolvedReviewSourceFilter?.isEmpty == true { return "选择至少一个来源以查看建议。" }
        if model.hasActiveTagFilters { return "可在左侧调整标签条件，或清除上方筛选。" }
        guard let overview = model.suggestionOverviews.first(where: { $0.id == tagID }) else {
            return "可调整来源范围，或返回总览生成建议。"
        }
        switch overview.taskStatus {
        case .notReady: return "还需确认 \(overview.missingPositiveCount) 张属于这个标签的照片。样本匹配和模型识别不要求拒绝样本。"
        case .waiting, .running: return "新建议会随分析进度出现，也可返回总览查看任务。"
        case .paused: return "建议生成已暂停，可返回总览继续任务。"
        case .terminalFailure, .retryableFailure: return "生成任务未完成，可返回总览检查并重试。"
        case .ready: return "可返回总览使用按样本匹配或用模型识别生成建议；无需补充拒绝样本。模型未准备好时，请先到训练工程更新对应模型。"
        default: return "当前范围没有待审建议，可返回总览继续审核其他标签或更新建议。"
        }
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
        case .featurePrint: "正反对比"
        case .standardModel: "标准模型"
        case .personalModel: "样本匹配模型"
        case .personalAdamW: "学习识别"
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
    var origins: [ReviewQueueItemProjection] = []
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
    @State private var showsOrigins = false

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
            .overlay(alignment: .topLeading) {
            if state.origins.count > 1 {
                Button("\(state.origins.count) 个模型", systemImage: "square.stack") { showsOrigins.toggle() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(6)
                    .popover(isPresented: $showsOrigins) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("已载入的模型建议").font(.headline)
                            ForEach(state.origins) { origin in
                                Text("\(origin.suggestionOrigin.reviewDisplayName) · \(String(format: "%.2f", origin.score))")
                            }
                            Text("分数不可跨模型比较；审核会处理当前标签下这张照片的全部建议。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(16).frame(maxWidth: 340)
                    }
            }
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
                Text("当前目录没有可用的样本匹配模型。")
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
            "使用你的样本匹配模型分析当前\(model.selectedMediaKind.displayName)，并显示建议标签。"
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
