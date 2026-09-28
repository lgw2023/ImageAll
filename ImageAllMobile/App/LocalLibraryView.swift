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

    private let store: LocalLibraryStore?
    private let favoriteSource: any LocalFavoriteSource
    private let browser: LocalLibraryBrowser?
    private var photoChanges: LocalPhotoChangeObserver?

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
        } catch {
            store = nil
            browser = nil
            errorMessage = "本机资料库无法打开：\(error.localizedDescription)"
        }
        photoChanges = LocalPhotoChangeObserver { [weak self] in
            Task { await self?.refresh() }
        }
    }

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

    func cancelBulkSharePreview() { browser?.cancelBulkSharePreview() }

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
    func streamSelectedArchive(to remote: RemoteCompanionModel, includeAlbumCatalog: Bool = false) async throws -> ImageAllMigrationTransferSealReceipt {
        let connection = try remote.migrationStreamingConnection()
        if includeAlbumCatalog { try remote.requireMigrationAlbumCatalogSupport() }
        let snapshot = try await makeMigrationFactSnapshot()
        guard !snapshot.selectedAssetIDs.isEmpty else { throw LocalArchiveExportError.emptySelection }
        guard Set(snapshot.selectedAssetIDs) == Set(snapshot.assets.map(\.id)) else {
            throw LocalArchiveExportError.selectionNotVisible
        }
        let check: @Sendable () async throws -> Void = { [self, remote] in
            try Task.checkCancellation()
            try await remote.validateMigrationStreamingConnection(
                hostID: connection.hostID, deviceID: connection.deviceID)
            try await self.validateSharedSnapshotScope(snapshot)
        }
        return try await LocalPhotoArchiveExporter.stream(snapshot: snapshot, includeAlbumCatalog: includeAlbumCatalog, configuration: .init(
            destination: "\(connection.hostID.uuidString)|\(connection.deviceID.uuidString)",
            beforeResource: { try await check() },
            uploadResource: { migrationID, file, resource in
                guard let path = resource.relativePath, let size = resource.byteCount,
                      let hash = resource.sha256 else { throw LocalArchiveExportError.incompleteArchive }
                _ = try await connection.client.uploadMigrationFile(
                    at: file, migrationID: migrationID, relativePath: path,
                    byteCount: size, sha256: hash, sourceInstallID: snapshot.installID, beforeChunk: check)
                try await check()
                let receipt = try await connection.client.verifyMigrationResource(
                    migrationID: migrationID, deviceID: connection.deviceID,
                    request: .init(relativePath: path, byteCount: size, sha256: hash))
                try await check()
                return receipt
            },
            finish: { [self] root, header, items in
                try await check()
                let current = try await self.makeMigrationFactSnapshot()
                guard current.installID == header.sourceDeviceID, current.sourceEpoch == header.sourceEpoch,
                      current.scopeRevision == header.scopeRevision,
                      Set(current.selectedAssetIDs) == Set(items.map(\.mediaID)),
                      Set(current.assets.map(\.id)) == Set(items.map(\.mediaID)) else {
                    throw LocalArchiveExportError.selectionChanged
                }
                let facts = try LocalMigrationFactExporter.export(snapshot: current)
                defer { try? FileManager.default.removeItem(at: facts) }
                _ = try ImageAllMigrationFacts.publish(from: facts, into: root)
                let receipt = try await connection.client.finishPreparedMigration(
                    at: root, header: header, items: items, beforeChunk: check)
                try await check()
                try ImageAllMigrationStreamRecord(hostID: connection.hostID, deviceID: connection.deviceID,
                    header: header, items: items, receipt: receipt).save(in: root)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: root.appendingPathComponent(ImageAllMigrationStreamRecord.filename).path)
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
                hostID: record.hostID, deviceID: record.deviceID)
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
    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [onChange] in onChange() }
    }
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
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
                Menu {
                    Button("刷新", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
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
        List {
            if model.authorization == .limited {
                Section {
                    Label("当前只显示系统授权的照片；相册结构可能不可用。", systemImage: "info.circle")
                        .font(.footnote)
                }
            }
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
            Section("已授权照片") {
                ForEach(model.assets) { asset in
                    NavigationLink {
                        LocalAssetDetailView(model: model, asset: asset)
                    } label: {
                        HStack {
                            LocalThumbnailView(localIdentifier: asset.localIdentifier)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading) {
                                Text(asset.kind == "video" ? "视频" : "照片")
                                if let date = asset.creationDate {
                                    Text(date, format: .dateTime.year().month().day())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if asset.favoriteTarget ?? asset.observedFavorite {
                                Image(systemName: "heart.fill").foregroundStyle(.red)
                            }
                        }
                    }
                }
                if model.hasMore {
                    Button("加载更多") { Task { await model.loadMore() } }
                }
            }
        }
        .refreshable { await model.refresh() }
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
    @State private var preview: LocalBulkSharePreview?
    @State private var busy = false
    @State private var message: String?
    @State private var work: Task<Void, Never>?

    var body: some View {
        Form {
            Section("范围") {
                Text("读取当前系统允许访问的非隐藏照片和视频，预览数量后再决定是否加入待分享。有限照片权限只覆盖你已授权的项目，不代表整个 iPhone 图库。")
                Text("本步骤不读取原件、不从 iCloud 下载、不发送目录。确认后，所选范围会用于之后你手动发起的同步与归档；新增照片不会自动加入。已有待分享项目保留。")
            }
            Section {
                Button(busy ? "正在核对…" : "预览已授权范围") {
                    preview = nil
                    busy = true
                    work = Task {
                        defer { busy = false }
                        do { preview = try await model.prepareBulkSharePreview(); message = nil }
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
                                let added = try await model.confirmBulkSharePreview(preview)
                                message = "已新增 \(added) 项到待分享，其余已在范围内。尚未同步目录或传输原件。"
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
        .navigationTitle("批量准备分享范围")
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
    @ObservedObject var model: LocalLibraryModel
    @ObservedObject var remoteModel: RemoteCompanionModel
    @State private var isSending = false
    @State private var isCheckingCollectionHistory = false
    @State private var isExporting = false
    @State private var isExportingFacts = false
    @State private var savedStreamingArchives: [LocalStreamingArchive] = []
    @State private var isStreamingArchive = false
    @State private var includeAlbumCatalog = false
    @State private var streamTask: Task<Void, Never>?
    @State private var isUploadingArchive = false
    @State private var exportedArchive: URL?
    @State private var exportedArchiveComplete = false
    @State private var exportedVerification: ImageAllMigrationVerification?
    @State private var savedArchives: [URL] = []
    @State private var exportedFacts: URL?
    @State private var statusMessage: String?
    @State private var archiveStatusMessage: String?
    @State private var tagAliasCandidate: LocalSharedTagAliasCandidate?
    @State private var collectionAliasCandidate: LocalSharedCollectionAliasCandidate?

    var body: some View {
        List {
            Section {
                Text("已选择 \(model.sharedSelections.count) 项。只会发送当前仍获准访问的目录及整理信息；权限暂时收缩不会撤销选择，也不会被当作删除。")
                    .font(.footnote)
            }
            Section("待分享资产") {
                ForEach(model.sharedSelections) { selection in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(selection.kind == "video" ? "视频" : "照片")
                            if let date = selection.creationDate {
                                Text(date, format: .dateTime.year().month().day())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(selection.id.uuidString.prefix(8))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("移除") {
                            Task {
                                await model.setShared(
                                    false, assetID: selection.id,
                                    localIdentifier: selection.localIdentifier
                                )
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
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
            Section {
                Button(isSending ? "正在提交…" : "同步目录与整理信息到 Mac") {
                    Task {
                        isSending = true
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
                .disabled(isSending || isCheckingCollectionHistory || !remoteModel.isConnected)
                if let statusMessage {
                    Text(statusMessage).font(.footnote).foregroundStyle(.secondary)
                }
                Text("连接 Mac 后可手动同步目录与整理信息；原件归档需单独点按下方按钮。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("批量范围") {
                NavigationLink("预览并批量加入已授权照片／视频") {
                    LocalBulkShareView(model: model)
                }
            }
            Section("共享集合") {
                NavigationLink("重命名共享集合") {
                    LocalCollectionRenameView(model: model, remote: remoteModel)
                }
            }
            archiveSection
        }
        .navigationTitle("待分享范围")
        .onDisappear { streamTask?.cancel() }
    }

    private var archiveSection: some View {
        Section("本机原件归档") {
            Toggle("保存可访问用户相册目录（含空相册）", isOn: $includeAlbumCatalog)
                .disabled(isStreamingArchive || isExporting || isUploadingArchive)
            if includeAlbumCatalog {
                Text("需完整照片权限。会保存所有可访问用户相册／文件夹的名称、层级和成员数量；只传输已选择的照片和视频，不复制未选成员。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("有限照片权限下仅归档可访问媒体，来源相册不可读取，不能完成相册完整性验收。")
                .font(.footnote).foregroundStyle(.secondary)
            Text("归档仅通过 Wi-Fi 或有线网络发送。切到蜂窝或断网后保留已接收进度，恢复网络后可重试原批次。")
                .font(.footnote).foregroundStyle(.secondary)
            Button(isStreamingArchive ? "正在处理逐资源批次…" : "所选项目逐资源传到 Mac（减少暂存）") {
                guard !isStreamingArchive else { return }
                isStreamingArchive = true
                streamTask = Task {
                    archiveStatusMessage = nil
                    defer { isStreamingArchive = false; streamTask = nil }
                    do {
                        let receipt = try await model.streamSelectedArchive(to: remoteModel, includeAlbumCatalog: includeAlbumCatalog)
                        archiveStatusMessage = "Mac 已接收并复验 \(receipt.itemCount) 项、\(receipt.resourceCount) 个资源；手机原件保留。请在 Mac 接收目录中入库，再完成尾部对账和独立恢复验收。"
                    } catch is CancellationError {
                        archiveStatusMessage = "传输已暂停。恢复连接后可按原范围重试，Mac 已落盘进度保留。"
                    } catch {
                        archiveStatusMessage = "逐资源传输未完成：\(error.localizedDescription)；请恢复原范围和连接后重试。"
                    }
                }
            }
            .disabled(isStreamingArchive || isExporting || isUploadingArchive || isSending
                      || model.sharedSelections.isEmpty || !remoteModel.isConnected)
            if isStreamingArchive {
                Button("暂停逐资源传输") { streamTask?.cancel() }
            }
            Button("查找逐资源批次以继续来源验收") {
                do {
                    savedStreamingArchives = try LocalPhotoArchiveExporter.existingStreamingArchives()
                    if savedStreamingArchives.isEmpty {
                        archiveStatusMessage = "没有已保存回执的逐资源批次；若上次响应丢失或由旧版生成，请按原来源和范围重试传输。"
                    }
                } catch { archiveStatusMessage = "读取逐资源批次失败：\(error.localizedDescription)" }
            }
            .disabled(isStreamingArchive || isExporting || isUploadingArchive)
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
                .disabled(isStreamingArchive || isExporting || isUploadingArchive || isSending
                          || !remoteModel.isConnected)
            }
            Text("每次仅暂存一个资源，Mac 校验后释放手机暂存，保留 Photos 原件。仍需容纳单个最大资源；请保持 App 在前台。重试会重新准备资源，并继续 Mac 已落盘进度。")
                .font(.footnote).foregroundStyle(.secondary)
            Button(isExporting ? "正在读取并核对原件…" : "生成所选项目的本机归档包") {
                Task {
                    isExporting = true
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
            .disabled(isStreamingArchive || isExporting || isSending || model.sharedSelections.isEmpty)
            if let exportedArchive {
                LocalArchiveShareButton(
                    url: exportedArchive, isComplete: exportedArchiveComplete
                )
                Button(isUploadingArchive ? "正在分片上传到 Mac…" : "上传已校验归档到 Mac") {
                    Task {
                        isUploadingArchive = true
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
                          || isUploadingArchive || isExporting || isStreamingArchive)
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
            .disabled(isStreamingArchive || isExporting || isUploadingArchive)
            ForEach(savedArchives, id: \.self) { archive in
                Button("选用归档 \(archive.deletingPathExtension().lastPathComponent)") {
                    Task {
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
                .disabled(isStreamingArchive || isExporting || isUploadingArchive)
            }
            Button(isExportingFacts ? "正在生成整理信息快照…" : "导出最新整理信息快照") {
                Task {
                    isExportingFacts = true
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
            .disabled(isExporting || isExportingFacts || model.sharedSelections.isEmpty)
            if let exportedFacts {
                LocalFactsShareButton(url: exportedFacts)
            }
            if let exportedArchive {
                Button(isUploadingArchive ? "正在上传整理信息…" : "生成并上传最新整理信息到 Mac") {
                    Task {
                        isUploadingArchive = true
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
                          || isUploadingArchive || isExporting || isExportingFacts || isStreamingArchive)
                Button(isUploadingArchive ? "正在上传检查点…" : "生成并上传验收检查点") {
                    Task {
                        isUploadingArchive = true
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
                          || isUploadingArchive || isExporting || isExportingFacts || isStreamingArchive)
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

private struct LocalStreamingArchive: Identifiable {
    let root: URL
    let migrationID: UUID
    var id: URL { root }
}

@MainActor
private enum LocalPhotoArchiveExporter {
    private struct SourceVersion: Codable, Equatable {
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

    private static func hashSourceResource(_ resource: PHAssetResource) async throws -> (Int64, String) {
        let sink = ResourceDigestSink()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().requestData(
                for: resource, options: options,
                dataReceivedHandler: { chunk in sink.append(chunk) },
                completionHandler: { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: ()) }
                }
            )
        }
        return try sink.result()
    }

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
        let beforeResource: @MainActor () async throws -> Void
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

    private static func build(
        snapshot initialSnapshot: LocalSharedSnapshot, includeAlbumCatalog: Bool = false, stream: Stream? = nil
    ) async throws -> Output {
        var snapshot = initialSnapshot
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
        }
        let binding = ResumeBinding(installID: snapshot.installID, sourceEpoch: snapshot.sourceEpoch,
            scopeRevision: snapshot.scopeRevision,
            mediaLocators: Dictionary(uniqueKeysWithValues: snapshot.assets.map { ($0.id.uuidString, $0.localIdentifier) }),
            sources: sourceVersions, albums: albumMemberships.memberships,
            unavailableAlbumCoverage: albumMemberships.coverage == .selectedAssetsOnly ? nil : albumMemberships.coverage,
            albumCatalog: albumMemberships.catalog, destination: stream?.destination)
        let bindingEncoder = JSONEncoder()
        bindingEncoder.outputFormatting = [.sortedKeys]
        let checkpoint = try ImageAllMigrationExportCheckpoint(parent: parent, binding: bindingEncoder.encode(binding))
        defer { checkpoint.close() }
        if stream != nil {
            let frozen = try checkpoint.frozenContext(bindingEncoder.encode(initialSnapshot))
            snapshot = try JSONDecoder().decode(LocalSharedSnapshot.self, from: frozen)
            guard snapshot.installID == initialSnapshot.installID,
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
            let pending = Set(try checkpoint.streamingResourceWindow().map(\.path))
            var revalidated = Set<String>()
            if !pending.isEmpty {
                for selected in snapshot.assets {
                    guard let source = byLocator[selected.localIdentifier] else {
                        throw LocalArchiveExportError.selectionNotVisible
                    }
                    for (index, resource) in PHAssetResource.assetResources(for: source).enumerated() {
                        let location = try checkpoint.resourceLocation(
                            key: "\(selected.id.uuidString)|\(index)", fileExtension: fileExtension(for: resource))
                        if pending.contains(location.url.path) {
                            try await stream?.beforeResource()
                            // Do not discard the interrupted cache if Photos can
                            // no longer supply the current resource without cloud.
                            _ = try await hashSourceResource(resource)
                            revalidated.insert(location.url.path)
                        }
                    }
                }
                guard revalidated == pending else { throw LocalArchiveExportError.sourceChanged }
                try await stream?.beforeResource()
            }
            try checkpoint.resetStreamingResourceWindow()
        }
        let migrationID = checkpoint.migrationID
        let staging = checkpoint.root
        let published = parent.appendingPathComponent("\(migrationID.uuidString).imageallarchive", isDirectory: true)
        try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: staging.path)
        try checkpoint.removeUnpublishedManifest()

        var items: [ImageAllMigrationItem] = []
        for selected in snapshot.assets {
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
                        // Only our deterministic scratch resource is removed,
                        // after independent receiver verification. Never PhotoKit.
                        let checked = try checkpoint.resourceLocation(
                            key: "\(selected.id.uuidString)|\(index)", fileExtension: fileExtension)
                        try manager.removeItem(at: checked.url)
                    }
                    exported.append(record)
                } catch {
                    if stream != nil { throw error }
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
            appleAlbumCoverage: albumMemberships.coverage, appleAlbumCatalog: albumMemberships.catalog
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

    private static func sourceVersion(_ asset: PHAsset) -> SourceVersion {
        SourceVersion(
            modificationDate: asset.modificationDate,
            creationDate: asset.creationDate, metadata: sourceMetadata(asset),
            resourceSignature: PHAssetResource.assetResources(for: asset).map {
                "\($0.type.rawValue):\($0.uniformTypeIdentifier):\($0.originalFilename)"
            }
        )
    }

    private static func sourceMetadata(_ asset: PHAsset) -> ImageAllMigrationSourceMetadata {
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource, toFile: url, options: options
            ) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    nonisolated private static func hashFile(_ url: URL) throws -> (Int64, String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty {
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

    private var currentAsset: LocalAsset {
        model.assets.first(where: { $0.id == asset.id }) ?? asset
    }

    var body: some View {
        List {
            LocalThumbnailView(localIdentifier: asset.localIdentifier)
                .frame(maxWidth: .infinity)
                .frame(height: 280)
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

private struct LocalThumbnailView: View {
    let localIdentifier: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Rectangle().fill(.quaternary).overlay { Image(systemName: "photo") } }
        }
        .task(id: localIdentifier) {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
            guard let asset = result.firstObject else { return }
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .opportunistic
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 560, height: 560),
                contentMode: .aspectFit, options: options
            ) { candidate, info in
                guard (info?[PHImageCancelledKey] as? Bool) != true,
                      info?[PHImageErrorKey] == nil else { return }
                Task { @MainActor in image = candidate }
            }
        }
    }
}
