import SwiftUI

enum ReviewWorkspaceMode: Equatable {
    case overview
    case tagQueue(tagID: UUID, displayName: String)
}

struct ReviewOverviewView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let onOpenQueue: (UUID, String) -> Void
    let onBack: () -> Void

    private var showsLocalModelPanel: Bool {
        model.supportsPersonalLibrarySuggestions || model.supportsStandardLibrarySuggestions
    }

    var body: some View {
        VStack(spacing: 0) {
            ReviewOverviewHeader(model: model, onBack: onBack)
            Divider()
            if model.suggestionOverviews.isEmpty, !showsLocalModelPanel {
                ContentUnavailableView {
                    Label("暂无待审核标签", systemImage: "sparkles")
                } description: {
                    Text("先在图库中为照片打标签并积累确认/拒绝样本，再回来生成建议。")
                } actions: {
                    Button("返回图库", action: onBack)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    if showsLocalModelPanel {
                        ReviewLocalModelPanel(model: model)
                            .frame(minWidth: 248, idealWidth: 288, maxWidth: 320)
                    }
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(
                                    .adaptive(minimum: 320, maximum: 460),
                                    spacing: 12,
                                    alignment: .top
                                ),
                            ],
                            alignment: .leading,
                            spacing: 12
                        ) {
                            ForEach(model.suggestionOverviews) { overview in
                                ReviewTagOverviewCard(
                                    model: model,
                                    overview: overview,
                                    onOpenQueue: onOpenQueue
                                )
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
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

private struct ReviewOverviewHeader: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("返回图库", systemImage: "photo.on.rectangle", action: onBack)

            Divider()
                .frame(height: 18)

            ReviewSourceFilterMenu(model: model)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Text("每标签上限")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(
                    value: Binding(
                        get: { model.maxPendingSuggestionsPerTag },
                        set: { model.setMaxPendingSuggestionsPerTag($0) }
                    ),
                    in: PendingSuggestionGenerationLimits.minCount
                        ... PendingSuggestionGenerationLimits.maxCount,
                    step: 50
                ) {
                    Text("\(model.maxPendingSuggestionsPerTag)")
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 40, alignment: .trailing)
                }
                .help("特征向量、个人模型、超级个人模型与抽检路径均按此上限保留分数最高的待审核建议。")
            }

            if model.pendingSuggestionTotal > 0 {
                Text("\(model.pendingSuggestionTotal) 条待审")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.secondary.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
        .help("控制建议生成与待审列表的扫描范围；与侧栏「浏览某一来源」相互独立。")
    }
}

private struct ReviewLocalModelPanel: View {
    @ObservedObject var model: LibraryWorkspaceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("本地模型", systemImage: "cpu")
                    .font(.headline)

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
                    .help("只检查本机回环服务，不会启动服务或下载模型")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

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
                        help: "按顶部来源筛选扫描；仅分析当前可本地读取的预览；iCloud 云端照片会跳过",
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
            .padding(12)
        }
    }

    private var personalLibraryActionTitle: String {
        if model.isGeneratingPersonalLibrarySuggestions {
            return model.usesAppPersonalSampleSuggestionsPath ? "抽检中…" : "扫描中…"
        }
        return model.usesAppPersonalSampleSuggestionsPath
            ? "抽 \(model.maxPendingSuggestionsPerTag) 张"
            : "扫描全库"
    }

    private var personalLibraryActionHelp: String {
        model.usesAppPersonalSampleSuggestionsPath
            ? "有多选时用选中照片；无多选时从库中抽样。仅用本机预览；云端未下载照片会跳过"
            : "按顶部来源筛选扫描；仅分析当前可本地读取的预览；iCloud 云端照片会跳过"
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
            .help(help)
            if let jobActivity, !jobActivity.availableActions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(jobActivity.availableActions, id: \.self) { jobAction in
                        Button(reviewJobActionTitle(jobAction), role: jobAction == .cancel ? .destructive : nil) {
                            Task { await applyAction(jobAction) }
                        }
                        .font(.caption)
                        .disabled(model.isApplyingJobActivityAction(jobActivity.id))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
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
            "服务未运行；现有照片、标签和 Feature Print 不受影响。"
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
            model.usesAppPersonalSampleSuggestionsPath
                ? "抽检最多 \(model.maxPendingSuggestionsPerTag) 张加入审核队列。"
                : "把当前个人模型建议加入审核队列。"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(overview.displayName)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if overview.pendingSuggestionCount > 0 {
                    Text("\(overview.pendingSuggestionCount)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }

            HStack(spacing: 12) {
                Text("已确认 \(overview.acceptedSampleCount)")
                Text("已拒绝 \(overview.rejectedSampleCount)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if overview.pendingSuggestionCount > 0 {
                ReviewOriginCountBadges(
                    counts: overview.pendingSuggestionCounts,
                    onOpenQueue: { onOpenQueue(overview.id, overview.displayName) }
                )
            }

            Text(reviewTagStatusText(overview))
                .font(.caption)
                .foregroundStyle(.secondary)

            TagSuggestionThresholdControls(
                model: model,
                tagID: overview.id,
                displayName: overview.displayName,
                rejectedSampleCount: overview.rejectedSampleCount
            )

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

            Divider()

            if overview.canReview {
                Button {
                    onOpenQueue(overview.id, overview.displayName)
                } label: {
                    Label("审核建议", systemImage: "checklist")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

            ReviewTagGenerateActions(model: model, overview: overview)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }
}

private struct ReviewOriginCountBadges: View {
    let counts: SuggestionOriginCounts
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
            .help("打开待审核队列")
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
                        title: "特征向量 Top \(model.maxPendingSuggestionsPerTag)",
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
                        title: "个人模型 Top \(model.maxPendingSuggestionsPerTag)",
                        icon: "brain.head.profile",
                        method: .personalModel,
                        mode: overview.canUpdate ? .update : .generate,
                        isBusy: model.isGeneratingAppPersonalTagLibrarySuggestions
                    )
                    .disabled(model.isGeneratingAppPersonalTagLibrarySuggestions)
                }
                if model.canGenerateAppPersonalAdamWTagLibrarySuggestions(for: overview) {
                    generateButton(
                        title: "超级个人 Top \(model.maxPendingSuggestionsPerTag)",
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
                    }
                    if overview.canResume {
                        Button {
                            Task { await model.resumeSuggestionJob(jobID) }
                        } label: {
                            Label("继续", systemImage: "play.fill")
                        }
                        .controlSize(.small)
                    }
                    if overview.canCancel {
                        Button(role: .destructive) {
                            Task { await model.cancelSuggestionJob(jobID) }
                        } label: {
                            Label("取消", systemImage: "xmark")
                        }
                        .controlSize(.small)
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


struct TagSuggestionThresholdControls: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let tagID: UUID
    let displayName: String
    let rejectedSampleCount: Int
    @State private var references:
        [SuggestionScoreThresholdMethod: SuggestionThresholdReference] = [:]

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
                        Text(String(format: "%.2f", model.effectiveSuggestionMinScore(tagID: tagID, method: method)))
                            .font(.caption2.monospacedDigit())
                            .frame(width: 36, alignment: .trailing)
                        Stepper(
                            "",
                            value: Binding(
                                get: {
                                    model.effectiveSuggestionMinScore(tagID: tagID, method: method)
                                },
                                set: { newValue in
                                    model.setSuggestionThresholdOverride(
                                        tagID: tagID,
                                        method: method,
                                        minScore: newValue
                                    )
                                }
                            ),
                            step: 0.05
                        )
                        .labelsHidden()
                        .controlSize(.mini)
                        Button("刷新") {
                            model.prunePendingSuggestionsBelowThreshold(
                                tagID: tagID,
                                displayName: displayName,
                                method: method
                            )
                        }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                        .help("按当前生效门槛删除本轨低于门槛的 pending，不重跑全库扫描")
                    }
                    if let reference = references[method] {
                        HStack(spacing: 4) {
                            Text(
                                "参考 "
                                    + String(format: "%.2f", reference.minScore)
                                    + " · "
                                    + String(reference.rejectedSampleCount)
                                    + " 拒绝"
                            )
                            .foregroundStyle(.secondary)
                            Button("采用") {
                                model.setSuggestionThresholdOverride(
                                    tagID: tagID,
                                    method: method,
                                    minScore: reference.minScore
                                )
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.caption2)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .task(id: "\(tagID.uuidString.lowercased()):\(rejectedSampleCount)") {
            references = await model.suggestionThresholdReferences(tagID: tagID)
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
                Button("开始") {
                    let captured = model.pendingSuggestionConfirmation ?? pending
                    Task { _ = await model.confirmPendingSuggestionEnqueue(captured) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!(model.pendingSuggestionConfirmation?.canStart ?? pending.canStart))
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
        let limitText = String(pending.maxPendingSuggestionsPerTag)
        switch pending.method {
        case .featureKnn:
            switch pending.mode {
            case .generate:
                return "将用特征向量近邻检查所选来源中已入库的照片，只保留分数高于 \(thresholdText) 且最高的 \(limitText) 条待审核建议。训练样本仍来自全部来源；人工标签不会丢失。"
            case .update:
                return "将用最新确认/拒绝样本重新扫描所选来源，只保留分数高于 \(thresholdText) 且最高的 \(limitText) 条；人工标签不会改变。"
            }
        case .personalModel:
            return "将用当前人脑质心个人模型扫描所选来源，只保留分数高于 \(thresholdText) 且最高的 \(limitText) 条“\(pending.displayName)”待审核建议。需要该标签已在人脑模型中；不要求拒绝样本。人工标签不会丢失。"
        case .personalAdamW:
            return "将用当前超级人脑 AdamW 个人模型扫描所选来源，只保留分数高于 \(thresholdText) 且最高的 \(limitText) 条“\(pending.displayName)”待审核建议。需要该标签已在超级模型中；不要求拒绝样本。人工标签不会丢失。"
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
            HStack(spacing: 8) {
                ReviewSourceFilterMenu(model: model)
                if let overview = model.suggestionOverviews.first(where: { $0.id == tagID }) {
                    Text(statusHeader(overview))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !model.reviewQueueItems.isEmpty {
                    LibraryGridDensityPicker(
                        selection: Binding(
                            get: { model.gridDensity },
                            set: { model.setGridDensity($0) }
                        ),
                        help: "调整待审核建议网格缩略图大小"
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
        .onKeyPress("p") { handleReviewKey(.accept) }
        .onKeyPress("x") { handleReviewKey(.reject) }
        .onKeyPress("u") { handleReviewDefer() }
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
                                    item: item,
                                    model: model,
                                    isSelected: model.selectedReviewItemID == item.id
                                        || (
                                            model.selectedReviewItemID == nil
                                                && model.selectedAssetIDs.contains(item.assetID)
                                        ),
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
                .onChange(of: gridScrollTargetID) { _, itemID in
                    guard let itemID else { return }
                    scrollProxy.scrollTo(itemID, anchor: .center)
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

private struct ReviewThumbnailView: View {
    let item: ReviewQueueItemProjection
    @ObservedObject var model: LibraryWorkspaceModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    @State private var image: NSImage?
    @State private var isCloudOnly = false

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
            "\(isSelected ? "已选择" : "未选择")，\(item.suggestionOrigin.reviewDisplayName)建议，分数 \(String(format: "%.2f", item.score))"
        )
        .accessibilityHint("选择待审核照片；双击可预览，也可按 P、X 或 U 处理")
        .help(LibraryAssetDetailText.reviewHoverText(item))
        .accessibilityAction {
            onSelect()
        }
        .accessibilityAction(named: "打开单图预览") {
            onOpen()
        }
        .task(id: item.assetID) {
            await loadReviewThumbnailWhileVisible()
        }
    }

    private func loadReviewThumbnailWhileVisible() async {
        isCloudOnly = false
        guard item.availability == .available else {
            image = nil
            return
        }

        if let cached = model.cachedThumbnailData(for: item.assetID),
           let cachedImage = LibraryGridThumbnailImageFactory.image(from: cached)
        {
            image = cachedImage
            return
        }

        var transientAttempts = 0
        while !Task.isCancelled {
            switch await model.loadThumbnailResultWithRetry(assetID: item.assetID) {
            case let .loaded(data):
                guard !Task.isCancelled else { return }
                if let decoded = LibraryGridThumbnailImageFactory.image(from: data) {
                    model.rememberThumbnailData(data, for: item.assetID)
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
        return "photo"
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
