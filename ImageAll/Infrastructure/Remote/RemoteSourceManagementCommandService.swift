import AppKit
import Foundation

struct AppKitRemoteSourceNativeApprovalPresenter: RemoteSourceNativeApprovalPresenting {
    @MainActor
    func confirm(_ approval: RemoteSourceNativeApproval) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = approval.isDestructive ? .warning : .informational
        alert.messageText = approval.title
        alert.informativeText = approval.detail
        alert.addButton(withTitle: approval.confirmTitle)
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private extension RemoteSourceNativeApproval {
    var isDestructive: Bool {
        if case .delete = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .connectPhotos: "连接 Apple Photos？"
        case let .rebindPhotos(sourceName): "从“\(sourceName)”连接当前系统照片图库？"
        case let .fullRepair(sourceName): "对“\(sourceName)”执行完整修复扫描？"
        case let .requestPhotosWriteAuthorization(sourceName):
            "为“\(sourceName)”请求照片写入权限？"
        case let .delete(sourceName): "从 ImageAll 删除“\(sourceName)”？"
        }
    }

    var detail: String {
        switch self {
        case .connectPhotos:
            "ImageAll 平时只读访问照片和元数据。继续后 macOS 会请求照片访问权限；普通浏览不会修改 Apple Photos 原图。"
        case .rebindPhotos:
            "旧图库索引、人工标签和历史会保留；当前系统图库会成为新的独立来源，不会迁移或合并无法确认身份的照片。"
        case .fullRepair:
            "这会重新扫描整个 Apple Photos 图库并在后台修复缺失状态。扫描期间仍可浏览已有索引。"
        case .requestPhotosWriteAuthorization:
            "仅在移入回收站提示权限不足时使用。继续后 macOS 会请求照片库读写授权；本操作本身不会移动、修改或删除照片。"
        case .delete:
            "来源、照片索引、相关标签/审核/分析明细及 App 缓存会从 ImageAll 中删除且无法撤销；磁盘原文件或 Apple Photos 原图不会被修改或删除。"
        }
    }

    var confirmTitle: String {
        switch self {
        case .connectPhotos: "继续并请求照片权限"
        case .rebindPhotos: "保留历史并连接"
        case .fullRepair: "开始完整修复扫描"
        case .requestPhotosWriteAuthorization: "继续并请求写入权限"
        case .delete: "删除来源"
        }
    }
}

actor RemoteSourceManagementCommandService: RemoteSourceManagementCommandPort {
    private struct AcceptedOperation: Sendable {
        let command: SourceManagementCommandRequest
        let requestID: UUID
    }

    private let workspace: any RemoteSourceManagementWorkspacePort
    private let mutationAuthorization: (any FolderMutationAuthorizationPort)?
    private let photosMutation: (any PhotosLibraryMutationPort)?
    private let workspaceNoticeRecorder: (any RemoteWorkspaceNoticeRecording)?
    private let approvalPresenter: any RemoteSourceNativeApprovalPresenting
    private let clock: any JobClock
    private var requestsByID: [UUID: SourceManagementCommandRequestSnapshot] = [:]
    private var acceptedOperations: [UUID: AcceptedOperation] = [:]
    private var tasksByID: [UUID: Task<Void, Never>] = [:]

    init(
        workspace: any RemoteSourceManagementWorkspacePort,
        mutationAuthorization: (any FolderMutationAuthorizationPort)? = nil,
        photosMutation: (any PhotosLibraryMutationPort)? = nil,
        workspaceNoticeRecorder: (any RemoteWorkspaceNoticeRecording)? = nil,
        approvalPresenter: any RemoteSourceNativeApprovalPresenting =
            AppKitRemoteSourceNativeApprovalPresenter(),
        clock: any JobClock = SystemJobClock()
    ) {
        self.workspace = workspace
        self.mutationAuthorization = mutationAuthorization
        self.photosMutation = photosMutation
        self.workspaceNoticeRecorder = workspaceNoticeRecorder
        self.approvalPresenter = approvalPresenter
        self.clock = clock
    }

    func snapshot() throws -> SourceManagementCommandSnapshot {
        SourceManagementCommandSnapshot(
            sources: try workspace.fetchSources(),
            requests: requestsByID.values.sorted { lhs, rhs in
                if lhs.updatedAtMs != rhs.updatedAtMs { return lhs.updatedAtMs > rhs.updatedAtMs }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        )
    }

    func submit(
        _ command: SourceManagementCommandRequest
    ) throws -> SourceManagementCommandRequestSnapshot {
        if let accepted = acceptedOperations[command.operationID] {
            guard accepted.command == command else {
                throw SourceManagementCommandError.operationConflict
            }
            guard let existing = requestsByID[accepted.requestID] else {
                throw SourceManagementCommandError.unavailable
            }
            return existing
        }

        if command.action == .cancelPrewarm {
            return try cancelActivePrewarm(command)
        }

        guard !requestsByID.values.contains(where: {
            $0.phase == .awaitingMac || $0.phase == .running
        }) else {
            throw SourceManagementCommandError.invalidAction
        }

        let sources = try workspace.fetchSources()
        let source = try validate(command, sources: sources)
        let requestID = UUID()
        let sourceDisplayName = switch command.action {
        case .refreshAll,
             .prewarmAllThumbnails,
             .prewarmAllOriginalAspect,
             .reauthorizeAll,
             .refreshAllFolderMutationAuthorizations:
            "全部来源"
        default:
            source?.displayName
        }
        let initial = SourceManagementCommandRequestSnapshot(
            id: requestID,
            operationID: command.operationID,
            action: command.action,
            sourceID: source?.id,
            sourceDisplayName: sourceDisplayName,
            phase: command.action.requiresMacInteraction ? .awaitingMac : .running,
            message: command.action.initialMessage,
            updatedAtMs: clock.nowMs
        )
        requestsByID[requestID] = initial
        acceptedOperations[command.operationID] = AcceptedOperation(
            command: command,
            requestID: requestID
        )
        tasksByID[requestID] = Task { [weak self] in
            await self?.execute(command, requestID: requestID, source: source)
        }
        return initial
    }

    private func cancelActivePrewarm(
        _ command: SourceManagementCommandRequest
    ) throws -> SourceManagementCommandRequestSnapshot {
        if let sourceID = command.sourceID,
           try !workspace.fetchSources().contains(where: { $0.id == sourceID })
        {
            throw SourceManagementCommandError.sourceNotFound
        }
        guard let active = requestsByID.values.first(where: {
            $0.sourceID == command.sourceID
                && $0.action.isPrewarm
                && [.awaitingMac, .running].contains($0.phase)
        }) else { throw SourceManagementCommandError.invalidAction }

        acceptedOperations[command.operationID] = AcceptedOperation(
            command: command,
            requestID: active.id
        )
        tasksByID[active.id]?.cancel()
        let message: String
        if active.action.isAllSourcePrewarm {
            message = "已取消全部来源缓存任务；已完成 \(active.completedSourceCount ?? 0)/\(active.totalSourceCount ?? 0) 个来源，已生成的缓存仍会保留"
        } else {
            message = "已取消“\(active.sourceDisplayName ?? "来源")”的缩略图预热；已生成的缓存仍会保留"
        }
        finish(
            active.id,
            phase: .cancelled,
            message: message
        )
        return requestsByID[active.id] ?? active
    }

    private func validate(
        _ command: SourceManagementCommandRequest,
        sources: [LibrarySourceSummary]
    ) throws -> LibrarySourceSummary? {
        switch command.action {
        case .connectFolder:
            guard command.sourceID == nil else { throw SourceManagementCommandError.invalidAction }
            return nil
        case .connectPhotos:
            guard command.sourceID == nil,
                  !sources.contains(where: { $0.kind == .photos })
            else { throw SourceManagementCommandError.invalidAction }
            return nil
        case .refreshAll:
            guard command.sourceID == nil,
                  sources.contains(where: { $0.state == .active })
            else { throw SourceManagementCommandError.invalidAction }
            return nil
        case .prewarmAllThumbnails, .prewarmAllOriginalAspect:
            guard command.sourceID == nil,
                  sources.contains(where: {
                      $0.state == .active || $0.state == .unavailable
                  })
            else { throw SourceManagementCommandError.invalidAction }
            return nil
        case .reauthorizeAll:
            guard command.sourceID == nil,
                  sources.contains(where: Self.requiresAccessAuthorization)
            else { throw SourceManagementCommandError.invalidAction }
            return nil
        case .refreshAllFolderMutationAuthorizations:
            guard command.sourceID == nil,
                  sources.contains(where: {
                      $0.kind == .folder && $0.state == .active
                  })
            else { throw SourceManagementCommandError.invalidAction }
            return nil
        case .rebindPhotos,
             .reauthorize,
             .rescan,
             .syncPhotos,
             .fullRepair,
             .openPhotosPrivacySettings,
             .requestPhotosWriteAuthorization,
             .refreshFolderMutationAuthorization,
             .prewarmThumbnails,
             .prewarmOriginalAspect,
             .cancelPrewarm,
             .delete:
            guard let sourceID = command.sourceID,
                  let source = sources.first(where: { $0.id == sourceID })
            else { throw SourceManagementCommandError.sourceNotFound }
            let valid = switch command.action {
            case .rebindPhotos:
                source.kind == .photos && source.state == .unavailable
            case .reauthorize:
                source.state == .authorizationRequired
                    || (source.kind == .photos && source.state == .disabled)
                    || (source.kind == .folder && source.state == .unavailable)
            case .rescan:
                source.kind == .folder && source.state == .active
            case .syncPhotos, .fullRepair:
                source.kind == .photos && source.state == .active
            case .openPhotosPrivacySettings:
                source.kind == .photos
            case .requestPhotosWriteAuthorization:
                source.kind == .photos && source.state == .active
            case .refreshFolderMutationAuthorization:
                source.kind == .folder && source.state == .active
            case .prewarmThumbnails, .prewarmOriginalAspect:
                source.state == .active || source.state == .unavailable
            case .cancelPrewarm:
                false
            case .delete:
                true
            case .connectFolder, .connectPhotos:
                false
            case .refreshAll:
                false
            case .prewarmAllThumbnails,
                 .prewarmAllOriginalAspect,
                 .reauthorizeAll,
                 .refreshAllFolderMutationAuthorizations:
                false
            }
            guard valid else { throw SourceManagementCommandError.invalidAction }
            return source
        }
    }

    private func execute(
        _ command: SourceManagementCommandRequest,
        requestID: UUID,
        source: LibrarySourceSummary?
    ) async {
        do {
            switch command.action {
            case .connectFolder:
                switch try await workspace.connectFolder() {
                case .cancelled:
                    finish(requestID, phase: .cancelled, message: "已在 Mac 上取消选择文件夹")
                    return
                case let .connected(sourceID):
                    startFolderRunner(sourceIDs: [sourceID])
                }
            case .connectPhotos:
                guard await approvalPresenter.confirm(.connectPhotos) else {
                    finish(requestID, phase: .cancelled, message: "已在 Mac 上取消连接 Apple Photos")
                    return
                }
                markRunning(requestID, message: "正在等待 macOS 照片权限并连接图库…")
                let outcome = try await workspace.connectPhotos()
                let sourceID = switch outcome {
                case let .connected(sourceID), let .alreadyConnected(sourceID): sourceID
                }
                startPhotosRunner(sourceIDs: [sourceID])
            case .refreshAll:
                let activeSources = try workspace.fetchSources().filter { $0.state == .active }
                guard !activeSources.isEmpty else {
                    throw SourceManagementCommandError.invalidAction
                }
                let folderSourceIDs = Set(
                    activeSources.lazy.filter { $0.kind == .folder }.map(\.id)
                )
                let photosSourceIDs = Set(
                    activeSources.lazy.filter { $0.kind == .photos }.map(\.id)
                )
                if !folderSourceIDs.isEmpty {
                    try workspace.enqueueReconcile(sourceIDs: Array(folderSourceIDs))
                    startFolderRunner(sourceIDs: folderSourceIDs)
                }
                for sourceID in photosSourceIDs {
                    try await workspace.syncPhotosLibrary(sourceID: sourceID)
                }
                if !photosSourceIDs.isEmpty {
                    startPhotosRunner(sourceIDs: photosSourceIDs)
                }
                finish(
                    requestID,
                    phase: .completed,
                    message: "已为 \(activeSources.count) 个活跃来源排入更新任务"
                )
                return
            case .prewarmAllThumbnails, .prewarmAllOriginalAspect:
                await runAllSourcePrewarm(
                    requestID: requestID,
                    originalAspect: command.action == .prewarmAllOriginalAspect
                )
                return
            case .reauthorizeAll:
                await runAllSourceReauthorization(requestID: requestID)
                return
            case .refreshAllFolderMutationAuthorizations:
                await runAllFolderMutationAuthorization(requestID: requestID)
                return
            case .rebindPhotos:
                guard let source,
                      await approvalPresenter.confirm(.rebindPhotos(sourceName: source.displayName))
                else {
                    finish(requestID, phase: .cancelled, message: "已在 Mac 上取消连接当前系统图库")
                    return
                }
                markRunning(requestID, message: "正在连接当前系统照片图库…")
                let outcome = try await workspace.rebindPhotos(unavailableSourceID: source.id)
                switch outcome {
                case let .rebound(_, sourceID): startPhotosRunner(sourceIDs: [sourceID])
                }
            case .reauthorize:
                guard let source else { throw SourceManagementCommandError.sourceNotFound }
                if source.kind == .photos {
                    try await workspace.reactivatePhotosLibrary(sourceID: source.id)
                    startPhotosRunner(sourceIDs: [source.id])
                } else {
                    switch try await workspace.reauthorizeFolder(sourceID: source.id) {
                    case .cancelled:
                        finish(requestID, phase: .cancelled, message: "已在 Mac 上取消重新选择文件夹")
                        return
                    case .reauthorized:
                        startFolderRunner(sourceIDs: [source.id])
                    }
                }
            case .rescan:
                guard let source else { throw SourceManagementCommandError.sourceNotFound }
                try workspace.enqueueReconcile(sourceIDs: [source.id])
                startFolderRunner(sourceIDs: [source.id])
            case .syncPhotos:
                guard let source else { throw SourceManagementCommandError.sourceNotFound }
                try await workspace.syncPhotosLibrary(sourceID: source.id)
                startPhotosRunner(sourceIDs: [source.id])
            case .fullRepair:
                guard let source,
                      await approvalPresenter.confirm(.fullRepair(sourceName: source.displayName))
                else {
                    finish(requestID, phase: .cancelled, message: "已在 Mac 上取消完整修复扫描")
                    return
                }
                markRunning(requestID, message: "正在排入 Apple Photos 完整修复扫描…")
                try await workspace.requestPhotosFullRepair(sourceID: source.id)
                startPhotosRunner(sourceIDs: [source.id])
            case .openPhotosPrivacySettings:
                guard await workspace.openPhotosPrivacySettings() else {
                    throw SourceManagementCommandError.unavailable
                }
                finish(
                    requestID,
                    phase: .completed,
                    message: "已在 Mac 上打开照片权限设置"
                )
                return
            case .requestPhotosWriteAuthorization:
                guard let source,
                      await approvalPresenter.confirm(
                          .requestPhotosWriteAuthorization(sourceName: source.displayName)
                      )
                else {
                    finish(requestID, phase: .cancelled, message: "已在 Mac 上取消请求照片写入权限")
                    return
                }
                guard let photosMutation else { throw SourceManagementCommandError.unavailable }
                markRunning(requestID, message: "正在等待 macOS 照片库读写授权…")
                switch await photosMutation.requestAuthorization() {
                case .authorized:
                    finish(
                        requestID,
                        phase: .completed,
                        message: "已获得“\(source.displayName)”的照片库写入权限，可以重新执行移入回收站"
                    )
                case .denied, .restricted:
                    finish(
                        requestID,
                        phase: .failed,
                        message: "未获得照片库写入权限，请在系统设置中允许 ImageAll 访问照片库后重试"
                    )
                case .notDetermined:
                    finish(requestID, phase: .failed, message: "尚未完成照片库写入授权，请重试")
                }
                return
            case .refreshFolderMutationAuthorization:
                guard let source else { throw SourceManagementCommandError.sourceNotFound }
                guard let mutationAuthorization else {
                    throw SourceManagementCommandError.unavailable
                }
                markRunning(requestID, message: "请在 Mac 系统窗口中选择原文件夹以更新回收权限…")
                switch try await mutationAuthorization.authorizeMutation(sourceID: source.id) {
                case .authorized:
                    finish(
                        requestID,
                        phase: .completed,
                        message: "已更新“\(source.displayName)”的回收权限，可以重新执行删除或恢复"
                    )
                case .cancelled:
                    finish(requestID, phase: .cancelled, message: "已在 Mac 上取消更新回收权限")
                }
                return
            case .prewarmThumbnails, .prewarmOriginalAspect:
                guard let source else { throw SourceManagementCommandError.sourceNotFound }
                await runSourcePrewarm(
                    requestID: requestID,
                    source: source,
                    originalAspect: command.action == .prewarmOriginalAspect
                )
                return
            case .cancelPrewarm:
                throw SourceManagementCommandError.invalidAction
            case .delete:
                guard let source,
                      await approvalPresenter.confirm(.delete(sourceName: source.displayName))
                else {
                    finish(requestID, phase: .cancelled, message: "已在 Mac 上取消删除来源")
                    return
                }
                markRunning(requestID, message: "正在删除 ImageAll 中的来源记录和缓存…")
                let outcome = try await workspace.deleteLibrarySource(sourceID: source.id)
                finish(
                    requestID,
                    phase: .completed,
                    message: "已删除来源记录及 \(outcome.deletedAssetCount) 个资产索引；原始媒体未修改"
                )
                return
            }
            finish(requestID, phase: .completed, message: command.action.completedMessage)
        } catch is CancellationError {
            finishIfActive(
                requestID,
                phase: .cancelled,
                message: "已取消“\(source?.displayName ?? "来源")”的缩略图预热"
            )
        } catch PhotosLibraryError.authorizationDenied,
                PhotosLibraryError.authorizationRestricted
        {
            finish(
                requestID,
                phase: .failed,
                message: "未获得 Apple Photos 权限，请在系统设置中允许 ImageAll 访问照片后重试"
            )
        } catch let error as DeleteLibrarySourceError {
            if case let .unresolvedRecycleEntries(blockers) = error,
               let source
            {
                await workspaceNoticeRecorder?.recordSourceDeletionBlocked(
                    sourceID: source.id,
                    displayName: source.displayName,
                    blockers: blockers
                )
            }
            let message = switch error {
            case let .unresolvedRecycleEntries(blockers):
                "来源仍有 \(blockers.totalCount) 条回收记录需要先在 Mac 端处理"
            case .sourceNotFound: "来源已不存在"
            case .cacheCleanupFailed: "App 缓存清理失败，来源未完整删除"
            case .persistenceFailure: "来源删除事务失败"
            }
            finish(requestID, phase: .failed, message: message)
        } catch {
            finish(requestID, phase: .failed, message: "Mac 未能完成该来源操作")
        }
    }

    private func markRunning(_ requestID: UUID, message: String) {
        finish(requestID, phase: .running, message: message, clearTask: false)
    }

    private static func requiresAccessAuthorization(_ source: LibrarySourceSummary) -> Bool {
        switch source.kind {
        case .folder:
            source.state == .unavailable || source.state == .authorizationRequired
        case .photos:
            source.state == .authorizationRequired || source.state == .disabled
        }
    }

    private func runAllSourceReauthorization(requestID: UUID) async {
        let targets: [LibrarySourceSummary]
        do {
            targets = try workspace.fetchSources().filter(Self.requiresAccessAuthorization)
        } catch {
            finish(requestID, phase: .failed, message: "无法读取需要重新授权的来源")
            return
        }
        guard !targets.isEmpty else {
            finish(requestID, phase: .failed, message: "当前没有需要重新授权的来源")
            return
        }

        for (index, source) in targets.enumerated() {
            updateBatchAuthorizationProgress(
                requestID,
                source: source,
                completedSourceCount: index,
                totalSourceCount: targets.count,
                message: "请在 Mac 上重新授权“\(source.displayName)”（来源 \(index + 1)/\(targets.count)）"
            )
            do {
                switch source.kind {
                case .folder:
                    switch try await workspace.reauthorizeFolder(sourceID: source.id) {
                    case .cancelled:
                        finish(
                            requestID,
                            phase: .cancelled,
                            message: "已停止批量访问授权；完成 \(index)/\(targets.count) 个来源，之前完成的授权仍然有效"
                        )
                        return
                    case .reauthorized:
                        startFolderRunner(sourceIDs: [source.id])
                    }
                case .photos:
                    try await workspace.reactivatePhotosLibrary(sourceID: source.id)
                    startPhotosRunner(sourceIDs: [source.id])
                }
            } catch {
                finish(
                    requestID,
                    phase: .failed,
                    message: "“\(source.displayName)”授权失败；已完成 \(index)/\(targets.count) 个来源"
                )
                return
            }
        }

        updateBatchAuthorizationProgress(
            requestID,
            source: targets[targets.count - 1],
            completedSourceCount: targets.count,
            totalSourceCount: targets.count,
            message: "正在完成全部来源访问授权…"
        )
        finish(
            requestID,
            phase: .completed,
            message: "已依次完成 \(targets.count) 个来源的访问授权"
        )
    }

    private func runAllFolderMutationAuthorization(requestID: UUID) async {
        guard let mutationAuthorization else {
            finish(requestID, phase: .failed, message: "当前无法更新文件夹回收权限")
            return
        }
        let targets: [LibrarySourceSummary]
        do {
            targets = try workspace.fetchSources().filter {
                $0.kind == .folder && $0.state == .active
            }
        } catch {
            finish(requestID, phase: .failed, message: "无法读取需要更新回收权限的文件夹来源")
            return
        }
        guard !targets.isEmpty else {
            finish(requestID, phase: .failed, message: "当前没有可更新回收权限的文件夹来源")
            return
        }

        for (index, source) in targets.enumerated() {
            updateBatchAuthorizationProgress(
                requestID,
                source: source,
                completedSourceCount: index,
                totalSourceCount: targets.count,
                message: "请在 Mac 上选择“\(source.displayName)”原文件夹以更新回收权限（来源 \(index + 1)/\(targets.count)）"
            )
            do {
                switch try await mutationAuthorization.authorizeMutation(sourceID: source.id) {
                case .authorized:
                    break
                case .cancelled:
                    finish(
                        requestID,
                        phase: .cancelled,
                        message: "已停止批量回收权限更新；完成 \(index)/\(targets.count) 个来源，没有立即修改任何照片"
                    )
                    return
                }
            } catch {
                finish(
                    requestID,
                    phase: .failed,
                    message: "“\(source.displayName)”回收权限更新失败；已完成 \(index)/\(targets.count) 个来源"
                )
                return
            }
        }

        updateBatchAuthorizationProgress(
            requestID,
            source: targets[targets.count - 1],
            completedSourceCount: targets.count,
            totalSourceCount: targets.count,
            message: "正在完成全部文件夹回收权限更新…"
        )
        finish(
            requestID,
            phase: .completed,
            message: "已依次更新 \(targets.count) 个文件夹来源的回收权限；没有立即修改任何照片"
        )
    }

    private func updateBatchAuthorizationProgress(
        _ requestID: UUID,
        source: LibrarySourceSummary,
        completedSourceCount: Int,
        totalSourceCount: Int,
        message: String
    ) {
        guard let current = requestsByID[requestID],
              [.awaitingMac, .running].contains(current.phase)
        else { return }
        requestsByID[requestID] = SourceManagementCommandRequestSnapshot(
            id: current.id,
            operationID: current.operationID,
            action: current.action,
            sourceID: nil,
            sourceDisplayName: source.displayName,
            phase: .awaitingMac,
            message: message,
            completedSourceCount: completedSourceCount,
            totalSourceCount: totalSourceCount,
            updatedAtMs: clock.nowMs
        )
    }

    private struct SourcePrewarmResult {
        let total: Int
        let warmed: Int
        let reused: Int
        let ineligible: Int
        let failed: Int
    }

    private func runSourcePrewarm(
        requestID: UUID,
        source: LibrarySourceSummary,
        originalAspect: Bool
    ) async {
        guard let result = await warmSource(
            requestID: requestID,
            source: source,
            originalAspect: originalAspect,
            completedSourceCount: nil,
            totalSourceCount: nil
        ) else {
            if Task.isCancelled {
                finishIfActive(
                    requestID,
                    phase: .cancelled,
                    message: "已取消“\(source.displayName)”的缩略图预热"
                )
            } else {
                finish(
                    requestID,
                    phase: .failed,
                    message: "无法读取“\(source.displayName)”的资产清单"
                )
            }
            return
        }
        let kindName = originalAspect ? "原比例缓存" : "网格缩略图"
        finish(
            requestID,
            phase: .completed,
            message: "已完成“\(source.displayName)”的\(kindName)：生成 \(result.warmed)，复用 \(result.reused)，不可处理跳过 \(result.ineligible)，失败 \(result.failed)，共 \(result.total) 项"
        )
    }

    private func runAllSourcePrewarm(
        requestID: UUID,
        originalAspect: Bool
    ) async {
        let sources: [LibrarySourceSummary]
        do {
            sources = try workspace.fetchSources().filter {
                $0.state == .active || $0.state == .unavailable
            }
        } catch {
            finish(requestID, phase: .failed, message: "无法读取全部来源")
            return
        }
        guard !sources.isEmpty else {
            finish(requestID, phase: .failed, message: "没有可预热的来源")
            return
        }

        var totalAssets = 0
        var totalWarmed = 0
        var totalReused = 0
        var totalIneligible = 0
        var totalFailed = 0
        var failedSourceCount = 0
        for (index, source) in sources.enumerated() {
            guard !Task.isCancelled else {
                finishIfActive(
                    requestID,
                    phase: .cancelled,
                    message: "已取消全部来源缩略图预热（完成 \(index)/\(sources.count) 个来源）"
                )
                return
            }
            guard let result = await warmSource(
                requestID: requestID,
                source: source,
                originalAspect: originalAspect,
                completedSourceCount: index,
                totalSourceCount: sources.count
            ) else {
                guard !Task.isCancelled else {
                    finishIfActive(
                        requestID,
                        phase: .cancelled,
                        message: "已取消全部来源缩略图预热（完成 \(index)/\(sources.count) 个来源）"
                    )
                    return
                }
                failedSourceCount += 1
                continue
            }
            totalAssets += result.total
            totalWarmed += result.warmed
            totalReused += result.reused
            totalIneligible += result.ineligible
            totalFailed += result.failed
            updatePrewarmProgress(
                requestID,
                completed: result.total,
                total: result.total,
                warmed: result.warmed,
                reused: result.reused,
                ineligible: result.ineligible,
                failed: result.failed,
                completedSourceCount: index + 1,
                totalSourceCount: sources.count,
                message: "已完成“\(source.displayName)”（来源 \(index + 1)/\(sources.count)）"
            )
        }

        let kindName = originalAspect ? "原比例缓存" : "网格缩略图"
        updatePrewarmProgress(
            requestID,
            completed: totalAssets,
            total: totalAssets,
            warmed: totalWarmed,
            reused: totalReused,
            ineligible: totalIneligible,
            failed: totalFailed,
            completedSourceCount: sources.count,
            totalSourceCount: sources.count,
            message: "正在完成全部来源\(kindName)…"
        )
        finish(
            requestID,
            phase: .completed,
            message: "已完成 \(sources.count) 个来源的\(kindName)：共 \(totalAssets) 项，生成 \(totalWarmed)，复用 \(totalReused)，不可处理跳过 \(totalIneligible)，失败 \(totalFailed)，来源失败 \(failedSourceCount)"
        )
    }

    private func warmSource(
        requestID: UUID,
        source: LibrarySourceSummary,
        originalAspect: Bool,
        completedSourceCount: Int?,
        totalSourceCount: Int?
    ) async -> SourcePrewarmResult? {
        let kindName = originalAspect ? "原比例缓存" : "网格缩略图"
        let sourcePosition = completedSourceCount.flatMap { completed in
            totalSourceCount.map { "（来源 \(completed + 1)/\($0)）" }
        } ?? ""
        updatePrewarmProgress(
            requestID,
            completed: 0,
            total: 0,
            warmed: 0,
            reused: 0,
            ineligible: 0,
            failed: 0,
            completedSourceCount: completedSourceCount,
            totalSourceCount: totalSourceCount,
            sourceDisplayName: source.displayName,
            message: "正在统计“\(source.displayName)”需要预热的项目…\(sourcePosition)"
        )

        var assets: [AssetGridItemProjection] = []
        var seenAssetIDs = Set<UUID>()
        var cursor: AssetPageCursor?
        var pageCount = 0
        repeat {
            guard !Task.isCancelled else { return nil }
            pageCount += 1
            guard pageCount <= 100_000 else { break }
            do {
                let page = try workspace.fetchAssetPage(
                    filter: AssetPageFilter(sourceIDs: [source.id], searchText: ""),
                    sort: .newest,
                    cursor: cursor
                )
                guard !page.items.isEmpty else { break }
                for item in page.items where seenAssetIDs.insert(item.assetID).inserted {
                    assets.append(item)
                }
                let next = page.nextCursor
                guard next != cursor else { break }
                cursor = next
            } catch {
                return nil
            }
        } while cursor != nil

        var cachedAssetIDs = Set<UUID>()
        if originalAspect {
            do {
                cachedAssetIDs = try await workspace.cachedOriginalAspectThumbnailAssetIDs(
                    sourceID: source.id
                )
            } catch {
                for asset in assets {
                    guard !Task.isCancelled else { return nil }
                    do {
                        if try await workspace.loadOriginalAspectThumbnailIfCached(
                            assetID: asset.assetID
                        ) != nil {
                            cachedAssetIDs.insert(asset.assetID)
                        }
                    } catch is CancellationError {
                        return nil
                    } catch {}
                }
            }
        } else {
            cachedAssetIDs = (try? await workspace.cachedSquareThumbnailAssetIDs(
                sourceID: source.id
            )) ?? []
        }

        let listedAssetIDs = Set(assets.map(\.assetID))
        cachedAssetIDs.formIntersection(listedAssetIDs)
        let assetsToWarm = assets.filter {
            !cachedAssetIDs.contains($0.assetID) && Self.canGenerateThumbnail(for: $0)
        }
        let reused = cachedAssetIDs.count
        let ineligible = max(0, assets.count - reused - assetsToWarm.count)
        let assetIDsToWarm = assetsToWarm.map(\.assetID)

        updatePrewarmProgress(
            requestID,
            completed: 0,
            total: assetIDsToWarm.count,
            warmed: 0,
            reused: reused,
            ineligible: ineligible,
            failed: 0,
            completedSourceCount: completedSourceCount,
            totalSourceCount: totalSourceCount,
            sourceDisplayName: source.displayName,
            message: assetIDsToWarm.isEmpty
                ? "“\(source.displayName)”无需生成新的\(kindName)\(sourcePosition)"
                : "正在预热“\(source.displayName)”的\(kindName) 0 / \(assetIDsToWarm.count)\(sourcePosition)"
        )

        var warmed = 0
        var failed = 0
        for (index, assetID) in assetIDsToWarm.enumerated() {
            guard !Task.isCancelled else { return nil }
            do {
                if originalAspect {
                    _ = try await workspace.prewarmOriginalAspectThumbnail(assetID: assetID)
                } else {
                    _ = try await workspace.loadThumbnail(assetID: assetID)
                }
                warmed += 1
            } catch is CancellationError {
                return nil
            } catch {
                failed += 1
            }
            let completed = index + 1
            updatePrewarmProgress(
                requestID,
                completed: completed,
                total: assetIDsToWarm.count,
                warmed: warmed,
                reused: reused,
                ineligible: ineligible,
                failed: failed,
                completedSourceCount: completedSourceCount,
                totalSourceCount: totalSourceCount,
                sourceDisplayName: source.displayName,
                message: "正在预热“\(source.displayName)”的\(kindName) \(completed) / \(assetIDsToWarm.count)\(sourcePosition)"
            )
        }
        return SourcePrewarmResult(
            total: assets.count,
            warmed: warmed,
            reused: reused,
            ineligible: ineligible,
            failed: failed
        )
    }

    private static func canGenerateThumbnail(for asset: AssetGridItemProjection) -> Bool {
        guard asset.sourceState == .active, asset.availability == .available else {
            return false
        }
        return switch asset.mediaKind {
        case .image:
            ApprovedSourceMediaTypes.contains(asset.mediaType)
        case .video:
            ApprovedSourceMediaTypes.isVideoMediaType(asset.mediaType)
                && (asset.durationMs ?? 0) > 0
        }
    }

    private func updatePrewarmProgress(
        _ requestID: UUID,
        completed: Int,
        total: Int,
        warmed: Int,
        reused: Int = 0,
        ineligible: Int = 0,
        failed: Int,
        completedSourceCount: Int? = nil,
        totalSourceCount: Int? = nil,
        sourceDisplayName: String? = nil,
        message: String
    ) {
        guard let current = requestsByID[requestID],
              [.awaitingMac, .running].contains(current.phase)
        else { return }
        requestsByID[requestID] = SourceManagementCommandRequestSnapshot(
            id: current.id,
            operationID: current.operationID,
            action: current.action,
            sourceID: current.sourceID,
            sourceDisplayName: sourceDisplayName ?? current.sourceDisplayName,
            phase: .running,
            message: message,
            completedCount: completed,
            totalCount: total,
            warmedCount: warmed,
            failedCount: failed,
            reusedCount: reused,
            ineligibleCount: ineligible,
            completedSourceCount: completedSourceCount,
            totalSourceCount: totalSourceCount,
            updatedAtMs: clock.nowMs
        )
    }

    private func finishIfActive(
        _ requestID: UUID,
        phase: SourceManagementCommandPhase,
        message: String
    ) {
        guard let current = requestsByID[requestID],
              [.awaitingMac, .running].contains(current.phase)
        else { return }
        finish(requestID, phase: phase, message: message)
    }

    private func finish(
        _ requestID: UUID,
        phase: SourceManagementCommandPhase,
        message: String,
        clearTask: Bool = true
    ) {
        guard let current = requestsByID[requestID] else { return }
        requestsByID[requestID] = SourceManagementCommandRequestSnapshot(
            id: current.id,
            operationID: current.operationID,
            action: current.action,
            sourceID: current.sourceID,
            sourceDisplayName: current.sourceDisplayName,
            phase: phase,
            message: message,
            completedCount: current.completedCount,
            totalCount: current.totalCount,
            warmedCount: current.warmedCount,
            failedCount: current.failedCount,
            reusedCount: current.reusedCount,
            ineligibleCount: current.ineligibleCount,
            completedSourceCount: current.completedSourceCount,
            totalSourceCount: current.totalSourceCount,
            updatedAtMs: clock.nowMs
        )
        if clearTask { tasksByID[requestID] = nil }
        pruneFinishedRequests()
    }

    private func startFolderRunner(sourceIDs: Set<UUID>) {
        let workspace = workspace
        Task.detached(priority: .utility) {
            try? workspace.runPendingReconcileJobs(sourceIDs: sourceIDs)
        }
    }

    private func startPhotosRunner(sourceIDs: Set<UUID>) {
        let workspace = workspace
        Task.detached(priority: .utility) {
            try? workspace.runPendingPhotosReconcileJobs(sourceIDs: sourceIDs)
        }
    }

    private func pruneFinishedRequests() {
        let orderedFinished = requestsByID.values
            .filter { [.completed, .cancelled, .failed].contains($0.phase) }
            .sorted { $0.updatedAtMs > $1.updatedAtMs }
        for request in orderedFinished.dropFirst(16) {
            requestsByID[request.id] = nil
            acceptedOperations = acceptedOperations.filter {
                $0.value.requestID != request.id
            }
        }
    }
}

private extension SourceManagementCommandAction {
    var requiresMacInteraction: Bool {
        switch self {
        case .connectFolder,
             .connectPhotos,
             .reauthorizeAll,
             .refreshAllFolderMutationAuthorizations,
             .rebindPhotos,
             .reauthorize,
             .fullRepair,
             .openPhotosPrivacySettings,
             .requestPhotosWriteAuthorization,
             .refreshFolderMutationAuthorization,
             .delete:
            true
        case .rescan,
             .syncPhotos,
             .refreshAll,
             .prewarmAllThumbnails,
             .prewarmAllOriginalAspect,
             .prewarmThumbnails,
             .prewarmOriginalAspect,
             .cancelPrewarm:
            false
        }
    }

    var isPrewarm: Bool {
        self == .prewarmThumbnails
            || self == .prewarmOriginalAspect
            || self == .prewarmAllThumbnails
            || self == .prewarmAllOriginalAspect
    }

    var isAllSourcePrewarm: Bool {
        self == .prewarmAllThumbnails || self == .prewarmAllOriginalAspect
    }

    var initialMessage: String {
        requiresMacInteraction
            ? "请回到 Mac 完成原生确认或系统选择器"
            : "Mac 正在接收来源操作…"
    }

    var completedMessage: String {
        switch self {
        case .connectFolder: "已连接文件夹，后台扫描已开始"
        case .connectPhotos: "已连接 Apple Photos，后台同步已开始"
        case .refreshAll: "全部活跃来源已排入更新任务"
        case .prewarmAllThumbnails: "全部来源缩略图预热已完成"
        case .prewarmAllOriginalAspect: "全部来源原比例缓存预热已完成"
        case .reauthorizeAll: "已完成全部需要访问权限的来源授权"
        case .refreshAllFolderMutationAuthorizations: "已更新全部文件夹回收权限"
        case .rebindPhotos: "已保留旧历史并连接当前系统图库"
        case .reauthorize: "来源授权已恢复，后台同步已开始"
        case .rescan: "文件夹重扫已排入后台任务"
        case .syncPhotos: "Apple Photos 同步已排入后台任务"
        case .fullRepair: "Apple Photos 完整修复扫描已排入后台任务"
        case .openPhotosPrivacySettings: "已在 Mac 上打开照片权限设置"
        case .requestPhotosWriteAuthorization: "已更新照片库写入授权"
        case .refreshFolderMutationAuthorization: "已更新文件夹回收权限"
        case .prewarmThumbnails: "来源缩略图预热已完成"
        case .prewarmOriginalAspect: "来源原比例缓存预热已完成"
        case .cancelPrewarm: "来源缩略图预热已取消"
        case .delete: "来源已从 ImageAll 删除"
        }
    }
}
