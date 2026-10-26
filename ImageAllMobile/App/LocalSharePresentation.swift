import Foundation
import Darwin
import ImageAllRemoteProtocol

/// Read progress is deliberately separate from a successful digest comparison.
/// No resource names, locators or source bytes are retained here.
struct LocalShareSourceRevalidationProgress {
    static let reasonCode = "sourceVersionUnverified"
    private(set) var wasRequired = false
    private(set) var isReading = false
    private(set) var expectedBytes: Int64 = 0
    private(set) var readBytes: Int64 = 0
    private(set) var verifiedResources = 0

    mutating func begin(expectedBytes: Int64) {
        wasRequired = true
        self.expectedBytes = max(0, expectedBytes)
        readBytes = 0
        isReading = true
    }
    mutating func recordReadBytes(_ count: Int64) {
        guard isReading else { return }
        readBytes = max(readBytes, count)
    }
    /// Call only after the existing checkpoint digest check and save succeed.
    mutating func didVerify() {
        guard isReading else { return }
        isReading = false
        verifiedResources += 1
    }
    mutating func stopReading() { isReading = false }
    var message: String {
        guard isReading else { return "本轮来源重验已通过 \(verifiedResources) 个资源" }
        let read = ByteCountFormatter.string(fromByteCount: readBytes, countStyle: .binary)
        let expected = ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .binary)
        return "缺少当前来源版本的验证记录，正在重读手机原件 · 已读 \(read) / 预期 \(expected) · 本轮已通过 \(verifiedResources) 个资源；读完后仍需比对摘要"
    }
}

/// Persisted user intent. Archive/checkpoint records remain the byte-progress authority.
struct LocalShareTask: Codable {
    enum Phase: String, Codable { case idle, running, pausing, paused, failed, received }
    enum Intent: String, Codable { case transferSelection, sealReceived }
    enum PauseReason: String, Codable {
        case userRequested, appBackground, usbDisconnected, cancelled, processInterrupted
        var message: String {
            switch self {
            case .userRequested: "已按你的操作暂停。"
            case .appBackground: "App 进入后台，已暂停；请回到前台后继续。"
            case .usbDisconnected: "USB 连接已中断；请恢复原 Mac 连接。"
            case .cancelled: "本轮任务已取消，未记录到更具体的触发原因。"
            case .processInterrupted: "上次任务随 App 退出而中断；请核对原范围后手动继续。"
            }
        }
    }
    var phase: Phase = .idle
    private(set) var intent: Intent = .transferSelection
    private(set) var pauseReason: PauseReason?
    private(set) var receivedItemCount: Int?
    var itemCount = 0
    var target = ""
    var macOwnsProcessing: Bool?
    var detail: String?
    // Fresh observations only; do not persist live Mac phases across app exit.
    var macStatus: RemoteImportTaskStatus?
    // Runtime error descriptions can contain private paths; never persist them.
    enum CodingKeys: String, CodingKey {
        case phase, intent, pauseReason, receivedItemCount, itemCount, target, macOwnsProcessing
    }
    mutating func begin(itemCount: Int, target: String, intent: Intent = .transferSelection) {
        self.itemCount = itemCount; self.target = target; detail = nil; phase = .running
        self.intent = intent; pauseReason = nil; receivedItemCount = nil
    }
    mutating func requestPause(_ reason: PauseReason) {
        guard phase == .running else { return }
        pauseReason = reason; phase = .pausing
    }
    mutating func pause(reason: PauseReason = .cancelled) {
        if pauseReason == nil { pauseReason = reason }
        phase = .paused
    }
    mutating func receive(itemCount: Int) {
        receivedItemCount = itemCount; pauseReason = nil; phase = .received
    }
}

enum LocalShareTaskRecoveryError: Error, LocalizedError {
    case invalidRecord, bindingChanged, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidRecord: "原导入任务记录无法读取或版本不兼容，已停止新传输；请保留记录排查。"
        case .bindingChanged: "原导入任务的范围、来源或目标已变化，不能静默改为新批次。"
        case .unavailable: "导入任务记录无法保存，已停止新传输；请检查本机存储后重新打开 App。"
        }
    }
}

/// A validated old seal, not a new transfer or a fresh integrity receipt.
struct LocalShareLegacyCandidate: Sendable {
    let receipt: ImageAllMigrationTransferSealReceipt
    let sourceInstallID: UUID
    let sourceEpoch: UUID
    let hostID: UUID
    let selectionIDs: Set<UUID>
    let includeAlbumCatalog: Bool

    init?(record: ImageAllMigrationStreamRecord, hostID: UUID, deviceID: UUID,
          sourceInstallID: UUID, sourceEpoch: UUID, selectionIDs: Set<UUID>, includeAlbumCatalog: Bool) throws {
        try record.validate()
        guard record.hostID == hostID, record.deviceID == deviceID,
              record.header.sourceDeviceID == sourceInstallID, record.header.sourceEpoch == sourceEpoch,
              Set(record.header.retainedSelectionIDs ?? record.items.map(\.mediaID)) == selectionIDs,
              (record.header.appleAlbumCatalog != nil) == includeAlbumCatalog else { return nil }
        receipt = record.receipt
        self.sourceInstallID = sourceInstallID; self.sourceEpoch = sourceEpoch
        self.hostID = hostID; self.selectionIDs = selectionIDs; self.includeAlbumCatalog = includeAlbumCatalog
    }

    func query(taskID: UUID) -> RemoteImportTaskQuery {
        .init(taskID: taskID, migrationID: receipt.migrationID, sourceInstallID: sourceInstallID,
              sourceEpoch: sourceEpoch, manifestSHA256: receipt.manifestSHA256)
    }
}

struct LocalShareTaskRecord: Codable {
    let version: Int
    let taskID: UUID
    var task: LocalShareTask
    private(set) var selectionIDs: Set<UUID>
    private(set) var includeAlbumCatalog: Bool
    private(set) var hostID: String
    private(set) var fingerprint: String
    private(set) var sourceInstallID: UUID?
    private(set) var sourceEpoch: UUID?
    private(set) var migrationID: UUID?
    private(set) var sealedManifestSHA256: String?
    private(set) var exportStagingName: String?
    private(set) var automaticCleanup: ImageAllAutomaticCleanup?

    init() {
        version = 1; taskID = UUID(); task = LocalShareTask()
        selectionIDs = []; includeAlbumCatalog = false; hostID = ""; fingerprint = ""
    }

    mutating func begin(selectionIDs: Set<UUID>, includeAlbumCatalog: Bool, hostID: String,
                        fingerprint: String, target: String, intent: LocalShareTask.Intent) throws {
        guard !selectionIDs.isEmpty, UUID(uuidString: hostID) != nil, !fingerprint.isEmpty,
              task.phase == .idle || task.phase == .paused || task.phase == .failed else {
            throw LocalShareTaskRecoveryError.bindingChanged
        }
        if task.phase != .idle {
            guard self.selectionIDs == selectionIDs, self.includeAlbumCatalog == includeAlbumCatalog,
                  self.hostID == hostID, self.fingerprint == fingerprint else {
                throw LocalShareTaskRecoveryError.bindingChanged
            }
        }
        if task.phase == .idle { automaticCleanup = .init() }
        self.selectionIDs = selectionIDs; self.includeAlbumCatalog = includeAlbumCatalog
        self.hostID = hostID; self.fingerprint = fingerprint
        task.begin(itemCount: selectionIDs.count, target: target, intent: intent)
    }

    mutating func bind(sourceInstallID: UUID, sourceEpoch: UUID) throws {
        guard self.sourceInstallID == nil || self.sourceInstallID == sourceInstallID,
              self.sourceEpoch == nil || self.sourceEpoch == sourceEpoch else {
            throw LocalShareTaskRecoveryError.bindingChanged
        }
        self.sourceInstallID = sourceInstallID; self.sourceEpoch = sourceEpoch
    }

    mutating func bind(migrationID: UUID) throws {
        guard self.migrationID == nil || self.migrationID == migrationID else {
            throw LocalShareTaskRecoveryError.bindingChanged
        }
        self.migrationID = migrationID
    }

    mutating func bindExportRoot(_ root: URL, migrationID: UUID) throws {
        let name = root.lastPathComponent
        let suffix = name.dropFirst(9)
        guard self.migrationID == migrationID, name.hasPrefix(".staging-"),
              name.count == 73, suffix.allSatisfy({ "0123456789abcdef".contains($0) }),
              exportStagingName == nil || exportStagingName == name else {
            throw LocalShareTaskRecoveryError.bindingChanged
        }
        exportStagingName = name
    }

    mutating func beginAutomaticCleanup(nowMs: Int64, connected: Bool, ready: Bool) -> UUID? {
        guard statusQuery != nil, exportStagingName != nil else { return nil }
        return automaticCleanup?.begin(nowMs: nowMs, connected: connected, ready: ready)
    }
    mutating func finishAutomaticCleanup(_ nonce: UUID, failure: ImageAllAutomaticCleanup.Reason? = nil, nowMs: Int64) {
        if let failure { automaticCleanup?.deferAttempt(nonce, reason: failure, nowMs: nowMs) }
        else { automaticCleanup?.complete(nonce) }
    }

    mutating func receive(_ receipt: ImageAllMigrationTransferSealReceipt) throws {
        guard receipt.migrationID == migrationID,
              (0...task.itemCount).contains(receipt.itemCount),
              sealedManifestSHA256 == nil || sealedManifestSHA256 == receipt.manifestSHA256 else {
            throw LocalShareTaskRecoveryError.bindingChanged
        }
        sealedManifestSHA256 = receipt.manifestSHA256
        if receipt.hostProcessingVersion == 1 {
            task.macOwnsProcessing = true
            automaticCleanup = nil
        }
        task.receive(itemCount: receipt.itemCount)
    }

    var statusQuery: RemoteImportTaskQuery? {
        guard task.phase == .received, let migrationID, let sourceInstallID, let sourceEpoch,
              let sealedManifestSHA256 else { return nil }
        return .init(taskID: taskID, migrationID: migrationID, sourceInstallID: sourceInstallID,
                     sourceEpoch: sourceEpoch, manifestSHA256: sealedManifestSHA256)
    }

    mutating func observe(_ status: RemoteImportTaskStatus) throws {
        guard status.query == statusQuery,
              status.itemCount == nil || status.itemCount == task.receivedItemCount,
              status.phase != .browsable || (status.sourceID != nil && status.itemCount == task.receivedItemCount) else {
            throw LocalShareTaskRecoveryError.bindingChanged
        }
        task.macStatus = status
    }

    mutating func associate(_ candidate: LocalShareLegacyCandidate, status: RemoteImportTaskStatus,
                            selectionIDs: Set<UUID>, includeAlbumCatalog: Bool,
                            hostID: String, fingerprint: String, target: String) throws {
        guard task.phase == .idle, status.query == candidate.query(taskID: taskID),
              UUID(uuidString: hostID) == candidate.hostID, selectionIDs == candidate.selectionIDs,
              includeAlbumCatalog == candidate.includeAlbumCatalog,
              status.phase == .browsable, status.sourceID != nil,
              status.itemCount == candidate.receipt.itemCount else {
            throw LocalShareTaskRecoveryError.bindingChanged
        }
        // Build the whole candidate before changing the caller's record.
        var next = self
        try next.begin(selectionIDs: selectionIDs, includeAlbumCatalog: includeAlbumCatalog,
                       hostID: hostID, fingerprint: fingerprint, target: target, intent: .sealReceived)
        try next.bind(sourceInstallID: candidate.sourceInstallID, sourceEpoch: candidate.sourceEpoch)
        try next.bind(migrationID: candidate.receipt.migrationID)
        try next.receive(candidate.receipt)
        try next.observe(status)
        self = next
    }

    func restored() throws -> Self {
        try validate()
        var copy = self
        copy.automaticCleanup = copy.automaticCleanup?.restored()
        if copy.task.phase == .running || copy.task.phase == .pausing {
            copy.task.pause(reason: .processInterrupted)
        }
        return copy
    }

    func validate() throws {
        guard version == 1, selectionIDs.count <= 100_000,
              (sourceInstallID == nil) == (sourceEpoch == nil),
              migrationID == nil || sourceInstallID != nil,
              exportStagingName.map({ $0.hasPrefix(".staging-") && $0.count == 73 && $0.dropFirst(9).allSatisfy { "0123456789abcdef".contains($0) } }) ?? true,
              exportStagingName == nil || migrationID != nil,
              sealedManifestSHA256.map({ $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }) ?? true,
              task.itemCount == selectionIDs.count,
              task.receivedItemCount.map({ 0...task.itemCount ~= $0 }) ?? true else {
            throw LocalShareTaskRecoveryError.invalidRecord
        }
        if task.phase != .idle {
            guard !selectionIDs.isEmpty, UUID(uuidString: hostID) != nil, !fingerprint.isEmpty else {
                throw LocalShareTaskRecoveryError.invalidRecord
            }
        } else if !selectionIDs.isEmpty || migrationID != nil || sourceInstallID != nil {
            throw LocalShareTaskRecoveryError.invalidRecord
        }
    }
}

/// Small atomic application-private record. Missing is distinct from malformed.
struct LocalShareTaskJournal {
    let directory: URL
    private var url: URL { directory.appendingPathComponent("active-task.json") }
    private let maximumBytes = 4 * 1_024 * 1_024

    private func validateDirectory() throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw LocalShareTaskRecoveryError.unavailable
        }
    }

    func load() throws -> LocalShareTaskRecord? {
        try validateDirectory()
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw LocalShareTaskRecoveryError.invalidRecord
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= maximumBytes,
              let bytes = try handle.read(upToCount: maximumBytes + 1), bytes.count <= maximumBytes else {
            throw LocalShareTaskRecoveryError.invalidRecord
        }
        do { return try JSONDecoder().decode(LocalShareTaskRecord.self, from: bytes).restored() }
        catch { throw LocalShareTaskRecoveryError.invalidRecord }
    }

    func save(_ record: LocalShareTaskRecord) throws {
        try validateDirectory()
        try record.validate()
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw LocalShareTaskRecoveryError.invalidRecord }
        } else if errno != ENOENT { throw LocalShareTaskRecoveryError.unavailable }
        let bytes = try JSONEncoder().encode(record)
        guard bytes.count <= maximumBytes else { throw LocalShareTaskRecoveryError.invalidRecord }
        #if os(iOS)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try bytes.write(to: url, options: .atomic)
        #endif
    }
}

struct LocalSharePresentation {
    enum Action { case select, permission, connect, start, pause, resume, retry, macNextStep, none }
    let title: String
    let message: String
    let buttonTitle: String
    let action: Action
    let isEnabled: Bool
    let isError: Bool

    static func resolve(task: LocalShareTask, selectedCount: Int, canReadPhotos: Bool,
        needsFullAccess: Bool, connected: Bool, awaitingConsent: Bool,
        otherWork: Bool, selectionMatches: Bool, targetMatches: Bool = true,
        transferPhase: String = "准备目录与整理信息"
    ) -> Self {
        func state(_ title: String, _ message: String, _ button: String, _ action: Action,
                   enabled: Bool = true, error: Bool = false) -> Self {
            Self(title: title, message: message, buttonTitle: button, action: action,
                 isEnabled: enabled, isError: error)
        }
        if task.phase == .running || task.phase == .pausing {
            let title = task.phase == .pausing ? "正在暂停" : (transferPhase == "传输原件" ? "正在传输" : "正在准备与核对")
            return state(title, "本次 \(task.itemCount) 项 → \(task.target)。请保持 App 在前台。",
                         task.phase == .pausing ? "正在暂停…" : "暂停导入", .pause,
                         enabled: task.phase != .pausing)
        }
        if otherWork { return state("正在处理更多操作", "请等待当前操作结束。", "正在处理…", .none, enabled: false) }
        if task.phase == .received {
            let received = task.receivedItemCount ?? task.itemCount
            if task.macOwnsProcessing == true {
                if connected && targetMatches, let status = task.macStatus, status.phase == .browsable {
                    return state("已导入 Mac · 可浏览", "\(received) 项已加入 Mac 图库。可以拔线，手机原件保留。", "查看 Mac 浏览入口", .macNextStep)
                }
                return state("传输完成 · 可以拔线", "\(received) 项已由 Mac 接管。核验、入库和收尾会在 Mac 独立完成；进度或问题请在 Mac“设备与导入”查看，无需保持手机在线。", "查看 Mac 进度", .macNextStep)
            }
            // A sealed subset is this task's delivered scope. Historical
            // selection differences do not imply an outstanding user intention.
            if !connected || !targetMatches {
                return state("Mac 已接收 · 状态待刷新", "请连接原 Mac 核对入库结果。", "恢复 Mac 连接", .connect)
            }
            if let status = task.macStatus {
                switch status.phase {
                case .browsable:
                    return state("已导入 Mac · 可浏览", "\(received) 项已发布到 Mac 图库。在 Mac 左侧打开“iPhone · 已导入 Mac”。此导入流程不会删除手机原件。", "查看 Mac 浏览入口", .macNextStep)
                case .verifying:
                    return state("Mac 正在验证与入库", "Mac 正在核对接收包、复制并验证独立副本。此阶段是本地读盘，不是重新上传。", "查看 Mac 进度", .macNextStep)
                case .publishing:
                    return state("Mac 正在发布来源", "副本已入库，正在核查归档并加入主图库。", "查看 Mac 进度", .macNextStep)
                case .needsAttention:
                    return state("Mac 导入需要处理", "Mac 尚未确认来源可浏览。请在“设备与导入”查看失败或中断原因，再手动继续；刷新不会重新上传。", "查看 Mac 处理步骤", .macNextStep, error: true)
                case .awaitingImport:
                    return state("Mac 已接收 · 待入库", "本次 \(received) 项已发送到 \(task.target)。请在 Mac“设备与导入”点击“导入照片与信息”。", "查看 Mac 入库步骤", .macNextStep)
                }
            }
            return state("Mac 已接收 · 状态待核对", "本次 \(received) 项已发送到 \(task.target)。正在等待 Mac 的入库与发布结果。", "查看 Mac 入库步骤", .macNextStep)
        }
        if task.phase == .paused || task.phase == .failed {
            let title = task.phase == .paused ? "已暂停" : "导入未完成"
            let reason = task.phase == .paused ? (task.pauseReason?.message ?? "") : ""
            let intent = task.intent == .sealReceived ? "继续时仅封存已接收项目，不重新上传原件。" : ""
            let context = reason + "本次 \(task.itemCount) 项 → \(task.target)。Mac 已落盘进度保留。" + intent
            if !selectionMatches {
                return state(title, context + " 当前选择或选项已变化；请恢复原任务范围后继续。", "恢复原选择与选项", .select, error: task.phase == .failed)
            }
            if !canReadPhotos || needsFullAccess {
                return state(title, context + " 请先恢复照片访问权限。", "处理照片权限", .permission, error: task.phase == .failed)
            }
            if !connected || !targetMatches {
                return state(title, context + " 请先恢复原 Mac 连接，再手动继续。", awaitingConsent ? "核对 Mac 身份" : "恢复 Mac 连接", .connect, error: task.phase == .failed)
            }
            return state(title, context + " 继续会重新核对原范围与旧进度。",
                         task.phase == .paused ? "继续原批次" : "重试原批次",
                         task.phase == .paused ? .resume : .retry, error: task.phase == .failed)
        }
        if selectedCount == 0 { return state("尚未选择内容", "先将照片或视频加入待分享。", "选择照片与视频", .select) }
        if !canReadPhotos || needsFullAccess {
            return state("需要照片权限", needsFullAccess ? "保存相簿目录需要完整权限；也可关闭此选项。" : "已有选择保留，请恢复照片访问。", "处理照片权限", .permission)
        }
        if !connected { return state(awaitingConsent ? "等待身份确认" : "等待连接 Mac", "连接后会一起发送所选原件与整理信息。", awaitingConsent ? "核对 Mac 身份" : "连接目标 Mac", .connect) }
        return state("可以开始导入", "发送 \(selectedCount) 项原件与整理信息，此导入流程不会删除手机原件。", "导入所选照片与信息", .start)
    }
}

/// Exact registrations retained before replacing the visible task. Never scans
/// export folders or adopts historical tasks. Completed task records are kept.
struct LocalShareCleanupQueue {
    let directory: URL
    private var index: URL { directory.appendingPathComponent("pending.json") }
    private func ids() throws -> [UUID] {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            if errno == ENOENT { return [] }
            throw LocalShareTaskRecoveryError.unavailable
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw LocalShareTaskRecoveryError.invalidRecord }
        let fd = Darwin.open(index.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return [] }
            throw LocalShareTaskRecoveryError.invalidRecord
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size < 8192 else {
            throw LocalShareTaskRecoveryError.invalidRecord
        }
        let value = try JSONDecoder().decode([UUID].self, from: handle.readToEnd() ?? Data())
        guard value.count <= 64, Set(value).count == value.count else { throw LocalShareTaskRecoveryError.invalidRecord }
        return value
    }
    private func writeIndex(_ value: [UUID]) throws {
        guard value.count <= 64 else { throw LocalShareTaskRecoveryError.unavailable }
        let data = try JSONEncoder().encode(value)
        #if os(iOS)
        try data.write(to: index, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: index, options: .atomic)
        #endif
    }
    private func journal(_ id: UUID) -> LocalShareTaskJournal {
        .init(directory: directory.appendingPathComponent(id.uuidString.lowercased()))
    }
    func retain(_ record: LocalShareTaskRecord) throws {
        guard record.automaticCleanup != nil, record.statusQuery != nil, record.exportStagingName != nil else { return }
        var registered = try ids()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let taskJournal = journal(record.taskID)
        try FileManager.default.createDirectory(at: taskJournal.directory, withIntermediateDirectories: false)
        if let existing = try taskJournal.load() {
            guard existing.statusQuery == record.statusQuery, existing.exportStagingName == record.exportStagingName,
                  existing.hostID == record.hostID, existing.fingerprint == record.fingerprint else {
                throw LocalShareTaskRecoveryError.bindingChanged
            }
            // A prior successful save must never be regressed by a repeated reset.
            if existing.automaticCleanup?.phase == .complete { return }
        }
        try taskJournal.save(record)
        if record.automaticCleanup?.phase != .complete && !registered.contains(record.taskID) {
            registered.append(record.taskID)
        }
        try writeIndex(registered)
    }
    func contains(_ id: UUID) throws -> Bool { try ids().contains(id) }
    func save(_ record: LocalShareTaskRecord) throws {
        var registered = try ids()
        guard registered.contains(record.taskID), record.statusQuery != nil else { throw LocalShareTaskRecoveryError.invalidRecord }
        try journal(record.taskID).save(record)
        if record.automaticCleanup?.phase == .complete {
            registered.removeAll { $0 == record.taskID }; try writeIndex(registered)
        }
    }
    func next(hostID: String, fingerprint: String, nowMs: Int64) throws -> LocalShareTaskRecord? {
        var registered = try ids()
        for id in registered {
            guard let record = try journal(id).load(), record.taskID == id, let state = record.automaticCleanup else {
                throw LocalShareTaskRecoveryError.invalidRecord
            }
            if state.phase == .complete {
                registered.removeAll { $0 == id }; try writeIndex(registered); continue
            }
            guard record.statusQuery != nil, record.exportStagingName != nil else { throw LocalShareTaskRecoveryError.invalidRecord }
            if record.hostID == hostID, record.fingerprint == fingerprint, state.nextAttemptAtMs <= nowMs { return record }
        }
        return nil
    }
}
