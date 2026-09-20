import AppKit
import SwiftUI

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
            .persistentHelp("以这个明确标签的已确认照片创建“成长与足迹”故事草稿。")
            .accessibilityIdentifier("timeStoryCreateFromTag")
    }
}

struct TimeStorySheetModifier: ViewModifier {
    @ObservedObject var model: LibraryWorkspaceModel
    @Binding var tag: TagListItem?

    func body(content: Content) -> some View {
        content.sheet(item: $tag) { selectedTag in
            if let storyModel = model.makeTimeStoryWorkspaceModel(for: selectedTag) {
                TimeStoryWorkspaceView(model: storyModel)
            } else {
                ContentUnavailableView(
                    "时光故事暂不可用",
                    systemImage: "film",
                    description: Text("故事运行组件没有完成初始化。")
                )
                .frame(minWidth: 520, minHeight: 320)
            }
        }
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
    @Published private(set) var project: TimeStoryProject?
    @Published private(set) var readinessSnapshot: TimeStoryCandidateSnapshot?
    @Published private(set) var loadedCandidateCount = 0
    @Published private(set) var isReadingCandidates = false
    @Published private(set) var projects: [TimeStoryProjectSummary] = []
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
    @Published var message: String?

    private var creativePlugin: StoryCreativePlugin {
        StoryCreativePlugin(rootProvider: runtime.creativeRootProvider,
                            exporter: runtime.packageExporter, validator: runtime.validator)
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
            let project = try runtime.planner.makeProject(snapshot: snapshot, nowMs: now)
            readinessSnapshot = snapshot
            self.project = project
            message = "草稿已生成；保存后可随时重新打开。"
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
            message = "故事项目已重新打开。"
            creativePlan = nil
            refreshCreativeRequest()
            await loadThumbnails()
        } catch {
            message = error.localizedDescription
        }
        isBusy = false
    }

    func save() async {
        guard var project else { return }
        isBusy = true
        project.updatedAtMs = runtime.clock.nowMs
        let store = runtime.store
        let projectToSave = project
        do {
            try await Task.detached { try store.save(projectToSave) }.value
            self.project = project
            await refreshProjects()
            message = "故事项目已保存。"
        } catch {
            message = error.localizedDescription
        }
        isBusy = false
    }

    func regenerate() async {
        guard let current = project else { return }
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
              runtime.planner.replacementCandidates(for: shotID, in: project).contains(where: { $0.assetID == candidate.assetID })
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
        return runtime.planner.replacementCandidates(for: shotID, in: project)
    }

    var addableCandidates: [TimeStoryCandidate] {
        guard let project else { return [] }
        return runtime.planner.addableCandidates(in: project)
    }

    func addCandidate(_ candidate: TimeStoryCandidate) async {
        guard let current = project else { return }
        do {
            let updated = try runtime.planner.appending(candidate, to: current, nowMs: runtime.clock.nowMs)
            project = updated
            if let shot = updated.shots.first(where: { $0.assetID == candidate.assetID }) {
                await loadThumbnail(for: shot)
            }
            message = "已从本次限定候选补入照片；请核对顺序、字幕并保存。"
        } catch { message = error.localizedDescription }
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

    func refreshOpenMontageCapability() async {
        openMontageCapability = await runtime.openMontageTasks.capability()
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
        guard let project else { return }
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
        thumbnails = [:]
        for shot in project?.shots ?? [] {
            guard !Task.isCancelled else { return }
            await loadThumbnail(for: shot)
        }
    }

    private func loadThumbnail(for shot: TimeStoryShot) async {
        do {
            let data = try await runtime.media.loadStoryImage(assetID: shot.assetID)
            if let image = NSImage(data: data) { thumbnails[shot.id] = image }
        } catch {
            // The export preflight reports exact missing/version failures. A failed
            // editor thumbnail stays visibly empty without changing the project.
        }
    }
}

struct TimeStoryWorkspaceView: View {
    @StateObject private var model: TimeStoryWorkspaceModel
    @Environment(\.dismiss) private var dismiss

    init(model: TimeStoryWorkspaceModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        NavigationSplitView {
            projectSidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            editor
        }
        .frame(minWidth: 980, minHeight: 680)
        .task { await model.start() }
        .toolbar {
            ToolbarItemGroup {
                Button("保存") { Task { await model.save() } }
                    .disabled(model.project == nil || model.isBusy)
                    .accessibilityIdentifier("timeStorySaveButton")
                Button("重新生成") { Task { await model.regenerate() } }
                    .disabled(model.project == nil || model.isBusy)
                    .accessibilityIdentifier("timeStoryRegenerateButton")
                musicMenu
                Button("导出 MP4…") { chooseExportDestination() }
                    .disabled(
                        model.project?.shots.isEmpty != false
                            || model.exportProgress != nil
                            || model.packageExportProgress != nil
                    )
                    .accessibilityIdentifier("timeStoryExportButton")
                Menu("OpenMontage 本地制作") {
                    ForEach(TimeStoryPackageAspect.allCases) { aspect in
                        Button(aspect.displayName) { model.submitToOpenMontage(aspect: aspect) }
                    }
                }
                .disabled(
                    model.project?.shots.isEmpty != false
                        || model.exportProgress != nil
                        || model.packageExportProgress != nil
                        || model.openMontageTask?.phase.isTerminal == false
                )
                .persistentHelp("将本次故事冻结后发布给用户已启动的 OpenMontage 本地执行器。")
                .accessibilityIdentifier("timeStoryOpenMontageButton")
                Menu("导出独立故事包") {
                    ForEach(TimeStoryPackageAspect.allCases) { aspect in
                        Button(aspect.displayName + "…") { choosePackageDestination(aspect: aspect) }
                    }
                }
                .disabled(
                    model.project?.shots.isEmpty != false
                        || model.exportProgress != nil
                        || model.packageExportProgress != nil
                )
                .persistentHelp("导出供外部制作工具使用的素材与制作方案。")
                .accessibilityIdentifier("timeStoryPackageExportButton")
                Button("关闭") { dismiss() }
            }
        }
    }

    private var projectSidebar: some View {
        List {
            Section("当前模板") {
                Label("成长与足迹", systemImage: "film.stack")
                    .accessibilityIdentifier("timeStoryTemplateGrowthFootprints")
            }
            Section("已保存故事") {
                if model.projects.isEmpty {
                    Text("尚无已保存故事")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.projects) { project in
                    Button {
                        Task { await model.open(project.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.title).lineLimit(2)
                            Text("预计 \(formattedDuration(project.durationSeconds)) · \(project.subjectTagDisplayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let project = model.project {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        creativePanel(project)
                        readinessHeader(project)
                        TimeStoryTimelinePreview(project: project, thumbnails: model.thumbnails)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 12)
                        Divider()
                        ForEach(project.chapters) { chapter in
                            chapterView(chapter, project: project)
                        }
                        if project.readiness.unknownTimeCount > 0 {
                            Label(
                                "\(project.readiness.unknownTimeCount) 张时间未知照片留在待确认区，未插入成长顺序。",
                                systemImage: "questionmark.circle"
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 18)
                        }
                    }
                    .padding(.vertical, 18)
                }
                statusBar
            }
            .navigationTitle(project.title)
        } else if let snapshot = model.readinessSnapshot, let summary = model.readinessPreview {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("\(snapshot.tagDisplayName) · 素材就绪报告", systemImage: "checklist")
                        .font(.title2.bold())
                    readinessBody(summary: summary, snapshot: snapshot)
                    Button("生成故事草稿") { Task { await model.createDraft(for: TagListItem(
                        id: snapshot.tagID, displayName: snapshot.tagDisplayName, state: .active
                    )) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || !snapshot.candidates.contains {
                        $0.availability == .available && $0.mediaCreatedAtMs != nil
                    })
                    .accessibilityIdentifier("timeStoryGenerateDraftButton")
                    if !snapshot.candidates.contains(where: { $0.availability == .available && $0.mediaCreatedAtMs != nil }) {
                        Text("至少需要一张有可靠拍摄时间且可用的已确认照片，才能生成草稿。")
                            .foregroundStyle(.orange)
                    }
                    if model.isBusy {
                        ProgressView("已读取 \(model.loadedCandidateCount) 张，正在更新候选…")
                        Button("取消读取") { model.cancelCandidateLoading() }
                    }
                }.padding(24)
            }
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

    private func creativePanel(_ project: TimeStoryProject) -> some View {
        DisclosureGroup("OpenMontage 创作方案 · Agent 协作") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("描述你想讲的故事", text: Binding(
                    get: { model.project?.creativeIntent ?? "" }, set: { model.setCreativeIntent($0) }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("storyCreativeIntent")
                HStack {
                    Text("主体：\(project.subjectTagDisplayName) · 本次候选仅含当前故事的 \(Set(project.shots.map(\.assetID)).count) 张照片")
                    Stepper(value: Binding(get: { (model.project?.creativeTargetFrames ?? 1800) / 30 },
                                           set: { model.setCreativeTarget($0) }), in: 10...180, step: 5) {
                        Text("目标 \((model.project?.creativeTargetFrames ?? 1800) / 30) 秒")
                    }.frame(width: 160)
                }.font(.caption)
                Text("保留锁定与明确编辑。只允许本地使用；本请求不授权云上传。自由 Atelier 场景尚未接入此编辑器。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Menu("发布创作请求") {
                        ForEach(TimeStoryPackageAspect.allCases) { aspect in
                            Button(aspect.displayName) { Task { await model.publishCreativeRequest(aspect: aspect) } }
                        }
                    }.disabled(model.isBusy || project.shots.isEmpty)
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
        }.padding(.horizontal, 18).padding(.top, 8)
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
            Text("成片中项目标题显示为片头卡；章节标题显示为各章节卡；镜头字幕只显示在对应照片底部。")
                .font(.caption)
                .foregroundStyle(.secondary)
            readinessBody(summary: summary, snapshot: project.candidateSnapshot)
            if !model.addableCandidates.isEmpty {
                Menu("从本次候选补入镜头…") {
                    ForEach(Array(model.addableCandidates.prefix(40).enumerated()), id: \.element.assetID) { item in
                        let candidate = item.element
                        Button("拍摄顺序 \(item.offset + 1) · \(Date(timeIntervalSince1970: Double(candidate.mediaCreatedAtMs ?? 0) / 1000).formatted(date: .omitted, time: .standard)) · \(candidate.width ?? 0)×\(candidate.height ?? 0)") {
                            Task { await model.addCandidate(candidate) }
                        }
                    }
                }
                .accessibilityIdentifier("timeStoryAddCandidate")
                .persistentHelp("仅补入同一已确认地点的可用、可靠时间照片，最多 18 张；按拍摄时间插入。")
            }
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
            Text("可靠拍摄日期：\(summary.matchingCount - summary.unknownTimeCount) 张，覆盖 \(formattedTimeCoverage(summary))；未知 \(summary.unknownTimeCount) 张不进入时间章节。来自目录中有时区的媒体时间或 PhotoKit creationDate；索引未保留原始时区与年月精度，按日期展示，不用文件修改时间。")
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

    private func chapterView(_ chapter: TimeStoryChapter, project: TimeStoryProject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                "章节标题",
                text: Binding(
                    get: {
                        model.project?.chapters.first(where: { $0.id == chapter.id })?.title
                            ?? chapter.title
                    },
                    set: { model.setChapterTitle(chapter.id, title: $0) }
                )
            )
            .font(.title3.weight(.semibold))
            .textFieldStyle(.plain)
            .accessibilityIdentifier("timeStoryChapterTitle")
            ForEach(project.shots.filter { chapter.shotIDs.contains($0.id) }) { shot in
                shotRow(shot)
            }
        }
        .padding(.horizontal, 18)
    }

    private func shotRow(_ shot: TimeStoryShot) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let image = model.thumbnails[shot.id] {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ZStack {
                        Color.secondary.opacity(0.12)
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 150, height: 92)
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
            Spacer()
            Menu("替换") {
                let replacements = model.replacementCandidates(for: shot.id)
                if replacements.isEmpty {
                    Text("同一主体、时期及地点无可用替代照片")
                }
                ForEach(replacements.prefix(40)) { candidate in
                    Button(candidate.fileName ?? candidate.assetID.uuidString) {
                        Task { await model.replace(shot.id, with: candidate) }
                    }
                }
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
            } else if let capability = model.openMontageCapability,
                      capability.state != .ready
            {
                HStack {
                    Label("OpenMontage 未连接", systemImage: "bolt.slash")
                        .font(.caption.weight(.semibold))
                    Text(capability.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("刷新") { Task { await model.refreshOpenMontageCapability() } }
                }
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
            HStack(spacing: 14) {
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("时间线预览")
                        .font(.headline)
                    Text("预览、MP4 与故事包共用整数帧边界")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        playbackStartedAt = Date()
                        isPlaying.toggle()
                    } label: {
                        Label(isPlaying ? "暂停" : "播放", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    }
                    Text("\(formatted(seconds)) / \(formatted(duration))")
                        .font(.caption.monospacedDigit())
                }
                .frame(width: 180, alignment: .leading)
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
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
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
