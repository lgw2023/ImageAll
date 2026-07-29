import Foundation
import SwiftUI

struct TrainingWorkspaceView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let onReturnToLibrary: () -> Void
    @State private var isPresentingTrainingSetup = false
    @State private var pendingLaunchRequest: TrainingWorkspaceLaunchRequest?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let activity = model.trainingWorkspaceActivity {
                activityBanner(activity)
                Divider()
            }
            slotStrip
            Divider()
            HSplitView {
                runList
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                detail
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("训练工程")
        .accessibilityLabel("训练工程工作台")
        .task {
            await model.refreshTrainingWorkspace(presentation: .automatic)
        }
        .sheet(
            isPresented: $isPresentingTrainingSetup,
            onDismiss: performPendingLaunch
        ) {
            TrainingWorkspaceLaunchSheet(model: model) { request in
                pendingLaunchRequest = request
                isPresentingTrainingSetup = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                isPresentingTrainingSetup = true
            } label: {
                Label("新建训练任务…", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                model.isRebuildingPersonalModel
                    || model.isRebuildingPersonalAdamWModel
                    || model.isGeneratingPersonalLibrarySuggestions
            )
            .persistentHelp("打开训练设置，选择目标标签、训练方法和照片范围，再确认创建任务。")

            Button {
                Task { await model.refreshTrainingWorkspace() }
            } label: {
                if model.isRefreshingTrainingWorkspace {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isRefreshingTrainingWorkspace)
            .persistentHelp("重新读取训练记录、模型槽位和当前任务进度；不会启动新的训练。")

            Spacer()
            Button("返回图库", systemImage: "photo.on.rectangle") {
                onReturnToLibrary()
            }
            .persistentHelp("退出训练工作台并返回照片图库；正在运行的后台任务不会被取消。")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func performPendingLaunch() {
        guard let request = pendingLaunchRequest else { return }
        pendingLaunchRequest = nil
        switch request {
        case let .feature(tagID, displayName, mode):
            Task {
                await model.setTrainingRunMethodFilter(nil)
                model.requestEnqueueSuggestions(
                    tagID: tagID,
                    displayName: displayName,
                    mode: mode,
                    method: .featureKnn
                )
            }
        case let .personal(method, tagIDs, assetIDs):
            Task {
                await model.setTrainingRunMethodFilter(nil)
                switch method {
                case .personalCentroid:
                    await model.rebuildPersonalModel(
                        tagIDs: tagIDs,
                        assetIDs: assetIDs
                    )
                case .personalAdamW:
                    await model.rebuildPersonalAdamWModel(
                        tagIDs: tagIDs,
                        assetIDs: assetIDs
                    )
                case .featureKnn:
                    break
                }
            }
        }
    }

    private func activityBanner(_ activity: TrainingWorkspaceActivity) -> some View {
        HStack(alignment: .top, spacing: 12) {
            switch activity.phase {
            case let .preparingEmbeddings(completed, total):
                ProgressView(
                    value: Double(completed),
                    total: Double(max(total, 1))
                )
                .progressViewStyle(.circular)
                .controlSize(.small)
            case .preparingSamples, .trainingAndPublishing:
                ProgressView()
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(TrainingWorkspaceActivityPresentation.title(activity))
                    .font(.subheadline.weight(.semibold))
                Text(TrainingWorkspaceActivityPresentation.detail(activity))
                    .font(.caption)
                Text(TrainingWorkspaceActivityPresentation.phase(activity))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("训练记录创建后会自动出现在下方，无需手动刷新。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前训练状态")
    }

    private var slotStrip: some View {
        HStack(spacing: 10) {
            ForEach(model.trainingSlots) { slot in
                let isTraining = model.trainingWorkspaceActivity?.method == slot.method
                let presentation = TrainingWorkspaceMethodPresentation(method: slot.method)
                VStack(alignment: .leading, spacing: 4) {
                    Label(presentation.shortTitle, systemImage: presentation.systemImage)
                        .font(.subheadline.weight(.semibold))
                    Text(presentation.technicalName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Label(
                        isTraining ? "训练中" : (slot.isPublished ? "已就绪" : "尚未训练"),
                        systemImage: isTraining
                            ? "gearshape.2"
                            : slot.isPublished
                            ? "checkmark.circle.fill"
                            : "circle.dashed"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        isTraining ? Color.blue : (slot.isPublished ? .green : .secondary)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .accessibilityLabel("三种训练产物状态")
    }

    private var runList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("训练记录")
                    .font(.headline)
                Spacer()
                Text("显示")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(
                    "训练记录显示范围",
                    selection: Binding(
                        get: { model.trainingRunMethodFilter },
                        set: { method in
                            Task { await model.setTrainingRunMethodFilter(method) }
                        }
                    )
                ) {
                    Text("全部记录").tag(Optional<TrainingRunMethod>.none)
                    ForEach(TrainingRunMethod.allCases, id: \.self) { method in
                        Text(TrainingWorkspaceMethodPresentation(method: method).shortTitle)
                            .tag(Optional(method))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .persistentHelp("筛选左侧训练记录；只改变显示范围，不会删除或停止任何任务。")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if model.trainingRuns.isEmpty {
                if model.trainingWorkspaceActivity != nil {
                    ContentUnavailableView(
                        "正在创建训练记录",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("样本准备完成后，当前训练会自动显示在这里。")
                    )
                } else {
                    ContentUnavailableView(
                        "暂无训练记录",
                        systemImage: "clock.badge.questionmark",
                        description: Text("从“新建训练任务”开始；失败和取消的记录也会保留。")
                    )
                }
            } else {
                List(
                    model.trainingRuns,
                    selection: Binding(
                        get: { model.selectedTrainingRunID },
                        set: { model.selectTrainingRun($0) }
                    )
                ) { run in
                    TrainingWorkspaceRunRow(run: run)
                        .tag(run.id)
                }
                .listStyle(.sidebar)
                .accessibilityLabel("训练记录列表")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let run = model.selectedTrainingRun {
            let presentation = TrainingWorkspaceMethodPresentation(method: run.method)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(presentation.shortTitle)
                                .font(.title2.weight(.semibold))
                            Text(presentation.technicalName)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(run.id.uuidString.lowercased())
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(run.state.trainingWorkspaceDisplayName)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                run.state.trainingWorkspaceTint.opacity(0.14),
                                in: Capsule()
                            )
                    }
                    TrainingWorkspaceDetailSection("概览") {
                        LabeledContent("任务", value: presentation.shortTitle)
                        LabeledContent("技术方法", value: presentation.technicalName)
                        LabeledContent("状态", value: run.state.trainingWorkspaceDisplayName)
                        LabeledContent(
                            "创建时间",
                            value: TrainingWorkspaceDateFormatter.string(run.createdAtMs)
                        )
                        if let startedAtMs = run.startedAtMs {
                            LabeledContent(
                                "开始时间",
                                value: TrainingWorkspaceDateFormatter.string(startedAtMs)
                            )
                        }
                        if let finishedAtMs = run.finishedAtMs {
                            LabeledContent(
                                "结束时间",
                                value: TrainingWorkspaceDateFormatter.string(finishedAtMs)
                            )
                        }
                        if let jobID = run.jobID {
                            LabeledContent("关联任务", value: jobID.uuidString.lowercased())
                        }
                    }
                    TrainingWorkspaceJSONSection(
                        title: "数据",
                        json: run.sampleSummaryJSON,
                        emptyText: "没有样本摘要"
                    )
                    TrainingWorkspaceJSONSection(
                        title: "配置",
                        json: run.configJSON,
                        emptyText: "没有配置摘要"
                    )
                    TrainingWorkspaceMetricsSection(json: run.metricsJSON)
                    TrainingWorkspaceDetailSection("产物") {
                        LabeledContent("类型", value: run.artifactKind ?? "未发布")
                        LabeledContent(
                            "引用",
                            value: TrainingWorkspaceJSONPresentation.safeArtifactReference(
                                run.artifactRef
                            ) ?? (run.artifactRef == nil ? "无" : "已隐藏不安全引用")
                        )
                        if let artifactSHA256 = run.artifactSHA256 {
                            LabeledContent("SHA-256", value: artifactSHA256)
                        }
                        if let manifest = run.sampleManifestSHA256 {
                            LabeledContent("样本清单 SHA-256", value: manifest)
                        }
                    }
                    TrainingWorkspaceJSONSection(
                        title: "结果",
                        json: run.resultSummaryJSON,
                        emptyText: "没有结果摘要"
                    )
                    if let errorCode = run.errorCode {
                        TrainingWorkspaceDetailSection("错误") {
                            LabeledContent("错误码", value: errorCode)
                        }
                    }
                }
                .padding(20)
            }
            .accessibilityLabel("训练记录详情")
        } else {
            ContentUnavailableView {
                Label("选择一条训练记录", systemImage: "list.bullet.rectangle")
            } description: {
                Text("这里会展示概览、数据、配置、过程、产物和结果。三种建议可以同时进入待审核队列。")
            }
        }
    }
}

private enum TrainingWorkspaceLaunchRequest {
    case feature(
        tagID: UUID,
        displayName: String,
        mode: PersonalizationReviewEnqueueMode
    )
    case personal(
        method: TrainingRunMethod,
        tagIDs: Set<UUID>,
        assetIDs: Set<UUID>
    )
}

private enum TrainingWorkspacePhotoScopeChoice: Hashable {
    case allSources
    case currentSelection
}

private struct TrainingWorkspaceLaunchSheet: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let onLaunch: (TrainingWorkspaceLaunchRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedMethod: TrainingRunMethod
    @State private var selectedFeatureTagID: UUID?
    @State private var selectedPersonalTagIDs: Set<UUID>
    @State private var photoScopeChoice: TrainingWorkspacePhotoScopeChoice = .allSources

    init(
        model: LibraryWorkspaceModel,
        onLaunch: @escaping (TrainingWorkspaceLaunchRequest) -> Void
    ) {
        self.model = model
        self.onLaunch = onLaunch

        let featureOptions = model.suggestionOverviews.filter {
            $0.canGenerate || $0.canUpdate
        }
        let personalOptions = model.suggestionOverviews.filter(\.canGeneratePersonalModel)
        let initialMethod: TrainingRunMethod
        if !featureOptions.isEmpty, !model.activeReviewSources.isEmpty {
            initialMethod = .featureKnn
        } else if model.supportsPersonalModelRebuild, !personalOptions.isEmpty {
            initialMethod = .personalCentroid
        } else if model.supportsPersonalAdamWModelRebuild, !personalOptions.isEmpty {
            initialMethod = .personalAdamW
        } else {
            initialMethod = .featureKnn
        }

        _selectedMethod = State(initialValue: initialMethod)
        _selectedFeatureTagID = State(initialValue: featureOptions.first?.id)
        _selectedPersonalTagIDs = State(
            initialValue: personalOptions.count == 1
                ? Set([personalOptions[0].id])
                : []
        )
    }

    private var featureOptions: [SuggestionTagOverview] {
        model.suggestionOverviews.filter { $0.canGenerate || $0.canUpdate }
    }

    private var personalOptions: [SuggestionTagOverview] {
        model.suggestionOverviews.filter(\.canGeneratePersonalModel)
    }

    private var selectedTagNames: [String] {
        switch selectedMethod {
        case .featureKnn:
            featureOptions
                .filter { $0.id == selectedFeatureTagID }
                .map(\.displayName)
        case .personalCentroid, .personalAdamW:
            personalOptions
                .filter { selectedPersonalTagIDs.contains($0.id) }
                .map(\.displayName)
        }
    }

    private var selectedAssetIDs: Set<UUID> {
        photoScopeChoice == .currentSelection ? model.selectedAssetIDs : []
    }

    private var launchSummary: TrainingWorkspaceLaunchSummary {
        TrainingWorkspaceLaunchSummary(
            method: selectedMethod,
            tagNames: selectedTagNames,
            photoScope: selectedAssetIDs.isEmpty
                ? .allSources
                : .selectedAssets(count: selectedAssetIDs.count)
        )
    }

    private var canLaunch: Bool {
        guard isMethodAvailable(selectedMethod) else { return false }
        switch selectedMethod {
        case .featureKnn:
            return selectedFeatureTagID != nil
        case .personalCentroid, .personalAdamW:
            return !selectedPersonalTagIDs.isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("新建训练任务")
                    .font(.title2.weight(.semibold))
                Text("先选择你想完成的事情。算法名称保留为技术说明，不再作为操作入口。")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 18)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    methodSidebar
                        .padding(20)
                }
                .frame(width: 300)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        configurationPanel
                            .padding(.horizontal, 24)
                            .padding(.top, 24)
                            .padding(.bottom, 16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    confirmationPanel
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Button("取消", role: .cancel) {
                    dismiss()
                }
                .persistentHelp("放弃本次训练设置并关闭窗口，不创建任务。")
                Spacer()
                Button(launchButtonTitle) {
                    launch()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canLaunch)
                .persistentHelp("按当前标签、方法和照片范围创建训练或建议生成任务。")
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 22)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 980, height: 740)
        .accessibilityLabel("新建训练任务")
    }

    private var methodSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("任务类型")
                .font(.headline)
            VStack(spacing: 10) {
                ForEach(TrainingRunMethod.allCases, id: \.self) { method in
                    methodSidebarCard(method)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func methodSidebarCard(_ method: TrainingRunMethod) -> some View {
        let presentation = TrainingWorkspaceMethodPresentation(method: method)
        let isSelected = selectedMethod == method
        let isAvailable = isMethodAvailable(method)
        return Button {
            selectedMethod = method
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: presentation.systemImage)
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(presentation.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Image(
                            systemName: isSelected
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    }
                    Text("技术：\(presentation.technicalName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(presentation.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(
                        isAvailable ? presentation.requirement : unavailableText(method),
                        systemImage: isAvailable
                            ? "checkmark.seal"
                            : "exclamationmark.triangle"
                    )
                    .font(.caption2)
                    .foregroundStyle(isAvailable ? Color.secondary : .orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(12)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.10)
                    : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected
                            ? Color.accentColor
                            : Color.secondary.opacity(0.20),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityLabel(
            "\(presentation.title)，\(presentation.technicalName)"
        )
        .persistentHelp(
            isAvailable
                ? "\(presentation.title)：\(presentation.detail) \(presentation.requirement)"
                : "\(presentation.title) 当前不可用：\(unavailableText(method))"
        )
    }

    private var configurationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("选择标签和照片范围", systemImage: "slider.horizontal.3")
                .font(.headline)
            configuration
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var confirmationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Label("启动前确认", systemImage: "checklist")
                .font(.headline)
            confirmationSummary
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var configuration: some View {
        switch selectedMethod {
        case .featureKnn:
            VStack(alignment: .leading, spacing: 12) {
                Picker("要寻找哪种标签的相似照片？", selection: $selectedFeatureTagID) {
                    ForEach(featureOptions) { overview in
                        Text(
                            "\(overview.displayName)（属于 \(overview.acceptedSampleCount) / 不属于 \(overview.rejectedSampleCount)）"
                        )
                        .tag(Optional(overview.id))
                    }
                }
                .pickerStyle(.menu)
                .persistentHelp("选择要为哪个标签寻找相似照片；列表同时显示现有正反样本数。")
                Text("下一步可以选择要扫描的照片来源，并确认建议阈值。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .personalCentroid, .personalAdamW:
            VStack(alignment: .leading, spacing: 12) {
                Text("要训练哪些标签？")
                    .font(.subheadline.weight(.semibold))
                Text("每个标签会独立训练、独立发布；多选即启动多次互不影响的训练。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if personalOptions.isEmpty {
                    Label(
                        "还没有达到最低样本要求的标签。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(personalOptions) { overview in
                                Toggle(
                                    isOn: Binding(
                                        get: {
                                            selectedPersonalTagIDs.contains(overview.id)
                                        },
                                        set: { isSelected in
                                            if isSelected {
                                                selectedPersonalTagIDs.insert(overview.id)
                                            } else {
                                                selectedPersonalTagIDs.remove(overview.id)
                                            }
                                        }
                                    )
                                ) {
                                    HStack(spacing: 12) {
                                        Text(overview.displayName)
                                            .frame(minWidth: 120, alignment: .leading)
                                        Spacer()
                                        Text("已确认 \(overview.acceptedSampleCount) 张")
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(
                                    selectedPersonalTagIDs.contains(overview.id)
                                        ? Color.accentColor.opacity(0.08)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(minHeight: 220, maxHeight: 260)
                    .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                    }
                }

                Divider()
                Picker("使用哪些照片？", selection: $photoScopeChoice) {
                    Text("所有来源中的已确认照片")
                        .tag(TrainingWorkspacePhotoScopeChoice.allSources)
                    if !model.selectedAssetIDs.isEmpty {
                        Text("当前在图库中选择的 \(model.selectedAssetIDs.count) 张照片")
                            .tag(TrainingWorkspacePhotoScopeChoice.currentSelection)
                    }
                }
                .pickerStyle(.radioGroup)
                .persistentHelp("选择训练使用全部来源中的确认照片，或只使用图库当前选中的照片。")
                Text("默认使用所有来源；只有你在这里明确选择时，才会限制为图库中的当前选择。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var confirmationSummary: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
            summaryRow("任务", launchSummary.methodText)
            summaryRow("标签", launchSummary.tagText)
            summaryRow(
                "照片范围",
                selectedMethod == .featureKnn
                    ? "下一步选择要扫描的照片来源"
                    : launchSummary.photoScopeText
            )
            summaryRow("最低要求", launchSummary.requirementText)
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private var launchButtonTitle: String {
        selectedMethod == .featureKnn
            ? "下一步：选择照片来源"
            : "开始训练"
    }

    private func isMethodAvailable(_ method: TrainingRunMethod) -> Bool {
        switch method {
        case .featureKnn:
            !featureOptions.isEmpty && !model.activeReviewSources.isEmpty
        case .personalCentroid:
            model.supportsPersonalModelRebuild && !personalOptions.isEmpty
        case .personalAdamW:
            model.supportsPersonalAdamWModelRebuild && !personalOptions.isEmpty
        }
    }

    private func unavailableText(_ method: TrainingRunMethod) -> String {
        switch method {
        case .featureKnn:
            if model.activeReviewSources.isEmpty {
                return "需要至少一个可用照片来源"
            }
            return "需要至少 2 个属于、2 个不属于"
        case .personalCentroid, .personalAdamW:
            if personalOptions.isEmpty {
                return "需要至少一个有 2 张已确认照片的标签"
            }
            return "当前设备尚未提供此训练能力"
        }
    }

    private func launch() {
        switch selectedMethod {
        case .featureKnn:
            guard let overview = featureOptions.first(where: {
                $0.id == selectedFeatureTagID
            }) else { return }
            onLaunch(
                .feature(
                    tagID: overview.id,
                    displayName: overview.displayName,
                    mode: overview.canUpdate ? .update : .generate
                )
            )
        case .personalCentroid, .personalAdamW:
            guard !selectedPersonalTagIDs.isEmpty else { return }
            onLaunch(
                .personal(
                    method: selectedMethod,
                    tagIDs: selectedPersonalTagIDs,
                    assetIDs: selectedAssetIDs
                )
            )
        }
    }
}

struct TrainingWorkspaceInspectorView: View {
    @ObservedObject var model: LibraryWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("训练工程")
                .font(.headline)
            if let activity = model.trainingWorkspaceActivity {
                ProgressView()
                    .controlSize(.small)
                Text(TrainingWorkspaceActivityPresentation.title(activity))
                    .font(.subheadline.weight(.semibold))
                Text(TrainingWorkspaceActivityPresentation.detail(activity))
                    .foregroundStyle(.secondary)
                Text(TrainingWorkspaceActivityPresentation.phase(activity))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let run = model.selectedTrainingRun {
                let presentation = TrainingWorkspaceMethodPresentation(method: run.method)
                LabeledContent("任务", value: presentation.shortTitle)
                LabeledContent("技术方法", value: presentation.technicalName)
                LabeledContent("状态", value: run.state.trainingWorkspaceDisplayName)
                LabeledContent(
                    "创建",
                    value: TrainingWorkspaceDateFormatter.string(run.createdAtMs)
                )
                Text("训练编号 \(run.id.uuidString.lowercased())")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("从工作台选择一条训练记录，或新建训练任务。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Text("样本门槛")
                .font(.subheadline.weight(.semibold))
            Text("相似照片：每个标签至少 2 个属于、2 个不属于。")
            Text("快速与增强个人模型：每个标签至少 2 个已确认样本。")
            Text("训练结果不会覆盖人工标签；三种建议可以在待审核区同时出现。")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct TrainingWorkspaceMethodPresentation: Equatable {
    let method: TrainingRunMethod
    let title: String
    let shortTitle: String
    let technicalName: String
    let detail: String
    let requirement: String
    let systemImage: String

    init(method: TrainingRunMethod) {
        self = switch method {
        case .featureKnn:
            Self(
                method: method,
                title: "为标签寻找相似照片",
                shortTitle: "相似照片",
                technicalName: "特征向量近邻",
                detail: "用已确认属于和不属于该标签的照片作参考，找出新的相似照片并送去审核。",
                requirement: "每个标签至少 2 个属于、2 个不属于",
                systemImage: "sparkle.magnifyingglass"
            )
        case .personalCentroid:
            Self(
                method: method,
                title: "更新快速个人模型",
                shortTitle: "快速个人模型",
                technicalName: "质心模型",
                detail: "为每个选中标签单独训练一个快速个人模型；互不影响，可单独回滚。",
                requirement: "每个标签至少 2 个已确认样本",
                systemImage: "brain.head.profile"
            )
        case .personalAdamW:
            Self(
                method: method,
                title: "训练增强个人模型",
                shortTitle: "增强个人模型",
                technicalName: "AdamW 线性模型",
                detail: "为每个选中标签单独做更充分的本机训练；标签之间互不影响。",
                requirement: "每个标签至少 2 个已确认样本",
                systemImage: "brain.head.profile.fill"
            )
        }
    }

    init(
        method: TrainingRunMethod,
        title: String,
        shortTitle: String,
        technicalName: String,
        detail: String,
        requirement: String,
        systemImage: String
    ) {
        self.method = method
        self.title = title
        self.shortTitle = shortTitle
        self.technicalName = technicalName
        self.detail = detail
        self.requirement = requirement
        self.systemImage = systemImage
    }
}

struct TrainingWorkspaceLaunchSummary: Equatable {
    let method: TrainingRunMethod
    let tagNames: [String]
    let photoScope: TrainingWorkspaceActivityScope

    var methodText: String {
        let presentation = TrainingWorkspaceMethodPresentation(method: method)
        return "\(presentation.shortTitle)（\(presentation.technicalName)）"
    }

    var tagText: String {
        let names = tagNames.sorted()
        return names.isEmpty ? "尚未选择" : names.joined(separator: "、")
    }

    var photoScopeText: String {
        switch photoScope {
        case .allSources:
            "所有来源中的已确认样本"
        case let .selectedAssets(count):
            "当前选择的 \(count) 张照片"
        }
    }

    var requirementText: String {
        TrainingWorkspaceMethodPresentation(method: method).requirement
    }
}

private struct TrainingWorkspaceRunRow: View {
    let run: TrainingRunRecord

    var body: some View {
        let presentation = TrainingWorkspaceMethodPresentation(method: run.method)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(presentation.shortTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(run.state.trainingWorkspaceDisplayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(run.state.trainingWorkspaceTint)
            }
            Text(presentation.technicalName)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(TrainingWorkspaceDateFormatter.string(run.createdAtMs))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(run.id.uuidString.lowercased())
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct TrainingWorkspaceDetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        } label: {
            Text(title)
                .font(.headline)
        }
    }
}

private struct TrainingWorkspaceJSONSection: View {
    let title: String
    let json: String
    let emptyText: String

    var body: some View {
        DisclosureGroup {
            Text(TrainingWorkspaceJSONPresentation.pretty(json) ?? emptyText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .textSelection(.enabled)
        } label: {
            Label("\(title) · 技术详情", systemImage: "curlybraces")
                .font(.headline)
        }
        .padding(12)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct TrainingWorkspaceMetricsSection: View {
    let json: String

    var body: some View {
        TrainingWorkspaceDetailSection("过程") {
            if let summary = TrainingWorkspaceJSONPresentation.metricsSummary(json) {
                Text(summary)
                    .font(.callout)
            }
            DisclosureGroup("查看原始训练指标") {
                Text(TrainingWorkspaceJSONPresentation.prettyMetrics(json) ?? "没有过程指标")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
    }
}

private enum TrainingWorkspaceDateFormatter {
    static func string(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}

enum TrainingWorkspaceJSONPresentation {
    private static let sensitiveKeyFragments = [
        "path", "bookmark", "locator", "filename", "original",
    ]

    static func pretty(_ json: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let sanitized = sanitize(object, key: nil),
              JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(
                  withJSONObject: sanitized,
                  options: [.prettyPrinted, .sortedKeys]
              )
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func metricsSummary(_ json: String) -> String? {
        guard let metrics = try? JSONSerialization.jsonObject(with: Data(json.utf8))
            as? [String: Any]
        else {
            return nil
        }
        guard let split = metrics["evaluationSplit"] as? String else {
            if json.contains("\"validationLoss\"")
                || json.contains("\"bestValidationLoss\"")
            {
                return "历史指标：评估切分未记录，不能把该 loss 判定为验证损失。"
            }
            return nil
        }
        let trainCount = metrics["trainSampleCount"] as? Int ?? 0
        let validationCount = metrics["validationSampleCount"] as? Int ?? 0
        switch split {
        case "validation":
            return "评估口径：验证集 · 训练样本 \(trainCount) · 验证样本 \(validationCount)"
        case "trainFallback":
            return "评估口径：训练集回退（样本不足，未建立验证集）· 训练样本 \(trainCount)"
        default:
            return "评估口径：\(split)"
        }
    }

    static func prettyMetrics(_ json: String) -> String? {
        pretty(json)?
            .replacingOccurrences(
                of: "\"bestValidationLoss\"",
                with: "\"legacyEvaluationLoss\""
            )
            .replacingOccurrences(
                of: "\"validationLoss\"",
                with: "\"legacyEvaluationLoss\""
            )
    }

    static func safeArtifactReference(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains("://"),
              !value.split(separator: "/").contains("..")
        else {
            return nil
        }
        return value
    }

    private static func sanitize(_ value: Any, key: String?) -> Any? {
        if let key {
            let normalized = key.lowercased()
            if sensitiveKeyFragments.contains(where: normalized.contains) {
                return nil
            }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                if let sanitized = sanitize(entry.value, key: entry.key) {
                    result[entry.key] = sanitized
                }
            }
        }
        if let array = value as? [Any] {
            return array.compactMap { sanitize($0, key: nil) }
        }
        return value
    }
}

enum TrainingWorkspaceActivityPresentation {
    static func title(_ activity: TrainingWorkspaceActivity) -> String {
        "\(TrainingWorkspaceMethodPresentation(method: activity.method).shortTitle)正在训练"
    }

    static func detail(_ activity: TrainingWorkspaceActivity) -> String {
        let tags = activity.tagNames.isEmpty
            ? "未命名标签"
            : activity.tagNames.joined(separator: "、")
        let scope = switch activity.scope {
        case .allSources:
            "所有来源"
        case let .selectedAssets(count):
            "当前选择（\(count) 张）"
        }
        let samples = activity.sampleCount.map { "\($0) 张" } ?? "正在统计"
        return "标签：\(tags) · 范围：\(scope) · 样本：\(samples)"
    }

    static func phase(_ activity: TrainingWorkspaceActivity) -> String {
        switch activity.phase {
        case .preparingSamples:
            "正在读取训练样本"
        case let .preparingEmbeddings(completed, total):
            "正在准备本地特征 \(completed) / \(total)"
        case .trainingAndPublishing:
            "正在训练并发布模型"
        }
    }
}

private extension TrainingRunState {
    var trainingWorkspaceDisplayName: String {
        switch self {
        case .queued: "等待中"
        case .running: "运行中"
        case .succeeded: "成功"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }

    var trainingWorkspaceTint: Color {
        switch self {
        case .queued: .secondary
        case .running: .blue
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }
}
