import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

@MainActor
final class TimeStoryWorkspaceModel: ObservableObject {
    @Published private(set) var project: TimeStoryProject?
    @Published private(set) var projects: [TimeStoryProjectSummary] = []
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    @Published private(set) var isBusy = false
    @Published private(set) var exportProgress: TimeStoryRenderProgress?
    @Published private(set) var lastExportURL: URL?
    @Published var message: String?

    private let runtime: TimeStoryFeatureRuntime
    private let initialTag: TagListItem
    private var exportTask: Task<Void, Never>?

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

    deinit { exportTask?.cancel() }

    func start() async {
        guard project == nil, !isBusy else { return }
        await refreshProjects()
        await createDraft(for: initialTag)
    }

    func createDraft(for tag: TagListItem) async {
        isBusy = true
        message = "正在冻结候选清单并生成草稿…"
        let runtime = runtime
        do {
            let now = runtime.clock.nowMs
            let project = try await Task.detached(priority: .userInitiated) {
                let snapshot = try runtime.candidates.snapshot(tag: tag, nowMs: now)
                return try runtime.planner.makeProject(snapshot: snapshot, nowMs: now)
            }.value
            self.project = project
            message = "草稿已生成；保存后可随时重新打开。"
            await loadThumbnails()
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
        message = "正在按同一候选快照重新生成…"
        let runtime = runtime
        do {
            let regenerated = try await Task.detached(priority: .userInitiated) {
                try runtime.planner.makeProject(
                    snapshot: current.candidateSnapshot,
                    nowMs: runtime.clock.nowMs,
                    existing: current
                )
            }.value
            project = regenerated
            message = "已重新生成，并保留锁定、排除和明确编辑。"
            await loadThumbnails()
        } catch {
            message = error.localizedDescription
        }
        isBusy = false
    }

    func setChapterTitle(_ chapterID: UUID, title: String) {
        guard var project,
              let index = project.chapters.firstIndex(where: { $0.id == chapterID })
        else { return }
        project.chapters[index].title = title
        project.chapters[index].isUserEdited = true
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
              let index = project.shots.firstIndex(where: { $0.id == shotID })
        else { return }
        let previousAssetID = project.shots[index].assetID
        project.excludedAssetIDs.insert(previousAssetID)
        project.shots[index].assetID = candidate.assetID
        project.shots[index].contentRevision = candidate.contentRevision
        project.shots[index].caption = candidate.placeName ?? project.subjectTagDisplayName
        project.shots[index].reasons = ["用户替换"]
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
        let used = Set(project.shots.filter { $0.id != shotID }.map(\.assetID))
        return project.candidateSnapshot.candidates.filter {
            $0.mediaCreatedAtMs != nil
                && $0.availability == .available
                && !used.contains($0.assetID)
                && !project.excludedAssetIDs.contains($0.assetID)
        }
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
            defer {
                progressContinuation.finish()
                progressTask.cancel()
            }
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
            self?.exportProgress = nil
            self?.exportTask = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
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
                    .disabled(model.project?.shots.isEmpty != false || model.exportProgress != nil)
                    .accessibilityIdentifier("timeStoryExportButton")
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
                            Text("\(formattedDuration(project.durationSeconds)) · \(project.subjectTagDisplayName)")
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
                readinessHeader(project)
                TimeStoryTimelinePreview(project: project, thumbnails: model.thumbnails)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
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
        } else if model.isBusy {
            ProgressView("正在生成故事草稿…")
                .controlSize(.large)
        } else {
            ContentUnavailableView(
                "无法生成故事",
                systemImage: "film",
                description: Text(model.message ?? "没有可用候选素材。")
            )
        }
    }

    private func readinessHeader(_ project: TimeStoryProject) -> some View {
        let summary = project.readiness
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("素材就绪摘要", systemImage: "checklist")
                    .font(.headline)
                Spacer()
                Text("实际时长 \(formattedDuration(project.timelineDurationSeconds))")
                    .font(.headline.monospacedDigit())
            }
            HStack(spacing: 16) {
                summaryPill("匹配", value: "\(summary.matchingCount)")
                summaryPill("可靠时间", value: "\(summary.matchingCount - summary.unknownTimeCount)")
                summaryPill("时间未知", value: "\(summary.unknownTimeCount)")
                summaryPill("地点", value: "\(summary.namedPlaceCount)")
                summaryPill("地点未确认", value: "\(summary.locationMetadataUnconfirmedCount)")
                summaryPill("不可用", value: "\(summary.unavailableCount)")
            }
            Text(
                "可靠拍摄时间覆盖：\(formattedTimeCoverage(summary))；"
                    + "无地点 \(summary.noLocationCount) 张；"
                    + "仅有坐标 \(summary.coordinateOnlyCount) 张。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(
                summary.similarityFilteringState == .ready
                    ? "已复用兼容的近重复结果；跨时期相似画面仍保留。"
                    : "相似筛选未完成；已按时间、地点、收藏和分辨率退化生成。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let tradeoff = summary.selectionTradeoff {
                Text(tradeoff).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(18)
        .background(.background.secondary)
        .accessibilityIdentifier("timeStoryReadinessSummary")
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
                Text(shot.caption).font(.headline).lineLimit(1)
                Text(shot.reasons.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text("没有其他可用候选")
                }
                ForEach(replacements.prefix(40)) { candidate in
                    Button(candidate.fileName ?? candidate.assetID.uuidString) {
                        Task { await model.replace(shot.id, with: candidate) }
                    }
                }
            }
            Button(role: .destructive) { model.remove(shot.id) } label: {
                Label("移除", systemImage: "trash")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("timeStoryShotRow")
    }

    @ViewBuilder
    private var statusBar: some View {
        VStack(spacing: 6) {
            if let progress = model.exportProgress {
                HStack {
                    ProgressView(value: progress.fraction)
                    Text(progress.phase.rawValue)
                        .font(.caption.monospacedDigit())
                    Button("取消导出") { model.cancelExport() }
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

    private func formattedDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
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
}

private struct TimeStoryTimelinePreview: View {
    let project: TimeStoryProject
    let thumbnails: [UUID: NSImage]
    @State private var isPlaying = false
    @State private var playbackStartedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { context in
            let duration = project.timelineDurationSeconds
            let elapsed = max(0, context.date.timeIntervalSince(playbackStartedAt))
            let seconds = isPlaying && duration > 0 ? elapsed.truncatingRemainder(dividingBy: duration) : 0
            let state = TimeStoryTimeline.state(
                at: seconds,
                shots: project.shots,
                transitionSeconds: TimeStoryConstants.transitionDurationSeconds
            )
            HStack(spacing: 14) {
                ZStack(alignment: .bottom) {
                    Color.black
                    if let state {
                        previewImage(state.current, opacity: 1 - state.blend, scale: 1 + 0.015 * state.progress)
                        if let next = state.next {
                            previewImage(next, opacity: state.blend, scale: 1)
                        }
                        Text(state.current.caption)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .shadow(color: .black, radius: 3)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            .padding(12)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("timeStoryTimelinePreview")

                VStack(alignment: .leading, spacing: 8) {
                    Text("时间线预览")
                        .font(.headline)
                    Text("与导出共用镜头时长和转场重叠")
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
    private func previewImage(_ shot: TimeStoryShot, opacity: Double, scale: Double) -> some View {
        if let image = thumbnails[shot.id] {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .opacity(opacity)
        }
    }

    private func formatted(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
