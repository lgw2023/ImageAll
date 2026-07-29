import AppKit
import Charts
import SwiftUI

struct LibrarySlimmingClusterPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: SlimmingClusterKind
    let memberAssetIDs: [UUID]
    let representativeAssetID: UUID
    let score: Double
    let modelIdentity: SlimmingVectorModelIdentity

    var kindTitle: String {
        switch kind {
        case .byteIdentical: "完全相同"
        case .perceptualDuplicate: "视觉重复"
        case .nearDuplicateScene: "同场景相似"
        }
    }

    var scoreCaption: String {
        switch kind {
        case .byteIdentical:
            "内容完全一致"
        case .perceptualDuplicate:
            String(format: "画面高度相似 · 匹配度 %.0f%%", score * 100)
        case .nearDuplicateScene:
            String(format: "同场景相似度 %.0f%%", score * 100)
        }
    }

    var technicalDetailsCaption: String {
        switch kind {
        case .byteIdentical:
            "SHA-256 一致 · \(modelIdentity.revisionCaption)"
        case .perceptualDuplicate:
            String(
                format: "感知匹配 %.0f%% · %@",
                score * 100,
                modelIdentity.revisionCaption
            )
        case .nearDuplicateScene:
            String(
                format: "DINOv2 余弦 %.3f · %@",
                score,
                modelIdentity.revisionCaption
            )
        }
    }

    var cluster: SlimmingCluster {
        SlimmingCluster(
            id: id,
            kind: kind,
            memberAssetIDs: memberAssetIDs,
            representativeAssetID: representativeAssetID,
            score: score,
            modelIdentity: modelIdentity
        )
    }

    init(_ cluster: SlimmingCluster) {
        id = cluster.id
        kind = cluster.kind
        memberAssetIDs = cluster.memberAssetIDs
        representativeAssetID = cluster.representativeAssetID
        score = cluster.score
        modelIdentity = cluster.modelIdentity
    }
}

struct LibrarySlimmingAnalysisJobPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let mode: LibrarySlimmingAnalyzeMode
    let state: JobState
    let controlRequest: JobControlRequest
    let progress: JobProgress
    let attempts: Int
    let maxAttempts: Int
    let memberCount: Int
    let seedCount: Int
    let clusterCount: Int
    let hasResult: Bool
    let createdAtMs: Int64
    let updatedAtMs: Int64
    let sourceNames: [String]

    var modeTitle: String {
        switch mode {
        case .catalog: "全部来源"
        case .currentFilter: "当前筛选"
        case .seeds: "种子检索"
        }
    }

    var stateTitle: String {
        switch (state, controlRequest) {
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

    var detailCaption: String {
        var parts: [String] = ["\(memberCount) 张"]
        if seedCount > 0 {
            parts.append("种子 \(seedCount)")
        }
        if hasResult {
            parts.append("\(clusterCount) 个簇")
        }
        parts.append("尝试 \(attempts)/\(maxAttempts)")
        if let progressCaption = scanProgressCaption {
            parts.append(progressCaption)
        }
        return parts.joined(separator: " · ")
    }

    var attemptCaption: String {
        "\(attempts) / \(maxAttempts)"
    }

    var sourceNamesText: String {
        guard !sourceNames.isEmpty else { return "任务来源不可用" }
        return sourceNames.joined(separator: "、")
    }

    var sourceCaption: String {
        guard sourceNames.count > 1 else {
            return "来源：\(sourceNamesText)"
        }
        return "来源（\(sourceNames.count)）：\(sourceNamesText)"
    }

    private var scanProgressCaption: String? {
        guard memberCount > 0,
              let progressTotal = progress.total,
              progressTotal > 0,
              state == .running || state == .paused || state == .pending
        else {
            return nil
        }
        guard let mapped = LibrarySlimmingJobProgressPresentation.scanProgress(
            completed: progress.completed,
            progressTotal: progressTotal,
            memberCount: memberCount
        ) else {
            return nil
        }
        return "\(mapped.completed)/\(mapped.total)"
    }

    var createdCaption: String {
        let date = Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1000)
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    init(_ summary: LibrarySlimmingAnalysisJobSummary) {
        id = summary.jobID
        mode = summary.mode
        state = summary.state
        controlRequest = summary.controlRequest
        progress = summary.progress
        attempts = summary.attempts
        maxAttempts = summary.maxAttempts
        memberCount = summary.memberCount
        seedCount = summary.seedCount
        clusterCount = summary.clusterCount
        hasResult = summary.hasResult
        createdAtMs = summary.createdAtMs
        updatedAtMs = summary.updatedAtMs
        sourceNames = summary.sourceNames
    }
}

struct LibrarySlimmingWorkspaceView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let onReturnToLibrary: () -> Void
    @FocusState private var keyboardFocused: Bool
    @State private var confirmMoveToRecycle = false
    @State private var suppressMoveToRecycleConfirmation = false
    @State private var confirmPurgeEntryID: UUID?
    @State private var identicalCleanupPlan: LibrarySlimmingIdenticalCleanupPlan?
    @State private var slimmingGridCellFrames = LibraryGridCellFrameStore()
    @State private var isSlimmingMarqueeSelecting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("工作台", selection: Binding(
                get: { model.librarySlimmingWorkspaceTab },
                set: { model.selectLibrarySlimmingWorkspaceTab($0) }
            )) {
                Text("分析结果").tag(LibrarySlimmingWorkspaceTab.clusters)
                Text("回收站").tag(LibrarySlimmingWorkspaceTab.recycleBin)
            }
            .pickerStyle(.segmented)
            .persistentHelp("在分析结果和 ImageAll 回收站之间切换；不会启动、删除或恢复任务。")
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if model.isAnalyzingLibrarySlimming, let progress = model.librarySlimmingScanProgress {
                progressBanner(progress)
                Divider()
            }
            if let message = model.librarySlimmingRecycleActionMessage {
                statusBanner(message)
                Divider()
            } else if !model.isAnalyzingLibrarySlimming,
                      let message = model.librarySlimmingStatusMessage
            {
                statusBanner(message)
                Divider()
            }

            // Size-locked workspace body.
            //
            // Under NavigationSplitView + .inspector, HSplitView/List often receive an
            // unbounded height proposal. A long cluster List then sizes to its full
            // content height, expands the detail column, and clips the header/picker
            // out of view. Color.clear flexes to the remaining offered space; its
            // overlay proposes that exact size to children, so List must scroll.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if model.librarySlimmingWorkspaceTab == .recycleBin {
                        recycleBinList
                    } else {
                        GeometryReader { proxy in
                            let navigatorWidth = analysisNavigatorWidth(
                                availableWidth: proxy.size.width
                            )
                            HStack(spacing: 0) {
                                analysisHistoryAndClusters
                                    .frame(width: navigatorWidth, height: proxy.size.height)
                                Divider()
                                clusterDetail
                                    .frame(
                                        width: max(proxy.size.width - navigatorWidth - 1, 0),
                                        height: proxy.size.height
                                    )
                            }
                        }
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("图库瘦身")
        .accessibilityLabel("图库瘦身工作台")
        .focusable()
        .focused($keyboardFocused)
        .focusEffectDisabled()
        .onAppear {
            keyboardFocused = true
            model.ensureLibrarySlimmingClusterSelection()
        }
        .onChange(of: model.librarySlimmingClusters.map(\.id)) { _, _ in
            model.ensureLibrarySlimmingClusterSelection()
        }
        .onChange(of: model.selectedLibrarySlimmingClusterID) { _, _ in
            model.ensureLibrarySlimmingClusterSelection()
        }
        .onKeyPress(.delete, action: handleMoveToRecycleKeyPress)
        .onKeyPress(.deleteForward, action: handleMoveToRecycleKeyPress)
        .task {
            await model.refreshLibrarySlimmingAnalysisJobs()
            await model.refreshSourceSimilarityIndexStatus()
            model.ensureLibrarySlimmingAnalysisMonitoring()
        }
        .task(id: model.librarySlimmingWorkspaceTab) {
            if model.librarySlimmingWorkspaceTab == .recycleBin {
                await model.refreshLibrarySlimmingRecycleEntries()
            }
        }
        .sheet(isPresented: $confirmMoveToRecycle) {
            LibrarySlimmingMoveToRecycleConfirmationSheet(
                selectedCount: model.selectedLibrarySlimmingMemberIDs.count,
                suppressFutureConfirmation: $suppressMoveToRecycleConfirmation,
                onConfirm: {
                    if suppressMoveToRecycleConfirmation {
                        model.setSkipsLibrarySlimmingMoveToRecycleConfirmation(true)
                    }
                    confirmMoveToRecycle = false
                    Task { await model.moveSelectedLibrarySlimmingMembersToRecycle() }
                },
                onCancel: {
                    confirmMoveToRecycle = false
                }
            )
        }
        .sheet(
            isPresented: Binding(
                get: { identicalCleanupPlan != nil },
                set: { if !$0 { identicalCleanupPlan = nil } }
            )
        ) {
            if let plan = identicalCleanupPlan {
                LibrarySlimmingIdenticalCleanupConfirmationSheet(
                    plan: plan,
                    onConfirm: {
                        identicalCleanupPlan = nil
                        Task {
                            await model.moveLibrarySlimmingIdenticalRedundancyToRecycle(
                                plan: plan
                            )
                        }
                    },
                    onCancel: {
                        identicalCleanupPlan = nil
                    }
                )
            }
        }
        .confirmationDialog(
            "立即永久删除",
            isPresented: Binding(
                get: { confirmPurgeEntryID != nil },
                set: { if !$0 { confirmPurgeEntryID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                if let id = confirmPurgeEntryID {
                    Task { await model.purgeLibrarySlimmingRecycleEntry(id) }
                }
                confirmPurgeEntryID = nil
            }
            .persistentHelp("永久删除回收站中的这张文件夹原图；此操作不可撤销。")
            Button("取消", role: .cancel) {
                confirmPurgeEntryID = nil
            }
            .persistentHelp("关闭确认窗口并保留回收站中的照片。")
        } message: {
            Text("此操作不可撤销，将删除回收站中的原图文件。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    Task { await model.analyzeLibrarySlimming(mode: .catalog) }
                } label: {
                    if model.isAnalyzingLibrarySlimming,
                       model.librarySlimmingAnalyzeMode == .catalog
                    {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.librarySlimmingCatalogAnalyzeRunningTitle)
                    } else {
                        Label(
                            model.librarySlimmingCatalogAnalyzeActionTitle,
                            systemImage: "wand.and.stars"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canAnalyzeLibrarySlimmingCatalog)
                .persistentHelp(
                    "\(model.librarySlimmingCatalogSourceScopeCaption)；不会取消已有分析记录"
                )

                Menu {
                    Button {
                        model.selectAllLibrarySlimmingCatalogSources()
                    } label: {
                        Label(
                            "全选",
                            systemImage: allLibrarySlimmingCatalogSourcesSelected
                                ? "checkmark"
                                : "square"
                        )
                    }

                    Button {
                        model.clearLibrarySlimmingCatalogSourceSelection()
                    } label: {
                        Label("清空选择", systemImage: "xmark")
                    }
                    .disabled(
                        !model.activeLibrarySlimmingSources.contains {
                            model.isLibrarySlimmingCatalogSourceIncluded($0.id)
                        }
                    )

                    Divider()

                    ForEach(model.activeLibrarySlimmingSources) { source in
                        Toggle(
                            isOn: Binding(
                                get: {
                                    model.isLibrarySlimmingCatalogSourceIncluded(source.id)
                                },
                                set: {
                                    model.setLibrarySlimmingCatalogSourceIncluded(
                                        source.id,
                                        $0
                                    )
                                }
                            )
                        ) {
                            Label(
                                source.displayName,
                                systemImage: source.kind == .photos
                                    ? "photo.on.rectangle.angled"
                                    : "folder"
                            )
                        }
                    }
                } label: {
                    Label(
                        model.librarySlimmingCatalogSourceSelectionTitle,
                        systemImage: "square.stack.3d.up"
                    )
                }
                .disabled(model.activeLibrarySlimmingSources.isEmpty)
                .persistentHelp(
                    "选择一个或多个要分析的来源；只列出当前可用来源"
                )

                Button {
                    Task { await model.analyzeLibrarySlimming(mode: .currentFilter) }
                } label: {
                    if model.isAnalyzingLibrarySlimming,
                       model.librarySlimmingAnalyzeMode == .currentFilter
                    {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.librarySlimmingCurrentFilterRunningTitle)
                    } else {
                        Label(
                            model.librarySlimmingCurrentFilterActionTitle,
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                    }
                }
                .disabled(
                    !model.supportsLibrarySlimming
                        || !model.hasLibrarySlimmingFilterScope
                )
                .persistentHelp(
                    "\(model.librarySlimmingFilterScopeCaption)；不会取消已有分析记录"
                )

                if !model.librarySlimmingSeedAssetIDs.isEmpty {
                    Button {
                        Task { await model.analyzeLibrarySlimming(mode: .seeds) }
                    } label: {
                        Label(
                            "按种子查找 (\(model.librarySlimmingSeedAssetIDs.count))",
                            systemImage: "target"
                        )
                    }
                    .disabled(!model.supportsLibrarySlimming)
                    .persistentHelp("以当前种子发起新的检索任务；不会取消已有分析记录")
                }

                if model.supportsLibrarySlimmingThresholds {
                    Button {
                        model.showsLibrarySlimmingThresholdEditor.toggle()
                    } label: {
                        Label("阈值", systemImage: "slider.horizontal.3")
                    }
                    .popover(
                        isPresented: $model.showsLibrarySlimmingThresholdEditor,
                        arrowEdge: .bottom
                    ) {
                        LibrarySlimmingThresholdEditor(model: model)
                            .frame(width: 320)
                            .padding(16)
                    }
                    .persistentHelp("调整相似召回与精排阈值；下次分析生效")
                }

                Spacer()

                Button("返回图库", systemImage: "photo.on.rectangle") {
                    onReturnToLibrary()
                }
                .persistentHelp("退出图库瘦身工作区并返回照片图库；已有分析任务不会被删除。")
            }

            HStack(spacing: 10) {
                if model.canPauseLibrarySlimmingAnalysis {
                    Button {
                        Task { await model.pauseLibrarySlimmingAnalysis() }
                    } label: {
                        Label("暂停当前", systemImage: "pause.fill")
                    }
                    .persistentHelp("暂停当前选中的分析任务")
                } else if model.canResumeLibrarySlimmingAnalysis {
                    Button {
                        Task { await model.resumeLibrarySlimmingAnalysis() }
                    } label: {
                        Label("继续当前", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .persistentHelp("从已保存进度继续当前选中的分析任务")
                }

                if model.canDeleteSelectedLibrarySlimmingAnalysisJob {
                    Button(role: .destructive) {
                        if let id = model.librarySlimmingAnalysisJobID {
                            Task { await model.deleteLibrarySlimmingAnalysisJob(id) }
                        }
                    } label: {
                        Label("删除记录", systemImage: "trash")
                    }
                    .persistentHelp("永久删除当前选中的分析任务与结果")
                }

                if model.librarySlimmingIdenticalGroupCount > 0 {
                    Button(role: .destructive) {
                        Task {
                            identicalCleanupPlan =
                                await model.prepareLibrarySlimmingIdenticalCleanup()
                        }
                    } label: {
                        if model.isPreparingLibrarySlimmingIdenticalCleanup {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在计算清理方案…")
                        } else {
                            Label(
                                "一键清理完全相同（\(model.librarySlimmingIdenticalGroupCount) 组）",
                                systemImage: "trash.square"
                            )
                        }
                    }
                    .disabled(!model.canPrepareLibrarySlimmingIdenticalCleanup)
                    .persistentHelp(
                        model.librarySlimmingIdenticalCleanupDisabledReason
                            ?? "为当前分析结果的每个完全相同分组保留一张，并预览其余照片的批量回收方案。"
                    )
                }

                if model.selectedLibrarySlimmingCluster != nil {
                    Button(role: .destructive) {
                        requestMoveToRecycleConfirmation()
                    } label: {
                        if model.selectedLibrarySlimmingMemberIDs.isEmpty {
                            Label("移入回收站", systemImage: "trash.slash")
                        } else {
                            Label(
                                "移入回收站 (\(model.selectedLibrarySlimmingMemberIDs.count))",
                                systemImage: "trash.slash"
                            )
                        }
                    }
                    .disabled(!model.canMoveSelectedLibrarySlimmingMembersToRecycle)
                    .persistentHelp(
                        model.librarySlimmingMoveToRecycleDisabledReason
                            ?? "将簇内选中的照片移入回收站（⌫ / Delete 或右键菜单）"
                    )
                }

                if model.librarySlimmingPendingCount > 0 {
                    Text("待分析 \(model.librarySlimmingPendingCount) 张")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }

                if model.supportsSourceSimilarityIndex {
                    Button {
                        Task { await model.initializeSourceSimilarityIndex() }
                    } label: {
                        if model.isInitializingSourceSimilarityIndex {
                            ProgressView()
                                .controlSize(.small)
                            Text("初始化中…")
                        } else {
                            Label(
                                "初始化来源索引",
                                systemImage: "point.3.connected.trianglepath.dotted"
                            )
                        }
                    }
                    .disabled(!model.canInitializeSourceSimilarityIndex)
                    .persistentHelp("为当前选中的单个来源建立 Feature Print 邻域索引，加速后续按种子检索")

                    if let caption = model.sourceSimilarityIndexCaption {
                        Text(caption)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                Spacer()

                Text(model.librarySlimmingFilterScopeCaption)
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .lineLimit(2)
                    .persistentHelp("“分析来源”或“分析当前筛选”将覆盖的来源、标签和搜索条件。")

                Text(modeCaption)
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var modeCaption: String {
        switch model.librarySlimmingAnalyzeMode {
        case .catalog: "模式：\(model.librarySlimmingCatalogSourceSelectionTitle)"
        case .currentFilter: "模式：当前筛选"
        case .seeds: "模式：种子检索"
        }
    }

    private var allLibrarySlimmingCatalogSourcesSelected: Bool {
        !model.activeLibrarySlimmingSources.isEmpty
            && model.activeLibrarySlimmingSources.allSatisfy {
                model.isLibrarySlimmingCatalogSourceIncluded($0.id)
            }
    }

    private func handleMoveToRecycleKeyPress() -> KeyPress.Result {
        guard model.librarySlimmingWorkspaceTab == .clusters,
              model.canMoveSelectedLibrarySlimmingMembersToRecycle
        else { return .ignored }
        requestMoveToRecycleConfirmation()
        return .handled
    }

    private func requestMoveToRecycleConfirmation() {
        guard model.canMoveSelectedLibrarySlimmingMembersToRecycle else { return }
        if model.skipsLibrarySlimmingMoveToRecycleConfirmation {
            Task { await model.moveSelectedLibrarySlimmingMembersToRecycle() }
            return
        }
        suppressMoveToRecycleConfirmation = false
        confirmMoveToRecycle = true
    }

    private func presentMoveToRecycle(for assetID: UUID) {
        if model.selectedLibrarySlimmingMemberIDs.contains(assetID) {
            // Keep the current multi-selection.
        } else {
            model.selectLibrarySlimmingMember(assetID, additive: false)
        }
        requestMoveToRecycleConfirmation()
    }

    private func progressBanner(_ progress: LibrarySlimmingScanProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(progress.caption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .animation(.linear(duration: 0.25), value: progress.fraction)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityLabel(progress.caption)
        .animation(.default, value: progress.caption)
    }

    private func statusBanner(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    private func analysisNavigatorWidth(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth > 0 else { return 0 }
        let preferred = min(340, max(220, availableWidth * 0.34))
        // Never consume more than half the locked pane when the inspector is open.
        return min(preferred, availableWidth * 0.5)
    }

    private var analysisHistoryAndClusters: some View {
        List(selection: Binding(
            get: { model.librarySlimmingAnalysisJobID },
            set: { model.selectLibrarySlimmingAnalysisJob($0) }
        )) {
            Section {
                if model.librarySlimmingAnalysisJobs.isEmpty {
                    Text("尚无分析记录。发起分析后会永久保存在这里，除非手动删除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.librarySlimmingAnalysisJobs) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(job.modeTitle)
                                    .font(.headline)
                                Spacer()
                                Text(job.stateTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(job.detailCaption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(job.sourceCaption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .help(job.sourceCaption)
                            Text(job.createdCaption)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .tag(Optional(job.id))
                        .contextMenu {
                            if job.state != .running {
                                Button("删除记录", role: .destructive) {
                                    Task { await model.deleteLibrarySlimmingAnalysisJob(job.id) }
                                }
                                .persistentHelp("永久删除这条分析任务记录和结果；不会删除任何原照片。")
                            }
                        }
                        .accessibilityLabel(
                            "\(job.modeTitle)，\(job.stateTitle)，\(job.detailCaption)，\(job.sourceCaption)"
                        )
                    }
                }
            } header: {
                HStack {
                    Text("分析记录")
                    Spacer()
                    Text("\(model.librarySlimmingAnalysisJobs.count) 条")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if model.librarySlimmingAnalysisJobID == nil {
                    Text("请先选择一条分析记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.librarySlimmingClusters.isEmpty {
                    if model.hasCompletedLibrarySlimmingScan {
                        Text("本次分析未发现相同或相似簇。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if model.canResumeLibrarySlimmingAnalysis {
                        Text("该任务尚无结果。若进度长时间不动，请点击工具栏「继续当前」。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if model.isAnalyzingLibrarySlimming {
                        Text("该任务尚无结果，正在后台处理…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("该任务尚无结果。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.librarySlimmingClusters) { cluster in
                        Button {
                            model.selectLibrarySlimmingCluster(cluster.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(cluster.kindTitle)
                                        .font(.body.weight(.semibold))
                                    Spacer()
                                    Text("\(cluster.memberAssetIDs.count) 张")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                                Text(cluster.scoreCaption)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            model.selectedLibrarySlimmingClusterID == cluster.id
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                        .accessibilityLabel("\(cluster.kindTitle)，\(cluster.memberAssetIDs.count) 张")
                    }
                }
            } header: {
                HStack {
                    Text("结果分组")
                    Spacer()
                    if !model.librarySlimmingClusters.isEmpty {
                        Text("\(model.librarySlimmingClusters.count) 组")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var clusterDetail: some View {
        Group {
            if let cluster = model.selectedLibrarySlimmingCluster {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(cluster.kindTitle)
                            .font(.title2.weight(.semibold))
                        Spacer()
                        Text(cluster.scoreCaption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)

                    Text(
                        "成员 \(cluster.memberAssetIDs.count) · 已选 \(model.selectedLibrarySlimmingMemberIDs.count) · ⌘点击多选 · Shift 点击连续选择 · 拖拽框选"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)

                    if let sourceSummary = model.librarySlimmingSelectedClusterSourceSummary {
                        Text("来源：\(sourceSummary)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.horizontal, 16)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    GeometryReader { proxy in
                        let layoutWidth = LibraryGridLayout.layoutWidth(
                            containerWidth: proxy.size.width
                        )
                        ScrollView {
                            LibraryGridMarqueeContainer(
                                cellFrames: slimmingGridCellFrames,
                                isMarqueeSelecting: $isSlimmingMarqueeSelecting,
                                viewportHeight: proxy.size.height,
                                contentWidth: layoutWidth,
                                currentSelection: model.selectedLibrarySlimmingMemberIDs,
                                onSelectionChange: { assetIDs, _ in
                                    keyboardFocused = true
                                    model.selectLibrarySlimmingMembers(assetIDs)
                                }
                            ) {
                                LazyVGrid(
                                    columns: LibraryGridLayout.gridItems(
                                        containerWidth: proxy.size.width,
                                        density: model.gridDensity
                                    ),
                                    spacing: LibraryGridLayout.spacing
                                ) {
                                    ForEach(cluster.memberAssetIDs, id: \.self) { assetID in
                                        SlimmingThumbnailCell(
                                            model: model,
                                            assetID: assetID,
                                            isSelected: model.selectedLibrarySlimmingMemberIDs.contains(assetID)
                                        )
                                        .libraryGridCellFrameReporter(assetID: assetID)
                                        .onTapGesture {
                                            guard !isSlimmingMarqueeSelecting else { return }
                                            keyboardFocused = true
                                            let flags = NSEvent.modifierFlags.intersection(
                                                .deviceIndependentFlagsMask
                                            )
                                            model.selectLibrarySlimmingMember(
                                                assetID,
                                                additive: flags.contains(.command),
                                                extendRange: flags.contains(.shift)
                                            )
                                        }
                                        .contextMenu {
                                            moveToRecycleContextMenu(for: assetID)
                                        }
                                    }
                                }
                                .padding(LibraryGridLayout.horizontalPadding)
                            }
                        }
                        .scrollDisabled(isSlimmingMarqueeSelecting)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if model.librarySlimmingClusters.isEmpty, model.hasCompletedLibrarySlimmingScan {
                ContentUnavailableView {
                    Label("无相似结果", systemImage: "checkmark.circle")
                } description: {
                    Text("本次分析未发现相同或相似簇。")
                }
            } else if model.librarySlimmingAnalysisJobID == nil {
                ContentUnavailableView {
                    Label("选择分析记录", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("请先从左侧“分析记录”选择一个任务。")
                }
            } else if model.librarySlimmingClusters.isEmpty {
                ContentUnavailableView {
                    Label("正在准备结果", systemImage: "photo.stack")
                } description: {
                    Text("任务仍在处理，或暂时还没有形成相同、相似照片分组。")
                }
            } else {
                ContentUnavailableView {
                    Label("选择结果分组", systemImage: "photo.stack")
                } description: {
                    Text("请从左侧“结果分组”选择一组照片。")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func moveToRecycleContextMenu(for assetID: UUID) -> some View {
        let moveCount = model.selectedLibrarySlimmingMemberIDs.contains(assetID)
            ? model.selectedLibrarySlimmingMemberIDs.count
            : 1
        Button("移入回收站 (\(moveCount))", role: .destructive) {
            presentMoveToRecycle(for: assetID)
        }
        .disabled(!model.supportsLibrarySlimmingRecycle || model.isMutatingLibrarySlimmingRecycle)
        .persistentHelp("把当前照片或已选照片移入回收站；确认前不会改动原照片。")
    }

    private var recycleBinList: some View {
        Group {
            if model.librarySlimmingRecycleEntries.isEmpty {
                ContentUnavailableView {
                    Label("回收站为空", systemImage: "trash")
                } description: {
                    Text(
                        "文件夹照片由 ImageAll 保留 30 天；Photos 资产遵循 macOS「照片」App 的删除与恢复规则。"
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.librarySlimmingRecycleEntries) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        SlimmingThumbnailCell(model: model, assetID: entry.assetID, isSelected: false)
                            .frame(width: 72, height: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                entry.fileName
                                    ?? entry.originalRelativePath
                                    ?? entry.photosLocalIdentifier
                                    ?? "未命名"
                            )
                                .font(.body.weight(.medium))
                                .lineLimit(2)
                            Text(entry.sourceKind == .file ? "文件夹" : "Photos")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if entry.sourceKind == .photos {
                                Text(
                                    RecycleCountdownFormatter.recordCleanupText(
                                        cleanupAfterMs: entry.purgeAfterMs,
                                        nowMs: Int64(Date().timeIntervalSince1970 * 1000)
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Text("实际保留期限与永久删除由「照片」App 管理")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(
                                    RecycleCountdownFormatter.text(
                                        purgeAfterMs: entry.purgeAfterMs,
                                        nowMs: Int64(Date().timeIntervalSince1970 * 1000)
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        VStack(spacing: 8) {
                            Button(entry.sourceKind == .photos ? "恢复说明" : "恢复") {
                                Task { await model.restoreLibrarySlimmingRecycleEntry(entry.id) }
                            }
                            .disabled(model.isMutatingLibrarySlimmingRecycle)
                            .persistentHelp(
                                entry.sourceKind == .photos
                                    ? "查看如何从 Apple Photos“最近删除”中恢复这张照片。"
                                    : "把这张文件夹照片从 ImageAll 回收站恢复到原位置。"
                            )
                            if entry.sourceKind == .file {
                                Button("立即删除", role: .destructive) {
                                    confirmPurgeEntryID = entry.id
                                }
                                .disabled(model.isMutatingLibrarySlimmingRecycle)
                                .persistentHelp("打开永久删除确认；确认后这张原图将不可恢复。")
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct LibrarySlimmingInspectorView: View {
    @ObservedObject var model: LibraryWorkspaceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("图库瘦身")
                    .font(.headline)
                Text(
                    "查找相同与相似照片。文件夹资产使用 ImageAll 的 30 天回收机制；Photos 资产使用 macOS「照片」App 的系统删除与恢复机制。"
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("分析记录", value: "\(model.librarySlimmingAnalysisJobs.count) 条")
                if let job = model.selectedLibrarySlimmingAnalysisJob {
                    LabeledContent("当前任务", value: job.modeTitle)
                    LabeledContent("任务来源") {
                        Text(job.sourceNamesText)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(job.sourceCaption)
                    }
                    LabeledContent("状态", value: job.stateTitle)
                    LabeledContent("尝试次数", value: job.attemptCaption)
                    LabeledContent("范围", value: "\(job.memberCount) 张")
                    if job.seedCount > 0 {
                        LabeledContent("种子", value: "\(job.seedCount) 张")
                    }
                } else if !model.librarySlimmingSeedAssetIDs.isEmpty {
                    LabeledContent("待用种子", value: "\(model.librarySlimmingSeedAssetIDs.count) 张")
                }
                if model.librarySlimmingAnalyzeMode == .currentFilter
                    || model.librarySlimmingAnalyzeMode == .seeds
                {
                    LabeledContent("筛选", value: model.librarySlimmingFilterScopeSummary)
                }
                LabeledContent("回收站", value: "\(model.librarySlimmingRecycleEntries.count) 项")
                if let caption = model.sourceSimilarityIndexCaption {
                    LabeledContent("来源索引", value: caption.replacingOccurrences(of: "来源索引：", with: ""))
                }
                if let cluster = model.selectedLibrarySlimmingCluster {
                    Divider()
                    LabeledContent("类型", value: cluster.kindTitle)
                    LabeledContent("成员", value: "\(cluster.memberAssetIDs.count)")
                    LabeledContent("已选", value: "\(model.selectedLibrarySlimmingMemberIDs.count)")
                    LabeledContent(
                        "来源",
                        value: model.librarySlimmingSelectedClusterSourceSummary ?? "正在读取…"
                    )
                    LabeledContent("结果", value: cluster.scoreCaption)
                    LabeledContent("技术详情") {
                        Text(cluster.technicalDetailsCaption)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                if model.librarySlimmingPendingCount > 0 {
                    Divider()
                    Text("有 \(model.librarySlimmingPendingCount) 张照片缺少 Feature Print 或 DINOv2，已标为待分析。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SlimmingThumbnailCell: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let assetID: UUID
    var isSelected: Bool = false
    @State private var image: NSImage?
    @State private var loadState: SlimmingThumbnailLoadState = .loading

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    switch loadState {
                    case .loading:
                        ProgressView()
                            .controlSize(.small)
                    case let .placeholder(symbol):
                        Image(systemName: symbol)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            .overlay(alignment: .bottomLeading) {
                if let sourceName = model.librarySlimmingSourceName(for: assetID) {
                    Text(sourceName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.68), in: Capsule())
                        .padding(7)
                        .help("来源：\(sourceName)")
                        .accessibilityLabel("来源：\(sourceName)")
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: loadID) {
            image = nil
            loadState = .loading
            switch await model.loadThumbnailResultWithRetry(assetID: assetID) {
            case let .loaded(data):
                guard !Task.isCancelled else { return }
                if let decoded = LibraryGridThumbnailImageFactory.image(from: data) {
                    image = decoded
                } else {
                    loadState = .placeholder(symbol: "exclamationmark.triangle")
                }
            case .cloudOnly:
                loadState = .placeholder(symbol: "icloud.and.arrow.down")
            case .unavailable:
                loadState = .placeholder(symbol: "photo")
            case .failed:
                loadState = .placeholder(symbol: "exclamationmark.triangle")
            case .cancelled:
                guard !Task.isCancelled else { return }
                loadState = .placeholder(symbol: "photo")
            }
        }
    }

    private var loadID: SlimmingThumbnailLoadID {
        SlimmingThumbnailLoadID(
            assetID: assetID,
            restoreVersion: model.librarySlimmingThumbnailReloadVersion(for: assetID)
        )
    }
}

private enum SlimmingThumbnailLoadState: Equatable {
    case loading
    case placeholder(symbol: String)
}

private struct SlimmingThumbnailLoadID: Hashable {
    let assetID: UUID
    let restoreVersion: Int
}

private struct LibrarySlimmingMoveToRecycleConfirmationSheet: View {
    let selectedCount: Int
    @Binding var suppressFutureConfirmation: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("移入回收站")
                .font(.headline)
            Text(
                "文件夹照片将移入 ImageAll 回收站，默认保留 30 天；Photos 资产将由 macOS 移入系统「最近删除」，恢复和永久删除均由「照片」App 管理。"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Toggle("不再弹出该消息", isOn: $suppressFutureConfirmation)
            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .persistentHelp("关闭窗口并保留所有照片，不执行回收操作。")
                Button("移入回收站（\(selectedCount) 张）", role: .destructive) {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .persistentHelp("确认把列出的照片移入回收站，之后仍可按来源规则恢复。")
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct LibrarySlimmingIdenticalCleanupConfirmationSheet: View {
    let plan: LibrarySlimmingIdenticalCleanupPlan
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    runtimeMetrics
                    charts
                    cleanupRules
                    notices
                }
                .padding(24)
            }

            Divider()

            HStack {
                Text("执行前会再次读取当前资产与来源状态；统计变化时将停止清理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)
                Button(
                    "清理 \(plan.assetIDsToRecycle.count.formatted()) 张",
                    role: .destructive
                ) {
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 820, height: 720)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "trash.square")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
                .frame(width: 42, height: 42)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text("一键清理完全相同照片")
                    .font(.title2.weight(.semibold))
                Text("这是基于当前运行时资产与来源状态生成的实际清理预览。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var runtimeMetrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本次实际统计")
                .font(.headline)
            HStack(spacing: 12) {
                CleanupMetricCard(
                    title: "已核验照片",
                    value: plan.verifiedAssetCount,
                    systemImage: "checkmark.seal",
                    tint: .blue
                )
                CleanupMetricCard(
                    title: "会保留",
                    value: plan.retainedAssetCount,
                    systemImage: "photo.badge.checkmark",
                    tint: .green
                )
                CleanupMetricCard(
                    title: "将清理",
                    value: plan.assetIDsToRecycle.count,
                    systemImage: "trash",
                    tint: .orange
                )
                CleanupMetricCard(
                    title: "处理分组",
                    value: plan.groupCount,
                    systemImage: "square.stack.3d.up",
                    tint: .indigo
                )
            }
            Text("统计由本次预览中逐组核验通过的实际资产 ID 汇总；安全跳过的分组不计入以上数字。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var charts: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("数据概览")
                .font(.headline)
            HStack(alignment: .top, spacing: 16) {
                GroupBox("去留比例") {
                    ZStack {
                        Chart(dispositionData) { item in
                            SectorMark(
                                angle: .value("照片数", item.count),
                                innerRadius: .ratio(0.62),
                                angularInset: 1.5
                            )
                            .foregroundStyle(item.color)
                        }
                        VStack(spacing: 2) {
                            Text(plan.verifiedAssetCount.formatted())
                                .font(.title3.weight(.semibold))
                            Text("张已核验")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .chartLegend(.hidden)
                    .frame(height: 180)

                    HStack {
                        chartLegend(color: .green, title: "保留", count: plan.retainedAssetCount)
                        Spacer()
                        chartLegend(
                            color: .orange,
                            title: "清理",
                            count: plan.assetIDsToRecycle.count
                        )
                    }
                }
                .frame(width: 260)

                GroupBox("完全相同组规模") {
                    Chart(groupSizeData) { item in
                        BarMark(
                            x: .value("每组照片数", item.label),
                            y: .value("分组数", item.groupCount)
                        )
                        .foregroundStyle(.indigo.gradient)
                        .annotation(position: .top) {
                            Text(item.groupCount.formatted())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .chartXAxisLabel("每组照片数")
                    .chartYAxisLabel("分组数")
                    .frame(height: 180)
                    .accessibilityLabel("完全相同组规模分布")
                }
                .frame(maxWidth: .infinity)
            }

            GroupBox("待清理照片来源") {
                Chart(recycleSourceData) { item in
                    BarMark(
                        x: .value("照片数", item.count),
                        y: .value("来源", item.label)
                    )
                    .foregroundStyle(item.color.gradient)
                    .annotation(position: .trailing) {
                        Text("\(item.count.formatted()) 张")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxisLabel("待清理照片数")
                .frame(height: 105)
                .accessibilityLabel("待清理照片来源分布")
            }
        }
    }

    private var cleanupRules: some View {
        GroupBox("删除优先级") {
            HStack(alignment: .top, spacing: 28) {
                Label("1. Apple Photos", systemImage: "photo.on.rectangle")
                Label("2. 来源名较长", systemImage: "textformat.size.larger")
                Label("3. 来源名较短", systemImage: "textformat.size.smaller")
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("同长度时使用稳定顺序，只用于保证每次结果一致；每个已核验分组严格保留一张。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if plan.photosAssetCount > 0 {
            Label(
                "macOS 仍会对全部 Apple Photos 待删项集中显示一次系统确认。",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
        if plan.skippedGroupCount > 0 {
            Label(
                "另有 \(plan.skippedGroupCount.formatted()) 组因成员或来源状态变化已安全跳过，不会删除。",
                systemImage: "shield"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    private var dispositionData: [CleanupChartItem] {
        [
            CleanupChartItem(
                id: "retained",
                label: "保留",
                count: plan.retainedAssetCount,
                color: .green
            ),
            CleanupChartItem(
                id: "recycle",
                label: "清理",
                count: plan.assetIDsToRecycle.count,
                color: .orange
            ),
        ]
    }

    private var recycleSourceData: [CleanupChartItem] {
        [
            CleanupChartItem(
                id: "photos",
                label: "Apple Photos",
                count: plan.photosAssetCount,
                color: .pink
            ),
            CleanupChartItem(
                id: "files",
                label: "文件夹来源",
                count: plan.fileAssetCount,
                color: .blue
            ),
        ]
    }

    private var groupSizeData: [CleanupGroupSizeChartItem] {
        var bucketCounts: [String: Int] = [:]
        for (memberCount, groupCount) in plan.groupSizeHistogram {
            let label = memberCount >= 5 ? "5+" : "\(memberCount)"
            bucketCounts[label, default: 0] += groupCount
        }
        return ["2", "3", "4", "5+"].compactMap { label in
            guard let count = bucketCounts[label], count > 0 else { return nil }
            return CleanupGroupSizeChartItem(
                id: label,
                label: label,
                groupCount: count
            )
        }
    }

    private func chartLegend(color: Color, title: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(title) \(count.formatted())")
                .font(.caption)
        }
    }

    private func cancel() {
        onCancel()
        dismiss()
    }

    private func confirm() {
        onConfirm()
        dismiss()
    }
}

private struct CleanupMetricCard: View {
    let title: String
    let value: Int
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value.formatted())
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(tint.opacity(0.18))
        }
    }
}

private struct CleanupChartItem: Identifiable {
    let id: String
    let label: String
    let count: Int
    let color: Color
}

private struct CleanupGroupSizeChartItem: Identifiable {
    let id: String
    let label: String
    let groupCount: Int
}

private struct LibrarySlimmingThresholdEditor: View {
    @ObservedObject var model: LibraryWorkspaceModel
    @State private var topK: Double = Double(NearDuplicateSceneThresholds.factory.featurePrintRecallTopK)
    @State private var maxL2: Double = NearDuplicateSceneThresholds.factory.featurePrintMaxL2Distance
    @State private var dino: Double = NearDuplicateSceneThresholds.factory.dinoCosineMinSimilarity
    @State private var bucket: Double = Double(
        NearDuplicateSceneThresholds.factory.sceneBucketActivationAssetCount
    )
    @State private var recallMode = NearDuplicateSceneThresholds.factory.featurePrintRecallMode
    @State private var l2Mode = NearDuplicateSceneThresholds.factory.featurePrintL2Mode
    @State private var dinoMode = NearDuplicateSceneThresholds.factory.dinoCosineMode
    @State private var bucketingMode = NearDuplicateSceneThresholds.factory.sceneBucketingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("相似度阈值")
                .font(.headline)
            Text("修改后下次分析生效。极限模式会扩大或收紧场景相似召回；完全相同、视觉重复不受影响。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            labeledSlider("Feature Print Top-K", value: $topK, range: 1...128, step: 1) {
                "\(Int(topK.rounded()))"
            }
            .disabled(recallMode == .allCandidates)
            Toggle("召回全部候选（完整扫描）", isOn: Binding(
                get: { recallMode == .allCandidates },
                set: { recallMode = $0 ? .allCandidates : .topK }
            ))
            .toggleStyle(.checkbox)

            labeledSlider("Feature Print L2 半径", value: $maxL2, range: 0...200, step: 1) {
                String(format: "%.0f", maxL2)
            }
            .disabled(l2Mode == .unlimited)
            Toggle("L2 半径不限", isOn: Binding(
                get: { l2Mode == .unlimited },
                set: { l2Mode = $0 ? .unlimited : .radius }
            ))
            .toggleStyle(.checkbox)

            labeledSlider("DINOv2 余弦下限", value: $dino, range: 0...1, step: 0.01) {
                String(format: "%.2f", dino)
            }
            .disabled(dinoMode == .unlimited)
            Toggle("DINOv2 精排不设下限", isOn: Binding(
                get: { dinoMode == .unlimited },
                set: { dinoMode = $0 ? .unlimited : .minimum }
            ))
            .toggleStyle(.checkbox)

            Picker("按拍摄日分桶", selection: $bucketingMode) {
                Text("始终").tag(SceneBucketingMode.always)
                Text("自动").tag(SceneBucketingMode.automatic)
                Text("从不").tag(SceneBucketingMode.never)
            }
            .pickerStyle(.segmented)

            if bucketingMode == .automatic {
                labeledSlider("分桶激活资产数", value: $bucket, range: 2...10_000, step: 1) {
                    "\(Int(bucket.rounded()))"
                }
            }

            if usesExtremeMode {
                Label(
                    "极限设置可能显著增加分析时间和相似结果数量；“全部候选”会绕过大分组的 64 个候选上限。",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("恢复默认") {
                    model.resetLibrarySlimmingSceneThresholds()
                    syncFromModel()
                }
                .persistentHelp("把相似照片召回和精排参数恢复为 ImageAll 默认值。")
                Spacer()
                Button("应用") {
                    model.updateLibrarySlimmingSceneThresholds(
                        NearDuplicateSceneThresholds(
                            featurePrintRecallTopK: Int(topK.rounded()),
                            featurePrintMaxL2Distance: maxL2,
                            dinoCosineMinSimilarity: dino,
                            sceneBucketActivationAssetCount: Int(bucket.rounded()),
                            featurePrintRecallMode: recallMode,
                            featurePrintL2Mode: l2Mode,
                            dinoCosineMode: dinoMode,
                            sceneBucketingMode: bucketingMode
                        )
                    )
                }
                .keyboardShortcut(.defaultAction)
                .persistentHelp("保存当前相似判断参数；它们会从下一次分析开始生效。")
            }
        }
        .onAppear(perform: syncFromModel)
        .padding(16)
        .frame(width: 440)
    }

    private func syncFromModel() {
        let current = model.librarySlimmingSceneThresholds
        topK = Double(current.featurePrintRecallTopK)
        maxL2 = current.featurePrintMaxL2Distance
        dino = current.dinoCosineMinSimilarity
        bucket = Double(current.sceneBucketActivationAssetCount)
        recallMode = current.featurePrintRecallMode
        l2Mode = current.featurePrintL2Mode
        dinoMode = current.dinoCosineMode
        bucketingMode = current.sceneBucketingMode
    }

    private var usesExtremeMode: Bool {
        recallMode == .allCandidates
            || l2Mode == .unlimited
            || dinoMode == .unlimited
            || bucketingMode != .automatic
    }

    private func labeledSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        caption: @escaping () -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(caption())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
            Slider(value: value, in: range, step: step)
        }
    }
}
