import AppKit
import Foundation

struct AppKitRemoteLibrarySlimmingNativeApprovalPresenter:
    RemoteLibrarySlimmingNativeApprovalPresenting
{
    @MainActor
    func confirm(_ approval: RemoteLibrarySlimmingNativeApproval) -> Bool {
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

private extension RemoteLibrarySlimmingNativeApproval {
    var isDestructive: Bool {
        switch self {
        case .purge, .releaseSpaceBatch: true
        case let .identicalCleanup(_, _, _, mode): mode == .releaseSourceSpace
        case .restore, .retry, .recoverableBatch: false
        }
    }

    var title: String {
        switch self {
        case let .restore(fileName): "恢复“\(fileName)”？"
        case let .retry(fileName): "重新检查“\(fileName)”的回收状态？"
        case let .purge(fileName): "永久删除“\(fileName)”？"
        case let .recoverableBatch(count, mediaKind):
            "将选中的 \(count) \(mediaKind == .video ? "段视频" : "张照片")移入可恢复回收站？"
        case let .releaseSpaceBatch(count, mediaKind):
            "立即删除选中的 \(count) \(mediaKind == .video ? "段视频" : "张照片")并释放空间？"
        case let .identicalCleanup(groupCount, removalCount, mediaKind, _):
            "一键清理 \(groupCount) 组完全相同\(mediaKind == .video ? "视频" : "照片")中的 \(removalCount) 项？"
        }
    }

    var detail: String {
        switch self {
        case .restore:
            "ImageAll 会把隔离区中的文件恢复到原位置；若原位置已有文件，恢复会安全失败并继续保留回收项。"
        case .retry:
            "ImageAll 只会核对原位置和隔离区，并在结果唯一时继续协调状态；不会猜测或删除两侧文件。"
        case .purge:
            "这会永久删除 ImageAll 隔离区中的原始媒体文件，无法恢复。Apple Photos 项不支持此操作。"
        case .recoverableBatch:
            "文件来源会先复制到 ImageAll 隔离区并验证，保留 30 天后清理；跨磁盘复制可能需要一些时间。Apple Photos 项会移入系统“最近删除”。"
        case .releaseSpaceBatch:
            "文件来源会在身份校验后永久删除，不能从 ImageAll 恢复。Apple Photos 项仍只会移入系统“最近删除”，并遵循系统保留期。"
        case let .identicalCleanup(groupCount, removalCount, _, mode):
            "已重新核验 \(groupCount) 组，并为每组严格保留一项；其余 \(removalCount) 项将"
                + (mode == .releaseSourceSpace
                    ? "立即清理。文件夹原始媒体会永久删除，Apple Photos 项进入系统“最近删除”。"
                    : "移入可恢复回收站。文件夹媒体保留 30 天，Apple Photos 项进入系统“最近删除”。")
        }
    }

    var confirmTitle: String {
        switch self {
        case .restore: "恢复到原位置"
        case .retry: "重新检查"
        case .purge: "永久删除"
        case .recoverableBatch: "移入可恢复回收站"
        case .releaseSpaceBatch: "立即删除并释放空间"
        case let .identicalCleanup(_, _, _, mode):
            mode == .releaseSourceSpace ? "快速清理" : "可恢复回收"
        }
    }
}

actor RemoteLibrarySlimmingCommandService: RemoteLibrarySlimmingCommandPort {
    private struct AcceptedOperation: Sendable {
        let command: LibrarySlimmingLaunchCommand
        let receipt: LibrarySlimmingLaunchReceipt
    }

    private struct AcceptedRecycleOperation: Sendable {
        let command: LibrarySlimmingRecycleCommandRequest
        let requestID: UUID
    }

    private struct AcceptedRemovalOperation: Sendable {
        let command: LibrarySlimmingRemovalCommand
        let requestID: UUID
    }

    private struct PreparedIdenticalCleanup: Sendable {
        let snapshot: LibrarySlimmingIdenticalCleanupPlanSnapshot
        let plan: LibrarySlimmingIdenticalCleanupPlan
    }

    private struct AcceptedIdenticalCleanupOperation: Sendable {
        let command: LibrarySlimmingIdenticalCleanupCommand
        let requestID: UUID
    }

    private let catalog: any RemoteCatalogServing
    private let analysis: any LibrarySlimmingAnalysisJobPort
    private let thresholds: any NearDuplicateSceneThresholdWriting
    private let recycle: any LibrarySlimmingRecyclePort
    private let mutationAuthorization: any FolderMutationAuthorizationPort
    private let photosMutation: any PhotosLibraryMutationPort
    private let approvalPresenter: any RemoteLibrarySlimmingNativeApprovalPresenting
    private let clock: any JobClock
    private var acceptedOperations: [UUID: AcceptedOperation] = [:]
    private var recycleRequestsByID: [UUID: LibrarySlimmingRecycleCommandRequestSnapshot] = [:]
    private var acceptedRecycleOperations: [UUID: AcceptedRecycleOperation] = [:]
    private var recycleTasksByID: [UUID: Task<Void, Never>] = [:]
    private var removalRequestsByID: [UUID: LibrarySlimmingRemovalCommandRequestSnapshot] = [:]
    private var acceptedRemovalOperations: [UUID: AcceptedRemovalOperation] = [:]
    private var removalTasksByID: [UUID: Task<Void, Never>] = [:]
    private var identicalCleanupPlansByID: [UUID: PreparedIdenticalCleanup] = [:]
    private var identicalCleanupRequestsByID:
        [UUID: LibrarySlimmingIdenticalCleanupRequestSnapshot] = [:]
    private var acceptedIdenticalCleanupOperations:
        [UUID: AcceptedIdenticalCleanupOperation] = [:]
    private var identicalCleanupTasksByID: [UUID: Task<Void, Never>] = [:]
    private var runnerTask: Task<Void, Never>?

    init(
        catalog: any RemoteCatalogServing,
        analysis: any LibrarySlimmingAnalysisJobPort,
        thresholds: any NearDuplicateSceneThresholdWriting,
        recycle: any LibrarySlimmingRecyclePort,
        mutationAuthorization: any FolderMutationAuthorizationPort,
        photosMutation: any PhotosLibraryMutationPort,
        approvalPresenter: any RemoteLibrarySlimmingNativeApprovalPresenting =
            AppKitRemoteLibrarySlimmingNativeApprovalPresenter(),
        clock: any JobClock = SystemJobClock()
    ) {
        self.catalog = catalog
        self.analysis = analysis
        self.thresholds = thresholds
        self.recycle = recycle
        self.mutationAuthorization = mutationAuthorization
        self.photosMutation = photosMutation
        self.approvalPresenter = approvalPresenter
        self.clock = clock
    }

    func setup(mediaKind: MediaKind) throws -> LibrarySlimmingCommandSetupSnapshot {
        LibrarySlimmingCommandSetupSnapshot(
            mediaKind: mediaKind,
            sources: try catalog.fetchSources().filter { $0.state == .active },
            thresholds: thresholds.thresholds(),
            factoryThresholds: .factory
        )
    }

    func launch(
        _ command: LibrarySlimmingLaunchCommand
    ) throws -> LibrarySlimmingLaunchReceipt {
        if let accepted = acceptedOperations[command.operationID] {
            guard accepted.command == command else {
                throw LibrarySlimmingCommandError.activeConflict
            }
            return accepted.receipt
        }

        let setup = try setup(mediaKind: command.mediaKind)
        let activeSourceIDs = Set(setup.sources.map(\.id))
        let filter: AssetPageFilter
        switch command.mode {
        case .catalog:
            let selectedSourceIDs = command.sourceIDs ?? activeSourceIDs
            guard !selectedSourceIDs.isEmpty,
                  selectedSourceIDs.isSubset(of: activeSourceIDs),
                  command.seedAssetIDs.isEmpty
            else {
                throw LibrarySlimmingCommandError.invalidSelection
            }
            filter = AssetPageFilter(
                sourceIDs: selectedSourceIDs.sorted(by: Self.uuidLessThan),
                availabilities: [.available],
                mediaKinds: [command.mediaKind]
            )
        case .currentFilter:
            guard let requestedFilter = command.filter,
                  command.seedAssetIDs.isEmpty
            else {
                throw LibrarySlimmingCommandError.invalidSelection
            }
            filter = Self.normalizedFilter(requestedFilter, mediaKind: command.mediaKind)
        case .seeds:
            guard !command.seedAssetIDs.isEmpty else {
                throw LibrarySlimmingCommandError.invalidSelection
            }
            filter = Self.normalizedFilter(
                command.filter ?? AssetPageFilter(availabilities: [.available]),
                mediaKind: command.mediaKind
            )
        }

        let assetIDs = try Self.listAllAssetIDs(
            catalog: catalog,
            filter: filter,
            sort: command.sort
        )
        guard !assetIDs.isEmpty || !command.seedAssetIDs.isEmpty else {
            throw LibrarySlimmingCommandError.invalidSelection
        }
        let seeds = command.seedAssetIDs.sorted(by: Self.uuidLessThan)
        let snapshot: LibrarySlimmingAnalysisJobSnapshot
        do {
            snapshot = try analysis.enqueue(
                mode: command.mode,
                assetIDs: assetIDs,
                seedAssetIDs: seeds,
                mediaKind: command.mediaKind
            )
        } catch {
            throw Self.mapAnalysisError(error)
        }
        let receipt = LibrarySlimmingLaunchReceipt(
            operationID: command.operationID,
            jobID: snapshot.jobID,
            acceptedAtMs: clock.nowMs,
            memberCount: Set(assetIDs).union(seeds).count
        )
        acceptedOperations[command.operationID] = AcceptedOperation(
            command: command,
            receipt: receipt
        )
        startRunnerIfNeeded()
        return receipt
    }

    func apply(
        jobID: UUID,
        action: LibrarySlimmingJobCommandAction
    ) throws -> LibrarySlimmingJobCommandResult {
        do {
            switch action {
            case .pause:
                let snapshot = try analysis.pause(jobID: jobID)
                return LibrarySlimmingJobCommandResult(snapshot: snapshot, deleted: false)
            case .resume:
                let snapshot = try analysis.resume(jobID: jobID)
                startRunnerIfNeeded()
                return LibrarySlimmingJobCommandResult(snapshot: snapshot, deleted: false)
            case .deleteRecord:
                try analysis.delete(jobID: jobID)
                return LibrarySlimmingJobCommandResult(snapshot: nil, deleted: true)
            }
        } catch {
            throw Self.mapAnalysisError(error)
        }
    }

    func updateThresholds(
        _ requested: NearDuplicateSceneThresholds
    ) -> NearDuplicateSceneThresholds {
        let value = requested.clamped()
        thresholds.setThresholds(value)
        return thresholds.thresholds()
    }

    func recycleSnapshot(
        mediaKind: MediaKind,
        sourceID: UUID?,
        searchText: String?,
        limit: Int
    ) throws -> LibrarySlimmingRecycleCommandSnapshot {
        let sourceNames = Dictionary(
            uniqueKeysWithValues: try catalog.fetchSources().map { ($0.id, $0.displayName) }
        )
        let foldedQuery = searchText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let filtered = try recycle.listRecycleBinEntries().filter { entry in
            guard entry.mediaKind == mediaKind else { return false }
            if let sourceID, entry.sourceID != sourceID { return false }
            guard let foldedQuery, !foldedQuery.isEmpty else { return true }
            return entry.fileName?
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .contains(foldedQuery) == true
        }
        let safeLimit = max(1, min(limit, 5_000))
        return LibrarySlimmingRecycleCommandSnapshot(
            entries: Array(filtered.prefix(safeLimit)),
            totalCount: filtered.count,
            sourceNames: sourceNames,
            requests: recycleRequestsByID.values.sorted { lhs, rhs in
                if lhs.updatedAtMs != rhs.updatedAtMs { return lhs.updatedAtMs > rhs.updatedAtMs }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        )
    }

    func submitRecycle(
        _ command: LibrarySlimmingRecycleCommandRequest
    ) throws -> LibrarySlimmingRecycleCommandRequestSnapshot {
        if acceptedRemovalOperations[command.operationID] != nil
            || acceptedIdenticalCleanupOperations[command.operationID] != nil
        {
            throw LibrarySlimmingCommandError.operationConflict
        }
        if let accepted = acceptedRecycleOperations[command.operationID] {
            guard accepted.command == command else {
                throw LibrarySlimmingCommandError.operationConflict
            }
            guard let existing = recycleRequestsByID[accepted.requestID] else {
                throw LibrarySlimmingCommandError.unavailable
            }
            return existing
        }
        guard !recycleRequestsByID.values.contains(where: {
            $0.phase == .awaitingMac || $0.phase == .running
        }), !hasActiveRemovalRequest, !hasActiveIdenticalCleanupRequest else {
            throw LibrarySlimmingCommandError.activeConflict
        }
        guard let entry = try recycle.listRecycleBinEntries()
            .first(where: { $0.id == command.entryID })
        else {
            throw LibrarySlimmingCommandError.recycleEntryNotFound
        }
        try validateRecycle(command, entry: entry)

        let requestID = UUID()
        let requiresMac = command.action != .discardPreflightFailure
        let request = LibrarySlimmingRecycleCommandRequestSnapshot(
            id: requestID,
            operationID: command.operationID,
            entryID: command.entryID,
            action: command.action,
            fileName: entry.fileName,
            phase: requiresMac ? .awaitingMac : .running,
            message: requiresMac
                ? "请回到 Mac 完成原生确认"
                : "Mac 正在安全撤销未执行的失败意图…",
            updatedAtMs: clock.nowMs
        )
        recycleRequestsByID[requestID] = request
        acceptedRecycleOperations[command.operationID] = AcceptedRecycleOperation(
            command: command,
            requestID: requestID
        )
        recycleTasksByID[requestID] = Task { [weak self] in
            await self?.executeRecycle(command, requestID: requestID, entry: entry)
        }
        return request
    }

    func removalSnapshot(
        mediaKind: MediaKind
    ) -> LibrarySlimmingRemovalCommandSnapshot {
        LibrarySlimmingRemovalCommandSnapshot(
            requests: removalRequestsByID.values
                .filter { $0.mediaKind == mediaKind }
                .sorted { lhs, rhs in
                    if lhs.updatedAtMs != rhs.updatedAtMs {
                        return lhs.updatedAtMs > rhs.updatedAtMs
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
        )
    }

    func submitRemoval(
        _ requested: LibrarySlimmingRemovalCommand
    ) throws -> LibrarySlimmingRemovalCommandRequestSnapshot {
        if acceptedRecycleOperations[requested.operationID] != nil
            || acceptedIdenticalCleanupOperations[requested.operationID] != nil
        {
            throw LibrarySlimmingCommandError.operationConflict
        }
        let canonicalAssetIDs = Array(Set(requested.assetIDs)).sorted(by: Self.uuidLessThan)
        let command = LibrarySlimmingRemovalCommand(
            operationID: requested.operationID,
            jobID: requested.jobID,
            clusterID: requested.clusterID,
            mediaKind: requested.mediaKind,
            assetIDs: canonicalAssetIDs,
            mode: requested.mode
        )
        if let accepted = acceptedRemovalOperations[command.operationID] {
            guard accepted.command == command else {
                throw LibrarySlimmingCommandError.operationConflict
            }
            guard let existing = removalRequestsByID[accepted.requestID] else {
                throw LibrarySlimmingCommandError.unavailable
            }
            return existing
        }
        guard !hasActiveRemovalRequest, !hasActiveIdenticalCleanupRequest,
              !recycleRequestsByID.values.contains(where: {
                  $0.phase == .awaitingMac || $0.phase == .running
              })
        else {
            throw LibrarySlimmingCommandError.activeConflict
        }
        guard !canonicalAssetIDs.isEmpty, canonicalAssetIDs.count <= 5_000 else {
            throw LibrarySlimmingCommandError.invalidSelection
        }
        let summaries = try analysis.listJobs(mediaKind: command.mediaKind)
        guard summaries.contains(where: { $0.jobID == command.jobID }) else {
            throw LibrarySlimmingCommandError.jobNotFound
        }
        let snapshot = try analysis.snapshot(jobID: command.jobID)
        let resultClusters = snapshot.result?.clusters ?? []
        let clusterAssetIDs: Set<UUID>?
        if let cluster = resultClusters.first(where: { $0.id == command.clusterID }) {
            clusterAssetIDs = Set(cluster.memberAssetIDs)
        } else if resultClusters.isEmpty, !snapshot.seedAssetIDs.isEmpty {
            let seedClusterID = NearDuplicateSceneClusterService.stableClusterID(
                kind: .nearDuplicateScene,
                members: snapshot.seedAssetIDs
            )
            clusterAssetIDs = seedClusterID == command.clusterID
                ? Set(snapshot.seedAssetIDs)
                : nil
        } else {
            clusterAssetIDs = nil
        }
        guard let clusterAssetIDs,
              Set(canonicalAssetIDs).isSubset(of: clusterAssetIDs)
        else {
            throw LibrarySlimmingCommandError.invalidSelection
        }

        let requestID = UUID()
        let request = LibrarySlimmingRemovalCommandRequestSnapshot(
            id: requestID,
            operationID: command.operationID,
            jobID: command.jobID,
            clusterID: command.clusterID,
            mediaKind: command.mediaKind,
            assetIDs: canonicalAssetIDs,
            mode: command.mode,
            phase: .awaitingMac,
            progress: nil,
            audit: nil,
            message: "请回到 Mac 核对并确认这次批量操作",
            updatedAtMs: clock.nowMs
        )
        removalRequestsByID[requestID] = request
        acceptedRemovalOperations[command.operationID] = AcceptedRemovalOperation(
            command: command,
            requestID: requestID
        )
        removalTasksByID[requestID] = Task { [weak self] in
            await self?.executeRemoval(command, requestID: requestID)
        }
        return request
    }

    func prepareIdenticalCleanup(
        jobID: UUID,
        mediaKind: MediaKind
    ) throws -> LibrarySlimmingIdenticalCleanupPlanSnapshot {
        guard !hasActiveRemovalRequest, !hasActiveIdenticalCleanupRequest,
              !recycleRequestsByID.values.contains(where: {
                  $0.phase == .awaitingMac || $0.phase == .running
              })
        else {
            throw LibrarySlimmingCommandError.activeConflict
        }
        let summaries = try analysis.listJobs(mediaKind: mediaKind)
        guard summaries.contains(where: { $0.jobID == jobID }) else {
            throw LibrarySlimmingCommandError.jobNotFound
        }
        let analysisSnapshot = try analysis.snapshot(jobID: jobID)
        let clusters = analysisSnapshot.result?.clusters ?? []
        let plan = try recycle.makeIdenticalCleanupPlan(clusters: clusters)
        guard !plan.isEmpty else {
            throw LibrarySlimmingCommandError.invalidSelection
        }
        let planID = UUID()
        let snapshot = LibrarySlimmingIdenticalCleanupPlanSnapshot(
            id: planID,
            jobID: jobID,
            mediaKind: mediaKind,
            groupCount: plan.groupCount,
            verifiedAssetCount: plan.verifiedAssetCount,
            retainedAssetCount: plan.retainedAssetCount,
            removalAssetCount: plan.assetIDsToRecycle.count,
            skippedGroupCount: plan.skippedGroupCount,
            photosAssetCount: plan.photosAssetCount,
            fileAssetCount: plan.fileAssetCount,
            groupSizeHistogram: plan.groupSizeHistogram,
            preparedAtMs: clock.nowMs
        )
        identicalCleanupPlansByID[planID] = PreparedIdenticalCleanup(
            snapshot: snapshot,
            plan: plan
        )
        pruneIdenticalCleanupPlans()
        return snapshot
    }

    func identicalCleanupSnapshot(
        mediaKind: MediaKind
    ) -> LibrarySlimmingIdenticalCleanupSnapshot {
        LibrarySlimmingIdenticalCleanupSnapshot(
            requests: identicalCleanupRequestsByID.values
                .filter { $0.mediaKind == mediaKind }
                .sorted { lhs, rhs in
                    if lhs.updatedAtMs != rhs.updatedAtMs {
                        return lhs.updatedAtMs > rhs.updatedAtMs
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
        )
    }

    func submitIdenticalCleanup(
        _ command: LibrarySlimmingIdenticalCleanupCommand
    ) throws -> LibrarySlimmingIdenticalCleanupRequestSnapshot {
        if acceptedRecycleOperations[command.operationID] != nil
            || acceptedRemovalOperations[command.operationID] != nil
        {
            throw LibrarySlimmingCommandError.operationConflict
        }
        if let accepted = acceptedIdenticalCleanupOperations[command.operationID] {
            guard accepted.command == command,
                  let existing = identicalCleanupRequestsByID[accepted.requestID]
            else {
                throw LibrarySlimmingCommandError.operationConflict
            }
            return existing
        }
        guard !hasActiveRemovalRequest, !hasActiveIdenticalCleanupRequest,
              !recycleRequestsByID.values.contains(where: {
                  $0.phase == .awaitingMac || $0.phase == .running
              })
        else {
            throw LibrarySlimmingCommandError.activeConflict
        }
        guard let prepared = identicalCleanupPlansByID[command.planID] else {
            throw LibrarySlimmingCommandError.cleanupPlanNotFound
        }
        let requestID = UUID()
        let request = LibrarySlimmingIdenticalCleanupRequestSnapshot(
            id: requestID,
            operationID: command.operationID,
            planID: command.planID,
            jobID: prepared.snapshot.jobID,
            mediaKind: prepared.snapshot.mediaKind,
            mode: command.mode,
            phase: .awaitingMac,
            progress: nil,
            audit: nil,
            verification: nil,
            message: "请回到 Mac 核对并确认一键清理方案",
            updatedAtMs: clock.nowMs
        )
        identicalCleanupRequestsByID[requestID] = request
        acceptedIdenticalCleanupOperations[command.operationID] =
            AcceptedIdenticalCleanupOperation(command: command, requestID: requestID)
        identicalCleanupTasksByID[requestID] = Task { [weak self] in
            await self?.executeIdenticalCleanup(
                command,
                requestID: requestID,
                prepared: prepared
            )
        }
        return request
    }

    func slimmingHiddenAssetIDs(from assetIDs: [UUID]) async throws -> Set<UUID> {
        try await Task.detached(priority: .utility) { [recycle] in
            try recycle.slimmingHiddenAssetIDs(from: assetIDs)
        }.value
    }

    private var hasActiveRemovalRequest: Bool {
        removalRequestsByID.values.contains {
            $0.phase == .awaitingMac || $0.phase == .running
        }
    }

    private var hasActiveIdenticalCleanupRequest: Bool {
        identicalCleanupRequestsByID.values.contains {
            $0.phase == .awaitingMac || $0.phase == .running
        }
    }

    private func executeIdenticalCleanup(
        _ command: LibrarySlimmingIdenticalCleanupCommand,
        requestID: UUID,
        prepared: PreparedIdenticalCleanup
    ) async {
        let snapshot = prepared.snapshot
        guard await approvalPresenter.confirm(
            .identicalCleanup(
                groupCount: snapshot.groupCount,
                removalCount: snapshot.removalAssetCount,
                mediaKind: snapshot.mediaKind,
                mode: command.mode
            )
        ) else {
            finishIdenticalCleanup(
                requestID,
                phase: .cancelled,
                message: "已在 Mac 上取消一键清理"
            )
            return
        }
        markIdenticalCleanupRunning(requestID, message: "正在重新核验冻结方案…")
        do {
            let analysisSnapshot = try analysis.snapshot(jobID: snapshot.jobID)
            let clusters = analysisSnapshot.result?.clusters ?? []
            let refreshedPlan = try await Task.detached(priority: .utility) { [recycle] in
                try recycle.makeIdenticalCleanupPlan(clusters: clusters)
            }.value
            guard refreshedPlan == prepared.plan else {
                throw LibrarySlimmingCommandError.cleanupPlanChanged
            }

            markIdenticalCleanupRunning(
                requestID,
                message: command.mode == .releaseSourceSpace
                    ? "正在逐组保留一项并释放空间…"
                    : "正在逐组保留一项并移入可恢复回收站…"
            )
            var outcome = try await performIdenticalCleanup(
                command,
                requestID: requestID,
                plan: prepared.plan
            )
            if !outcome.authorizationRequiredSourceIDs.isEmpty
                || !outcome.authorizationDeniedPhotosAssetIDs.isEmpty
            {
                var authorizationReady = outcome.mutationAuthorizationInvalidAssetIDs.isEmpty
                for sourceID in outcome.authorizationRequiredSourceIDs {
                    markIdenticalCleanupRunning(
                        requestID,
                        message: "请在 Mac 系统窗口中确认来源写入权限…"
                    )
                    do {
                        if case .authorized = try await mutationAuthorization.authorizeMutation(
                            sourceID: sourceID
                        ) {
                            continue
                        }
                    } catch {}
                    authorizationReady = false
                }
                if !outcome.authorizationDeniedPhotosAssetIDs.isEmpty {
                    markIdenticalCleanupRunning(
                        requestID,
                        message: "请在系统对话框中允许 ImageAll 访问照片库…"
                    )
                    if await photosMutation.requestAuthorization() != .authorized {
                        authorizationReady = false
                    }
                }
                if authorizationReady {
                    outcome = try await performIdenticalCleanup(
                        command,
                        requestID: requestID,
                        plan: prepared.plan
                    )
                }
            }

            let hidden = try await slimmingHiddenAssetIDs(
                from: prepared.plan.assetIDsToRecycle
            )
            let verification = try await Task.detached(priority: .utility) { [recycle] in
                try recycle.verifyIdenticalCleanup(plan: prepared.plan)
            }.value
            let audit = Self.makeAudit(outcome: outcome, hidden: hidden)
            let verificationSnapshot = Self.makeIdenticalCleanupVerification(verification)
            let message = Self.identicalCleanupMessage(
                mode: command.mode,
                verification: verification,
                outcome: outcome
            )
            finishIdenticalCleanup(
                requestID,
                phase: .completed,
                audit: audit,
                verification: verificationSnapshot,
                message: message
            )
            try? recycle.enqueuePurgeExpired()
        } catch LibrarySlimmingCommandError.cleanupPlanChanged,
                LibrarySlimmingRecycleError.cleanupPlanChanged
        {
            finishIdenticalCleanup(
                requestID,
                phase: .failed,
                message: "分析结果或来源状态已变化，请重新预览一键清理方案"
            )
        } catch {
            finishIdenticalCleanup(
                requestID,
                phase: .failed,
                message: "Mac 未能安全完成一键清理；未确认的项目仍保留"
            )
        }
    }

    private func performIdenticalCleanup(
        _ command: LibrarySlimmingIdenticalCleanupCommand,
        requestID: UUID,
        plan: LibrarySlimmingIdenticalCleanupPlan
    ) async throws -> LibrarySlimmingRecycleMoveOutcome {
        let service = self
        return try await Task.detached(priority: .utility) { [recycle] in
            let progress: LibrarySlimmingRecycleMoveProgressHandler = { value in
                Task {
                    await service.updateIdenticalCleanupProgress(
                        requestID,
                        progress: value,
                        totalAssetCount: plan.assetIDsToRecycle.count
                    )
                }
            }
            switch command.mode {
            case .recoverableRecycle:
                return try recycle.moveIdenticalCleanupAssetsToRecycle(
                    plan: plan,
                    onProgress: progress
                )
            case .releaseSourceSpace:
                return try recycle.deleteIdenticalCleanupAssetsImmediately(
                    plan: plan,
                    onProgress: progress
                )
            }
        }.value
    }

    private func updateIdenticalCleanupProgress(
        _ requestID: UUID,
        progress: LibrarySlimmingRecycleMoveProgress,
        totalAssetCount: Int
    ) {
        guard let current = identicalCleanupRequestsByID[requestID],
              current.phase == .running
        else { return }
        identicalCleanupRequestsByID[requestID] =
            LibrarySlimmingIdenticalCleanupRequestSnapshot(
                id: current.id,
                operationID: current.operationID,
                planID: current.planID,
                jobID: current.jobID,
                mediaKind: current.mediaKind,
                mode: current.mode,
                phase: .running,
                progress: LibrarySlimmingRemovalCommandProgress(
                    phase: progress.phase,
                    completedAssetCount: min(
                        totalAssetCount,
                        max(0, progress.completedAssetCount)
                    ),
                    totalAssetCount: totalAssetCount,
                    copiedBytes: progress.copiedBytes,
                    totalFileBytes: progress.totalFileBytes
                ),
                audit: current.audit,
                verification: current.verification,
                message: Self.progressMessage(progress.phase, mode: current.mode),
                updatedAtMs: clock.nowMs
            )
    }

    private func markIdenticalCleanupRunning(_ requestID: UUID, message: String) {
        finishIdenticalCleanup(
            requestID,
            phase: .running,
            message: message,
            clearTask: false
        )
    }

    private func finishIdenticalCleanup(
        _ requestID: UUID,
        phase: LibrarySlimmingRecycleCommandPhase,
        audit: LibrarySlimmingRemovalCommandAudit? = nil,
        verification: LibrarySlimmingIdenticalCleanupVerificationSnapshot? = nil,
        message: String,
        clearTask: Bool = true
    ) {
        guard let current = identicalCleanupRequestsByID[requestID] else { return }
        identicalCleanupRequestsByID[requestID] =
            LibrarySlimmingIdenticalCleanupRequestSnapshot(
                id: current.id,
                operationID: current.operationID,
                planID: current.planID,
                jobID: current.jobID,
                mediaKind: current.mediaKind,
                mode: current.mode,
                phase: phase,
                progress: current.progress,
                audit: audit ?? current.audit,
                verification: verification ?? current.verification,
                message: message,
                updatedAtMs: clock.nowMs
            )
        if clearTask { identicalCleanupTasksByID[requestID] = nil }
        pruneIdenticalCleanupRequests()
    }

    private func pruneIdenticalCleanupPlans() {
        let sorted = identicalCleanupPlansByID.values.sorted {
            $0.snapshot.preparedAtMs > $1.snapshot.preparedAtMs
        }
        for plan in sorted.dropFirst(16) {
            identicalCleanupPlansByID[plan.snapshot.id] = nil
        }
    }

    private func pruneIdenticalCleanupRequests() {
        let finished = identicalCleanupRequestsByID.values
            .filter { [.completed, .cancelled, .failed].contains($0.phase) }
            .sorted { $0.updatedAtMs > $1.updatedAtMs }
        for request in finished.dropFirst(16) {
            identicalCleanupRequestsByID[request.id] = nil
            acceptedIdenticalCleanupOperations[request.operationID] = nil
            identicalCleanupPlansByID[request.planID] = nil
        }
    }

    private func executeRemoval(
        _ command: LibrarySlimmingRemovalCommand,
        requestID: UUID
    ) async {
        let approval: RemoteLibrarySlimmingNativeApproval = switch command.mode {
        case .recoverableRecycle:
            .recoverableBatch(count: command.assetIDs.count, mediaKind: command.mediaKind)
        case .releaseSourceSpace:
            .releaseSpaceBatch(count: command.assetIDs.count, mediaKind: command.mediaKind)
        }
        guard await approvalPresenter.confirm(approval) else {
            finishRemoval(
                requestID,
                phase: .cancelled,
                message: "已在 Mac 上取消批量操作"
            )
            return
        }
        markRemovalRunning(
            requestID,
            message: command.mode == .releaseSourceSpace
                ? "正在验证来源并释放空间…"
                : "正在复制、校验并移入可恢复回收站…"
        )
        do {
            var outcome = try await performRemoval(
                command,
                requestID: requestID,
                assetIDs: command.assetIDs,
                completedBeforeRetry: 0
            )
            if !outcome.authorizationRequiredSourceIDs.isEmpty {
                markRemovalRunning(requestID, message: "请在 Mac 系统窗口中确认来源写入权限…")
                var authorizedAtLeastOneSource = false
                for sourceID in outcome.authorizationRequiredSourceIDs {
                    do {
                        if case .authorized = try await mutationAuthorization.authorizeMutation(
                            sourceID: sourceID
                        ) {
                            authorizedAtLeastOneSource = true
                        }
                    } catch {
                        continue
                    }
                }
                if authorizedAtLeastOneSource, !outcome.authorizationRequiredAssetIDs.isEmpty {
                    let retryAssetIDs = outcome.authorizationRequiredAssetIDs
                    let otherFailedAssetIDs = outcome.failedAssetIDs.filter {
                        !Set(retryAssetIDs).contains($0)
                    }
                    let retry = try await performRemoval(
                        command,
                        requestID: requestID,
                        assetIDs: retryAssetIDs,
                        completedBeforeRetry: Self.completedAssetCount(
                            total: command.assetIDs.count,
                            outcome: outcome
                        )
                    )
                    outcome.recycledEntryIDs.append(contentsOf: retry.recycledEntryIDs)
                    outcome.permanentlyDeletedAssetIDs.append(
                        contentsOf: retry.permanentlyDeletedAssetIDs
                    )
                    outcome.durabilityPendingAssetIDs.append(
                        contentsOf: retry.durabilityPendingAssetIDs
                    )
                    outcome.skippedPhotosAssetIDs.append(contentsOf: retry.skippedPhotosAssetIDs)
                    outcome.authorizationDeniedPhotosAssetIDs.append(
                        contentsOf: retry.authorizationDeniedPhotosAssetIDs
                    )
                    outcome.failedAssetIDs = otherFailedAssetIDs + retry.failedAssetIDs
                    outcome.authorizationRequiredSourceIDs = retry.authorizationRequiredSourceIDs
                    outcome.authorizationRequiredAssetIDs = retry.authorizationRequiredAssetIDs
                    outcome.mutationAuthorizationInvalidAssetIDs.append(
                        contentsOf: retry.mutationAuthorizationInvalidAssetIDs
                    )
                    outcome.photosMutationFailedAssetIDs.append(
                        contentsOf: retry.photosMutationFailedAssetIDs
                    )
                    outcome.photosMutationFailureCategories.append(
                        contentsOf: retry.photosMutationFailureCategories
                    )
                    outcome.photosMutationFailureCodes.append(
                        contentsOf: retry.photosMutationFailureCodes
                    )
                    outcome.sourceChangedAssetIDs.append(contentsOf: retry.sourceChangedAssetIDs)
                }
            }
            if !outcome.authorizationDeniedPhotosAssetIDs.isEmpty {
                markRemovalRunning(
                    requestID,
                    message: "请在系统对话框中允许 ImageAll 访问照片库…"
                )
                if await photosMutation.requestAuthorization() == .authorized {
                    let retryAssetIDs = outcome.authorizationDeniedPhotosAssetIDs
                    let retrySet = Set(retryAssetIDs)
                    let otherFailedAssetIDs = outcome.failedAssetIDs.filter {
                        !retrySet.contains($0)
                    }
                    let retry = try await performRemoval(
                        command,
                        requestID: requestID,
                        assetIDs: retryAssetIDs,
                        completedBeforeRetry: Self.completedAssetCount(
                            total: command.assetIDs.count,
                            outcome: outcome
                        )
                    )
                    outcome.recycledEntryIDs.append(contentsOf: retry.recycledEntryIDs)
                    outcome.permanentlyDeletedAssetIDs.append(
                        contentsOf: retry.permanentlyDeletedAssetIDs
                    )
                    outcome.durabilityPendingAssetIDs.append(
                        contentsOf: retry.durabilityPendingAssetIDs
                    )
                    outcome.skippedPhotosAssetIDs.append(contentsOf: retry.skippedPhotosAssetIDs)
                    outcome.authorizationDeniedPhotosAssetIDs =
                        retry.authorizationDeniedPhotosAssetIDs
                    outcome.failedAssetIDs = otherFailedAssetIDs + retry.failedAssetIDs
                    outcome.authorizationRequiredSourceIDs.append(
                        contentsOf: retry.authorizationRequiredSourceIDs
                    )
                    outcome.authorizationRequiredAssetIDs.append(
                        contentsOf: retry.authorizationRequiredAssetIDs
                    )
                    outcome.mutationAuthorizationInvalidAssetIDs.append(
                        contentsOf: retry.mutationAuthorizationInvalidAssetIDs
                    )
                    outcome.photosMutationFailedAssetIDs.append(
                        contentsOf: retry.photosMutationFailedAssetIDs
                    )
                    outcome.photosMutationFailureCategories.append(
                        contentsOf: retry.photosMutationFailureCategories
                    )
                    outcome.photosMutationFailureCodes.append(
                        contentsOf: retry.photosMutationFailureCodes
                    )
                    outcome.sourceChangedAssetIDs.append(contentsOf: retry.sourceChangedAssetIDs)
                }
            }
            let hidden = try await slimmingHiddenAssetIDs(from: command.assetIDs)
            try? recycle.enqueuePurgeExpired()
            if command.mode == .releaseSourceSpace,
               !outcome.permanentlyDeletedAssetIDs.isEmpty
                    || !outcome.durabilityPendingAssetIDs.isEmpty
            {
                let nowMs = clock.nowMs
                Task.detached(priority: .utility) { [recycle] in
                    _ = try? recycle.recoverInterruptedOperations()
                    _ = try? recycle.purgeExpired(nowMs: nowMs)
                }
            }
            let audit = Self.makeAudit(outcome: outcome, hidden: hidden)
            finishRemoval(
                requestID,
                phase: .completed,
                audit: audit,
                message: Self.removalMessage(mode: command.mode, outcome: outcome)
            )
        } catch {
            finishRemoval(
                requestID,
                phase: .failed,
                message: "Mac 未能安全完成这次批量操作"
            )
        }
    }

    private func performRemoval(
        _ command: LibrarySlimmingRemovalCommand,
        requestID: UUID,
        assetIDs: [UUID],
        completedBeforeRetry: Int
    ) async throws -> LibrarySlimmingRecycleMoveOutcome {
        let service = self
        return try await Task.detached(priority: .utility) { [recycle] in
            let progress: LibrarySlimmingRecycleMoveProgressHandler = { value in
                Task {
                    await service.updateRemovalProgress(
                        requestID,
                        progress: value,
                        completedBeforeRetry: completedBeforeRetry,
                        totalAssetCount: command.assetIDs.count
                    )
                }
            }
            switch command.mode {
            case .recoverableRecycle:
                return try recycle.moveAssetsToRecycle(
                    assetIDs: assetIDs,
                    onProgress: progress
                )
            case .releaseSourceSpace:
                return try recycle.deleteAssetsImmediately(
                    assetIDs: assetIDs,
                    onProgress: progress
                )
            }
        }.value
    }

    private func updateRemovalProgress(
        _ requestID: UUID,
        progress: LibrarySlimmingRecycleMoveProgress,
        completedBeforeRetry: Int,
        totalAssetCount: Int
    ) {
        guard let current = removalRequestsByID[requestID], current.phase == .running else {
            return
        }
        let completed = min(
            totalAssetCount,
            completedBeforeRetry + progress.completedAssetCount
        )
        removalRequestsByID[requestID] = LibrarySlimmingRemovalCommandRequestSnapshot(
            id: current.id,
            operationID: current.operationID,
            jobID: current.jobID,
            clusterID: current.clusterID,
            mediaKind: current.mediaKind,
            assetIDs: current.assetIDs,
            mode: current.mode,
            phase: .running,
            progress: LibrarySlimmingRemovalCommandProgress(
                phase: progress.phase,
                completedAssetCount: completed,
                totalAssetCount: totalAssetCount,
                copiedBytes: progress.copiedBytes,
                totalFileBytes: progress.totalFileBytes
            ),
            audit: current.audit,
            message: Self.progressMessage(progress.phase, mode: current.mode),
            updatedAtMs: clock.nowMs
        )
    }

    private func markRemovalRunning(_ requestID: UUID, message: String) {
        finishRemoval(
            requestID,
            phase: .running,
            message: message,
            clearTask: false
        )
    }

    private func finishRemoval(
        _ requestID: UUID,
        phase: LibrarySlimmingRecycleCommandPhase,
        audit: LibrarySlimmingRemovalCommandAudit? = nil,
        message: String,
        clearTask: Bool = true
    ) {
        guard let current = removalRequestsByID[requestID] else { return }
        removalRequestsByID[requestID] = LibrarySlimmingRemovalCommandRequestSnapshot(
            id: current.id,
            operationID: current.operationID,
            jobID: current.jobID,
            clusterID: current.clusterID,
            mediaKind: current.mediaKind,
            assetIDs: current.assetIDs,
            mode: current.mode,
            phase: phase,
            progress: current.progress,
            audit: audit ?? current.audit,
            message: message,
            updatedAtMs: clock.nowMs
        )
        if clearTask { removalTasksByID[requestID] = nil }
        pruneRemovalRequests()
    }

    private func pruneRemovalRequests() {
        let finished = removalRequestsByID.values
            .filter { [.completed, .cancelled, .failed].contains($0.phase) }
            .sorted { $0.updatedAtMs > $1.updatedAtMs }
        for request in finished.dropFirst(16) {
            removalRequestsByID[request.id] = nil
            acceptedRemovalOperations[request.operationID] = nil
        }
    }

    private func validateRecycle(
        _ command: LibrarySlimmingRecycleCommandRequest,
        entry: RecycleEntryRecord
    ) throws {
        let valid = switch command.action {
        case .restore, .purge:
            entry.sourceKind == .file && entry.resolution == .restoreOrPurge
        case .discardPreflightFailure:
            entry.sourceKind == .file && entry.resolution == .discardPreflightFailure
        case .retryInterruptedOperation:
            entry.resolution == .retryInterruptedOperation || entry.resolution == .inspect
        }
        guard valid else { throw LibrarySlimmingCommandError.invalidAction }
    }

    private func executeRecycle(
        _ command: LibrarySlimmingRecycleCommandRequest,
        requestID: UUID,
        entry: RecycleEntryRecord
    ) async {
        let fileName = entry.fileName ?? "未命名媒体"
        do {
            switch command.action {
            case .restore:
                guard await approvalPresenter.confirm(.restore(fileName: fileName)) else {
                    finishRecycle(requestID, phase: .cancelled, message: "已在 Mac 上取消恢复")
                    return
                }
                markRecycleRunning(requestID, message: "正在恢复到原位置…")
                do {
                    try await Task.detached(priority: .utility) { [recycle] in
                        try recycle.restore(entryID: entry.id)
                    }.value
                } catch LibrarySlimmingRecycleError.mutationAuthorizationRequired {
                    markRecycleRunning(requestID, message: "请在 Mac 系统窗口中确认来源写入权限…")
                    guard case .authorized = try await mutationAuthorization.authorizeMutation(
                        sourceID: entry.sourceID
                    ) else {
                        finishRecycle(
                            requestID,
                            phase: .cancelled,
                            message: "已取消来源写入授权，媒体仍保留在回收站"
                        )
                        return
                    }
                    try await Task.detached(priority: .utility) { [recycle] in
                        try recycle.restore(entryID: entry.id)
                    }.value
                }
                finishRecycle(requestID, phase: .completed, message: "已恢复到原位置")
            case .discardPreflightFailure:
                try await Task.detached(priority: .utility) { [recycle] in
                    try recycle.discardFailedPreflightEntry(entryID: entry.id)
                }.value
                finishRecycle(
                    requestID,
                    phase: .completed,
                    message: "已撤销未执行的失败意图；原文件和隔离区均未修改"
                )
            case .retryInterruptedOperation:
                guard await approvalPresenter.confirm(.retry(fileName: fileName)) else {
                    finishRecycle(requestID, phase: .cancelled, message: "已在 Mac 上取消重新检查")
                    return
                }
                markRecycleRunning(requestID, message: "正在核对原位置与隔离区…")
                try await Task.detached(priority: .utility) { [recycle] in
                    try recycle.retryInterruptedEntry(entryID: entry.id)
                }.value
                finishRecycle(requestID, phase: .completed, message: "已重新检查并协调回收状态")
            case .purge:
                guard await approvalPresenter.confirm(.purge(fileName: fileName)) else {
                    finishRecycle(requestID, phase: .cancelled, message: "已在 Mac 上取消永久删除")
                    return
                }
                markRecycleRunning(requestID, message: "正在永久删除隔离区中的原始媒体…")
                try await Task.detached(priority: .utility) { [recycle] in
                    try recycle.purgeNow(entryID: entry.id)
                }.value
                finishRecycle(requestID, phase: .completed, message: "已永久删除，无法恢复")
            }
        } catch LibrarySlimmingRecycleError.restoreConflict {
            finishRecycle(requestID, phase: .failed, message: "恢复失败：原位置已经存在文件")
        } catch LibrarySlimmingRecycleError.mutationAuthorizationRequired,
                LibrarySlimmingRecycleError.mutationAuthorizationInvalid
        {
            finishRecycle(requestID, phase: .failed, message: "操作需要重新确认来源写入权限")
        } catch {
            finishRecycle(requestID, phase: .failed, message: "Mac 未能安全完成该回收站操作")
        }
    }

    private func markRecycleRunning(_ requestID: UUID, message: String) {
        finishRecycle(requestID, phase: .running, message: message, clearTask: false)
    }

    private func finishRecycle(
        _ requestID: UUID,
        phase: LibrarySlimmingRecycleCommandPhase,
        message: String,
        clearTask: Bool = true
    ) {
        guard let current = recycleRequestsByID[requestID] else { return }
        recycleRequestsByID[requestID] = LibrarySlimmingRecycleCommandRequestSnapshot(
            id: current.id,
            operationID: current.operationID,
            entryID: current.entryID,
            action: current.action,
            fileName: current.fileName,
            phase: phase,
            message: message,
            updatedAtMs: clock.nowMs
        )
        if clearTask { recycleTasksByID[requestID] = nil }
        pruneRecycleRequests()
    }

    private func pruneRecycleRequests() {
        let finished = recycleRequestsByID.values
            .filter { [.completed, .cancelled, .failed].contains($0.phase) }
            .sorted { $0.updatedAtMs > $1.updatedAtMs }
        for request in finished.dropFirst(16) {
            recycleRequestsByID[request.id] = nil
            acceptedRecycleOperations[request.operationID] = nil
        }
    }

    private func startRunnerIfNeeded() {
        guard runnerTask == nil else { return }
        let analysis = analysis
        runnerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try analysis.runPending()
                } catch {
                    break
                }
                let hasActive = (try? analysis.listJobs().contains {
                    $0.state == .pending || $0.state == .running
                }) == true
                guard hasActive else { break }
                try? await Task.sleep(for: .seconds(1))
            }
            await self?.runnerFinished()
        }
    }

    private func runnerFinished() {
        runnerTask = nil
    }

    private nonisolated static func completedAssetCount(
        total: Int,
        outcome: LibrarySlimmingRecycleMoveOutcome
    ) -> Int {
        let retryable = Set(outcome.authorizationRequiredAssetIDs)
            .union(outcome.authorizationDeniedPhotosAssetIDs)
        return max(0, total - retryable.count)
    }

    private nonisolated static func makeAudit(
        outcome: LibrarySlimmingRecycleMoveOutcome,
        hidden: Set<UUID>
    ) -> LibrarySlimmingRemovalCommandAudit {
        LibrarySlimmingRemovalCommandAudit(
            hiddenAssetIDs: sortedUUIDs(hidden),
            recycledEntryIDs: sortedUUIDs(Set(outcome.recycledEntryIDs)),
            permanentlyDeletedAssetIDs: sortedUUIDs(Set(outcome.permanentlyDeletedAssetIDs)),
            durabilityPendingAssetIDs: sortedUUIDs(Set(outcome.durabilityPendingAssetIDs)),
            failedAssetIDs: sortedUUIDs(Set(outcome.failedAssetIDs)),
            authorizationRequiredSourceIDs: sortedUUIDs(
                Set(outcome.authorizationRequiredSourceIDs)
            ),
            authorizationRequiredAssetIDs: sortedUUIDs(
                Set(outcome.authorizationRequiredAssetIDs)
            ),
            authorizationDeniedPhotosAssetIDs: sortedUUIDs(
                Set(outcome.authorizationDeniedPhotosAssetIDs)
            ),
            mutationAuthorizationInvalidAssetIDs: sortedUUIDs(
                Set(outcome.mutationAuthorizationInvalidAssetIDs)
            ),
            photosMutationFailedAssetIDs: sortedUUIDs(
                Set(outcome.photosMutationFailedAssetIDs)
            ),
            photosMutationFailureCategories: Array(
                Set(outcome.photosMutationFailureCategories)
            ).sorted { $0.rawValue < $1.rawValue },
            photosMutationFailureCodes: Array(Set(outcome.photosMutationFailureCodes)).sorted(),
            sourceChangedAssetIDs: sortedUUIDs(Set(outcome.sourceChangedAssetIDs))
        )
    }

    private nonisolated static func makeIdenticalCleanupVerification(
        _ verification: LibrarySlimmingIdenticalCleanupVerification
    ) -> LibrarySlimmingIdenticalCleanupVerificationSnapshot {
        LibrarySlimmingIdenticalCleanupVerificationSnapshot(
            verifiedGroupCount: verification.verifiedGroupCount,
            targetGroupCount: verification.targetGroupCount,
            targetRetainedAssetCount: verification.targetRetainedAssetCount,
            observedAssetCount: verification.observedAssetCount,
            currentAvailableAssetCount: verification.currentAvailableAssetCount,
            retainedNonredundantAssetCount: verification.retainedNonredundantAssetCount,
            recycledRedundantAssetCount: verification.recycledRedundantAssetCount,
            remainingRedundantAssetCount: verification.remainingRedundantAssetCount,
            unresolvedAssetCount: verification.unresolvedAssetCount,
            unresolvedGroupCount: verification.unresolvedGroupCount,
            isComplete: verification.isComplete
        )
    }

    private nonisolated static func identicalCleanupMessage(
        mode: LibrarySlimmingRemovalCommandMode,
        verification: LibrarySlimmingIdenticalCleanupVerification,
        outcome: LibrarySlimmingRecycleMoveOutcome
    ) -> String {
        var parts = [
            "已完成去重 \(verification.verifiedGroupCount)/\(verification.targetGroupCount) 组",
            mode == .releaseSourceSpace
                ? "已从活动图库移除 \(verification.recycledRedundantAssetCount) 项"
                : "已移入回收站 \(verification.recycledRedundantAssetCount) 项",
        ]
        if verification.unresolvedGroupCount > 0 {
            parts.append("尚未完成 \(verification.unresolvedGroupCount) 组")
        }
        if verification.remainingRedundantAssetCount > 0 {
            parts.append("仍有冗余 \(verification.remainingRedundantAssetCount) 项")
        }
        if verification.unresolvedAssetCount > 0 {
            parts.append("状态待确认 \(verification.unresolvedAssetCount) 项")
        }
        if !outcome.failedAssetIDs.isEmpty {
            parts.append("失败 \(Set(outcome.failedAssetIDs).count) 项")
        }
        return parts.joined(separator: " · ")
    }

    private nonisolated static func removalMessage(
        mode: LibrarySlimmingRemovalCommandMode,
        outcome: LibrarySlimmingRecycleMoveOutcome
    ) -> String {
        var parts: [String] = []
        if !outcome.recycledEntryIDs.isEmpty {
            parts.append(
                mode == .releaseSourceSpace
                    ? "已移入系统最近删除 \(outcome.recycledEntryIDs.count) 项"
                    : "已移入可恢复回收站 \(outcome.recycledEntryIDs.count) 项"
            )
        }
        if !outcome.permanentlyDeletedAssetIDs.isEmpty {
            parts.append("已永久删除 \(outcome.permanentlyDeletedAssetIDs.count) 项")
        }
        if !outcome.durabilityPendingAssetIDs.isEmpty {
            parts.append("\(outcome.durabilityPendingAssetIDs.count) 项等待后台确认磁盘状态")
        }
        if !outcome.authorizationDeniedPhotosAssetIDs.isEmpty {
            parts.append("Photos 未授权 \(outcome.authorizationDeniedPhotosAssetIDs.count) 项")
        }
        if !outcome.authorizationRequiredSourceIDs.isEmpty {
            parts.append("部分来源仍需要写入授权")
        }
        if !outcome.sourceChangedAssetIDs.isEmpty {
            parts.append("\(outcome.sourceChangedAssetIDs.count) 项来源已变化")
        }
        if !outcome.mutationAuthorizationInvalidAssetIDs.isEmpty {
            parts.append("\(outcome.mutationAuthorizationInvalidAssetIDs.count) 项来源权限已失效")
        }
        if !outcome.photosMutationFailedAssetIDs.isEmpty {
            parts.append("Photos 操作失败 \(outcome.photosMutationFailedAssetIDs.count) 项")
        }
        if !outcome.failedAssetIDs.isEmpty {
            parts.append("失败 \(outcome.failedAssetIDs.count) 项")
        }
        return parts.isEmpty ? "未处理任何项目" : parts.joined(separator: " · ")
    }

    private nonisolated static func progressMessage(
        _ phase: LibrarySlimmingRecycleMovePhase,
        mode: LibrarySlimmingRemovalCommandMode
    ) -> String {
        switch phase {
        case .waitingForBackgroundIO: "正在等待后台磁盘任务暂停…"
        case .preparing: "正在准备并验证来源…"
        case .copying: "正在复制到可恢复隔离区…"
        case .syncingDestination: "正在同步隔离区数据…"
        case .verifyingDestination: "正在校验隔离区副本…"
        case .verifyingSource: "正在复核来源身份…"
        case .deletingSource:
            mode == .releaseSourceSpace ? "正在删除来源文件…" : "正在移除来源文件…"
        case .syncingSourceDirectory: "正在确认来源目录状态…"
        case .photosSystemMutation: "正在移入 Photos 最近删除…"
        case .completedAsset: "正在收尾并刷新图库…"
        }
    }

    private nonisolated static func sortedUUIDs(_ values: Set<UUID>) -> [UUID] {
        values.sorted(by: uuidLessThan)
    }

    private nonisolated static func listAllAssetIDs(
        catalog: any RemoteCatalogServing,
        filter: AssetPageFilter,
        sort: AssetPageSort
    ) throws -> [UUID] {
        var ids: [UUID] = []
        var cursor: AssetPageCursor?
        repeat {
            let page = try catalog.fetchAssetPage(
                filter: filter,
                sort: sort,
                cursor: cursor,
                limit: 200
            )
            ids.append(contentsOf: page.items.map(\.assetID))
            cursor = page.nextCursor
        } while cursor != nil
        return ids
    }

    private nonisolated static func normalizedFilter(
        _ requested: AssetPageFilter,
        mediaKind: MediaKind
    ) -> AssetPageFilter {
        var filter = requested
        filter.mediaKinds = [mediaKind]
        return filter
    }

    private nonisolated static func uuidLessThan(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }

    private nonisolated static func mapAnalysisError(_ error: Error) -> Error {
        if let jobError = error as? JobQueueError {
            switch jobError {
            case .jobNotFound:
                return LibrarySlimmingCommandError.jobNotFound
            case .invalidTransition:
                return LibrarySlimmingCommandError.invalidAction
            default:
                break
            }
        }
        if let completionError = error as? FingerprintCompletionError {
            switch completionError {
            case .notFound, .ineligible:
                return LibrarySlimmingCommandError.invalidSelection
            default:
                break
            }
        }
        return error
    }
}
