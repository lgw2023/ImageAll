import AVFoundation
import CryptoKit
import Foundation

enum OpenMontageStoryTaskPhase: String, Codable, Sendable, Equatable {
    case preparingAssets
    case waitingForExecutor
    case rendering
    case verifyingResult
    case succeeded
    case failed
    case cancelled
    case interrupted

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .interrupted: true
        case .preparingAssets, .waitingForExecutor, .rendering, .verifyingResult: false
        }
    }
}

struct OpenMontageVerifiedResult: Sendable, Equatable {
    let taskID: String
    let projectID: String
    let projectRevision: String
    let aspect: TimeStoryPackageAspect
    let totalFrames: Int
    let framesPerSecond: Int
    let width: Int
    let height: Int
    let fileURL: URL
    let fileSHA256: String
    let authorizedRootURL: URL
}

struct OpenMontageStoryTaskSnapshot: Sendable, Equatable, Identifiable {
    let taskID: String
    let projectID: String
    let projectRevision: String?
    let aspect: TimeStoryPackageAspect
    let totalFrames: Int?
    let phase: OpenMontageStoryTaskPhase
    let progress: Double
    let updatedAtMs: Int64
    let detail: String?
    let result: OpenMontageVerifiedResult?

    var id: String { taskID }
}

enum OpenMontageExecutorConnectionState: String, Sendable, Equatable {
    case unconfigured
    case authorizationRequired
    case offline
    case incompatible
    case dependenciesUnavailable
    case ready
}

struct OpenMontageExecutorCapability: Sendable, Equatable {
    let state: OpenMontageExecutorConnectionState
    let protocolVersion: String?
    let executorVersion: String?
    let schemaSHA256: String?
    let heartbeatAtMs: Int64?
    let detail: String
}

protocol OpenMontageStoryTasking: Sendable {
    func capability() async -> OpenMontageExecutorCapability

    func submit(
        project: TimeStoryProject,
        aspect: TimeStoryPackageAspect,
        onProgress: @escaping @Sendable (OpenMontageStoryTaskSnapshot) -> Void
    ) async throws -> OpenMontageStoryTaskSnapshot

    func task(taskID: String) async throws -> OpenMontageStoryTaskSnapshot
    func latestTask(projectID: UUID) async throws -> OpenMontageStoryTaskSnapshot?
    func requestCancellation(taskID: String) async throws -> OpenMontageStoryTaskSnapshot
    func verifiedResult(taskID: String) async throws -> OpenMontageVerifiedResult
    func retryFrozenTask(taskID: String) async throws -> OpenMontageStoryTaskSnapshot
    func diagnosticReport(taskID: String?) async throws -> Data
}

extension OpenMontageStoryTasking {
    func retryFrozenTask(taskID: String) async throws -> OpenMontageStoryTaskSnapshot {
        throw OpenMontageTaskError.executorIncompatible("此制作组件不支持冻结任务重试。")
    }
    func diagnosticReport(taskID: String?) async throws -> Data {
        throw OpenMontageTaskError.executorIncompatible("此制作组件不支持诊断导出。")
    }
}

enum OpenMontageTaskError: LocalizedError, Equatable, Sendable {
    case taskRootNotConfigured
    case taskRootAuthorizationRequired
    case taskRootOffline
    case taskRootUnsafe
    case executorOffline(String)
    case executorIncompatible(String)
    case dependenciesUnavailable(String)
    case taskAlreadyActive
    case protocolViolation(String)
    case resultValidationFailed(String)

    var errorDescription: String? {
        switch self {
        case .taskRootNotConfigured:
            "请选择用于本地制作的任务目录。"
        case .taskRootAuthorizationRequired:
            "OpenMontage 任务目录需要重新授权。"
        case .taskRootOffline:
            "OpenMontage 任务目录当前不可用，请确认磁盘已连接。"
        case .taskRootUnsafe:
            "OpenMontage 返回了任务目录之外的路径，已拒绝访问。"
        case let .executorOffline(detail):
            "OpenMontage 执行器未连接。\(detail)"
        case let .executorIncompatible(detail):
            "OpenMontage 执行器版本不兼容。\(detail)"
        case let .dependenciesUnavailable(detail):
            "OpenMontage 本地依赖尚未就绪。\(detail)"
        case .taskAlreadyActive:
            "已有制作任务正在进行，请等待完成或先取消。"
        case let .protocolViolation(detail):
            "OpenMontage 任务记录无效：\(detail)"
        case let .resultValidationFailed(detail):
            "成片验证未通过：\(detail)"
        }
    }
}

struct UnavailableOpenMontageStoryTaskClient: OpenMontageStoryTasking {
    func capability() async -> OpenMontageExecutorCapability {
        OpenMontageExecutorCapability(
            state: .unconfigured,
            protocolVersion: nil,
            executorVersion: nil,
            schemaSHA256: nil,
            heartbeatAtMs: nil,
            detail: "尚未选择任务目录。"
        )
    }

    func submit(
        project _: TimeStoryProject,
        aspect _: TimeStoryPackageAspect,
        onProgress _: @escaping @Sendable (OpenMontageStoryTaskSnapshot) -> Void
    ) async throws -> OpenMontageStoryTaskSnapshot {
        throw OpenMontageTaskError.taskRootNotConfigured
    }

    func task(taskID _: String) async throws -> OpenMontageStoryTaskSnapshot {
        throw OpenMontageTaskError.taskRootNotConfigured
    }

    func latestTask(projectID _: UUID) async throws -> OpenMontageStoryTaskSnapshot? { nil }

    func requestCancellation(taskID _: String) async throws -> OpenMontageStoryTaskSnapshot {
        throw OpenMontageTaskError.taskRootNotConfigured
    }

    func verifiedResult(taskID _: String) async throws -> OpenMontageVerifiedResult {
        throw OpenMontageTaskError.taskRootNotConfigured
    }
}

enum OpenMontageTaskFileValidation {
    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

protocol OpenMontageTaskRootProviding: Sendable {
    func resolveTaskRoot() throws -> URL
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

struct UserDefaultsOpenMontageTaskRootStore: OpenMontageTaskRootProviding, @unchecked Sendable {
    static let bookmarkKey = "OpenMontageTaskRootBookmark.v1"
    static let installationIDKey = "OpenMontageImageAllInstallationID.v1"

    let managedRoot: URL
    let defaults: UserDefaults
    let bookmarks: any SecurityScopedBookmarkPort

    init(
        defaults: UserDefaults = .standard,
        managedRoot: URL = Self.managedTaskRoot,
        bookmarks: any SecurityScopedBookmarkPort = FoundationSecurityScopedBookmarkAdapter()
    ) {
        self.managedRoot = managedRoot
        self.defaults = defaults
        self.bookmarks = bookmarks
    }

    static var managedTaskRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImageAll/OpenMontageTasks", isDirectory: true)
    }

    var configuredRootURL: URL? {
        try? resolveTaskRoot()
    }

    var installationID: String {
        if let existing = defaults.string(forKey: Self.installationIDKey), !existing.isEmpty {
            return existing
        }
        let created = "imageall-\(UUID().uuidString.lowercased())"
        defaults.set(created, forKey: Self.installationIDKey)
        return created
    }

    func saveTaskRoot(_ url: URL) throws {
        let accessing = bookmarks.startAccessing(url)
        defer { if accessing { bookmarks.stopAccessing(url) } }
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isPackageKey,
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              values.isPackage != true
        else { throw OpenMontageTaskError.taskRootUnsafe }
        if url.standardizedFileURL == managedRoot.standardizedFileURL {
            clearTaskRoot() // Explicit selection of the App-owned directory needs no external grant.
            return
        }
        let bookmark = try bookmarks.createWritableBookmark(for: url)
        // Verify the persisted grant, not just the transient NSOpenPanel URL.
        let resolved = try bookmarks.resolveBookmark(bookmark)
        guard !resolved.isStale, bookmarks.startAccessing(resolved.url) else {
            throw OpenMontageTaskError.taskRootAuthorizationRequired
        }
        defer { bookmarks.stopAccessing(resolved.url) }
        defaults.set(bookmark, forKey: Self.bookmarkKey)
    }

    func clearTaskRoot() {
        defaults.removeObject(forKey: Self.bookmarkKey)
    }

    func resolveTaskRoot() throws -> URL {
        guard OpenMontageConfiguration.enabled(defaults) else {
            throw OpenMontageTaskError.executorOffline("OpenMontage 已在设置中停用。")
        }
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else {
            let root = managedRoot
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
        let resolved: BookmarkResolveResult
        do {
            resolved = try bookmarks.resolveBookmark(bookmark)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code)
            {
                throw OpenMontageTaskError.taskRootOffline
            }
            throw OpenMontageTaskError.taskRootAuthorizationRequired
        }
        if resolved.isStale {
            // A stale bookmark can still hold a valid grant after an app update.
            // Renew only while that grant is active; never switch queues silently.
            guard bookmarks.startAccessing(resolved.url) else {
                throw OpenMontageTaskError.taskRootAuthorizationRequired
            }
            defer { bookmarks.stopAccessing(resolved.url) }
            let refreshed = try bookmarks.createWritableBookmark(for: resolved.url)
            defaults.set(refreshed, forKey: Self.bookmarkKey)
        }
        return resolved.url
    }

    func startAccessing(_ url: URL) -> Bool {
        url.standardizedFileURL == managedRoot.standardizedFileURL || bookmarks.startAccessing(url)
    }

    func stopAccessing(_ url: URL) {
        if url.standardizedFileURL != managedRoot.standardizedFileURL { bookmarks.stopAccessing(url) }
    }
}

struct OpenMontageTaskDirectoryInspector: Sendable {
    let rootProvider: any OpenMontageTaskRootProviding

    func capability(now: Date = Date()) async -> OpenMontageExecutorCapability {
        do {
            let root = try rootProvider.resolveTaskRoot()
            guard rootProvider.startAccessing(root) else {
                throw OpenMontageTaskError.taskRootAuthorizationRequired
            }
            defer { rootProvider.stopAccessing(root) }
            return try FileOpenMontageStoryTaskClient.readCapability(root: root, now: now)
        } catch let error as OpenMontageTaskError {
            let state: OpenMontageExecutorConnectionState = switch error {
            case .taskRootNotConfigured: .unconfigured
            case .executorIncompatible: .incompatible
            case .dependenciesUnavailable: .dependenciesUnavailable
            case .taskRootAuthorizationRequired: .authorizationRequired
            case .taskRootOffline, .taskRootUnsafe,
                 .executorOffline, .taskAlreadyActive, .protocolViolation,
                 .resultValidationFailed: .offline
            }
            return OpenMontageExecutorCapability(
                state: state,
                protocolVersion: nil,
                executorVersion: nil,
                schemaSHA256: nil,
                heartbeatAtMs: nil,
                detail: error.localizedDescription
            )
        } catch {
            return OpenMontageExecutorCapability(
                state: .offline,
                protocolVersion: nil,
                executorVersion: nil,
                schemaSHA256: nil,
                heartbeatAtMs: nil,
                detail: "无法读取 OpenMontage 状态：\(error.localizedDescription)"
            )
        }
    }
}

actor FileOpenMontageStoryTaskClient: OpenMontageStoryTasking {
    static let protocolVersion = OpenMontageContract.taskProtocolVersion
    // Pinned ImageAll typography envelope extension; synchronized with the bundled
    // protocol schema and lock by scripts/openmontage/task_protocol_patch.py.
    static let protocolSchemaSHA256 = OpenMontageContract.taskProtocolSHA256
    static let storySchemaSHA256 = StoryRenderPackageExporter.schemaSHA256
    static let heartbeatStaleSeconds: TimeInterval = 10

    private let rootProvider: any OpenMontageTaskRootProviding
    private let packageExporter: any TimeStoryPackageExporting
    private let installationID: String
    private let applicationVersion: String
    private let now: @Sendable () -> Date
    private var observed: [String: ObservedTask] = [:]

    init(
        rootProvider: any OpenMontageTaskRootProviding,
        packageExporter: any TimeStoryPackageExporting,
        installationID: String,
        applicationVersion: String = FileOpenMontageStoryTaskClient.defaultApplicationVersion,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.rootProvider = rootProvider
        self.packageExporter = packageExporter
        self.installationID = installationID
        self.applicationVersion = applicationVersion
        self.now = now
    }

    func capability() async -> OpenMontageExecutorCapability {
        do {
            return try withRoot { root in
                try Self.readCapability(root: root, now: now())
            }
        } catch let error as OpenMontageTaskError {
            let state: OpenMontageExecutorConnectionState = switch error {
            case .taskRootNotConfigured: .unconfigured
            case .executorIncompatible: .incompatible
            case .dependenciesUnavailable: .dependenciesUnavailable
            case .taskRootAuthorizationRequired: .authorizationRequired
            case .taskRootOffline, .taskRootUnsafe,
                 .executorOffline, .taskAlreadyActive, .protocolViolation,
                 .resultValidationFailed: .offline
            }
            return OpenMontageExecutorCapability(
                state: state,
                protocolVersion: nil,
                executorVersion: nil,
                schemaSHA256: nil,
                heartbeatAtMs: nil,
                detail: error.localizedDescription
            )
        } catch {
            return OpenMontageExecutorCapability(
                state: .offline,
                protocolVersion: nil,
                executorVersion: nil,
                schemaSHA256: nil,
                heartbeatAtMs: nil,
                detail: "无法读取 OpenMontage 状态：\(error.localizedDescription)"
            )
        }
    }

    func submit(
        project: TimeStoryProject,
        aspect: TimeStoryPackageAspect,
        onProgress: @escaping @Sendable (OpenMontageStoryTaskSnapshot) -> Void
    ) async throws -> OpenMontageStoryTaskSnapshot {
        let expectedProjectID = StoryRenderPackageExporter.packageProjectID(for: project.id)
        let root = try rootProvider.resolveTaskRoot()
        guard rootProvider.startAccessing(root) else {
            throw OpenMontageTaskError.taskRootAuthorizationRequired
        }
        defer { rootProvider.stopAccessing(root) }
        let capability = try Self.readCapability(root: root, now: now())
        guard capability.state == .ready else {
            switch capability.state {
            case .dependenciesUnavailable:
                throw OpenMontageTaskError.dependenciesUnavailable(capability.detail)
            case .incompatible:
                throw OpenMontageTaskError.executorIncompatible(capability.detail)
            case .authorizationRequired: throw OpenMontageTaskError.taskRootAuthorizationRequired
            case .unconfigured, .offline:
                throw OpenMontageTaskError.executorOffline(capability.detail)
            case .ready:
                throw OpenMontageTaskError.executorIncompatible("执行器能力状态无法确认。")
            }
        }
        let heartbeat = try Self.decode(
            HeartbeatDocument.self,
            at: root.appendingPathComponent("executor/heartbeat.json")
        )
        guard heartbeat.activeTaskID == nil,
              !observed.values.contains(where: { !$0.snapshot.phase.isTerminal }),
              try !Self.hasUnfinishedPublishedTask(under: root)
        else {
            throw OpenMontageTaskError.taskAlreadyActive
        }

        let taskID = "imageall-\(UUID().uuidString.lowercased())"
        onProgress(OpenMontageStoryTaskSnapshot(
            taskID: taskID,
            projectID: expectedProjectID,
            projectRevision: nil,
            aspect: aspect,
            totalFrames: nil,
            phase: .preparingAssets,
            progress: 0,
            updatedAtMs: Self.milliseconds(now()),
            detail: "正在准备本次任务的故事素材。",
            result: nil
        ))

        let fileManager = FileManager.default
        let tasksRoot = root.appendingPathComponent("tasks", isDirectory: true)
        try Self.ensureDirectory(tasksRoot, under: root, create: true)
        let taskRoot = tasksRoot.appendingPathComponent(taskID, isDirectory: true)
        guard !fileManager.fileExists(atPath: taskRoot.path) else {
            throw OpenMontageTaskError.protocolViolation("新任务身份已经存在。")
        }
        let submission = taskRoot.appendingPathComponent("submission", isDirectory: true)
        let requests = taskRoot.appendingPathComponent("requests", isDirectory: true)
        try fileManager.createDirectory(at: submission, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: requests, withIntermediateDirectories: false)
        var completionPublished = false
        defer {
            if !completionPublished {
                try? fileManager.removeItem(at: taskRoot)
            }
        }

        let package = submission.appendingPathComponent("package", isDirectory: true)
        let exportResult = try await packageExporter.export(
            project: project,
            aspect: aspect,
            destinationURL: package,
            onProgress: { packageProgress in
                onProgress(OpenMontageStoryTaskSnapshot(
                    taskID: taskID,
                    projectID: expectedProjectID,
                    projectRevision: nil,
                    aspect: aspect,
                    totalFrames: nil,
                    phase: .preparingAssets,
                    progress: min(0.88, packageProgress.fraction * 0.88),
                    updatedAtMs: Self.milliseconds(Date()),
                    detail: "正在准备本次任务的故事素材。",
                    result: nil
                ))
            }
        )
        guard exportResult.projectID == expectedProjectID else {
            throw OpenMontageTaskError.protocolViolation("故事项目身份与冻结导出不一致。")
        }
        let storyURL = package.appendingPathComponent("story.json")
        let story = try Self.decode(StoryRenderPackageDocument.self, at: storyURL)
        guard story.projectID == exportResult.projectID,
              story.projectRevision == exportResult.projectRevision,
              story.export.totalFrames == exportResult.totalFrames,
              story.export.fps == 30,
              story.export.width == aspect.width,
              story.export.height == aspect.height
        else {
            throw OpenMontageTaskError.protocolViolation("故事入口与导出结果身份不一致。")
        }

        let submittedAt = Self.timestamp(now())
        let submitter = SubmitterDocument(
            application: "ImageAll",
            applicationVersion: applicationVersion,
            installationID: installationID
        )
        let taskDocument = TaskDocument(
            documentType: "story-task",
            protocolVersion: Self.protocolVersion,
            taskType: "story-render",
            taskID: taskID,
            projectID: story.projectID,
            projectRevision: story.projectRevision,
            submittedBy: submitter,
            submittedAt: submittedAt,
            storyPackage: .init(
                entrypoint: "package/story.json",
                schemaVersion: StoryRenderPackageExporter.schemaVersion,
                schemaSHA256: Self.storySchemaSHA256
            )
        )
        try Self.atomicWrite(
            Self.encode(taskDocument),
            to: submission.appendingPathComponent("task.json")
        )
        try Task.checkCancellation()

        let expectedPaths = Set(
            ["task.json", "package/story.json"]
                + story.assets.map { "package/\($0.relativePath)" }
        )
        let actualPaths = try Self.submissionRegularFiles(at: submission)
        guard actualPaths == expectedPaths else {
            let extras = actualPaths.subtracting(expectedPaths).sorted()
            let missing = expectedPaths.subtracting(actualPaths).sorted()
            throw OpenMontageTaskError.protocolViolation(
                "任务文件集合不完整（多余 \(extras.prefix(4).joined(separator: ", "))；缺少 \(missing.prefix(4).joined(separator: ", "))）。"
            )
        }
        let entries = try expectedPaths.sorted().map { relativePath -> CompletionDocument.FileEntry in
            let file = try Self.resolveSafeExistingFile(relativePath, under: submission)
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize else {
                throw OpenMontageTaskError.protocolViolation("任务清单包含非普通文件。")
            }
            return .init(
                path: relativePath,
                sizeBytes: size,
                sha256: try OpenMontageTaskFileValidation.sha256(file)
            )
        }
        let manifest = entries.map { "\($0.sha256)  \($0.sizeBytes)  \($0.path)\n" }.joined()
        let completion = CompletionDocument(
            documentType: "story-task-completion",
            protocolVersion: Self.protocolVersion,
            producer: submitter,
            deliveryID: taskID,
            taskID: taskID,
            projectID: story.projectID,
            projectRevision: story.projectRevision,
            status: "complete",
            storyPackage: taskDocument.storyPackage,
            completedAt: Self.timestamp(now()),
            hashAlgorithm: "sha256",
            files: entries,
            manifestSHA256: Self.sha256(Data(manifest.utf8))
        )
        try Task.checkCancellation()
        try Self.atomicWrite(
            Self.encode(completion),
            to: submission.appendingPathComponent("complete.json")
        )
        completionPublished = true

        let snapshot = OpenMontageStoryTaskSnapshot(
            taskID: taskID,
            projectID: story.projectID,
            projectRevision: story.projectRevision,
            aspect: aspect,
            totalFrames: story.export.totalFrames,
            phase: .waitingForExecutor,
            progress: 0,
            updatedAtMs: Self.milliseconds(now()),
            detail: "任务已完整发布，等待 OpenMontage 接收。",
            result: nil
        )
        observed[taskID] = ObservedTask(eventSequence: 0, snapshot: snapshot)
        onProgress(snapshot)
        return snapshot
    }

    func task(taskID: String) async throws -> OpenMontageStoryTaskSnapshot {
        try Self.validateTaskID(taskID)
        return try await withRootAsync { root in
            try await readTask(taskID: taskID, root: root)
        }
    }

    /// Explicit retry of a confirmed failed/cancelled local render. Never reload source media.
    func retryFrozenTask(taskID: String) async throws -> OpenMontageStoryTaskSnapshot {
        try Self.validateTaskID(taskID)
        return try await withRootAsync { root in
            // Use a fresh client view: a cached terminal result cannot authorize changed disk state.
            observed[taskID] = nil
            let previous = try await readTask(taskID: taskID, root: root)
            guard previous.phase == .failed || previous.phase == .cancelled else {
                throw OpenMontageTaskError.protocolViolation("仅已确认失败或取消的本地制作可重试；状态未知时请先检查连接。")
            }
            _ = try Self.readCapability(root: root, now: now())
            guard try !Self.hasUnfinishedPublishedTask(under: root) else { throw OpenMontageTaskError.taskAlreadyActive }
            let heartbeat = try Self.decode(HeartbeatDocument.self, at: root.appendingPathComponent("executor/heartbeat.json"))
            guard heartbeat.activeTaskID == nil else { throw OpenMontageTaskError.taskAlreadyActive }
            let oldRoot = try Self.taskRoot(taskID: taskID, root: root)
            let source = oldRoot.appendingPathComponent("submission")
            let task = try Self.decode(TaskDocument.self, at: source.appendingPathComponent("task.json"))
            let original = try Self.decode(CompletionDocument.self, at: source.appendingPathComponent("complete.json"))
            guard task.storyPackage.schemaSHA256 == Self.storySchemaSHA256 else {
                throw OpenMontageTaskError.executorIncompatible("旧任务格式不受当前执行器支持，请从项目重新制作。")
            }
            let paths = Set(original.files.map(\.path))
            guard paths.count == original.files.count, paths == (try Self.submissionRegularFiles(at: source)) else {
                throw OpenMontageTaskError.protocolViolation("冻结任务的文件清单不一致，不能重试。")
            }
            let manifest = original.files.sorted { $0.path < $1.path }.map { "\($0.sha256)  \($0.sizeBytes)  \($0.path)\n" }.joined()
            guard Self.sha256(Data(manifest.utf8)) == original.manifestSHA256 else {
                throw OpenMontageTaskError.protocolViolation("冻结任务的清单摘要不一致，不能重试。")
            }
            let newID = "imageall-\(UUID().uuidString.lowercased())"
            let destinationRoot = try Self.taskRoot(taskID: newID, root: root)
            let destination = destinationRoot.appendingPathComponent("submission")
            try Self.ensureDirectory(destination, under: root, create: true)
            var published = false
            defer { if !published { try? FileManager.default.removeItem(at: destinationRoot) } }
            for entry in original.files {
                try Task.checkCancellation()
                let input = try Self.resolveSafeExistingFile(entry.path, under: source)
                guard try input.resourceValues(forKeys: [.fileSizeKey]).fileSize == entry.sizeBytes,
                      try OpenMontageTaskFileValidation.sha256(input) == entry.sha256 else {
                    throw OpenMontageTaskError.protocolViolation("冻结素材已改变，不能重试。")
                }
                if entry.path == "task.json" { continue } // The retry publishes a fresh identity once.
                let output = destination.appendingPathComponent(entry.path)
                try Self.ensureDirectory(output.deletingLastPathComponent(), under: destination, create: true)
                try FileManager.default.copyItem(at: input, to: output)
                guard try OpenMontageTaskFileValidation.sha256(output) == entry.sha256 else {
                    throw OpenMontageTaskError.protocolViolation("冻结素材复制校验失败。")
                }
            }
            let timestamp = Self.timestamp(now())
            let nextTask = TaskDocument(documentType: task.documentType, protocolVersion: task.protocolVersion,
                taskType: task.taskType, taskID: newID, projectID: task.projectID, projectRevision: task.projectRevision,
                submittedBy: task.submittedBy, submittedAt: timestamp, storyPackage: task.storyPackage)
            try Self.atomicWrite(Self.encode(nextTask), to: destination.appendingPathComponent("task.json"))
            let entries = try original.files.sorted { $0.path < $1.path }.map { entry -> CompletionDocument.FileEntry in
                let url = try Self.resolveSafeExistingFile(entry.path, under: destination)
                return .init(path: entry.path, sizeBytes: try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
                             sha256: try OpenMontageTaskFileValidation.sha256(url))
            }
            let nextManifest = entries.map { "\($0.sha256)  \($0.sizeBytes)  \($0.path)\n" }.joined()
            let complete = CompletionDocument(documentType: original.documentType, protocolVersion: original.protocolVersion,
                producer: original.producer, deliveryID: newID, taskID: newID, projectID: original.projectID,
                projectRevision: original.projectRevision, status: "complete", storyPackage: original.storyPackage,
                completedAt: timestamp, hashAlgorithm: "sha256", files: entries,
                manifestSHA256: Self.sha256(Data(nextManifest.utf8)))
            try Self.atomicWrite(Self.encode(["retryOfTaskID": taskID, "createdAt": timestamp]),
                                 to: destinationRoot.appendingPathComponent("retry.json"))
            try Task.checkCancellation()
            try Self.atomicWrite(Self.encode(complete), to: destination.appendingPathComponent("complete.json"))
            published = true
            return try await readTask(taskID: newID, root: root)
        }
    }

    func diagnosticReport(taskID: String?) async throws -> Data {
        if let taskID { try Self.validateTaskID(taskID) }
        let connection = await capability()
        var report: [String: String] = ["format": "imageall-openmontage-diagnostic-v1",
            "generatedAt": Self.timestamp(now()), "connection": connection.state.rawValue,
            "expectedProtocolSHA256": Self.protocolSchemaSHA256, "expectedStorySHA256": Self.storySchemaSHA256]
        // Do not copy capability detail or raw errors: upstream validators can include the entire request.
        if let version = connection.executorVersion, version.count <= 40,
           version.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) { report["executorVersion"] = version }
        try? withRoot { root in
            if let observed = try? Self.decode(CapabilityDocument.self, at: root.appendingPathComponent("executor/capabilities.json")),
               observed.taskProtocolSchemaSHA256.count == 64,
               observed.taskProtocolSchemaSHA256.allSatisfy({ $0.isHexDigit }) {
                report["observedProtocolSHA256"] = observed.taskProtocolSchemaSHA256
            }
        }
        if let taskID {
            report["taskID"] = taskID
            try withRoot { root in
                let taskRoot = try Self.taskRoot(taskID: taskID, root: root)
                if let state = try? Self.decode(StatusDocument.self, at: taskRoot.appendingPathComponent("state/status.json")) {
                    let allowedStates = ["accepted", "validating", "queued", "running", "cancelling", "succeeded", "failed", "cancelled", "rejected", "interrupted"]
                    report["taskState"] = allowedStates.contains(state.state) ? state.state : "unknown"
                    let stages = ["intake", "validation", "preparation", "rendering", "verification", "publication", "terminal"]
                    report["stage"] = stages.contains(state.stage) ? state.stage : "unknown"
                    report["eventSequence"] = String(state.eventSequence)
                    report["terminal"] = String(state.terminal)
                    if let code = state.error?.code, code.count <= 80,
                       code.allSatisfy({ $0.isASCII && ($0.isUppercase || $0 == "_") }) { report["errorCode"] = code }
                } else { report["taskState"] = "unreadable-or-not-yet-accepted" }
            }
        }
        return try Self.encode(report)
    }

    func latestTask(projectID: UUID) async throws -> OpenMontageStoryTaskSnapshot? {
        let expectedProjectID = StoryRenderPackageExporter.packageProjectID(for: projectID)
        return try await withRootAsync { root in
            let tasksRoot = root.appendingPathComponent("tasks", isDirectory: true)
            guard FileManager.default.fileExists(atPath: tasksRoot.path) else { return nil }
            let urls = try FileManager.default.contentsOfDirectory(
                at: tasksRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            var newest: (taskID: String, updatedAt: Int64)?
            for url in urls {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let candidateID = url.lastPathComponent
                guard (try? Self.validateTaskID(candidateID)) != nil else { continue }
                let taskURL = url.appendingPathComponent("submission/task.json")
                guard let document = try? Self.decode(TaskDocument.self, at: taskURL),
                      document.projectID == expectedProjectID,
                      document.taskID == candidateID
                else { continue }
                let statusURL = url.appendingPathComponent("state/status.json")
                let updatedAt: Int64
                if let status = try? Self.decode(StatusDocument.self, at: statusURL),
                   let date = Self.parseTimestamp(status.updatedAt)
                {
                    updatedAt = Self.milliseconds(date)
                } else {
                    updatedAt = Self.milliseconds(Self.parseTimestamp(document.submittedAt) ?? .distantPast)
                }
                if newest == nil || updatedAt > newest!.updatedAt {
                    newest = (candidateID, updatedAt)
                }
            }
            guard let newest else { return nil }
            return try await readTask(taskID: newest.taskID, root: root)
        }
    }

    func requestCancellation(taskID: String) async throws -> OpenMontageStoryTaskSnapshot {
        try Self.validateTaskID(taskID)
        return try await withRootAsync { root in
            let current = try await readTask(taskID: taskID, root: root)
            guard !current.phase.isTerminal else { return current }
            let taskRoot = try Self.taskRoot(taskID: taskID, root: root)
            let cancelURL = taskRoot.appendingPathComponent("requests/cancel.json")
            if FileManager.default.fileExists(atPath: cancelURL.path) {
                let existing = try Self.decode(CancelDocument.self, at: cancelURL)
                guard existing.taskID == taskID,
                      existing.protocolVersion == Self.protocolVersion,
                      existing.documentType == "story-task-cancel"
                else {
                    throw OpenMontageTaskError.protocolViolation("已有取消请求身份无效。")
                }
                return current
            }
            let document = CancelDocument(
                documentType: "story-task-cancel",
                protocolVersion: Self.protocolVersion,
                taskID: taskID,
                requestID: "cancel-\(UUID().uuidString.lowercased())",
                requestedAt: Self.timestamp(now()),
                requestedBy: SubmitterDocument(
                    application: "ImageAll",
                    applicationVersion: applicationVersion,
                    installationID: installationID
                )
            )
            try Self.atomicWrite(Self.encode(document), to: cancelURL)
            return OpenMontageStoryTaskSnapshot(
                taskID: current.taskID,
                projectID: current.projectID,
                projectRevision: current.projectRevision,
                aspect: current.aspect,
                totalFrames: current.totalFrames,
                phase: current.phase,
                progress: current.progress,
                updatedAtMs: Self.milliseconds(now()),
                detail: "已请求取消，等待执行器确认。",
                result: nil
            )
        }
    }

    func verifiedResult(taskID: String) async throws -> OpenMontageVerifiedResult {
        try Self.validateTaskID(taskID)
        return try await withRootAsync { root in
            let snapshot = try await readTask(taskID: taskID, root: root)
            guard snapshot.phase == .succeeded, let result = snapshot.result else {
                throw OpenMontageTaskError.resultValidationFailed("任务尚未进入已验证成功状态。")
            }
            return result
        }
    }

    private static func isReadableStorySchema(version: String, hash: String) -> Bool {
        (version == OpenMontageContract.storySchemaVersion && hash == OpenMontageContract.storySchemaSHA256)
            || (version == OpenMontageContract.legacyStorySchemaVersion && hash == OpenMontageContract.legacyStorySchemaSHA256)
    }

    private func readTask(taskID: String, root: URL) async throws -> OpenMontageStoryTaskSnapshot {
        if let cached = observed[taskID], cached.snapshot.phase.isTerminal {
            return cached.snapshot
        }
        let taskRoot = try Self.taskRoot(taskID: taskID, root: root)
        let taskDocument = try Self.decode(
            TaskDocument.self,
            at: taskRoot.appendingPathComponent("submission/task.json")
        )
        let completion = try Self.decode(
            CompletionDocument.self,
            at: taskRoot.appendingPathComponent("submission/complete.json")
        )
        guard taskDocument.protocolVersion == Self.protocolVersion,
              taskDocument.documentType == "story-task",
              taskDocument.taskType == "story-render",
              taskDocument.taskID == taskID,
              completion.protocolVersion == Self.protocolVersion,
              completion.documentType == "story-task-completion",
              completion.producer.application == taskDocument.submittedBy.application,
              completion.producer.applicationVersion == taskDocument.submittedBy.applicationVersion,
              completion.producer.installationID == taskDocument.submittedBy.installationID,
              completion.deliveryID == taskID,
              completion.taskID == taskID,
              completion.projectID == taskDocument.projectID,
              completion.projectRevision == taskDocument.projectRevision,
              completion.status == "complete",
              completion.storyPackage.entrypoint == taskDocument.storyPackage.entrypoint,
              completion.storyPackage.schemaVersion == taskDocument.storyPackage.schemaVersion,
              completion.storyPackage.schemaSHA256 == taskDocument.storyPackage.schemaSHA256,
              Self.isReadableStorySchema(version: taskDocument.storyPackage.schemaVersion,
                                         hash: taskDocument.storyPackage.schemaSHA256)
        else { throw OpenMontageTaskError.protocolViolation("任务或完成记录身份不一致。") }
        let story = try Self.decode(
            StoryRenderPackageDocument.self,
            at: taskRoot.appendingPathComponent("submission/package/story.json")
        )
        guard story.schemaVersion == taskDocument.storyPackage.schemaVersion,
              story.projectID == taskDocument.projectID,
              story.projectRevision == taskDocument.projectRevision
        else { throw OpenMontageTaskError.protocolViolation("故事与任务项目身份不一致。") }
        let aspect = try Self.aspect(width: story.export.width, height: story.export.height)
        let statusURL = taskRoot.appendingPathComponent("state/status.json")
        guard FileManager.default.fileExists(atPath: statusURL.path) else {
            if let cached = observed[taskID] { return cached.snapshot }
            let capability = try? Self.readCapability(root: root, now: now())
            return OpenMontageStoryTaskSnapshot(
                taskID: taskID,
                projectID: story.projectID,
                projectRevision: story.projectRevision,
                aspect: aspect,
                totalFrames: story.export.totalFrames,
                phase: .waitingForExecutor,
                progress: 0,
                updatedAtMs: Self.milliseconds(now()),
                detail: capability?.state == .ready
                    ? "任务已发布，等待 OpenMontage 接收。"
                    : (capability?.detail ?? "执行器当前离线；任务不会自动重复提交。"),
                result: nil
            )
        }
        let status = try Self.decode(StatusDocument.self, at: statusURL)
        guard status.documentType == "story-task-status",
              status.protocolVersion == Self.protocolVersion,
              status.taskID == taskID,
              status.projectID == story.projectID,
              status.projectRevision == story.projectRevision,
              (status.submissionDigestSHA256 == completion.manifestSHA256
                || (status.state == "rejected" && status.terminal && status.stage == "terminal"
                    && status.error?.stage == "intake" && status.error?.retryable == false
                    && status.submissionDigestSHA256 == String(repeating: "0", count: 64))),
              (status.terminal == Self.isTerminalState(status.state))
        else { throw OpenMontageTaskError.protocolViolation("执行器状态身份或终态标记无效。") }
        if let cached = observed[taskID] {
            if status.eventSequence < cached.eventSequence { return cached.snapshot }
            if status.eventSequence == cached.eventSequence { return cached.snapshot }
        }

        let phase = Self.phase(state: status.state, stage: status.stage)
        let result: OpenMontageVerifiedResult?
        if phase == .succeeded {
            result = try await Self.validateResult(
                taskID: taskID,
                root: root,
                taskRoot: taskRoot,
                task: taskDocument,
                completion: completion,
                story: story,
                aspect: aspect
            )
        } else {
            result = nil
        }
        var detail = Self.userFacingTaskDetail(phase: phase, errorCode: status.error?.code)
        if detail == nil, !phase.isTerminal,
           let capability = try? Self.readCapability(root: root, now: now()),
           capability.state != .ready
        {
            detail = capability.detail + " 当前任务不会自动重新提交。"
        }
        let snapshot = OpenMontageStoryTaskSnapshot(
            taskID: taskID,
            projectID: story.projectID,
            projectRevision: story.projectRevision,
            aspect: aspect,
            totalFrames: story.export.totalFrames,
            phase: phase,
            progress: status.progress,
            updatedAtMs: Self.milliseconds(Self.parseTimestamp(status.updatedAt) ?? now()),
            detail: detail,
            result: result
        )
        observed[taskID] = ObservedTask(eventSequence: status.eventSequence, snapshot: snapshot)
        return snapshot
    }

    private func withRoot<T>(_ operation: (URL) throws -> T) throws -> T {
        let root = try rootProvider.resolveTaskRoot()
        guard rootProvider.startAccessing(root) else {
            throw OpenMontageTaskError.taskRootAuthorizationRequired
        }
        defer { rootProvider.stopAccessing(root) }
        return try operation(root)
    }

    private func withRootAsync<T>(
        _ operation: (URL) async throws -> T
    ) async throws -> T {
        let root = try rootProvider.resolveTaskRoot()
        guard rootProvider.startAccessing(root) else {
            throw OpenMontageTaskError.taskRootAuthorizationRequired
        }
        defer { rootProvider.stopAccessing(root) }
        return try await operation(root)
    }

    fileprivate static func readCapability(root: URL, now: Date) throws -> OpenMontageExecutorCapability {
        let capabilityURL = root.appendingPathComponent("executor/capabilities.json")
        let heartbeatURL = root.appendingPathComponent("executor/heartbeat.json")
        guard FileManager.default.fileExists(atPath: capabilityURL.path),
              FileManager.default.fileExists(atPath: heartbeatURL.path)
        else { throw OpenMontageTaskError.executorOffline("请先启动本地执行器。") }
        let document = try decode(CapabilityDocument.self, at: capabilityURL)
        guard document.documentType == "story-executor-capabilities",
              document.protocolVersion == protocolVersion,
              document.executorName == "openmontage-story-executor",
              document.taskProtocolSchemaSHA256 == protocolSchemaSHA256,
              document.storyPackageSchemas.contains(where: {
                  $0.version == StoryRenderPackageExporter.schemaVersion
                      && $0.sha256 == storySchemaSHA256
              }),
              document.taskTypes == ["story-render"],
              document.maxConcurrentTasks == 1,
              document.features.cancellation,
              document.features.restartRecovery,
              document.features.atomicResultPublication,
              !document.features.remoteAPI
        else {
            throw OpenMontageTaskError.executorIncompatible("任务协议或故事格式能力不匹配。")
        }
        guard document.readiness.ready else {
            let detail = document.readiness.checks.filter { !$0.ready }.map {
                [$0.detail, $0.installHint].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            }.joined(separator: "；")
            throw OpenMontageTaskError.dependenciesUnavailable(detail)
        }
        let heartbeat = try decode(HeartbeatDocument.self, at: heartbeatURL)
        guard heartbeat.documentType == "story-executor-heartbeat",
              heartbeat.protocolVersion == protocolVersion,
              heartbeat.executorVersion == document.executorVersion,
              heartbeat.instanceID == document.instanceID,
              let updated = parseTimestamp(heartbeat.updatedAt)
        else { throw OpenMontageTaskError.executorIncompatible("心跳身份与能力记录不一致。") }
        guard now.timeIntervalSince(updated) <= heartbeatStaleSeconds,
              now.timeIntervalSince(updated) >= -heartbeatStaleSeconds
        else { throw OpenMontageTaskError.executorOffline("执行器心跳已过期。") }
        switch heartbeat.availability {
        case "ready", "busy":
            break
        case "degraded":
            throw OpenMontageTaskError.dependenciesUnavailable("执行器报告本地依赖不可用。")
        case "starting":
            throw OpenMontageTaskError.executorOffline("本地执行器正在启动，请稍后刷新状态。")
        case "draining":
            throw OpenMontageTaskError.executorOffline("本地执行器正在停止，请等待它完成后重新启动。")
        case "stopped":
            throw OpenMontageTaskError.executorOffline("本地执行器已停止，请启动后刷新状态。")
        default:
            throw OpenMontageTaskError.executorIncompatible("执行器报告未知在线状态。")
        }
        return OpenMontageExecutorCapability(
            state: .ready,
            protocolVersion: document.protocolVersion,
            executorVersion: document.executorVersion,
            schemaSHA256: document.taskProtocolSchemaSHA256,
            heartbeatAtMs: milliseconds(updated),
            detail: heartbeat.availability == "busy"
                ? "已连接；执行器正在处理一个任务。"
                : "已连接并可制作。"
        )
    }

    private static func validateResult(
        taskID: String,
        root: URL,
        taskRoot: URL,
        task: TaskDocument,
        completion: CompletionDocument,
        story: StoryRenderPackageDocument,
        aspect: TimeStoryPackageAspect
    ) async throws -> OpenMontageVerifiedResult {
        let result = try decode(
            ResultDocument.self,
            at: taskRoot.appendingPathComponent("state/result.json")
        )
        guard result.documentType == "story-task-result",
              result.protocolVersion == protocolVersion,
              result.taskID == taskID,
              result.projectID == task.projectID,
              result.projectRevision == task.projectRevision,
              result.submissionDigestSHA256 == completion.manifestSHA256,
              result.storyPackageSHA256 == (try OpenMontageTaskFileValidation.sha256(
                  taskRoot.appendingPathComponent("submission/package/story.json")
              )),
              result.media.verificationStatus == "pass",
              result.media.width == aspect.width,
              result.media.height == aspect.height,
              abs(result.media.fps - 30) < 0.001,
              result.media.frames == story.export.totalFrames,
              abs(result.media.durationSeconds - Double(story.export.totalFrames) / 30) < 0.05
        else { throw OpenMontageTaskError.resultValidationFailed("任务身份、画幅、帧率或帧数不匹配。") }

        let requiredPrefix = "runs/\(taskID)/"
        guard result.output.path.hasPrefix(requiredPrefix) else {
            throw OpenMontageTaskError.resultValidationFailed("成片路径不在本任务结果目录内。")
        }
        let output = try resolveSafeExistingFile(result.output.path, under: root)
        let outputValues = try output.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard outputValues.isRegularFile == true,
              outputValues.fileSize == result.output.sizeBytes,
              try OpenMontageTaskFileValidation.sha256(output) == result.output.sha256
        else { throw OpenMontageTaskError.resultValidationFailed("成片文件大小或哈希不匹配。") }
        for report in [
            result.reports.validation,
            result.reports.consistency,
            result.reports.mediaVerification,
            result.reports.render,
        ] {
            guard report.path.hasPrefix(requiredPrefix) else {
                throw OpenMontageTaskError.resultValidationFailed("验证报告路径不在本任务结果目录内。")
            }
            let reportURL = try resolveSafeExistingFile(report.path, under: root)
            guard try OpenMontageTaskFileValidation.sha256(reportURL) == report.sha256 else {
                throw OpenMontageTaskError.resultValidationFailed("验证报告哈希不匹配。")
            }
        }
        let measured = try await inspectMovie(output)
        guard measured.width == aspect.width,
              measured.height == aspect.height,
              abs(measured.framesPerSecond - 30) < 0.01,
              measured.frames == story.export.totalFrames
        else { throw OpenMontageTaskError.resultValidationFailed("本机复核的画幅、帧率或帧数不匹配。") }
        return OpenMontageVerifiedResult(
            taskID: taskID,
            projectID: task.projectID,
            projectRevision: task.projectRevision,
            aspect: aspect,
            totalFrames: measured.frames,
            framesPerSecond: Int(measured.framesPerSecond.rounded()),
            width: measured.width,
            height: measured.height,
            fileURL: output,
            fileSHA256: result.output.sha256,
            authorizedRootURL: root
        )
    }

    private static func inspectMovie(_ url: URL) async throws -> MovieMeasurement {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw OpenMontageTaskError.resultValidationFailed("成片没有视频轨。")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = size.applying(transform)
        let fps = Double(try await track.load(.nominalFrameRate))
        guard fps.isFinite, fps > 0 else {
            throw OpenMontageTaskError.resultValidationFailed("无法确认成片帧率。")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else {
            throw OpenMontageTaskError.resultValidationFailed("无法读取成片视频帧。")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw OpenMontageTaskError.resultValidationFailed("无法开始复核成片。")
        }
        var frames = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // Compressed H.264 tracks can emit timing/end-marker buffers with
            // zero samples. Count video samples, not reader callbacks.
            frames += CMSampleBufferGetNumSamples(sampleBuffer)
        }
        guard reader.status == .completed else {
            throw OpenMontageTaskError.resultValidationFailed("成片未能完整解码。")
        }
        return MovieMeasurement(
            width: Int(abs(transformed.width).rounded()),
            height: Int(abs(transformed.height).rounded()),
            framesPerSecond: fps,
            frames: frames
        )
    }

    private static func taskRoot(taskID: String, root: URL) throws -> URL {
        try validateTaskID(taskID)
        let tasks = root.appendingPathComponent("tasks", isDirectory: true)
        let task = tasks.appendingPathComponent(taskID, isDirectory: true)
        try ensureContained(task, under: tasks)
        return task
    }

    private static func ensureDirectory(_ url: URL, under root: URL, create: Bool) throws {
        try ensureContained(url, under: root)
        if create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw OpenMontageTaskError.taskRootUnsafe
        }
    }

    private static func resolveSafeExistingFile(_ relativePath: String, under root: URL) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              })
        else { throw OpenMontageTaskError.taskRootUnsafe }
        let candidate = root.appendingPathComponent(relativePath)
        try ensureContained(candidate, under: root)
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        var relationship: FileManager.URLRelationship = .other
        try FileManager.default.getRelationship(
            &relationship,
            ofDirectoryAt: resolvedRoot,
            toItemAt: resolvedCandidate
        )
        guard relationship == .contains else { throw OpenMontageTaskError.taskRootUnsafe }
        let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw OpenMontageTaskError.taskRootUnsafe
        }
        return candidate
    }

    private static func ensureContained(_ candidate: URL, under root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw OpenMontageTaskError.taskRootUnsafe
        }
    }

    private static func submissionRegularFiles(at root: URL) throws -> Set<String> {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else { throw OpenMontageTaskError.protocolViolation("无法枚举任务文件。") }
        var files = Set<String>()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else { throw OpenMontageTaskError.taskRootUnsafe }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw OpenMontageTaskError.taskRootUnsafe }
            let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedURL.path.hasPrefix(resolvedRoot.path + "/") else {
                throw OpenMontageTaskError.taskRootUnsafe
            }
            let relative = String(resolvedURL.path.dropFirst(resolvedRoot.path.count + 1))
            guard relative != "complete.json" else { continue }
            files.insert(relative)
        }
        return files
    }

    private static func hasUnfinishedPublishedTask(under root: URL) throws -> Bool {
        let tasksRoot = root.appendingPathComponent("tasks", isDirectory: true)
        guard FileManager.default.fileExists(atPath: tasksRoot.path) else { return false }
        let taskDirectories = try FileManager.default.contentsOfDirectory(
            at: tasksRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for taskRoot in taskDirectories {
            let values = try taskRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let completionURL = taskRoot.appendingPathComponent("submission/complete.json")
            guard FileManager.default.fileExists(atPath: completionURL.path) else { continue }
            let statusURL = taskRoot.appendingPathComponent("state/status.json")
            guard FileManager.default.fileExists(atPath: statusURL.path) else { return true }
            guard let status = try? decode(StatusDocument.self, at: statusURL),
                  status.terminal == isTerminalState(status.state)
            else { return true }
            if !status.terminal { return true }
        }
        return false
    }

    private static func atomicWrite(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try ensureContained(destination, under: parent)
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).pending"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.withoutOverwriting])
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw OpenMontageTaskError.protocolViolation("协议文件已存在，拒绝覆盖。")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func validateTaskID(_ taskID: String) throws {
        guard !taskID.isEmpty, taskID.count <= 128,
              taskID.first?.isASCII == true,
              taskID.first?.isLetter == true || taskID.first?.isNumber == true,
              taskID.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-")
              })
        else { throw OpenMontageTaskError.protocolViolation("taskID 格式无效。") }
    }

    private static func aspect(width: Int, height: Int) throws -> TimeStoryPackageAspect {
        if width == TimeStoryPackageAspect.landscape.width,
           height == TimeStoryPackageAspect.landscape.height
        { return .landscape }
        if width == TimeStoryPackageAspect.portrait.width,
           height == TimeStoryPackageAspect.portrait.height
        { return .portrait }
        throw OpenMontageTaskError.protocolViolation("故事画幅不是受支持的横屏或竖屏。")
    }

    private static func phase(state: String, stage: String) -> OpenMontageStoryTaskPhase {
        switch state {
        case "succeeded": .succeeded
        case "failed", "rejected": .failed
        case "cancelled": .cancelled
        case "interrupted": .interrupted
        case "accepted", "validating", "queued": .waitingForExecutor
        case "running", "cancelling":
            stage == "verification" || stage == "publication" ? .verifyingResult : .rendering
        default: .interrupted
        }
    }

    private static func userFacingTaskDetail(
        phase: OpenMontageStoryTaskPhase,
        errorCode: String?
    ) -> String? {
        switch phase {
        case .failed:
            if errorCode == "COMPLETION_INVALID" {
                return "执行器拒绝了任务提交记录，尚未开始渲染。请更新本地执行器后重新制作。"
            }
            if errorCode == "RESULT_VERIFICATION_FAILED" {
                return "成片未通过执行器检查。请查看本地任务记录；原生制作仍可使用。"
            }
            return "这次制作未完成。请查看本地执行器的任务记录；原生制作仍可使用。"
        case .cancelled:
            return "取消请求已确认，没有发布成片。"
        case .interrupted:
            return "制作已中断，结果无法确认；请检查本地执行器。不会自动重新提交。"
        case .preparingAssets, .waitingForExecutor, .rendering, .verifyingResult, .succeeded:
            return nil
        }
    }

    private static func isTerminalState(_ state: String) -> Bool {
        ["succeeded", "failed", "cancelled", "rejected", "interrupted"].contains(state)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OpenMontageTaskError.protocolViolation("缺少协议文件 \(url.lastPathComponent)。")
        }
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch {
            throw OpenMontageTaskError.protocolViolation(
                "无法读取协议文件 \(url.lastPathComponent)：\(error.localizedDescription)"
            )
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static var defaultApplicationVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
        return "\(version) (\(build))"
    }
}

private extension FileOpenMontageStoryTaskClient {
    struct ObservedTask: Sendable {
        let eventSequence: Int
        let snapshot: OpenMontageStoryTaskSnapshot
    }

    struct MovieMeasurement: Sendable {
        let width: Int
        let height: Int
        let framesPerSecond: Double
        let frames: Int
    }

    struct SubmitterDocument: Codable, Sendable {
        let application: String
        let applicationVersion: String
        let installationID: String
    }

    struct TaskDocument: Codable, Sendable {
        let documentType: String
        let protocolVersion: String
        let taskType: String
        let taskID: String
        let projectID: String
        let projectRevision: String
        let submittedBy: SubmitterDocument
        let submittedAt: String
        let storyPackage: StoryPackage

        struct StoryPackage: Codable, Sendable {
            let entrypoint: String
            let schemaVersion: String
            let schemaSHA256: String
        }
    }

    struct CompletionDocument: Codable, Sendable {
        let documentType: String
        let protocolVersion: String
        let producer: SubmitterDocument
        let deliveryID: String
        let taskID: String
        let projectID: String
        let projectRevision: String
        let status: String
        let storyPackage: TaskDocument.StoryPackage
        let completedAt: String
        let hashAlgorithm: String
        let files: [FileEntry]
        let manifestSHA256: String

        struct FileEntry: Codable, Sendable {
            let path: String
            let sizeBytes: Int
            let sha256: String
        }
    }

    struct CancelDocument: Codable, Sendable {
        let documentType: String
        let protocolVersion: String
        let taskID: String
        let requestID: String
        let requestedAt: String
        let requestedBy: SubmitterDocument
    }

    struct CapabilityDocument: Codable, Sendable {
        let documentType: String
        let protocolVersion: String
        let executorName: String
        let executorVersion: String
        let instanceID: String
        let taskProtocolSchemaSHA256: String
        let storyPackageSchemas: [StorySchema]
        let taskTypes: [String]
        let maxConcurrentTasks: Int
        let features: Features
        let readiness: Readiness
        let generatedAt: String

        struct StorySchema: Codable, Sendable { let version: String; let sha256: String }
        struct Features: Codable, Sendable {
            let cancellation: Bool
            let restartRecovery: Bool
            let atomicResultPublication: Bool
            let remoteAPI: Bool
        }
        struct Readiness: Codable, Sendable { let ready: Bool; let checks: [Check] }
        struct Check: Codable, Sendable {
            let name: String
            let ready: Bool
            let detail: String
            let installHint: String?
        }
    }

    struct HeartbeatDocument: Codable, Sendable {
        let documentType: String
        let protocolVersion: String
        let executorVersion: String
        let instanceID: String
        let pid: Int
        let sequence: Int
        let availability: String
        let activeTaskID: String?
        let startedAt: String
        let updatedAt: String
    }

    struct StatusDocument: Codable, Sendable {
        let documentType: String
        let protocolVersion: String
        let taskID: String
        let projectID: String
        let projectRevision: String
        let submissionDigestSHA256: String
        let eventSequence: Int
        let state: String
        let stage: String
        let progress: Double
        let terminal: Bool
        let updatedAt: String
        let error: ErrorDocument?

        struct ErrorDocument: Codable, Sendable {
            let code: String
            let stage: String
            let message: String
            let retryable: Bool
            let detailsCode: String?
        }
    }

    struct ResultDocument: Codable, Sendable {
        let documentType: String
        let protocolVersion: String
        let taskID: String
        let projectID: String
        let projectRevision: String
        let submissionDigestSHA256: String
        let adapterRunID: String
        let storyPackageSHA256: String
        let output: Output
        let media: Media
        let reports: Reports
        let publishedAt: String

        struct Output: Codable, Sendable {
            let path: String
            let sha256: String
            let sizeBytes: Int
        }
        struct Media: Codable, Sendable {
            let videoCodec: String
            let audioCodec: String?
            let width: Int
            let height: Int
            let fps: Double
            let frames: Int
            let durationSeconds: Double
            let verificationStatus: String
        }
        struct Reports: Codable, Sendable {
            let validation: Report
            let consistency: Report
            let mediaVerification: Report
            let render: Report
        }
        struct Report: Codable, Sendable { let path: String; let sha256: String }
    }
}
