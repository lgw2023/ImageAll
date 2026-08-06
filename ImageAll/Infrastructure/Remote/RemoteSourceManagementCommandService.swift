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
    private let approvalPresenter: any RemoteSourceNativeApprovalPresenting
    private let clock: any JobClock
    private var requestsByID: [UUID: SourceManagementCommandRequestSnapshot] = [:]
    private var acceptedOperations: [UUID: AcceptedOperation] = [:]
    private var tasksByID: [UUID: Task<Void, Never>] = [:]

    init(
        workspace: any RemoteSourceManagementWorkspacePort,
        mutationAuthorization: (any FolderMutationAuthorizationPort)? = nil,
        photosMutation: (any PhotosLibraryMutationPort)? = nil,
        approvalPresenter: any RemoteSourceNativeApprovalPresenting =
            AppKitRemoteSourceNativeApprovalPresenter(),
        clock: any JobClock = SystemJobClock()
    ) {
        self.workspace = workspace
        self.mutationAuthorization = mutationAuthorization
        self.photosMutation = photosMutation
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
        let initial = SourceManagementCommandRequestSnapshot(
            id: requestID,
            operationID: command.operationID,
            action: command.action,
            sourceID: source?.id,
            sourceDisplayName: source?.displayName,
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
        guard let sourceID = command.sourceID,
              try workspace.fetchSources().contains(where: { $0.id == sourceID })
        else { throw SourceManagementCommandError.sourceNotFound }
        guard let active = requestsByID.values.first(where: {
            $0.sourceID == sourceID
                && $0.action.isPrewarm
                && [.awaitingMac, .running].contains($0.phase)
        }) else { throw SourceManagementCommandError.invalidAction }

        acceptedOperations[command.operationID] = AcceptedOperation(
            command: command,
            requestID: active.id
        )
        tasksByID[active.id]?.cancel()
        finish(
            active.id,
            phase: .cancelled,
            message: "已取消“\(active.sourceDisplayName ?? "来源")”的缩略图预热"
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
        case .rebindPhotos,
             .reauthorize,
             .rescan,
             .syncPhotos,
             .fullRepair,
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

    private func runSourcePrewarm(
        requestID: UUID,
        source: LibrarySourceSummary,
        originalAspect: Bool
    ) async {
        let kindName = originalAspect ? "原比例缓存" : "网格缩略图"
        markRunning(requestID, message: "正在统计“\(source.displayName)”需要预热的项目…")

        var assetIDs: [UUID] = []
        var seenAssetIDs = Set<UUID>()
        var cursor: AssetPageCursor?
        var pageCount = 0
        repeat {
            guard !Task.isCancelled else {
                finishIfActive(
                    requestID,
                    phase: .cancelled,
                    message: "已取消“\(source.displayName)”的缩略图预热"
                )
                return
            }
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
                    assetIDs.append(item.assetID)
                }
                let next = page.nextCursor
                guard next != cursor else { break }
                cursor = next
            } catch {
                finish(
                    requestID,
                    phase: .failed,
                    message: "无法读取“\(source.displayName)”的资产清单"
                )
                return
            }
        } while cursor != nil

        var assetIDsToWarm = assetIDs
        if originalAspect {
            do {
                let cached = try await workspace.cachedOriginalAspectThumbnailAssetIDs(
                    sourceID: source.id
                )
                assetIDsToWarm.removeAll(where: cached.contains)
            } catch {
                var uncachedAssetIDs: [UUID] = []
                uncachedAssetIDs.reserveCapacity(assetIDs.count)
                for assetID in assetIDs {
                    guard !Task.isCancelled else {
                        finishIfActive(
                            requestID,
                            phase: .cancelled,
                            message: "已取消“\(source.displayName)”的缩略图预热"
                        )
                        return
                    }
                    do {
                        if try await workspace.loadOriginalAspectThumbnailIfCached(
                            assetID: assetID
                        ) == nil {
                            uncachedAssetIDs.append(assetID)
                        }
                    } catch is CancellationError {
                        finishIfActive(
                            requestID,
                            phase: .cancelled,
                            message: "已取消“\(source.displayName)”的缩略图预热"
                        )
                        return
                    } catch {
                        // Match the Mac workflow: a failed probe must not block repair.
                        uncachedAssetIDs.append(assetID)
                    }
                }
                assetIDsToWarm = uncachedAssetIDs
            }
        }

        updatePrewarmProgress(
            requestID,
            completed: 0,
            total: assetIDsToWarm.count,
            warmed: 0,
            failed: 0,
            message: assetIDsToWarm.isEmpty
                ? "“\(source.displayName)”无需生成新的\(kindName)"
                : "正在预热“\(source.displayName)”的\(kindName) 0 / \(assetIDsToWarm.count)"
        )

        var warmed = 0
        var failed = 0
        for (index, assetID) in assetIDsToWarm.enumerated() {
            guard !Task.isCancelled else {
                finishIfActive(
                    requestID,
                    phase: .cancelled,
                    message: "已取消“\(source.displayName)”的缩略图预热"
                )
                return
            }
            do {
                if originalAspect {
                    _ = try await workspace.prewarmOriginalAspectThumbnail(assetID: assetID)
                } else {
                    _ = try await workspace.loadThumbnail(assetID: assetID)
                }
                warmed += 1
            } catch is CancellationError {
                finishIfActive(
                    requestID,
                    phase: .cancelled,
                    message: "已取消“\(source.displayName)”的缩略图预热"
                )
                return
            } catch {
                failed += 1
            }
            let completed = index + 1
            updatePrewarmProgress(
                requestID,
                completed: completed,
                total: assetIDsToWarm.count,
                warmed: warmed,
                failed: failed,
                message: "正在预热“\(source.displayName)”的\(kindName) \(completed) / \(assetIDsToWarm.count)"
            )
        }

        finish(
            requestID,
            phase: .completed,
            message: "已完成“\(source.displayName)”的\(kindName)：成功 \(warmed)，失败 \(failed)"
        )
    }

    private func updatePrewarmProgress(
        _ requestID: UUID,
        completed: Int,
        total: Int,
        warmed: Int,
        failed: Int,
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
            sourceDisplayName: current.sourceDisplayName,
            phase: .running,
            message: message,
            completedCount: completed,
            totalCount: total,
            warmedCount: warmed,
            failedCount: failed,
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
             .rebindPhotos,
             .reauthorize,
             .fullRepair,
             .requestPhotosWriteAuthorization,
             .refreshFolderMutationAuthorization,
             .delete:
            true
        case .rescan,
             .syncPhotos,
             .prewarmThumbnails,
             .prewarmOriginalAspect,
             .cancelPrewarm:
            false
        }
    }

    var isPrewarm: Bool {
        self == .prewarmThumbnails || self == .prewarmOriginalAspect
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
        case .rebindPhotos: "已保留旧历史并连接当前系统图库"
        case .reauthorize: "来源授权已恢复，后台同步已开始"
        case .rescan: "文件夹重扫已排入后台任务"
        case .syncPhotos: "Apple Photos 同步已排入后台任务"
        case .fullRepair: "Apple Photos 完整修复扫描已排入后台任务"
        case .requestPhotosWriteAuthorization: "已更新照片库写入授权"
        case .refreshFolderMutationAuthorization: "已更新文件夹回收权限"
        case .prewarmThumbnails: "来源缩略图预热已完成"
        case .prewarmOriginalAspect: "来源原比例缓存预热已完成"
        case .cancelPrewarm: "来源缩略图预热已取消"
        case .delete: "来源已从 ImageAll 删除"
        }
    }
}
