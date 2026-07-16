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
    }

    private var reviewGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132, maximum: 220), spacing: 8)],
                spacing: 8
            ) {
                ForEach(model.reviewQueueItems) { item in
                    ReviewThumbnailView(
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
                        await model.loadMoreReviewQueueIfNeeded(currentAssetID: item.assetID, tagID: tagID)
                    }
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { contentFocused = true }
    }

    private func handleReviewKey(_ action: LibraryTagDecisionAction) -> KeyPress.Result {
        guard contentFocused else { return .ignored }
        Task { await model.applyReviewDecision(action: action) }
        return .handled
    }

    private func handleReviewDefer() -> KeyPress.Result {
        guard contentFocused else { return .ignored }
        model.deferReviewSelection()
        return .handled
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
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
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
        }
    }
}