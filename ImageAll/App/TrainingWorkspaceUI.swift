import Charts
import Foundation
import SwiftUI

enum TrainingWorkspaceLayout {
    static let navigatorMinimumWidth: CGFloat = 210
    static let navigatorMaximumWidth: CGFloat = 270
    static let navigatorMaximumFraction: CGFloat = 0.42

    static func navigatorWidth(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth > 0 else { return 0 }
        let proportional = availableWidth * 0.22
        let preferred = min(
            navigatorMaximumWidth,
            max(navigatorMinimumWidth, proportional)
        )
        return min(preferred, availableWidth * navigatorMaximumFraction)
    }
}

struct TrainingWorkspaceView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let onReturnToLibrary: () -> Void
    @State private var isPresentingTrainingSetup = false
    @State private var pendingLaunchRequest: TrainingWorkspaceLaunchRequest?
    @State private var showsRunNavigator = true

    var body: some View {
        VStack(spacing: 0) {
            compactCommandBar
            Divider()
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    if showsRunNavigator {
                        runList
                            .frame(
                                width: TrainingWorkspaceLayout.navigatorWidth(
                                    availableWidth: proxy.size.width
                                ),
                                height: proxy.size.height
                            )
                        Divider()
                    }
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .animation(.easeInOut(duration: 0.16), value: showsRunNavigator)
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

    private var compactCommandBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Picker("媒体", selection: Binding(
                    get: { model.selectedMediaKind },
                    set: { mediaKind in
                        Task { await model.setTrainingWorkspaceMediaKind(mediaKind) }
                    }
                )) {
                    Label("照片", systemImage: MediaKind.image.systemImage)
                        .tag(MediaKind.image)
                    Label("视频", systemImage: MediaKind.video.systemImage)
                        .tag(MediaKind.video)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 146)
                .accessibilityLabel("媒体类型")
                .accessibilityIdentifier("trainingMediaKindTabs")
                .persistentHelp(
                    "在训练工程内切换照片和视频；训练记录、模型槽和新建任务不会跨媒体混用。"
                )

                Button {
                    isPresentingTrainingSetup = true
                } label: {
                    Label("新建训练任务…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLaunchingTrainingUnavailable)
                .persistentHelp(
                    "打开训练设置，选择目标标签、训练方法和\(model.selectedMediaKind.displayName)范围，再确认创建任务。"
                )

                trainingSlotMenu

                Button {
                    showsRunNavigator.toggle()
                } label: {
                    Label(
                        showsRunNavigator ? "隐藏记录" : "显示记录",
                        systemImage: "rectangle.leadinghalf.inset.filled"
                    )
                    .labelStyle(.iconOnly)
                }
                .accessibilityLabel(showsRunNavigator ? "隐藏训练记录" : "显示训练记录")
                .persistentHelp(
                    showsRunNavigator
                        ? "隐藏训练记录栏，让任务详情使用全部宽度。"
                        : "显示训练记录栏。"
                )

                Button {
                    Task { await model.refreshTrainingWorkspace() }
                } label: {
                    if model.isRefreshingTrainingWorkspace {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("刷新", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                }
                .accessibilityLabel("刷新训练工程")
                .disabled(model.isRefreshingTrainingWorkspace)
                .persistentHelp("重新读取训练记录、模型槽位和当前任务进度；不会启动新的训练。")

                Spacer(minLength: 12)
                inlineActivityStatus

                Button("返回图库", systemImage: "photo.on.rectangle") {
                    onReturnToLibrary()
                }
                .persistentHelp(
                    "退出训练工作台并返回\(model.selectedMediaKind.displayName)图库；正在运行的后台任务不会被取消。"
                )
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    private var isLaunchingTrainingUnavailable: Bool {
        model.isRebuildingPersonalModel
            || model.isRebuildingPersonalAdamWModel
            || model.isGeneratingPersonalLibrarySuggestions
    }

    private var publishedTrainingSlotCount: Int {
        model.trainingSlots.filter(\.isPublished).count
    }

    private var trainingSlotMenu: some View {
        Menu {
            ForEach(model.trainingSlots) { slot in
                let isTraining = model.trainingWorkspaceActivity?.method == slot.method
                let presentation = TrainingWorkspaceMethodPresentation(
                    method: slot.method,
                    mediaKind: model.selectedMediaKind
                )
                Label(
                    "\(presentation.shortTitle)：\(trainingSlotStatusTitle(slot, isTraining: isTraining))",
                    systemImage: trainingSlotStatusSystemImage(slot, isTraining: isTraining)
                )
            }
        } label: {
            Label(
                "模型 \(publishedTrainingSlotCount)/\(model.trainingSlots.count)",
                systemImage: "shippingbox.and.arrow.backward"
            )
        }
        .accessibilityLabel(
            "三种训练产物状态，\(publishedTrainingSlotCount) 个已就绪"
        )
        .persistentHelp("查看相似照片、快速个人模型和增强个人模型的发布状态。")
    }

    private func trainingSlotStatusTitle(
        _ slot: TrainingWorkspaceSlot,
        isTraining: Bool
    ) -> String {
        isTraining ? "训练中" : (slot.isPublished ? "已就绪" : "尚未训练")
    }

    private func trainingSlotStatusSystemImage(
        _ slot: TrainingWorkspaceSlot,
        isTraining: Bool
    ) -> String {
        if isTraining { return "gearshape.2" }
        return slot.isPublished ? "checkmark.circle.fill" : "circle.dashed"
    }

    @ViewBuilder
    private var inlineActivityStatus: some View {
        if let activity = model.trainingWorkspaceActivity {
            HStack(spacing: 6) {
                switch activity.phase {
                case let .preparingEmbeddings(completed, total):
                    ProgressView(
                        value: Double(completed),
                        total: Double(max(total, 1))
                    )
                    .progressViewStyle(.linear)
                    .frame(width: 54)
                case .preparingSamples, .trainingAndPublishing:
                    ProgressView()
                        .controlSize(.small)
                }
                Text(
                    TrainingWorkspaceActivityPresentation.title(
                        activity,
                        mediaKind: model.selectedMediaKind
                    )
                )
                    .fontWeight(.medium)
                Text(TrainingWorkspaceActivityPresentation.phase(activity))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .lineLimit(1)
            .help(
                TrainingWorkspaceActivityPresentation.detail(
                    activity,
                    mediaKind: model.selectedMediaKind
                )
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("当前训练状态")
        }
    }

    private var runList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("训练记录")
                    .font(.headline)
                Text(model.trainingRuns.count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
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
                        Text(
                            TrainingWorkspaceMethodPresentation(
                                method: method,
                                mediaKind: model.selectedMediaKind
                            ).shortTitle
                        )
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
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 34)
                .accessibilityLabel("训练记录列表")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let run = model.selectedTrainingRun {
            runDetail(run)
        } else {
            ContentUnavailableView {
                Label("选择一条训练记录", systemImage: "list.bullet.rectangle")
            } description: {
                Text("这里会展示概览、数据、配置、过程、产物和结果。三种建议可以同时进入待审核队列。")
            }
        }
    }

    private func runDetail(_ run: TrainingRunRecord) -> some View {
        let presentation = TrainingWorkspaceMethodPresentation(
            method: run.method,
            mediaKind: run.mediaKind
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: presentation.systemImage)
                        .font(.title2)
                        .foregroundStyle(run.state.trainingWorkspaceTint)
                        .frame(width: 42, height: 42)
                        .background(
                            run.state.trainingWorkspaceTint.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(presentation.shortTitle)
                            .font(.title2.weight(.semibold))
                        Text(
                            "\(presentation.technicalName) · Run \(shortIdentifier(run.id))"
                        )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(run.state.trainingWorkspaceDisplayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(run.state.trainingWorkspaceTint)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            run.state.trainingWorkspaceTint.opacity(0.12),
                            in: Capsule()
                        )
                }

                runFactLedger(run)
                if let errorCode = run.errorCode {
                    TrainingWorkspaceErrorSection(errorCode: errorCode)
                }
                TrainingWorkspaceMetricsSection(json: run.metricsJSON)
                TrainingWorkspaceArtifactSection(run: run)
                TrainingWorkspaceTechnicalDetailsSection(run: run)
            }
            .padding(18)
            .frame(maxWidth: 1_000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityLabel("训练记录详情")
    }

    private func runFactLedger(_ run: TrainingRunRecord) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 180), spacing: 18)],
            alignment: .leading,
            spacing: 12
        ) {
            TrainingWorkspaceRunFact(
                label: "媒体",
                value: run.mediaKind.displayName,
                systemImage: run.mediaKind.systemImage
            )
            TrainingWorkspaceRunFact(
                label: "创建",
                value: TrainingWorkspaceDateFormatter.string(run.createdAtMs),
                systemImage: "calendar.badge.clock"
            )
            if let startedAtMs = run.startedAtMs {
                TrainingWorkspaceRunFact(
                    label: "开始",
                    value: TrainingWorkspaceDateFormatter.string(startedAtMs),
                    systemImage: "play.circle"
                )
            }
            if let finishedAtMs = run.finishedAtMs {
                TrainingWorkspaceRunFact(
                    label: "结束",
                    value: TrainingWorkspaceDateFormatter.string(finishedAtMs),
                    systemImage: "checkmark.circle"
                )
            }
            if run.mediaKind == .video {
                TrainingWorkspaceRunFact(
                    label: "AI 输入",
                    value: "代表缩略图 videoPoster.v1",
                    systemImage: "rectangle.stack.badge.play"
                )
            }
            if let jobID = run.jobID {
                TrainingWorkspaceRunFact(
                    label: "关联任务",
                    value: shortIdentifier(jobID),
                    systemImage: "link"
                )
            }
        }
        .padding(14)
        .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.secondary.opacity(0.12))
        }
    }

    private func shortIdentifier(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
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
        return model.suggestionOverviews.filter { $0.canGenerate || $0.canUpdate }
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
            mediaKind: model.selectedMediaKind,
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
                .persistentHelp(
                    "按当前标签、方法和\(model.selectedMediaKind.displayName)范围创建训练或建议生成任务。"
                )
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
        let presentation = TrainingWorkspaceMethodPresentation(
            method: method,
            mediaKind: model.selectedMediaKind
        )
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
            Label(
                "选择标签和\(model.selectedMediaKind.displayName)范围",
                systemImage: "slider.horizontal.3"
            )
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
                Picker(
                    "要寻找哪种标签的相似\(model.selectedMediaKind.displayName)？",
                    selection: $selectedFeatureTagID
                ) {
                    ForEach(featureOptions) { overview in
                        Text(
                            "\(overview.displayName)（属于 \(overview.acceptedSampleCount) / 不属于 \(overview.rejectedSampleCount)）"
                        )
                        .tag(Optional(overview.id))
                    }
                }
                .pickerStyle(.menu)
                .persistentHelp(
                    "选择要为哪个标签寻找相似\(model.selectedMediaKind.displayName)；列表同时显示现有正反样本数。"
                )
                Text(
                    "下一步可以选择要扫描的\(model.selectedMediaKind.displayName)来源，并确认建议阈值。"
                )
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
                Picker(
                    "使用哪些\(model.selectedMediaKind.displayName)？",
                    selection: $photoScopeChoice
                ) {
                    Text("所有来源中的已确认\(model.selectedMediaKind.displayName)")
                        .tag(TrainingWorkspacePhotoScopeChoice.allSources)
                    if !model.selectedAssetIDs.isEmpty {
                        Text(
                            "当前在图库中选择的 \(model.selectedAssetIDs.count) \(model.selectedMediaKind == .image ? "张照片" : "个视频")"
                        )
                            .tag(TrainingWorkspacePhotoScopeChoice.currentSelection)
                    }
                }
                .pickerStyle(.radioGroup)
                .persistentHelp(
                    "选择训练使用全部来源中的确认\(model.selectedMediaKind.displayName)，或只使用图库当前选中的\(model.selectedMediaKind.displayName)。"
                )
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
                "\(model.selectedMediaKind.displayName)范围",
                selectedMethod == .featureKnn
                    ? "下一步选择要扫描的\(model.selectedMediaKind.displayName)来源"
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
            ? "下一步：选择\(model.selectedMediaKind.displayName)来源"
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
                return "需要至少一个可用\(model.selectedMediaKind.displayName)来源"
            }
            return "需要至少 2 个属于、2 个不属于"
        case .personalCentroid, .personalAdamW:
            if personalOptions.isEmpty {
                return "需要至少一个有 2 个已确认\(model.selectedMediaKind.displayName)样本的标签"
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
                Text(
                    TrainingWorkspaceActivityPresentation.title(
                        activity,
                        mediaKind: model.selectedMediaKind
                    )
                )
                    .font(.subheadline.weight(.semibold))
                Text(
                    TrainingWorkspaceActivityPresentation.detail(
                        activity,
                        mediaKind: model.selectedMediaKind
                    )
                )
                    .foregroundStyle(.secondary)
                Text(TrainingWorkspaceActivityPresentation.phase(activity))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let run = model.selectedTrainingRun {
                let presentation = TrainingWorkspaceMethodPresentation(
                    method: run.method,
                    mediaKind: run.mediaKind
                )
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
            Text(
                "相似\(model.selectedMediaKind.displayName)：每个标签至少 2 个属于、2 个不属于。"
            )
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

    init(method: TrainingRunMethod, mediaKind: MediaKind = .image) {
        self = switch method {
        case .featureKnn:
            Self(
                method: method,
                title: "为标签寻找相似\(mediaKind.displayName)",
                shortTitle: "相似\(mediaKind.displayName)",
                technicalName: "特征向量近邻",
                detail: "用已确认属于和不属于该标签的\(mediaKind.displayName)作参考，找出新的相似\(mediaKind.displayName)并送去审核。",
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
    let mediaKind: MediaKind
    let photoScope: TrainingWorkspaceActivityScope

    init(
        method: TrainingRunMethod,
        tagNames: [String],
        mediaKind: MediaKind = .image,
        photoScope: TrainingWorkspaceActivityScope
    ) {
        self.method = method
        self.tagNames = tagNames
        self.mediaKind = mediaKind
        self.photoScope = photoScope
    }

    var methodText: String {
        let presentation = TrainingWorkspaceMethodPresentation(
            method: method,
            mediaKind: mediaKind
        )
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
            "当前选择的 \(count) \(mediaKind == .image ? "张照片" : "个视频")"
        }
    }

    var requirementText: String {
        TrainingWorkspaceMethodPresentation(
            method: method,
            mediaKind: mediaKind
        ).requirement
    }
}

private struct TrainingWorkspaceRunRow: View {
    let run: TrainingRunRecord

    var body: some View {
        let presentation = TrainingWorkspaceMethodPresentation(
            method: run.method,
            mediaKind: run.mediaKind
        )
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(presentation.shortTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(run.state.trainingWorkspaceTint)
                Text(run.state.trainingWorkspaceDisplayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                Text(presentation.technicalName)
                Text("·")
                Text(TrainingWorkspaceDateFormatter.string(run.createdAtMs))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
        .help("训练编号 \(run.id.uuidString.lowercased())")
        .accessibilityElement(children: .combine)
    }
}

private struct TrainingWorkspaceRunFact: View {
    let label: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct TrainingWorkspaceDetailSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
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
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
    }
}

private struct TrainingWorkspaceArtifactSection: View {
    let run: TrainingRunRecord

    private var safeReference: String {
        TrainingWorkspaceJSONPresentation.safeArtifactReference(run.artifactRef)
            ?? (run.artifactRef == nil ? "无" : "已隐藏不安全引用")
    }

    private var hasTechnicalValues: Bool {
        run.artifactRef != nil
            || run.artifactSHA256 != nil
            || run.sampleManifestSHA256 != nil
    }

    var body: some View {
        TrainingWorkspaceDetailSection(
            "训练产物",
            systemImage: "shippingbox"
        ) {
            LabeledContent("类型", value: run.artifactKind ?? "未发布")
            if hasTechnicalValues {
                DisclosureGroup("查看引用与校验值") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("引用", value: safeReference)
                        if let artifactSHA256 = run.artifactSHA256 {
                            LabeledContent("SHA-256", value: artifactSHA256)
                        }
                        if let manifest = run.sampleManifestSHA256 {
                            LabeledContent("样本清单 SHA-256", value: manifest)
                        }
                    }
                    .font(.caption)
                    .padding(.top, 6)
                }
            }
        }
    }
}

private struct TrainingWorkspaceMetricsSection: View {
    let json: String

    private var metrics: [TrainingWorkspaceMetricPoint] {
        TrainingWorkspaceJSONPresentation.metricCurve(json)
    }

    private var bestMetric: TrainingWorkspaceMetricPoint? {
        metrics.min { lhs, rhs in
            lhs.loss == rhs.loss ? lhs.epoch < rhs.epoch : lhs.loss < rhs.loss
        }
    }

    private var latestMetric: TrainingWorkspaceMetricPoint? {
        metrics.last
    }

    var body: some View {
        TrainingWorkspaceDetailSection(
            "训练过程",
            systemImage: "chart.xyaxis.line"
        ) {
            if let summary = TrainingWorkspaceJSONPresentation.metricsSummary(json) {
                Text(summary)
                    .font(.callout)
            } else {
                Text("当前记录没有可概括的评估口径。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if metrics.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "chart.line.downtrend.xyaxis")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("没有可绘制的训练曲线")
                            .font(.subheadline.weight(.semibold))
                        Text("训练完成并记录逐轮损失后，曲线会显示在这里。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    .secondary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            } else {
                metricHighlights
                lossChart
            }
        }
    }

    private var metricHighlights: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120), spacing: 10)],
            alignment: .leading,
            spacing: 10
        ) {
            metricHighlight(
                title: "训练轮次",
                value: metrics.count.formatted(),
                systemImage: "repeat"
            )
            metricHighlight(
                title: "最佳损失",
                value: formattedLoss(bestMetric?.loss),
                systemImage: "arrow.down.to.line"
            )
            metricHighlight(
                title: "最终损失",
                value: formattedLoss(latestMetric?.loss),
                systemImage: "flag.checkered"
            )
        }
    }

    private var lossChart: some View {
        Chart {
            ForEach(metrics) { metric in
                LineMark(
                    x: .value("训练轮次", metric.epoch),
                    y: .value("评估损失", metric.loss)
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)
            }

            if let bestMetric {
                RuleMark(y: .value("最佳损失", bestMetric.loss))
                    .foregroundStyle(Color.green.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                PointMark(
                    x: .value("最佳轮次", bestMetric.epoch),
                    y: .value("最佳损失", bestMetric.loss)
                )
                .foregroundStyle(Color.green)
                .symbolSize(42)
            }
        }
        .chartLegend(.hidden)
        .chartXAxisLabel("训练轮次")
        .chartYAxisLabel("评估损失")
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) {
                AxisGridLine().foregroundStyle(.secondary.opacity(0.14))
                AxisTick()
                AxisValueLabel()
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) {
                AxisGridLine().foregroundStyle(.secondary.opacity(0.14))
                AxisTick()
                AxisValueLabel()
            }
        }
        .frame(height: 230)
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            .secondary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityLabel("训练损失曲线")
        .accessibilityValue(accessibilitySummary)
    }

    private func metricHighlight(
        title: String,
        value: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            Color.accentColor.opacity(0.065),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func formattedLoss(_ loss: Double?) -> String {
        guard let loss else { return "—" }
        return loss.formatted(.number.precision(.significantDigits(3 ... 5)))
    }

    private var accessibilitySummary: String {
        guard let bestMetric, let latestMetric else { return "没有过程指标" }
        return """
        共 \(metrics.count) 轮，最佳损失 \(formattedLoss(bestMetric.loss))，\
        最终损失 \(formattedLoss(latestMetric.loss))
        """
    }
}

private struct TrainingWorkspaceTechnicalDetailsSection: View {
    let run: TrainingRunRecord

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 14) {
                technicalBlock(
                    title: "运行标识",
                    text: identifierText
                )
                technicalBlock(
                    title: "数据",
                    text: TrainingWorkspaceJSONPresentation.pretty(run.sampleSummaryJSON)
                        ?? "没有样本摘要"
                )
                technicalBlock(
                    title: "配置",
                    text: TrainingWorkspaceJSONPresentation.pretty(run.configJSON)
                        ?? "没有配置摘要"
                )
                technicalBlock(
                    title: "结果",
                    text: TrainingWorkspaceJSONPresentation.pretty(run.resultSummaryJSON)
                        ?? "没有结果摘要"
                )
            }
            .padding(.top, 10)
        } label: {
            Label("数据、配置与结果 · 技术详情", systemImage: "curlybraces")
                .font(.headline)
        }
        .padding(12)
        .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }

    private var identifierText: String {
        var lines = ["training_run: \(run.id.uuidString.lowercased())"]
        if let jobID = run.jobID {
            lines.append("job: \(jobID.uuidString.lowercased())")
        }
        return lines.joined(separator: "\n")
    }

    private func technicalBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TrainingWorkspaceErrorSection: View {
    let errorCode: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 3) {
                Text("训练失败")
                    .font(.headline)
                Text(errorCode)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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

    static func metricCurve(_ json: String) -> [TrainingWorkspaceMetricPoint] {
        guard let metrics = try? JSONSerialization.jsonObject(with: Data(json.utf8))
            as? [String: Any],
              let epochs = metrics["epochs"] as? [[String: Any]]
        else {
            return []
        }
        var lossByEpoch: [Int: Double] = [:]
        for item in epochs {
            guard let epoch = item["epoch"] as? Int,
                  epoch > 0,
                  let number = (item["evaluationLoss"] ?? item["validationLoss"])
                    as? NSNumber
            else {
                continue
            }
            let loss = number.doubleValue
            guard loss.isFinite, loss >= 0 else { continue }
            lossByEpoch[epoch] = loss
        }
        return lossByEpoch
            .map { TrainingWorkspaceMetricPoint(epoch: $0.key, loss: $0.value) }
            .sorted { $0.epoch < $1.epoch }
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

struct TrainingWorkspaceMetricPoint: Identifiable, Equatable {
    let epoch: Int
    let loss: Double

    var id: Int { epoch }
}

enum TrainingWorkspaceActivityPresentation {
    static func title(
        _ activity: TrainingWorkspaceActivity,
        mediaKind: MediaKind = .image
    ) -> String {
        "\(TrainingWorkspaceMethodPresentation(method: activity.method, mediaKind: mediaKind).shortTitle)正在训练"
    }

    static func detail(
        _ activity: TrainingWorkspaceActivity,
        mediaKind: MediaKind = .image
    ) -> String {
        let tags = activity.tagNames.isEmpty
            ? "未命名标签"
            : activity.tagNames.joined(separator: "、")
        let scope = switch activity.scope {
        case .allSources:
            "所有来源"
        case let .selectedAssets(count):
            "当前选择（\(count) \(mediaKind == .image ? "张" : "个")）"
        }
        let samples = activity.sampleCount.map {
            "\($0) \(mediaKind == .image ? "张" : "个")"
        } ?? "正在统计"
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
