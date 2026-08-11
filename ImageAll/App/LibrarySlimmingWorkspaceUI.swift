import AppKit
import Charts
import SwiftUI

struct LibrarySlimmingClusterPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let mediaKind: MediaKind
    let kind: SlimmingClusterKind
    let memberAssetIDs: [UUID]
    let representativeAssetID: UUID
    let score: Double
    let modelIdentity: SlimmingVectorModelIdentity
    let isSeedOnlyResult: Bool
    let originalMemberCount: Int
    let isHistoricalProcessedRecord: Bool

    var memberCountCaption: String {
        if isHistoricalProcessedRecord {
            return "原 \(originalMemberCount) 张 · 现 \(memberAssetIDs.count) 张可查看"
        }
        return "\(memberAssetIDs.count) 张"
    }

    var kindTitle: String {
        if isSeedOnlyResult {
            return mediaKind == .video ? "种子视频" : "种子照片"
        }
        if mediaKind == .video {
            switch kind {
            case .byteIdentical: return "完全相同视频"
            case .perceptualDuplicate: return "代表缩略图重复"
            case .nearDuplicateScene: return "相似视频（按代表缩略图）"
            }
        }
        return switch kind {
        case .byteIdentical: "完全相同"
        case .perceptualDuplicate: "视觉重复"
        case .nearDuplicateScene: "同场景相似"
        }
    }

    var scoreCaption: String {
        if isSeedOnlyResult {
            return "未找到相似项 · 可继续选择操作"
        }
        if mediaKind == .video {
            switch kind {
            case .byteIdentical:
                return "完整视频文件一致"
            case .perceptualDuplicate:
                return String(format: "代表缩略图匹配度 %.0f%%", score * 100)
            case .nearDuplicateScene:
                return String(format: "代表缩略图相似度 %.0f%%", score * 100)
            }
        }
        return switch kind {
        case .byteIdentical:
            "内容完全一致"
        case .perceptualDuplicate:
            String(format: "画面高度相似 · 匹配度 %.0f%%", score * 100)
        case .nearDuplicateScene:
            String(format: "同场景相似度 %.0f%%", score * 100)
        }
    }

    var technicalDetailsCaption: String {
        if isSeedOnlyResult {
            return "种子检索未形成相似分组"
        }
        return switch kind {
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

    init(_ cluster: SlimmingCluster, mediaKind: MediaKind = .image) {
        id = cluster.id
        self.mediaKind = mediaKind
        kind = cluster.kind
        memberAssetIDs = cluster.memberAssetIDs
        representativeAssetID = cluster.representativeAssetID
        score = cluster.score
        modelIdentity = cluster.modelIdentity
        isSeedOnlyResult = false
        originalMemberCount = cluster.memberAssetIDs.count
        isHistoricalProcessedRecord = false
    }

    init(
        historical cluster: SlimmingCluster,
        availableMemberAssetIDs: [UUID],
        originalMemberCount: Int,
        mediaKind: MediaKind = .image
    ) {
        id = cluster.id
        self.mediaKind = mediaKind
        kind = cluster.kind
        memberAssetIDs = availableMemberAssetIDs
        representativeAssetID = availableMemberAssetIDs.contains(cluster.representativeAssetID)
            ? cluster.representativeAssetID
            : availableMemberAssetIDs.first ?? cluster.representativeAssetID
        score = cluster.score
        modelIdentity = cluster.modelIdentity
        isSeedOnlyResult = false
        self.originalMemberCount = max(originalMemberCount, availableMemberAssetIDs.count)
        isHistoricalProcessedRecord = true
    }

    init(seedAssetIDs: [UUID], mediaKind: MediaKind) {
        precondition(!seedAssetIDs.isEmpty)
        let members = Array(Set(seedAssetIDs)).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        id = NearDuplicateSceneClusterService.stableClusterID(
            kind: .nearDuplicateScene,
            members: members
        )
        self.mediaKind = mediaKind
        kind = .nearDuplicateScene
        memberAssetIDs = members
        representativeAssetID = members[0]
        score = 1
        modelIdentity = .featurePrintOnly
        isSeedOnlyResult = true
        originalMemberCount = members.count
        isHistoricalProcessedRecord = false
    }

    func retainingMemberAssetIDs(
        _ members: [UUID],
        allowBelowMinimum: Bool = false
    ) -> LibrarySlimmingClusterPresentation? {
        if isSeedOnlyResult {
            guard !members.isEmpty else { return nil }
            return LibrarySlimmingClusterPresentation(
                seedAssetIDs: members,
                mediaKind: mediaKind
            )
        }
        if isHistoricalProcessedRecord {
            return LibrarySlimmingClusterPresentation(
                historical: cluster,
                availableMemberAssetIDs: members,
                originalMemberCount: originalMemberCount,
                mediaKind: mediaKind
            )
        }
        guard members.count >= 2 || (allowBelowMinimum && !members.isEmpty) else {
            return nil
        }
        return LibrarySlimmingClusterPresentation(
            SlimmingCluster(
                id: id,
                kind: kind,
                memberAssetIDs: members,
                representativeAssetID: members.contains(representativeAssetID)
                    ? representativeAssetID
                    : members[0],
                score: score,
                modelIdentity: modelIdentity
            ),
            mediaKind: mediaKind
        )
    }
}

struct LibrarySlimmingAnalysisJobPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let mode: LibrarySlimmingAnalyzeMode
    let mediaKind: MediaKind
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
        let unit = mediaKind == .video ? "个视频" : "张照片"
        var parts: [String] = ["\(memberCount) \(unit)"]
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
        mediaKind = summary.mediaKind
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

enum LibrarySlimmingWorkspaceLayout {
    static let navigatorMinimumWidth: CGFloat = 196
    static let navigatorMaximumWidth: CGFloat = 244
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

enum LibrarySlimmingMoveConfirmationAction {
    static func confirm(
        canPersistSkip: Bool,
        suppressFutureConfirmation: Bool,
        setSkipsConfirmation: (Bool) -> Void,
        submit: () -> Void
    ) {
        if canPersistSkip, suppressFutureConfirmation {
            setSkipsConfirmation(true)
        }
        submit()
    }
}

enum LibrarySlimmingClusterPagination {
    static let initialLimit = 100
    static let pageSize = 100

    static func visibleCount(totalCount: Int, limit: Int) -> Int {
        min(max(limit, 0), max(totalCount, 0))
    }

    static func nextLimit(currentLimit: Int, totalCount: Int) -> Int {
        min(max(totalCount, 0), max(currentLimit, 0) + pageSize)
    }
}

enum LibrarySlimmingClusterQueueScope: String, CaseIterable, Identifiable, Sendable {
    case pending
    case confirmed
    case ignored

    var id: Self { self }

    var title: String {
        switch self {
        case .pending: "待处理"
        case .confirmed: "已确认"
        case .ignored: "已忽略"
        }
    }

    var systemImage: String {
        switch self {
        case .pending: "tray"
        case .confirmed: "checkmark.circle"
        case .ignored: "eye.slash"
        }
    }

    func matches(_ disposition: LibrarySlimmingClusterReviewDisposition?) -> Bool {
        switch self {
        case .pending: disposition == nil
        case .confirmed: disposition == .confirmed
        case .ignored: disposition == .ignored
        }
    }
}

enum LibrarySlimmingRecyclePagination {
    static let initialLimit = 100
    static let pageSize = 100

    static func visibleCount(totalCount: Int, limit: Int) -> Int {
        min(max(limit, 0), max(totalCount, 0))
    }

    static func nextLimit(currentLimit: Int, totalCount: Int) -> Int {
        min(max(totalCount, 0), max(currentLimit, 0) + pageSize)
    }
}

enum LibrarySlimmingRecycleScope: String, CaseIterable, Identifiable {
    case all
    case photos
    case files
    case attention

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "全部"
        case .photos: "Photos"
        case .files: "文件夹"
        case .attention: "待处理"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .photos: "photo.on.rectangle.angled"
        case .files: "folder"
        case .attention: "exclamationmark.triangle"
        }
    }

    func matches(_ entry: RecycleEntryRecord) -> Bool {
        switch self {
        case .all: true
        case .photos: entry.sourceKind == .photos
        case .files: entry.sourceKind == .file
        case .attention: entry.state != .recycled
        }
    }

    func filtered(_ entries: [RecycleEntryRecord]) -> [RecycleEntryRecord] {
        guard self != .all else { return entries }
        return entries.filter(matches)
    }

    func count(in entries: [RecycleEntryRecord]) -> Int {
        guard self != .all else { return entries.count }
        return entries.lazy.filter(matches).count
    }
}

private struct LibrarySlimmingClusterListRefreshModifier: ViewModifier {
    @ObservedObject var model: LibraryWorkspaceModel
    @Binding var clusterLimit: Int

    func body(content: Content) -> some View {
        content
            .onChange(of: model.visibleLibrarySlimmingClusters.map(\.id)) { _, _ in
                model.ensureLibrarySlimmingClusterSelection()
            }
            .onChange(of: model.librarySlimmingAnalysisJobID) { _, _ in
                clusterLimit = LibrarySlimmingClusterPagination.initialLimit
            }
            .onChange(of: model.librarySlimmingClusterQueueScope) { _, _ in
                clusterLimit = LibrarySlimmingClusterPagination.initialLimit
            }
    }
}

struct LibrarySlimmingWorkspaceView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let onReturnToLibrary: () -> Void
    @FocusState private var keyboardFocused: Bool
    @State private var confirmMoveToRecycle = false
    @State private var confirmFastDelete = false
    @State private var suppressMoveToRecycleConfirmation = false
    @State private var confirmPurgeEntryID: UUID?
    @State private var identicalCleanupPlan: LibrarySlimmingIdenticalCleanupPlan?
    @State private var slimmingGridCellFrames = LibraryGridCellFrameStore()
    @State private var isSlimmingMarqueeSelecting = false
    @State private var librarySlimmingClusterLimit =
        LibrarySlimmingClusterPagination.initialLimit
    @State private var librarySlimmingRecycleLimit =
        LibrarySlimmingRecyclePagination.initialLimit
    @State private var librarySlimmingRecycleScope = LibrarySlimmingRecycleScope.all
    @State private var showsAnalysisNavigator = true

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                compactCommandBar
                Divider()

                // Lock the workspace body to the remaining height so long Lists scroll.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if model.librarySlimmingWorkspaceTab == .recycleBin {
                            recycleBinList
                        } else {
                            GeometryReader { proxy in
                                HStack(spacing: 0) {
                                    if showsAnalysisNavigator {
                                        analysisHistoryAndClusters
                                            .frame(
                                                width: LibrarySlimmingWorkspaceLayout.navigatorWidth(
                                                    availableWidth: proxy.size.width
                                                ),
                                                height: proxy.size.height
                                            )
                                        Divider()
                                    }
                                    clusterDetail
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                .animation(.easeInOut(duration: 0.16), value: showsAnalysisNavigator)
                            }
                        }
                    }
            }

            if let navigation = model.librarySlimmingPreviewNavigation {
                LibrarySlimmingQuickLookView(
                    model: model,
                    navigation: navigation,
                    onRequestDelete: requestFastDeleteFromPreview
                )
                .transition(.opacity)
                .zIndex(10)
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
        .modifier(
            LibrarySlimmingClusterListRefreshModifier(
                model: model,
                clusterLimit: $librarySlimmingClusterLimit
            )
        )
        .onChange(of: model.selectedLibrarySlimmingClusterID) { _, _ in
            model.ensureLibrarySlimmingClusterSelection()
        }
        .onChange(of: model.librarySlimmingRecycleEntries.count) { _, _ in
            librarySlimmingRecycleLimit = LibrarySlimmingRecyclePagination.initialLimit
        }
        .onChange(of: model.librarySlimmingRecycleSearchText) { _, _ in
            librarySlimmingRecycleLimit = LibrarySlimmingRecyclePagination.initialLimit
        }
        .onChange(of: model.librarySlimmingRecycleSourceFilterID) { _, _ in
            librarySlimmingRecycleLimit = LibrarySlimmingRecyclePagination.initialLimit
        }
        .onChange(of: librarySlimmingRecycleScope) { _, _ in
            librarySlimmingRecycleLimit = LibrarySlimmingRecyclePagination.initialLimit
        }
        .onChange(of: model.librarySlimmingPreviewAssetID) { _, _ in
            keyboardFocused = true
        }
        .onKeyPress(.space, action: handlePreviewSpaceKeyPress)
        .onKeyPress(.escape, action: handlePreviewEscapeKeyPress)
        .onKeyPress(
            keys: [.leftArrow, .rightArrow],
            action: handlePreviewNavigationKeyPress
        )
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
                mediaKind: model.selectedMediaKind,
                favoriteCount: model.selectedLibrarySlimmingFavoriteProtectionCount,
                allowsSuppressingFutureConfirmation:
                    model.canPersistentlySkipSelectedLibrarySlimmingMoveConfirmation,
                suppressFutureConfirmation: $suppressMoveToRecycleConfirmation,
                onConfirm: {
                    confirmMoveToRecycle = false
                    LibrarySlimmingMoveConfirmationAction.confirm(
                        canPersistSkip:
                            model.canPersistentlySkipSelectedLibrarySlimmingMoveConfirmation,
                        suppressFutureConfirmation: suppressMoveToRecycleConfirmation,
                        setSkipsConfirmation: {
                            model.setSkipsLibrarySlimmingMoveToRecycleConfirmation($0)
                        },
                        submit: {
                            Task { await model.moveSelectedLibrarySlimmingMembersToRecycle() }
                        }
                    )
                },
                onCancel: {
                    confirmMoveToRecycle = false
                }
            )
        }
        .sheet(isPresented: $confirmFastDelete) {
            LibraryFastDeleteConfirmationSheet(
                selectedCount: model.selectedLibrarySlimmingMemberIDs.count,
                mediaKind: model.selectedMediaKind,
                favoriteCount: model.selectedLibrarySlimmingFavoriteProtectionCount,
                onConfirm: {
                    confirmFastDelete = false
                    Task { await model.deleteSelectedLibrarySlimmingMembersImmediately() }
                },
                onCancel: {
                    confirmFastDelete = false
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
                    onFastDelete: {
                        identicalCleanupPlan = nil
                        Task {
                            await model.deleteLibrarySlimmingIdenticalRedundancyImmediately(
                                plan: plan
                            )
                        }
                    },
                    onRecoverableRecycle: {
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
        .sheet(
            isPresented: Binding(
                get: { model.librarySlimmingIdenticalCleanupPostDeleteReport != nil },
                set: {
                    if !$0 {
                        model.dismissLibrarySlimmingIdenticalCleanupPostDeleteReport()
                    }
                }
            )
        ) {
            if let report = model.librarySlimmingIdenticalCleanupPostDeleteReport {
                LibrarySlimmingIdenticalCleanupVerificationSheet(
                    report: report,
                    onDismiss: {
                        model.dismissLibrarySlimmingIdenticalCleanupPostDeleteReport()
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
            .persistentHelp(
                model.selectedMediaKind == .video
                    ? "永久删除回收站中的这个文件夹视频；此操作不可撤销。"
                    : "永久删除回收站中的这张文件夹原图；此操作不可撤销。"
            )
            Button("取消", role: .cancel) {
                confirmPurgeEntryID = nil
            }
            .persistentHelp("关闭确认窗口并保留回收站中的媒体。")
        } message: {
            if let entryID = confirmPurgeEntryID,
               let entry = model.librarySlimmingRecycleEntries.first(where: { $0.id == entryID }),
               model.favoriteState(for: entry.assetID).isDeletionProtected
            {
                Text("此项目有红心保护。再次确认仍会永久删除原始媒体文件，且不可撤销。")
            } else {
                Text("此操作不可撤销，将删除回收站中的原始媒体文件。")
            }
        }
    }

    private var compactCommandBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Picker("媒体", selection: Binding(
                    get: { model.selectedMediaKind },
                    set: { mediaKind in
                        Task { await model.setLibrarySlimmingWorkspaceMediaKind(mediaKind) }
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
                .accessibilityIdentifier("librarySlimmingMediaKindTabs")
                .persistentHelp("切换照片和视频；分析任务、结果和回收记录不会跨媒体混用。")

                Picker("工作台", selection: Binding(
                    get: { model.librarySlimmingWorkspaceTab },
                    set: { model.selectLibrarySlimmingWorkspaceTab($0) }
                )) {
                    Text("分析结果").tag(LibrarySlimmingWorkspaceTab.clusters)
                    Text("回收站").tag(LibrarySlimmingWorkspaceTab.recycleBin)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 154)
                .persistentHelp("切换分析结果和 ImageAll 回收站；不会启动、删除或恢复任务。")

                if model.librarySlimmingWorkspaceTab == .clusters {
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

                    catalogSourceMenu
                    analysisOptionsMenu

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
                                ?? "为当前分析结果的每个完全相同分组保留一个，并预览其余媒体的批量回收方案。"
                        )
                    }

                    if model.selectedLibrarySlimmingCluster != nil {
                        Button(role: .destructive) {
                            requestFastDeleteConfirmation()
                        } label: {
                            if model.isMutatingLibrarySlimmingRecycle {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在处理…")
                            } else if model.selectedLibrarySlimmingMemberIDs.isEmpty {
                                Label("快速清理", systemImage: "trash.fill")
                            } else {
                                Label(
                                    "快速清理 (\(model.selectedLibrarySlimmingMemberIDs.count))",
                                    systemImage: "trash.fill"
                                )
                            }
                        }
                        .disabled(!model.canMoveSelectedLibrarySlimmingMembersToRecycle)
                        .persistentHelp(
                            model.librarySlimmingMoveToRecycleDisabledReason
                                ?? "文件夹媒体将永久删除，使来源空间立即可回收；Photos 使用系统“最近删除”（⌫ / Delete）"
                        )

                        Menu {
                            Button("移入可恢复回收站") {
                                requestMoveToRecycleConfirmation()
                            }
                            .persistentHelp("文件夹媒体复制到 ImageAll 回收站后再删除源文件，跨磁盘时可能较慢。")
                        } label: {
                            Label("更多", systemImage: "ellipsis.circle")
                        }
                        .disabled(!model.canMoveSelectedLibrarySlimmingMembersToRecycle)
                        .persistentHelp("选择保留恢复能力的安全回收方式。")
                    }

                    Button {
                        showsAnalysisNavigator.toggle()
                    } label: {
                        Label(
                            showsAnalysisNavigator ? "隐藏记录" : "显示记录",
                            systemImage: "rectangle.leadinghalf.inset.filled"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(showsAnalysisNavigator ? "隐藏分析记录" : "显示分析记录")
                    .persistentHelp(
                        showsAnalysisNavigator
                            ? "隐藏分析记录与结果分组栏，让照片网格使用全部宽度。"
                            : "显示分析记录与结果分组栏。"
                    )
                }

                Spacer(minLength: 12)
                if model.librarySlimmingWorkspaceTab == .recycleBin {
                    Label(
                        "\(model.librarySlimmingRecycleEntries.count.formatted()) 项",
                        systemImage: "tray.full"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        "回收站共有 \(model.librarySlimmingRecycleEntries.count) 项"
                    )
                } else {
                    inlineActivityStatus
                }

                Button("返回图库", systemImage: "photo.on.rectangle") {
                    onReturnToLibrary()
                }
                .persistentHelp("退出图库瘦身工作区并返回图库；已有分析任务不会被删除。")
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var catalogSourceMenu: some View {
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
                        get: { model.isLibrarySlimmingCatalogSourceIncluded(source.id) },
                        set: { model.setLibrarySlimmingCatalogSourceIncluded(source.id, $0) }
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
        .persistentHelp("选择一个或多个要分析的来源；只列出当前可用来源。")
    }

    private var analysisOptionsMenu: some View {
        Menu {
            Button {
                Task { await model.analyzeLibrarySlimming(mode: .currentFilter) }
            } label: {
                Label(
                    model.librarySlimmingCurrentFilterActionTitle,
                    systemImage: "line.3.horizontal.decrease.circle"
                )
            }
            .disabled(!model.supportsLibrarySlimming || !model.hasLibrarySlimmingFilterScope)

            if !model.librarySlimmingSeedAssetIDs.isEmpty {
                Button {
                    Task { await model.analyzeLibrarySlimming(mode: .seeds) }
                } label: {
                    Label(
                        "按种子查找（\(model.librarySlimmingSeedAssetIDs.count)）",
                        systemImage: "target"
                    )
                }
                .disabled(!model.supportsLibrarySlimming)
            }

            Divider()

            if model.canPauseLibrarySlimmingAnalysis {
                Button("暂停当前", systemImage: "pause.fill") {
                    Task { await model.pauseLibrarySlimmingAnalysis() }
                }
            } else if model.canResumeLibrarySlimmingAnalysis {
                Button("继续当前", systemImage: "play.fill") {
                    Task { await model.resumeLibrarySlimmingAnalysis() }
                }
            }

            if model.canDeleteSelectedLibrarySlimmingAnalysisJob {
                Button("删除当前记录", systemImage: "trash", role: .destructive) {
                    if let id = model.librarySlimmingAnalysisJobID {
                        Task { await model.deleteLibrarySlimmingAnalysisJob(id) }
                    }
                }
            }

            Divider()

            if model.supportsLibrarySlimmingThresholds {
                Button("调整相似阈值…", systemImage: "slider.horizontal.3") {
                    model.showsLibrarySlimmingThresholdEditor = true
                }
            }

            Button("刷新来源", systemImage: "arrow.clockwise") {
                Task { await model.refreshLibrarySlimmingCatalog() }
            }
            .disabled(!model.canRefreshLibrarySlimmingCatalog)

            if model.supportsSourceSimilarityIndex {
                Button(
                    model.isInitializingSourceSimilarityIndex ? "正在初始化来源索引…" : "初始化来源索引",
                    systemImage: "point.3.connected.trianglepath.dotted"
                ) {
                    Task { await model.initializeSourceSimilarityIndex() }
                }
                .disabled(!model.canInitializeSourceSimilarityIndex)
            }
        } label: {
            Label("分析选项", systemImage: "ellipsis.circle")
        }
        .popover(
            isPresented: $model.showsLibrarySlimmingThresholdEditor,
            arrowEdge: .bottom
        ) {
            LibrarySlimmingThresholdEditor(model: model)
                .frame(width: 320)
                .padding(16)
        }
        .persistentHelp("当前筛选、种子检索、任务控制、阈值、刷新和来源索引。")
    }

    @ViewBuilder
    private var inlineActivityStatus: some View {
        if model.isAnalyzingLibrarySlimming, let progress = model.librarySlimmingScanProgress {
            HStack(spacing: 6) {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 54)
                Text(progress.caption)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(progress.caption)
        } else if let message = model.librarySlimmingRecycleActionMessage
                    ?? model.librarySlimmingStatusMessage
        {
            let isFailure = message.contains("失败") || message.hasPrefix("未移动")
            Label(
                message,
                systemImage: isFailure
                    ? "exclamationmark.triangle.fill"
                    : "info.circle"
            )
            .font(.caption)
            .foregroundStyle(isFailure ? Color.red : Color.secondary)
            .lineLimit(1)
            .frame(maxWidth: 250, alignment: .trailing)
            .help(message)
            .accessibilityLabel(message)
        } else if model.librarySlimmingPendingCount > 0 {
            Text(
                model.selectedMediaKind == .video
                    ? "待分析 \(model.librarySlimmingPendingCount) 个"
                    : "待分析 \(model.librarySlimmingPendingCount) 张"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var allLibrarySlimmingCatalogSourcesSelected: Bool {
        !model.activeLibrarySlimmingSources.isEmpty
            && model.activeLibrarySlimmingSources.allSatisfy {
                model.isLibrarySlimmingCatalogSourceIncluded($0.id)
            }
    }

    private func handleMoveToRecycleKeyPress() -> KeyPress.Result {
        if model.librarySlimmingPreviewAssetID != nil {
            requestFastDeleteFromPreview()
            return .handled
        }
        guard model.librarySlimmingWorkspaceTab == .clusters,
              model.canMoveSelectedLibrarySlimmingMembersToRecycle
        else { return .ignored }
        requestFastDeleteConfirmation()
        return .handled
    }

    private func handlePreviewSpaceKeyPress() -> KeyPress.Result {
        guard model.librarySlimmingWorkspaceTab == .clusters,
              model.librarySlimmingPreviewAssetID != nil
                || !model.selectedLibrarySlimmingMemberIDs.isEmpty
        else { return .ignored }
        model.toggleLibrarySlimmingPreview()
        return .handled
    }

    private func handlePreviewEscapeKeyPress() -> KeyPress.Result {
        guard model.librarySlimmingPreviewAssetID != nil else { return .ignored }
        model.closeLibrarySlimmingPreview()
        return .handled
    }

    private func handlePreviewNavigationKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard model.librarySlimmingPreviewAssetID != nil else { return .ignored }
        switch keyPress.key {
        case .leftArrow:
            model.moveLibrarySlimmingPreview(by: -1)
        case .rightArrow:
            model.moveLibrarySlimmingPreview(by: 1)
        default:
            return .ignored
        }
        return .handled
    }

    private func requestFastDeleteFromPreview() {
        guard model.prepareLibrarySlimmingPreviewDeletion() else { return }
        confirmFastDelete = true
    }

    private func requestFastDeleteConfirmation() {
        guard model.canMoveSelectedLibrarySlimmingMembersToRecycle else { return }
        confirmFastDelete = true
    }

    private func requestMoveToRecycleConfirmation() {
        guard model.canMoveSelectedLibrarySlimmingMembersToRecycle else { return }
        if !model.shouldConfirmSelectedLibrarySlimmingMoveToRecycle {
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

    private var analysisHistoryAndClusters: some View {
        let visibleClusters = model.visibleLibrarySlimmingClusters
        return List(selection: Binding(
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
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(job.modeTitle)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(job.stateTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(job.detailCaption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(job.sourceCaption)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(job.sourceCaption)
                        }
                        .tag(Optional(job.id))
                        .contextMenu {
                            if job.state != .running {
                                Button("删除记录", role: .destructive) {
                                    Task { await model.deleteLibrarySlimmingAnalysisJob(job.id) }
                                }
                                .persistentHelp("永久删除这条分析任务记录和结果；不会删除任何原始媒体。")
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
                ForEach(LibrarySlimmingClusterQueueScope.allCases) { scope in
                    Button {
                        model.selectLibrarySlimmingClusterQueueScope(scope)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: scope.systemImage)
                                .frame(width: 16)
                                .foregroundStyle(
                                    model.librarySlimmingClusterQueueScope == scope
                                        ? Color.accentColor
                                        : Color.secondary
                                )
                            Text(scope.title)
                                .font(.subheadline.weight(
                                    model.librarySlimmingClusterQueueScope == scope
                                        ? .semibold
                                        : .regular
                                ))
                            Spacer()
                            Text(model.librarySlimmingClusterCount(in: scope).formatted())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        model.librarySlimmingClusterQueueScope == scope
                            ? Color.accentColor.opacity(0.09)
                            : Color.clear
                    )
                    .accessibilityLabel(
                        "\(scope.title)，\(model.librarySlimmingClusterCount(in: scope)) 组"
                    )
                }
            } header: {
                Text("审阅队列")
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
                } else if visibleClusters.isEmpty {
                    Text("“\(model.librarySlimmingClusterQueueScope.title)”队列为空。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(
                        visibleClusters.prefix(
                            LibrarySlimmingClusterPagination.visibleCount(
                                totalCount: visibleClusters.count,
                                limit: librarySlimmingClusterLimit
                            )
                        )
                    ) { cluster in
                        librarySlimmingClusterReviewRow(cluster)
                        // This List's native selection belongs exclusively to analysis jobs.
                        // Cluster rows manage a separate model selection and contain their own
                        // review buttons, so allowing AppKit to select the row can leave a blue
                        // native highlight on one cluster while the detail still shows another.
                        .selectionDisabled()
                        .listRowBackground(
                            model.selectedLibrarySlimmingClusterID == cluster.id
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                    }
                    if librarySlimmingClusterLimit < visibleClusters.count {
                        let remaining = visibleClusters.count
                            - librarySlimmingClusterLimit
                        Button {
                            librarySlimmingClusterLimit =
                                LibrarySlimmingClusterPagination.nextLimit(
                                    currentLimit: librarySlimmingClusterLimit,
                                    totalCount: visibleClusters.count
                                )
                        } label: {
                            Text(
                                "再显示 \(min(LibrarySlimmingClusterPagination.pageSize, remaining)) 组（剩余 \(remaining) 组）"
                            )
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("加载更多结果分组，剩余 \(remaining) 组")
                    }
                }
            } header: {
                HStack {
                    Text(model.librarySlimmingClusterQueueScope.title)
                    Spacer()
                    if !visibleClusters.isEmpty {
                        Text("\(visibleClusters.count) 组")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func librarySlimmingClusterReviewRow(
        _ cluster: LibrarySlimmingClusterPresentation
    ) -> some View {
        let disposition = model.librarySlimmingClusterReviewDisposition(for: cluster.id)
        let isSaving = model.librarySlimmingClusterReviewPendingIDs.contains(cluster.id)
        return HStack(alignment: .center, spacing: 8) {
            Button {
                model.selectLibrarySlimmingCluster(cluster.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(cluster.kindTitle)
                            .font(.body.weight(.semibold))
                        Spacer()
                        Text(cluster.memberCountCaption)
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
            .layoutPriority(1)

            VStack(alignment: .trailing, spacing: 5) {
                librarySlimmingDispositionButton(
                    title: "已确认",
                    systemImage: "checkmark",
                    disposition: .confirmed,
                    current: disposition,
                    clusterID: cluster.id,
                    isSaving: isSaving
                )
                librarySlimmingDispositionButton(
                    title: "忽略",
                    systemImage: "eye.slash",
                    disposition: .ignored,
                    current: disposition,
                    clusterID: cluster.id,
                    isSaving: isSaving
                )
                if isSaving {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("正在保存分组状态")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(cluster.kindTitle)，\(cluster.memberCountCaption)")
    }

    private func librarySlimmingDispositionButton(
        title: String,
        systemImage: String,
        disposition: LibrarySlimmingClusterReviewDisposition,
        current: LibrarySlimmingClusterReviewDisposition?,
        clusterID: UUID,
        isSaving: Bool
    ) -> some View {
        let isActive = current == disposition
        return Button {
            Task {
                await model.setLibrarySlimmingClusterReviewDisposition(
                    clusterID: clusterID,
                    disposition: disposition
                )
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .foregroundStyle(isActive ? Color.white : Color.secondary)
                .background {
                    Capsule(style: .continuous)
                        .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.1))
                }
        }
        .buttonStyle(.borderless)
        .disabled(isSaving || isActive)
        .accessibilityLabel(isActive ? "当前为\(title)" : "设为\(title)")
    }

    private var clusterDetail: some View {
        Group {
            if let cluster = model.selectedLibrarySlimmingCluster {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(cluster.kindTitle)
                            .font(.headline)

                        Text(cluster.memberCountCaption)
                            .foregroundStyle(.secondary)

                        if !model.selectedLibrarySlimmingMemberIDs.isEmpty {
                            Text("已选 \(model.selectedLibrarySlimmingMemberIDs.count)")
                                .foregroundStyle(Color.accentColor)
                        }

                        Text("⌘ / Shift 多选 · 拖拽框选")
                            .foregroundStyle(.tertiary)

                        if let sourceSummary = model.librarySlimmingSelectedClusterSourceSummary {
                            Label(sourceSummary, systemImage: "photo.on.rectangle.angled")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help("来源：\(sourceSummary)")
                        }

                        Spacer()

                        if let disposition = model.librarySlimmingClusterReviewDisposition(
                            for: cluster.id
                        ) {
                            Label(
                                disposition == .confirmed ? "已确认" : "已忽略",
                                systemImage: disposition == .confirmed
                                    ? "checkmark.circle.fill"
                                    : "eye.slash.fill"
                            )
                            .foregroundStyle(
                                disposition == .confirmed ? Color.accentColor : Color.secondary
                            )
                            Button("重新处理") {
                                Task {
                                    await model.setLibrarySlimmingClusterReviewDisposition(
                                        clusterID: cluster.id,
                                        disposition: nil
                                    )
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(
                                model.librarySlimmingClusterReviewPendingIDs.contains(cluster.id)
                            )
                            .persistentHelp("移回待处理队列；不会修改任何照片。")
                        }

                        Text(cluster.scoreCaption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .fixedSize(horizontal: false, vertical: true)
                    Divider()

                    if cluster.memberAssetIDs.isEmpty,
                       cluster.isHistoricalProcessedRecord
                    {
                        ContentUnavailableView {
                            Label("历史处理记录", systemImage: "checkmark.circle")
                        } description: {
                            Text("原分组仍有审阅记录，但成员当前均已回收、清理或不再可查看。")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
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
                                                guard !model.librarySlimmingRecyclePendingAssetIDs
                                                    .contains(assetID)
                                                else { return }
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
                                                slimmingMemberContextMenu(for: assetID)
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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if !model.librarySlimmingClusters.isEmpty,
                      model.visibleLibrarySlimmingClusters.isEmpty
            {
                ContentUnavailableView {
                    Label(
                        "\(model.librarySlimmingClusterQueueScope.title)队列为空",
                        systemImage: model.librarySlimmingClusterQueueScope.systemImage
                    )
                } description: {
                    Text("可从左侧切换到其他审阅队列。")
                }
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
                    Text("任务仍在处理，或暂时还没有形成相同、相似媒体分组。")
                }
            } else {
                ContentUnavailableView {
                    Label("选择结果分组", systemImage: "photo.stack")
                } description: {
                    Text("请从左侧“结果分组”选择一组媒体。")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func slimmingMemberContextMenu(for assetID: UUID) -> some View {
        let moveCount = model.selectedLibrarySlimmingMemberIDs.contains(assetID)
            ? model.selectedLibrarySlimmingMemberIDs.count
            : 1
        let favoriteState = model.favoriteState(for: assetID)
        Button(favoriteState.isFavorite ? "取消红心" : "加入红心") {
            Task { await model.toggleFavorite(assetID: assetID) }
        }
        Divider()
        Button("快速删除并释放空间 (\(moveCount))", role: .destructive) {
            if !model.selectedLibrarySlimmingMemberIDs.contains(assetID) {
                model.selectLibrarySlimmingMember(assetID, additive: false)
            }
            requestFastDeleteConfirmation()
        }
        .disabled(!model.supportsLibrarySlimmingRecycle || model.isMutatingLibrarySlimmingRecycle)
        .persistentHelp("文件夹媒体会在身份核验后永久删除；Photos 仍由系统移入“最近删除”。")
        Button("移入可恢复回收站 (\(moveCount))") {
            presentMoveToRecycle(for: assetID)
        }
        .disabled(!model.supportsLibrarySlimmingRecycle || model.isMutatingLibrarySlimmingRecycle)
        .persistentHelp("把当前媒体或已选媒体移入可恢复回收站；跨磁盘时可能较慢。")
    }

    private var recycleBinList: some View {
        VStack(spacing: 0) {
            recycleBinHeader
            Divider()
            recycleBinSearchResults
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var recycleBinHeader: some View {
        let filteredEntries = model.filteredLibrarySlimmingRecycleEntries

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("回收站")
                        .font(.title2.weight(.semibold))
                    Text(recycleBinSummaryCaption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                if model.isMutatingLibrarySlimmingRecycle {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在处理…")
                            .font(.callout.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
            }

            if let sourceTitle = model.librarySlimmingRecycleSourceFilterTitle {
                HStack(spacing: 8) {
                    Label(
                        "正在查看“\(sourceTitle)”来源的回收记录",
                        systemImage: "line.3.horizontal.decrease.circle.fill"
                    )
                    .font(.callout.weight(.medium))
                    Spacer()
                    Button("显示全部来源") {
                        model.clearLibrarySlimmingRecycleSourceFilter()
                    }
                    .buttonStyle(.borderless)
                    .persistentHelp("清除来源范围，显示所有来源的回收站项目。")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.orange.opacity(0.22))
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    recycleBinScopeControls(entries: filteredEntries)
                    Spacer(minLength: 16)
                    recycleBinSearchBar(resultCount: filteredEntries.count)
                        .frame(width: 310)
                }

                VStack(alignment: .leading, spacing: 10) {
                    recycleBinScopeControls(entries: filteredEntries)
                    recycleBinSearchBar(resultCount: filteredEntries.count)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .background {
            LinearGradient(
                colors: [Color.orange.opacity(0.075), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var recycleBinSummaryCaption: String {
        let count = model.librarySlimmingRecycleEntries.count.formatted()
        let unit = model.selectedMediaKind == .video ? "个视频项目" : "张照片项目"
        let attention = LibrarySlimmingRecycleScope.attention.count(
            in: model.librarySlimmingRecycleEntries
        )
        if attention > 0 {
            return "当前 \(count) \(unit)，其中 \(attention.formatted()) 项需要关注"
        }
        return "当前 \(count) \(unit)，均处于可恢复或系统管理状态"
    }

    private func recycleBinScopeControls(entries: [RecycleEntryRecord]) -> some View {
        HStack(spacing: 7) {
            ForEach(LibrarySlimmingRecycleScope.allCases) { scope in
                recycleBinScopeButton(scope, entries: entries)
            }
        }
    }

    private func recycleBinScopeButton(
        _ scope: LibrarySlimmingRecycleScope,
        entries: [RecycleEntryRecord]
    ) -> some View {
        let isSelected = librarySlimmingRecycleScope == scope
        let isAttention = scope == .attention
        let tint = isAttention ? Color.orange : Color.accentColor
        let count = scope.count(in: entries)

        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                librarySlimmingRecycleScope = scope
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: scope.systemImage)
                Text(scope.title)
                Text(count.formatted())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? tint : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tint.opacity(isSelected ? 0.16 : 0.07), in: Capsule())
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? tint : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isSelected ? tint.opacity(0.1) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isSelected ? tint.opacity(0.45) : Color.secondary.opacity(0.16))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(scope.title)，\(count) 项")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("librarySlimmingRecycleScope.\(scope.rawValue)")
        .persistentHelp("只显示\(scope.title)范围内的回收站项目。")
    }

    private func recycleBinSearchBar(resultCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                "按文件名搜索",
                text: Binding(
                    get: { model.librarySlimmingRecycleSearchText },
                    set: { model.updateLibrarySlimmingRecycleSearchText($0) }
                )
            )
            .textFieldStyle(.plain)
            .accessibilityIdentifier("librarySlimmingRecycleFilenameSearch")
            .persistentHelp("输入文件名的一部分，即时筛选当前回收站条目。")
            if !model.trimmedLibrarySlimmingRecycleSearchText.isEmpty {
                Text(resultCount.formatted())
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Button {
                    model.updateLibrarySlimmingRecycleSearchText("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("清除回收站文件名搜索")
                .persistentHelp("清除文件名搜索并显示全部回收站条目。")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.secondary.opacity(0.2))
        }
    }

    @ViewBuilder
    private var recycleBinSearchResults: some View {
        let filteredEntries = model.filteredLibrarySlimmingRecycleEntries
        let visibleEntries = librarySlimmingRecycleScope.filtered(filteredEntries)

        Group {
            if model.librarySlimmingRecycleEntries.isEmpty {
                ContentUnavailableView {
                    Label("回收站为空", systemImage: "trash")
                } description: {
                    Text(
                        "文件夹媒体由 ImageAll 保留 30 天；Photos 资产遵循 macOS「照片」App 的删除与恢复规则。"
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredEntries.isEmpty {
                ContentUnavailableView {
                    Label("没有匹配的媒体", systemImage: "magnifyingglass")
                } description: {
                    if let sourceTitle = model.librarySlimmingRecycleSourceFilterTitle,
                       model.trimmedLibrarySlimmingRecycleSearchText.isEmpty
                    {
                        Text("“\(sourceTitle)”当前没有回收或待处理项目。")
                    } else {
                        Text(
                            "没有文件名包含“\(model.trimmedLibrarySlimmingRecycleSearchText)”"
                                + "的回收站条目。"
                        )
                    }
                } actions: {
                    if !model.trimmedLibrarySlimmingRecycleSearchText.isEmpty {
                        Button("清除搜索") {
                            model.updateLibrarySlimmingRecycleSearchText("")
                        }
                        .persistentHelp("清除文件名搜索并显示全部回收站条目。")
                    } else if model.librarySlimmingRecycleSourceFilterID != nil {
                        Button("显示全部来源") {
                            model.clearLibrarySlimmingRecycleSourceFilter()
                        }
                        .persistentHelp("清除来源范围并显示全部回收站条目。")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleEntries.isEmpty {
                ContentUnavailableView {
                    Label("这个范围内没有媒体", systemImage: librarySlimmingRecycleScope.systemImage)
                } description: {
                    Text("其他来源或处理状态中仍有回收站项目。")
                } actions: {
                    Button("查看全部") {
                        librarySlimmingRecycleScope = .all
                    }
                    .persistentHelp("显示当前搜索和来源范围内的全部回收站项目。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: 380, maximum: 640),
                                spacing: 12,
                                alignment: .top
                            )
                        ],
                        alignment: .center,
                        spacing: 12
                    ) {
                        ForEach(
                            visibleEntries.prefix(
                                LibrarySlimmingRecyclePagination.visibleCount(
                                    totalCount: visibleEntries.count,
                                    limit: librarySlimmingRecycleLimit
                                )
                            )
                        ) { entry in
                            recycleEntryCard(entry)
                        }
                        if librarySlimmingRecycleLimit
                            < visibleEntries.count
                        {
                            let remaining =
                                visibleEntries.count
                                - librarySlimmingRecycleLimit
                            Button {
                                librarySlimmingRecycleLimit =
                                    LibrarySlimmingRecyclePagination.nextLimit(
                                        currentLimit: librarySlimmingRecycleLimit,
                                        totalCount: visibleEntries.count
                                    )
                            } label: {
                                Label(
                                    "再显示 \(min(LibrarySlimmingRecyclePagination.pageSize, remaining)) 项",
                                    systemImage: "chevron.down.circle"
                                )
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("加载更多回收站条目，剩余 \(remaining) 项")
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func recycleEntryCard(_ entry: RecycleEntryRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 13) {
                RecycleThumbnailCell(
                    model: model,
                    entry: entry
                )
                .frame(width: 96, height: 84)

                VStack(alignment: .leading, spacing: 7) {
                    Text(recycleEntryDisplayName(entry))
                        .font(.headline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(recycleEntryDisplayName(entry))

                    HStack(spacing: 7) {
                        Label(
                            entry.sourceKind == .photos ? "Apple Photos" : "文件夹来源",
                            systemImage: entry.sourceKind == .photos
                                ? "photo.on.rectangle.angled"
                                : "folder"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(entry.sourceKind == .photos ? Color.blue : Color.secondary)

                        Text(recycleEntryMovedCaption(entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    recycleEntryLifecycle(entry)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)

            Divider()
                .padding(.horizontal, 12)

            HStack(spacing: 8) {
                recycleEntryPolicyCaption(entry)
                    .frame(maxWidth: .infinity, alignment: .leading)
                recycleEntryActions(entry)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    entry.state == .recycled
                        ? Color.secondary.opacity(0.16)
                        : recycleEntryLifecycleTint(entry).opacity(0.28)
                )
        }
        .shadow(color: .black.opacity(0.035), radius: 5, y: 2)
        .accessibilityElement(children: .contain)
    }

    private func recycleEntryDisplayName(_ entry: RecycleEntryRecord) -> String {
        entry.fileName
            ?? entry.originalRelativePath
            ?? entry.photosLocalIdentifier
            ?? "未命名"
    }

    private func recycleEntryMovedCaption(_ entry: RecycleEntryRecord) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(entry.trashedAtMs) / 1_000)
        let action = switch entry.state {
        case .recycled: "移入"
        case .pending: "开始处理"
        case .restoring: "开始恢复"
        case .purging: "开始清理"
        case .failed: "尝试处理"
        case .restored: "恢复"
        case .purged: "清理"
        }
        return "\(date.formatted(date: .abbreviated, time: .omitted)) \(action)"
    }

    @ViewBuilder
    private func recycleEntryLifecycle(_ entry: RecycleEntryRecord) -> some View {
        if entry.state != .recycled {
            let tint = recycleEntryLifecycleTint(entry)
            Label(
                recycleEntryStateText(entry),
                systemImage: recycleEntryStateIcon(entry)
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                tint.opacity(0.09),
                in: RoundedRectangle(cornerRadius: 7)
            )
        } else if entry.sourceKind == .photos {
            Label(
                RecycleCountdownFormatter.recordCleanupText(
                    cleanupAfterMs: entry.purgeAfterMs,
                    nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
                ),
                systemImage: "clock"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Label(
                RecycleCountdownFormatter.text(
                    purgeAfterMs: entry.purgeAfterMs,
                    nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
                ),
                systemImage: "hourglass"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
        }
    }

    private func recycleEntryPolicyCaption(_ entry: RecycleEntryRecord) -> some View {
        Label(
            recycleEntryPolicyText(entry),
            systemImage: recycleEntryPolicyIcon(entry)
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func recycleEntryActions(_ entry: RecycleEntryRecord) -> some View {
        switch entry.resolution {
        case .restoreOrPurge:
            Button {
                Task {
                    await model.restoreLibrarySlimmingRecycleEntry(entry.id)
                }
            } label: {
                Label(
                    entry.sourceKind == .photos ? "恢复说明" : "恢复",
                    systemImage: entry.sourceKind == .photos
                        ? "questionmark.circle"
                        : "arrow.uturn.backward"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isMutatingLibrarySlimmingRecycle)
            .persistentHelp(
                entry.sourceKind == .photos
                    ? "查看如何从 Apple Photos“最近删除”中恢复这个媒体。"
                    : "把这个文件夹媒体从 ImageAll 回收站恢复到原位置。"
            )

            if entry.sourceKind == .file {
                Button("立即删除", systemImage: "trash", role: .destructive) {
                    confirmPurgeEntryID = entry.id
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isMutatingLibrarySlimmingRecycle)
                .persistentHelp("打开永久删除确认；确认后这个原始媒体将不可恢复。")
            }
        case .discardPreflightFailure:
            Button("更新回收权限", systemImage: "lock.open") {
                Task {
                    await model.refreshFolderMutationAuthorization(entry.sourceID)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isMutatingLibrarySlimmingRecycle)
            .persistentHelp("重新选择原文件夹，更新这个来源的回收与恢复权限；不会立即修改媒体。")

            Button("移除记录", systemImage: "xmark.circle") {
                Task {
                    await model.discardLibrarySlimmingPreflightFailure(entry.id)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isMutatingLibrarySlimmingRecycle)
            .persistentHelp("只移除这条未开始文件操作的失败记录；不会读写、移动或删除原文件。")
        case .retryInterruptedOperation:
            Button(
                entry.state == .purging ? "继续清理" : "继续协调",
                systemImage: "arrow.clockwise"
            ) {
                Task {
                    await model.retryInterruptedLibrarySlimmingRecycleEntry(entry.id)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isMutatingLibrarySlimmingRecycle)
            .persistentHelp("根据已登记的事务继续安全恢复；不会重复提交已经完成的来源删除。")
        case .reinspectFileLocations:
            Button("重新检查", systemImage: "arrow.clockwise") {
                Task {
                    await model.retryInterruptedLibrarySlimmingRecycleEntry(entry.id)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isMutatingLibrarySlimmingRecycle)
            .persistentHelp("只检查原位置与隔离区；只有结果唯一时才更新记录。")

            recycleEntryExplanationButton(entry)
        case .updateFolderAuthorization:
            Button("更新回收权限", systemImage: "lock.open") {
                Task {
                    await model.refreshFolderMutationAuthorization(entry.sourceID)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isMutatingLibrarySlimmingRecycle)
            .persistentHelp("重新选择原文件夹更新权限；不会立即删除、移动或恢复媒体。")

            recycleEntryExplanationButton(entry)
        case .refreshSourceBeforeRetry:
            Button("刷新来源", systemImage: "arrow.triangle.2.circlepath") {
                Task {
                    await model.refreshLibrarySlimmingRecycleSource(entry.sourceID)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isMutatingLibrarySlimmingRecycle)
            .persistentHelp("重新读取这个来源的目录状态；完成后需重新分析，再重试清理。")

            recycleEntryExplanationButton(entry)
        case .requestPhotosAuthorization:
            Button("请求照片权限", systemImage: "photo.badge.checkmark") {
                Task {
                    await model.requestPhotosLibraryWriteAuthorization(for: entry.sourceID)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isMutatingLibrarySlimmingRecycle)
            .persistentHelp("请求 Apple Photos 完整读写授权；不会立即删除媒体。")

            recycleEntryExplanationButton(entry)
        case .retryFromAnalysis:
            Button("返回分析结果", systemImage: "rectangle.grid.2x2") {
                model.selectLibrarySlimmingWorkspaceTab(.clusters)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.isMutatingLibrarySlimmingRecycle)
            .persistentHelp("返回当前分析结果；核对媒体状态后可重新发起清理。")

            recycleEntryExplanationButton(entry)
        }
    }

    private func recycleEntryExplanationButton(
        _ entry: RecycleEntryRecord
    ) -> some View {
        Button("说明", systemImage: "info.circle") {
            model.explainUnresolvedLibrarySlimmingRecycleEntry(entry.id)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .persistentHelp("说明本次操作为何未完成，以及下一步如何处理。")
    }

    private func recycleEntryStateText(_ entry: RecycleEntryRecord) -> String {
        if entry.isDiscardablePreflightFailure {
            return "尚未开始：需要更新文件夹回收权限"
        }
        return switch entry.state {
        case .pending: "处理尚未完成，正在等待安全协调"
        case .restoring: "恢复尚未完成，可继续协调"
        case .purging: "永久清理尚未完成，可安全继续"
        case .failed: recycleEntryProblemText(entry.problem)
        case .recycled: "可恢复"
        case .restored: "已恢复"
        case .purged: "已永久清理"
        }
    }

    private func recycleEntryStateIcon(_ entry: RecycleEntryRecord) -> String {
        switch entry.state {
        case .pending: "clock.arrow.circlepath"
        case .restoring: "arrow.uturn.backward.circle"
        case .purging: "trash.circle"
        case .failed:
            entry.problem == .photosUserCancelled
                ? "xmark.circle"
                : "exclamationmark.circle.fill"
        case .recycled: "checkmark.circle"
        case .restored: "arrow.uturn.backward.circle.fill"
        case .purged: "trash.circle.fill"
        }
    }

    private func recycleEntryLifecycleTint(_ entry: RecycleEntryRecord) -> Color {
        switch entry.state {
        case .pending, .restoring: .blue
        case .purging: .orange
        case .failed:
            switch entry.problem {
            case .locationConflict, .locationMissing: .red
            default: .orange
            }
        case .recycled, .restored, .purged: .secondary
        }
    }

    private func recycleEntryProblemText(_ problem: RecycleEntryProblem?) -> String {
        switch problem {
        case .sourceAuthorizationRequired: "需要文件夹回收权限"
        case .sourceAuthorizationInvalid: "原有文件夹回收权限已失效"
        case .sourceChanged: "来源文件已变化，已停止处理以避免误删"
        case .photosAuthorizationRequired: "需要 Apple Photos 完整读写权限"
        case .photosAssetNotFound: "Photos 中已找不到同一媒体，未提交删除"
        case .photosUserCancelled: "已取消系统删除确认，媒体未被删除"
        case .photosMutationFailed: "Apple Photos 未确认完成删除"
        case .fileIO: "文件操作没有形成可确认的完整结果"
        case .locationConflict: "原位置与隔离区同时存在内容，需要核对"
        case .locationMissing: "无法确认媒体当前的唯一位置"
        case .unknown, nil: "本次处理未完成，需要重新核对"
        }
    }

    private func recycleEntryPolicyText(_ entry: RecycleEntryRecord) -> String {
        switch entry.state {
        case .recycled:
            return entry.sourceKind == .photos
                ? "恢复与永久删除由「照片」App 管理"
                : "可恢复到原位置"
        case .pending:
            return "ImageAll 会先确认实际位置，不会重复删除"
        case .restoring:
            return "正在协调原位置与 ImageAll 隔离区"
        case .purging:
            return "永久清理已经开始，完成后不可恢复"
        case .failed:
            return switch entry.problem {
            case .sourceAuthorizationRequired, .sourceAuthorizationInvalid:
                "原文件未因本次失败而被修改"
            case .sourceChanged:
                "原文件未删除；刷新来源并重新分析后再试"
            case .photosAuthorizationRequired,
                 .photosAssetNotFound,
                 .photosUserCancelled,
                 .photosMutationFailed:
                "未确认移入「最近删除」；可修正原因后重试"
            case .locationConflict:
                "两处内容均会保留，ImageAll 不会覆盖或删除"
            case .locationMissing:
                "位置未确认前，ImageAll 不会继续删除"
            case .fileIO, .unknown, nil:
                "未确认删除完成；现有内容会继续受到保护"
            }
        case .restored:
            return "媒体已经恢复"
        case .purged:
            return "媒体已经永久清理"
        }
    }

    private func recycleEntryPolicyIcon(_ entry: RecycleEntryRecord) -> String {
        switch entry.state {
        case .recycled:
            entry.sourceKind == .photos ? "info.circle" : "arrow.uturn.backward.circle"
        case .pending, .restoring: "shield.lefthalf.filled"
        case .purging: "trash.circle"
        case .failed: "shield"
        case .restored: "checkmark.circle"
        case .purged: "trash.circle.fill"
        }
    }
}

struct LibrarySlimmingPreviewViewportState: Equatable {
    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 8

    private(set) var scale: CGFloat = minimumScale
    private(set) var offset: CGSize = .zero

    mutating func zoom(
        wheelDelta: CGFloat,
        isPrecise: Bool,
        fittedImageSize: CGSize,
        viewportSize: CGSize
    ) {
        let sensitivity: CGFloat = isPrecise ? 0.012 : 0.08
        let limitedDelta = min(500, max(-500, wheelDelta))
        let factor = exp(limitedDelta * sensitivity)
        scale = min(
            Self.maximumScale,
            max(Self.minimumScale, scale * factor)
        )
        offset = constrainedOffset(
            offset,
            fittedImageSize: fittedImageSize,
            viewportSize: viewportSize
        )
    }

    func canPan(fittedImageSize: CGSize, viewportSize: CGSize) -> Bool {
        let limit = panLimit(
            fittedImageSize: fittedImageSize,
            viewportSize: viewportSize
        )
        return limit.width > 0 || limit.height > 0
    }

    mutating func drag(
        by translation: CGSize,
        fittedImageSize: CGSize,
        viewportSize: CGSize
    ) {
        guard canPan(
            fittedImageSize: fittedImageSize,
            viewportSize: viewportSize
        ) else {
            offset = .zero
            return
        }
        offset = constrainedOffset(
            CGSize(
                width: offset.width + translation.width,
                height: offset.height + translation.height
            ),
            fittedImageSize: fittedImageSize,
            viewportSize: viewportSize
        )
    }

    private func constrainedOffset(
        _ proposed: CGSize,
        fittedImageSize: CGSize,
        viewportSize: CGSize
    ) -> CGSize {
        let limit = panLimit(
            fittedImageSize: fittedImageSize,
            viewportSize: viewportSize
        )
        return CGSize(
            width: min(limit.width, max(-limit.width, proposed.width)),
            height: min(limit.height, max(-limit.height, proposed.height))
        )
    }

    private func panLimit(
        fittedImageSize: CGSize,
        viewportSize: CGSize
    ) -> CGSize {
        CGSize(
            width: max(0, (fittedImageSize.width * scale - viewportSize.width) / 2),
            height: max(0, (fittedImageSize.height * scale - viewportSize.height) / 2)
        )
    }
}

private struct LibrarySlimmingQuickLookView: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let navigation: LibrarySlimmingPreviewNavigationPresentation
    let onRequestDelete: () -> Void
    @State private var image: NSImage?
    @State private var loadFailed = false
    @State private var viewport = LibrarySlimmingPreviewViewportState()
    @State private var lastDragTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let viewportSize = CGSize(
                width: max(0, proxy.size.width - 120),
                height: max(0, proxy.size.height - 110)
            )
            ZStack {
                Color.black.opacity(0.96)

                previewContent(viewportSize: viewportSize)

                VStack(spacing: 0) {
                    quickLookToolbar
                    Spacer()
                    Text(
                        "滚轮缩放  ·  放大后按住左键拖动  ·  空格 / Esc 退出  ·  ← → 切换  ·  Delete 删除"
                    )
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(.bottom, 14)
                }

                HStack {
                    navigationButton(
                        title: "上一张",
                        systemImage: "chevron.left",
                        isEnabled: navigation.canMovePrevious
                    ) {
                        model.moveLibrarySlimmingPreview(by: -1)
                    }
                    Spacer()
                    navigationButton(
                        title: "下一张",
                        systemImage: "chevron.right",
                        isEnabled: navigation.canMoveNext
                    ) {
                        model.moveLibrarySlimmingPreview(by: 1)
                    }
                }
                .padding(.horizontal, 18)
            }
            .background {
                LibrarySlimmingPreviewScrollWheelMonitor { wheelDelta, isPrecise in
                    guard let image else { return }
                    let fittedImageSize = Self.fittedImageSize(
                        for: image,
                        in: viewportSize
                    )
                    viewport.zoom(
                        wheelDelta: wheelDelta,
                        isPrecise: isPrecise,
                        fittedImageSize: fittedImageSize,
                        viewportSize: viewportSize
                    )
                    lastDragTranslation = .zero
                }
            }
        }
        .accessibilityIdentifier("librarySlimmingQuickLook")
        .accessibilityLabel("图库瘦身大图预览，当前缩放 \(zoomPercentage)%")
        .task(id: navigation.assetID) {
            image = nil
            loadFailed = false
            viewport = LibrarySlimmingPreviewViewportState()
            lastDragTranslation = .zero
            guard let data = await model.previewData(assetID: navigation.assetID),
                  let decoded = NSImage(data: data)
            else {
                guard !Task.isCancelled else { return }
                loadFailed = true
                return
            }
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }

    private var quickLookToolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("第 \(navigation.position) 张，共 \(navigation.totalCount) 张")
                    .font(.headline)
                if let sourceName = navigation.sourceName {
                    Text(sourceName)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }
            Spacer()
            MediaFavoriteButton(
                state: model.favoriteState(for: navigation.assetID),
                isVisible: true
            ) {
                Task { await model.toggleFavorite(assetID: navigation.assetID) }
            }
            Text("\(zoomPercentage)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.white.opacity(0.12), in: Capsule())
                .accessibilityLabel("当前缩放 \(zoomPercentage)%")
            Button(role: .destructive, action: onRequestDelete) {
                Label("删除", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .accessibilityHint("保持预览并打开当前照片的快速删除确认")
            Button {
                model.closeLibrarySlimmingPreview()
            } label: {
                Label("关闭", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
            .accessibilityHint("关闭大图预览并保留当前照片选择")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.58))
    }

    @ViewBuilder
    private func previewContent(viewportSize: CGSize) -> some View {
        if let image {
            let fittedImageSize = Self.fittedImageSize(for: image, in: viewportSize)
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: fittedImageSize.width, height: fittedImageSize.height)
                    .scaleEffect(viewport.scale)
                    .offset(viewport.offset)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let incrementalTranslation = CGSize(
                                    width: value.translation.width - lastDragTranslation.width,
                                    height: value.translation.height - lastDragTranslation.height
                                )
                                viewport.drag(
                                    by: incrementalTranslation,
                                    fittedImageSize: fittedImageSize,
                                    viewportSize: viewportSize
                                )
                                lastDragTranslation = value.translation
                            }
                            .onEnded { _ in
                                lastDragTranslation = .zero
                            }
                    )
                    .accessibilityLabel("当前预览照片")
            }
            .frame(width: viewportSize.width, height: viewportSize.height)
            .clipped()
        } else if loadFailed {
            ContentUnavailableView {
                Label("无法载入大图预览", systemImage: "exclamationmark.triangle")
            } description: {
                Text("照片可能仅存于 iCloud，或当前来源暂时不可读取。")
            }
            .foregroundStyle(.white)
            .frame(width: viewportSize.width, height: viewportSize.height)
        } else {
            ProgressView("正在载入预览…")
                .controlSize(.large)
                .tint(.white)
                .foregroundStyle(.white)
                .frame(width: viewportSize.width, height: viewportSize.height)
        }
    }

    private var zoomPercentage: Int {
        Int((viewport.scale * 100).rounded())
    }

    private static func fittedImageSize(for image: NSImage, in viewportSize: CGSize) -> CGSize {
        guard image.size.width > 0,
              image.size.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0
        else { return .zero }
        let fitScale = min(
            viewportSize.width / image.size.width,
            viewportSize.height / image.size.height
        )
        return CGSize(
            width: image.size.width * fitScale,
            height: image.size.height * fitScale
        )
    }

    private func navigationButton(
        title: String,
        systemImage: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 56)
                .background(.black.opacity(0.58), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.25)
        .accessibilityLabel(title)
    }
}

private struct LibrarySlimmingPreviewScrollWheelMonitor: NSViewRepresentable {
    let onScroll: (_ wheelDelta: CGFloat, _ isPrecise: Bool) -> Void

    func makeNSView(context: Context) -> ScrollWheelMonitorView {
        ScrollWheelMonitorView()
    }

    func updateNSView(_ nsView: ScrollWheelMonitorView, context: Context) {
        nsView.configure(onScroll: onScroll)
    }

    static func dismantleNSView(_ nsView: ScrollWheelMonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class ScrollWheelMonitorView: NSView {
        private var monitor: Any?
        private var onScroll: ((_ wheelDelta: CGFloat, _ isPrecise: Bool) -> Void)?

        func configure(
            onScroll: @escaping (_ wheelDelta: CGFloat, _ isPrecise: Bool) -> Void
        ) {
            self.onScroll = onScroll
            installMonitorIfNeeded()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else {
                installMonitorIfNeeded()
            }
        }

        func stopMonitoring() {
            onScroll = nil
            removeMonitor()
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                guard let self,
                      let hostWindow = self.window,
                      event.window === hostWindow
                else { return event }
                let localPoint = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(localPoint) else { return event }
                let rawDelta = event.scrollingDeltaY
                guard rawDelta != 0 else { return event }
                let wheelDelta = event.isDirectionInvertedFromDevice
                    ? -rawDelta
                    : rawDelta
                self.onScroll?(wheelDelta, event.hasPreciseScrollingDeltas)
                return nil
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
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
                    model.selectedMediaKind == .video
                        ? "按代表缩略图查找视觉重复或相似的视频。文件夹资产默认快速永久删除以释放来源空间，也可选择 ImageAll 的 30 天可恢复回收；Photos 使用系统“最近删除”。"
                        : "查找相同与相似照片。文件夹资产默认快速永久删除以释放来源空间，也可选择 ImageAll 的 30 天可恢复回收；Photos 使用系统“最近删除”。"
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
                    LabeledContent(
                        "范围",
                        value: model.selectedMediaKind == .video
                            ? "\(job.memberCount) 个"
                            : "\(job.memberCount) 张"
                    )
                    if job.seedCount > 0 {
                        LabeledContent(
                            "种子",
                            value: model.selectedMediaKind == .video
                                ? "\(job.seedCount) 个"
                                : "\(job.seedCount) 张"
                        )
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
                    LabeledContent("成员", value: cluster.memberCountCaption)
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
                    Text(
                        model.selectedMediaKind == .video
                            ? "有 \(model.librarySlimmingPendingCount) 个视频缺少代表缩略图、Feature Print 或 DINOv2，已标为待分析。"
                            : "有 \(model.librarySlimmingPendingCount) 张照片缺少 Feature Print 或 DINOv2，已标为待分析。"
                    )
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

private struct RecycleThumbnailCell: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let entry: RecycleEntryRecord
    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var isHovered = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.09))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: model.thumbnailAspectMode.imageContentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    VStack(spacing: 5) {
                        Image(systemName: entry.mediaKind == .video ? "video" : "photo")
                            .font(.title3)
                        Text(entry.state == .purging ? "预览已清理" : "暂无预览")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.12))
            }
            .overlay(alignment: .topLeading) {
                if entry.mediaKind == .video {
                    Image(systemName: "play.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.58), in: Circle())
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                MediaFavoriteButton(
                    state: model.favoriteState(for: entry.assetID),
                    isVisible: isHovered
                ) {
                    Task { await model.toggleFavorite(assetID: entry.assetID) }
                }
                .padding(6)
            }
        }
        .aspectRatio(
            model.thumbnailAspectMode.frameAspectRatio(imageSize: image?.size),
            contentMode: .fit
        )
        .task(id: loadID) {
            image = nil
            isLoading = true
            let result = await model.loadRecycleThumbnailResult(
                assetID: entry.assetID,
                aspectMode: model.thumbnailAspectMode
            )
            guard !Task.isCancelled else { return }
            if case let .loaded(data) = result,
               let decoded = LibraryGridThumbnailImageFactory.image(from: data)
            {
                image = decoded
            }
            isLoading = false
        }
        .task(id: entry.assetID) {
            await model.ensureFavoriteStatesLoaded(assetIDs: [entry.assetID])
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            let state = model.favoriteState(for: entry.assetID)
            Button(state.isFavorite ? "取消红心" : "加入红心") {
                Task { await model.toggleFavorite(assetID: entry.assetID) }
            }
            if entry.sourceKind == .photos {
                Text("Apple Photos 的“最近删除”由系统管理，红心不能暂停系统永久删除。")
            }
        }
        .accessibilityLabel(
            image == nil
                ? "\(entry.fileName ?? "媒体")，暂无缓存预览"
                : "\(entry.fileName ?? "媒体")预览"
        )
    }

    private var loadID: SlimmingThumbnailLoadID {
        SlimmingThumbnailLoadID(
            assetID: entry.assetID,
            restoreVersion: model.librarySlimmingThumbnailReloadVersion(for: entry.assetID),
            aspectMode: model.thumbnailAspectMode,
            originalAspectCacheGeneration: model.originalAspectThumbnailCacheGeneration
        )
    }
}

private struct SlimmingThumbnailCell: View {
    @ObservedObject var model: LibraryWorkspaceModel
    let assetID: UUID
    var isSelected: Bool = false
    @State private var image: NSImage?
    @State private var loadState: SlimmingThumbnailLoadState = .loading
    @State private var isHovered = false

    private var isPendingRecycle: Bool {
        model.librarySlimmingRecyclePendingAssetIDs.contains(assetID)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
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
            .overlay(alignment: .topLeading) {
                if model.selectedMediaKind == .video {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(.black.opacity(0.68), in: Circle())
                        .padding(7)
                        .accessibilityLabel("视频代表缩略图")
                }
            }
            .overlay(alignment: .topTrailing) {
                MediaFavoriteButton(
                    state: model.favoriteState(for: assetID),
                    isVisible: isHovered || isSelected
                ) {
                    Task { await model.toggleFavorite(assetID: assetID) }
                }
                .padding(7)
            }
            .overlay {
                if isPendingRecycle {
                    ZStack {
                        Color.black.opacity(0.55)
                        VStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                            Text("正在移动")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("正在安全移入回收站")
                }
            }
        }
        .aspectRatio(
            model.thumbnailAspectMode.frameAspectRatio(imageSize: image?.size),
            contentMode: .fit
        )
        .task(id: loadID) {
            image = nil
            loadState = .loading
            switch await model.loadThumbnailResultWithRetry(
                assetID: assetID,
                aspectMode: model.thumbnailAspectMode
            ) {
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
                loadState = .placeholder(
                    symbol: model.selectedMediaKind == .video ? "video" : "photo"
                )
            case .failed:
                loadState = .placeholder(symbol: "exclamationmark.triangle")
            case .cancelled:
                guard !Task.isCancelled else { return }
                loadState = .placeholder(
                    symbol: model.selectedMediaKind == .video ? "video" : "photo"
                )
            }
        }
        .task(id: assetID) {
            await model.ensureFavoriteStatesLoaded(assetIDs: [assetID])
        }
        .onHover { isHovered = $0 }
    }

    private var loadID: SlimmingThumbnailLoadID {
        SlimmingThumbnailLoadID(
            assetID: assetID,
            restoreVersion: model.librarySlimmingThumbnailReloadVersion(for: assetID),
            aspectMode: model.thumbnailAspectMode,
            originalAspectCacheGeneration: model.originalAspectThumbnailCacheGeneration
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
    let aspectMode: LibraryThumbnailAspectMode
    let originalAspectCacheGeneration: Int
}

private struct LibrarySlimmingMoveToRecycleConfirmationSheet: View {
    let selectedCount: Int
    let mediaKind: MediaKind
    let favoriteCount: Int
    let allowsSuppressingFutureConfirmation: Bool
    @Binding var suppressFutureConfirmation: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("移入可恢复回收站")
                .font(.headline)
            Text(
                "文件夹媒体会先复制到 ImageAll 回收站再从来源删除，默认保留 30 天；跨磁盘处理可能较慢。Photos 资产由 macOS 移入系统「最近删除」。"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if favoriteCount > 0 {
                Label(
                    "其中 \(favoriteCount) 项带红心。自动清理不会删除红心项，但你正在手动确认回收它们。",
                    systemImage: "heart.fill"
                )
                .foregroundStyle(.red)
                .font(.callout.weight(.semibold))
            }
            if allowsSuppressingFutureConfirmation {
                Toggle(
                    "不再确认单张或 5 张以内的普通回收",
                    isOn: $suppressFutureConfirmation
                )
            } else {
                Text("超过 5 个媒体的批量回收每次都需要确认。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .persistentHelp("关闭窗口并保留所有媒体，不执行回收操作。")
                Button(
                    mediaKind == .video
                        ? "可恢复回收（\(selectedCount) 个）"
                        : "可恢复回收（\(selectedCount) 张）",
                    role: .destructive
                ) {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .persistentHelp("确认把列出的媒体移入回收站，之后仍可按来源规则恢复。")
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct LibraryFastDeleteConfirmationSheet: View {
    let selectedCount: Int
    let mediaKind: MediaKind
    let favoriteCount: Int
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var deleteButtonFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("快速删除并释放空间", systemImage: "externaldrive.badge.minus")
                .font(.headline)
                .foregroundStyle(.red)
            Text(
                "文件夹来源中的原始媒体会在身份核验后直接永久删除，不复制到 ImageAll 回收站，因此来源空间会立即变为可回收，但无法通过 ImageAll 恢复。Apple Photos 资产仍只会进入系统「最近删除」。系统快照可能让磁盘容量显示稍后才更新。"
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            if favoriteCount > 0 {
                Label(
                    "其中 \(favoriteCount) 项带红心。继续会绕过红心自动保护并执行手动删除。",
                    systemImage: "heart.fill"
                )
                .foregroundStyle(.red)
                .font(.callout.weight(.semibold))
            }
            Text("此确认每次都会显示，不能设置为不再提醒。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(
                    mediaKind == .video
                        ? "永久删除（\(selectedCount) 个）"
                        : "永久删除（\(selectedCount) 张）",
                    role: .destructive
                ) {
                    onConfirm()
                    dismiss()
                }
                .focused($deleteButtonFocused)
                .keyboardShortcut(.defaultAction)
                .persistentHelp("永久删除文件夹原始媒体并释放来源空间；此操作不可撤销。")
            }
        }
        .padding(20)
        .frame(width: 460)
        .defaultFocus($deleteButtonFocused, true, priority: .userInitiated)
    }
}

private struct LibrarySlimmingIdenticalCleanupConfirmationSheet: View {
    let plan: LibrarySlimmingIdenticalCleanupPlan
    let onFastDelete: () -> Void
    let onRecoverableRecycle: () -> Void
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
                Text("文件夹可快速永久删除以释放空间，也可选择较慢的可恢复回收。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("可恢复回收") {
                    recoverableRecycle()
                }
                .persistentHelp("文件夹媒体复制到 ImageAll 回收站；跨磁盘时可能较慢。")
                Button(
                    "快速清理 \(plan.assetIDsToRecycle.count.formatted()) 张",
                    role: .destructive
                ) {
                    fastDelete()
                }
                .keyboardShortcut(.defaultAction)
                .persistentHelp("文件夹媒体直接永久删除并释放来源空间；Photos 进入系统“最近删除”。")
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
                Text("一键清理完全相同媒体")
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
                    title: "已核验媒体",
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
                    title: "红心保留",
                    value: plan.favoriteRetainedAssetCount,
                    systemImage: "heart.fill",
                    tint: .red
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
            Text(
                "普通保留 \(plan.ordinaryRetainedAssetCount) 项；"
                    + "全组红心而安全跳过 \(plan.protectedSkippedAssetCount) 项。"
                    + "红心资产不会进入自动删除计划。"
            )
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
                                angle: .value("媒体数", item.count),
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
                            x: .value("每组媒体数", item.label),
                            y: .value("分组数", item.groupCount)
                        )
                        .foregroundStyle(.indigo.gradient)
                        .annotation(position: .top) {
                            Text(item.groupCount.formatted())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .chartXAxisLabel("每组媒体数")
                    .chartYAxisLabel("分组数")
                    .frame(height: 180)
                    .accessibilityLabel("完全相同组规模分布")
                }
                .frame(maxWidth: .infinity)
            }

            GroupBox("待清理媒体来源") {
                Chart(recycleSourceData) { item in
                    BarMark(
                        x: .value("媒体数", item.count),
                        y: .value("来源", item.label)
                    )
                    .foregroundStyle(item.color.gradient)
                    .annotation(position: .trailing) {
                        Text("\(item.count.formatted()) 张")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxisLabel("待清理媒体数")
                .frame(height: 105)
                .accessibilityLabel("待清理媒体来源分布")
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
        if plan.fileAssetCount > 0 {
            Label(
                "“快速清理”会永久删除 \(plan.fileAssetCount.formatted()) 个文件夹媒体，ImageAll 无法恢复。",
                systemImage: "externaldrive.badge.exclamationmark"
            )
            .font(.caption)
            .foregroundStyle(.red)
        }
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

    private func fastDelete() {
        onFastDelete()
        dismiss()
    }

    private func recoverableRecycle() {
        onRecoverableRecycle()
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

private struct LibrarySlimmingIdenticalCleanupVerificationSheet: View {
    let report: LibrarySlimmingIdenticalCleanupPostDeleteReport
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    reportContent
                }
                .padding(28)
            }

            Divider()

            HStack {
                Text("这是删除动作结束后的独立核验结果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") {
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .frame(width: 680, height: 540)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: headerSystemImage)
                .font(.system(size: 30))
                .foregroundStyle(headerTint)
                .frame(width: 46, height: 46)
                .background(headerTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(headerTitle)
                    .font(.title2.weight(.semibold))
                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var reportContent: some View {
        switch report {
        case let .verified(verification):
            verifiedContent(verification)
        case let .unavailable(message):
            unavailableContent(message)
        }
    }

    private func verifiedContent(
        _ verification: LibrarySlimmingIdenticalCleanupVerification
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 6) {
                Text(
                    "\(verification.verifiedGroupCount.formatted())"
                        + " / "
                        + verification.targetGroupCount.formatted()
                )
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(verification.isComplete ? Color.green : Color.orange)
                Text("组完全相同媒体已完成去重")
                    .font(.title3.weight(.medium))
                Text(
                    "目标是保留全部红心资产；没有红心时每组保留 1 张，"
                        + "共 \(verification.targetRetainedAssetCount.formatted()) 张。"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)

            HStack(spacing: 12) {
                CleanupMetricCard(
                    title: "目标保留",
                    value: verification.targetRetainedAssetCount,
                    systemImage: "scope",
                    tint: .blue
                )
                CleanupMetricCard(
                    title: "当前实际可用",
                    value: verification.currentAvailableAssetCount,
                    systemImage: "photo.stack",
                    tint: .green
                )
                CleanupMetricCard(
                    title: "完成去重",
                    value: verification.verifiedGroupCount,
                    systemImage: "square.stack.3d.up.fill",
                    tint: .indigo
                )
                CleanupMetricCard(
                    title: "尚未完成",
                    value: verification.unresolvedGroupCount,
                    systemImage: "exclamationmark.triangle",
                    tint: verification.unresolvedGroupCount == 0 ? .gray : .orange
                )
            }

            if verification.isComplete {
                Label(
                    "核验完成：实际读取 \(verification.observedAssetCount.formatted()) 张，"
                        + "确认已清理 \(verification.recycledRedundantAssetCount.formatted()) 张；"
                        + "处理范围内没有仍处于可用状态的计划删除项。",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("核验发现未完成项", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(
                        "本次实际读取 \(verification.observedAssetCount.formatted()) 张；"
                            + "确认已清理 \(verification.recycledRedundantAssetCount.formatted()) 张；"
                            + "当前实际可用 \(verification.currentAvailableAssetCount.formatted()) 张；"
                            + "其中仍可用的冗余媒体 \(verification.remainingRedundantAssetCount.formatted()) 个；"
                            + "状态无法确认 \(verification.unresolvedAssetCount.formatted()) 张。"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            Text(
                "“完成去重”“确认已清理”和“当前实际可用”均来自删除后的再次读取；"
                    + "“目标保留”来自本次运行时逐组清理计划，不代表所有分组均已完成。"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func unavailableContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("未显示未经证实的保留数量", systemImage: "shield.lefthalf.filled")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
            Text("请保留当前回收记录并重新进入图库瘦身后再核验；在成功读取真实状态前，ImageAll 不会用删除前计划值代替结果。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var headerTitle: String {
        switch report {
        case let .verified(verification):
            verification.isComplete ? "删除后核验完成" : "删除后核验存在未完成项"
        case .unavailable:
            "删除后核验未完成"
        }
    }

    private var headerSubtitle: String {
        switch report {
        case .verified:
            "已重新读取本次处理资产的实时可用与回收状态。"
        case .unavailable:
            "删除动作已经结束，但无法取得可信的实际统计。"
        }
    }

    private var headerSystemImage: String {
        switch report {
        case let .verified(verification):
            verification.isComplete ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        case .unavailable:
            "exclamationmark.shield.fill"
        }
    }

    private var headerTint: Color {
        switch report {
        case let .verified(verification):
            verification.isComplete ? .green : .orange
        case .unavailable:
            .orange
        }
    }

    private func close() {
        onDismiss()
        dismiss()
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
                .persistentHelp("把相似媒体召回和精排参数恢复为 ImageAll 默认值。")
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
