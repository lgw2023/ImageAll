import SwiftUI

enum ReviewWorkspaceMode: Equatable {
    case overview
    case tagQueue(tagID: UUID, displayName: String)
}

struct ReviewOverviewView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let onOpenQueue: (UUID, String) -> Void
    let onBack: () -> Void

    var body: some View {
        List {
            if model.supportsPersonalLibrarySuggestions {
                Section("个人模型") {
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
                                    Text("正在检查本地服务")
                                }
                            } else {
                                Label("刷新服务状态", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(model.localModelServiceHealthState == .checking)
                        .help("只检查本机回环服务，不会启动服务或下载模型")

                        Divider()

                        Text(personalLibraryStatusText)
                            .font(.caption)
                            .foregroundStyle(personalLibraryStatusColor)
                        Button {
                            Task { await model.generatePersonalLibrarySuggestions() }
                        } label: {
                            if model.isGeneratingPersonalLibrarySuggestions {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("正在扫描全库")
                                }
                            } else {
                                Label("用个人模型扫描全库", systemImage: "brain.head.profile")
                            }
                        }
                        .disabled(
                            model.isGeneratingPersonalLibrarySuggestions
                                || model.isRebuildingPersonalModel
                        )
                        .help("仅分析当前可本地读取的预览；iCloud 云端照片会跳过，不会批量下载")
                    }
                    .padding(.vertical, 4)
                }
            }
            ForEach(model.suggestionOverviews) { overview in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(overview.displayName).font(.headline)
                        Spacer()
                        if overview.pendingSuggestionCount > 0 {
                            Text("\(overview.pendingSuggestionCount)")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                    Text("已确认 \(overview.acceptedSampleCount) · 已拒绝 \(overview.rejectedSampleCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(statusText(overview))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if overview.missingPositiveCount > 0 || overview.missingNegativeCount > 0 {
                        Text("还需确认 \(overview.missingPositiveCount) 张、标记不属于 \(overview.missingNegativeCount) 张")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if overview.recommendedPositiveSampleGap > 0
                        || overview.recommendedNegativeSampleGap > 0
                    {
                        Text("样本已可用；建议正反样本各至少 4 张，并尽量覆盖不同内容（当前 \(overview.acceptedSampleCount)/\(overview.rejectedSampleCount)）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        if overview.canGenerate {
                            Button("生成建议") {
                                model.requestEnqueueSuggestions(
                                    tagID: overview.id,
                                    displayName: overview.displayName,
                                    mode: .generate,
                                    sourceCount: model.sources.filter { $0.state == .active }.count
                                )
                            }
                        }
                        if overview.canUpdate {
                            Button("更新建议") {
                                model.requestEnqueueSuggestions(
                                    tagID: overview.id,
                                    displayName: overview.displayName,
                                    mode: .update,
                                    sourceCount: model.sources.filter { $0.state == .active }.count
                                )
                            }
                        }
                        if overview.canReview {
                            Button("审核建议") {
                                onOpenQueue(overview.id, overview.displayName)
                            }
                        }
                        if overview.canPause, let jobID = overview.activeJobID {
                            Button("暂停") { Task { await model.pauseSuggestionJob(jobID) } }
                        }
                        if overview.canResume, let jobID = overview.activeJobID {
                            Button("继续") { Task { await model.resumeSuggestionJob(jobID) } }
                        }
                        if overview.canCancel, let jobID = overview.activeJobID {
                            Button("取消") { Task { await model.cancelSuggestionJob(jobID) } }
                        }
                    }
                    .buttonStyle(.link)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("待审核建议")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("返回图库", action: onBack)
            }
        }
    }

    private var localModelServiceStatusText: String {
        switch model.localModelServiceHealthState {
        case .unchecked:
            "本地模型服务尚未检查。"
        case .checking:
            "正在检查本地模型服务…"
        case let .ready(serviceVersion, provider):
            "服务已就绪 · \(provider.provider) / \(provider.modelID) · v\(serviceVersion)"
        case let .degraded(serviceVersion):
            "服务已连接，但尚未加载模型 · v\(serviceVersion)"
        case .unavailable:
            "本地模型服务未运行；现有照片、标签和 Feature Print 不受影响。"
        }
    }

    private var localModelServiceStatusColor: Color {
        switch model.localModelServiceHealthState {
        case .ready:
            .green
        case .degraded:
            .orange
        case .unavailable:
            .red
        case .unchecked, .checking:
            .secondary
        }
    }

    private var personalLibraryStatusText: String {
        switch model.personalLibrarySuggestionState {
        case .idle:
            "把当前个人 DINO 模型的建议加入现有审核队列。"
        case let .waiting(checked, suggested, skipped):
            "等待扫描 · 已检查 \(checked) 张 · 建议 \(suggested) 条 · 跳过 \(skipped) 张"
        case let .running(checked, suggested, skipped):
            "已检查 \(checked) 张 · 建议 \(suggested) 条 · 跳过 \(skipped) 张"
        case let .paused(checked, suggested, skipped):
            "扫描已暂停 · 已检查 \(checked) 张 · 建议 \(suggested) 条 · 跳过 \(skipped) 张"
        case let .retryableFailure(checked, suggested, skipped):
            "本地服务暂时不可用，任务将重试 · 已检查 \(checked) 张 · 建议 \(suggested) 条 · 跳过 \(skipped) 张"
        case let .completed(checked, suggested, skipped):
            "扫描完成：检查 \(checked) 张，加入 \(suggested) 条建议，跳过 \(skipped) 张。"
        case let .cancelled(checked, suggested, skipped):
            "扫描已取消：检查 \(checked) 张，加入 \(suggested) 条建议，跳过 \(skipped) 张。"
        case .personalUnavailable:
            "当前目录没有可用的个人模型，请先重建个人模型。"
        case .serviceUnavailable:
            "本地模型服务不可用；现有照片、标签和 Feature Print 建议不受影响。"
        case .failed:
            "模型身份或结果未通过校验，personal 建议已安全忽略。"
        }
    }

    private var personalLibraryStatusColor: Color {
        switch model.personalLibrarySuggestionState {
        case .failed, .serviceUnavailable, .retryableFailure:
            .red
        case .personalUnavailable, .paused:
            .orange
        default:
            .secondary
        }
    }

    private func statusText(_ overview: SuggestionTagOverview) -> String {
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
}

struct ReviewQueueContentView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let tagID: UUID
    let displayName: String
    @FocusState.Binding var contentFocused: Bool
    @State private var gridColumnCount = 1
    @State private var gridScrollTargetID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if let overview = model.suggestionOverviews.first(where: { $0.id == tagID }) {
                Text(statusHeader(overview))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
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
        .onKeyPress("p") { handleReviewKey(.accept) }
        .onKeyPress("x") { handleReviewKey(.reject) }
        .onKeyPress("u") { handleReviewDefer() }
        .onKeyPress(.space) {
            guard model.primarySelectedAssetID != nil else { return .ignored }
            model.toggleSinglePhotoView()
            return .handled
        }
        .onKeyPress(
            keys: [.leftArrow, .rightArrow, .upArrow, .downArrow],
            action: handleNavigationKey
        )
    }

    private var reviewGrid: some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(
                                    minimum: LibraryGridDensity.standard.cellWidthRange.lowerBound,
                                    maximum: LibraryGridDensity.standard.cellWidthRange.upperBound
                                ),
                                spacing: LibraryGridLayout.spacing
                            ),
                        ],
                        spacing: LibraryGridLayout.spacing
                    ) {
                        ForEach(model.reviewQueueItems) { item in
                            ReviewThumbnailView(
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
                                await model.loadMoreReviewQueueIfNeeded(
                                    currentAssetID: item.assetID,
                                    tagID: tagID
                                )
                            }
                        }
                    }
                    .padding(LibraryGridLayout.horizontalPadding)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .accessibilityLabel("待审核建议网格")
                .onAppear {
                    updateGridColumnCount(containerWidth: proxy.size.width)
                    contentFocused = true
                    gridScrollTargetID = model.primarySelectedAssetID
                }
                .onChange(of: proxy.size.width) { _, width in
                    updateGridColumnCount(containerWidth: width)
                }
                .onChange(of: gridScrollTargetID) { _, assetID in
                    guard let assetID else { return }
                    scrollProxy.scrollTo(assetID, anchor: .center)
                    gridScrollTargetID = nil
                }
            }
        }
    }

    private func handleReviewKey(_ action: LibraryTagDecisionAction) -> KeyPress.Result {
        guard contentFocused else { return .ignored }
        Task { await model.applyReviewDecision(action: action) }
        return .handled
    }

    private func handleReviewDefer() -> KeyPress.Result {
        guard contentFocused else { return .ignored }
        Task { await model.deferReviewSelection() }
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
            gridScrollTargetID = model.primarySelectedAssetID
        }
        return .handled
    }

    private func updateGridColumnCount(containerWidth: CGFloat) {
        gridColumnCount = LibraryGridLayout.columnCount(
            containerWidth: containerWidth,
            density: .standard
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

private struct ReviewThumbnailView: View {
    let item: ReviewQueueItemProjection
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
                    Image(systemName: "photo")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
                VStack {
                    Spacer()
                    HStack {
                        Text(item.suggestionOrigin == .personalModel ? "个人 DINO" : "Feature Print")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.65), in: Capsule())
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
        .accessibilityLabel(item.fileName ?? "照片")
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(
            "\(isSelected ? "已选择" : "未选择")，\(item.suggestionOrigin == .personalModel ? "个人 DINO 建议" : "Feature Print 建议")"
        )
        .accessibilityHint("选择待审核照片；双击可预览，也可按 P、X 或 U 处理")
        .accessibilityAction {
            onSelect()
        }
        .accessibilityAction(named: "打开单图预览") {
            onOpen()
        }
        .task(id: item.assetID) {
            guard item.availability == .available,
                  let data = await model.thumbnailData(assetID: item.assetID)
            else { return }
            image = NSImage(data: data)
        }
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
                        Text(
                            suggestion.suggestionOrigin == .personalModel
                                ? "个人 DINO"
                                : "Feature Print"
                        )
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
                        Button("不属于") {
                            Task {
                                await model.applyInspectorSuggestion(tagID: suggestion.tagID, action: .reject)
                            }
                        }
                    }
                    .font(.caption)
                }
                if model.assetPendingSuggestions.count > 5, !expanded {
                    Button("另外 \(model.assetPendingSuggestions.count - 5) 条建议") {
                        expanded = true
                    }
                    .font(.caption)
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
                    Text("正在分析当前照片…")
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
                                .help("标记为不合适")
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
                                .help("确认并添加标签")
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
                Text("请先在上方获取这张照片的 iCloud 预览。")
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
                Text("本地模型服务当前不可用，照片与人工标签不受影响。")
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
    }

    private func personalRequestButton(_ title: String) -> some View {
        Button(title) {
            Task { await model.requestPersonalModelSuggestions() }
        }
        .buttonStyle(.bordered)
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
