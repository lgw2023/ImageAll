import CryptoKit
import CoreTransferable
import ImageAllLocalLibrary
import ImageAllRemoteClient
import ImageAllRemoteProtocol
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LocalSharedSyncSummary {
    let applied: Int
    let unchanged: Int
    let conflicts: Int
    let deferred: Int
    let received: Int
    let pullSupported: Bool
    let pullHasMore: Bool
    let collectionReceived: Int
    let collectionPullSupported: Bool
    let collectionPullHasMore: Bool
    let favoriteReceived: Int
    let favoritePullSupported: Bool
    let favoritePullHasMore: Bool
    let remaining: Int
}

struct LocalCleanupSourceCheck {
    let plan: LocalSourceRetirementPlan
    let sourceVersions: [String: String]
}

@MainActor
final class LocalLibraryModel: ObservableObject {
    @Published private(set) var authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var assets: [LocalAsset] = []
    @Published private(set) var tags: [LocalTag] = []
    @Published private(set) var collections: [LocalCollection] = []
    @Published private(set) var sharedSelections: [LocalShareSelection] = []
    @Published private(set) var sharedConflicts: [LocalSharedPendingOperation] = []
    @Published private(set) var privateCollectionRevisions: [UUID: Int64] = [:]
    @Published private(set) var pendingCollectionRename: LocalCollectionRenameCommand?
    @Published private(set) var pendingCount = 0
    @Published private(set) var hasMore = false
    @Published private(set) var favoriteWritesInFlight: Set<UUID> = []
    @Published var errorMessage: String?
    @Published private var shareTaskRecord = LocalShareTaskRecord()
    @Published private(set) var shareTaskPersistenceError: String?
    @Published private(set) var macImportStatusMessage: String?
    @Published private(set) var legacyAssociationInProgress = false
    @Published private(set) var legacyAssociationMessage: String?
    @Published private(set) var exportCleanupBusy = false
    @Published private(set) var exportCleanupMessage: String?
    var canReleaseExportPayload: Bool { shareTask.macOwnsProcessing != true && shareTask.phase == .received && shareTaskRecord.exportStagingName != nil && !exportCleanupBusy }
    private var refreshingMacImportStatus = false
    private var shareTaskJournal: LocalShareTaskJournal?
    var shareTask: LocalShareTask {
        get { shareTaskRecord.task }
        set {
            shareTaskRecord.task = newValue
            do { try saveShareTaskRecord(shareTaskRecord) }
            catch { failShareTaskPersistence(error) }
        }
    }
    private func failShareTaskPersistence(_ error: Error) {
        shareTaskPersistenceError = error.localizedDescription
        errorMessage = shareTaskPersistenceError
        activeImportTask?.cancel()
    }
    private func saveShareTaskRecord(_ record: LocalShareTaskRecord) throws {
        guard shareTaskPersistenceError == nil, let shareTaskJournal else {
            throw LocalShareTaskRecoveryError.unavailable
        }
        do { try shareTaskJournal.save(record) }
        catch { failShareTaskPersistence(error); throw error }
    }
    func beginShareTask(target: String, hostID: String, fingerprint: String,
                        includeAlbumCatalog: Bool, intent: LocalShareTask.Intent) throws {
        var record = shareTaskRecord
        try record.begin(selectionIDs: Set(sharedSelections.map(\.id)),
            includeAlbumCatalog: includeAlbumCatalog, hostID: hostID, fingerprint: fingerprint,
            target: target, intent: intent)
        try saveShareTaskRecord(record)
        shareTaskRecord = record
    }
    func resetReceivedShareTask() {
        guard shareTask.phase == .received, !exportCleanupBusy else { return }
        let record = LocalShareTaskRecord()
        do {
            try cleanupQueue()?.retain(shareTaskRecord)
            try saveShareTaskRecord(record); shareTaskRecord = record
        }
        catch { failShareTaskPersistence(error) }
    }
    private func bindShareTaskSource(_ snapshot: LocalSharedSnapshot) throws {
        var record = shareTaskRecord
        try record.bind(sourceInstallID: snapshot.installID, sourceEpoch: snapshot.sourceEpoch)
        try saveShareTaskRecord(record)
        shareTaskRecord = record
    }
    private func bindShareTaskMigration(_ id: UUID) throws {
        var record = shareTaskRecord
        try record.bind(migrationID: id)
        try saveShareTaskRecord(record)
        shareTaskRecord = record
    }
    var activeImportTask: Task<Void, Never>?
    func pauseActiveImport(reason: LocalShareTask.PauseReason = .userRequested) {
        guard shareTask.phase == .running else { return }
        shareTask.requestPause(reason)
        activeImportTask?.cancel()
    }
    @Published var shareIncludeAlbumCatalog = UserDefaults.standard.object(forKey: "imageall.mobile.shareIncludeAlbumCatalog") as? Bool ?? true {
        didSet { UserDefaults.standard.set(shareIncludeAlbumCatalog, forKey: "imageall.mobile.shareIncludeAlbumCatalog") }
    }
    @Published private(set) var shareSelectionEditing = false
    var shareTaskSelectionIDs: Set<UUID> { shareTaskRecord.selectionIDs }
    var shareTaskAlbumCatalog: Bool { shareTaskRecord.includeAlbumCatalog }
    var shareTaskHostID: String { shareTaskRecord.hostID }
    var shareTaskFingerprint: String { shareTaskRecord.fingerprint }

    func receiveShareTask(_ receipt: ImageAllMigrationTransferSealReceipt) throws {
        var record = shareTaskRecord
        try record.receive(receipt)
        try saveShareTaskRecord(record)
        shareTaskRecord = record
    }

    func refreshMacImportStatus(_ remote: RemoteCompanionModel) async {
        guard !refreshingMacImportStatus, shareTaskPersistenceError == nil,
              shareTask.phase == .received else { return }
        guard let query = shareTaskRecord.statusQuery else {
            macImportStatusMessage = "旧任务未保存清单绑定，请在 Mac 核对结果；不会为补齐状态重新上传。"
            return
        }
        refreshingMacImportStatus = true
        defer { refreshingMacImportStatus = false }
        do {
            guard shareTaskHostID == remote.savedPairingHostID,
                  shareTaskFingerprint == remote.savedPairingFingerprint else {
                throw LocalShareTaskRecoveryError.bindingChanged
            }
            let connection = try remote.importStatusConnection()
            let status = try await connection.client.importTaskStatus(query)
            try remote.validateImportStatusConnection(hostID: connection.hostID,
                deviceID: connection.deviceID, transportID: connection.transportID)
            guard shareTaskRecord.statusQuery == query,
                  shareTaskHostID == remote.savedPairingHostID,
                  shareTaskFingerprint == remote.savedPairingFingerprint else { return }
            try shareTaskRecord.observe(status)
            macImportStatusMessage = "Mac 状态已更新 · " + Date(timeIntervalSince1970: Double(status.checkedAtMs) / 1_000)
                .formatted(date: .omitted, time: .standard)
        } catch {
            guard shareTaskRecord.statusQuery == query else { return }
            shareTaskRecord.task.macStatus = nil
            macImportStatusMessage = "暂未取得 Mac 最新状态：\(error.localizedDescription)"
        }
    }

    private func cleanupQueue() -> LocalShareCleanupQueue? {
        shareTaskJournal.map { .init(directory: $0.directory.appendingPathComponent("AutomaticCleanup")) }
    }
    private func saveCleanupRecord(_ record: LocalShareTaskRecord) throws {
        if record.taskID == shareTaskRecord.taskID {
            try saveShareTaskRecord(record); shareTaskRecord = record
            if let queue = cleanupQueue(), try queue.contains(record.taskID) { try queue.save(record) }
        } else {
            guard let queue = cleanupQueue() else { throw LocalShareTaskRecoveryError.unavailable }
            try queue.save(record)
        }
    }
    var automaticCleanupMessage: String? {
        guard let state = shareTaskRecord.automaticCleanup, shareTask.phase == .received else { return nil }
        switch state.phase {
        case .complete: return "自动收尾完成 · Mac 图库可继续浏览"
        case .running: return "正在核验并自动收尾…"
        case .pending: return "Mac 完成导入后将自动收尾"
        case .deferred:
            return state.reason == .connectionUnavailable ? "自动收尾已延期 · 等待连接原 Mac" : "自动收尾已延期 · 稍后重试，已导入图库不受影响"
        }
    }
    func advanceAutomaticCleanup(_ remote: RemoteCompanionModel) async {
        guard !exportCleanupBusy, shareTaskPersistenceError == nil,
              shareTask.phase != .running, shareTask.phase != .pausing,
              UIApplication.shared.applicationState == .active, !Task.isCancelled else { return }
        var next = shareTaskRecord
        let nonce = next.beginAutomaticCleanup(nowMs: Int64(Date().timeIntervalSince1970 * 1000),
            connected: remote.isConnected, ready: shareTask.macStatus?.phase == .browsable)
        if next.automaticCleanup != shareTaskRecord.automaticCleanup {
            do { try saveShareTaskRecord(next); shareTaskRecord = next }
            catch { return }
        }
        if let nonce {
            await releaseExportPayload(remote, automaticNonce: nonce)
        } else if remote.isConnected {
            do {
                guard var queued = try cleanupQueue()?.next(hostID: remote.savedPairingHostID,
                    fingerprint: remote.savedPairingFingerprint, nowMs: Int64(Date().timeIntervalSince1970 * 1000)),
                      queued.statusQuery != nil else { return }
                if let nonce = queued.beginAutomaticCleanup(nowMs: Int64(Date().timeIntervalSince1970 * 1000), connected: true, ready: true) {
                    try saveCleanupRecord(queued)
                    await releaseExportPayload(remote, automaticNonce: nonce, queuedRecord: queued)
                }
            } catch { exportCleanupMessage = "先前任务收尾已延期：\(error.localizedDescription)" }
        }
    }

    func releaseExportPayload(_ remote: RemoteCompanionModel, automaticNonce: UUID? = nil,
                              queuedRecord: LocalShareTaskRecord? = nil) async {
        let cleanupRecord = queuedRecord ?? shareTaskRecord
        guard !exportCleanupBusy, let query = cleanupRecord.statusQuery,
              let name = cleanupRecord.exportStagingName else { return }
        exportCleanupBusy = true
        exportCleanupMessage = "正在核验 Mac 最终副本…"
        defer { exportCleanupBusy = false }
        do {
            guard cleanupRecord.hostID == remote.savedPairingHostID,
                  cleanupRecord.fingerprint == remote.savedPairingFingerprint else { throw LocalShareTaskRecoveryError.bindingChanged }
            let connection = try remote.importStatusConnection()
            let nonce = automaticNonce ?? UUID()
            let receipt: RemoteExportCleanupReceipt
            if automaticNonce != nil {
                receipt = try await connection.client.automaticCleanup(query, nonce: nonce,
                    hostID: connection.hostID, deviceID: connection.deviceID)
            } else {
                receipt = try await connection.client.exportCleanupReceipt(query, nonce: nonce,
                    hostID: connection.hostID, deviceID: connection.deviceID)
            }
            try Task.checkCancellation()
            guard UIApplication.shared.applicationState == .active else { throw CancellationError() }
            try remote.validateImportStatusConnection(hostID: connection.hostID,
                deviceID: connection.deviceID, transportID: connection.transportID)
            guard queuedRecord != nil || (shareTaskRecord.statusQuery == query && shareTaskRecord.exportStagingName == name) else {
                throw LocalShareTaskRecoveryError.bindingChanged
            }
            let parent = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false).appendingPathComponent("LocalLibrary/MigrationStreaming")
            let root = parent.appendingPathComponent(name)
            exportCleanupMessage = "正在释放已核验的导出暂存…"
            let work = Task.detached(priority: .utility) {
                try ImageAllMigrationExportCleanup.release(root: root, query: query,
                    hostID: connection.hostID, deviceID: connection.deviceID, nonce: nonce, receipt: receipt)
            }
            let result = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            if let automaticNonce {
                var next = queuedRecord ?? shareTaskRecord
                next.finishAutomaticCleanup(automaticNonce, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
                try saveCleanupRecord(next)
            }
            exportCleanupMessage = result.alreadyReleased ? "导出暂存已收尾，Mac 图库可继续浏览。" :
                "导出暂存收尾完成，释放 \(ByteCountFormatter.string(fromByteCount: result.logicalBytesReleased, countStyle: .file))。"
        } catch {
            if let automaticNonce {
                var next = queuedRecord ?? shareTaskRecord
                let reason: ImageAllAutomaticCleanup.Reason = !remote.isConnected ? .connectionUnavailable :
                    (error is CancellationError ? .interrupted : .failed)
                next.finishAutomaticCleanup(automaticNonce, failure: reason, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
                do { try saveCleanupRecord(next) } catch { /* Persistence error already surfaced. */ }
            }
            exportCleanupMessage = "收尾暂未完成，可重试：\(error.localizedDescription)"
        }
        await refreshMacImportStatus(remote)
    }

    /// Explicit metadata-only adoption. No Photos fetch, begin, seal or upload.
    func associatePreviouslyPublishedTask(_ remote: RemoteCompanionModel, target: String) async {
        guard let store, shareTask.phase == .idle, !legacyAssociationInProgress,
              shareTaskPersistenceError == nil, !shareSelectionEditing else { return }
        legacyAssociationInProgress = true
        legacyAssociationMessage = "正在读取手机旧清单并核对 Mac 发布记录，不上传原件…"
        defer { legacyAssociationInProgress = false }
        do {
            let taskID = shareTaskRecord.taskID
            let ids = Set(sharedSelections.map(\.id)), albums = shareIncludeAlbumCatalog
            let fingerprint = remote.savedPairingFingerprint
            let connection = try remote.importStatusConnection()
            let install = try await store.installID(), version = try await store.shareSelectionVersion()
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: false)
            let parent = support.appendingPathComponent("LocalLibrary/MigrationStreaming")
            let candidates = try await Task.detached(priority: .utility) {
                var result: [LocalShareLegacyCandidate] = []
                try ImageAllMigrationStreamRecord.visitExisting(in: parent) { record in
                    if let candidate = try LocalShareLegacyCandidate(record: record,
                        hostID: connection.hostID, deviceID: connection.deviceID,
                        sourceInstallID: install, sourceEpoch: version.sourceEpoch,
                        selectionIDs: ids, includeAlbumCatalog: albums) {
                        result.append(candidate)
                    }
                }
                return result
            }.value
            guard candidates.count == 1, let candidate = candidates.first else {
                legacyAssociationMessage = candidates.isEmpty
                    ? "没有找到与当前选择、相簿选项及原 Mac 身份匹配的已封存批次。未新建或上传；请保留旧记录核对。"
                    : "找到多个匹配的旧批次，不能自动选择。未新建或上传；请先核对批次。"
                return
            }
            let status = try await connection.client.importTaskStatus(candidate.query(taskID: taskID))
            try remote.validateImportStatusConnection(hostID: connection.hostID,
                deviceID: connection.deviceID, transportID: connection.transportID)
            guard shareTask.phase == .idle, shareTaskRecord.taskID == taskID,
                  Set(sharedSelections.map(\.id)) == ids, shareIncludeAlbumCatalog == albums,
                  remote.savedPairingFingerprint == fingerprint,
                  try await store.installID() == install,
                  try await store.shareSelectionVersion() == version else {
                throw LocalShareTaskRecoveryError.bindingChanged
            }
            var record = shareTaskRecord
            try record.associate(candidate, status: status, selectionIDs: ids, includeAlbumCatalog: albums,
                hostID: connection.hostID.uuidString, fingerprint: fingerprint, target: target)
            try saveShareTaskRecord(record)
            shareTaskRecord = record
            legacyAssociationMessage = nil
            macImportStatusMessage = "已关联旧批次 · 核对 \(candidate.receipt.itemCount) 项已发布；原件新增上传 0。"
        } catch {
            legacyAssociationMessage = "未关联旧批次：\(error.localizedDescription) 未启动传输，也未修改 Mac 照片。"
        }
    }

    private let store: LocalLibraryStore?
    private let favoriteSource: any LocalFavoriteSource
    private let browser: LocalLibraryBrowser?
    private var photoChanges: LocalPhotoChangeObserver?
    private let photoVisibilityGeneration = LocalLibraryVisibilityGeneration()

    func validateCleanupRecheckIdentity(_ request: RemotePhoneCleanupRecheck) async throws {
        guard let store else { throw RemoteAPIError(code: .internalError, message: "本机资料库不可用") }
        let install = try await store.installID()
        let scope = try await store.shareSelectionVersion()
        guard request.isValid, request.sourceInstallID == install,
              request.sourceEpoch == scope.sourceEpoch, request.scopeRevision == scope.revision else {
            throw RemoteAPIError(code: .conflict, message: "手机来源身份或分享范围已变化，请重新归档与预检")
        }
    }

    init(favoriteSource: any LocalFavoriteSource = PhotoKitLocalFavoriteSource(),
         browsingSource: any LocalLibraryBrowsingSource = PhotoKitLocalBrowsingSource()) {
        self.favoriteSource = favoriteSource
        do {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let opened = try LocalLibraryStore(url: root.appendingPathComponent("LocalLibrary/local.sqlite"))
            store = opened
            browser = LocalLibraryBrowser(store: opened, source: browsingSource)
            do {
                let journal = LocalShareTaskJournal(directory: root.appendingPathComponent("LocalLibrary"))
                shareTaskJournal = journal
                if let restored = try journal.load() {
                    try journal.save(restored)
                    shareTaskRecord = restored
                }
            } catch {
                shareTaskPersistenceError = error.localizedDescription
                errorMessage = shareTaskPersistenceError
            }
        } catch {
            store = nil
            browser = nil
            errorMessage = "本机资料库无法打开：\(error.localizedDescription)"
        }
        photoChanges = LocalPhotoChangeObserver(generation: photoVisibilityGeneration) { [weak self] in
            Task { await self?.refresh() }
        }
    }

    #if DEBUG
    /// Explicit, metadata-only diagnosis of the retained selection. Never reads
    /// resources or changes selection; report only aggregate counts, not locators.
    func diagnoseSelectedAvailability() async -> [String: Any] {
        do {
            guard let store else { return ["error": "localStoreUnavailable"] }
            let selected = try await store.sharedSelections()
            let permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            var report: [String: Any] = ["selectedCount": selected.count,
                "authorization": permission.rawValue, "sourceBytesRead": false,
                "macUploads": false, "selectionChanged": false]
            guard permission == .authorized || permission == .limited else { return report }
            let identifiers = selected.map(\.localIdentifier)
            let normal = PHFetchOptions()
            normal.includeHiddenAssets = false
            normal.includeAssetSourceTypes = .typeUserLibrary
            let eligible = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: normal)
            var eligibleIDs = Set<String>()
            eligible.enumerateObjects { asset, _, _ in eligibleIDs.insert(asset.localIdentifier) }
            let missing = identifiers.filter { !eligibleIDs.contains($0) }
            let metadata = PHFetchOptions()
            metadata.includeHiddenAssets = true
            metadata.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
            let returned = PHAsset.fetchAssets(withLocalIdentifiers: missing, options: metadata)
            var hidden = 0, nonUserLibrary = 0, returnedUserLibrary = 0
            returned.enumerateObjects { asset, _, _ in
                if asset.isHidden { hidden += 1 }
                if !asset.sourceType.contains(.typeUserLibrary) { nonUserLibrary += 1 }
                if !asset.isHidden && asset.sourceType.contains(.typeUserLibrary) { returnedUserLibrary += 1 }
            }
            report["eligibleCount"] = eligibleIDs.count
            report["missingFromImportFetch"] = missing.count
            report["hiddenCount"] = hidden
            report["otherSourceTypeCount"] = nonUserLibrary
            report["returnedUnhiddenUserLibraryCount"] = returnedUserLibrary
            report["notReturnedByPhotoKitCount"] = missing.count - returned.count
            report["authorizationAfter"] = PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue
            return report
        } catch { return ["errorDomain": (error as NSError).domain, "errorCode": (error as NSError).code] }
    }

    func diagnoseImportPreparation(verifyOnePendingLocalResource: Bool = false) async -> [String: Any] {
        do {
            guard let store else { return ["error": "localStoreUnavailable"] }
            let selected = try await store.sharedSelections()
            let options = PHFetchOptions()
            options.includeHiddenAssets = false; options.includeAssetSourceTypes = .typeUserLibrary
            guard authorization == .authorized || authorization == .limited else { return ["error": "photosNotAuthorized"] }
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: selected.map(\.localIdentifier), options: options)
            var visible = Set<String>()
            fetched.enumerateObjects { asset, _, _ in visible.insert(asset.localIdentifier) }
            let snapshot = try await store.sharedSnapshot(visibleIdentifiers: visible)
            return try await LocalPhotoArchiveExporter.preparationDiagnostics(
                snapshot: snapshot, verifyOnePendingLocalResource: verifyOnePendingLocalResource)
        } catch { return ["error": error.localizedDescription] }
    }
    #endif

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await refresh()
    }

    func exportLocalBackup() async throws -> LocalLibraryBackupReport {
        guard let store else { throw LocalFavoriteSourceError.storeUnavailable }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAll-Facts-\(UUID().uuidString)", isDirectory: true)
        return try await store.exportBackup(to: root.appendingPathComponent("ImageAll-LocalFacts.sqlite"))
    }

    func refresh() async {
        // Hide the old projection immediately, including while SQLite work yields.
        assets = []
        hasMore = false
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        do { try await browser?.refresh() }
        catch { errorMessage = "本机资料保存失败：\(error.localizedDescription)" }
        await publishBrowseProjection()
    }

    func loadMore() async {
        do { try await browser?.loadMore() }
        catch { errorMessage = "本机资料保存失败：\(error.localizedDescription)" }
        await publishBrowseProjection()
    }

    private func publishBrowseProjection() async {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authorization == .authorized || authorization == .limited {
            assets = browser?.assets ?? []
            hasMore = browser?.hasMore ?? false
        } else {
            browser?.invalidate()
            assets = []
            hasMore = false
        }
        await reloadFacts()
    }

    func createTag(_ name: String) async {
        guard let store else { return }
        do {
            _ = try await store.createTag(name: name)
            await reloadFacts()
        } catch { errorMessage = "创建标签失败：\(error.localizedDescription)" }
    }

    func createCollection(_ name: String) async {
        guard let store else { return }
        do {
            _ = try await store.createCollection(name: name)
            await reloadFacts()
        } catch { errorMessage = "创建集合失败：\(error.localizedDescription)" }
    }

    func decisions(for asset: LocalAsset) async -> [UUID: LocalDecision] {
        do { return try await store?.decisions(assetID: asset.id) ?? [:] }
        catch { errorMessage = "读取标签失败：\(error.localizedDescription)"; return [:] }
    }

    func memberships(for asset: LocalAsset) async -> Set<UUID> {
        do { return try await store?.memberships(assetID: asset.id) ?? [] }
        catch { errorMessage = "读取集合失败：\(error.localizedDescription)"; return [] }
    }

    func setDecision(_ decision: LocalDecision, asset: LocalAsset, tag: LocalTag) async {
        guard let store else { return }
        do {
            try await store.setDecision(assetID: asset.id, tagID: tag.id, decision: decision)
            await reloadFacts()
        } catch { errorMessage = "保存标签失败：\(error.localizedDescription)" }
    }

    func tagUndoCandidates(for asset: LocalAsset) async -> [UUID: UUID] {
        guard let store else { return [:] }
        return (try? await store.tagUndoCandidates(assetID: asset.id)) ?? [:]
    }

    func undoTagDecision(_ operationID: UUID) async {
        guard let store else { return }
        do {
            try await store.undoTagDecision(operationID: operationID)
            await reloadFacts()
        } catch LocalLibraryError.undoUnavailable {
            errorMessage = "这次标签修改已不能撤销：本机或 Mac 状态已有变化，或同步尚待完成。请核对当前决定后重新编辑。"
        } catch { errorMessage = "撤销标签失败：\(error.localizedDescription)" }
    }

    func setMembership(_ included: Bool, asset: LocalAsset, collection: LocalCollection) async {
        guard let store else { return }
        do {
            try await store.setMembership(assetID: asset.id, collectionID: collection.id, included: included)
            await reloadFacts()
        } catch { errorMessage = "保存集合失败：\(error.localizedDescription)" }
    }

    func collectionUndoCandidates(for asset: LocalAsset) async -> [UUID: UUID] {
        guard let store else { return [:] }
        return (try? await store.collectionUndoCandidates(assetID: asset.id)) ?? [:]
    }

    func undoMembership(_ operationID: UUID) async {
        guard let store else { return }
        do {
            try await store.undoMembership(operationID: operationID)
            await reloadFacts()
        } catch LocalLibraryError.undoUnavailable {
            errorMessage = "这次集合修改已不能撤销：本机或 Mac 状态已有变化，或同步尚待完成。请核对当前成员状态后重新编辑。"
        } catch { errorMessage = "撤销集合修改失败：\(error.localizedDescription)" }
    }

    func prepareBulkSharePreview() async throws -> LocalBulkSharePreview {
        guard let browser else { throw LocalFavoriteSourceError.storeUnavailable }
        assets = []
        hasMore = false
        return try await browser.prepareBulkSharePreview()
    }

    func confirmBulkSharePreview(_ preview: LocalBulkSharePreview) async throws -> Int {
        guard let browser else { throw LocalFavoriteSourceError.storeUnavailable }
        let added = try await browser.confirmBulkSharePreview(preview)
        await refresh()
        return added
    }

    private struct CompletedSelectionLedger: Codable {
        let installID: UUID
        let epoch: UUID
        var ids: Set<UUID>
    }
    private var newBatchPreviewTaskID: UUID?
    private func newBatchLedger() throws -> (URL, CompletedSelectionLedger) {
        guard shareTask.phase == .received, let install = shareTaskRecord.sourceInstallID,
              let epoch = shareTaskRecord.sourceEpoch, let journal = shareTaskJournal else {
            throw LocalShareTaskRecoveryError.bindingChanged
        }
        let url = journal.directory.appendingPathComponent("completed-selection.json")
        var ledger = CompletedSelectionLedger(installID: install, epoch: epoch, ids: [])
        if FileManager.default.fileExists(atPath: url.path) {
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw LocalShareTaskRecoveryError.invalidRecord }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? file.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 16 * 1024 * 1024,
                  let data = try file.read(upToCount: 16 * 1024 * 1024 + 1), data.count <= 16 * 1024 * 1024 else {
                throw LocalShareTaskRecoveryError.invalidRecord
            }
            ledger = try JSONDecoder().decode(CompletedSelectionLedger.self, from: data)
            guard ledger.installID == install, ledger.epoch == epoch else { throw LocalShareTaskRecoveryError.bindingChanged }
        }
        ledger.ids.formUnion(shareTaskRecord.selectionIDs)
        return (url, ledger)
    }
    func prepareNewBatchPreview() async throws -> LocalBulkSharePreview {
        guard authorization == .authorized, !exportCleanupBusy, !shareSelectionEditing, let browser, let store else {
            throw LocalShareTaskRecoveryError.unavailable
        }
        let (_, ledger) = try newBatchLedger()
        guard try await store.installID() == ledger.installID,
              try await store.shareSelectionVersion().sourceEpoch == ledger.epoch else {
            throw LocalShareTaskRecoveryError.bindingChanged
        }
        newBatchPreviewTaskID = shareTaskRecord.taskID
        return try await browser.prepareBulkSharePreview(excludingAssetIDs: ledger.ids)
    }
    func confirmNewBatchPreview(_ preview: LocalBulkSharePreview) async throws -> Int {
        guard !exportCleanupBusy, !shareSelectionEditing, let browser, let journal = shareTaskJournal,
              newBatchPreviewTaskID == shareTaskRecord.taskID else { throw LocalShareTaskRecoveryError.bindingChanged }
        shareSelectionEditing = true
        defer { shareSelectionEditing = false; newBatchPreviewTaskID = nil }
        let (ledgerURL, ledger) = try newBatchLedger()
        // Preserve the original task before replacing selection or the visible task.
        let saved = LocalShareTaskJournal(directory: journal.directory.appendingPathComponent("CompletedTasks")
            .appendingPathComponent(shareTaskRecord.taskID.uuidString.lowercased()))
        try FileManager.default.createDirectory(at: saved.directory, withIntermediateDirectories: true)
        try saved.save(shareTaskRecord)
        try JSONEncoder().encode(ledger).write(to: ledgerURL, options: [.atomic, .completeFileProtection])
        let count = try await browser.confirmBulkSharePreview(preview, replacingSelection: true)
        resetReceivedShareTask()
        guard shareTask.phase == .idle else { throw LocalShareTaskRecoveryError.unavailable }
        await reloadFacts()
        return count
    }
    func cancelBulkSharePreview() { browser?.cancelBulkSharePreview(); newBatchPreviewTaskID = nil }

    func renamePrivateCollection(_ collection: LocalCollection, revision: Int64, name: String) async throws {
        guard let store else { throw LocalFavoriteSourceError.storeUnavailable }
        do {
            try await store.renamePrivateCollection(collectionID: collection.id, expectedName: collection.name,
                                                    expectedRevision: revision, newName: name)
            await reloadFacts()
        } catch {
            await reloadFacts()
            throw error
        }
    }

    func prepareCollectionRename(collectionID: UUID, name: String) async throws -> LocalCollectionRenameCommand {
        guard let store else { throw LocalFavoriteSourceError.storeUnavailable }
        let visible = try await observedSharedVisibleIdentifiers()
        let command = try await store.prepareCollectionRename(collectionID: collectionID, newName: name,
                                                              visibleIdentifiers: visible)
        await reloadFacts()
        return command
    }

    func sendCollectionRename(_ command: LocalCollectionRenameCommand, remote: RemoteCompanionModel) async throws {
        guard let store else { throw LocalFavoriteSourceError.storeUnavailable }
        do {
            let visible = try await observedSharedVisibleIdentifiers()
            try await store.validateCollectionRename(command, visibleIdentifiers: visible)
            let receipt = try await remote.renameLocalLibraryCollection(command)
            for _ in 0..<20 {
                let cursor = try await store.sharedCollectionChangeCursor()
                if cursor >= receipt.resultingChangeCursor { break }
                let page = try await remote.fetchLocalLibraryCollectionChanges(sourceEpoch: command.sourceEpoch,
                    scopeRevision: command.scopeRevision, afterCursor: cursor)
                _ = try await store.applySharedCollectionChanges(hostID: page.hostID, deviceID: page.deviceID,
                    sourceEpoch: page.sourceEpoch, scopeRevision: page.scopeRevision, afterCursor: cursor,
                    changes: page.changes.map {
                        LocalSharedCollectionChange(sequence: $0.sequence, assetID: $0.assetID,
                            collectionID: $0.collectionID, collectionName: $0.collectionName,
                            included: $0.included, fieldRevision: $0.fieldRevision,
                            renamedFrom: $0.renamedFrom, createdCollectionID: $0.createdCollectionID)
                    }, nextCursor: page.nextCursor)
                if !page.hasMore { break }
            }
            try await store.completeCollectionRename(command, resultingCursor: receipt.resultingChangeCursor)
            await reloadFacts()
        } catch {
            await reloadFacts()
            throw error
        }
    }

    func abandonCollectionRename(_ command: LocalCollectionRenameCommand) async {
        do {
            try await store?.abandonCollectionRename(commandID: command.commandID)
            await reloadFacts()
        } catch { errorMessage = "停止改名重试失败：\(error.localizedDescription)" }
    }

    func setShared(_ shared: Bool, assetID: UUID, localIdentifier: String) async {
        guard let store else { return }
        do {
            try await store.setShared(assetID: assetID, shared: shared)
            if let index = assets.firstIndex(where: { $0.id == assetID }),
               let refreshed = try await store.assets(visibleIdentifiers: [localIdentifier]).first {
                assets[index] = refreshed
            }
            await reloadFacts()
        } catch {
            errorMessage = "更新待分享范围失败：\(error.localizedDescription)"
        }
    }

    func removeSharedSelections(_ ids: Set<UUID>) async -> Int {
        guard let store, !shareSelectionEditing, shareTask.phase != .running, shareTask.phase != .pausing else { return 0 }
        shareSelectionEditing = true
        defer { shareSelectionEditing = false }
        var removed = 0
        for id in ids {
            do { try await store.setShared(assetID: id, shared: false); removed += 1 }
            catch { errorMessage = "部分项目未移出待分享：\(error.localizedDescription)"; break }
        }
        await reloadFacts()
        return removed
    }

    func restoreShareTaskSelection() async {
        guard let store, !shareSelectionEditing, shareTask.phase == .paused || shareTask.phase == .failed else { return }
        shareSelectionEditing = true
        defer { shareSelectionEditing = false }
        let current = Set(sharedSelections.map(\.id))
        do {
            for id in current.subtracting(shareTaskSelectionIDs) { try await store.setShared(assetID: id, shared: false) }
            for id in shareTaskSelectionIDs.subtracting(current) { try await store.setShared(assetID: id, shared: true) }
            shareIncludeAlbumCatalog = shareTaskAlbumCatalog
        } catch { errorMessage = "未完全恢复任务范围，请核对选择：\(error.localizedDescription)" }
        await reloadFacts()
    }

    func prepareSharedSnapshotRecoveringReceipt(
        from remoteModel: RemoteCompanionModel
    ) async throws -> LocalSharedSnapshot {
        guard let store else { throw LocalFavoriteSourceError.storeUnavailable }
        var legacyPending: LocalSharedSnapshot?
        if let pending = try await store.pendingSharedSnapshot() {
            let lookup = try await remoteModel.lookupLocalLibrarySnapshotReceipt(pending)
            if let receipt = lookup.receipt {
                guard let importedIDs = receipt.importedAssetIDs else {
                    throw LocalLibraryError.syncIdentityChanged
                }
                try await store.acknowledgeSharedSnapshot(
                    pending, hostID: receipt.hostID, deviceID: receipt.deviceID,
                    importedAssetIDs: importedIDs
                )
            } else if !lookup.supported {
                legacyPending = pending
            }
        }
        // Permission may change while the receipt query is in flight.
        let currentVisible = try await observedSharedVisibleIdentifiers()
        if let legacyPending {
            let current = try await store.sharedSnapshot(visibleIdentifiers: currentVisible)
            guard legacyPending.installID == current.installID,
                  legacyPending.sourceEpoch == current.sourceEpoch,
                  legacyPending.scopeRevision == current.scopeRevision,
                  legacyPending.selectedAssetIDs == current.selectedAssetIDs,
                  Set(legacyPending.assets.map(\.id)) == Set(current.assets.map(\.id)) else {
                throw RemoteAPIError(
                    code: .conflict,
                    message: "Mac 版本不支持查询丢失的快照回执；当前权限或分享范围已变化，请先升级 Mac 后重试"
                )
            }
        }
        return try await store.prepareSharedSnapshot(
            visibleIdentifiers: currentVisible
        )
    }

    func validateSharedSnapshotScope(_ snapshot: LocalSharedSnapshot) async throws {
        guard let store else { throw LocalFavoriteSourceError.storeUnavailable }
        let visible = try await observedSharedVisibleIdentifiers()
        try await store.validateSharedSnapshotScope(snapshot, visibleIdentifiers: visible)
    }

    private func sharedVisibleIdentifiersForTransfer(_ snapshot: LocalSharedSnapshot) throws -> Set<String> {
        let permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard permission == .authorized || permission == .limited else {
            throw LocalArchiveExportError.selectionNotVisible
        }
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAssetSourceTypes = .typeUserLibrary
        let result = PHAsset.fetchAssets(withLocalIdentifiers: snapshot.assets.map(\.localIdentifier), options: options)
        var visible = Set<String>()
        result.enumerateObjects { asset, _, _ in visible.insert(asset.localIdentifier) }
        return visible
    }

    private func makeMigrationFactSnapshot() async throws -> LocalSharedSnapshot {
        guard let store else { throw LocalFavoriteSourceError.storeUnavailable }
        let identifiers = try await observedSharedVisibleIdentifiers()
        return try await store.migrationFactSnapshot(visibleIdentifiers: identifiers)
    }

    private func observedSharedVisibleIdentifiers() async throws -> Set<String> {
        guard let store else { throw LocalFavoriteSourceError.storeUnavailable }
        let selections = try await store.sharedSelections()
        var visible: [PHAsset] = []
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authorization == .authorized || authorization == .limited {
            let options = PHFetchOptions()
            options.includeHiddenAssets = false
            options.includeAssetSourceTypes = .typeUserLibrary
            let result = PHAsset.fetchAssets(
                withLocalIdentifiers: selections.map(\.localIdentifier), options: options
            )
            result.enumerateObjects { asset, _, _ in visible.append(asset) }
        }
        try await store.observe(visible.map {
            LocalObservedAsset(
                localIdentifier: $0.localIdentifier,
                kind: $0.mediaType == .video ? "video" : "image",
                creationDate: $0.creationDate,
                isFavorite: $0.isFavorite
            )
        })
        return Set(visible.map(\.localIdentifier))
    }

    /// An explicit, local-only export of the current selected scope. A reduced
    /// Photos permission must never silently turn this into a smaller archive.
    func exportSelectedArchive(includeAlbumCatalog: Bool = false) async throws -> (URL, ImageAllMigrationVerification) {
        let snapshot = try await makeMigrationFactSnapshot()
        guard !snapshot.selectedAssetIDs.isEmpty else {
            throw LocalArchiveExportError.emptySelection
        }
        guard Set(snapshot.selectedAssetIDs) == Set(snapshot.assets.map(\.id)) else {
            throw LocalArchiveExportError.selectionNotVisible
        }
        let result = try await LocalPhotoArchiveExporter.export(snapshot: snapshot, includeAlbumCatalog: includeAlbumCatalog)
        do {
            let current = try await makeMigrationFactSnapshot()
            guard current.sourceEpoch == snapshot.sourceEpoch,
                  current.scopeRevision == snapshot.scopeRevision,
                  Set(current.selectedAssetIDs) == Set(snapshot.selectedAssetIDs),
                  Set(current.assets.map(\.id)) == Set(snapshot.assets.map(\.id)) else {
                throw LocalArchiveExportError.selectionChanged
            }
            if result.1.isComplete {
                let facts = try LocalMigrationFactExporter.export(snapshot: current)
                defer { try? FileManager.default.removeItem(at: facts) }
                try LocalMigrationFactExporter.attach(facts, to: result.0)
                return (result.0, try ImageAllMigrationArchive.verify(at: result.0))
            }
            return result
        } catch {
            try? FileManager.default.removeItem(at: result.0)
            throw error
        }
    }

    /// Explicit resource-first network export. Each local scratch resource is
    /// released only after the paired receiver independently confirms its bytes.
    /// One user action delivers the selected media and its organization facts
    /// through the existing paired protocol; conflicts never silently proceed.
    func importSelectedPhotos(to remote: RemoteCompanionModel, includeAlbumCatalog: Bool = false, sealVerifiedSubset: Bool = false) async throws -> ImageAllMigrationTransferSealReceipt {
        guard !sharedSelections.isEmpty else { throw LocalArchiveExportError.emptySelection }
        guard shareTask.phase == .running, shareTaskPersistenceError == nil else {
            throw LocalShareTaskRecoveryError.unavailable
        }
        remote.beginMigrationProgress(intent: sealVerifiedSubset ? .sealReceived : .transferSelection)
        remote.recordMigrationTask(id: shareTaskRecord.taskID)
        defer { remote.finishMigrationProgress() }
        let initialConnection = try remote.migrationStreamingConnection()
        guard try await initialConnection.client.fetchCapabilities().migrationHandoffVersion == 1 else {
            throw RemoteAPIError(code: .conflict, message: "请先更新 Mac ImageAll，再开始传输。新版支持传完拔线，由 Mac 独立处理。")
        }
        if let id = shareTaskRecord.migrationID, let name = shareTaskRecord.exportStagingName {
            let prior = try await initialConnection.client.migrationHandoffReceipt(migrationID: id)
            if let prior {
                let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: false)
                let root = support.appendingPathComponent("LocalLibrary/MigrationStreaming").appendingPathComponent(name)
                let lease = try ImageAllMigrationExportCheckpoint(streamingRoot: root)
                defer { lease.close() }
                let file = try FileHandle(forReadingFrom: root.appendingPathComponent("manifest.jsonl"))
                defer { try? file.close() }
                var digest = SHA256()
                while let bytes = try autoreleasepool(invoking: { try file.read(upToCount: 64 * 1024) }), !bytes.isEmpty {
                    digest.update(data: bytes)
                }
                guard prior.hostProcessingVersion == 1, prior.migrationID == lease.migrationID,
                      prior.manifestSHA256 == digest.finalize().map({ String(format: "%02x", $0) }).joined() else {
                    throw LocalShareTaskRecoveryError.bindingChanged
                }
                return prior
            }
        }
        if includeAlbumCatalog {
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
                throw RemoteAPIError(code: .conflict, message: "保存用户相簿目录需要完整照片权限，请在系统设置中授权或关闭相簿目录选项。")
            }
            try remote.requireMigrationAlbumCatalogSupport()
        }
        remote.setMigrationPhase("读取所选目录与核对上次回执")
        let snapshot = try await prepareSharedSnapshotRecoveringReceipt(from: remote)
        try bindShareTaskSource(snapshot)
        remote.setMigrationPhase("发送目录与整理信息，等待 Mac 回执")
        let receipt = try await remote.submitLocalLibrarySnapshot(snapshot) {
            try await self.validateSharedSnapshotScope(snapshot)
        }
        remote.setMigrationPhase("同步红心、标签与集合")
        let result = try await completeSharedSync(snapshot: snapshot, receipt: receipt, remoteModel: remote)
        let readiness = ImageAllPhoneImportReadiness(conflicts: result.conflicts,
            remainingOperations: result.remaining, deferredOperations: result.deferred,
            hasMoreTagChanges: result.pullHasMore, hasMoreCollectionChanges: result.collectionPullHasMore,
            hasMoreFavoriteChanges: result.favoritePullHasMore)
        guard readiness.canStartMediaImport else {
            throw RemoteAPIError(code: .conflict,
                message: "目录已提交，整理信息还有冲突、待处理操作或后续变化页。请先到“更多操作”同步并处理整理信息冲突，再重试导入；原件尚未传输。")
        }
        try Task.checkCancellation()
        try remote.validateMigrationStreamingConnection(hostID: initialConnection.hostID,
            deviceID: initialConnection.deviceID, transportID: initialConnection.transportID)
        remote.setMigrationPhase("核对续传目录与原件")
        return try await streamSelectedArchive(to: remote, includeAlbumCatalog: includeAlbumCatalog,
            expectedScope: snapshot, expectedTransportID: initialConnection.transportID, sealVerifiedSubset: sealVerifiedSubset)
    }

    func streamSelectedArchive(to remote: RemoteCompanionModel, includeAlbumCatalog: Bool = false,
                               expectedScope: LocalSharedSnapshot? = nil, expectedTransportID: UUID? = nil, sealVerifiedSubset: Bool = false) async throws -> ImageAllMigrationTransferSealReceipt {
        let connection = try remote.migrationStreamingConnection()
        guard expectedTransportID == nil || expectedTransportID == connection.transportID else { throw ImageAllUSBError.disconnected }
        if includeAlbumCatalog { try remote.requireMigrationAlbumCatalogSupport() }
        let snapshot = try await makeMigrationFactSnapshot()
        if let expectedScope {
            guard snapshot.installID == expectedScope.installID,
                  snapshot.sourceEpoch == expectedScope.sourceEpoch,
                  snapshot.scopeRevision == expectedScope.scopeRevision,
                  Set(snapshot.selectedAssetIDs) == Set(expectedScope.selectedAssetIDs) else {
                throw LocalArchiveExportError.selectionChanged
            }
        }
        guard !snapshot.selectedAssetIDs.isEmpty else { throw LocalArchiveExportError.emptySelection }
        let availability = try LocalMigrationAvailability(snapshot: snapshot)
        guard availability.availableCount > 0 else { throw LocalArchiveExportError.selectionNotVisible }
        remote.setMigrationAvailability(available: availability.availableCount, pending: availability.pendingCount)
        guard let store else { throw LocalFavoriteSourceError.storeUnavailable }
        let scopeValidator = LocalSharedSnapshotScopeValidator(snapshot: snapshot, store: store,
            generation: photoVisibilityGeneration, visibleIdentifiers: { [self] in
                try await self.sharedVisibleIdentifiersForTransfer(snapshot)
            })
        let check: @Sendable () async throws -> Void = { [remote, self] in
            try Task.checkCancellation()
            guard await self.shareTaskPersistenceError == nil else { throw LocalShareTaskRecoveryError.unavailable }
            try await remote.validateMigrationStreamingConnection(
                hostID: connection.hostID, deviceID: connection.deviceID, transportID: connection.transportID)
            let permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard permission == .authorized || permission == .limited else {
                throw LocalArchiveExportError.selectionNotVisible
            }
            try await scopeValidator.validate(permissionVersion: permission.rawValue)
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == permission else {
                throw LocalArchiveExportError.selectionNotVisible
            }
            try await remote.validateMigrationStreamingConnection(
                hostID: connection.hostID, deviceID: connection.deviceID, transportID: connection.transportID)
        }
        let boundaryCheck: @Sendable () async throws -> Void = {
            try await check()
            let permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            try await scopeValidator.validate(permissionVersion: permission.rawValue, forceRefresh: true)
            try await check()
        }
        let transferClient = connection.client.recoveringMigrationRequests(
            beforeAttempt: check,
            accessToken: { rejected in
                try await remote.migrationAccessToken(rejected: rejected, hostID: connection.hostID,
                    deviceID: connection.deviceID, transportID: connection.transportID)
            },
            onRetry: { attempt in
                await remote.setMigrationPhase("连接短暂中断，正在自动重试（\(attempt)）")
            })
        return try await LocalPhotoArchiveExporter.stream(snapshot: snapshot, includeAlbumCatalog: includeAlbumCatalog, configuration: .init(
            destination: "\(connection.hostID.uuidString)|\(connection.deviceID.uuidString)",
            sealVerifiedSubset: sealVerifiedSubset,
            expectedMigrationID: shareTaskRecord.migrationID,
            reportItem: { index, total in remote.reportMigrationItem(index: index, total: total) },
            resumeCheckpoint: { [self] migrationID in
                try bindShareTaskMigration(migrationID)
                remote.setMigrationPhase("恢复 Mac 接收进度")
                try await boundaryCheck()
                _ = try await transferClient.beginMigrationTransfer(migrationID: migrationID,
                    sourceInstallID: snapshot.installID)
                let receipts = try await transferClient.migrationResumeCheckpoint(migrationID: migrationID,
                    deviceID: connection.deviceID, sourceInstallID: snapshot.installID, allowDurableCustody: true)
                try await check()
                remote.recordMigrationRecovery(id: migrationID, receiptCount: receipts.count)
                remote.setMigrationPhase("接收进度已恢复，完整性待核验")
                return receipts
            },
            beforeResource: {
                remote.setMigrationPhase("准备原件与校验")
                try await boundaryCheck()
            },
            beforeSourceRevalidation: { expectedBytes in
                remote.beginSourceRevalidation(expectedBytes: expectedBytes)
                try await boundaryCheck()
            },
            sourceRevalidationRead: { remote.recordSourceRevalidationRead($0) },
            sourceRevalidationVerified: { remote.finishSourceRevalidation() },
            verifyExistingResource: { migrationID, resource in
                guard let path = resource.relativePath, let size = resource.byteCount, let hash = resource.sha256 else {
                    throw LocalArchiveExportError.incompleteArchive
                }
                remote.setMigrationPhase("核对 Mac 接收进度，跳过手机重复导出")
                try await boundaryCheck()
                return try await transferClient.acceptMigrationResource(migrationID: migrationID,
                    deviceID: connection.deviceID, request: .init(relativePath: path, byteCount: size, sha256: hash))
            },
            uploadResource: { migrationID, file, resource in
                guard let path = resource.relativePath, let size = resource.byteCount,
                      let hash = resource.sha256 else { throw LocalArchiveExportError.incompleteArchive }
                try await boundaryCheck()
                remote.beginMigrationUpload()
                do {
                    _ = try await transferClient.uploadMigrationFile(
                        at: file, migrationID: migrationID, relativePath: path,
                        byteCount: size, sha256: hash, sourceInstallID: snapshot.installID, beforeChunk: check,
                        onCommittedBytes: { count in
                            await remote.setMigrationPhase("传输原件")
                            await remote.recordMigrationBytes(count)
                        })
                } catch {
                    remote.endMigrationUpload()
                    throw error
                }
                remote.endMigrationUpload()
                remote.setMigrationPhase("Mac 确认接收，完整核验将在交接后进行")
                try await boundaryCheck()
                let receipt = try await transferClient.acceptMigrationResource(
                    migrationID: migrationID, deviceID: connection.deviceID,
                    request: .init(relativePath: path, byteCount: size, sha256: hash))
                try await check()
                return receipt
            },
            finish: { [self] root, header, items in
                remote.setMigrationPhase("提交整理信息，交由 Mac 继续处理")
                try await boundaryCheck()
                let current = try await self.makeMigrationFactSnapshot()
                guard current.installID == header.sourceDeviceID, current.sourceEpoch == header.sourceEpoch,
                      current.scopeRevision == header.scopeRevision,
                      Set(current.selectedAssetIDs) == Set(header.retainedSelectionIDs ?? items.map(\.mediaID)),
                      Set(current.assets.map(\.id)) == Set(items.map(\.mediaID)) else {
                    throw LocalArchiveExportError.selectionChanged
                }
                let archivedFacts = try current.archiveSnapshot(mediaIDs: Set(items.map(\.mediaID)),
                    allowVerifiedSubset: sealVerifiedSubset)
                let facts = try LocalMigrationFactExporter.export(snapshot: archivedFacts)
                defer { try? FileManager.default.removeItem(at: facts) }
                _ = try ImageAllMigrationFacts.publish(from: facts, into: root)
                // Save the exact root before the request so a lost ACK can be
                // recovered without reading Photos or uploading anything again.
                var pending = self.shareTaskRecord
                try pending.bindExportRoot(root, migrationID: header.migrationID)
                try self.saveShareTaskRecord(pending)
                self.shareTaskRecord = pending
                let receipt = try await transferClient.finishPreparedMigration(
                    at: root, header: header, items: items, handoffToMac: true, beforeChunk: check)
                // The authenticated response is the disconnect boundary. Do not
                // require a still-live transport after this durable acceptance.
                try ImageAllMigrationStreamRecord(hostID: connection.hostID, deviceID: connection.deviceID,
                    header: header, items: items, receipt: receipt).save(in: root)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: root.appendingPathComponent(ImageAllMigrationStreamRecord.filename).path)
                var taskRecord = self.shareTaskRecord
                try taskRecord.bindExportRoot(root, migrationID: header.migrationID)
                try self.saveShareTaskRecord(taskRecord)
                self.shareTaskRecord = taskRecord
                return receipt
            }
        ))
    }

    func exportSelectedFacts() async throws -> URL {
        let snapshot = try await makeMigrationFactSnapshot()
        guard !snapshot.selectedAssetIDs.isEmpty else {
            throw LocalArchiveExportError.emptySelection
        }
        guard Set(snapshot.selectedAssetIDs) == Set(snapshot.assets.map(\.id)) else {
            throw LocalArchiveExportError.selectionNotVisible
        }
        return try await Task.detached(priority: .utility) {
            try LocalMigrationFactExporter.export(snapshot: snapshot)
        }.value
    }

    func recheckCleanupSources(_ request: RemotePhoneCleanupRecheck,
        remote: RemoteCompanionModel, reportID: UUID = UUID()
    ) async throws -> LocalCleanupSourceCheck {
        guard UIApplication.shared.applicationState == .active else { throw CancellationError() }
        try await validateCleanupRecheckIdentity(request)
        guard try await remote.fetchPhoneCleanupRecheck() == request else {
            throw LocalArchiveExportError.selectionChanged
        }
        let stream = try LocalPhotoArchiveExporter.existingStreamingArchives().first { $0.migrationID == request.migrationID }
        let lease: ImageAllMigrationExportCheckpoint?
        let root: URL
        let record: ImageAllMigrationStreamRecord?
        let header: ImageAllMigrationHeader
        let items: [ImageAllMigrationItem]
        if let stream {
            let opened = try ImageAllMigrationExportCheckpoint(streamingRoot: stream.root)
            lease = opened
            root = opened.root
            do {
                let saved = try ImageAllMigrationStreamRecord.read(in: root)
                guard saved.hostID == request.hostID, saved.deviceID == request.deviceID else {
                    throw LocalArchiveExportError.archiveScopeChanged
                }
                record = saved; header = saved.header; items = saved.items
            } catch { opened.close(); throw error }
        } else {
            lease = nil; record = nil
            guard let saved = try LocalPhotoArchiveExporter.existingArchives().first(where: {
                UUID(uuidString: $0.deletingPathExtension().lastPathComponent) == request.migrationID
            }) else {
                throw RemoteAPIError(code: .notFound, message: "本机没有该迁移批次的归档或逐资源记录，不能核对来源")
            }
            root = saved
            var foundHeader: ImageAllMigrationHeader?
            var foundItems: [ImageAllMigrationItem] = []
            _ = try ImageAllMigrationArchive.visitVerifiedRecords(at: root,
                onHeader: { foundHeader = $0 }, onItem: { foundItems.append($0) })
            guard let foundHeader else { throw LocalArchiveExportError.incompleteArchive }
            header = foundHeader; items = foundItems
        }
        defer { lease?.close() }
        guard let factsURL = try ImageAllMigrationFacts.latestPublishedURL(in: root) else {
            throw LocalArchiveExportError.syncNotAcknowledged
        }
        let archivedFacts = try ImageAllMigrationFacts.read(at: factsURL)
        try request.validateSourceEvidence(header: header, items: items, archivedFacts: archivedFacts)
        try Task.checkCancellation()
        let sourceVersions = try LocalPhotoArchiveExporter.cleanupSourceVersions(items.map(\.sourceLocalIdentifier))
        let currentURL = try await exportCompletionCheckpointFacts(for: root, streamRecord: record)
        defer { try? FileManager.default.removeItem(at: currentURL) }
        let current = try ImageAllMigrationFacts.read(at: currentURL)
        try request.validateSourceEvidence(header: header, items: items, archivedFacts: archivedFacts, currentFacts: current)
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState == .active,
              try await remote.fetchPhoneCleanupRecheck() == request else {
            throw LocalArchiveExportError.selectionChanged
        }
        try await validateCleanupRecheckIdentity(request)
        guard let store else { throw LocalFavoriteSourceError.storeUnavailable }
        let visible = try await observedSharedVisibleIdentifiers()
        let final = try await store.migrationCompletionCheckpoint(visibleIdentifiers: visible)
        let finalURL = try LocalMigrationFactExporter.export(snapshot: final.snapshot,
            checkpoint: final.checkpoint, archiveManifestSHA256: request.manifestSHA256,
            sourceVerifiedAtMs: current.syncCheckpoint?.sourceVerifiedAtMs)
        defer { try? FileManager.default.removeItem(at: finalURL) }
        try request.validateSourceEvidence(header: header, items: items, archivedFacts: archivedFacts,
            currentFacts: ImageAllMigrationFacts.read(at: finalURL))
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState == .active else { throw CancellationError() }
        guard sourceVersions == (try LocalPhotoArchiveExporter.cleanupSourceVersions(items.map(\.sourceLocalIdentifier))),
              let digest = request.factSnapshotSHA256 else { throw LocalArchiveExportError.selectionChanged }
        let plan = LocalSourceRetirementPlan(id: UUID(), migrationID: request.migrationID,
            requestID: request.id, sourceReportID: reportID, completionReceiptID: request.completionReceiptID,
            backupReceiptID: request.backupReceiptID, manifestSHA256: request.manifestSHA256,
            factSnapshotSHA256: digest,
            candidateAssetIDs: final.snapshot.assets.filter { !$0.observedFavorite && $0.favoriteTarget != true }.map(\.id),
            snapshot: final.snapshot, checkpoint: final.checkpoint)
        return .init(plan: plan, sourceVersions: sourceVersions)
    }

    func sourceRetirementHistory() async throws -> [LocalSourceRetirementRecord] {
        guard let store else { throw LocalFavoriteSourceError.storeUnavailable }
        return try await store.sourceRetirementRecords().reversed()
    }

    func sendSourceRetirement(_ id: UUID, remote: RemoteCompanionModel) async throws {
        guard let store, let record = try await store.sourceRetirementRecords().first(where: { $0.id == id }) else {
            throw LocalFavoriteSourceError.storeUnavailable
        }
        let outcome: RemotePhoneSourceRetirementOutcome
        switch record.state {
        case .completed: outcome = .completed
        case .failed: outcome = .failed
        case .submitted, .outcomeUnknown: outcome = .outcomeUnknown
        case .closedUnknown: outcome = .closedUnknown
        case .prepared, .cancelled: throw LocalLibraryError.sourceRetirementConflict
        }
        let p = record.plan
        let binding = RemotePhoneSourceRetirementBinding(operationID: p.id, hostID: p.checkpoint.hostID,
            deviceID: p.checkpoint.deviceID, requestID: p.requestID, sourceReportID: p.sourceReportID,
            migrationID: p.migrationID, sourceInstallID: p.snapshot.installID, sourceEpoch: p.snapshot.sourceEpoch,
            scopeRevision: p.snapshot.scopeRevision, completionReceiptID: p.completionReceiptID,
            backupReceiptID: p.backupReceiptID, manifestSHA256: p.manifestSHA256,
            factSnapshotSHA256: p.factSnapshotSHA256, candidateAssetIDs: p.candidateAssetIDs)
        try await remote.submitSourceRetirement(.init(binding: binding, outcome: outcome, updatedAtMs: record.updatedAtMs))
        try await store.acknowledgeSourceRetirement(id: id, state: record.state, updatedAtMs: record.updatedAtMs)
    }

    func closeUnknownSourceRetirement(_ id: UUID, remote: RemoteCompanionModel) async throws {
        guard let store else { throw LocalFavoriteSourceError.storeUnavailable }
        try await store.manuallyCloseUnknownSourceRetirement(id: id)
        try? await sendSourceRetirement(id, remote: remote)
    }

    func cancelPreparedSourceRetirement(_ id: UUID) async throws {
        guard let store else { throw LocalFavoriteSourceError.storeUnavailable }
        try await store.cancelSourceRetirement(id: id)
    }

    /// Only called from the explicit foreground confirmation button.
    func retireCleanupSources(_ report: RemotePhoneCleanupSourceReport,
        remote: RemoteCompanionModel
    ) async throws -> LocalSourceRetirementRecord {
        guard UIApplication.shared.applicationState == .active,
              PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              report.request.candidateCount > 0, let store else {
            throw LocalFavoriteSourceError.authorizationRequired
        }
        let checked = try await recheckCleanupSources(report.request, remote: remote, reportID: report.id)
        guard checked.plan.candidateAssetIDs.count == report.request.candidateCount else {
            throw LocalArchiveExportError.selectionChanged
        }
        _ = try await remote.recheckMacCopies(for: report)
        let auditDeadline = ProcessInfo.processInfo.systemUptime + 30
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState == .active,
              checked.sourceVersions == (try LocalPhotoArchiveExporter.cleanupSourceVersions(
                checked.plan.snapshot.assets.map(\.localIdentifier))) else {
            throw LocalArchiveExportError.selectionChanged
        }
        let visible = try await observedSharedVisibleIdentifiers()
        let source = PhotoKitLocalRetirementSource(plan: checked.plan, versions: checked.sourceVersions,
            auditDeadline: auditDeadline)
        let result = try await LocalSourceRetirementExecutor.perform(checked.plan, store: store,
            visibleIdentifiers: visible, source: source)
        // Outcome is already durable. A lost network receipt cannot undo it or retry PhotoKit.
        try? await sendSourceRetirement(result.id, remote: remote)
        return (try? await store.sourceRetirementRecords())?.first(where: { $0.id == result.id }) ?? result
    }

    func exportCompletionCheckpointFacts(
        for archiveRoot: URL, streamRecord: ImageAllMigrationStreamRecord? = nil
    ) async throws -> URL {
        guard let store else { throw LocalFavoriteSourceError.storeUnavailable }
        let identifiers = try await observedSharedVisibleIdentifiers()
        let before: (snapshot: LocalSharedSnapshot, checkpoint: LocalMigrationSyncCheckpoint)
        do {
            before = try await store.migrationCompletionCheckpoint(
                visibleIdentifiers: identifiers
            )
        } catch LocalLibraryError.migrationScopeIncomplete {
            throw LocalArchiveExportError.selectionNotVisible
        } catch LocalLibraryError.migrationSyncPending {
            throw LocalArchiveExportError.syncPending
        } catch LocalLibraryError.syncScopeNotAcknowledged {
            throw LocalArchiveExportError.syncNotAcknowledged
        }
        let manifestSHA256: String
        if let streamRecord {
            guard before.checkpoint.hostID == streamRecord.hostID,
                  before.checkpoint.deviceID == streamRecord.deviceID else {
                throw LocalArchiveExportError.archiveScopeChanged
            }
            try await LocalPhotoArchiveExporter.verifyCurrentSourcesMatchStream(
                streamRecord, snapshot: before.snapshot)
            manifestSHA256 = streamRecord.receipt.manifestSHA256
        } else {
            manifestSHA256 = try await LocalPhotoArchiveExporter.verifyCurrentSourcesMatchArchive(
                at: archiveRoot, snapshot: before.snapshot).manifestSHA256
        }
        let latestIdentifiers = try await observedSharedVisibleIdentifiers()
        let after = try await store.migrationCompletionCheckpoint(
            visibleIdentifiers: latestIdentifiers
        )
        guard before.checkpoint == after.checkpoint,
              before.snapshot.installID == after.snapshot.installID,
              before.snapshot.sourceEpoch == after.snapshot.sourceEpoch,
              before.snapshot.scopeRevision == after.snapshot.scopeRevision,
              before.snapshot.outboxWatermark == after.snapshot.outboxWatermark,
              before.snapshot.selectedAssetIDs == after.snapshot.selectedAssetIDs,
              before.snapshot.assets == after.snapshot.assets else {
            throw LocalArchiveExportError.selectionChanged
        }
        let verifiedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
        return try await Task.detached(priority: .utility) {
            try LocalMigrationFactExporter.export(
                snapshot: after.snapshot, checkpoint: after.checkpoint,
                archiveManifestSHA256: manifestSHA256,
                sourceVerifiedAtMs: verifiedAtMs
            )
        }.value
    }

    func submitStreamingCompletionCheckpoint(
        at root: URL, to remote: RemoteCompanionModel
    ) async throws -> ImageAllMigrationTransferSealReceipt {
        let connection = try remote.migrationStreamingConnection()
        let lease = try ImageAllMigrationExportCheckpoint(streamingRoot: root)
        defer { lease.close() }
        let record = try ImageAllMigrationStreamRecord.read(in: lease.root)
        guard record.header.migrationID == lease.migrationID,
              record.hostID == connection.hostID, record.deviceID == connection.deviceID else {
            throw LocalArchiveExportError.archiveScopeChanged
        }
        let scope = try await makeMigrationFactSnapshot()
        let check: @Sendable () async throws -> Void = { [self, remote] in
            try Task.checkCancellation()
            try await remote.validateMigrationStreamingConnection(
                hostID: record.hostID, deviceID: record.deviceID, transportID: connection.transportID)
            try await self.validateSharedSnapshotScope(scope)
        }
        try await check()
        // A saved receipt is historical. Independently recheck the current Mac
        // archive before spending time reading Photos or issuing a checkpoint.
        let current = try await connection.client.sealMigrationTransfer(migrationID: record.header.migrationID)
        guard record.matchesMedia(current) else { throw LocalArchiveExportError.sourceChanged }
        try await check()
        let facts = try await exportCompletionCheckpointFacts(for: lease.root, streamRecord: record)
        defer { try? FileManager.default.removeItem(at: facts) }
        try await check()
        _ = try ImageAllMigrationFacts.publish(from: facts, into: lease.root)
        let receipt = try await connection.client.finishPreparedMigration(
            at: lease.root, header: record.header, items: record.items, beforeChunk: check)
        try await check()
        try ImageAllMigrationStreamRecord(hostID: record.hostID, deviceID: record.deviceID,
            header: record.header, items: record.items, receipt: receipt).save(in: lease.root)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
            ofItemAtPath: lease.root.appendingPathComponent(ImageAllMigrationStreamRecord.filename).path)
        return receipt
    }

    func completeSharedSync(
        snapshot: LocalSharedSnapshot,
        receipt: RemoteLocalLibrarySnapshotReceipt,
        remoteModel: RemoteCompanionModel
    ) async throws -> LocalSharedSyncSummary {
        guard let store else { throw LocalFavoriteSourceError.storeUnavailable }
        guard let importedAssetIDs = receipt.importedAssetIDs else {
            throw LocalLibraryError.database("Mac 缺少首次导入字段回执，整理操作仍保留在手机")
        }
        do {
            try await store.acknowledgeSharedSnapshot(
                snapshot, hostID: receipt.hostID, deviceID: receipt.deviceID,
                importedAssetIDs: importedAssetIDs
            )
            var applied = 0
            var unchanged = 0
            var conflicts = 0
            var deferred = 0
            var received = 0
            var pullHasMore = false
            var collectionReceived = 0
            var collectionPullHasMore = false
            var favoriteReceived = 0
            var favoritePullHasMore = false
            var sent = 0
            var blockedFields: Set<String> = []
            let visible = Dictionary(uniqueKeysWithValues: snapshot.assets.map { ($0.id, $0) })
            let pending = try await store.pendingSharedOperations()
            for operation in pending {
                let isTag = operation.field.hasPrefix("tag.")
                let isCollection = operation.field.hasPrefix("collection.")
                let isFavorite = operation.field == "favorite.target"
                guard isTag
                    || (isCollection && remoteModel.supportsLocalLibraryCollectionMembership)
                    || (isFavorite && remoteModel.supportsLocalLibraryFavoriteTarget)
                else {
                    deferred += 1 // Unsupported fields retain their shared intent.
                    continue
                }
                let fieldKey = "\(operation.assetID.uuidString)|\(operation.field)"
                if blockedFields.contains(fieldKey) { deferred += 1; continue }
                if operation.isConflicted {
                    conflicts += 1
                    blockedFields.insert(fieldKey)
                    continue
                }
                if sent >= 100 { deferred += 1; continue }
                guard let asset = visible[operation.assetID],
                      PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
                        || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else {
                    deferred += 1
                    continue
                }
                let options = PHFetchOptions()
                options.includeHiddenAssets = false
                options.includeAssetSourceTypes = .typeUserLibrary
                guard PHAsset.fetchAssets(
                    withLocalIdentifiers: [asset.localIdentifier], options: options
                ).firstObject != nil else {
                    deferred += 1
                    continue
                }
                let disposition: LocalSharedTagDisposition
                if isTag {
                    guard let prepared = try await store.prepareSharedTagOperation(
                        id: operation.id, hostID: receipt.hostID, deviceID: receipt.deviceID
                    ) else { continue }
                    let tagReceipt = try await remoteModel.submitLocalLibraryTagDecision(prepared)
                    disposition = switch tagReceipt.disposition {
                    case .applied: .applied
                    case .unchanged: .unchanged
                    case .conflict: .conflict
                    }
                    let currentDecision: LocalDecision? = switch tagReceipt.currentDecision {
                    case .accepted: .accepted
                    case .rejected: .rejected
                    case .cleared: .cleared
                    case nil: nil
                    }
                    _ = try await store.recordSharedTagResult(
                        operationID: operation.id, hostID: receipt.hostID,
                        deviceID: receipt.deviceID, disposition: disposition,
                        fieldRevision: tagReceipt.fieldRevision,
                        currentDecision: currentDecision,
                        conflictReason: tagReceipt.conflictReason.map {
                            switch $0 {
                            case .fieldVersion: .fieldVersion
                            case .tagIdentity: .tagIdentity
                            case .nameAlias: .nameAlias
                            }
                        }
                    )
                } else if isCollection {
                    guard let prepared = try await store.prepareSharedCollectionOperation(
                        id: operation.id, hostID: receipt.hostID, deviceID: receipt.deviceID
                    ) else { continue }
                    let collectionReceipt = try await remoteModel.submitLocalLibraryCollectionMembership(
                        prepared
                    )
                    disposition = switch collectionReceipt.disposition {
                    case .applied: .applied
                    case .unchanged: .unchanged
                    case .conflict: .conflict
                    }
                    _ = try await store.recordSharedCollectionResult(
                        operationID: operation.id, hostID: receipt.hostID,
                        deviceID: receipt.deviceID, disposition: disposition,
                        fieldRevision: collectionReceipt.fieldRevision,
                        currentIncluded: collectionReceipt.currentIncluded,
                        conflictReason: collectionReceipt.conflictReason.map {
                            switch $0 {
                            case .fieldVersion: .fieldVersion
                            case .collectionIdentity: .collectionIdentity
                            case .nameAlias: .nameAlias
                            }
                        }
                    )
                } else {
                    guard let prepared = try await store.prepareSharedFavoriteOperation(
                        id: operation.id, hostID: receipt.hostID, deviceID: receipt.deviceID
                    ) else { continue }
                    let favoriteReceipt = try await remoteModel.submitLocalLibraryFavoriteTarget(
                        prepared
                    )
                    disposition = switch favoriteReceipt.disposition {
                    case .applied: .applied
                    case .unchanged: .unchanged
                    case .conflict: .conflict
                    }
                    _ = try await store.recordSharedFavoriteResult(
                        operationID: operation.id, hostID: receipt.hostID,
                        deviceID: receipt.deviceID, disposition: disposition,
                        fieldRevision: favoriteReceipt.fieldRevision,
                        currentTarget: favoriteReceipt.currentTarget
                    )
                }
                sent += 1
                switch disposition {
                case .applied: applied += 1
                case .unchanged: unchanged += 1
                case .conflict:
                    conflicts += 1
                    blockedFields.insert(fieldKey)
                }
            }
            let pullSupported = remoteModel.supportsLocalLibraryTagChanges
            if pullSupported {
                for _ in 0..<20 {
                    let cursor = try await store.sharedTagChangeCursor()
                    let page = try await remoteModel.fetchLocalLibraryTagChanges(
                        sourceEpoch: snapshot.sourceEpoch,
                        scopeRevision: snapshot.scopeRevision,
                        afterCursor: cursor
                    )
                    let result = try await store.applySharedTagChanges(
                        hostID: page.hostID, deviceID: page.deviceID,
                        sourceEpoch: page.sourceEpoch,
                        scopeRevision: page.scopeRevision, afterCursor: cursor,
                        changes: page.changes.map { change in
                            let decision: LocalDecision = switch change.decision {
                            case .accepted: .accepted
                            case .rejected: .rejected
                            case .cleared: .cleared
                            }
                            return LocalSharedTagChange(
                                sequence: change.sequence, assetID: change.assetID,
                                tagID: change.tagID, tagName: change.tagName,
                                decision: decision, fieldRevision: change.fieldRevision
                            )
                        }, nextCursor: page.nextCursor
                    )
                    received += result.applied
                    conflicts += result.conflicts
                    pullHasMore = page.hasMore
                    if !page.hasMore { break }
                }
            }
            let collectionPullSupported = remoteModel.supportsLocalLibraryCollectionChanges
            if collectionPullSupported {
                for _ in 0..<20 {
                    let cursor = try await store.sharedCollectionChangeCursor()
                    let page = try await remoteModel.fetchLocalLibraryCollectionChanges(
                        sourceEpoch: snapshot.sourceEpoch,
                        scopeRevision: snapshot.scopeRevision,
                        afterCursor: cursor
                    )
                    let result = try await store.applySharedCollectionChanges(
                        hostID: page.hostID, deviceID: page.deviceID,
                        sourceEpoch: page.sourceEpoch,
                        scopeRevision: page.scopeRevision, afterCursor: cursor,
                        changes: page.changes.map { change in
                            LocalSharedCollectionChange(
                                sequence: change.sequence, assetID: change.assetID,
                                collectionID: change.collectionID,
                                collectionName: change.collectionName,
                                included: change.included,
                                fieldRevision: change.fieldRevision,
                                renamedFrom: change.renamedFrom
                            )
                        }, nextCursor: page.nextCursor
                    )
                    collectionReceived += result.applied
                    conflicts += result.conflicts
                    collectionPullHasMore = page.hasMore
                    if !page.hasMore { break }
                }
            }
            let favoritePullSupported = remoteModel.supportsLocalLibraryFavoriteChanges
            if favoritePullSupported {
                for _ in 0..<20 {
                    let cursor = try await store.sharedFavoriteChangeCursor()
                    let page = try await remoteModel.fetchLocalLibraryFavoriteChanges(
                        sourceEpoch: snapshot.sourceEpoch,
                        scopeRevision: snapshot.scopeRevision,
                        afterCursor: cursor
                    )
                    let result = try await store.applySharedFavoriteChanges(
                        hostID: page.hostID, deviceID: page.deviceID,
                        sourceEpoch: page.sourceEpoch,
                        scopeRevision: page.scopeRevision, afterCursor: cursor,
                        changes: page.changes.map { change in
                            LocalSharedFavoriteChange(
                                sequence: change.sequence, assetID: change.assetID,
                                target: change.target,
                                fieldRevision: change.fieldRevision
                            )
                        }, nextCursor: page.nextCursor
                    )
                    favoriteReceived += result.applied
                    conflicts += result.conflicts
                    favoritePullHasMore = page.hasMore
                    if !page.hasMore { break }
                }
            }
            await reloadFacts()
            let remaining = pendingCount
            return LocalSharedSyncSummary(
                applied: applied, unchanged: unchanged,
                conflicts: conflicts, deferred: deferred,
                received: received,
                pullSupported: pullSupported,
                pullHasMore: pullHasMore,
                collectionReceived: collectionReceived,
                collectionPullSupported: collectionPullSupported,
                collectionPullHasMore: collectionPullHasMore,
                favoriteReceived: favoriteReceived,
                favoritePullSupported: favoritePullSupported,
                favoritePullHasMore: favoritePullHasMore,
                remaining: remaining
            )
        } catch {
            await reloadFacts()
            throw error
        }
    }

    func resolveSharedTagConflict(
        _ operation: LocalSharedPendingOperation,
        resolution: LocalSharedTagConflictResolution
    ) async {
        guard let store else {
            errorMessage = "本机资料库不可用"
            return
        }
        do {
            _ = try await store.resolveSharedTagConflict(
                operationID: operation.id, resolution: resolution
            )
            await reloadFacts()
        } catch {
            errorMessage = "处理标签冲突失败：\(error.localizedDescription)"
            await reloadFacts()
        }
    }

    func confirmSharedTagAlias(_ candidate: LocalSharedTagAliasCandidate) async throws {
        guard let store else { throw LocalFavoriteSourceError.storeUnavailable }
        try await store.confirmSharedTagAlias(candidate)
    }

    func confirmSharedCollectionAlias(_ candidate: LocalSharedCollectionAliasCandidate) async throws {
        guard let store else { throw LocalFavoriteSourceError.storeUnavailable }
        try await store.confirmSharedCollectionAlias(candidate)
    }

    func recoverSharedCollectionRenameHistory(
        _ operation: LocalSharedPendingOperation, remoteModel: RemoteCompanionModel
    ) async throws -> String {
        guard let store else { throw LocalFavoriteSourceError.storeUnavailable }
        let name = try await store.recoverSharedCollectionRenameHistory(operationID: operation.id) {
            epoch, scope, cursor in
            let page = try await remoteModel.fetchLocalLibraryCollectionChanges(
                sourceEpoch: epoch, scopeRevision: scope, afterCursor: cursor
            )
            return LocalSharedCollectionHistoryPage(
                hostID: page.hostID, deviceID: page.deviceID, sourceEpoch: page.sourceEpoch,
                scopeRevision: page.scopeRevision,
                changes: page.changes.map {
                    LocalSharedCollectionChange(
                        sequence: $0.sequence, assetID: $0.assetID, collectionID: $0.collectionID,
                        collectionName: $0.collectionName, included: $0.included,
                        fieldRevision: $0.fieldRevision, renamedFrom: $0.renamedFrom,
                        createdCollectionID: $0.createdCollectionID
                    )
                }, nextCursor: page.nextCursor
            )
        }
        await reloadFacts()
        return name
    }

    func resolveSharedCollectionConflict(
        _ operation: LocalSharedPendingOperation,
        resolution: LocalSharedCollectionConflictResolution
    ) async {
        guard let store else {
            errorMessage = "本机资料库不可用"
            return
        }
        do {
            _ = try await store.resolveSharedCollectionConflict(
                operationID: operation.id, resolution: resolution
            )
            await reloadFacts()
        } catch {
            errorMessage = "处理集合成员冲突失败：\(error.localizedDescription)"
            await reloadFacts()
        }
    }

    func resolveSharedFavoriteConflict(
        _ operation: LocalSharedPendingOperation,
        resolution: LocalSharedFavoriteConflictResolution
    ) async {
        guard let store else {
            errorMessage = "本机资料库不可用"
            return
        }
        do {
            _ = try await store.resolveSharedFavoriteConflict(
                operationID: operation.id, resolution: resolution
            )
            await reloadFacts()
        } catch {
            errorMessage = "处理收藏目标冲突失败：\(error.localizedDescription)"
            await reloadFacts()
        }
    }

    func setFavoriteTarget(_ favorite: Bool, asset: LocalAsset) async {
        await writeFavorite(favorite, asset: asset, saveNewIntent: true)
    }

    func retryFavoriteWriteback(asset: LocalAsset) async {
        guard let target = asset.favoriteTarget else { return }
        await writeFavorite(target, asset: asset, saveNewIntent: false)
    }

    private func writeFavorite(
        _ favorite: Bool, asset: LocalAsset, saveNewIntent: Bool
    ) async {
        guard let store else { return }
        guard !favoriteWritesInFlight.contains(asset.id) else { return }
        favoriteWritesInFlight.insert(asset.id)
        defer { favoriteWritesInFlight.remove(asset.id) }
        if saveNewIntent {
            do {
                try await store.setFavoriteTarget(assetID: asset.id, isFavorite: favorite)
                try await refreshStoredAsset(asset)
                await reloadFacts()
            } catch {
                errorMessage = "保存收藏目标失败：\(error.localizedDescription)"
                return
            }
        }

        do {
            let intent = try await store.prepareFavoriteWriteback(
                assetID: asset.id, expectedTarget: favorite
            )
            let outcome = try await LocalFavoriteWriteback.perform(intent, store: store, source: favoriteSource)
            try await refreshStoredAsset(asset)
            switch outcome {
            case .matched: break
            case .readbackMismatch:
                errorMessage = "已保存 ImageAll 收藏目标，但 Photos 回读尚未一致，可稍后刷新或重试。"
            case .superseded:
                errorMessage = "收藏目标已更新，旧写回结果未确认新目标；请刷新后按当前目标重试。"
            }
        } catch {
            try? await refreshStoredAsset(asset)
            errorMessage = "已保存 ImageAll 收藏目标，Photos 写回未完成：\(error.localizedDescription)"
        }
    }

    private func refreshStoredAsset(_ asset: LocalAsset) async throws {
        guard let store else { return }
        if let refreshed = try await store.assets(visibleIdentifiers: [asset.localIdentifier]).first,
           let index = assets.firstIndex(where: { $0.id == asset.id }) {
            assets[index] = refreshed
        }
    }

    private func reloadFacts() async {
        guard let store else { return }
        do {
            privateCollectionRevisions = try await store.privateCollectionNameRevisions()
            pendingCollectionRename = try await store.pendingCollectionRename()
            tags = try await store.tags()
            collections = try await store.collections()
            sharedSelections = try await store.sharedSelections()
            let pending = try await store.pendingSharedOperations()
            pendingCount = pending.count + (pendingCollectionRename == nil ? 0 : 1)
            sharedConflicts = pending.filter(\.isConflicted)
        } catch { errorMessage = "读取本机资料失败：\(error.localizedDescription)" }
    }
}

@MainActor
private final class PhotoKitLocalBrowsingSource: LocalLibraryBrowsingSource {
    private var fetched: PHFetchResult<PHAsset>?
    var canRead: Bool {
        let value = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return value == .authorized || value == .limited
    }
    private func options() -> PHFetchOptions {
        let value = PHFetchOptions()
        value.includeHiddenAssets = false
        value.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                      PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        value.includeAssetSourceTypes = .typeUserLibrary
        return value
    }
    func refresh() async throws -> Int {
        guard canRead else { fetched = nil; return 0 }
        let value = options()
        value.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetched = PHAsset.fetchAssets(with: value)
        return fetched?.count ?? 0
    }
    func observations(in range: Range<Int>) async throws -> [LocalObservedAsset] {
        guard canRead, let fetched else { return [] }
        return range.filter { $0 < fetched.count }.map {
            let asset = fetched.object(at: $0)
            return LocalObservedAsset(localIdentifier: asset.localIdentifier,
                kind: asset.mediaType == .video ? "video" : "image", creationDate: asset.creationDate,
                isFavorite: asset.isFavorite)
        }
    }
    func visibleIdentifiers(in candidates: Set<String>) throws -> Set<String> {
        guard canRead, !candidates.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(candidates), options: options())
        var visible = Set<String>()
        result.enumerateObjects { asset, _, _ in visible.insert(asset.localIdentifier) }
        return visible
    }
}

private final class LocalPhotoChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let onChange: @MainActor @Sendable () -> Void
    private let generation: LocalLibraryVisibilityGeneration
    init(generation: LocalLibraryVisibilityGeneration, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
        self.generation = generation
        super.init()
        PHPhotoLibrary.shared().register(self)
    }
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        generation.invalidate()
        Task { @MainActor [onChange] in onChange() }
    }
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
}

private final class SourceRetirementGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var submitted = false
    private let deadline: TimeInterval
    private var observer: NSObjectProtocol?
    @MainActor init(deadline: TimeInterval) {
        self.deadline = deadline
        closed = UIApplication.shared.applicationState != .active
        observer = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: nil) { [weak self] _ in self?.close() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func close() { lock.lock(); closed = true; lock.unlock() }
    func enter() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !submitted, ProcessInfo.processInfo.systemUptime <= deadline else { return false }
        submitted = true
        return true
    }
    func didSubmit() -> Bool { lock.lock(); defer { lock.unlock() }; return submitted }
}

private final class PhotoKitLocalRetirementSource: LocalSourceRetiring, @unchecked Sendable {
    private let identifiers: [String]
    private let versions: [String: String]
    private let gate: SourceRetirementGate
    @MainActor init(plan: LocalSourceRetirementPlan, versions: [String: String], auditDeadline: TimeInterval) {
        let candidates = Set(plan.candidateAssetIDs)
        let selected = plan.snapshot.assets.filter { candidates.contains($0.id) }.map(\.localIdentifier)
        identifiers = selected
        self.versions = versions.filter { selected.contains($0.key) }
        gate = SourceRetirementGate(deadline: auditDeadline)
    }
    func submitRetirement() async throws -> LocalSourceRetirementOutcome {
        if Task.isCancelled { return .failed }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                PHPhotoLibrary.shared().performChanges {
                    guard !self.identifiers.isEmpty,
                          PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
                    let options = PHFetchOptions()
                    options.includeHiddenAssets = false; options.includeAssetSourceTypes = .typeUserLibrary
                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: self.identifiers, options: options)
                    guard assets.count == self.identifiers.count else { return }
                    for index in 0..<assets.count {
                        let asset = assets.object(at: index)
                        guard !asset.isFavorite, asset.canPerform(.delete),
                              let fingerprint = try? LocalPhotoArchiveExporter.cleanupSourceFingerprint(asset),
                              fingerprint == self.versions[asset.localIdentifier] else { return }
                    }
                    guard self.gate.enter() else { return }
                    PHAssetChangeRequest.deleteAssets(assets)
                } completionHandler: { success, _ in
                    continuation.resume(returning: success && self.gate.didSubmit() ? .succeeded : .failed)
                }
            }
        } onCancel: { self.gate.close() }
    }
}

@MainActor
private final class PhotoKitLocalFavoriteSource: LocalFavoriteSource {
    private func asset(_ identifier: String) throws -> PHAsset {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            throw LocalFavoriteSourceError.authorizationRequired
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw LocalFavoriteSourceError.assetUnavailable
        }
        return asset
    }

    func writeFavorite(_ favorite: Bool, localIdentifier: String) async throws {
        try Task.checkCancellation()
        let sourceAsset = try asset(localIdentifier)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: sourceAsset).isFavorite = favorite
        }
    }

    func readFavorite(localIdentifier: String) async throws -> Bool {
        try asset(localIdentifier).isFavorite
    }
}

private enum LocalFavoriteSourceError: LocalizedError {
    case storeUnavailable
    case authorizationRequired
    case assetUnavailable

    var errorDescription: String? {
        switch self {
        case .storeUnavailable: "本机资料库不可用"
        case .authorizationRequired: "本机照片授权已变化"
        case .assetUnavailable: "这张照片已不在当前授权范围内"
        }
    }
}

struct LocalLibraryView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: LocalLibraryModel
    @ObservedObject var remoteModel: RemoteCompanionModel
    @State private var newTagName = ""
    @State private var newCollectionName = ""

    var body: some View {
        Group {
            switch model.authorization {
            case .notDetermined:
                ContentUnavailableView {
                    Label("浏览此 iPhone", systemImage: "photo.on.rectangle")
                } description: {
                    Text("授权后可离线整理本机照片。连接 Mac 不会自动分享照片或整理信息。")
                } actions: {
                    Button("选择照片访问权限") { Task { await model.requestAccess() } }
                }
            case .denied, .restricted:
                ContentUnavailableView(
                    "无法访问此 iPhone 的照片",
                    systemImage: "lock.shield",
                    description: Text("可在系统设置中更改权限。已有本地标签和集合会保留。")
                )
                Button("打开照片权限设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            case .authorized, .limited:
                libraryContent
            @unknown default:
                ContentUnavailableView("照片权限状态未知", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle("此 iPhone")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink("待分享") {
                    LocalShareScopeView(model: model, remoteModel: remoteModel)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { organizationContent } label: { Image(systemName: "square.stack") }
                    .accessibilityLabel("标签与集合")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("刷新", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    NavigationLink("批量加入待分享…") { LocalBulkShareView(model: model) }
                    Button("管理照片权限", systemImage: "lock.shield") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    NavigationLink("备份本机整理库") { LocalLibraryBackupView(model: model) }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
        .alert("本机图库", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("确定") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var libraryContent: some View {
        LocalPhotoLibraryContent(items: model.assets.map { asset in
            LocalShareItem(id: asset.id, localIdentifier: asset.localIdentifier,
                           isVideo: asset.kind == "video", date: asset.creationDate,
                           isFavorite: asset.favoriteTarget ?? asset.observedFavorite)
        }, sharedCount: model.sharedSelections.count, limited: model.authorization == .limited,
           hasMore: model.hasMore, loadMore: { Task { await model.loadMore() } }) { item in
            if let asset = model.assets.first(where: { $0.id == item.id }) {
                LocalAssetDetailView(model: model, asset: asset)
            }
        }
        .refreshable { await model.refresh() }
    }

    private var organizationContent: some View {
        List {
            Section {
                LabeledContent("已分享范围的待提交操作", value: "\(model.pendingCount)")
                Text("本机整理会持久保存；只有明确加入待分享范围的资产会进入跨端提交队列。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("标签") {
                HStack {
                    TextField("新标签名称", text: $newTagName)
                    Button("创建") {
                        let name = newTagName
                        newTagName = ""
                        Task { await model.createTag(name) }
                    }
                    .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(model.tags) { tag in Text(tag.name) }
            }
            Section("ImageAll 集合") {
                HStack {
                    TextField("新集合名称", text: $newCollectionName)
                    Button("创建") {
                        let name = newCollectionName
                        newCollectionName = ""
                        Task { await model.createCollection(name) }
                    }
                    .disabled(newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(model.collections) { collection in
                    if let revision = model.privateCollectionRevisions[collection.id] {
                        NavigationLink {
                            LocalPrivateCollectionRenameView(model: model, collection: collection, revision: revision)
                        } label: {
                            HStack { Text(collection.name); Spacer(); Text("改名").foregroundStyle(.secondary) }
                        }
                    } else {
                        Text(collection.name)
                    }
                }
                Text("本机新建且未进入分享范围的集合可直接改名。共享集合请到“待分享”中改名；旧集合的共享历史不足时，保留身份核对要求。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("整理")
    }

}

private struct LocalLibraryBackupTransfer: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .database) { value in SentTransferredFile(value.url) }
    }
}

private struct LocalLibraryBackupView: View {
    @ObservedObject var model: LocalLibraryModel
    @State private var report: LocalLibraryBackupReport?
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                Text("保存此 iPhone 已记录的标签、集合、收藏目标和离线待同步记录，包括当前无权访问照片的本地记录。")
                Text("不包含照片或视频原件。此备份用于保全整理信息，不是完整图库迁移包；恢复前仍需核对设备身份与同步状态。")
                    .foregroundStyle(.secondary)
                Button(busy ? "正在生成并校验…" : "生成本机整理库备份") {
                    Task {
                        busy = true
                        report = nil
                        failure = nil
                        defer { busy = false }
                        do { report = try await model.exportLocalBackup() }
                        catch { failure = "备份未完成：\(error.localizedDescription)" }
                    }
                }
                .disabled(busy)
            }
            if let report {
                Section("快照已校验") {
                    LabeledContent("已记录资产", value: "\(report.assetCount)")
                    LabeledContent("标签", value: "\(report.tagCount)")
                    LabeledContent("集合", value: "\(report.collectionCount)")
                    LabeledContent("待同步记录", value: "\(report.pendingSharedCount)")
                    LabeledContent("文件大小", value: ByteCountFormatter.string(fromByteCount: report.byteCount, countStyle: .file))
                    ShareLink(item: LocalLibraryBackupTransfer(url: report.url),
                              preview: SharePreview("ImageAll 本机整理库备份")) {
                        Label("保存或分享备份文件", systemImage: "square.and.arrow.up")
                    }
                    Text("请保存到你选择的位置。生成快照不会自动上传，也不会替换当前资料库。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let failure { Text(failure).foregroundStyle(.red) }
        }
        .navigationTitle("备份本机整理库")
    }
}

private struct LocalBulkShareView: View {
    @ObservedObject var model: LocalLibraryModel
    var newBatch = false
    @State private var preview: LocalBulkSharePreview?
    @State private var busy = false
    @State private var message: String?
    @State private var work: Task<Void, Never>?

    var body: some View {
        Form {
            Section("范围") {
                Text("读取当前系统允许访问的非隐藏照片和视频，预览数量后再决定是否加入待分享。有限照片权限只覆盖你已授权的项目，不代表整个 iPhone 图库。")
                Text(newBatch ? "仅选择既有任务范围之外的内容，不按拍摄日期筛选。先保留原任务记录，再用预览范围准备下一次导入；此步不读取或发送原件。" : "本步骤不读取原件、不从 iCloud 下载、不发送目录。确认后，所选范围会用于之后你手动发起的同步与归档；新增照片不会自动加入。已有待分享项目保留。")
            }
            Section {
                Button(busy ? "正在核对…" : "预览已授权范围") {
                    preview = nil
                    busy = true
                    work = Task {
                        defer { busy = false }
                        do { preview = try await (newBatch ? model.prepareNewBatchPreview() : model.prepareBulkSharePreview()); message = nil }
                        catch { message = "预览未完成或范围已变化，请刷新后重试。" }
                    }
                }
                .disabled(busy)
                if let preview {
                    LabeledContent("照片", value: "\(preview.photoCount)")
                    LabeledContent("视频", value: "\(preview.videoCount)")
                    Button("确认将这 \(preview.totalCount) 项加入待分享") {
                        busy = true
                        work = Task {
                            defer { busy = false; self.preview = nil }
                            do {
                                let added = try await (newBatch ? model.confirmNewBatchPreview(preview) : model.confirmBulkSharePreview(preview))
                                message = newBatch ? "已准备 \(added) 项新内容；返回待分享后开始导入。原任务记录已保留。" : "已新增 \(added) 项到待分享，其余已在范围内。尚未同步目录或传输原件。"
                            } catch LocalLibraryError.migrationSyncPending {
                                message = "还有待同步的整理修改，请先完成同步后再准备新批次。原有选择保留。"
                            } catch {
                                message = "未批量加入：授权、来源或分享范围已变化，请重新预览。原有选择保留。"
                            }
                        }
                    }
                    .disabled(busy || preview.totalCount == 0)
                }
                if let message { Text(message) }
            }
        }
        .navigationTitle(newBatch ? "准备新增内容" : "批量准备分享范围")
        .onDisappear {
            work?.cancel()
            model.cancelBulkSharePreview()
            Task { await model.refresh() }
        }
    }
}

private struct LocalPrivateCollectionRenameView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: LocalLibraryModel
    @State private var collection: LocalCollection
    @State private var revision: Int64
    @State private var name: String
    @State private var busy = false
    @State private var failure: String?

    init(model: LocalLibraryModel, collection: LocalCollection, revision: Int64) {
        self.model = model
        _collection = State(initialValue: collection)
        _revision = State(initialValue: revision)
        _name = State(initialValue: collection.name)
    }

    var body: some View {
        Form {
            LabeledContent("当前名称", value: collection.name)
            TextField("新名称", text: $name)
            Button("保存本机名称") {
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        try await model.renamePrivateCollection(collection, revision: revision, name: name)
                        dismiss()
                    } catch {
                        failure = "未保存：名称、集合版本或分享状态已有变化，或新名称已占用。请返回列表核对后重试。"
                    }
                }
            }
            .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("离线保存 ImageAll 集合名称，成员保持不变，不修改 Photos 相册。进入分享范围后须使用共享集合改名。")
                .font(.footnote)
            if let failure { Text(failure).foregroundStyle(.red) }
        }
        .navigationTitle("本机集合改名")
    }
}

private struct LocalCollectionRenameView: View {
    @ObservedObject var model: LocalLibraryModel
    @ObservedObject var remote: RemoteCompanionModel
    @State private var collectionID: UUID?
    @State private var name = ""
    @State private var busy = false
    @State private var message: String?
    @State private var confirmsAbandon = false

    var body: some View {
        Form {
            if let command = model.pendingCollectionRename {
                Section("待完成改名") {
                    LabeledContent("原名称", value: command.expectedName)
                    LabeledContent("希望改为", value: command.newName)
                    Button("重试同一改名并拉取结果") { send(command) }
                        .disabled(busy)
                    Button("停止重试…", role: .destructive) { confirmsAbandon = true }
                        .disabled(busy)
                    Text("Mac 可能已收到命令。重试会复用原请求；停止重试不会撤回 Mac 已完成的改名。")
                        .font(.footnote)
                }
            } else {
                Section("改名") {
                    Picker("集合", selection: $collectionID) {
                        Text("请选择").tag(UUID?.none)
                        ForEach(model.collections) { collection in
                            Text(collection.name).tag(Optional(collection.id))
                        }
                    }
                    TextField("新名称", text: $name)
                    Button(busy ? "正在提交…" : "保存并提交改名") {
                        guard let collectionID else { return }
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                let command = try await model.prepareCollectionRename(collectionID: collectionID, name: name)
                                try await model.sendCollectionRename(command, remote: remote)
                                message = "改名回执和对应变化已处理，请核对当前集合名称。"
                            } catch { message = "改名未完成：\(error.localizedDescription)。请先同步并核对集合；已保存的请求可在此重试。" }
                        }
                    }
                    .disabled(busy || collectionID == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section {
                Text("请先同步目录和整理信息。集合须包含当前可见且已分享的项目。此处只改 ImageAll 集合名称；本机名称在 Mac 确认并拉取变化后更新。")
                if let message { Text(message) }
            }
        }
        .navigationTitle("共享集合改名")
        .alert("停止重试这次改名？", isPresented: $confirmsAbandon) {
            Button("停止重试", role: .destructive) {
                guard let command = model.pendingCollectionRename else { return }
                Task { await model.abandonCollectionRename(command) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("保留历史记录，不撤回 Mac 上可能已完成的改名。之后请先同步，核对当前名称，再决定是否发起新的改名。")
        }
    }

    private func send(_ command: LocalCollectionRenameCommand) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.sendCollectionRename(command, remote: remote)
                message = "改名回执和对应变化已处理，请核对当前集合名称。"
            } catch { message = "改名仍待处理：\(error.localizedDescription)。如 Mac 已有更新，请先同步核对，再停止旧重试并重新提交。" }
        }
    }
}

private struct LocalShareScopeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: LocalLibraryModel
    @ObservedObject var remoteModel: RemoteCompanionModel
    @State private var isSending = false
    @State private var isCheckingCollectionHistory = false
    @State private var isExporting = false
    @State private var isExportingFacts = false
    @State private var savedStreamingArchives: [LocalStreamingArchive] = []
    @State private var isStreamingArchive = false
    @State private var confirmsVerifiedSubsetSeal = false
    private var includeAlbumCatalog: Bool { model.shareIncludeAlbumCatalog }
    @State private var streamTask: Task<Void, Never>?
    @State private var isUploadingArchive = false
    @State private var exportedArchive: URL?
    @State private var exportedArchiveComplete = false
    @State private var exportedVerification: ImageAllMigrationVerification?
    @State private var savedArchives: [URL] = []
    @State private var exportedFacts: URL?
    @State private var statusMessage: String?
    @State private var archiveStatusMessage: String?
    @State private var cleanupRecheck: RemotePhoneCleanupRecheck?
    @State private var isFetchingCleanupRecheck = false
    @State private var cleanupSourceCheckMessage: String?
    @State private var cleanupSourceReport: RemotePhoneCleanupSourceReport?
    @State private var confirmsSourceRetirement = false
    @State private var retirementHistory: [LocalSourceRetirementRecord] = []
    @State private var closesUnknownRetirement: LocalSourceRetirementRecord?
    @State private var tagAliasCandidate: LocalSharedTagAliasCandidate?
    @State private var collectionAliasCandidate: LocalSharedCollectionAliasCandidate?
    @State private var shareSheet: LocalShareSheet?

    private var workBusy: Bool {
        model.exportCleanupBusy || model.legacyAssociationInProgress || isStreamingArchive || model.shareTask.phase == .running || model.shareTask.phase == .pausing
            || isSending || isExporting || isUploadingArchive || isExportingFacts
            || isCheckingCollectionHistory || isFetchingCleanupRecheck || model.shareSelectionEditing
    }
    private var selectionMatches: Bool {
        model.shareTaskSelectionIDs == Set(model.sharedSelections.map(\.id))
            && model.shareTaskAlbumCatalog == includeAlbumCatalog
    }
    private var presentation: LocalSharePresentation {
        if let error = model.shareTaskPersistenceError {
            return LocalSharePresentation(title: "任务记录需要检查", message: error,
                buttonTitle: "已停止新传输", action: .none, isEnabled: false, isError: true)
        }
        return LocalSharePresentation.resolve(task: model.shareTask, selectedCount: model.sharedSelections.count,
            canReadPhotos: model.authorization == .authorized || model.authorization == .limited,
            needsFullAccess: includeAlbumCatalog && model.authorization != .authorized,
            connected: remoteModel.isConnected, awaitingConsent: remoteModel.usbPendingOffer != nil,
            otherWork: workBusy, selectionMatches: selectionMatches,
            targetMatches: model.shareTaskHostID == remoteModel.savedPairingHostID && model.shareTaskFingerprint == remoteModel.savedPairingFingerprint,
            transferPhase: remoteModel.migrationPhase)
    }
    private var targetName: String {
        remoteModel.usbPendingOffer?.hostDisplayName ?? (remoteModel.host.isEmpty ? "未指定 Mac" : remoteModel.host)
    }
    private var selectionItems: [LocalShareItem] {
        model.sharedSelections.map { LocalShareItem(id: $0.id, localIdentifier: $0.localIdentifier,
            isVideo: $0.kind == "video", date: $0.creationDate) }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            LocalShareDashboard(photoCount: model.sharedSelections.filter { $0.kind != "video" }.count,
                videoCount: model.sharedSelections.filter { $0.kind == "video" }.count,
                target: targetName,
                connection: "\(remoteModel.importTransportLabel) · \(remoteModel.isConnected ? "已连接" : (remoteModel.usbPendingOffer != nil ? "等待确认" : "未连接"))",
                presentation: presentation, detail: model.shareTask.phase == .received
                    ? model.macImportStatusMessage : model.shareTask.detail,
                progress: model.shareTask.phase == .running || model.shareTask.phase == .pausing
                    ? remoteModel.migrationProgressText : nil,
                busy: workBusy, conflictCount: model.sharedConflicts.count,
                previewItems: model.sharedSelections.prefix(4).map {
                    LocalShareItem(id: $0.id, localIdentifier: $0.localIdentifier,
                                   isVideo: $0.kind == "video", date: $0.creationDate)
                },
                open: { shareSheet = $0 }, perform: performPrimaryAction) {
                if model.canReleaseExportPayload || model.exportCleanupBusy {
                    Section("导出暂存") {
                        Button(model.exportCleanupBusy ? "正在核验与收尾…" : "释放导出暂存") {
                            Task { await model.releaseExportPayload(remoteModel) }
                        }.disabled(model.exportCleanupBusy || !remoteModel.isConnected)
                        Text("先核验 Mac 最终副本，再释放此任务的手机临时载荷；手机照片保持不变。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let message = model.automaticCleanupMessage { Text(message).font(.footnote) }
                        if let message = model.exportCleanupMessage { Text(message).font(.footnote) }
                    }
                }
                Section("导入选项") {
                    Toggle("包含相簿目录（含空相簿）", isOn: $model.shareIncludeAlbumCatalog).disabled(workBusy)
                    if includeAlbumCatalog {
                        Text("需完整照片权限。只传输已选媒体，目录选项不扩大选片范围。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if model.authorization == .limited {
                        Text("有限照片访问：仅发送可访问的所选媒体，来源相簿不可读取。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if model.shareTask.phase == .idle {
                    Section("已经导入过？") {
                        Button(model.legacyAssociationInProgress ? "正在核对旧批次…" : "关联已导入批次（不重传）") {
                            Task { await model.associatePreviouslyPublishedTask(remoteModel, target: targetName) }
                        }.disabled(workBusy || !remoteModel.isConnected)
                            .accessibilityIdentifier("share.associatePublishedBatch")
                        Text("连接原 Mac 后核对手机旧清单与 Mac 发布结果。保留现有选择和待处理项目，不重新上传。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let message = model.legacyAssociationMessage { Text(message).font(.footnote) }
                    }
                }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if remoteModel.isConnected { await model.refreshMacImportStatus(remoteModel) }
                await model.advanceAutomaticCleanup(remoteModel)
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
        .confirmationDialog("封存已接收的可读项目？", isPresented: $confirmsVerifiedSubsetSeal, titleVisibility: .visible) {
            Button("封存已接收项目") { startImport(sealVerifiedSubset: true) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("仅复用原批次中已有 Mac 校验回执的原件，缺少回执就停止。保留原选择与未完成项目，不删除手机内容。相簿、红心、标签和集合一并封存。")
        }
        .sheet(item: $shareSheet) { destination in
            NavigationStack {
                Group {
                    switch destination {
                    case .selection:
                        LocalShareSelectionPage(items: selectionItems, locked: workBusy,
                            remove: { await model.removeSharedSelections($0) }) {
                            NavigationLink("预览并批量加入已授权照片／视频") { LocalBulkShareView(model: model) }
                            if !selectionMatches, model.shareTask.phase == .paused || model.shareTask.phase == .failed {
                                Button("恢复本次任务的选择与选项") { Task { await model.restoreShareTaskSelection() } }
                            }
                        }
                    case .connection:
                        Form {
                            Section("当前连接") {
                                LabeledContent("目标 Mac", value: targetName)
                                LabeledContent("通道", value: remoteModel.importTransportLabel)
                                USBPhoneConnectionSection(model: remoteModel).disabled(workBusy)
                            }
                            Section {
                                Text("USB：在 Mac“设置 → 设备与导入”发起连接，在此核对身份。系统信任、照片权限与 ImageAll 配对是不同步骤。")
                                Text("网络：到“Mac 图库”扫码配对。USB 断线暂停，不会自动切换到网络；归档禁止走蜂窝。")
                                Text("正在执行任务时连接设置暂时锁定；请先暂停。")
                                    .foregroundStyle(.secondary)
                            }.font(.footnote)
                        }
                    case .more:
                        List {
                            if model.shareTask.phase == .received {
                                Section {
                                    NavigationLink("仅准备上次任务范围之外的内容") { LocalBulkShareView(model: model, newBatch: true) }
                                    Button("按当前选择开始下一次导入") { model.resetReceivedShareTask(); shareSheet = nil }
                                }
                            }
                            Section {
                                Button("封存已接收项目（不重传原件）") {
                                    shareSheet = nil; confirmsVerifiedSubsetSeal = true
                                }.disabled(workBusy || !remoteModel.isConnected || model.sharedSelections.isEmpty)
                            }
                            syncSection; conflictSections.disabled(workBusy); offlineSection
                            Section("共享集合") {
                                NavigationLink("重命名共享集合") { LocalCollectionRenameView(model: model, remote: remoteModel) }
                                    .disabled(workBusy)
                            }
                        }
                    case .advanced:
                        List { advancedSection }
                    case .macNextStep:
                        VStack {
                            Text(presentation.title).font(.headline)
                            Text(presentation.message).font(.callout)
                            Button("刷新 Mac 状态") { Task { await model.refreshMacImportStatus(remoteModel) } }
                            if let message = model.macImportStatusMessage { Text(message).font(.footnote) }
                            LocalShareMacNextStep(isBrowsable: remoteModel.isConnected
                                && model.shareTaskHostID == remoteModel.savedPairingHostID
                                && model.shareTaskFingerprint == remoteModel.savedPairingFingerprint
                                && model.shareTask.macStatus?.phase == .browsable,
                                macOwnsProcessing: model.shareTask.macOwnsProcessing == true)
                        }.padding()
                    }
                }
                .navigationTitle(destination.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if destination != .selection {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { shareSheet = nil }
                                .disabled(workBusy && destination != .connection)
                        }
                    }
                }
            }
            .interactiveDismissDisabled(workBusy && destination != .connection && (destination != .selection || model.shareSelectionEditing))
        }
        .onDisappear {
            guard shareSheet == nil else { return }
            // The main import is owned by the model and survives navigation.
            // Auxiliary source/cleanup checks remain tied to their visible UI.
            streamTask?.cancel()
            cleanupSourceCheckMessage = nil; cleanupSourceReport = nil; confirmsSourceRetirement = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                model.pauseActiveImport(reason: .appBackground); streamTask?.cancel()
                cleanupSourceCheckMessage = nil; cleanupSourceReport = nil; confirmsSourceRetirement = false
            }
        }
    }

    private func performPrimaryAction() {
        guard presentation.isEnabled else { return }
        switch presentation.action {
        case .select: shareSheet = .selection
        case .permission:
            if model.authorization == .notDetermined { Task { await model.requestAccess() } }
            else if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .connect: shareSheet = .connection
        case .start: startImport()
        case .resume, .retry: startImport(sealVerifiedSubset: model.shareTask.intent == .sealReceived)
        case .pause: pauseImportIfNeeded()
        case .macNextStep: shareSheet = .macNextStep
        case .none: break
        }
    }
    private func pauseImportIfNeeded() {
        model.pauseActiveImport()
    }
    private func startImport(sealVerifiedSubset: Bool = false) {
        guard !workBusy, remoteModel.isConnected, !model.sharedSelections.isEmpty else { return }
        do {
            try model.beginShareTask(target: targetName, hostID: remoteModel.savedPairingHostID,
                fingerprint: remoteModel.savedPairingFingerprint, includeAlbumCatalog: includeAlbumCatalog,
                intent: sealVerifiedSubset ? .sealReceived : .transferSelection)
        } catch {
            model.errorMessage = error.localizedDescription
            return
        }
        remoteModel.setMigrationPhase("准备目录与整理信息")
        isStreamingArchive = true
        model.activeImportTask = Task {
            defer {
                isStreamingArchive = false; model.activeImportTask = nil
                remoteModel.recordMigrationOutcome(String(describing: model.shareTask.phase),
                    stopReason: model.shareTask.pauseReason?.rawValue)
            }
            do {
                let receipt = try await model.importSelectedPhotos(to: remoteModel, includeAlbumCatalog: includeAlbumCatalog, sealVerifiedSubset: sealVerifiedSubset)
                try model.receiveShareTask(receipt)
                let deferred = model.sharedSelections.count - receipt.itemCount
                model.shareTask.detail = (receipt.hostProcessingVersion == 1
                    ? "Mac 已接收 \(receipt.itemCount) 项照片与信息，可以拔线。完整校验、入库和收尾将在 Mac 继续；手机原件保留。"
                    : "Mac 已接收并复验 \(receipt.itemCount) 项照片与信息、\(receipt.resourceCount) 个资源。手机原件保留；此回执不代表已入库。")
                    + (deferred > 0 ? "另有 \(deferred) 项仍保留待处理，本次归档不包含这些项目。" : "")
            } catch is CancellationError {
                model.shareTask.pause()
                model.shareTask.detail = (model.shareTask.pauseReason?.message ?? "")
                    + "恢复原连接后可按原范围继续，Mac 已落盘进度保留。"
            } catch ImageAllUSBError.disconnected {
                model.shareTask.pause(reason: .usbDisconnected)
                model.shareTask.detail = (model.shareTask.pauseReason?.message ?? "")
                    + "恢复原 Mac 连接后手动继续，已落盘进度保留；不会自动改走网络。"
            } catch {
                remoteModel.recordMigrationOutcome("error", error: error)
                if model.shareTask.phase == .pausing {
                    model.shareTask.pause()
                    model.shareTask.detail = (model.shareTask.pauseReason?.message ?? "")
                        + "旧进度保留。结束阶段：\(remoteModel.migrationPhase)；\(error.localizedDescription)"
                } else {
                    model.shareTask.phase = .failed
                    model.shareTask.detail = "\(remoteModel.migrationPhase)：\(error.localizedDescription)"
                }
            }
        }
    }

    @ViewBuilder private var conflictSections: some View {
            if !model.sharedConflicts.isEmpty {
                Section("整理信息冲突") {
                    ForEach(model.sharedConflicts) { operation in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(operation.field == "favorite.target"
                                 ? "收藏目标"
                                 : (operation.referenceName ?? "字段身份待确认"))
                                .font(.headline)
                            if operation.field.hasPrefix("collection.") {
                                Text("资产 \(operation.assetID.uuidString.prefix(8)) · 本机成员：\(membershipName(operation.localCurrentIncluded))")
                                    .font(.footnote)
                                if let revision = operation.conflictRevision {
                                    Text("已知 Mac 版本 \(revision)：\(membershipName(operation.conflictValue.map { $0 == "1" }))")
                                        .font(.footnote)
                                }
                                if let name = operation.verifiedCollectionRename {
                                    Text("已核对为同一集合，Mac 已将其改名为“\(name)”。请选择成员状态。")
                                        .font(.footnote)
                                }
                                if operation.conflictReason == .fieldVersion || operation.verifiedCollectionRename != nil,
                                   operation.conflictValue == "0" || operation.conflictValue == "1",
                                   operation.conflictRevision != nil {
                                    HStack {
                                        Button("采用已知 Mac 成员状态") {
                                            Task {
                                                await model.resolveSharedCollectionConflict(
                                                    operation, resolution: .acceptMac
                                                )
                                            }
                                        }
                                        Button("保留本机，待下次同步") {
                                            Task {
                                                await model.resolveSharedCollectionConflict(
                                                    operation, resolution: .keepPhone
                                                )
                                            }
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                } else {
                                    Text("集合身份需要先对账；当前保留本机意图。")
                                        .font(.footnote)
                                        .foregroundStyle(.orange)
                                    if operation.conflictReason == .collectionIdentity {
                                        Button(isCheckingCollectionHistory ? "正在核对改名历史…" : "从 Mac 核对改名历史") {
                                            Task {
                                                isCheckingCollectionHistory = true
                                                defer { isCheckingCollectionHistory = false }
                                                do {
                                                    let name = try await model.recoverSharedCollectionRenameHistory(
                                                        operation, remoteModel: remoteModel
                                                    )
                                                    statusMessage = "已核对为集合“\(name)”。请在冲突项中选择成员状态；尚未重发操作。"
                                                } catch {
                                                    statusMessage = "改名历史尚不能证明此身份。请先完成同步；历史缺失、范围或身份变化仍需对账。\(error.localizedDescription)"
                                                }
                                            }
                                        }
                                        .disabled(isCheckingCollectionHistory || isSending || !remoteModel.supportsLocalLibraryCollectionChanges)
                                    }
                                }
                            } else if operation.field == "favorite.target" {
                                Text("资产 \(operation.assetID.uuidString.prefix(8)) · 本机收藏目标：\(favoriteName(operation.localCurrentFavoriteTarget))")
                                    .font(.footnote)
                                if let revision = operation.conflictRevision {
                                    Text("已知 Mac 版本 \(revision)：\(favoriteName(operation.conflictValue.map { $0 == "1" }))")
                                        .font(.footnote)
                                }
                                if operation.conflictReason == .fieldVersion,
                                   operation.conflictValue == "0" || operation.conflictValue == "1",
                                   operation.conflictRevision != nil {
                                    HStack {
                                        Button("采用已知 Mac 收藏目标") {
                                            Task {
                                                await model.resolveSharedFavoriteConflict(
                                                    operation, resolution: .acceptMac
                                                )
                                            }
                                        }
                                        Button("保留本机，待下次同步") {
                                            Task {
                                                await model.resolveSharedFavoriteConflict(
                                                    operation, resolution: .keepPhone
                                                )
                                            }
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                    Text("采用 Mac 目标只更新 ImageAll；来源系统收藏需在照片详情中另行写回。")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Mac 未提供可处理的收藏版本，当前保留本机意图。")
                                        .font(.footnote)
                                        .foregroundStyle(.orange)
                                }
                            } else {
                                Text("资产 \(operation.assetID.uuidString.prefix(8)) · 本机：\(decisionName(operation.localCurrentDecision))")
                                    .font(.footnote)
                                if let revision = operation.conflictRevision {
                                    Text("已知 Mac 版本 \(revision)：\(decisionName(operation.conflictDecision))")
                                        .font(.footnote)
                                }
                                if operation.conflictReason == .fieldVersion,
                                   operation.conflictDecision != nil,
                                   operation.conflictRevision != nil {
                                    HStack {
                                        Button("采用已知 Mac 决定") {
                                            Task {
                                                await model.resolveSharedTagConflict(
                                                    operation, resolution: .acceptMac
                                                )
                                            }
                                        }
                                        Button("保留本机，待下次同步") {
                                            Task {
                                                await model.resolveSharedTagConflict(
                                                    operation, resolution: .keepPhone
                                                )
                                            }
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                } else {
                                    Text(operation.conflictReason == nil
                                         ? "Mac 未提供冲突类型；更新 Mac 后再对账。"
                                         : "标签身份需要先对账；当前不能直接覆盖或合并。")
                                        .font(.footnote)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
            }
            if let candidate = tagAliasCandidate {
                Section("核对标签身份") {
                    Text("Mac 标签“\(candidate.remoteTagName)”（\(candidate.remoteTagID.uuidString.prefix(8))）与本机标签“\(candidate.localTagName)”（\(candidate.localTagID.uuidString.prefix(8))）名称相近，但身份不同。确认后，本机标签 ID 保留；此 Mac 的共享同步会使用已确认的对应关系。")
                        .font(.footnote)
                    Button("确认这两个标签是同一个") {
                        Task {
                            do {
                                try await model.confirmSharedTagAlias(candidate)
                                tagAliasCandidate = nil
                                statusMessage = "标签身份对应关系已保存。请再次同步，重取未提交的 Mac 变化页。"
                            } catch {
                                statusMessage = "标签身份已变化或已有共享记录；请重新同步核对。\(error.localizedDescription)"
                                tagAliasCandidate = nil
                            }
                        }
                    }
                    Button("暂不合并", role: .cancel) {
                        tagAliasCandidate = nil
                        statusMessage = "标签身份未合并；Mac 变化页和 cursor 保持原状。"
                    }
                }
            }
            if let candidate = collectionAliasCandidate {
                Section("核对相册身份") {
                    Text("Mac 相册“\(candidate.remoteCollectionName)”（\(candidate.remoteCollectionID.uuidString.prefix(8))）与本机相册“\(candidate.localCollectionName)”（\(candidate.localCollectionID.uuidString.prefix(8))）名称相近，但身份不同。确认后，本机相册 ID 保留；此 Mac 的共享同步会使用已确认的对应关系。")
                        .font(.footnote)
                    Button("确认这两个相册是同一个") {
                        Task {
                            do {
                                try await model.confirmSharedCollectionAlias(candidate)
                                collectionAliasCandidate = nil
                                statusMessage = "相册身份对应关系已保存。请再次同步，重取未提交的 Mac 变化页。"
                            } catch {
                                statusMessage = "相册身份已变化或已有共享记录；请重新同步核对。\(error.localizedDescription)"
                                collectionAliasCandidate = nil
                            }
                        }
                    }
                    Button("暂不合并相册", role: .cancel) {
                        collectionAliasCandidate = nil
                        statusMessage = "相册身份未合并；Mac 变化页和 cursor 保持原状。"
                    }
                }
            }
    }
    private var syncSection: some View {
            Section {
                Button(isSending ? "正在提交…" : "同步目录与整理信息到 Mac") {
                    guard !workBusy else { return }
                    isSending = true
                    Task {
                        defer { isSending = false }
                        do {
                            let snapshot = try await model.prepareSharedSnapshotRecoveringReceipt(
                                from: remoteModel
                            )
                            let receipt = try await remoteModel.submitLocalLibrarySnapshot(snapshot) {
                                try await model.validateSharedSnapshotScope(snapshot)
                            }
                            do {
                                let result = try await model.completeSharedSync(
                                    snapshot: snapshot, receipt: receipt,
                                    remoteModel: remoteModel
                                )
                                tagAliasCandidate = nil
                                collectionAliasCandidate = nil
                                let pull = result.pullSupported
                                    ? "Mac 标签回传 \(result.received) 项"
                                    : "当前 Mac 版本尚无标签回传"
                                let continuation = result.pullHasMore
                                    || result.collectionPullHasMore
                                    || result.favoritePullHasMore
                                    ? "Mac 仍有后续变化页，请再次同步。" : ""
                                let collectionPull = result.collectionPullSupported
                                    ? "Mac 集合回传 \(result.collectionReceived) 项"
                                    : "当前 Mac 版本尚无集合回传"
                                let favoritePull = result.favoritePullSupported
                                    ? "Mac 收藏目标回传 \(result.favoriteReceived) 项"
                                    : "当前 Mac 版本尚无收藏目标回传"
                                statusMessage = "Mac 已接收 \(receipt.acceptedAssetCount) 项目录；手机标签/集合成员/收藏目标提交 \(result.applied) 项、已一致 \(result.unchanged) 项；\(pull)、\(collectionPull)、\(favoritePull)、冲突 \(result.conflicts) 项；仍待处理 \(result.remaining) 项。\(continuation)原件尚未传输。"
                            } catch {
                                if case LocalLibraryError.syncRemoteTagAliasRequired(let candidate) = error {
                                    tagAliasCandidate = candidate
                                    collectionAliasCandidate = nil
                                    statusMessage = "Mac 已接收目录；回传标签需要你确认同名不同 ID 的身份。变化页和 cursor 均未提交。"
                                } else if case LocalLibraryError.syncRemoteCollectionAliasRequired(let candidate) = error {
                                    collectionAliasCandidate = candidate
                                    tagAliasCandidate = nil
                                    statusMessage = "Mac 已接收目录；回传相册需要你确认同名不同 ID 的身份。变化页和 cursor 均未提交。"
                                } else if case LocalLibraryError.syncRemoteTagMismatch = error {
                                    statusMessage = "Mac 已接收目录，但回传标签与本机标签身份冲突。该变化页和 cursor 均未提交；请先核对同名不同 ID 或标签名称差异，当前版本不会自动合并。"
                                } else if case LocalLibraryError.syncRemoteCollectionMismatch = error {
                                    statusMessage = "Mac 已接收目录，但回传集合与本机集合身份冲突。集合变化页和 cursor 均未提交；同名不同 ID 不会自动合并。"
                                } else {
                                    statusMessage = "Mac 已接收目录，但整理信息提交未完成：\(error.localizedDescription)"
                                }
                            }
                        } catch {
                            statusMessage = "同步未完成：\(error.localizedDescription)"
                        }
                    }
                }
                .disabled(workBusy || !remoteModel.isConnected)
                if let statusMessage {
                    Text(statusMessage).font(.footnote).foregroundStyle(.secondary)
                }
                Text("只整理信息时可在此手动同步；导入照片请返回“待分享”，使用固定导入入口一起发送原件与信息。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
    }

    private var advancedSection: some View {
        Section("迁移验收与来源核对") {
            if isStreamingArchive {
                Text("当前正在执行核对操作，请保持前台与连接。").font(.footnote)
                Button("停止等待当前操作") { streamTask?.cancel() }
            }
            Text("只有完成 Mac 入库、独立备份与逐项核验后才进入此流程。接收回执不代表允许清理；原有来源核验和系统确认仍须完成。")
                .font(.footnote).foregroundStyle(.secondary)
            Button(isFetchingCleanupRecheck ? "正在读取核对请求…" : "查看 Mac 清理核对请求") {
                Task {
                    guard !isFetchingCleanupRecheck else { return }
                    isFetchingCleanupRecheck = true
                    cleanupRecheck = nil
                    cleanupSourceReport = nil
                    cleanupSourceCheckMessage = nil
                    defer { isFetchingCleanupRecheck = false }
                    do {
                        if let request = try await remoteModel.fetchPhoneCleanupRecheck() {
                            try await model.validateCleanupRecheckIdentity(request)
                            cleanupRecheck = request
                            archiveStatusMessage = "已收到 Mac 来源核对请求；尚未核验当前原件，也未执行删除。"
                        } else {
                            archiveStatusMessage = "没有当前有效的核对请求。请先在 Mac 完成独立备份预检并请求手机核对。"
                        }
                    } catch { archiveStatusMessage = "读取核对请求失败：\(error.localizedDescription)" }
                }
            }.disabled(workBusy)
            if let request = cleanupRecheck {
                Text("Mac 预检记录：\(request.candidateCount) 项待来源核对，\(request.favoriteProtectedCount) 项收藏保护。")
                Text("收到请求不代表允许删除。后续仍需逐项复查当前原件版本和收藏，再由您在手机前台确认。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(isStreamingArchive ? "正在核对…" : "核对当前手机来源（只读）") {
                    guard !isStreamingArchive else { return }
                    cleanupSourceCheckMessage = nil
                    cleanupSourceReport = nil
                    isStreamingArchive = true
                    streamTask = Task {
                        defer { isStreamingArchive = false; streamTask = nil }
                        do {
                            let checked = try await model.recheckCleanupSources(request, remote: remoteModel)
                            let count = checked.plan.snapshot.assets.count
                            let report = RemotePhoneCleanupSourceReport(id: checked.plan.sourceReportID, request: request,
                                checkedAtMs: Int64(Date().timeIntervalSince1970 * 1_000), verifiedItemCount: count)
                            try Task.checkCancellation()
                            do { try await remoteModel.submitPhoneCleanupSourceReport(report) }
                            catch {
                                cleanupSourceCheckMessage = "本机来源复查通过，但回传 Mac 未确认：\(error.localizedDescription)。请重新复查后回传；本次未执行删除。"
                                return
                            }
                            try Task.checkCancellation()
                            cleanupSourceReport = report
                            cleanupSourceCheckMessage = "Mac 已接收本次来源检查记录。已复查 \(count) 项原件与整理信息，\(request.favoriteProtectedCount) 项收藏继续保护。未执行删除；仍需 Mac 当前副本复核和手机前台确认。"
                        } catch is CancellationError {
                            cleanupSourceCheckMessage = "来源复查已取消，未形成通过结果。"
                        } catch {
                            cleanupSourceCheckMessage = "来源复查未通过：\(error.localizedDescription)"
                        }
                    }
                }.disabled(workBusy)
                if let report = cleanupSourceReport {
                    Button("请求 Mac 重新核验副本") {
                        guard !isStreamingArchive else { return }
                        isStreamingArchive = true
                        cleanupSourceCheckMessage = "Mac 正在逐项核验归档与独立备份，请保持前台和连接。"
                        streamTask = Task {
                            defer { isStreamingArchive = false; streamTask = nil }
                            do {
                                _ = try await remoteModel.recheckMacCopies(for: report)
                                cleanupSourceCheckMessage = "Mac 本次归档与独立备份复核通过。来源检查与前台删除确认仍须另行完成；未执行删除。"
                            } catch is CancellationError {
                                cleanupSourceCheckMessage = "已停止等待副本核验；Mac 只读检查可能仍在结束，未执行删除。"
                            } catch { cleanupSourceCheckMessage = "副本核验未通过：\(error.localizedDescription)" }
                        }
                    }.disabled(workBusy)
                }
                if let report = cleanupSourceReport, report.request.candidateCount > 0 {
                    Button("从系统照片删除已迁移的非收藏项…", role: .destructive) {
                        confirmsSourceRetirement = true
                    }.disabled(workBusy)
                    .confirmationDialog("从系统照片删除 \(report.request.candidateCount) 项？",
                        isPresented: $confirmsSourceRetirement, titleVisibility: .visible) {
                        Button("重新核验后从系统照片删除", role: .destructive) {
                            guard !isStreamingArchive else { return }
                            isStreamingArchive = true
                            cleanupSourceCheckMessage = "正在重新检查手机来源及 Mac 两份副本，通过后交由系统确认。"
                            streamTask = Task {
                                defer { isStreamingArchive = false; streamTask = nil; cleanupSourceReport = nil }
                                do {
                                    let result = try await model.retireCleanupSources(report, remote: remoteModel)
                                    switch result.state {
                                    case .completed: cleanupSourceCheckMessage = "系统已确认删除 \(result.plan.candidateAssetIDs.count) 项，来源退役已记录。Mac 独立归档和整理事实保留；恢复请前往系统照片，空间不保证立即释放。"
                                    case .failed: cleanupSourceCheckMessage = "系统未确认删除，或提交前条件已变化；未记为退役。"
                                    default: cleanupSourceCheckMessage = "来源操作结果未确定，已保留记录，不会自动重试。"
                                    }
                                    if !result.acknowledgedByMac {
                                        cleanupSourceCheckMessage = (cleanupSourceCheckMessage ?? "") + " Mac 尚未确认收到，可在清理记录中回传。"
                                    }
                                } catch { cleanupSourceCheckMessage = "来源清理未完成：\(error.localizedDescription)。若已提交系统，记录会保留，不会自动重试。" }
                            }
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("收藏项保留。此操作从 Photos 图库删除，并非只清除本机缓存；若系统启用了外部同步，删除可能传播。Mac 独立归档保留。不清空最近删除，恢复请前往系统照片。")
                    }
                }
                if let cleanupSourceCheckMessage {
                    Text(cleanupSourceCheckMessage).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Button("查看来源清理记录") {
                Task {
                    do {
                        retirementHistory = try await model.sourceRetirementHistory()
                        if retirementHistory.isEmpty { archiveStatusMessage = "暂无来源清理记录。" }
                    } catch { archiveStatusMessage = error.localizedDescription }
                }
            }.disabled(workBusy)
            ForEach(Array(retirementHistory.prefix(20))) { record in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(record.plan.candidateAssetIDs.count) 项 · \(Date(timeIntervalSince1970: Double(record.updatedAtMs) / 1_000).formatted(date: .abbreviated, time: .shortened))")
                    switch record.state {
                    case .prepared:
                        Text("尚未提交系统，可取消这条准备记录。")
                        Button("取消未提交记录") {
                            Task {
                                do {
                                    try await model.cancelPreparedSourceRetirement(record.id)
                                    retirementHistory = try await model.sourceRetirementHistory()
                                } catch { archiveStatusMessage = error.localizedDescription }
                            }
                        }.disabled(workBusy)
                    case .submitted, .outcomeUnknown:
                        Text("提交结果待核实，不会自动重试。请先在系统照片检查；暂时不可见不代表已删除。")
                        if record.canManuallyClose {
                            Button("核实后结束待核实记录…") { closesUnknownRetirement = record }
                                .disabled(workBusy)
                        } else {
                            Text("本次启动内可能仍有系统回调；请先重启 App，再核实和结束记录。")
                        }
                    case .closedUnknown: Text("用户已结束待核实记录，结果仍未知。未据此认定成功或失败，旧操作不会重试。")
                    case .completed: Text("系统曾确认删除，来源退役已记录。恢复请前往系统照片。")
                    case .cancelled: Text("已取消准备，未提交系统。")
                    case .failed: Text("系统未确认删除或提交前检查未通过。")
                    }
                    if [.completed, .failed, .submitted, .outcomeUnknown, .closedUnknown].contains(record.state) {
                        Text(record.acknowledgedByMac ? "Mac 已确认收到本条结果。" : "本条结果待回传 Mac。")
                        if !record.acknowledgedByMac {
                            Button("回传本条记录（不重复删除）") {
                                Task {
                                    do {
                                        try await model.sendSourceRetirement(record.id, remote: remoteModel)
                                        retirementHistory = try await model.sourceRetirementHistory()
                                    } catch { archiveStatusMessage = "回传未确认：\(error.localizedDescription)" }
                                }
                            }.disabled(workBusy)
                        }
                    }
                }.font(.footnote).foregroundStyle(.secondary)
            }

            Color.clear.frame(height: 0)
                .confirmationDialog("结束这条待核实记录？", isPresented: Binding(
                    get: { closesUnknownRetirement != nil },
                    set: { if !$0 { closesUnknownRetirement = nil } }), titleVisibility: .visible,
                    presenting: closesUnknownRetirement) { record in
                    Button("已核实，结束记录") {
                        Task {
                            do {
                                try await model.closeUnknownSourceRetirement(record.id, remote: remoteModel)
                                retirementHistory = try await model.sourceRetirementHistory()
                                archiveStatusMessage = "已结束待核实记录，结果仍未知。未执行照片操作；后续清理必须重新核验并明确确认。"
                            } catch { archiveStatusMessage = "无法结束记录：\(error.localizedDescription)" }
                            closesUnknownRetirement = nil
                        }
                    }
                    Button("保留待核实", role: .cancel) { closesUnknownRetirement = nil }
                } message: { record in
                    Text("请先在系统照片核实这批 \(record.plan.candidateAssetIDs.count) 项，并确认 Mac 归档和备份保留。结束记录只停止等待旧回调，不判定删除成功或失败，也不再次删除。若以后再清理，必须重新核验和确认。")
                }

            Button("查找逐资源批次以继续来源验收") {
                do {
                    savedStreamingArchives = try LocalPhotoArchiveExporter.existingStreamingArchives()
                    if savedStreamingArchives.isEmpty {
                        archiveStatusMessage = "没有已保存回执的逐资源批次；若上次响应丢失或由旧版生成，请按原来源和范围重试传输。"
                    }
                } catch { archiveStatusMessage = "读取逐资源批次失败：\(error.localizedDescription)" }
            }
            .disabled(workBusy)
            ForEach(savedStreamingArchives) { archive in
                Button("为批次 \(archive.migrationID.uuidString.prefix(8)) 生成并上传来源检查点") {
                    guard !isStreamingArchive else { return }
                    isStreamingArchive = true
                    streamTask = Task {
                        defer { isStreamingArchive = false; streamTask = nil }
                        do {
                            _ = try await model.submitStreamingCompletionCheckpoint(at: archive.root, to: remoteModel)
                            archiveStatusMessage = "同批次已重新核对 Mac 归档与手机来源，并提交整理事实及同步水位。请在 Mac 再次入库、核查和独立恢复；这不是最终迁移完成回执。"
                        } catch is CancellationError {
                            archiveStatusMessage = "来源验收已暂停，批次记录保留，可重试。"
                        } catch { archiveStatusMessage = "来源检查点未提交：\(error.localizedDescription)" }
                    }
                }
                .disabled(workBusy || !remoteModel.isConnected)
            }
            if let exportedArchive {
                Button(isUploadingArchive ? "正在上传检查点…" : "生成并上传验收检查点") {
                    guard !workBusy else { return }
                    isUploadingArchive = true
                    Task {
                        defer { isUploadingArchive = false }
                        do {
                            let facts = try await model.exportCompletionCheckpointFacts(
                                for: exportedArchive
                            )
                            try await Task.detached(priority: .utility) {
                                try LocalMigrationFactExporter.attach(
                                    facts, to: exportedArchive
                                )
                            }.value
                            exportedFacts = facts
                            _ = try await remoteModel.uploadMigrationArchive(
                                at: exportedArchive
                            )
                            archiveStatusMessage = "手机已逐资源复核来源并提交事实水位候选；请在 Mac 再次入库并核查。Mac 变化水位和独立恢复仍待验收。"
                        } catch {
                            archiveStatusMessage = "验收检查点未提交：\(error.localizedDescription)"
                        }
                    }
                }
                .disabled(!exportedArchiveComplete || !remoteModel.isConnected
                          || workBusy)
            }
            if let archiveStatusMessage { Text(archiveStatusMessage).font(.footnote) }
        }
    }
    private var offlineSection: some View {
        Section("离线归档与整理信息快照") {
            Button(isExporting ? "正在读取并核对原件…" : "生成所选项目的本机归档包") {
                guard !workBusy else { return }
                isExporting = true
                Task {
                    exportedArchive = nil
                    exportedArchiveComplete = false
                    exportedVerification = nil
                    archiveStatusMessage = nil
                    defer { isExporting = false }
                    do {
                        let (url, verification) = try await model.exportSelectedArchive(includeAlbumCatalog: includeAlbumCatalog)
                        exportedArchive = url
                        exportedArchiveComplete = verification.isComplete
                        exportedVerification = verification
                        archiveStatusMessage = archiveSummary(verification)
                    } catch {
                        archiveStatusMessage = "归档未完成：\(error.localizedDescription)"
                    }
                }
            }
            .disabled(workBusy || model.sharedSelections.isEmpty)
            if let exportedArchive {
                LocalArchiveShareButton(
                    url: exportedArchive, isComplete: exportedArchiveComplete
                )
                Button(isUploadingArchive ? "正在分片上传到 Mac…" : "上传已校验归档到 Mac") {
                    guard !workBusy else { return }
                    isUploadingArchive = true
                    Task {
                        defer { isUploadingArchive = false }
                        do {
                            let receipt = try await remoteModel.uploadMigrationArchive(
                                at: exportedArchive
                            )
                            archiveStatusMessage = "Mac 已接收并复验 \(receipt.itemCount) 项、\(receipt.resourceCount) 个资源；请在 Mac 接收目录中点击入库。此回执不是迁移完成确认。"
                        } catch {
                            archiveStatusMessage = "上传未完成；重连后可继续同一归档：\(error.localizedDescription)"
                        }
                    }
                }
                .disabled(!exportedArchiveComplete || !remoteModel.isConnected
                          || workBusy)
            }
            Button("查找本机已生成的归档以继续上传") {
                do {
                    savedArchives = try LocalPhotoArchiveExporter.existingArchives()
                    if savedArchives.isEmpty {
                        archiveStatusMessage = "本机没有可继续上传的归档包。"
                    }
                } catch {
                    archiveStatusMessage = "读取已有归档失败：\(error.localizedDescription)"
                }
            }
            .disabled(workBusy)
            ForEach(savedArchives, id: \.self) { archive in
                Button("选用归档 \(archive.deletingPathExtension().lastPathComponent)") {
                    guard !workBusy else { return }
                    isExporting = true
                    Task {
                        defer { isExporting = false }
                        exportedArchive = nil
                        exportedArchiveComplete = false
                        exportedVerification = nil
                        do {
                            let verification = try await Task.detached(priority: .utility) {
                                try ImageAllMigrationArchive.verify(at: archive)
                            }.value
                            exportedArchive = archive
                            exportedArchiveComplete = verification.isComplete
                            exportedVerification = verification
                            archiveStatusMessage = verification.isComplete
                                ? "已选用现有完整归档；连接 Mac 后会从接收端已提交的分片继续上传。"
                                : archiveSummary(verification)
                        } catch {
                            archiveStatusMessage = "现有归档不可继续上传：\(error.localizedDescription)"
                        }
                    }
                }
                .disabled(workBusy)
            }
            Button(isExportingFacts ? "正在生成整理信息快照…" : "导出最新整理信息快照") {
                guard !workBusy else { return }
                isExportingFacts = true
                Task {
                    exportedFacts = nil
                    defer { isExportingFacts = false }
                    do {
                        exportedFacts = try await model.exportSelectedFacts()
                        archiveStatusMessage = "整理信息快照已生成；请在 Mac 选中对应归档批次后导入。此操作不代表迁移完成。"
                    } catch {
                        archiveStatusMessage = "整理信息快照未生成：\(error.localizedDescription)"
                    }
                }
            }
            .disabled(workBusy || model.sharedSelections.isEmpty)
            if let exportedFacts {
                LocalFactsShareButton(url: exportedFacts)
            }
            if let exportedArchive {
                Button(isUploadingArchive ? "正在上传整理信息…" : "生成并上传最新整理信息到 Mac") {
                    guard !workBusy else { return }
                    isUploadingArchive = true
                    Task {
                        defer { isUploadingArchive = false }
                        do {
                            let facts = try await model.exportSelectedFacts()
                            try await Task.detached(priority: .utility) {
                                try LocalMigrationFactExporter.attach(
                                    facts, to: exportedArchive
                                )
                            }.value
                            exportedFacts = facts
                            let receipt = try await remoteModel.uploadMigrationArchive(
                                at: exportedArchive
                            )
                            archiveStatusMessage = "Mac 已复验最新整理信息；请在 Mac 对同一批次再次点击入库以对账。已接收 \(receipt.itemCount) 项，此回执不是迁移完成确认。"
                        } catch {
                            archiveStatusMessage = "整理信息上传未完成：\(error.localizedDescription)"
                        }
                    }
                }
                .disabled(!exportedArchiveComplete || !remoteModel.isConnected
                          || workBusy)

            }
            if let archiveStatusMessage {
                Text(archiveStatusMessage).font(.footnote).foregroundStyle(.secondary)
            }
            if let exportedVerification,
               !exportedVerification.unavailableResources.isEmpty {
                DisclosureGroup("不可用资源 · \(exportedVerification.unavailableResources.count) 项") {
                    ForEach(exportedVerification.unavailableResources, id: \.resourceID) { resource in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("资产 \(resource.mediaID.uuidString.prefix(8)) · \(resource.role)")
                            Text(unavailableResourceReason(resource.status))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                    }
                }
            }
            Text("仅读取当前获准访问的所选项目，不从 iCloud 下载。生成中断后，再次生成相同范围会核对并复用已暂存资源；来源或范围变化则另建批次。暂存占用手机空间，尚未提供自动清理。Mac 入库与迁移完成校验仍需后续步骤。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func decisionName(_ decision: LocalDecision?) -> String {
        switch decision {
        case .accepted: "接受"
        case .rejected: "拒绝"
        case .cleared: "清除"
        case nil: "未知"
        }
    }

    private func archiveSummary(_ verification: ImageAllMigrationVerification) -> String {
        if verification.isComplete {
            return "归档 \(verification.itemCount) 项，逐项校验 \(verification.resourceCount) 个资源；已声明资源完整。可继续上传，Mac 入库与完成验收仍需后续步骤。"
        }
        return "归档 \(verification.itemCount) 项，已校验 \(verification.resourceCount) 个资源；\(verification.unavailableResources.count) 个资源不可用，其中 \(verification.incompleteMediaIDs.count) 项资产缺少必需资源。下方列出原因；当前版本不能上传含资源缺口的归档，修复后需重新生成。"
    }

    private func unavailableResourceReason(
        _ status: ImageAllMigrationResourceStatus
    ) -> String {
        switch status {
        case .present: "已存在"
        case .notLocal: "原件当前不在本机；本期不从 iCloud 下载"
        case .permissionDenied: "当前照片权限不足"
        case .unsupported: "该资源类型暂不支持"
        }
    }

    private func membershipName(_ included: Bool?) -> String {
        switch included {
        case true: "包含"
        case false: "不包含"
        case nil: "未知"
        }
    }

    private func favoriteName(_ target: Bool?) -> String {
        switch target {
        case true: "收藏"
        case false: "取消收藏"
        case nil: "未知"
        }
    }
}

private enum LocalArchiveExportError: LocalizedError {
    case emptySelection
    case selectionNotVisible
    case selectionChanged
    case sourceChanged
    case resumeResourceMismatch
    case subsetRequiresVerifiedResources
    case localResourcesPending(Int)
    case selectedAssetsPending(Int)
    case incompleteArchive
    case archiveScopeChanged
    case syncPending
    case syncNotAcknowledged

    var errorDescription: String? {
        switch self {
        case .emptySelection: "请先选择要归档的照片或视频。"
        case .selectionNotVisible: "所选项目中有当前无权访问或已隐藏的资产；请先恢复访问，再生成完整范围归档。"
        case .selectionChanged: "导出期间分享范围已变化；请重新生成归档。"
        case .sourceChanged: "导出期间来源照片或视频已变化；请重新生成归档。"
        case .subsetRequiresVerifiedResources: "封存已接收项目需要原批次每个资源的匹配回执；当前证据不足。没有重新上传原件，原选择与断点保留。"
        case .resumeResourceMismatch: "待恢复缓存无法对应当前所选原件，旧进度已保留；请核对照片范围和版本。"
        case .localResourcesPending(let count): "已有可读取原件已发送并保留进度；还有 \(count) 个资源暂时无法从手机本地读取。整批尚未完成，原件在本地可用后重试即可继续，不会自动下载 iCloud 原件。"
        case .selectedAssetsPending(let count): "当前可访问的项目已传输并保留进度；还有 \(count) 项暂时不可访问，仍保留在待分享范围。请恢复这些项目的访问，或在预览中确认后调整选择；整批尚未完成。"
        case .incompleteArchive: "现有归档缺少必需原件，不能上传为完整迁移归档。"
        case .archiveScopeChanged: "整理信息范围或来源与此归档不一致，请重新选择对应归档。"
        case .syncPending: "仍有待发送整理操作或未解决冲突；请先同步并处理，再生成验收检查点。"
        case .syncNotAcknowledged: "当前分享范围尚无 Mac 确认；请先同步目录与整理信息。"
        }
    }
}

private struct LocalMigrationArchiveTransfer: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(
            exportedContentType: UTType(exportedAs: "com.gwlee.imageall.migration-archive")
        ) { archive in
            SentTransferredFile(archive.url)
        }
    }
}

private struct LocalArchiveShareButton: View {
    let url: URL
    let isComplete: Bool

    var body: some View {
        ShareLink(
            item: LocalMigrationArchiveTransfer(url: url),
            preview: SharePreview("ImageAll 原件归档包")
        ) {
            Text(isComplete
                 ? "导出归档包到文件或其他 App"
                 : "导出不完整归档供排查（不能用于迁移完成）")
        }
    }
}

private struct LocalMigrationFactsTransfer: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(
            exportedContentType: UTType(exportedAs: "com.gwlee.imageall.migration-facts")
        ) { facts in
            SentTransferredFile(facts.url)
        }
    }
}

private struct LocalFactsShareButton: View {
    let url: URL

    var body: some View {
        ShareLink(
            item: LocalMigrationFactsTransfer(url: url),
            preview: SharePreview("ImageAll 整理信息快照")
        ) {
            Text("导出整理信息快照到文件或其他 App")
        }
    }
}

private enum LocalMigrationFactExporter {
    static func attach(_ snapshotURL: URL, to archiveRoot: URL) throws {
        let read = try ImageAllMigrationFacts.readWithDigest(at: snapshotURL)
        let snapshot = read.snapshot
        var header: ImageAllMigrationHeader?
        var mediaIDs = Set<UUID>()
        var highestFactRevision: Int64 = 0
        let verification = try ImageAllMigrationArchive.visitVerifiedRecords(
            at: archiveRoot,
            onHeader: { header = $0 },
            onItem: { item in
                mediaIDs.insert(item.mediaID)
                highestFactRevision = max(highestFactRevision, item.factRevision)
            }
        )
        guard let header, verification.isComplete,
              snapshot.sourceDeviceID == header.sourceDeviceID,
              snapshot.sourceEpoch == header.sourceEpoch,
              snapshot.scopeRevision == header.scopeRevision,
              snapshot.snapshotSequence >= header.inventoryWatermark,
              snapshot.factWatermark >= highestFactRevision,
              Set(snapshot.items.map(\.mediaID)) == mediaIDs else {
            throw LocalArchiveExportError.archiveScopeChanged
        }
        if let checkpoint = snapshot.syncCheckpoint {
            guard checkpoint.archiveManifestSHA256 == verification.manifestSHA256,
                  checkpoint.sourceVerifiedAtMs != nil else {
                throw LocalArchiveExportError.sourceChanged
            }
        }
        if let currentURL = try ImageAllMigrationFacts.latestPublishedURL(in: archiveRoot) {
            let current = try ImageAllMigrationFacts.readWithDigest(at: currentURL)
            guard snapshot.snapshotSequence > current.snapshot.snapshotSequence ||
                    (snapshot.snapshotSequence == current.snapshot.snapshotSequence
                     && read.sha256 == current.sha256) else {
                throw LocalArchiveExportError.archiveScopeChanged
            }
        }
        let factDirectory = archiveRoot.appendingPathComponent(
            ImageAllMigrationFacts.sidecarDirectoryName, isDirectory: true
        )
        let existingNames = Set((try? FileManager.default.contentsOfDirectory(
            atPath: factDirectory.path
        )) ?? [])
        let published = try ImageAllMigrationFacts.publish(
            from: snapshotURL, into: archiveRoot
        )
        do {
            guard try ImageAllMigrationArchive.verify(at: archiveRoot).isComplete else {
                throw LocalArchiveExportError.incompleteArchive
            }
        } catch {
            if !existingNames.contains(published.lastPathComponent) {
                try? FileManager.default.removeItem(at: published)
            }
            throw error
        }
    }

    static func export(
        snapshot: LocalSharedSnapshot,
        checkpoint: LocalMigrationSyncCheckpoint? = nil,
        archiveManifestSHA256: String? = nil,
        sourceVerifiedAtMs: Int64? = nil
    ) throws -> URL {
        let items = factItems(from: snapshot)
        let facts = ImageAllMigrationFactSnapshot(
            sourceDeviceID: snapshot.installID, sourceEpoch: snapshot.sourceEpoch,
            scopeRevision: snapshot.scopeRevision,
            snapshotSequence: snapshot.snapshotSequence,
            factWatermark: snapshot.outboxWatermark, items: items,
            syncCheckpoint: checkpoint.map { local in
                ImageAllMigrationSyncCheckpoint(
                    hostID: local.hostID, deviceID: local.deviceID,
                    acknowledgedScopeRevision: local.acknowledgedScopeRevision,
                    acknowledgedSnapshotSequence: local.acknowledgedSnapshotSequence,
                    tagChangeCursor: local.tagChangeCursor,
                    collectionChangeCursor: local.collectionChangeCursor,
                    favoriteChangeCursor: local.favoriteChangeCursor,
                    tagAliases: local.tagAliases.map { alias in
                        ImageAllMigrationTagAlias(
                            localTagID: alias.localTagID,
                            localTagName: alias.localTagName,
                            remoteTagID: alias.remoteTagID,
                            remoteTagName: alias.remoteTagName
                        )
                    },
                    collectionAliases: local.collectionAliases.map { alias in
                        ImageAllMigrationCollectionAlias(
                            localCollectionID: alias.localCollectionID,
                            localCollectionName: alias.localCollectionName,
                            remoteCollectionID: alias.remoteCollectionID,
                            remoteCollectionName: alias.remoteCollectionName
                        )
                    },
                    archiveManifestSHA256: archiveManifestSHA256,
                    sourceVerifiedAtMs: sourceVerifiedAtMs
                )
            },
            auditRecords: snapshot.auditRecords?.map {
                ImageAllMigrationAuditRecord(operationID: $0.operationID, sequence: $0.sequence,
                    mediaID: $0.assetID, field: $0.field, value: $0.value, createdAtMs: $0.createdAtMs,
                    origin: $0.origin?.rawValue, referenceName: $0.referenceName)
            }
        )
        let manager = FileManager.default
        let support = try manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let parent = support.appendingPathComponent(
            "LocalLibrary/MigrationFacts", isDirectory: true
        )
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableParent = parent
        try mutableParent.setResourceValues(values)
        let url = parent.appendingPathComponent("\(UUID().uuidString).imageallfacts")
        try ImageAllMigrationFacts.write(facts, to: url)
        try manager.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path
        )
        return url
    }

    static func factItems(from snapshot: LocalSharedSnapshot) -> [ImageAllMigrationFactItem] {
        snapshot.assets.map { asset in
            ImageAllMigrationFactItem(
                mediaID: asset.id, observedFavorite: asset.observedFavorite,
                favoriteTarget: asset.favoriteTarget,
                tagDecisions: asset.tagDecisions.map { tag in
                    let decision: RemoteLocalLibraryDecision
                    switch tag.decision {
                    case .accepted: decision = .accepted
                    case .rejected: decision = .rejected
                    case .cleared: decision = .cleared
                    }
                    return ImageAllMigrationTagDecision(
                        tagID: tag.tagID, tagName: tag.tagName, decision: decision
                    )
                },
                collections: asset.collections.map { collection in
                    ImageAllMigrationCollectionMembership(
                        collectionID: collection.collectionID,
                        collectionName: collection.collectionName, included: true
                    )
                }
            )
        }
    }
}

#if DEBUG
@MainActor
func runSyntheticPhotoResourceCallbackProbe(
    progress: (@MainActor (Int64) -> Void)? = nil
) async throws -> [String: Any] {
    try await LocalPhotoArchiveExporter.syntheticResourceCallbackProbe(progress: progress)
}
#endif

private struct LocalStreamingArchive: Identifiable {
    let root: URL
    let migrationID: UUID
    var id: URL { root }
}

@MainActor
private enum LocalPhotoArchiveExporter {
    private struct SourceVersion: Codable, Equatable, Sendable {
        let modificationDate: Date?
        let creationDate: Date?
        let metadata: ImageAllMigrationSourceMetadata
        let resourceSignature: [String]
    }

    private final class ResourceDigestSink: @unchecked Sendable {
        private let lock = NSLock()
        private var digest = SHA256()
        private var byteCount: Int64 = 0
        private var overflow = false

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            let (next, didOverflow) = byteCount.addingReportingOverflow(Int64(data.count))
            byteCount = next
            overflow = overflow || didOverflow
            digest.update(data: data)
        }

        func result() throws -> (Int64, String) {
            lock.lock()
            defer { lock.unlock() }
            guard !overflow else { throw LocalArchiveExportError.sourceChanged }
            return (byteCount, digest.finalize().map { String(format: "%02x", $0) }.joined())
        }
        func bytesRead() -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            return overflow ? 0 : byteCount
        }
    }

    /// Re-reads every currently local PhotoKit resource without cloud access.
    /// A candidate checkpoint may only bind the exact media bytes and album
    /// membership recorded in the already published archive.
    static func verifyCurrentSourcesMatchArchive(
        at archiveRoot: URL, snapshot: LocalSharedSnapshot
    ) async throws -> ImageAllMigrationVerification {
        var header: ImageAllMigrationHeader?
        var items: [ImageAllMigrationItem] = []
        let verification = try ImageAllMigrationArchive.visitVerifiedRecords(
            at: archiveRoot,
            onHeader: { header = $0 },
            onItem: { items.append($0) }
        )
        guard let header, verification.isComplete else { throw LocalArchiveExportError.incompleteArchive }
        try await verifyCurrentSources(header: header, items: items, snapshot: snapshot)
        return verification
    }

    static func verifyCurrentSourcesMatchStream(
        _ record: ImageAllMigrationStreamRecord, snapshot: LocalSharedSnapshot
    ) async throws {
        try record.validate()
        try await verifyCurrentSources(header: record.header, items: record.items, snapshot: snapshot)
    }

    private static func verifyCurrentSources(
        header: ImageAllMigrationHeader, items: [ImageAllMigrationItem], snapshot: LocalSharedSnapshot
    ) async throws {
        guard header.appleAlbumCoverage == .selectedAssetsOnly,
              header.sourceDeviceID == snapshot.installID,
              header.sourceEpoch == snapshot.sourceEpoch,
              header.scopeRevision == snapshot.scopeRevision,
              Set(items.map(\.mediaID)) == Set(snapshot.selectedAssetIDs),
              items.count == snapshot.assets.count else {
            throw LocalArchiveExportError.archiveScopeChanged
        }
        let assetsByID = Dictionary(uniqueKeysWithValues: snapshot.assets.map { ($0.id, $0) })
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAssetSourceTypes = .typeUserLibrary
        let fetched = PHAsset.fetchAssets(
            withLocalIdentifiers: snapshot.assets.map(\.localIdentifier), options: options
        )
        var byLocator: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in byLocator[asset.localIdentifier] = asset }
        guard byLocator.count == snapshot.assets.count else {
            throw LocalArchiveExportError.selectionNotVisible
        }
        let before = byLocator.mapValues(sourceVersion)
        let selectedLocators = Set(byLocator.keys)
        let albums = try captureAlbumMemberships(selectedLocators: selectedLocators, includeCatalog: header.appleAlbumCatalog != nil)
        guard albums.coverage == header.appleAlbumCoverage, albums.catalog == header.appleAlbumCatalog else {
            throw LocalArchiveExportError.archiveScopeChanged
        }
        for item in items {
            try Task.checkCancellation()
            guard let selected = assetsByID[item.mediaID],
                  selected.localIdentifier == item.sourceLocalIdentifier,
                  let asset = byLocator[item.sourceLocalIdentifier],
                  (item.appleAlbums ?? []) == (albums.memberships[item.sourceLocalIdentifier] ?? []),
                  item.sourceMetadata == sourceMetadata(asset),
                  item.mediaKind == (asset.mediaType == .video ? .video : .image),
                  item.createdAtMs == asset.creationDate.map({
                      Int64($0.timeIntervalSince1970 * 1_000)
                  }) else {
                throw LocalArchiveExportError.sourceChanged
            }
            let resources = PHAssetResource.assetResources(for: asset)
            let primary = primaryResourceIndex(
                mediaType: asset.mediaType, resources: resources
            )
            guard primary != nil, item.resources.count == resources.count else {
                throw LocalArchiveExportError.sourceChanged
            }
            for (index, resource) in resources.enumerated() {
                try Task.checkCancellation()
                let expected = item.resources[index]
                let uti = resource.uniformTypeIdentifier.isEmpty
                    ? UTType.data.identifier : resource.uniformTypeIdentifier
                guard expected.status == .present,
                      expected.role == (index == primary ? "original" : resourceRole(resource.type)),
                      expected.uniformTypeIdentifier == uti,
                      expected.originalFilename == (resource.originalFilename.isEmpty ? nil : resource.originalFilename),
                      let bytes = expected.byteCount,
                      let hash = expected.sha256 else {
                    throw LocalArchiveExportError.sourceChanged
                }
                let current = try await hashSourceResource(resource)
                guard current.0 == bytes, current.1 == hash.lowercased() else {
                    throw LocalArchiveExportError.sourceChanged
                }
            }
        }
        let refreshed = PHAsset.fetchAssets(
            withLocalIdentifiers: snapshot.assets.map(\.localIdentifier), options: options
        )
        var finalByLocator: [String: PHAsset] = [:]
        refreshed.enumerateObjects { asset, _, _ in finalByLocator[asset.localIdentifier] = asset }
        guard finalByLocator.count == byLocator.count,
              finalByLocator.allSatisfy({ before[$0.key] == sourceVersion($0.value) }),
              albums == (try captureAlbumMemberships(selectedLocators: selectedLocators, includeCatalog: header.appleAlbumCatalog != nil)) else {
            throw LocalArchiveExportError.sourceChanged
        }
    }

    private static func hashSourceResource(_ resource: PHAssetResource,
        progress: (@MainActor (Int64) -> Void)? = nil
    ) async throws -> (Int64, String) {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        return try await hashResourceStream(progress: progress) { receive, complete in
            PHAssetResourceManager.default().requestData(
                for: resource, options: options,
                dataReceivedHandler: receive,
                completionHandler: complete
            )
        }
    }

    /// PhotoKit invokes these Objective-C callbacks on its own I/O queues.
    /// Explicit Sendable closures must not inherit this exporter's MainActor.
    /// Hash synchronously under the sink lock to preserve chunk order and avoid
    /// queuing an unbounded number of Data values on the UI actor.
    private static func hashResourceStream(
        progress: (@MainActor (Int64) -> Void)? = nil,
        request: (_ receive: @escaping @Sendable (Data) -> Void,
                  _ complete: @escaping @Sendable (Error?) -> Void) -> Void
    ) async throws -> (Int64, String) {
        let sink = ResourceDigestSink()
        // One sampler per read; never enqueue PhotoKit chunks on MainActor.
        let sampler: Task<Void, Never>? = progress.map { report in
            Task { @MainActor in
                while !Task.isCancelled {
                    report(sink.bytesRead())
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                }
            }
        }
        defer { sampler?.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let receive: @Sendable (Data) -> Void = { chunk in sink.append(chunk) }
            let complete: @Sendable (Error?) -> Void = { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
            request(receive, complete)
        }
        let result = try sink.result()
        progress?(result.0)
        return result
    }

    private static func awaitResourceWrite(
        request: (_ complete: @escaping @Sendable (Error?) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let complete: @Sendable (Error?) -> Void = { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
            request(complete)
        }
    }

    #if DEBUG
    /// Invokes the exact production callback adapters from a background queue.
    /// No PhotoKit calls, local library model, USB, or source files are involved.
    static func syntheticResourceCallbackProbe(
        progress: (@MainActor (Int64) -> Void)? = nil
    ) async throws -> [String: Any] {
        enum ProbeError: Error { case expected }
        let queue = DispatchQueue(label: "imageall.synthetic-resource-callbacks")
        let payload = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0) })
        let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let observationWindow = progress != nil
        let result = try await hashResourceStream(progress: progress) { receive, complete in
            queue.async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                for offset in stride(from: 0, to: payload.count, by: 65_536) {
                    receive(payload.subdata(in: offset..<min(offset + 65_536, payload.count)))
                    if observationWindow { Thread.sleep(forTimeInterval: 1) }
                }
                complete(nil)
            }
        }
        var readErrorPassed = false
        do {
            _ = try await hashResourceStream { receive, complete in
                queue.async {
                    dispatchPrecondition(condition: .notOnQueue(.main))
                    receive(Data([1, 2, 3]))
                    complete(ProbeError.expected)
                }
            }
        } catch ProbeError.expected { readErrorPassed = true }
        try await awaitResourceWrite { complete in
            queue.async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                complete(nil)
            }
        }
        var writeErrorPassed = false
        do {
            try await awaitResourceWrite { complete in
                queue.async {
                    dispatchPrecondition(condition: .notOnQueue(.main))
                    complete(ProbeError.expected)
                }
            }
        } catch ProbeError.expected { writeErrorPassed = true }
        let hashPassed = result.0 == Int64(payload.count) && result.1 == expected
        return ["passed": hashPassed && readErrorPassed && writeErrorPassed,
                "bytes": result.0, "digestMatched": hashPassed,
                "readErrorPropagated": readErrorPassed, "writeCompleted": true,
                "writeErrorPropagated": writeErrorPassed, "backgroundCallbacks": true,
                "photosAccessed": false, "macUploads": false]
    }
    #endif

    static func existingStreamingArchives() throws -> [LocalStreamingArchive] {
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true)
        let parent = support.appendingPathComponent("LocalLibrary/MigrationStreaming", isDirectory: true)
        guard manager.fileExists(atPath: parent.path) else { return [] }
        var result: [LocalStreamingArchive] = []
        for root in try manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            where root.lastPathComponent.hasPrefix(".staging-") {
            guard manager.fileExists(atPath: root.appendingPathComponent(ImageAllMigrationStreamRecord.filename).path)
                else { continue }
            let lease = try ImageAllMigrationExportCheckpoint(streamingRoot: root)
            do {
                let record = try ImageAllMigrationStreamRecord.read(in: lease.root)
                guard record.header.migrationID == lease.migrationID else {
                    throw LocalArchiveExportError.archiveScopeChanged
                }
                result.append(.init(root: lease.root, migrationID: record.header.migrationID))
                lease.close()
            } catch { lease.close(); throw error }
        }
        return result.sorted { $0.migrationID.uuidString < $1.migrationID.uuidString }
    }

    static func existingArchives() throws -> [URL] {
        let manager = FileManager.default
        let support = try manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let parent = support.appendingPathComponent(
            "LocalLibrary/MigrationArchives", isDirectory: true
        )
        guard manager.fileExists(atPath: parent.path) else { return [] }
        return try manager.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ).filter { url in
            guard url.pathExtension == "imageallarchive",
                  UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    struct Stream {
        let destination: String
        let sealVerifiedSubset: Bool
        let expectedMigrationID: UUID?
        let reportItem: @MainActor (Int, Int) -> Void
        let resumeCheckpoint: @MainActor (UUID) async throws -> [String: ImageAllMigrationResourceVerificationReceipt]
        let beforeResource: @MainActor () async throws -> Void
        let beforeSourceRevalidation: @MainActor (Int64) async throws -> Void
        let sourceRevalidationRead: @MainActor (Int64) -> Void
        let sourceRevalidationVerified: @MainActor () -> Void
        let verifyExistingResource: @MainActor (UUID, ImageAllMigrationResource) async throws -> ImageAllMigrationResourceVerificationReceipt
        let uploadResource: @MainActor (UUID, URL, ImageAllMigrationResource) async throws -> ImageAllMigrationResourceVerificationReceipt
        let finish: @MainActor (URL, ImageAllMigrationHeader, [ImageAllMigrationItem]) async throws -> ImageAllMigrationTransferSealReceipt
    }

    private enum Output {
        case archive(URL, ImageAllMigrationVerification)
        case stream(ImageAllMigrationTransferSealReceipt)
    }

    static func export(snapshot: LocalSharedSnapshot, includeAlbumCatalog: Bool = false) async throws -> (URL, ImageAllMigrationVerification) {
        guard case let .archive(url, verification) = try await build(snapshot: snapshot, includeAlbumCatalog: includeAlbumCatalog) else {
            throw LocalArchiveExportError.incompleteArchive
        }
        return (url, verification)
    }

    static func stream(snapshot: LocalSharedSnapshot, includeAlbumCatalog: Bool = false, configuration: Stream) async throws -> ImageAllMigrationTransferSealReceipt {
        guard case let .stream(receipt) = try await build(snapshot: snapshot, includeAlbumCatalog: includeAlbumCatalog, stream: configuration) else {
            throw LocalArchiveExportError.incompleteArchive
        }
        return receipt
    }

    #if DEBUG
    /// Metadata-only by default. An explicit diagnostic flag may read/hash one
    /// already-selected pending local resource; neither mode uploads or resets.
    static func preparationDiagnostics(
        snapshot: LocalSharedSnapshot, verifyOnePendingLocalResource: Bool = false
    ) async throws -> [String: Any] {
        let manager = FileManager.default
        let options = PHFetchOptions()
        options.includeHiddenAssets = false; options.includeAssetSourceTypes = .typeUserLibrary
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: snapshot.assets.map(\.localIdentifier), options: options)
        var sources: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in sources[asset.localIdentifier] = asset }
        var report: [String: Any] = ["selectedCount": snapshot.selectedAssetIDs.count,
            "visibleCount": sources.count, "sourceBytesRead": false, "macUploads": false]
        var sourceReadAttempted = false
        do {
            let albums = try captureAlbumMemberships(selectedLocators: Set(sources.keys), includeCatalog: true)
            report["albumCapturePassed"] = true
            report["albumCatalogCount"] = albums.catalog?.count ?? 0
        } catch {
            report["albumCapturePassed"] = false; report["albumCaptureError"] = error.localizedDescription
        }
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: false)
        let parent = support.appendingPathComponent("LocalLibrary/MigrationStreaming", isDirectory: true)
        var checkpoints: [[String: Any]] = []
        if manager.fileExists(atPath: parent.path) {
            for root in try manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                guard root.lastPathComponent.hasPrefix(".staging-") else { continue }
                let context = root.appendingPathComponent("stream-context.json")
                guard manager.fileExists(atPath: context.path) else { continue }
                let lease = try ImageAllMigrationExportCheckpoint(streamingRoot: root)
                defer { lease.close() }
                let pending = try lease.streamingResourceWindow()
                let frozen = try JSONDecoder().decode(LocalSharedSnapshot.self, from: Data(contentsOf: context))
                guard Set(frozen.selectedAssetIDs) == Set(snapshot.selectedAssetIDs) else { continue }
                let paths = Set(pending.map(\.path)), filenames = Set(pending.map(\.lastPathComponent))
                let relativePaths = try lease.streamingResourceWindowRelativePaths()
                var exact = Set<String>(), byName = Set<String>(), relativeMatches = Set<String>()
                if !pending.isEmpty {
                    for selected in frozen.assets {
                        guard let source = sources[selected.localIdentifier] else { continue }
                        for (index, resource) in PHAssetResource.assetResources(for: source).enumerated() {
                            let location = try lease.resourceLocation(key: "\(selected.id.uuidString)|\(index)",
                                fileExtension: fileExtension(for: resource))
                            if paths.contains(location.url.path) { exact.insert(location.url.path) }
                            if relativePaths.contains(location.relativePath) {
                                relativeMatches.insert(location.relativePath)
                                if verifyOnePendingLocalResource && !sourceReadAttempted {
                                    sourceReadAttempted = true
                                    report["sourceReadAttempted"] = true
                                    report["networkAccessAllowed"] = false
                                    do {
                                        let result = try await hashSourceResource(resource)
                                        report["sourceBytesRead"] = result.0 > 0
                                        report["verifiedSourceCount"] = 1
                                        report["verifiedSourceBytes"] = result.0
                                        report["sourceReadPassed"] = true
                                    } catch {
                                        report["sourceReadPassed"] = false
                                        report["sourceReadError"] = error.localizedDescription
                                    }
                                }
                            }
                            if filenames.contains(location.url.lastPathComponent) { byName.insert(location.url.lastPathComponent) }
                        }
                    }
                }
                checkpoints.append(["pendingCount": pending.count, "matchedAbsolutePaths": exact.count,
                    "matchedResourceNames": byName.count, "matchedRelativePaths": relativeMatches.count])
            }
        }
        report["matchingCheckpoints"] = checkpoints
        return report
    }
    #endif

    private static func build(
        snapshot initialSnapshot: LocalSharedSnapshot, includeAlbumCatalog: Bool = false, stream: Stream? = nil
    ) async throws -> Output {
        var snapshot = initialSnapshot
        let availability = try LocalMigrationAvailability(snapshot: snapshot)
        if stream == nil { try availability.requireComplete() }
        let manager = FileManager.default
        let support = try manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let parent = support.appendingPathComponent(stream == nil ? "LocalLibrary/MigrationArchives" : "LocalLibrary/MigrationStreaming", isDirectory: true)
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        var parentValues = URLResourceValues()
        parentValues.isExcludedFromBackup = true
        var mutableParent = parent
        try mutableParent.setResourceValues(parentValues)

        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAssetSourceTypes = .typeUserLibrary
        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: snapshot.assets.map(\.localIdentifier), options: options
        )
        var byLocator: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in byLocator[asset.localIdentifier] = asset }
        guard byLocator.count == snapshot.assets.count else {
            throw LocalArchiveExportError.selectionNotVisible
        }
        let sourceVersions = byLocator.mapValues(sourceVersion)
        let selectedLocators = Set(byLocator.keys)
        let albumMemberships = try captureAlbumMemberships(selectedLocators: selectedLocators, includeCatalog: includeAlbumCatalog)

        struct ResumeBinding: Encodable {
            let installID: UUID
            let sourceEpoch: UUID
            let scopeRevision: Int64
            let mediaLocators: [String: String]
            let sources: [String: SourceVersion]
            let albums: [String: [ImageAllMigrationAppleAlbumMembership]]
            let unavailableAlbumCoverage: ImageAllMigrationAppleAlbumCoverage?
            let albumCatalog: [ImageAllMigrationAppleCollection]?
            let destination: String?
            // Keep legacy complete bindings stable; bind partial work to every
            // retained selection, including temporarily invisible members.
            let retainedSelection: [String]?
        }
        let binding = ResumeBinding(installID: snapshot.installID, sourceEpoch: snapshot.sourceEpoch,
            scopeRevision: snapshot.scopeRevision,
            mediaLocators: Dictionary(uniqueKeysWithValues: snapshot.assets.map { ($0.id.uuidString, $0.localIdentifier) }),
            sources: sourceVersions, albums: albumMemberships.memberships,
            unavailableAlbumCoverage: albumMemberships.coverage == .selectedAssetsOnly ? nil : albumMemberships.coverage,
            albumCatalog: albumMemberships.catalog, destination: stream?.destination,
            retainedSelection: availability.pendingCount > 0 ? snapshot.selectedAssetIDs.map(\.uuidString).sorted() : nil)
        let bindingEncoder = JSONEncoder()
        bindingEncoder.outputFormatting = [.sortedKeys]
        let bindingData = try bindingEncoder.encode(binding)
        // Snapshot sequence advances on catalogue sync even when the selected
        // identities and facts are unchanged. Keep it out of active-batch identity.
        func resumeScope(_ value: LocalSharedSnapshot) throws -> Data {
            guard var object = try JSONSerialization.jsonObject(with: bindingEncoder.encode(value)) as? [String: Any] else {
                throw LocalArchiveExportError.archiveScopeChanged
            }
            object.removeValue(forKey: "snapshotSequence")
            object["destination"] = stream?.destination
            object["includeAlbumCatalog"] = includeAlbumCatalog
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        let scopeData = try resumeScope(initialSnapshot)
        var legacyMigrationID: UUID?
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--resume-existing-migration") {
            guard arguments.indices.contains(index + 1), let id = UUID(uuidString: arguments[index + 1]) else {
                throw LocalArchiveExportError.archiveScopeChanged
            }
            legacyMigrationID = id
        }
        #endif
        guard legacyMigrationID == nil || stream?.expectedMigrationID == nil
                || legacyMigrationID == stream?.expectedMigrationID else {
            throw LocalArchiveExportError.archiveScopeChanged
        }
        let requestedMigrationID = stream?.expectedMigrationID ?? legacyMigrationID
        let checkpoint = try stream == nil
            ? ImageAllMigrationExportCheckpoint(parent: parent, binding: bindingData)
            : ImageAllMigrationExportCheckpoint.streaming(parent: parent, binding: bindingData,
                scope: scopeData, legacyMigrationID: requestedMigrationID,
                requireExisting: requestedMigrationID != nil || stream?.sealVerifiedSubset == true)
        defer { checkpoint.close() }
        if stream != nil {
            let frozen = try checkpoint.frozenContext(bindingEncoder.encode(initialSnapshot))
            snapshot = try JSONDecoder().decode(LocalSharedSnapshot.self, from: frozen)
            guard try resumeScope(snapshot) == scopeData,
                  snapshot.installID == initialSnapshot.installID,
                  snapshot.sourceEpoch == initialSnapshot.sourceEpoch,
                  snapshot.scopeRevision == initialSnapshot.scopeRevision,
                  snapshot.snapshotSequence <= initialSnapshot.snapshotSequence,
                  snapshot.outboxWatermark <= initialSnapshot.outboxWatermark,
                  Set(snapshot.selectedAssetIDs) == Set(initialSnapshot.selectedAssetIDs),
                  Set(snapshot.assets.map(\.id)).count == snapshot.assets.count,
                  Set(snapshot.assets.map(\.localIdentifier)).count == snapshot.assets.count,
                  Dictionary(uniqueKeysWithValues: snapshot.assets.map { ($0.id, $0.localIdentifier) })
                    == Dictionary(uniqueKeysWithValues: initialSnapshot.assets.map { ($0.id, $0.localIdentifier) }) else {
                throw LocalArchiveExportError.archiveScopeChanged
            }
            try manager.setAttributes([.protectionKey: FileProtectionType.complete],
                ofItemAtPath: checkpoint.root.appendingPathComponent("stream-context.json").path)
            let pending = try checkpoint.streamingResourceWindowRelativePaths()
            var revalidated = Set<String>()
            if !pending.isEmpty {
                for selected in snapshot.assets {
                    guard let source = byLocator[selected.localIdentifier] else {
                        throw LocalArchiveExportError.selectionNotVisible
                    }
                    for (index, resource) in PHAssetResource.assetResources(for: source).enumerated() {
                        let location = try checkpoint.resourceLocation(
                            key: "\(selected.id.uuidString)|\(index)", fileExtension: fileExtension(for: resource))
                        if pending.contains(location.relativePath) {
                            // Validate identity now; validate source bytes below,
                            // per resource. One unavailable source must not stop
                            // all other locally readable resources before the loop.
                            revalidated.insert(location.relativePath)
                        }
                    }
                }
                guard revalidated == pending else {
                    throw LocalArchiveExportError.resumeResourceMismatch
                }
                try await stream?.beforeResource()
            }
            // Preserve interrupted resources. The loop below revalidates cached
            // bytes before reuse and releases only independently confirmed data.
        }
        let migrationID = checkpoint.migrationID
        let staging = checkpoint.root
        let published = parent.appendingPathComponent("\(migrationID.uuidString).imageallarchive", isDirectory: true)
        try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: staging.path)
        try checkpoint.removeUnpublishedManifest()

        // Receiver receipts remain bound to this original migration and paired
        // destination. A changed source binding requires per-resource validation;
        // successful validations survive interruptions, without repeated upload.
        let resumeReceipts = try await stream?.resumeCheckpoint(migrationID) ?? [:]
        let originalBindingMatches = checkpoint.matchesOriginalBinding(bindingData)
        if stream != nil {
            guard legacyMigrationID == nil || !resumeReceipts.isEmpty else {
                throw LocalArchiveExportError.resumeResourceMismatch
            }
            try checkpoint.rememberStreamingScope(scopeData)
        }

        var items: [ImageAllMigrationItem] = []
        var pendingLocalResources = 0
        for (selectedIndex, selected) in snapshot.assets.enumerated() {
            stream?.reportItem(selectedIndex + 1, snapshot.selectedAssetIDs.count)
            try Task.checkCancellation()
            guard let source = byLocator[selected.localIdentifier] else {
                throw LocalArchiveExportError.selectionNotVisible
            }
            let sourceResources = PHAssetResource.assetResources(for: source)
            let primary = primaryResourceIndex(mediaType: source.mediaType, resources: sourceResources)
            if stream != nil, primary == nil { throw LocalArchiveExportError.incompleteArchive }
            var exported: [ImageAllMigrationResource] = []
            for (index, resource) in sourceResources.enumerated() {
                let uti = resource.uniformTypeIdentifier.isEmpty
                    ? UTType.data.identifier : resource.uniformTypeIdentifier
                let role = index == primary ? "original" : resourceRole(resource.type)
                let fileExtension = Self.fileExtension(for: resource)
                let location = try checkpoint.resourceLocation(key: "\(selected.id.uuidString)|\(index)", fileExtension: fileExtension)
                let id = location.id, relativePath = location.relativePath, destination = location.url
                if let stream, let prior = try checkpoint.verifiedStreamingResource(id: id) {
                    guard prior.relativePath == relativePath, prior.role == role,
                          prior.uniformTypeIdentifier == uti,
                          prior.originalFilename == (resource.originalFilename.isEmpty ? nil : resource.originalFilename) else {
                        throw LocalArchiveExportError.sourceChanged
                    }
                    let version = try bindingEncoder.encode(sourceVersions[selected.localIdentifier])
                    if !originalBindingMatches,
                       try !checkpoint.isStreamingSourceVerified(prior, version: version) {
                        try await stream.beforeSourceRevalidation(prior.byteCount ?? 0)
                        let current = try await hashSourceResource(resource, progress: stream.sourceRevalidationRead)
                        try checkpoint.recordStreamingSourceVerification(prior, version: version,
                            byteCount: current.0, sha256: current.1)
                        stream.sourceRevalidationVerified()
                    }
                    if let receipt = resumeReceipts[relativePath] {
                        guard receipt.migrationID == migrationID,
                              receipt.resource.byteCount == prior.byteCount,
                              receipt.resource.sha256 == prior.sha256 else {
                            throw LocalArchiveExportError.sourceChanged
                        }
                    } else {
                        guard !stream.sealVerifiedSubset else { throw LocalArchiveExportError.subsetRequiresVerifiedResources }
                        let receipt = try await stream.verifyExistingResource(migrationID, prior)
                        try checkpoint.recordVerifiedStreamingResource(prior, receipt: receipt)
                    }
                    if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                    exported.append(prior)
                    continue
                }
                guard stream?.sealVerifiedSubset != true else { throw LocalArchiveExportError.subsetRequiresVerifiedResources }
                var preserveCachedResource = manager.fileExists(atPath: destination.path)
                do {
                    try Task.checkCancellation()
                    try await stream?.beforeResource()
                    var verifiedCache: (Int64, String)?
                    if preserveCachedResource {
                        let cached = try await Task.detached { try hashFile(destination) }.value
                        let current = try await hashSourceResource(resource)
                        if cached.0 == current.0 && cached.1 == current.1 {
                            verifiedCache = cached
                        } else {
                            // The current source has been read successfully; discard only this bad cache file.
                            try manager.removeItem(at: destination)
                            preserveCachedResource = false
                        }
                    }
                    let digest: (Int64, String)
                    if let verifiedCache {
                        digest = verifiedCache
                    } else {
                        try Task.checkCancellation()
                        try await writeLocalResource(resource, to: destination)
                        digest = try await Task.detached { try hashFile(destination) }.value
                    }
                    try manager.setAttributes(
                        [.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path
                    )
                    let record = ImageAllMigrationResource(
                        id: id, role: role, version: 1, uniformTypeIdentifier: uti,
                        required: true, status: .present, relativePath: relativePath,
                        byteCount: digest.0, sha256: digest.1,
                        originalFilename: resource.originalFilename.isEmpty ? nil : resource.originalFilename
                    )
                    if let stream {
                        let receipt = try await stream.uploadResource(migrationID, destination, record)
                        guard receipt.migrationID == migrationID,
                              receipt.resource.relativePath == relativePath,
                              receipt.resource.byteCount == digest.0,
                              receipt.resource.sha256 == digest.1 else {
                            throw LocalArchiveExportError.sourceChanged
                        }
                        try checkpoint.recordVerifiedStreamingResource(record, receipt: receipt)
                        try checkpoint.recordStreamingSourceVerification(record,
                            version: bindingEncoder.encode(sourceVersions[selected.localIdentifier]),
                            byteCount: digest.0, sha256: digest.1)
                        // Only our deterministic scratch resource is removed,
                        // after independent receiver verification. Never PhotoKit.
                        let checked = try checkpoint.resourceLocation(
                            key: "\(selected.id.uuidString)|\(index)", fileExtension: fileExtension)
                        try manager.removeItem(at: checked.url)
                    }
                    exported.append(record)
                } catch {
                    if stream != nil {
                        let failure = error as NSError
                        let code = failure.domain == PHPhotosError.errorDomain ? PHPhotosError.Code(rawValue: failure.code) : nil
                        if !Task.isCancelled, code == .networkAccessRequired || code == .missingResource || code == .requestNotSupportedForAsset {
                            pendingLocalResources += 1
                            continue
                        }
                        throw error
                    }
                    // If source revalidation fails, keep the prior cache and stop this attempt.
                    if preserveCachedResource { throw error }
                    try? manager.removeItem(at: destination)
                    let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                    let failure = error as NSError
                    let photoCode = failure.domain == PHPhotosError.errorDomain
                        ? PHPhotosError.Code(rawValue: failure.code) : nil
                    let resourceStatus: ImageAllMigrationResourceStatus
                    if current != .authorized && current != .limited {
                        resourceStatus = .permissionDenied
                    } else if photoCode == .accessRestricted || photoCode == .accessUserDenied {
                        resourceStatus = .permissionDenied
                    } else if photoCode == .networkAccessRequired || photoCode == .missingResource {
                        resourceStatus = .notLocal
                    } else if photoCode == .requestNotSupportedForAsset {
                        resourceStatus = .unsupported
                    } else {
                        throw error
                    }
                    exported.append(ImageAllMigrationResource(
                        id: id, role: role, version: 1, uniformTypeIdentifier: uti,
                        required: true, status: resourceStatus, relativePath: nil,
                        byteCount: nil, sha256: nil,
                        originalFilename: resource.originalFilename.isEmpty ? nil : resource.originalFilename
                    ))
                }
            }
            if primary == nil {
                exported.append(ImageAllMigrationResource(
                    id: UUID(), role: "original", version: 1,
                    uniformTypeIdentifier: UTType.data.identifier,
                    required: true, status: .unsupported,
                    relativePath: nil, byteCount: nil, sha256: nil
                ))
            }
            let decisions = selected.tagDecisions.map {
                let decision: RemoteLocalLibraryDecision
                switch $0.decision {
                case .accepted: decision = .accepted
                case .rejected: decision = .rejected
                case .cleared: decision = .cleared
                }
                return ImageAllMigrationTagDecision(
                    tagID: $0.tagID, tagName: $0.tagName,
                    decision: decision
                )
            }
            let collections = selected.collections.map {
                ImageAllMigrationCollectionMembership(
                    collectionID: $0.collectionID, collectionName: $0.collectionName, included: true
                )
            }
            items.append(ImageAllMigrationItem(
                mediaID: selected.id, sourceLocalIdentifier: selected.localIdentifier,
                mediaKind: selected.kind == "video" ? .video : .image,
                createdAtMs: source.creationDate.map { Int64($0.timeIntervalSince1970 * 1_000) },
                favoriteTarget: selected.favoriteTarget,
                observedFavorite: selected.observedFavorite,
                factRevision: snapshot.outboxWatermark,
                tagDecisions: decisions, collections: collections, resources: exported,
                appleAlbums: albumMemberships.memberships[selected.localIdentifier] ?? [],
                sourceMetadata: sourceMetadata(source)
            ))
        }
        guard pendingLocalResources == 0 else { throw LocalArchiveExportError.localResourcesPending(pendingLocalResources) }
        if stream?.sealVerifiedSubset != true {
            guard availability.pendingCount == 0 else {
                throw LocalArchiveExportError.selectedAssetsPending(availability.pendingCount)
            }
            try availability.requireComplete()
        }
        _ = try snapshot.archiveSnapshot(mediaIDs: Set(items.map(\.mediaID)),
            allowVerifiedSubset: stream?.sealVerifiedSubset == true)
        let finalResult = PHAsset.fetchAssets(
            withLocalIdentifiers: snapshot.assets.map(\.localIdentifier), options: options
        )
        var finalByLocator: [String: PHAsset] = [:]
        finalResult.enumerateObjects { asset, _, _ in finalByLocator[asset.localIdentifier] = asset }
        guard finalByLocator.count == byLocator.count,
              finalByLocator.allSatisfy({ sourceVersions[$0.key] == sourceVersion($0.value) }),
              albumMemberships == (try captureAlbumMemberships(
                  selectedLocators: selectedLocators, includeCatalog: includeAlbumCatalog
              )) else {
            throw LocalArchiveExportError.sourceChanged
        }
        let header = ImageAllMigrationHeader(
            migrationID: migrationID, sourceDeviceID: snapshot.installID,
            sourceEpoch: snapshot.sourceEpoch, scopeRevision: snapshot.scopeRevision,
            inventoryWatermark: snapshot.snapshotSequence, declaredItemCount: items.count,
            appleAlbumCoverage: albumMemberships.coverage, appleAlbumCatalog: albumMemberships.catalog,
            retainedSelectionIDs: availability.pendingCount > 0 ? snapshot.selectedAssetIDs : nil
        )
        let resourcesDirectory = staging.appendingPathComponent("resources", isDirectory: true)
        if manager.fileExists(atPath: resourcesDirectory.path),
           try manager.contentsOfDirectory(atPath: resourcesDirectory.path).isEmpty {
            try manager.removeItem(at: resourcesDirectory)
        }
        try ImageAllMigrationArchive.write(header: header, items: items, to: staging)
        if let stream {
            try manager.setAttributes([.protectionKey: FileProtectionType.complete],
                ofItemAtPath: staging.appendingPathComponent(ImageAllMigrationArchive.manifestFilename).path)
            return .stream(try await stream.finish(staging, header, items))
        }
        let verification = try ImageAllMigrationArchive.verify(at: staging)
        try manager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: staging.appendingPathComponent(ImageAllMigrationArchive.manifestFilename).path
        )
        try manager.moveItem(at: staging, to: published)
        return .archive(published, verification)
    }

    private struct AlbumSnapshot: Equatable {
        let coverage: ImageAllMigrationAppleAlbumCoverage
        let memberships: [String: [ImageAllMigrationAppleAlbumMembership]]
        let catalog: [ImageAllMigrationAppleCollection]?
    }

    /// Traverse only user-created Photos albums/folders. A membership is kept
    /// only for an asset in the explicit export scope; unrelated album members
    /// never enter the portable manifest.
    private static func captureAlbumMemberships(
        selectedLocators: Set<String>, includeCatalog: Bool = false
    ) throws -> AlbumSnapshot {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .limited:
            guard !includeCatalog else {
                throw RemoteAPIError(code: .conflict, message: "保存完整用户相册目录需要完整照片权限；也可关闭此选项，仅归档已授权媒体。")
            }
            return AlbumSnapshot(coverage: .unavailableLimitedAuthorization, memberships: [:], catalog: nil)
        case .authorized: break
        default: throw LocalArchiveExportError.selectionNotVisible
        }
        var result: [String: [ImageAllMigrationAppleAlbumMembership]] = [:]
        var visited: Set<String> = []
        var catalog: [ImageAllMigrationAppleCollection] = []
        func walk(
            _ collections: PHFetchResult<PHCollection>,
            folders: [ImageAllMigrationAppleAlbumMembership.Folder]
        ) throws {
            for index in 0..<collections.count {
                let collection = collections.object(at: index)
                guard visited.insert(collection.localIdentifier).inserted else {
                    throw LocalArchiveExportError.sourceChanged
                }
                if let folder = collection as? PHCollectionList {
                    if includeCatalog {
                        catalog.append(.init(localIdentifier: folder.localIdentifier, title: folder.localizedTitle,
                            kind: .folder, parentLocalIdentifier: folders.last?.localIdentifier,
                            sourceOrdinal: Int64(index), observedAssetCount: nil))
                    }
                    let path = folders + [.init(
                        localIdentifier: folder.localIdentifier, title: folder.localizedTitle
                    )]
                    try walk(PHCollection.fetchCollections(in: folder, options: nil), folders: path)
                } else if let album = collection as? PHAssetCollection,
                          album.assetCollectionType == .album {
                    let assets = PHAsset.fetchAssets(in: album, options: nil)
                    if includeCatalog {
                        catalog.append(.init(localIdentifier: album.localIdentifier, title: album.localizedTitle,
                            kind: .album, parentLocalIdentifier: folders.last?.localIdentifier,
                            sourceOrdinal: Int64(index), observedAssetCount: assets.count))
                    }
                    for ordinal in 0..<assets.count {
                        let locator = assets.object(at: ordinal).localIdentifier
                        guard selectedLocators.contains(locator) else { continue }
                        result[locator, default: []].append(.init(
                            albumLocalIdentifier: album.localIdentifier,
                            albumTitle: album.localizedTitle, folderPath: folders,
                            sourceOrdinal: Int64(ordinal)
                        ))
                    }
                }
            }
        }
        try walk(PHCollection.fetchTopLevelUserCollections(with: nil), folders: [])
        for locator in result.keys {
            result[locator]?.sort {
                $0.albumLocalIdentifier < $1.albumLocalIdentifier
            }
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw LocalArchiveExportError.sourceChanged
        }
        return AlbumSnapshot(coverage: .selectedAssetsOnly, memberships: result,
            catalog: includeCatalog ? catalog.sorted { $0.localIdentifier < $1.localIdentifier } : nil)
    }

    private static func fileExtension(for resource: PHAssetResource) -> String {
        let uti = resource.uniformTypeIdentifier.isEmpty ? UTType.data.identifier : resource.uniformTypeIdentifier
        let candidate = UTType(uti)?.preferredFilenameExtension ?? "bin"
        return (1...12).contains(candidate.count)
            && candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? candidate : "bin"
    }

    private static func primaryResourceIndex(
        mediaType: PHAssetMediaType, resources: [PHAssetResource]
    ) -> Int? {
        let preferred: [PHAssetResourceType] = mediaType == .video ? [.video] : [.photo]
        for type in preferred {
            if let index = resources.firstIndex(where: { $0.type == type }) { return index }
        }
        return nil
    }

    nonisolated static func cleanupSourceFingerprint(_ asset: PHAsset) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(sourceVersion(asset))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func cleanupSourceVersions(_ identifiers: [String]) throws -> [String: String] {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              Set(identifiers).count == identifiers.count else { throw LocalFavoriteSourceError.authorizationRequired }
        let options = PHFetchOptions()
        options.includeHiddenAssets = false; options.includeAssetSourceTypes = .typeUserLibrary
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: options)
        guard fetched.count == identifiers.count else { throw LocalFavoriteSourceError.assetUnavailable }
        var result: [String: String] = [:]
        for index in 0..<fetched.count {
            let asset = fetched.object(at: index)
            result[asset.localIdentifier] = try cleanupSourceFingerprint(asset)
        }
        return result
    }

    private nonisolated static func sourceVersion(_ asset: PHAsset) -> SourceVersion {
        SourceVersion(
            modificationDate: asset.modificationDate,
            creationDate: asset.creationDate, metadata: sourceMetadata(asset),
            resourceSignature: PHAssetResource.assetResources(for: asset).map {
                "\($0.type.rawValue):\($0.uniformTypeIdentifier):\($0.originalFilename)"
            }
        )
    }

    private nonisolated static func sourceMetadata(_ asset: PHAsset) -> ImageAllMigrationSourceMetadata {
        func milliseconds(_ date: Date?) -> Int64? {
            guard let value = date?.timeIntervalSince1970, value.isFinite,
                  value * 1_000 > Double(Int64.min), value * 1_000 < Double(Int64.max) else { return nil }
            return Int64(value * 1_000)
        }
        let location = asset.location.flatMap { value -> ImageAllMigrationSourceMetadata.Location? in
            guard value.horizontalAccuracy.isFinite, value.horizontalAccuracy >= 0,
                  value.coordinate.latitude.isFinite, (-90...90).contains(value.coordinate.latitude),
                  value.coordinate.longitude.isFinite, (-180...180).contains(value.coordinate.longitude) else { return nil }
            let hasAltitude = value.verticalAccuracy.isFinite && value.verticalAccuracy >= 0 && value.altitude.isFinite
            return .init(latitude: value.coordinate.latitude, longitude: value.coordinate.longitude,
                horizontalAccuracyMeters: value.horizontalAccuracy,
                altitudeMeters: hasAltitude ? value.altitude : nil,
                verticalAccuracyMeters: hasAltitude ? value.verticalAccuracy : nil,
                observedAtMs: milliseconds(value.timestamp))
        }
        return .init(pixelWidth: asset.pixelWidth > 0 ? asset.pixelWidth : nil,
            pixelHeight: asset.pixelHeight > 0 ? asset.pixelHeight : nil,
            durationSeconds: asset.mediaType == .video && asset.duration.isFinite && asset.duration >= 0 ? asset.duration : nil,
            modifiedAtMs: milliseconds(asset.modificationDate), location: location)
    }

    private static func resourceRole(_ type: PHAssetResourceType) -> String {
        switch type {
        case .photo: "photo"
        case .video: "video"
        case .audio: "audio"
        case .alternatePhoto: "alternatePhoto"
        case .fullSizePhoto: "fullSizePhoto"
        case .fullSizeVideo: "fullSizeVideo"
        case .adjustmentData: "adjustmentData"
        case .adjustmentBasePhoto: "adjustmentBasePhoto"
        case .pairedVideo: "pairedVideo"
        case .fullSizePairedVideo: "fullSizePairedVideo"
        case .adjustmentBasePairedVideo: "adjustmentBasePairedVideo"
        case .adjustmentBaseVideo: "adjustmentBaseVideo"
        case .photoProxy: "photoProxy"
        @unknown default: "unknown-\(type.rawValue)"
        }
    }

    private static func writeLocalResource(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        try await awaitResourceWrite { complete in
            PHAssetResourceManager.default().writeData(
                for: resource, toFile: url, options: options, completionHandler: complete
            )
        }
    }

    nonisolated private static func hashFile(_ url: URL) throws -> (Int64, String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let block = try autoreleasepool(invoking: { try handle.read(upToCount: 1_048_576) }), !block.isEmpty {
            count += Int64(block.count)
            hash.update(data: block)
        }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

private struct LocalAssetDetailView: View {
    @ObservedObject var model: LocalLibraryModel
    let asset: LocalAsset
    @State private var decisions: [UUID: LocalDecision] = [:]
    @State private var memberships: Set<UUID> = []
    @State private var tagUndo: [UUID: UUID] = [:]
    @State private var isEditingTags = false
    @State private var collectionUndo: [UUID: UUID] = [:]
    @State private var isEditingCollections = false
    @State private var showsPreview = false

    private var photoItem: LocalShareItem {
        LocalShareItem(id: asset.id, localIdentifier: asset.localIdentifier,
                       isVideo: asset.kind == "video", date: asset.creationDate)
    }

    private var currentAsset: LocalAsset {
        model.assets.first(where: { $0.id == asset.id }) ?? asset
    }

    var body: some View {
        List {
            Button { showsPreview = true } label: {
                LocalPhotoThumbnail(item: photoItem, preview: true)
                    .frame(maxWidth: .infinity).frame(height: 320).background(Color.black)
            }.buttonStyle(.plain).listRowInsets(EdgeInsets())
                .accessibilityLabel(asset.kind == "video" ? "预览视频封面" : "预览照片")
            Section("收藏") {
                Button(currentAsset.favoriteTarget ?? currentAsset.observedFavorite ? "取消 Photos 收藏" : "收藏到 Photos") {
                    Task {
                        await model.setFavoriteTarget(
                            !(currentAsset.favoriteTarget ?? currentAsset.observedFavorite), asset: currentAsset
                        )
                    }
                }
                .disabled(model.favoriteWritesInFlight.contains(asset.id))
                if let target = currentAsset.favoriteTarget,
                   target != currentAsset.observedFavorite,
                   (currentAsset.favoriteWritebackState == .failed
                        || currentAsset.favoriteWritebackState == .pending)
                {
                    Button("重试写回收藏目标") {
                        Task { await model.retryFavoriteWriteback(asset: currentAsset) }
                    }
                    .disabled(model.favoriteWritesInFlight.contains(asset.id))
                }
                LabeledContent("Photos 观测", value: currentAsset.observedFavorite ? "已收藏" : "未收藏")
                if let target = currentAsset.favoriteTarget {
                    LabeledContent("ImageAll 目标", value: target ? "收藏" : "不收藏")
                }
                Text(favoriteWritebackMessage(currentAsset.favoriteWritebackState))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("标签决定") {
                ForEach(model.tags) { tag in
                    HStack {
                        Text(tag.name)
                        Spacer()
                        Picker(tag.name, selection: Binding(
                            get: { decisions[tag.id] ?? .cleared },
                            set: { value in
                                decisions[tag.id] = value
                                isEditingTags = true
                                Task {
                                    await model.setDecision(value, asset: asset, tag: tag)
                                    await reloadTagState()
                                    isEditingTags = false
                                }
                            }
                        )) {
                            Text("清除").tag(LocalDecision.cleared)
                            Text("接受").tag(LocalDecision.accepted)
                            Text("拒绝").tag(LocalDecision.rejected)
                        }
                        .labelsHidden()
                        .disabled(isEditingTags)
                        if let operation = tagUndo[tag.id] {
                            Button("撤销") {
                                isEditingTags = true
                                Task {
                                    await model.undoTagDecision(operation)
                                    await reloadTagState()
                                    isEditingTags = false
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(isEditingTags)
                            .accessibilityLabel("撤销标签“\(tag.name)”的上次修改")
                        }
                    }
                }
                Text("撤销仅恢复上次标签决定。同步版本或身份变化后，旧撤销会失效。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("ImageAll 集合") {
                ForEach(model.collections) { collection in
                    HStack {
                        Toggle(collection.name, isOn: Binding(
                            get: { memberships.contains(collection.id) },
                            set: { included in
                                if included { memberships.insert(collection.id) }
                                else { memberships.remove(collection.id) }
                                isEditingCollections = true
                                Task {
                                    await model.setMembership(included, asset: asset, collection: collection)
                                    await reloadCollectionState()
                                    isEditingCollections = false
                                }
                            }
                        ))
                        .disabled(isEditingCollections)
                        if let operation = collectionUndo[collection.id] {
                            Button("撤销") {
                                isEditingCollections = true
                                Task {
                                    await model.undoMembership(operation)
                                    await reloadCollectionState()
                                    isEditingCollections = false
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(isEditingCollections)
                            .accessibilityLabel("撤销集合“\(collection.name)”的上次成员修改")
                        }
                    }
                }
            }
            Section("跨端分享") {
                Toggle("加入待分享范围", isOn: Binding(
                    get: { currentAsset.isShared },
                    set: { shared in
                        Task {
                            await model.setShared(
                                shared, assetID: asset.id,
                                localIdentifier: asset.localIdentifier
                            )
                        }
                    }
                ))
                Text("只有选中的照片会在手动同步时发送目录与整理信息；原件不会因此上传。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("本机照片")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsPreview) {
            NavigationStack {
                LocalPhotoThumbnail(item: photoItem, preview: true).background(Color.black)
                    .navigationTitle(asset.kind == "video" ? "视频封面预览" : "照片预览")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbarColorScheme(.dark, for: .navigationBar)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsPreview = false } } }
            }.environment(\.colorScheme, .dark)
        }
        .task(id: asset.id) {
            await reloadTagState()
            await reloadCollectionState()
        }
    }

    private func reloadCollectionState() async {
        memberships = await model.memberships(for: asset)
        collectionUndo = await model.collectionUndoCandidates(for: asset)
    }

    private func reloadTagState() async {
        decisions = await model.decisions(for: asset)
        tagUndo = await model.tagUndoCandidates(for: asset)
    }

    private func favoriteWritebackMessage(_ state: LocalFavoriteWritebackState) -> String {
        switch state {
        case .notRequested: "尚未从 ImageAll 更改系统收藏。"
        case .pending: "收藏目标已保存在本机，等待 Photos 回读。"
        case .matched: "Photos 回读与本机收藏目标一致。"
        case .failed: "Photos 写回未完成；本机目标已保留，可重新操作。"
        }
    }
}
