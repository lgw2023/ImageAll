import AppKit
import AVKit
import SwiftUI
import ImageIO

private enum TimeStoryDurationText {
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.00" }
        let centiseconds = max(0, Int((seconds * 100).rounded()))
        let wholeSeconds = centiseconds / 100
        return String(
            format: "%d:%02d.%02d",
            wholeSeconds / 60, wholeSeconds % 60, centiseconds % 100
        )
    }
}

struct TimeStoryCreationButton: View {
    let tag: TagListItem
    let action: (TagListItem) -> Void

    var body: some View {
        Button("创建时光故事…") { action(tag) }
            .persistentHelp("以这个标签的已确认照片进入自由编排工作区。")
            .accessibilityIdentifier("timeStoryCreateFromTag")
    }
}

private enum OpenMontageResultSaveError: LocalizedError {
    case directoryAuthorizationRequired
    case invalidDestination
    case fileAlreadyExists

    var errorDescription: String? {
        switch self {
        case .directoryAuthorizationRequired:
            "无法写入所选文件夹，请重新选择保存位置。"
        case .invalidDestination:
            "成片只能另存到刚刚选择的文件夹中。"
        case .fileAlreadyExists:
            "所选文件夹已有同名文件，请更换文件名；现有文件未被覆盖。"
        }
    }
}

@MainActor
final class TimeStoryWorkspaceModel: ObservableObject {
    @Published private(set) var project: TimeStoryProject? {
        didSet {
            if var current = project, var selection = current.styleTemplate,
               let ids = selection.shotIDs, ids != current.shots.map(\.id) {
                let map = Dictionary(zip(ids, selection.lines), uniquingKeysWith: { first, _ in first })
                selection.lines = current.shots.map { map[$0.id] ?? $0.caption }
                selection.shotIDs = current.shots.map(\.id)
                current.styleTemplate = selection
                project = current
            }
            guard !restoringHistory, let oldValue, let project, oldValue.id == project.id,
                  oldValue != project else { return }
            undoProjects.append(oldValue)
            if undoProjects.count > 50 { undoProjects.removeFirst() }
            redoProjects.removeAll()
        }
    }
    @Published private var undoProjects: [TimeStoryProject] = []
    @Published private var redoProjects: [TimeStoryProject] = []
    private var restoringHistory = false
    private let thumbnailGate = LibraryThumbnailLoadGate(limit: 4)
    private var thumbnailTasks: [UUID: Task<NSImage?, Never>] = [:]
    @Published private(set) var failedThumbnails: Set<UUID> = []
    var canUndo: Bool { !undoProjects.isEmpty }
    var canRedo: Bool { !redoProjects.isEmpty }
    func undo() { restoreHistory(undo: true) }
    func redo() { restoreHistory(undo: false) }
    private func restoreHistory(undo: Bool) {
        guard let current = project, let value = undo ? undoProjects.popLast() : redoProjects.popLast() else { return }
        restoringHistory = true
        if undo { redoProjects.append(current) } else { undoProjects.append(current) }
        project = value
        restoringHistory = false
        Task { await loadThumbnails() }
    }
    func setTitleCards(projectTitle: Bool? = nil, chapters: Bool? = nil) {
        guard var edited = project else { return }
        if let projectTitle { edited.showsProjectTitle = projectTitle }
        if let chapters { edited.showsChapterTitles = chapters }
        project = edited
    }
    func useFreeform() {
        guard var edited = project else { return }
        edited.isFreeform = true
        edited.showsProjectTitle = false
        edited.showsChapterTitles = false
        if edited.title == "\(edited.subjectTagDisplayName) · 成长与足迹" { edited.title = edited.subjectTagDisplayName }
        project = edited
    }
    func chooseTaskDirectory() {
        let settings = OpenMontageSettingsModel()
        settings.chooseTaskRoot()
        Task { await refreshOpenMontageCapability() }
    }

    @Published private(set) var readinessSnapshot: TimeStoryCandidateSnapshot?
    @Published private(set) var loadedCandidateCount = 0
    @Published private(set) var isReadingCandidates = false
    @Published private(set) var projects: [TimeStoryProjectSummary] = []
    @Published private(set) var candidateThumbnails: [UUID: NSImage] = [:]
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    @Published private(set) var isBusy = false
    @Published private(set) var exportProgress: TimeStoryRenderProgress?
    @Published private(set) var packageExportProgress: TimeStoryPackageProgress?
    @Published private(set) var openMontageCapability: OpenMontageExecutorCapability?
    @Published private(set) var openMontageTask: OpenMontageStoryTaskSnapshot?
    @Published private(set) var lastExportURL: URL?
    @Published private(set) var lastPackageURL: URL?
    @Published private(set) var creativeStatus = "本地创作插件 · 由 Agent 创作方案"
    @Published private(set) var creativePlan: StoryCreativePlan?
    @Published private(set) var atelierStatus = "Atelier 创作项目 · Agent 协作"
    @Published private(set) var atelierProposal: StoryAtelierProposal?
    @Published private(set) var selectedAtelierRequestID: String?
    @Published var atelierFeedback = ""
    @Published var styleTemplates = StoryStyleTemplate.builtins
    @Published var styleStatus = "选择模板后校对文案，再制作。"
    @Published var styleResultURL: URL?
    private var stylePollingTask: Task<Void, Never>?
    private var styleExchange: StoryStyleExchange {
        .init(rootProvider: runtime.creativeRootProvider, exporter: runtime.packageExporter)
    }
    private var styleCatalog: StoryStyleCatalog {
        .init(directory: runtime.store.rootDirectory.deletingLastPathComponent().appendingPathComponent("StyleTemplates/v1"))
    }
    func loadStyleTemplates() {
        do { styleTemplates = try styleCatalog.load() }
        catch { styleStatus = error.localizedDescription }
    }
    func applyStyle(_ template: StoryStyleTemplate) {
        guard var current = project else { return }
        current.styleTemplate = .init(template: template, lines: current.styleTemplate?.lines ?? current.shots.map { shot in
            if let title = current.chapters.first(where: { $0.id == shot.chapterID })?.title,
               current.showsChapterTitles != false { return title }
            return shot.caption
        }, shotIDs: current.shots.map(\.id))
        current.styleReceipt = nil
        project = current
        styleResultURL = nil
        styleStatus = "已套用样式，照片、顺序与时长已保留。请校对文案后制作；可撤销。"
    }
    func editStyle(_ selection: StoryStyleSelection) {
        project?.styleTemplate = selection
        styleResultURL = nil
    }
    func saveStyleVariant(name: String) {
        guard let selection = project?.styleTemplate else { return }
        do {
            let value = try styleCatalog.saveVariant(selection.template, name: name)
            project?.styleTemplate?.template = value
            loadStyleTemplates()
            styleStatus = "已另存为个人模板，仅保存样式参数。"
        } catch { styleStatus = error.localizedDescription }
    }
    func checkStyleConnection() {
        styleStatus = "正在检查模板制作端…"
        do { let value = try styleExchange.capability(); styleStatus = "模板制作端已连接 · \(value.implementations.count) 种样式可用" }
        catch { styleStatus = error.localizedDescription }
    }
    func renderStyle() async {
        guard let current = project, !isBusy else { return }
        isBusy = true
        styleStatus = "正在准备当前故事素材…"
        defer { isBusy = false }
        do {
            let receipt = try await styleExchange.publish(current)
            guard var edited = project, edited.id == current.id else { return }
            edited.styleReceipt = receipt
            try runtime.store.save(edited)
            project = edited
            styleResultURL = nil
            styleStatus = "已提交，等待本地制作端。"
            pollStyle(receipt)
        } catch { styleStatus = error.localizedDescription }
    }
    func refreshStyleResult() async {
        guard let receipt = project?.styleReceipt else { checkStyleConnection(); return }
        do {
            guard let result = try styleExchange.status(receipt) else {
                _ = try styleExchange.capability()
                styleStatus = "排队中，等待本地制作端。"; return
            }
            styleStatus = result.detail
            if result.status == "succeeded" {
                styleResultURL = try await styleExchange.verifiedURL(receipt)
                styleStatus = "成片已核验 · 9:16 · 30 fps · \(result.frames ?? 0) 帧"
            }
        } catch { styleStatus = error.localizedDescription }
    }
    private func pollStyle(_ receipt: StoryStyleReceipt) {
        stylePollingTask?.cancel()
        stylePollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.project?.styleReceipt == receipt else { return }
                await self.refreshStyleResult()
                if self.styleResultURL != nil { return }
                if let result = try? self.styleExchange.status(receipt), result.status == "failed" { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    @Published var message: String?

    private var creativePlugin: StoryCreativePlugin {
        StoryCreativePlugin(rootProvider: runtime.creativeRootProvider,
                            exporter: runtime.packageExporter, validator: runtime.validator)
    }
    private var atelierExchange: StoryAtelierExchange {
        StoryAtelierExchange(rootProvider: runtime.creativeRootProvider,
                             media: runtime.media, validator: runtime.validator)
    }
    var selectedAtelierReceipt: StoryAtelierReceipt? {
        let receipts = project?.atelierVersions ?? []
        return receipts.first(where: { $0.requestID == selectedAtelierRequestID }) ?? receipts.last
    }
    func selectAtelierVersion(_ id: String) {
        selectedAtelierRequestID = id
        atelierProposal = nil
        refreshAtelierStatus()
    }
    func publishAtelierRequest(feedback: String? = nil) async {
        guard let current = project, !isBusy else { return }
        let parentRevision = feedback == nil ? nil : selectedAtelierReceipt?.projectRevision
        isBusy = true
        atelierStatus = "正在发布已确认候选快照…"
        defer { isBusy = false }
        do {
            let receipt = try await atelierExchange.publish(
                project: current, feedback: feedback, parentProjectRevision: parentRevision)
            guard var edited = project, edited.id == current.id else { return }
            edited.atelierVersions = (edited.atelierVersions ?? []) + [receipt]
            try runtime.store.save(edited)
            project = edited
            selectedAtelierRequestID = receipt.requestID
            atelierProposal = nil
            atelierFeedback = ""
            atelierStatus = "等待创作 Agent · 本次发布 \(current.shots.count) 张已选照片"
            await refreshProjects()
        } catch { atelierStatus = error.localizedDescription }
    }
    func refreshAtelierStatus() {
        guard let receipt = selectedAtelierReceipt else { return }
        do { atelierStatus = try atelierExchange.status(receipt) }
        catch { atelierStatus = error.localizedDescription }
    }
    func readAtelierProposal() async {
        guard let current = project, let receipt = selectedAtelierReceipt else { return }
        do {
            let proposal = try atelierExchange.loadProposal(receipt, project: current)
            atelierProposal = proposal
            var edited = current
            if let index = edited.atelierVersions?.firstIndex(where: { $0.requestID == receipt.requestID }) {
                edited.atelierVersions?[index].projectRevision = proposal.projectRevision
                edited.atelierVersions?[index].proposalSHA256 = try atelierExchange.proposalHash(receipt)
                try runtime.store.save(edited)
                project = edited
            }
            atelierStatus = "项目已核验 · 审阅摘要后可提交制作。"
        } catch { atelierProposal = nil; atelierStatus = error.localizedDescription }
    }
    func requestAtelierRender() async {
        guard let current = project, let receipt = selectedAtelierReceipt else { return }
        do {
            _ = try atelierExchange.requestRender(receipt, project: current)
            atelierStatus = "制作任务已提交；等待可信本地 OpenMontage 进程处理。"
        } catch { atelierStatus = error.localizedDescription }
    }
    func openAtelierResult() async {
        guard let current = project, let receipt = selectedAtelierReceipt else { return }
        do {
            let (result, url) = try await atelierExchange.verifiedResult(receipt, project: current)
            var edited = current
            if let index = edited.atelierVersions?.firstIndex(where: { $0.requestID == receipt.requestID }) {
                edited.atelierVersions?[index].resultSHA256 = result.outputSHA256
                try runtime.store.save(edited)
                project = edited
            }
            atelierStatus = "成片已核验：\(result.frames ?? 0) 帧，可打开审片。"
            NSWorkspace.shared.open(url)
        } catch { atelierStatus = error.localizedDescription }
    }
    func cancelAtelierRequest() {
        guard let receipt = selectedAtelierReceipt else { return }
        do { try atelierExchange.cancel(receipt); atelierProposal = nil; refreshAtelierStatus() }
        catch { atelierStatus = error.localizedDescription }
    }
    func setCreativeIntent(_ value: String) { project?.creativeIntent = String(value.prefix(4000)) }
    func setCreativeTarget(_ seconds: Int) { project?.creativeTargetFrames = seconds * 30 }
    func publishCreativeRequest(aspect: TimeStoryPackageAspect) async {
        guard let current = project, !isBusy else { return }
        isBusy = true
        creativeStatus = "正在发布限定范围的创作请求…"
        defer { isBusy = false }
        do {
            let receipt = try await creativePlugin.publish(project: current, aspect: aspect)
            // Publishing does not replace concurrent editor changes.
            guard var edited = project, edited.id == current.id else { return }
            edited.creativeReceipt = receipt
            project = edited
            try runtime.store.save(edited)
            creativePlan = nil
            creativeStatus = "等待创作 Agent · 仅发布本故事照片；未授权云上传"
            await refreshProjects()
        } catch { creativeStatus = error.localizedDescription }
    }
    func refreshCreativeRequest() {
        guard let receipt = project?.creativeReceipt else { return }
        do { creativeStatus = try creativePlugin.status(receipt) }
        catch { creativeStatus = error.localizedDescription }
    }
    func readCreativePlan() {
        guard let receipt = project?.creativeReceipt, let current = project else { return }
        do {
            let (request, plan, digest) = try creativePlugin.loadPlan(receipt)
            _ = try creativePlugin.apply(plan, request: request, digest: digest, to: current)
            creativePlan = plan
            creativeStatus = "方案已校验 · 查看创作说明后应用到编辑器"
        } catch { creativePlan = nil; creativeStatus = error.localizedDescription }
    }
    func applyCreativePlan() async {
        guard let receipt = project?.creativeReceipt, let current = project else { return }
        do {
            let (request, plan, digest) = try creativePlugin.loadPlan(receipt)
            let updated = try creativePlugin.apply(plan, request: request, digest: digest, to: current)
            try runtime.store.save(updated)
            project = updated
            creativePlan = nil
            creativeStatus = "方案已应用并保存；可继续编辑，然后用本地制作冻结成片。"
            await refreshProjects()
            await loadThumbnails()
        } catch { creativeStatus = error.localizedDescription }
    }
    func cancelCreativeRequest() {
        guard let receipt = project?.creativeReceipt else { return }
        do { try creativePlugin.cancel(receipt); creativePlan = nil; refreshCreativeRequest() }
        catch { creativeStatus = error.localizedDescription }
    }

    private let runtime: TimeStoryFeatureRuntime
    private let initialTag: TagListItem
    private var exportTask: Task<Void, Never>?
    private var packageExportTask: Task<Void, Never>?
    private var openMontageSubmissionTask: Task<Void, Never>?
    private var openMontagePollingTask: Task<Void, Never>?
    private var candidateTask: Task<TimeStoryCandidateSnapshot, Error>?

    var readinessPreview: TimeStoryReadinessSummary? {
        readinessSnapshot.map { runtime.planner.readiness(for: $0) }
    }

    init(runtime: TimeStoryFeatureRuntime, tag: TagListItem) {
        self.runtime = runtime
        initialTag = tag
    }

#if DEBUG
    init(
        verificationRuntime runtime: TimeStoryFeatureRuntime,
        tag: TagListItem,
        project: TimeStoryProject,
        thumbnails: [UUID: NSImage]
    ) {
        self.runtime = runtime
        initialTag = tag
        self.project = project
        self.thumbnails = thumbnails
        message = "合成验收模式：未读取真实照片。"
    }
#endif

    deinit {
        exportTask?.cancel()
        packageExportTask?.cancel()
        openMontageSubmissionTask?.cancel()
        openMontagePollingTask?.cancel()
        candidateTask?.cancel()
        thumbnailTasks.values.forEach { $0.cancel() }
    }

    func start() async {
        guard !isBusy else { return }
        await refreshProjects()
        if project == nil {
            await loadReadiness()
        }
        await refreshOpenMontageCapability()
        await recoverOpenMontageTask()
        refreshCreativeRequest()
        selectedAtelierRequestID = project?.atelierVersions?.last?.requestID
        refreshAtelierStatus()
    }

    func cancelCandidateLoading() { candidateTask?.cancel() }

    private func fetchSnapshot(for tag: TagListItem) async throws -> TimeStoryCandidateSnapshot {
        let runtime = runtime
        let now = runtime.clock.nowMs
        loadedCandidateCount = 0
        isReadingCandidates = true
        defer { isReadingCandidates = false }
        let progress: @Sendable (Int) -> Void = { [weak self] count in
            Task { @MainActor in self?.loadedCandidateCount = count }
        }
        let task = Task.detached(priority: .userInitiated) {
            try runtime.candidates.snapshot(tag: tag, nowMs: now, onProgress: progress)
        }
        candidateTask = task
        defer { candidateTask = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func loadReadiness() async {
        guard !isBusy else { return }
        isBusy = true
        message = "正在读取已确认的主体候选…"
        do {
            readinessSnapshot = try await fetchSnapshot(for: initialTag)
            message = "素材就绪报告已生成；确认后可生成故事草稿。"
        } catch is CancellationError {
            message = "候选读取已取消。"
        } catch {
            message = error.localizedDescription
        }
        isBusy = false
    }

    func createDraft(for tag: TagListItem) async {
        isBusy = true
        message = "正在冻结候选清单并生成草稿…"
        let runtime = runtime
        do {
            let now = runtime.clock.nowMs
            let snapshot = try await fetchSnapshot(for: tag)
            let project = runtime.planner.makeFreeformProject(snapshot: snapshot, nowMs: now)
            readinessSnapshot = snapshot
            self.project = project
            undoProjects = []; redoProjects = []
            message = "自由编排已就绪，拖入照片开始。"
            await loadThumbnails()
        } catch is CancellationError {
            message = "候选读取已取消。"
        } catch {
            message = error.localizedDescription
        }
        isBusy = false
    }

    func open(_ id: UUID) async {
        isBusy = true
        let store = runtime.store
        do {
            project = try await Task.detached { try store.load(id) }.value
            undoProjects = []; redoProjects = []
            message = "故事项目已重新打开。"
            creativePlan = nil
            refreshCreativeRequest()
            selectedAtelierRequestID = project?.atelierVersions?.last?.requestID
            atelierProposal = nil
            refreshAtelierStatus()
            await loadThumbnails()
        } catch {
            message = error.localizedDescription
        }
        isBusy = false
    }

    @discardableResult
    func save() async -> Bool {
        guard var project else { return false }
        isBusy = true
        defer { isBusy = false }
        project.updatedAtMs = runtime.clock.nowMs
        let store = runtime.store
        let projectToSave = project
        do {
            try await Task.detached { try store.save(projectToSave) }.value
            self.project = project
            await refreshProjects()
            message = "故事项目已保存。"
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func openSavedProject(_ id: UUID) async {
        guard !isBusy else { return }
        if project != nil, !(await save()) { return }
        await open(id)
    }

    func regenerate() async {
        guard let current = project else { return }
        let unknownIDs = Set(current.candidateSnapshot.candidates.filter { $0.mediaCreatedAtMs == nil }.map(\.assetID))
        guard !current.shots.contains(where: { unknownIDs.contains($0.assetID) }) else {
            message = "当前含有手动加入的时间未知照片，无法按时间重新生成；可继续手动编排、保存和导出。"
            return
        }
        isBusy = true
        message = "正在重新读取当前主体候选并生成…"
        let runtime = runtime
        do {
            let tag = TagListItem(id: current.subjectTagID, displayName: current.subjectTagDisplayName, state: .active)
            let snapshot = try await fetchSnapshot(for: tag)
            let regenerated = try runtime.planner.makeProject(snapshot: snapshot, nowMs: runtime.clock.nowMs, existing: current)
            project = regenerated
            readinessSnapshot = snapshot
            message = "已重新生成，并保留锁定、排除和明确编辑。"
            await loadThumbnails()
        } catch is CancellationError {
            message = "候选读取已取消，原草稿保持不变。"
        } catch {
            message = error.localizedDescription
        }
        isBusy = false
    }

    func setChapterTitle(_ chapterID: UUID, title: String) {
        guard var project,
              let index = project.chapters.firstIndex(where: { $0.id == chapterID })
        else { return }
        project.chapters[index].title = String(title.prefix(240))
        project.chapters[index].isUserEdited = true
        var overrides = project.chapterTitleOverrides ?? [:]
        overrides[chapterID] = project.chapters[index].title
        project.chapterTitleOverrides = overrides
        project.updatedAtMs = runtime.clock.nowMs
        self.project = project
    }

    func setProjectTitle(_ title: String) {
        guard var project else { return }
        project.title = String(title.prefix(240))
        project.updatedAtMs = runtime.clock.nowMs
        self.project = project
    }

    func setCaption(_ shotID: UUID, caption: String) {
        guard var project,
              let index = project.shots.firstIndex(where: { $0.id == shotID })
        else { return }
        project.shots[index].caption = String(caption.prefix(240))
        project.shots[index].isUserEdited = true
        project.updatedAtMs = runtime.clock.nowMs
        self.project = project
    }

    /// Publish once so an entire batch is one undo step.
    func editShots(_ ids: Set<UUID>, duration: Double? = nil,
                   mode: TimeStoryPresentationMode? = nil, locked: Bool? = nil,
                   clearCaptions: Bool = false, remove: Bool = false) {
        guard var edited = project, !ids.isEmpty else { return }
        for index in edited.shots.indices where ids.contains(edited.shots[index].id) {
            if let duration, duration.isFinite { edited.shots[index].durationSeconds = min(12, max(1.5, duration)) }
            if let mode { edited.shots[index].presentationMode = mode }
            if let locked {
                edited.shots[index].isLocked = locked
                edited.shots[index].reasons.removeAll { $0 == "用户锁定" }
                if locked { edited.shots[index].reasons.append("用户锁定") }
            }
            if clearCaptions { edited.shots[index].caption = "" }
            edited.shots[index].isUserEdited = true
        }
        if remove {
            edited.excludedAssetIDs.formUnion(edited.shots.filter { ids.contains($0.id) }.map(\.assetID))
            edited.shots.removeAll { ids.contains($0.id) }
            for index in edited.chapters.indices { edited.chapters[index].shotIDs.removeAll { ids.contains($0) } }
            edited.chapters.removeAll { $0.shotIDs.isEmpty }
        }
        edited.updatedAtMs = runtime.clock.nowMs
        project = edited
    }

    func setDuration(_ shotID: UUID, seconds: Double) {
        guard var project,
              let index = project.shots.firstIndex(where: { $0.id == shotID })
        else { return }
        project.shots[index].durationSeconds = min(12, max(1.5, seconds))
        project.shots[index].isUserEdited = true
        project.updatedAtMs = runtime.clock.nowMs
        self.project = project
    }

    func toggleLock(_ shotID: UUID) {
        guard var project,
              let index = project.shots.firstIndex(where: { $0.id == shotID })
        else { return }
        project.shots[index].isLocked.toggle()
        if project.shots[index].isLocked {
            if !project.shots[index].reasons.contains("用户锁定") {
                project.shots[index].reasons.append("用户锁定")
            }
        } else {
            project.shots[index].reasons.removeAll { $0 == "用户锁定" }
        }
        project.updatedAtMs = runtime.clock.nowMs
        self.project = project
    }

    func remove(_ shotID: UUID) {
        guard var project,
              let shot = project.shots.first(where: { $0.id == shotID })
        else { return }
        project.excludedAssetIDs.insert(shot.assetID)
        project.shots.removeAll { $0.id == shotID }
        for index in project.chapters.indices {
            project.chapters[index].shotIDs.removeAll { $0 == shotID }
        }
        project.chapters.removeAll { $0.shotIDs.isEmpty }
        project.updatedAtMs = runtime.clock.nowMs
        self.project = project
        thumbnails.removeValue(forKey: shotID)
    }

    func replace(_ shotID: UUID, with candidate: TimeStoryCandidate) async {
        guard var project,
              let index = project.shots.firstIndex(where: { $0.id == shotID }),
              runtime.planner.manuallyEditableCandidates(in: project, replacing: shotID).contains(where: { $0.assetID == candidate.assetID })
        else { return }
        let previousAssetID = project.shots[index].assetID
        project.excludedAssetIDs.insert(previousAssetID)
        project.shots[index].assetID = candidate.assetID
        project.shots[index].contentRevision = candidate.contentRevision
        project.shots[index].caption = candidate.placeName ?? project.subjectTagDisplayName
        project.shots[index].reasons = ["用户替换", "用户锁定"]
        project.shots[index].isLocked = true
        project.shots[index].isUserEdited = true
        project.updatedAtMs = runtime.clock.nowMs
        self.project = project
        await loadThumbnail(for: project.shots[index])
    }

    func setMusic(url: URL?) {
        guard var project else { return }
        project.music = url.map {
            let bookmark = try? $0.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return TimeStoryMusicSelection(
                displayName: $0.lastPathComponent,
                filePath: $0.path,
                securityScopedBookmark: bookmark
            )
        }
        project.updatedAtMs = runtime.clock.nowMs
        self.project = project
    }

    func replacementCandidates(for shotID: UUID) -> [TimeStoryCandidate] {
        guard let project else { return [] }
        return runtime.planner.manuallyEditableCandidates(in: project, replacing: shotID).filter { candidate in
            candidate.assetID != project.shots.first(where: { $0.id == shotID })?.assetID
        }
    }

    var addableCandidates: [TimeStoryCandidate] {
        guard let project else { return [] }
        return runtime.planner.manuallyEditableCandidates(in: project)
    }

    func addCandidate(_ candidate: TimeStoryCandidate) async {
        guard let current = project else { return }
        do {
            let updated = try runtime.planner.manuallyInserting(candidate, in: current, nowMs: runtime.clock.nowMs)
            project = updated
            if let shot = updated.shots.first(where: { $0.assetID == candidate.assetID }) {
                await loadThumbnail(for: shot)
            }
            message = "已从本次限定候选补入照片；请核对顺序、字幕并保存。"
        } catch { message = error.localizedDescription }
    }

    func moveShots(_ ids: Set<UUID>, before targetID: UUID?) {
        guard var edited = project, targetID.map({ !ids.contains($0) }) ?? true else { return }
        let ordered = edited.shots.filter { ids.contains($0.id) }.map(\.id)
        do {
            for id in ordered { edited = try runtime.planner.moving(id, before: targetID, in: edited, nowMs: runtime.clock.nowMs) }
            project = edited
        } catch { message = error.localizedDescription }
    }

    func moveShot(_ id: UUID, before targetID: UUID?) {
        guard let current = project else { return }
        do { project = try runtime.planner.moving(id, before: targetID, in: current, nowMs: runtime.clock.nowMs) }
        catch { message = error.localizedDescription }
    }

    func loadCandidateThumbnail(_ candidate: TimeStoryCandidate) async {
        guard candidate.availability == .available else { return }
        _ = await thumbnail(assetID: candidate.assetID)
    }

    private func thumbnail(assetID: UUID) async -> NSImage? {
        if let cached = candidateThumbnails[assetID] { return cached }
        if let pending = thumbnailTasks[assetID] { return await pending.value }
        let media = runtime.media
        let gate = thumbnailGate
        let task = Task.detached(priority: .userInitiated) { () -> NSImage? in
            for attempt in 0..<2 {
                do {
                    let data = try await gate.withPermit { try await media.loadStoryThumbnail(assetID: assetID) }
                    try Task.checkCancellation()
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceShouldCacheImmediately: true,
                            kCGImageSourceThumbnailMaxPixelSize: 480
                          ] as CFDictionary) else { return nil }
                    return NSImage(cgImage: cg, size: .zero)
                } catch is CancellationError { return nil }
                catch { if attempt == 0 { try? await Task.sleep(for: .milliseconds(250)) } }
            }
            return nil
        }
        thumbnailTasks[assetID] = task
        let image = await task.value
        thumbnailTasks[assetID] = nil
        if let image { candidateThumbnails[assetID] = image; failedThumbnails.remove(assetID) }
        else { failedThumbnails.insert(assetID) }
        return image
    }

    func export(to destination: URL) {
        guard let project, exportTask == nil else { return }
        exportProgress = TimeStoryRenderProgress(phase: .preparing, fraction: 0)
        message = "正在导出 MP4…"
        let runtime = runtime
        let (progressStream, progressContinuation) = AsyncStream<TimeStoryRenderProgress>.makeStream()
        let progressTask = Task { @MainActor [weak self] in
            for await progress in progressStream {
                self?.exportProgress = progress
            }
        }
        exportTask = Task { [weak self] in
            do {
                let issues = try await Task.detached {
                    try runtime.validator.validate(project)
                }.value
                guard issues.isEmpty else {
                    throw TimeStoryError.mediaValidationFailed(issues)
                }
                try await runtime.renderer.render(
                    project: project,
                    destinationURL: destination,
                    onProgress: { progressContinuation.yield($0) }
                )
                guard !Task.isCancelled else { throw CancellationError() }
                self?.lastExportURL = destination
                self?.message = "MP4 已导出：\(destination.lastPathComponent)"
            } catch is CancellationError {
                self?.message = "导出已取消；没有发布不完整成片。"
            } catch let TimeStoryError.mediaValidationFailed(issues) {
                let detail = issues.prefix(3).map {
                    "镜头 \($0.shotIndex)（\($0.assetID.uuidString.prefix(8))…）：\($0.kind.rawValue)"
                }.joined(separator: "；")
                self?.message = "导出前检查未通过：\(detail)"
            } catch {
                self?.message = error.localizedDescription
            }
            progressContinuation.finish()
            progressTask.cancel()
            await progressTask.value
            self?.exportProgress = nil
            self?.exportTask = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func exportPackage(to destination: URL, aspect: TimeStoryPackageAspect) {
        guard let project, packageExportTask == nil else { return }
        packageExportProgress = TimeStoryPackageProgress(phase: .preparingAssets, fraction: 0)
        message = "正在导出供外部制作工具使用的素材与制作方案…"
        let exporter = runtime.packageExporter
        let (progressStream, progressContinuation) = AsyncStream<TimeStoryPackageProgress>.makeStream()
        let progressTask = Task { @MainActor [weak self] in
            for await progress in progressStream {
                self?.packageExportProgress = progress
            }
        }
        packageExportTask = Task { [weak self] in
            do {
                let result = try await exporter.export(
                    project: project,
                    aspect: aspect,
                    destinationURL: destination,
                    onProgress: { progressContinuation.yield($0) }
                )
                try Task.checkCancellation()
                self?.lastPackageURL = result.packageURL
                self?.message = "故事包已导出：\(destination.lastPathComponent)（\(result.totalFrames) 帧）"
            } catch is CancellationError {
                self?.message = "故事包导出已取消；既有故事包没有被修改。"
            } catch let TimeStoryError.mediaValidationFailed(issues) {
                let detail = issues.prefix(3).map {
                    "镜头 \($0.shotIndex)（\($0.assetID.uuidString.prefix(8))…）：\($0.kind.rawValue)"
                }.joined(separator: "；")
                self?.message = "导出前后素材版本检查未通过：\(detail)"
            } catch {
                self?.message = error.localizedDescription
            }
            progressContinuation.finish()
            progressTask.cancel()
            await progressTask.value
            self?.packageExportProgress = nil
            self?.packageExportTask = nil
        }
    }

    func cancelPackageExport() {
        packageExportTask?.cancel()
    }

    func submitToOpenMontage(aspect: TimeStoryPackageAspect) {
        guard let project,
              openMontageSubmissionTask == nil,
              openMontageTask?.phase.isTerminal != false
        else {
            if openMontageTask?.phase.isTerminal == false {
                message = OpenMontageTaskError.taskAlreadyActive.localizedDescription
            }
            return
        }
        let frozenProject = project
        let client = runtime.openMontageTasks
        message = "正在准备素材并发布 OpenMontage 制作任务…"
        let (progressStream, progressContinuation) =
            AsyncStream<OpenMontageStoryTaskSnapshot>.makeStream()
        let progressTask = Task { @MainActor [weak self] in
            for await snapshot in progressStream {
                guard self?.openMontageTask?.taskID == nil
                        || self?.openMontageTask?.taskID == snapshot.taskID
                else { continue }
                self?.openMontageTask = snapshot
            }
        }
        openMontageSubmissionTask = Task { [weak self] in
            do {
                let snapshot = try await client.submit(
                    project: frozenProject,
                    aspect: aspect,
                    onProgress: { progressContinuation.yield($0) }
                )
                guard !Task.isCancelled else { return }
                self?.openMontageTask = snapshot
                self?.message = "任务已发布，正在等待 OpenMontage 制作。"
                self?.startOpenMontagePolling(taskID: snapshot.taskID)
            } catch is CancellationError {
                self?.message = "任务发布已取消；未发布可执行的半成品任务。"
            } catch {
                self?.message = error.localizedDescription
            }
            progressContinuation.finish()
            progressTask.cancel()
            await progressTask.value
            self?.openMontageSubmissionTask = nil
        }
    }

    func cancelOpenMontageTask() {
        guard let taskID = openMontageTask?.taskID,
              openMontageTask?.phase.isTerminal == false
        else { return }
        let client = runtime.openMontageTasks
        Task { [weak self] in
            do {
                let snapshot = try await client.requestCancellation(taskID: taskID)
                guard self?.openMontageTask?.taskID == taskID else { return }
                self?.openMontageTask = snapshot
                self?.message = "已请求 OpenMontage 取消这次制作。"
            } catch {
                self?.message = error.localizedDescription
            }
        }
    }

    @Published private(set) var isStartingLocalEngine = false

    func startLocalEngine() async {
        guard !isStartingLocalEngine else { return }
        isStartingLocalEngine = true
        connectionCheckResult = "正在准备并启动本地制作组件…"
        styleStatus = "正在准备并启动本地制作组件…"
        defer { isStartingLocalEngine = false }
        do {
            let provider = runtime.creativeRootProvider
            let root = try provider.resolveTaskRoot()
            guard provider.startAccessing(root) else { throw OpenMontageTaskError.taskRootAuthorizationRequired }
            defer { provider.stopAccessing(root) }
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OpenMontage Helper.app")
            guard FileManager.default.fileExists(atPath: helper.path) else {
                throw StoryCreativeError.invalid("App 缺少本地制作组件，请重新安装完整版本。")
            }
            let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ImageAll/OpenMontageRuntime", isDirectory: true)
            let token = UUID().uuidString
            let request = try JSONSerialization.data(withJSONObject: ["token": token, "runtime": parent.path])
            try request.write(to: root.appendingPathComponent("launcher-request.json"), options: .atomic)
            let configuration = NSWorkspace.OpenConfiguration()
            var launchURL = URLComponents()
            launchURL.scheme = "imageall-openmontage"
            launchURL.host = "start"
            launchURL.queryItems = [URLQueryItem(name: "taskRoot", value: root.path),
                URLQueryItem(name: "runtime", value: parent.path), URLQueryItem(name: "token", value: token)]
            configuration.activates = false
            configuration.createsNewApplicationInstance = false
            // Launch first so Launch Services refreshes the helper registration after an App update.
            _ = try await NSWorkspace.shared.openApplication(at: helper, configuration: configuration)
            _ = try await NSWorkspace.shared.open([launchURL.url!], withApplicationAt: helper, configuration: configuration)
            for _ in 0..<120 {
                try await Task.sleep(for: .seconds(1))
                let capability = await runtime.openMontageTasks.capability()
                openMontageCapability = capability
                if capability.state == .ready {
                    connectionCheckResult = "本地制作已启动并连接 · \(root.lastPathComponent)"
                    checkStyleConnection()
                    return
                }
                if let data = try? Data(contentsOf: root.appendingPathComponent("launcher-result.json")),
                   let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   report["token"] as? String == token, report["success"] as? Bool == false {
                    throw StoryCreativeError.invalid(report["message"] as? String ?? "本地制作启动失败")
                }
            }
            throw StoryCreativeError.invalid("本地制作启动超时，请检查任务目录中的 launcher.log。")
        } catch {
            connectionCheckResult = error.localizedDescription
            styleStatus = error.localizedDescription
        }
    }

    @Published private(set) var isCheckingConnection = false
    @Published private(set) var connectionCheckResult: String?

    func refreshOpenMontageCapability() async {
        guard !isCheckingConnection else { return }
        isCheckingConnection = true
        defer { isCheckingConnection = false }
        openMontageCapability = await runtime.openMontageTasks.capability()
        let time = Date().formatted(date: .omitted, time: .standard)
        connectionCheckResult = "\(time) · \(openMontageCapability?.detail ?? "未获取到连接状态")"
    }

    func openOpenMontageResult() {
        withVerifiedOpenMontageResult { result in
            NSWorkspace.shared.open(result.fileURL)
        }
    }

    func revealOpenMontageResult() {
        withVerifiedOpenMontageResult { result in
            NSWorkspace.shared.activateFileViewerSelecting([result.fileURL])
        }
    }

    func saveOpenMontageResult(to destination: URL, in authorizedDirectory: URL) {
        withVerifiedOpenMontageResult { [weak self] result in
            do {
                let didAccess = authorizedDirectory.startAccessingSecurityScopedResource()
                guard didAccess else {
                    throw OpenMontageResultSaveError.directoryAuthorizationRequired
                }
                defer { authorizedDirectory.stopAccessingSecurityScopedResource() }
                try Self.copyVerifiedResult(
                    result,
                    to: destination,
                    in: authorizedDirectory
                )
                self?.message = "成片已另存为：\(destination.lastPathComponent)"
            } catch {
                self?.message = error.localizedDescription
            }
        }
    }

    private func recoverOpenMontageTask() async {
        guard let project, openMontageCapability?.state == .ready else { return }
        do {
            guard let snapshot = try await runtime.openMontageTasks.latestTask(projectID: project.id)
            else { return }
            openMontageTask = snapshot
            if !snapshot.phase.isTerminal {
                startOpenMontagePolling(taskID: snapshot.taskID)
            }
        } catch OpenMontageTaskError.taskRootNotConfigured {
            // Configuration is optional; the capability panel explains how to enable it.
        } catch {
            message = error.localizedDescription
        }
    }

    private func startOpenMontagePolling(taskID: String) {
        openMontagePollingTask?.cancel()
        let client = runtime.openMontageTasks
        openMontagePollingTask = Task { [weak self] in
            defer { self?.openMontagePollingTask = nil }
            while !Task.isCancelled {
                do {
                    let snapshot = try await client.task(taskID: taskID)
                    guard self?.openMontageTask?.taskID == taskID else { return }
                    self?.openMontageTask = snapshot
                    if snapshot.phase.isTerminal {
                        self?.message = Self.openMontageTerminalMessage(snapshot)
                        return
                    }
                } catch {
                    guard self?.openMontageTask?.taskID == taskID else { return }
                    self?.message = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func withVerifiedOpenMontageResult(
        perform: @escaping @MainActor (OpenMontageVerifiedResult) -> Void
    ) {
        guard let taskID = openMontageTask?.taskID else { return }
        let client = runtime.openMontageTasks
        Task { [weak self] in
            do {
                let result = try await client.verifiedResult(taskID: taskID)
                guard self?.openMontageTask?.taskID == taskID else { return }
                let didAccess = result.authorizedRootURL.startAccessingSecurityScopedResource()
                guard didAccess else {
                    throw OpenMontageTaskError.taskRootAuthorizationRequired
                }
                defer { result.authorizedRootURL.stopAccessingSecurityScopedResource() }
                perform(result)
            } catch {
                self?.message = error.localizedDescription
            }
        }
    }

    private static func copyVerifiedResult(
        _ result: OpenMontageVerifiedResult,
        to destination: URL,
        in authorizedDirectory: URL
    ) throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        guard parent.standardizedFileURL == authorizedDirectory.standardizedFileURL,
              parent.resolvingSymlinksInPath() == authorizedDirectory.resolvingSymlinksInPath(),
              fileManager.fileExists(atPath: parent.path)
        else {
            throw OpenMontageResultSaveError.invalidDestination
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw OpenMontageResultSaveError.fileAlreadyExists
        }
        let staging = parent.appendingPathComponent(
            ".imageall-openmontage-\(UUID().uuidString).tmp.mp4"
        )
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: result.fileURL, to: staging)
        guard try OpenMontageTaskFileValidation.sha256(staging) == result.fileSHA256 else {
            throw OpenMontageTaskError.resultValidationFailed("另存前文件哈希发生变化。")
        }
        try fileManager.moveItem(at: staging, to: destination)
    }

    private static func openMontageTerminalMessage(
        _ snapshot: OpenMontageStoryTaskSnapshot
    ) -> String {
        switch snapshot.phase {
        case .succeeded:
            "OpenMontage 已完成并验证成片。"
        case .failed:
            "OpenMontage 制作失败。\(snapshot.detail ?? "可在设置中检查执行器状态。")"
        case .cancelled:
            "这次 OpenMontage 制作已取消，没有发布成功成片。"
        case .interrupted:
            "执行器中断，任务状态无法确认；不会自动重新提交。"
        case .preparingAssets, .waitingForExecutor, .rendering, .verifyingResult:
            "OpenMontage 正在制作。"
        }
    }

    private func refreshProjects() async {
        let store = runtime.store
        do {
            projects = try await Task.detached { try store.list() }.value
        } catch {
            message = error.localizedDescription
        }
    }

    private func loadThumbnails() async {
        for shot in project?.shots ?? [] {
            guard !Task.isCancelled else { return }
            await loadThumbnail(for: shot)
        }
    }

    private func loadThumbnail(for shot: TimeStoryShot) async {
        if let image = await thumbnail(assetID: shot.assetID) { thumbnails[shot.id] = image }
    }

}

private struct StoryDropFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct TimeStoryWorkspaceView: View {
    @StateObject private var model: TimeStoryWorkspaceModel
    @State private var selectedShotID: UUID?
    @State private var selectedShotIDs: Set<UUID> = []
    @State private var selectionAnchor: UUID?
    @State private var batchDuration = 3.5
    @FocusState private var timelineFocused: Bool
    @State private var selectedCandidateID: UUID?
    @State private var replacementShotID: UUID?
    @State private var candidateSearch = ""
    @State private var bulkSelection = false
    @State private var pickedAssets: Set<UUID> = []
    @State private var inspectorTab = "镜头"
    @State private var productionMode = "当前编排"
    @State private var showStyleLibrary = false
    @State private var styleVariantName = ""
    @State private var stylePreviewPlayer: AVPlayer?
    @State private var productionAspect = TimeStoryPackageAspect.landscape
    @State private var showRegenerateConfirmation = false
    @State private var dropFrames: [String: CGRect] = [:]
    @State private var dragToken: String?
    @State private var dragLocation = CGPoint.zero

    init(model: TimeStoryWorkspaceModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        editor
        .frame(minWidth: 720, minHeight: 540)
        .coordinateSpace(name: "storyMontageCanvas")
        .onPreferenceChange(StoryDropFrameKey.self) { dropFrames = $0 }
        .overlay(alignment: .topLeading) {
            if let dragToken {
                Label(dragToken.hasPrefix("imageall-story-shot:") ? "移动镜头" : "添加 / 替换照片", systemImage: "hand.draw.fill")
                    .font(.callout.bold()).padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .position(x: dragLocation.x, y: dragLocation.y - 24)
                    .allowsHitTesting(false)
            }
        }
        .confirmationDialog("重新生成会按拍摄时间重新编排镜头。手动排序将被重置，锁定照片与明确编辑仍会保留。", isPresented: $showRegenerateConfirmation) {
            Button("重新生成") { Task { await model.regenerate() } }
        }
        .onChange(of: model.project?.id) { _, _ in
            selectedShotIDs = []; selectedShotID = nil; selectionAnchor = nil; selectedCandidateID = nil
        }
        .onChange(of: model.project?.shots.map(\.id)) { _, ids in
            selectedShotIDs.formIntersection(Set(ids ?? []))
            if let selectedShotID, !(ids ?? []).contains(selectedShotID) { self.selectedShotID = nil; selectedCandidateID = nil }
        }
        .task { await model.start() }
    }

    private func styleLibrary(_ project: TimeStoryProject) -> some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("OpenMontage 模板库").font(.headline); Spacer(); Button("收起") { showStyleLibrary = false } }
                    Text("9:16 · 保留当前照片、顺序和时长").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.styleTemplates) { template in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(template.name, systemImage: template.isPoem ? "text.below.photo" : "text.rectangle").font(.headline)
                            Text(template.isPoem ? "手写小字叠在照片内底部，带深灰柔边；不增加文字镜头。" : "简短文字卡淡出到照片，文字迅速交代内容。")
                                .font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Text(template.isPoem ? "自由场景 · 1.0.0" : "可编辑创作 · 1.0.0").font(.caption)
                                Spacer()
                                Button("示例预览") {
                                    if let url = Bundle.main.url(forResource: template.implementation, withExtension: "mp4") {
                                        stylePreviewPlayer = AVPlayer(url: url); stylePreviewPlayer?.play()
                                    }
                                }
                                Button("套用") { model.applyStyle(template) }
                                    .accessibilityIdentifier("applyStyle-" + template.id)
                            }
                        }.padding(12).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(12)
            }.frame(minWidth: 280, idealWidth: 330, maxWidth: 400)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let player = stylePreviewPlayer {
                        Text("合成素材样式示例 · 非当前故事").font(.caption).foregroundStyle(.secondary)
                        VideoPlayer(player: player).frame(height: 180)
                        Button("关闭示例") { player.pause(); stylePreviewPlayer = nil }
                    }
                    if let selection = project.styleTemplate {
                        Text(selection.template.name + " · 校对与制作").font(.headline)
                        Text("中央预览仍为原始编排；模板效果请看示例或制作后的成片。").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if selection.template.isPoem {
                                Stepper("字号 \(selection.template.fontSize)", value: styleIntBinding(\.fontSize), in: 24...64)
                                Stepper("距照片下沿 \(selection.template.bottomPercent)%", value: styleIntBinding(\.bottomPercent), in: 3...20)
                            } else {
                                Stepper("片头 \(selection.template.titleFrames) 帧", value: styleIntBinding(\.titleFrames), in: 1...90)
                                Stepper("文字卡 \(selection.template.cardFrames) 帧", value: styleIntBinding(\.cardFrames), in: 10...60)
                            }
                        }
                        Text(selection.template.isPoem ? "每行对应一张照片；相邻相同文案会连续显示，留空即纯享。" : "每行对应照片前的文字卡；相邻相同文案只出现一次，留空不加卡。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("制作视频") { Task { await model.renderStyle() } }.buttonStyle(.borderedProminent)
                                .disabled(model.isBusy || selection.lines.count != project.shots.count)
                                .accessibilityIdentifier("renderStyleVideo")
                            Button(model.isStartingLocalEngine ? "启动中…" : "启动本地制作") { Task { await model.startLocalEngine() } }
                                .disabled(model.isStartingLocalEngine).accessibilityIdentifier("storyStyleStartEngine")
                            Button("检查连接") { model.checkStyleConnection() }
                            Button("连接任务目录") { model.chooseTaskDirectory() }
                            Button("刷新结果") { Task { await model.refreshStyleResult() } }
                            if let url = model.styleResultURL { Button("播放上次成片") { NSWorkspace.shared.open(url) } }
                        }
                        HStack {
                            TextField("个人模板名称", text: $styleVariantName).frame(maxWidth: 220)
                            Button("另存为模板") { model.saveStyleVariant(name: styleVariantName) }.disabled(styleVariantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        ForEach(Array(project.shots.enumerated()), id: \.element.id) { index, shot in
                            HStack {
                                Text("\(index + 1)").monospacedDigit().frame(width: 25)
                                if let image = model.thumbnails[shot.id] {
                                    Image(nsImage: image).resizable().scaledToFit().frame(width: 44, height: 40)
                                }
                                TextField("此照片文案（可留空）", text: Binding(get: {
                                    let lines = model.project?.styleTemplate?.lines ?? []
                                    return index < lines.count ? lines[index] : ""
                                }, set: { text in
                                    guard var value = model.project?.styleTemplate else { return }
                                    while value.lines.count < project.shots.count { value.lines.append("") }
                                    value.lines[index] = String(text.prefix(80)); model.editStyle(value)
                                }))
                            }
                        }
                    } else { Text("从左侧选择一种样式。套用后可撤销；点击“制作视频”才会提交。") }
                    Text(model.styleStatus).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(12)
            }.frame(minWidth: 390)
        }.background(.background)
    }
    private func styleIntBinding(_ keyPath: WritableKeyPath<StoryStyleTemplate, Int>) -> Binding<Int> {
        Binding(get: { model.project?.styleTemplate?.template[keyPath: keyPath] ?? 0 }, set: { value in
            guard var selection = model.project?.styleTemplate else { return }
            selection.template[keyPath: keyPath] = value; model.editStyle(selection)
        })
    }

    private var editingActions: some View {
        HStack(spacing: 12) {
            TextField("项目名称", text: Binding(get: { model.project?.title ?? "" }, set: { model.setProjectTitle($0) }))
                .font(.headline).textFieldStyle(.plain).frame(maxWidth: 260)
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .help("撤销").disabled(!model.canUndo || model.isBusy)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .help("重做").disabled(!model.canRedo || model.isBusy)
            Button("保存") { Task { await model.save() } }
                .disabled(model.isBusy).accessibilityIdentifier("timeStorySaveButton")
            musicMenu
            Button("模板库", systemImage: "square.grid.2x2") {
                showStyleLibrary.toggle(); model.loadStyleTemplates()
            }.accessibilityIdentifier("timeStoryStyleLibrary")
            Button("制作设置") { inspectorTab = "创作" }
            Menu("导出") {
                Button("直接导出 MP4（横屏）…") { chooseExportDestination() }
                ForEach(TimeStoryPackageAspect.allCases) { aspect in
                    Button("故事包 · " + aspect.displayName + "…") { choosePackageDestination(aspect: aspect) }
                }
            }.disabled(model.project?.shots.isEmpty != false || model.isBusy || model.exportProgress != nil || model.packageExportProgress != nil)
                .accessibilityIdentifier("timeStoryExportButton")
        }.padding(12).background(.bar)
    }

    @ViewBuilder
    private var editor: some View {
        if let project = model.project {
            VStack(spacing: 0) {
                editingActions
                Divider()
                if showStyleLibrary { styleLibrary(project).frame(maxHeight: 370) }
                HSplitView {
                    materialBrowser(project)
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
                    VStack(spacing: 12) {
                        Spacer(minLength: 0)
                        if let id = selectedCandidateID, let image = previewImage(for: id) {
                            StoryPhotoFrame(image: image, mode: project.shots.first(where: { $0.id == selectedShotID && $0.assetID == id })?.presentationMode ?? .aspectFitBlack)
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            Button("返回成片预览") { selectedCandidateID = nil }
                        } else if project.shots.isEmpty {
                            ContentUnavailableView("拖入照片开始编排", systemImage: "film.stack",
                                description: Text("从左侧素材库添加照片，或在创作中选用自动模板。"))
                        } else {
                            TimeStoryTimelinePreview(project: project, thumbnails: model.thumbnails)
                        }
                        Spacer(minLength: 0)
                    }.padding(12).frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 0) {
                        Picker("属性", selection: $inspectorTab) {
                            Text("镜头").tag("镜头")
                            Text("创作").tag("创作")
                            Text("信息").tag("信息")
                        }.pickerStyle(.segmented).padding(10)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if inspectorTab == "镜头" {
                                    if selectedShotIDs.count > 1 { batchShotInspector }
                                    else if let shot = project.shots.first(where: { $0.id == selectedShotID }) { shotRow(shot) }
                                    else { Text("选中下方镜头，编辑字幕、时长或替换照片。").foregroundStyle(.secondary) }
                                } else if inspectorTab == "创作" {
                                    creationInspector(project)
                                } else {
                                    readinessBody(summary: runtimeSummary(project), snapshot: project.candidateSnapshot)
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.frame(minWidth: 275, idealWidth: 300, maxWidth: 360)
                }
                Divider()
                montageTimeline(project)
                statusBar
            }
            .disabled(model.isBusy)
            .navigationTitle(project.title)
        } else if let snapshot = model.readinessSnapshot {
            VStack(spacing: 18) {
                Image(systemName: "film.stack").font(.system(size: 42)).foregroundStyle(.secondary)
                Text(snapshot.tagDisplayName).font(.title2.bold())
                Text("\(snapshot.candidates.count) 张素材可供浏览，按自己的顺序自由编排。")
                Button("新建自由编排") { Task { await model.createDraft(for: TagListItem(
                    id: snapshot.tagID, displayName: snapshot.tagDisplayName, state: .active)) } }
                    .buttonStyle(.borderedProminent).disabled(model.isBusy)
                    .accessibilityIdentifier("timeStoryGenerateDraftButton")
                Menu("打开已保存故事") {
                    ForEach(model.projects) { saved in
                        Button(saved.title) { Task { await model.openSavedProject(saved.id) } }
                    }
                }.disabled(model.projects.isEmpty)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isBusy {
            VStack {
                ProgressView("已读取 \(model.loadedCandidateCount) 张主体候选…")
                Button("取消读取") { model.cancelCandidateLoading() }
            }
        } else {
            VStack(spacing: 12) {
                ContentUnavailableView("暂时无法读取候选", systemImage: "film", description: Text(model.message ?? "没有可用候选素材。"))
                Button("重试读取") { Task { await model.loadReadiness() } }
            }
        }
    }

    private func previewImage(for assetID: UUID) -> NSImage? {
        if let shot = model.project?.shots.first(where: { $0.assetID == assetID }), let image = model.thumbnails[shot.id] { return image }
        return model.candidateThumbnails[assetID]
    }

    private func materialBrowser(_ project: TimeStoryProject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("素材库", systemImage: "photo.on.rectangle.angled").font(.headline)
                Spacer()
                Menu("已保存") {
                    if model.projects.isEmpty { Text("尚无已保存故事") }
                    ForEach(model.projects) { saved in
                        Button(saved.title) {
                            Task { await model.openSavedProject(saved.id) }
                            selectedShotID = nil
                            replacementShotID = nil
                        }
                    }
                }
            }
            TextField("搜索文件名或地点", text: $candidateSearch).textFieldStyle(.roundedBorder)
            HStack {
                Toggle("多选", isOn: $bulkSelection).toggleStyle(.button)
                if bulkSelection {
                    Button("加入选中 (\(pickedAssets.count))") {
                        let chosen = visibleCandidates(project).filter { pickedAssets.contains($0.assetID) }
                        Task { for candidate in chosen { await model.addCandidate(candidate) }; pickedAssets = [] }
                    }.disabled(pickedAssets.isEmpty)
                }
            }
            if replacementShotID != nil {
                HStack {
                    Text("选择缩略图后点击替换").font(.caption)
                    Spacer()
                    Button("取消") { replacementShotID = nil }
                }
            } else {
                Text("拖到下方添加区加入故事；拖到镜头上替换照片。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 8)], spacing: 10) {
                    ForEach(visibleCandidates(project)) { candidate in
                        candidateCard(candidate, project: project)
                    }
                }
            }
            Text("\(visibleCandidates(project).count) 张素材 · 已选 \(project.shots.count) 张")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12)
        .accessibilityIdentifier("timeStoryMaterialBrowser")
    }

    private func visibleCandidates(_ project: TimeStoryProject) -> [TimeStoryCandidate] {
        let source = replacementShotID.map { model.replacementCandidates(for: $0) } ?? project.candidateSnapshot.candidates
        return source.filter {
            candidateSearch.isEmpty || ($0.fileName ?? "").localizedCaseInsensitiveContains(candidateSearch)
                || ($0.placeName ?? "").localizedCaseInsensitiveContains(candidateSearch)
        }
    }

    private func candidateCard(_ candidate: TimeStoryCandidate, project: TimeStoryProject) -> some View {
        let used = project.shots.contains { $0.assetID == candidate.assetID }
        let excluded = project.excludedAssetIDs.contains(candidate.assetID)
        let available = candidate.availability == .available && !used && !excluded
        return VStack(alignment: .leading, spacing: 5) {
            Group {
                if let image = model.candidateThumbnails[candidate.assetID] {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    if candidate.availability != .available {
                        Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                    } else if model.failedThumbnails.contains(candidate.assetID) {
                        Button("重试加载") { Task { await model.loadCandidateThumbnail(candidate) } }.font(.caption)
                    } else { ProgressView().controlSize(.small) }
                }
            }
            .frame(maxWidth: .infinity).frame(height: 88)
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(pickedAssets.contains(candidate.assetID) ? Color.accentColor : .clear, lineWidth: 3))
            .onTapGesture {
                if bulkSelection, available {
                    if pickedAssets.contains(candidate.assetID) { pickedAssets.remove(candidate.assetID) }
                    else { pickedAssets.insert(candidate.assetID) }
                } else { selectedCandidateID = candidate.assetID }
            }
            Text(candidate.mediaCreatedAtMs.map(captureDate) ?? "拍摄时间待确认")
                .font(.caption2).lineLimit(1)
            Text(candidate.placeName ?? candidate.fileName ?? "未记录地点")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            if used { Text("已加入").font(.caption).foregroundStyle(.tint) }
            else if excluded { Text("已从故事排除").font(.caption).foregroundStyle(.secondary) }
            else if candidate.availability != .available { Text("素材不可用").font(.caption).foregroundStyle(.secondary) }
            else {
                Button(replacementShotID == nil ? "＋ 加入故事" : "替换所选镜头") {
                    Task {
                        if let id = replacementShotID {
                            await model.replace(id, with: candidate)
                            replacementShotID = nil
                        } else { await model.addCandidate(candidate) }
                    }
                }.font(.caption)

            }
        }
        .padding(6)
        .background(selectedCandidateID == candidate.assetID ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .simultaneousGesture(storyDragGesture(available ? "imageall-story-asset:" + candidate.assetID.uuidString : "imageall-story-unavailable"))
        .background(dropFrameReader("imageall-story-asset:" + candidate.assetID.uuidString))
        .task(id: candidate.assetID) { await model.loadCandidateThumbnail(candidate) }
        .accessibilityIdentifier("timeStoryCandidateCard")
    }

    private func montageTimeline(_ project: TimeStoryProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("镜头编排", systemImage: "film").font(.headline)
                Text("\(formattedDuration(project.timelineDurationSeconds)) · 拖动镜头排序 / 拖入素材替换")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("已选 \(selectedShotIDs.count) · ⌘ 点选 / ⇧ 连选").font(.caption)
                Button("全选") { selectAllShots(project) }
                if !selectedShotIDs.isEmpty {
                    Menu("批量操作") { batchShotActions }
                }
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(project.shots) { shot in
                        VStack(alignment: .leading, spacing: 5) {
                            if project.showsChapterTitles ?? true, let chapter = project.chapters.first(where: { $0.id == shot.chapterID }), chapter.shotIDs.first == shot.id {
                                TextField("章节标题", text: Binding(get: {
                                    model.project?.chapters.first(where: { $0.id == chapter.id })?.title ?? chapter.title
                                }, set: { model.setChapterTitle(chapter.id, title: $0) }))
                                    .font(.caption.bold()).textFieldStyle(.plain)
                            } else { Text(" ").font(.caption) }
                            Group {
                                if let image = model.thumbnails[shot.id] { StoryPhotoFrame(image: image, mode: shot.presentationMode) }
                                else { Image(systemName: "photo") }
                            }.frame(width: 126, height: 75).background(Color.black.opacity(0.9))
                            Text("\(shot.durationSeconds, specifier: "%.1f") 秒 · \(shot.caption.isEmpty ? "无字幕" : shot.caption)")
                                .font(.caption).lineLimit(1)
                        }
                        .frame(width: 126).padding(7)
                        .background(selectedShotIDs.contains(shot.id) ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { selectShot(shot, in: project) }
                        .contentShape(Rectangle())
                        .simultaneousGesture(storyDragGesture("imageall-story-shot:" + shot.id.uuidString))
                        .background(dropFrameReader(shot.id.uuidString))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(dropHighlight(shot.id.uuidString), lineWidth: 2))
                        .contextMenu {
                            Button("向前移动") {
                                if let index = project.shots.firstIndex(where: { $0.id == shot.id }), index > 0 {
                                    model.moveShot(shot.id, before: project.shots[index - 1].id)
                                }
                            }
                            Button("移到末尾") { model.moveShot(shot.id, before: nil) }
                            if selectedShotIDs.contains(shot.id), selectedShotIDs.count > 1 {
                                Divider()
                                batchShotActions
                            }
                            Button("从素材库选图替换") { selectedShotIDs = [shot.id]; selectedShotID = shot.id; replacementShotID = shot.id }
                            Button("从故事排除", role: .destructive) { model.remove(shot.id) }
                        }
                        .accessibilityIdentifier("timeStoryTimelineClip")
                    }
                    Label("拖入照片\n添加镜头", systemImage: "plus.rectangle.on.rectangle")
                        .font(.callout).frame(width: 136, height: 120)
                        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(.secondary))
                        .contentShape(Rectangle())
                        .background(dropFrameReader("append"))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(dropHighlight("append"), lineWidth: 2))
                        .accessibilityIdentifier("timeStoryTimelineDropZone")
                }
            }
        }
        .focusable().focused($timelineFocused)
        // Selection is shown on clips; keep keyboard focus without a canvas-wide ring.
        .focusEffectDisabled()
        .onKeyPress(keys: [.init("a")]) { key in
            guard key.modifiers.contains(.command) else { return .ignored }
            selectAllShots(project); return .handled
        }
        .onKeyPress(.escape) { selectedShotIDs = []; selectedShotID = nil; selectedCandidateID = nil; return .handled }
        .onKeyPress(keys: [.delete, .deleteForward, .init("\u{7F}")]) { _ in
            guard !selectedShotIDs.isEmpty else { return .ignored }
            model.editShots(selectedShotIDs, remove: true); return .handled
        }
        .padding(12)
    }

    private func selectAllShots(_ project: TimeStoryProject) {
        selectedShotIDs = Set(project.shots.map(\.id))
        selectedShotID = project.shots.first?.id
        selectedCandidateID = project.shots.first?.assetID
        selectionAnchor = selectedShotID
        inspectorTab = "镜头"; timelineFocused = true
    }

    private func selectShot(_ shot: TimeStoryShot, in project: TimeStoryProject) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor = selectionAnchor,
           let start = project.shots.firstIndex(where: { $0.id == anchor }),
           let end = project.shots.firstIndex(where: { $0.id == shot.id }) {
            let range = Set(project.shots[min(start, end)...max(start, end)].map(\.id))
            selectedShotIDs = flags.contains(.command) ? selectedShotIDs.union(range) : range
        } else if flags.contains(.command) {
            if !selectedShotIDs.insert(shot.id).inserted { selectedShotIDs.remove(shot.id) }
            selectionAnchor = shot.id
        } else { selectedShotIDs = [shot.id]; selectionAnchor = shot.id }
        selectedShotID = selectedShotIDs.contains(shot.id) ? shot.id : project.shots.first(where: { selectedShotIDs.contains($0.id) })?.id
        selectedCandidateID = project.shots.first(where: { $0.id == selectedShotID })?.assetID
        inspectorTab = "镜头"; timelineFocused = true
    }

    @ViewBuilder private var batchShotActions: some View {
        Button("锁定所选镜头") { model.editShots(selectedShotIDs, locked: true) }
        Button("解锁所选镜头") { model.editShots(selectedShotIDs, locked: false) }
        Menu("画面适配") {
            ForEach(TimeStoryPresentationMode.allCases, id: \.self) { mode in
                Button(mode.displayName) { model.editShots(selectedShotIDs, mode: mode) }
            }
        }
        Button("将所选镜头移到开头") {
            model.moveShots(selectedShotIDs, before: model.project?.shots.first(where: { !selectedShotIDs.contains($0.id) })?.id)
        }
        Button("将所选镜头移到末尾") { model.moveShots(selectedShotIDs, before: nil) }
        Button("清空所选字幕") { model.editShots(selectedShotIDs, clearCaptions: true) }
        Divider()
        Button("从故事排除所选镜头", role: .destructive) { model.editShots(selectedShotIDs, remove: true) }
    }

    private var batchShotInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("已选 \(selectedShotIDs.count) 个镜头").font(.headline)
            Text("以下操作应用到所有选中镜头，可一次撤销。").font(.caption).foregroundStyle(.secondary)
            Stepper("统一时长 \(batchDuration, specifier: "%.1f") 秒", value: $batchDuration, in: 1.5...12, step: 0.5)
            Button("应用时长") { model.editShots(selectedShotIDs, duration: batchDuration) }
            Menu("画面适配") {
                ForEach(TimeStoryPresentationMode.allCases, id: \.self) { mode in
                    Button(mode.displayName) { model.editShots(selectedShotIDs, mode: mode) }
                }
            }
            Menu("更多批量操作") { batchShotActions }
        }.accessibilityIdentifier("timeStoryBatchInspector")
    }

    private func dropFrameReader(_ key: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: StoryDropFrameKey.self,
                                   value: [key: proxy.frame(in: .named("storyMontageCanvas"))])
        }
    }

    private func dropHighlight(_ key: String) -> Color {
        dragToken != nil && dropFrames[key]?.contains(dragLocation) == true ? .accentColor : .clear
    }

    // HSplitView hosts its columns separately on macOS. Convert a local drag
    // through the measured source frame rather than relying on a named gesture space.
    private func dragPoint(_ localPoint: CGPoint, token: String) -> CGPoint {
        let key = token.hasPrefix("imageall-story-shot:") ? String(token.dropFirst("imageall-story-shot:".count)) : token
        let origin = dropFrames[key]?.origin ?? .zero
        return CGPoint(x: origin.x + localPoint.x, y: origin.y + localPoint.y)
    }

    private func storyDragGesture(_ token: String) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                guard token != "imageall-story-unavailable" else { return }
                dragToken = token
                dragLocation = dragPoint(value.location, token: token)
            }
            .onEnded { value in
                defer { dragToken = nil }
                let point = dragPoint(value.location, token: token)
                guard token != "imageall-story-unavailable",
                      let target = dropFrames.first(where: {
                          ($0.key == "append" || UUID(uuidString: $0.key) != nil) && $0.value.contains(point)
                      })?.key else { return }
                let accepted = handleDrop([token], onto: UUID(uuidString: target))
#if DEBUG
                if ProcessInfo.processInfo.environment["IMAGEALL_TIME_STORY_UI_VERIFICATION"] == "1" {
                    FileHandle.standardError.write(Data("STORY_UI_DROP_ACCEPTED=\(accepted)\n".utf8))
                }
#endif
            }
    }

    private func handleDrop(_ items: [String], onto shotID: UUID?) -> Bool {
        guard let value = items.first, let project = model.project else { return false }
        if value.hasPrefix("imageall-story-shot:"), let id = UUID(uuidString: String(value.dropFirst("imageall-story-shot:".count))),
           project.shots.contains(where: { $0.id == id }), id != shotID {
            let moving = selectedShotIDs.contains(id) ? selectedShotIDs : [id]
            guard shotID.map({ !moving.contains($0) }) ?? true else { return false }
            model.moveShots(moving, before: shotID)
            return true
        }
        if value.hasPrefix("imageall-story-asset:"), let id = UUID(uuidString: String(value.dropFirst("imageall-story-asset:".count))),
           let candidate = project.candidateSnapshot.candidates.first(where: { $0.assetID == id }) {
            let eligible = shotID.map { model.replacementCandidates(for: $0) } ?? model.addableCandidates
            guard eligible.contains(candidate) else { return false }
            Task {
                if let shotID { await model.replace(shotID, with: candidate); selectedShotID = shotID }
                else { await model.addCandidate(candidate) }
            }
            return true
        }
        return false
    }

    private func creationInspector(_ project: TimeStoryProject) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编排方式").font(.headline)
            HStack {
                Text(project.isFreeform == true ? "自由编排" : "成长与足迹模板")
                Spacer()
                if project.isFreeform != true { Button("转为自由编排") { model.useFreeform() } }
            }
            Menu("选用自动模板") {
                Button("成长与足迹 · 按时间选片") { showRegenerateConfirmation = true }
            }
            Toggle("显示片头", isOn: Binding(get: { model.project?.showsProjectTitle ?? true }, set: { model.setTitleCards(projectTitle: $0) }))
            Toggle("显示章节卡", isOn: Binding(get: { model.project?.showsChapterTitles ?? true }, set: { model.setTitleCards(chapters: $0) }))
            Divider()
            Text("创作意图").font(.headline)
            TextField("希望呈现什么内容与氛围", text: Binding(get: { model.project?.creativeIntent ?? "" }, set: { model.setCreativeIntent($0) }), axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.roundedBorder).accessibilityIdentifier("storyCreativeIntent")
            Stepper(value: Binding(get: { (model.project?.creativeTargetFrames ?? 1800) / 30 }, set: { model.setCreativeTarget($0) }), in: 10...180, step: 5) {
                Text("创作目标 \((project.creativeTargetFrames ?? 1800) / 30) 秒")
            }
            Text("当前编排 \(formattedDuration(project.timelineDurationSeconds))。目标时长用于创作请求，不会自动改动现有镜头。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("制作方式").font(.headline)
            Picker("方式", selection: $productionMode) {
                Text("当前编排").tag("当前编排")
                Text("可编辑创作").tag("可编辑创作")
                Text("自由场景").tag("自由场景")
            }.labelsHidden()
            connectionControls
            if productionMode == "当前编排" {
                Picker("画幅", selection: $productionAspect) {
                    ForEach(TimeStoryPackageAspect.allCases) { aspect in Text(aspect.displayName).tag(aspect) }
                }
                Button("开始本地制作") { model.submitToOpenMontage(aspect: productionAspect) }
                    .buttonStyle(.borderedProminent)
                    .disabled(project.shots.isEmpty || model.openMontageCapability?.state != .ready || model.openMontageTask?.phase.isTerminal == false)
                Text("按当前镜头和时长制作。也可从顶部直接导出横屏 MP4，无需连接外部执行器。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if productionMode == "可编辑创作" {
                if project.shots.count > 100 { Text("此制作方式最多接收 100 张已选照片；当前项目仍可继续编辑和直接导出。").foregroundStyle(.orange) }
                creativePanel(project)
            } else { atelierPanel(project) }
        }
    }

    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(connectionTitle).font(.subheadline.bold())
            if let capability = model.openMontageCapability, capability.state != .ready {
                Text(capability.detail).font(.caption).foregroundStyle(.secondary)
            }
            Button(model.isStartingLocalEngine ? "启动中…" : "启动本地制作") { Task { await model.startLocalEngine() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.isStartingLocalEngine)
                .accessibilityIdentifier("storyStartEngine")
            HStack {
                Button("选择任务目录…") { model.chooseTaskDirectory() }
                    .accessibilityIdentifier("storyConnectDirectory")
                Button(model.isCheckingConnection ? "检查中…" : "检查连接") { Task { await model.refreshOpenMontageCapability() } }
                    .disabled(model.isCheckingConnection)
                    .accessibilityIdentifier("storyCheckConnection")
            }
            if let result = model.connectionCheckResult {
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var connectionTitle: String {
        switch model.openMontageCapability?.state {
        case .ready: "本地制作已连接"
        case .authorizationRequired: "任务目录授权已失效"
        case .unconfigured: "尚未配置本地制作"
        case .offline: "本地执行器未就绪"
        case .incompatible: "执行器版本不兼容"
        case .dependenciesUnavailable: "本地制作依赖未就绪"
        case nil: "正在检查本地制作"
        }
    }

    private func creativePanel(_ project: TimeStoryProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Text("保留当前照片顺序，生成可编辑方案；锁定的字幕和时长保持不变。提交后由创作 Agent 处理。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Menu("发布创作请求") {
                        ForEach(TimeStoryPackageAspect.allCases) { aspect in
                            Button(aspect.displayName) { Task { await model.publishCreativeRequest(aspect: aspect) } }
                        }
                    }.disabled(model.isBusy || project.shots.isEmpty || project.shots.count > 100 || model.openMontageCapability?.state != .ready)
                    .accessibilityIdentifier("storyCreativePublish")
                    if project.creativeReceipt != nil {
                        Button("刷新状态") { model.refreshCreativeRequest() }
                        Button("读取方案") { model.readCreativePlan() }
                        Button("取消创作") { model.cancelCreativeRequest() }
                    }
                    Text(model.creativeStatus).font(.caption).textSelection(.enabled)
                }
                if let plan = model.creativePlan {
                    Text("\(plan.title) · \(plan.shots.count) 张 · 创作来源：\(plan.planningMode) / \(plan.pluginVersion)")
                    Text((plan.observations + plan.uncertainties.map { "待核对：" + $0 }).joined(separator: "\n"))
                        .font(.caption).textSelection(.enabled)
                    Button("应用方案并保存") { Task { await model.applyCreativePlan() } }
                        .accessibilityIdentifier("storyCreativeApply")
                } else if let receipt = project.creativeReceipt, receipt.appliedPlanSHA256 != nil {
                    Text((receipt.observations + receipt.uncertainties.map { "待核对：" + $0 }).joined(separator: "\n"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 6)
        }
    }

    private func atelierPanel(_ project: TimeStoryProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let candidates = project.candidateSnapshot.candidates.filter { candidate in
                candidate.availability == .available && project.shots.contains { $0.assetID == candidate.assetID }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("自由场景制作使用已选 \(project.shots.count) 张照片；支持 1–100 张可用照片，保留已选顺序及锁定时长，竖屏输出。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("发布竖屏 Atelier 创作") {
                        Task { await model.publishAtelierRequest() }
                    }
                    .disabled(model.isBusy || candidates.isEmpty || candidates.count > 100 || model.openMontageCapability?.state != .ready)
                    .accessibilityIdentifier("storyAtelierPublish")
                    if let versions = project.atelierVersions, !versions.isEmpty {
                        ForEach(versions) { version in
                            Button("版本 \(version.requestRevision)") { model.selectAtelierVersion(version.requestID) }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("storyAtelierVersion\(version.requestRevision)")
                        }
                    }
                }
                if let receipt = model.selectedAtelierReceipt {
                    HStack {
                        Text("当前：版本 \(receipt.requestRevision)")
                        Button("刷新状态") { model.refreshAtelierStatus() }
                        Button("读取项目摘要") { Task { await model.readAtelierProposal() } }
                        Button("取消") { model.cancelAtelierRequest() }
                    }
                    if let proposal = model.atelierProposal, proposal.requestID == receipt.requestID {
                        Text("\(proposal.title) · \(Double(proposal.totalFrames) / 30, specifier: "%.1f") 秒 · \(proposal.width)×\(proposal.height)")
                            .font(.headline)
                        Text(proposal.summary).font(.caption).textSelection(.enabled)
                        Text("项目修订：\(proposal.projectRevision)")
                            .font(.caption.monospaced()).textSelection(.enabled)
                        Button("提交此创作版本制作") { Task { await model.requestAtelierRender() } }
                            .accessibilityIdentifier("storyAtelierRender")
                    }
                    Button("核验并打开成片") { Task { await model.openAtelierResult() } }
                        .accessibilityIdentifier("storyAtelierOpenResult")
                    TextField("对镜头、选片、节奏或文字提出具体修改意见", text: $model.atelierFeedback, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("storyAtelierFeedback")
                    Button("按修改意见再创作新版本") {
                        Task { await model.publishAtelierRequest(feedback: model.atelierFeedback) }
                    }
                    .disabled(model.atelierFeedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || receipt.projectRevision == nil || model.isBusy)
                    .accessibilityIdentifier("storyAtelierRevise")
                }
                Text(model.atelierStatus).font(.caption).textSelection(.enabled)
            }.padding(.vertical, 6)
        }
    }

    private func runtimeSummary(_ project: TimeStoryProject) -> TimeStoryReadinessSummary {
        TimeStoryPlanner().readiness(for: project.candidateSnapshot, selectedCount: project.shots.count)
    }

    private func readinessHeader(_ project: TimeStoryProject) -> some View {
        let summary = runtimeSummary(project)
        let target = Double(project.creativeTargetFrames ?? 1800) / 30
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("素材就绪摘要", systemImage: "checklist")
                    .font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("预计成片 \(formattedDuration(project.timelineDurationSeconds))")
                        .font(.headline.monospacedDigit())
                    Text("目标约 \(formattedDuration(target)) · 按 30 fps 时间线计算")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TextField(
                "项目标题",
                text: Binding(
                    get: { model.project?.title ?? project.title },
                    set: { model.setProjectTitle($0) }
                )
            )
            .font(.title2.weight(.semibold))
            .accessibilityIdentifier("timeStoryProjectTitle")
            Text("片头和章节卡可在创作面板开关；镜头字幕显示在对应照片底部。")
                .font(.caption)
                .foregroundStyle(.secondary)
            readinessBody(summary: summary, snapshot: project.candidateSnapshot)
            Text("本故事已排除 \(project.excludedAssetIDs.count) 张；排除会在重新生成后继续生效。")
                .font(.caption).foregroundStyle(.secondary)
            if project.timelineDurationSeconds > target {
                Text("预计成片 \(formattedDuration(project.timelineDurationSeconds))，超过约 \(formattedDuration(target)) 目标。可以缩短镜头、排除照片，或保留较长成片；锁定时长不会自动缩短。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(18)
        .background(.background.secondary)
        .accessibilityIdentifier("timeStoryReadinessSummary")
    }

    private func readinessBody(summary: TimeStoryReadinessSummary, snapshot: TimeStoryCandidateSnapshot) -> some View {
        let details = TimeStoryReadinessDetails(candidates: snapshot.candidates)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                summaryPill("已确认候选", value: "\(summary.matchingCount)")
                summaryPill("待确认建议", value: snapshot.pendingReviewCount.map(String.init) ?? "未知")
                summaryPill("可用", value: "\(details.available)")
                summaryPill("不可用", value: "\(summary.unavailableCount)")
                summaryPill("时间未知", value: "\(summary.unknownTimeCount)")
            }
            Text("分母：当前可查询、标签已接受的静态图片 \(summary.matchingCount) 张；可用与不可用互斥。待审建议单独去重，不包含在分母；已拒绝的不纳入。回收及查询隐藏的缺失 Photos 历史不在范围内。")
            Text("可靠拍摄日期：\(summary.matchingCount - summary.unknownTimeCount) 张，覆盖 \(formattedTimeCoverage(summary))；未知 \(summary.unknownTimeCount) 张不自动进入时间章节（可手动加入）。来自目录中有时区的媒体时间或 PhotoKit creationDate；索引未保留原始时区与年月精度，按日期展示，不用文件修改时间。")
            Text("有确认地点名 \(details.namedAssets) 张 / \(summary.namedPlaceCount) 个不同地点；仅坐标 \(summary.coordinateOnlyCount) 张；已检查无地点 \(summary.noLocationCount) 张；元数据未确认 \(summary.locationMetadataUnconfirmedCount) 张。四类照片计数互斥；地点名只用于连续章节，不推断居住。")
            Text("近重复：可确认分析 \(details.analyzedAssets) / \(summary.matchingCount) 张，\(details.duplicateGroups) 组涉及 \(details.assetsInDuplicateGroups) 张；其余 \(summary.matchingCount - details.analyzedAssets) 张没有兼容的逐项结果，不能断言无重复。时间/地点/可用性/相似状态可重叠。")
            if let tradeoff = summary.selectionTradeoff {
                Text(tradeoff).foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("timeStoryReadinessDetails")
    }

    private func summaryPill(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func shotRow(_ shot: TimeStoryShot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let image = model.thumbnails[shot.id] {
                    StoryPhotoFrame(image: image, mode: shot.presentationMode)
                } else {
                    ZStack {
                        Color.secondary.opacity(0.12)
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 120, height: 72)
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                TextField(
                    "镜头字幕",
                    text: Binding(
                        get: { model.project?.shots.first(where: { $0.id == shot.id })?.caption ?? shot.caption },
                        set: { model.setCaption(shot.id, caption: $0) }
                    )
                )
                .font(.headline)
                .accessibilityIdentifier("timeStoryShotCaption")
                Text(shot.reasons.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let evidence = model.project?.candidateSnapshot.candidates.first(where: { $0.assetID == shot.assetID }) {
                    Text("拍摄日期 \(evidence.mediaCreatedAtMs.map(captureDate) ?? "待确认") · 来源 \(evidence.captureTimeSource ?? "旧项目未记录") · 地点 \(evidence.placeName ?? "未确认名称")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Stepper(
                        value: Binding(
                            get: { model.project?.shots.first(where: { $0.id == shot.id })?.durationSeconds ?? shot.durationSeconds },
                            set: { model.setDuration(shot.id, seconds: $0) }
                        ),
                        in: 1.5 ... 12,
                        step: 0.5
                    ) {
                        Text("\(shot.durationSeconds, specifier: "%.1f") 秒")
                            .monospacedDigit()
                    }
                    .frame(width: 150)
                    Toggle(isOn: Binding(
                        get: { model.project?.shots.first(where: { $0.id == shot.id })?.isLocked ?? shot.isLocked },
                        set: { _ in model.toggleLock(shot.id) }
                    )) {
                        Label("锁定", systemImage: shot.isLocked ? "lock.fill" : "lock.open")
                    }
                    .toggleStyle(.button)
                }
            }
            Picker("画面适配", selection: Binding(
                get: { model.project?.shots.first(where: { $0.id == shot.id })?.presentationMode ?? shot.presentationMode },
                set: { model.editShots([shot.id], mode: $0) }
            )) {
                ForEach(TimeStoryPresentationMode.allCases, id: \.self) { mode in Text(mode.displayName).tag(mode) }
            }.accessibilityIdentifier("timeStoryPresentationMode")
            Text("裁剪以画面中心为准；完整显示保留照片全部内容。").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("从素材库选图替换") {
                replacementShotID = shot.id
                candidateSearch = ""
            }
            Button(role: .destructive) { model.remove(shot.id) } label: {
                Label("从本故事排除", systemImage: "trash")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("timeStoryShotRow")
    }

    @ViewBuilder
    private var statusBar: some View {
        VStack(spacing: 6) {
            if model.isReadingCandidates {
                HStack {
                    ProgressView()
                    Text("已遍历 \(model.loadedCandidateCount) 张主体候选…")
                        .font(.caption.monospacedDigit())
                    Button("取消读取") { model.cancelCandidateLoading() }
                }
            }
            if let progress = model.exportProgress {
                HStack {
                    ProgressView(value: progress.fraction)
                    Text(progress.phase.rawValue)
                        .font(.caption.monospacedDigit())
                    Button("取消导出") { model.cancelExport() }
                }
            }
            if let progress = model.packageExportProgress {
                HStack {
                    ProgressView(value: progress.fraction)
                    Text(packagePhaseName(progress.phase))
                        .font(.caption.monospacedDigit())
                    Button("取消故事包导出") { model.cancelPackageExport() }
                }
            }
            if let task = model.openMontageTask {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if !task.phase.isTerminal {
                            ProgressView(value: task.progress)
                                .frame(maxWidth: 220)
                        }
                        Label(openMontagePhaseName(task.phase), systemImage: openMontagePhaseIcon(task.phase))
                            .font(.caption.weight(.semibold))
                        Text(task.aspect.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !task.phase.isTerminal {
                            Button("取消制作") { model.cancelOpenMontageTask() }
                        }
                        if task.phase == .succeeded {
                            Button("打开成片") { model.openOpenMontageResult() }
                            Button("在 Finder 中显示") { model.revealOpenMontageResult() }
                            Button("另存…") { chooseOpenMontageResultDestination() }
                        }
                    }
                    Text("任务 \(task.taskID.prefix(8))… · 本次内容已冻结；之后的项目编辑不会改变该任务。")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let detail = task.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(task.phase == .failed ? .red : .secondary)
                    }
                }
                .accessibilityIdentifier("timeStoryOpenMontageStatus")
            }
            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(.bar)
    }

    private var musicMenu: some View {
        Menu {
            Button("选择本地配乐…") { chooseMusic() }
            if model.project?.music != nil {
                Button("移除配乐") { model.setMusic(url: nil) }
            }
        } label: {
            Label(model.project?.music?.displayName ?? "无配乐", systemImage: "music.note")
        }
        .disabled(model.project == nil)
    }

    private func chooseMusic() {
        let panel = NSOpenPanel()
        panel.title = "选择时光故事配乐"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { model.setMusic(url: panel.url) }
    }

    private func chooseExportDestination() {
        guard let project = model.project else { return }
        let panel = NSSavePanel()
        panel.title = "导出时光故事 MP4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(project.subjectTagDisplayName)-成长与足迹.mp4"
        if panel.runModal() == .OK, let url = panel.url { model.export(to: url) }
    }

    private func choosePackageDestination(aspect: TimeStoryPackageAspect) {
        guard let project = model.project else { return }
        let panel = NSOpenPanel()
        panel.title = "选择故事包保存位置（\(aspect.displayName)）"
        panel.message = "将在所选文件夹内生成供外部制作工具使用的故事包。"
        panel.prompt = "选择文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let directory = panel.url {
            let safeSubject = project.subjectTagDisplayName
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let name = "\(safeSubject)-时光故事-\(aspect.rawValue).storyrenderpackage"
            model.exportPackage(
                to: directory.appendingPathComponent(name, isDirectory: true),
                aspect: aspect
            )
        }
    }

    private func packagePhaseName(_ phase: TimeStoryPackageProgress.Phase) -> String {
        switch phase {
        case .preparingAssets: "准备素材"
        case .writingPlan: "写入制作方案"
        case .verifying: "完整校验"
        case .publishing: "发布故事包"
        }
    }

    private func chooseOpenMontageResultDestination() {
        guard let project = model.project else { return }
        let panel = NSOpenPanel()
        panel.title = "另存 OpenMontage 成片"
        panel.message = "选择保存文件夹；ImageAll 会在这个文件夹内校验并发布成片。"
        panel.prompt = "保存到此文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 48))
        let label = NSTextField(labelWithString: "成片文件名")
        label.frame = NSRect(x: 0, y: 28, width: 360, height: 18)
        let fileName = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 360, height: 24)
        )
        fileName.stringValue = "\(project.subjectTagDisplayName)-OpenMontage.mp4"
        fileName.setAccessibilityIdentifier("openMontageResultFileName")
        accessory.addSubview(label)
        accessory.addSubview(fileName)
        panel.accessoryView = accessory
        if panel.runModal() == .OK, let directory = panel.url {
            let name = fileName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != ".", name != "..",
                  !name.contains("/"), !name.contains(":"),
                  name.lowercased().hasSuffix(".mp4")
            else {
                model.message = "请输入不含路径符号、以 .mp4 结尾的文件名。"
                return
            }
            model.saveOpenMontageResult(
                to: directory.appendingPathComponent(name),
                in: directory
            )
        }
    }

    private func openMontagePhaseName(_ phase: OpenMontageStoryTaskPhase) -> String {
        switch phase {
        case .preparingAssets: "正在准备素材"
        case .waitingForExecutor: "等待 OpenMontage"
        case .rendering: "正在制作成片"
        case .verifyingResult: "正在检查成片"
        case .succeeded: "制作完成"
        case .failed: "制作失败"
        case .cancelled: "已取消"
        case .interrupted: "制作已中断"
        }
    }

    private func openMontagePhaseIcon(_ phase: OpenMontageStoryTaskPhase) -> String {
        switch phase {
        case .preparingAssets: "square.and.arrow.up"
        case .waitingForExecutor: "hourglass"
        case .rendering: "film.stack"
        case .verifyingResult: "checkmark.shield"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .interrupted: "bolt.slash"
        }
    }

    private func formattedDuration(_ seconds: Double) -> String {
        TimeStoryDurationText.format(seconds)
    }

    private func formattedTimeCoverage(_ summary: TimeStoryReadinessSummary) -> String {
        guard let start = summary.reliableTimeStartMs,
              let end = summary.reliableTimeEndMs
        else { return "未确认" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(formatter.string(from: Date(timeIntervalSince1970: Double(start) / 1_000)))"
            + " 至 \(formatter.string(from: Date(timeIntervalSince1970: Double(end) / 1_000)))"
    }

    private func captureDate(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }
}

private struct TimeStoryTimelinePreview: View {
    let project: TimeStoryProject
    let thumbnails: [UUID: NSImage]
    @State private var isPlaying = false
    @State private var playbackStartedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { context in
            let timeline = try? TimeStoryTimeline.normalize(project: project)
            let duration = timeline?.durationSeconds ?? 0
            let elapsed = max(0, context.date.timeIntervalSince(playbackStartedAt))
            let seconds = isPlaying && duration > 0 ? elapsed.truncatingRemainder(dividingBy: duration) : 0
            let frame = Int((seconds * Double(timeline?.fps ?? 30)).rounded(.down))
            let state = timeline?.state(atFrame: frame)
            VStack(spacing: 12) {
                ZStack(alignment: .bottom) {
                    Color.black
                    if let state {
                        previewContent(
                            state.current,
                            opacity: 1 - state.blend,
                            scale: 0.985 + 0.015 * state.progress
                        )
                        if let next = state.next {
                            previewContent(next, opacity: state.blend, scale: 0.985)
                        }
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("timeStoryTimelinePreview")

                HStack(spacing: 12) {
                    Button {
                        playbackStartedAt = Date()
                        isPlaying.toggle()
                    } label: {
                        Label(isPlaying ? "暂停" : "播放", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    }
                    Text("\(formatted(seconds)) / \(formatted(duration))")
                        .font(.caption.monospacedDigit())
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func previewContent(
        _ segment: TimeStoryFrameSegment,
        opacity: Double,
        scale: Double
    ) -> some View {
        Group {
            switch segment.kind {
            case .projectTitle, .chapterTitle:
                ZStack {
                    Color(red: 0.055, green: 0.082, blue: 0.12)
                    VStack(spacing: 10) {
                        Text(segment.title ?? "")
                            .font(segment.kind == .projectTitle ? .title.bold() : .title2.bold())
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                        Rectangle()
                            .fill(Color(red: 0.95, green: 0.78, blue: 0.47))
                            .frame(width: 72, height: 3)
                    }
                    .padding(24)
                }
            case .photo:
                ZStack(alignment: .bottom) {
                    if let shotID = segment.shotID, let image = thumbnails[shotID] {
                        StoryPhotoFrame(image: image, mode: segment.presentationMode, progress: (scale - 0.985) / 0.015)
                    }
                    if let caption = segment.caption,
                       !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        Text(caption)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .shadow(color: .black, radius: 3)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            .padding(12)
                    }
                }
            }
        }
        .opacity(opacity)
    }

    private func formatted(_ seconds: Double) -> String {
        TimeStoryDurationText.format(seconds)
    }
}

/// Shared fitting geometry with the native renderer. The canvas clips only in fill mode.
private struct StoryPhotoFrame: View {
    let image: NSImage
    let mode: TimeStoryPresentationMode
    var progress: Double = 1
    var body: some View {
        GeometryReader { proxy in
            let rect = mode.imageRect(image: image.size, canvas: proxy.size, progress: progress)
            ZStack {
                Color.black
                if mode == .fullFrameWithBackground {
                    let background = TimeStoryPresentationMode.aspectFill.imageRect(image: image.size, canvas: proxy.size)
                    Image(nsImage: image).resizable().frame(width: background.width, height: background.height)
                        .opacity(0.32).overlay(Color.black.opacity(0.1472))
                }
                Image(nsImage: image).resizable().frame(width: rect.width, height: rect.height)
            }.frame(width: proxy.size.width, height: proxy.size.height).clipped()
        }
    }
}
