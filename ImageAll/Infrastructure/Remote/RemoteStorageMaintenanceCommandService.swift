import AppKit
import Foundation

struct AppKitRemoteStorageNativeApprovalPresenter: RemoteStorageNativeApprovalPresenting {
    @MainActor
    func confirm(_ approval: RemoteStorageNativeApproval) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = approval.title
        alert.informativeText = approval.detail
        alert.addButton(withTitle: approval.confirmTitle)
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private extension RemoteStorageNativeApproval {
    var title: String {
        switch self {
        case .clearPreviewCache: "清理预览缓存？"
        case .clearPhotosOriginals: "清理长期保留的 Photos 原图副本？"
        }
    }

    var detail: String {
        switch self {
        case .clearPreviewCache:
            "只会删除可重建的网格缩略图和单图预览。原始照片、标签、Feature Print 与个人模型不会被删除。"
        case .clearPhotosOriginals:
            "只会删除 ImageAll 自己长期保留的 Apple Photos 原图副本。Apple Photos 原图、标签和分析结果不会被修改；以后分析时可能需要重新下载。"
        }
    }

    var confirmTitle: String {
        switch self {
        case .clearPreviewCache: "清理预览缓存"
        case .clearPhotosOriginals: "清理原图副本"
        }
    }
}

actor RemoteStorageMaintenanceCommandService: RemoteStorageMaintenanceCommandPort {
    private struct AcceptedOperation: Sendable {
        let command: StorageMaintenanceCommandRequest
        let requestID: UUID
    }

    private let workspace: any RemoteStorageMaintenanceWorkspacePort
    private let approvalPresenter: any RemoteStorageNativeApprovalPresenting
    private let clock: any JobClock
    private var requestsByID: [UUID: StorageMaintenanceCommandRequestSnapshot] = [:]
    private var acceptedOperations: [UUID: AcceptedOperation] = [:]
    private var tasksByID: [UUID: Task<Void, Never>] = [:]

    init(
        workspace: any RemoteStorageMaintenanceWorkspacePort,
        approvalPresenter: any RemoteStorageNativeApprovalPresenting =
            AppKitRemoteStorageNativeApprovalPresenter(),
        clock: any JobClock = SystemJobClock()
    ) {
        self.workspace = workspace
        self.approvalPresenter = approvalPresenter
        self.clock = clock
    }

    func snapshot() throws -> StorageMaintenanceCommandSnapshot {
        let preview = try workspace.fetchPreviewCacheUsage()
        let originals = try workspace.fetchPhotosOriginalStorageUsage()
        let location = workspace.fetchAppStorageLocation()
        return StorageMaintenanceCommandSnapshot(
            previewCache: StorageMaintenanceUsageSummary(
                entryCount: preview.entryCount,
                registeredBytes: Self.signedBytes(preview.registeredBytes)
            ),
            photosOriginals: StorageMaintenanceUsageSummary(
                entryCount: originals.entryCount,
                registeredBytes: originals.registeredBytes
            ),
            appStorage: StorageMaintenanceAppStorageSummary(
                kind: location.usesExternalStorage ? .externalStorage : .internalStorage,
                requiresRestart: location.requiresRestart,
                pendingExternalRootName: location.requiresRestart
                    ? location.preferredExternalRootURL?.lastPathComponent
                    : nil
            ),
            requests: requestsByID.values.sorted { lhs, rhs in
                if lhs.updatedAtMs != rhs.updatedAtMs { return lhs.updatedAtMs > rhs.updatedAtMs }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        )
    }

    func submit(
        _ command: StorageMaintenanceCommandRequest
    ) throws -> StorageMaintenanceCommandRequestSnapshot {
        if let accepted = acceptedOperations[command.operationID] {
            guard accepted.command == command else {
                throw StorageMaintenanceCommandError.operationConflict
            }
            guard let existing = requestsByID[accepted.requestID] else {
                throw StorageMaintenanceCommandError.unavailable
            }
            return existing
        }

        guard !requestsByID.values.contains(where: {
            $0.phase == .awaitingMac || $0.phase == .running
        }) else {
            throw StorageMaintenanceCommandError.invalidAction
        }

        let requestID = UUID()
        let initial = StorageMaintenanceCommandRequestSnapshot(
            id: requestID,
            operationID: command.operationID,
            action: command.action,
            phase: .awaitingMac,
            message: command.action.initialMessage,
            updatedAtMs: clock.nowMs,
            result: nil
        )
        requestsByID[requestID] = initial
        acceptedOperations[command.operationID] = AcceptedOperation(
            command: command,
            requestID: requestID
        )
        tasksByID[requestID] = Task { [weak self] in
            await self?.execute(command, requestID: requestID)
        }
        return initial
    }

    private func execute(
        _ command: StorageMaintenanceCommandRequest,
        requestID: UUID
    ) async {
        do {
            switch command.action {
            case .exportPortableData:
                guard let parentDirectory = await workspace.choosePortableExportDirectory() else {
                    finish(requestID, phase: .cancelled, message: "已在 Mac 上取消导出")
                    return
                }
                markRunning(requestID, message: "正在 Mac 上导出用户数据…")
                let workspace = workspace
                let result = try await Task.detached(priority: .utility) {
                    try workspace.exportPortableUserData(to: parentDirectory)
                }.value
                finish(
                    requestID,
                    phase: .completed,
                    message: "已导出 \(result.totalRecordCount) 条记录到“\(result.bundleURL.lastPathComponent)”",
                    result: StorageMaintenanceCommandResult(
                        bundleName: result.bundleURL.lastPathComponent,
                        totalRecordCount: result.totalRecordCount
                    )
                )
            case .chooseExternalStorage:
                switch try await workspace.chooseExternalAppStorageLocation() {
                case .cancelled:
                    finish(requestID, phase: .cancelled, message: "已在 Mac 上取消选择外置存储")
                case let .restartRequired(status):
                    let name = status.preferredExternalRootURL?.lastPathComponent
                    finish(
                        requestID,
                        phase: .completed,
                        message: name.map { "已选择“\($0)”，重启 ImageAll 后开始使用" }
                            ?? "已选择外置存储，重启 ImageAll 后开始使用",
                        result: StorageMaintenanceCommandResult(requiresRestart: true)
                    )
                }
            case .clearPreviewCache:
                guard await approvalPresenter.confirm(.clearPreviewCache) else {
                    finish(requestID, phase: .cancelled, message: "已在 Mac 上取消清理预览缓存")
                    return
                }
                markRunning(requestID, message: "正在清理可重建的预览缓存…")
                let result = try await workspace.clearPreviewCache()
                finish(
                    requestID,
                    phase: .completed,
                    message: "已清理 \(result.removedEntries) 条预览记录，释放 \(Self.byteText(result.removedBytes))",
                    result: StorageMaintenanceCommandResult(
                        affectedEntryCount: result.removedEntries,
                        affectedBytes: Self.signedBytes(result.removedBytes),
                        partialReclaim: result.partialReclaim
                    )
                )
            case .clearPhotosOriginals:
                guard await approvalPresenter.confirm(.clearPhotosOriginals) else {
                    finish(requestID, phase: .cancelled, message: "已在 Mac 上取消清理原图副本")
                    return
                }
                markRunning(requestID, message: "正在清理 ImageAll 长期保留的 Photos 原图副本…")
                let workspace = workspace
                let result = try await Task.detached(priority: .utility) {
                    try workspace.clearPhotosOriginalStorage()
                }.value
                finish(
                    requestID,
                    phase: .completed,
                    message: "已清理 \(result.removedEntries) 条原图副本，释放 \(Self.byteText(result.removedBytes))",
                    result: StorageMaintenanceCommandResult(
                        affectedEntryCount: result.removedEntries,
                        affectedBytes: result.removedBytes,
                        partialReclaim: result.partialReclaim
                    )
                )
            }
        } catch ProductionLibraryWorkspaceError.librarySlimmingAnalysisInProgress {
            finish(requestID, phase: .failed, message: "图库瘦身分析正在使用原图副本，请等待分析结束后再清理")
        } catch let error as PortableCatalogExportError {
            finish(requestID, phase: .failed, message: Self.exportFailureMessage(error))
        } catch AppStorageLocationError.cancelled {
            finish(requestID, phase: .cancelled, message: "已在 Mac 上取消选择外置存储")
        } catch let error as AppStorageLocationError {
            finish(requestID, phase: .failed, message: Self.storageFailureMessage(error))
        } catch {
            finish(requestID, phase: .failed, message: "Mac 未能完成该存储操作")
        }
    }

    private func markRunning(_ requestID: UUID, message: String) {
        finish(requestID, phase: .running, message: message, clearTask: false)
    }

    private func finish(
        _ requestID: UUID,
        phase: StorageMaintenanceCommandPhase,
        message: String,
        result: StorageMaintenanceCommandResult? = nil,
        clearTask: Bool = true
    ) {
        guard let current = requestsByID[requestID] else { return }
        requestsByID[requestID] = StorageMaintenanceCommandRequestSnapshot(
            id: current.id,
            operationID: current.operationID,
            action: current.action,
            phase: phase,
            message: message,
            updatedAtMs: clock.nowMs,
            result: result
        )
        if clearTask { tasksByID[requestID] = nil }
        pruneFinishedRequests()
    }

    private func pruneFinishedRequests() {
        let orderedFinished = requestsByID.values
            .filter { [.completed, .cancelled, .failed].contains($0.phase) }
            .sorted { $0.updatedAtMs > $1.updatedAtMs }
        for request in orderedFinished.dropFirst(16) {
            requestsByID[request.id] = nil
            acceptedOperations[request.operationID] = nil
        }
    }

    private static func signedBytes(_ bytes: UInt64) -> Int64 {
        Int64(clamping: bytes)
    }

    private static func byteText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: signedBytes(bytes), countStyle: .file)
    }

    private static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private static func exportFailureMessage(_ error: PortableCatalogExportError) -> String {
        switch error {
        case .destinationCollision: "导出位置已有同名目录，请重新选择"
        case .destinationOverlapsSource: "导出位置不能位于已连接的图库来源内"
        case .destinationIsolationIndeterminate: "无法确认导出位置与图库来源相互隔离"
        case .invalidRequest: "导出请求无效"
        case .databaseReadFailed: "读取目录库失败，未导出数据"
        case .writeFailed: "写入导出文件失败"
        case .validationFailed: "导出校验失败，未发布不完整结果"
        case .publicationFailed: "导出已生成但无法发布到所选位置"
        }
    }

    private static func storageFailureMessage(_ error: AppStorageLocationError) -> String {
        switch error {
        case .cancelled: "已在 Mac 上取消选择外置存储"
        case .invalidRoot: "所选目录不能作为 ImageAll 外置存储"
        case .authorizationUnavailable, .staleBookmark: "无法持续访问所选外置目录，请重新选择"
        case .directoryCreationFailed: "无法在所选位置创建 ImageAll 存储目录"
        case .bookmarkCreationFailed: "无法保存所选外置目录的访问权限"
        case .migrationFailed: "迁移应用资料失败，原存储仍保持可用"
        case .conflictingDestination: "所选位置已有冲突的 ImageAll 数据"
        }
    }
}

private extension StorageMaintenanceCommandAction {
    var initialMessage: String {
        switch self {
        case .exportPortableData: "请回到 Mac 选择用户数据导出位置"
        case .chooseExternalStorage: "请回到 Mac 选择外置应用存储位置"
        case .clearPreviewCache, .clearPhotosOriginals: "请回到 Mac 确认清理操作"
        }
    }
}
