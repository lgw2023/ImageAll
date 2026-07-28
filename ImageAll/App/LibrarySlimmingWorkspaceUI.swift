import AppKit
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
        case .byteIdentical: "相同 · 字节"
        case .perceptualDuplicate: "相同 · 感知"
        case .nearDuplicateScene: "相似 · 场景"
        }
    }

    var scoreCaption: String {
        switch kind {
        case .byteIdentical:
            "SHA-256 一致 · \(modelIdentity.revisionCaption)"
        case .perceptualDuplicate:
            String(
                format: "感知相近 · %.0f%% · %@",
                score * 100,
                modelIdentity.revisionCaption
            )
        case .nearDuplicateScene:
            String(format: "DINOv2 %.2f · %@", score, modelIdentity.revisionCaption)
        }
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
    let memberCount: Int
    let seedCount: Int
    let clusterCount: Int
    let hasResult: Bool
    let createdAtMs: Int64
    let updatedAtMs: Int64

    var modeTitle: String {
        switch mode {
        case .catalog: "当前库"
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
        if let progressCaption = scanProgressCaption {
            parts.append(progressCaption)
        }
        return parts.joined(separator: " · ")
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
        memberCount = summary.memberCount
        seedCount = summary.seedCount
        clusterCount = summary.clusterCount
        hasResult = summary.hasResult
        createdAtMs = summary.createdAtMs
        updatedAtMs = summary.updatedAtMs
    }
}

struct LibrarySlimmingWorkspaceView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let onReturnToLibrary: () -> Void
    @FocusState private var keyboardFocused: Bool
    @State private var confirmMoveToRecycle = false
    @State private var suppressMoveToRecycleConfirmation = false
    @State private var confirmPurgeEntryID: UUID?

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
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if model.isAnalyzingLibrarySlimming, let progress = model.librarySlimmingScanProgress {
                progressBanner(progress)
                Divider()
            } else if let message = model.librarySlimmingStatusMessage {
                statusBanner(message)
                Divider()
            }

            Group {
                if model.librarySlimmingWorkspaceTab == .recycleBin {
                    recycleBinList
                } else {
                    HSplitView {
                        analysisHistoryAndClusters
                            .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                        clusterDetail
                            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("图库瘦身")
        .accessibilityLabel("图库瘦身工作台")
        .focusable()
        .focused($keyboardFocused)
        .focusEffectDisabled()
        .onAppear { keyboardFocused = true }
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
            Button("取消", role: .cancel) {
                confirmPurgeEntryID = nil
            }
        } message: {
            Text("此操作不可撤销，将删除回收站中的原图文件。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.analyzeLibrarySlimming(mode: .catalog) }
            } label: {
                if model.isAnalyzingLibrarySlimming, model.librarySlimmingAnalyzeMode == .catalog {
                    ProgressView()
                        .controlSize(.small)
                    Text("分析中…")
                } else {
                    Label("分析当前库", systemImage: "wand.and.stars")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.supportsLibrarySlimming)
            .help("发起新的全库分析；不会取消已有分析记录")

            Button {
                Task { await model.analyzeLibrarySlimming(mode: .currentFilter) }
            } label: {
                Label("分析当前筛选", systemImage: "line.3.horizontal.decrease.circle")
            }
            .disabled(
                !model.supportsLibrarySlimming
                    || !model.hasLibrarySlimmingFilterScope
            )
            .help("使用侧栏目的地与图库当前标签/来源/搜索筛选作为分析宇宙；不会取消已有分析记录")

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
                .help("以当前种子发起新的检索任务；不会取消已有分析记录")
            }

            if model.canPauseLibrarySlimmingAnalysis {
                Button {
                    Task { await model.pauseLibrarySlimmingAnalysis() }
                } label: {
                    Label("暂停当前", systemImage: "pause.fill")
                }
                .help("暂停当前选中的分析任务")
            } else if model.canResumeLibrarySlimmingAnalysis {
                Button {
                    Task { await model.resumeLibrarySlimmingAnalysis() }
                } label: {
                    Label("继续当前", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .help("从已保存进度继续当前选中的分析任务")
            }

            if model.canDeleteSelectedLibrarySlimmingAnalysisJob {
                Button(role: .destructive) {
                    if let id = model.librarySlimmingAnalysisJobID {
                        Task { await model.deleteLibrarySlimmingAnalysisJob(id) }
                    }
                } label: {
                    Label("删除记录", systemImage: "trash")
                }
                .help("永久删除当前选中的分析任务与结果")
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
                .help(
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
                        Label("初始化来源索引", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
                .disabled(!model.canInitializeSourceSimilarityIndex)
                .help("为当前选中的单个来源建立 Feature Print 邻域索引，加速后续按种子检索")

                if let caption = model.sourceSimilarityIndexCaption {
                    Text(caption)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            if model.supportsLibrarySlimmingThresholds {
                Button {
                    model.showsLibrarySlimmingThresholdEditor.toggle()
                } label: {
                    Label("阈值", systemImage: "slider.horizontal.3")
                }
                .popover(isPresented: $model.showsLibrarySlimmingThresholdEditor, arrowEdge: .bottom) {
                    LibrarySlimmingThresholdEditor(model: model)
                        .frame(width: 320)
                        .padding(16)
                }
                .help("调整相似召回与精排阈值；下次分析生效")
            }

            Spacer()

            if model.librarySlimmingAnalyzeMode == .currentFilter
                || model.librarySlimmingAnalyzeMode == .seeds
            {
                Text(model.librarySlimmingFilterScopeSummary)
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .lineLimit(2)
                    .help("当前筛选范围")
            }

            Text(modeCaption)
                .foregroundStyle(.tertiary)
                .font(.caption)

            Button("返回图库", systemImage: "photo.on.rectangle") {
                onReturnToLibrary()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var modeCaption: String {
        switch model.librarySlimmingAnalyzeMode {
        case .catalog: "模式：当前库"
        case .currentFilter: "模式：当前筛选"
        case .seeds: "模式：种子检索"
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

    private var analysisHistoryAndClusters: some View {
        List(selection: Binding(
            get: { model.librarySlimmingAnalysisJobID },
            set: { model.selectLibrarySlimmingAnalysisJob($0) }
        )) {
            Section("分析记录") {
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
                            }
                        }
                        .accessibilityLabel(
                            "\(job.modeTitle)，\(job.stateTitle)，\(job.detailCaption)"
                        )
                    }
                }
            }

            Section("簇（相同优先）") {
                if model.librarySlimmingAnalysisJobID == nil {
                    Text("选择左侧一条分析记录查看结果。")
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
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selectLibrarySlimmingCluster(cluster.id)
                        }
                        .listRowBackground(
                            model.selectedLibrarySlimmingClusterID == cluster.id
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                        .accessibilityLabel("\(cluster.kindTitle)，\(cluster.memberAssetIDs.count) 张")
                    }
                }
            }
        }
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

                    Text(
                        "成员 \(cluster.memberAssetIDs.count) · 已选 \(model.selectedLibrarySlimmingMemberIDs.count) · ⌘点击多选"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                    GeometryReader { proxy in
                        ScrollView {
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
                                    .onTapGesture {
                                        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                                        model.selectLibrarySlimmingMember(
                                            assetID,
                                            additive: flags.contains(.command)
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
                }
            } else if model.librarySlimmingClusters.isEmpty, model.hasCompletedLibrarySlimmingScan {
                ContentUnavailableView {
                    Label("无相似结果", systemImage: "checkmark.circle")
                } description: {
                    Text("本次分析未发现相同或相似簇。")
                }
            } else if model.librarySlimmingClusters.isEmpty {
                Color.clear
            } else {
                ContentUnavailableView("选择一个簇", systemImage: "photo.stack")
            }
        }
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
                            if entry.sourceKind == .file {
                                Button("立即删除", role: .destructive) {
                                    confirmPurgeEntryID = entry.id
                                }
                                .disabled(model.isMutatingLibrarySlimmingRecycle)
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
                LabeledContent("状态", value: job.stateTitle)
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
                LabeledContent("分数", value: cluster.scoreCaption)
            }
            if model.librarySlimmingPendingCount > 0 {
                Divider()
                Text("有 \(model.librarySlimmingPendingCount) 张照片缺少 Feature Print 或 DINOv2，已标为待分析。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SlimmingThumbnailCell: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let assetID: UUID
    var isSelected: Bool = false
    @State private var image: NSImage?

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
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: assetID) {
            let data = await model.thumbnailData(assetID: assetID)
            if let data {
                image = LibraryGridThumbnailImageFactory.image(from: data)
            }
        }
    }
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
                Button("移入回收站（\(selectedCount) 张）", role: .destructive) {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct LibrarySlimmingThresholdEditor: View {
    @ObservedObject var model: LibraryWorkspaceModel
    @State private var topK: Double = Double(NearDuplicateSceneThresholds.factory.featurePrintRecallTopK)
    @State private var maxL2: Double = NearDuplicateSceneThresholds.factory.featurePrintMaxL2Distance
    @State private var dino: Double = NearDuplicateSceneThresholds.factory.dinoCosineMinSimilarity
    @State private var bucket: Double = Double(
        NearDuplicateSceneThresholds.factory.sceneBucketActivationAssetCount
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("相似度阈值")
                .font(.headline)
            Text("修改后下次分析生效。分桶仅作用于「当前库 / 当前筛选」的场景相似；相同档与种子检索不受分桶限制。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            labeledSlider("Feature Print Top-K", value: $topK, range: 4...64, step: 1) {
                "\(Int(topK.rounded()))"
            }
            labeledSlider("Feature Print L2 半径", value: $maxL2, range: 5...80, step: 1) {
                String(format: "%.0f", maxL2)
            }
            labeledSlider("DINOv2 余弦下限", value: $dino, range: 0.70...0.99, step: 0.01) {
                String(format: "%.2f", dino)
            }
            labeledSlider("分桶激活资产数", value: $bucket, range: 16...2000, step: 16) {
                "\(Int(bucket.rounded()))"
            }

            HStack {
                Button("恢复默认") {
                    model.resetLibrarySlimmingSceneThresholds()
                    syncFromModel()
                }
                Spacer()
                Button("应用") {
                    model.updateLibrarySlimmingSceneThresholds(
                        NearDuplicateSceneThresholds(
                            featurePrintRecallTopK: Int(topK.rounded()),
                            featurePrintMaxL2Distance: maxL2,
                            dinoCosineMinSimilarity: dino,
                            sceneBucketActivationAssetCount: Int(bucket.rounded())
                        )
                    )
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear(perform: syncFromModel)
    }

    private func syncFromModel() {
        let current = model.librarySlimmingSceneThresholds
        topK = Double(current.featurePrintRecallTopK)
        maxL2 = current.featurePrintMaxL2Distance
        dino = current.dinoCosineMinSimilarity
        bucket = Double(current.sceneBucketActivationAssetCount)
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
