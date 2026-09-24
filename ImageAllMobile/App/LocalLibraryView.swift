import CryptoKit
import CoreTransferable
import ImageAllLocalLibrary
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
    @Published private(set) var pendingCount = 0
    @Published private(set) var hasMore = false
    @Published private(set) var favoriteWritesInFlight: Set<UUID> = []
    @Published var errorMessage: String?

    private let store: LocalLibraryStore?
    private var fetchedAssets: PHFetchResult<PHAsset>?
    private var loadedCount = 0
    private let pageSize = 100

    init() {
        do {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            store = try LocalLibraryStore(url: root.appendingPathComponent("LocalLibrary/local.sqlite"))
        } catch {
            store = nil
            errorMessage = "本机资料库无法打开：\(error.localizedDescription)"
        }
    }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await refresh()
    }

    func refresh() async {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            // Permission loss hides the projection. The local facts and outbox remain intact.
            fetchedAssets = nil
            loadedCount = 0
            assets = []
            hasMore = false
            await reloadFacts()
            return
        }
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAssetSourceTypes = .typeUserLibrary
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchedAssets = PHAsset.fetchAssets(with: options)
        loadedCount = 0
        assets = []
        await loadMore()
    }

    func loadMore() async {
        guard let fetchedAssets, let store else { return }
        let end = min(fetchedAssets.count, loadedCount + pageSize)
        guard end > loadedCount else {
            hasMore = false
            return
        }
        let page = (loadedCount..<end).map { fetchedAssets.object(at: $0) }
        do {
            try await store.observe(page.map {
                LocalObservedAsset(
                    localIdentifier: $0.localIdentifier,
                    kind: $0.mediaType == .video ? "video" : "image",
                    creationDate: $0.creationDate,
                    isFavorite: $0.isFavorite
                )
            })
            let pageIDs = Set(page.map(\.localIdentifier))
            let indexed = try await store.assets(visibleIdentifiers: pageIDs)
            let byLocator = Dictionary(uniqueKeysWithValues: indexed.map { ($0.localIdentifier, $0) })
            assets += page.compactMap { byLocator[$0.localIdentifier] }
            loadedCount = end
            hasMore = end < fetchedAssets.count
            await reloadFacts()
        } catch {
            errorMessage = "本机资料保存失败：\(error.localizedDescription)"
        }
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

    func setMembership(_ included: Bool, asset: LocalAsset, collection: LocalCollection) async {
        guard let store else { return }
        do {
            try await store.setMembership(assetID: asset.id, collectionID: collection.id, included: included)
            await reloadFacts()
        } catch { errorMessage = "保存集合失败：\(error.localizedDescription)" }
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
    func exportSelectedArchive() async throws -> (URL, ImageAllMigrationVerification) {
        let snapshot = try await makeMigrationFactSnapshot()
        guard !snapshot.selectedAssetIDs.isEmpty else {
            throw LocalArchiveExportError.emptySelection
        }
        guard Set(snapshot.selectedAssetIDs) == Set(snapshot.assets.map(\.id)) else {
            throw LocalArchiveExportError.selectionNotVisible
        }
        let result = try await LocalPhotoArchiveExporter.export(snapshot: snapshot)
        do {
            let current = try await makeMigrationFactSnapshot()
            guard current.sourceEpoch == snapshot.sourceEpoch,
                  current.scopeRevision == snapshot.scopeRevision,
                  Set(current.selectedAssetIDs) == Set(snapshot.selectedAssetIDs),
                  Set(current.assets.map(\.id)) == Set(snapshot.assets.map(\.id)) else {
                throw LocalArchiveExportError.selectionChanged
            }
            return result
        } catch {
            try? FileManager.default.removeItem(at: result.0)
            throw error
        }
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

    func exportCompletionCheckpointFacts(for archiveRoot: URL) async throws -> URL {
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
        let verification = try await LocalPhotoArchiveExporter.verifyCurrentSourcesMatchArchive(
            at: archiveRoot, snapshot: before.snapshot
        )
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
                archiveManifestSHA256: verification.manifestSHA256,
                sourceVerifiedAtMs: verifiedAtMs
            )
        }.value
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
                                fieldRevision: change.fieldRevision
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
            let remaining = try await store.pendingSharedOperations().count
            await reloadFacts()
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
            let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard authorization == .authorized || authorization == .limited else {
                throw LocalFavoriteSourceError.authorizationRequired
            }
            let fetched = PHAsset.fetchAssets(
                withLocalIdentifiers: [asset.localIdentifier], options: nil
            )
            guard let sourceAsset = fetched.firstObject else {
                throw LocalFavoriteSourceError.assetUnavailable
            }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: sourceAsset).isFavorite = favorite
            }
            let readback = PHAsset.fetchAssets(
                withLocalIdentifiers: [asset.localIdentifier], options: nil
            ).firstObject?.isFavorite
            try await store.finishFavoriteWriteback(
                assetID: asset.id, requestedValue: favorite, observedValue: readback
            )
            try await refreshStoredAsset(asset)
            if readback != favorite {
                errorMessage = "已保存 ImageAll 收藏目标，但 Photos 回读尚未一致，可稍后刷新或重试。"
            }
        } catch {
            try? await store.finishFavoriteWriteback(
                assetID: asset.id, requestedValue: favorite, observedValue: nil
            )
            try? await refreshStoredAsset(asset)
            errorMessage = "已保存 ImageAll 收藏目标，Photos 写回未完成：\(error.localizedDescription)"
        }
    }

    private func refreshStoredAsset(_ asset: LocalAsset) async throws {
        guard let store, let index = assets.firstIndex(where: { $0.id == asset.id }) else { return }
        if let refreshed = try await store.assets(visibleIdentifiers: [asset.localIdentifier]).first {
            assets[index] = refreshed
        }
    }

    private func reloadFacts() async {
        guard let store else { return }
        do {
            tags = try await store.tags()
            collections = try await store.collections()
            sharedSelections = try await store.sharedSelections()
            let pending = try await store.pendingSharedOperations()
            pendingCount = pending.count
            sharedConflicts = pending.filter(\.isConflicted)
        } catch { errorMessage = "读取本机资料失败：\(error.localizedDescription)" }
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
                Button("刷新", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            }
        }
        .task { await model.refresh() }
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
                ForEach(model.collections) { collection in Text(collection.name) }
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

private struct LocalShareScopeView: View {
    @ObservedObject var model: LocalLibraryModel
    @ObservedObject var remoteModel: RemoteCompanionModel
    @State private var isSending = false
    @State private var isExporting = false
    @State private var isExportingFacts = false
    @State private var isUploadingArchive = false
    @State private var exportedArchive: URL?
    @State private var exportedArchiveComplete = false
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
                                if operation.conflictReason == .fieldVersion,
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
                            let receipt = try await remoteModel.submitLocalLibrarySnapshot(snapshot)
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
                .disabled(isSending || !remoteModel.isConnected)
                if let statusMessage {
                    Text(statusMessage).font(.footnote).foregroundStyle(.secondary)
                }
                Text("连接 Mac 后可手动同步目录与整理信息；原件归档需单独点按下方按钮。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            archiveSection
        }
        .navigationTitle("待分享范围")
    }

    private var archiveSection: some View {
        Section("本机原件归档") {
            Button(isExporting ? "正在读取并核对原件…" : "生成所选项目的本机归档包") {
                Task {
                    isExporting = true
                    exportedArchive = nil
                    exportedArchiveComplete = false
                    archiveStatusMessage = nil
                    defer { isExporting = false }
                    do {
                        let (url, verification) = try await model.exportSelectedArchive()
                        exportedArchive = url
                        exportedArchiveComplete = verification.isComplete
                        archiveStatusMessage = "归档 \(verification.itemCount) 项，已校验 \(verification.resourceCount) 个资源；必需原件缺失 \(verification.incompleteMediaIDs.count) 项。缺失项不能视为迁移完成。"
                    } catch {
                        archiveStatusMessage = "归档未完成：\(error.localizedDescription)"
                    }
                }
            }
            .disabled(isExporting || isSending || model.sharedSelections.isEmpty)
            if let exportedArchive {
                LocalArchiveShareButton(url: exportedArchive)
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
                          || isUploadingArchive || isExporting)
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
            .disabled(isExporting || isUploadingArchive)
            ForEach(savedArchives, id: \.self) { archive in
                Button("选用归档 \(archive.deletingPathExtension().lastPathComponent)") {
                    Task {
                        do {
                            let verification = try await Task.detached(priority: .utility) {
                                try ImageAllMigrationArchive.verify(at: archive)
                            }.value
                            guard verification.isComplete else {
                                throw LocalArchiveExportError.incompleteArchive
                            }
                            exportedArchive = archive
                            exportedArchiveComplete = true
                            archiveStatusMessage = "已选用现有归档；连接 Mac 后会从接收端已提交的分片继续上传。"
                        } catch {
                            archiveStatusMessage = "现有归档不可继续上传：\(error.localizedDescription)"
                        }
                    }
                }
                .disabled(isExporting || isUploadingArchive)
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
                          || isUploadingArchive || isExporting || isExportingFacts)
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
                          || isUploadingArchive || isExporting || isExportingFacts)
            }
            if let archiveStatusMessage {
                Text(archiveStatusMessage).font(.footnote).foregroundStyle(.secondary)
            }
            Text("仅读取当前获准访问的所选项目，不从 iCloud 下载。归档包由用户选择导出位置；Mac 入库与迁移完成校验仍需后续步骤。")
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

    var body: some View {
        ShareLink(
            item: LocalMigrationArchiveTransfer(url: url),
            preview: SharePreview("ImageAll 原件归档包")
        ) {
            Text("导出归档包到文件或其他 App")
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

@MainActor
private enum LocalPhotoArchiveExporter {
    private struct SourceVersion: Equatable {
        let modificationDate: Date?
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
        guard let header, verification.isComplete,
              header.appleAlbumCoverage == .selectedAssetsOnly,
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
        let albums = try captureAlbumMemberships(selectedLocators: selectedLocators)
        for item in items {
            guard let selected = assetsByID[item.mediaID],
                  selected.localIdentifier == item.sourceLocalIdentifier,
                  let asset = byLocator[item.sourceLocalIdentifier],
                  item.appleAlbums == (albums[item.sourceLocalIdentifier] ?? []),
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
                let expected = item.resources[index]
                let uti = resource.uniformTypeIdentifier.isEmpty
                    ? UTType.data.identifier : resource.uniformTypeIdentifier
                guard expected.status == .present,
                      expected.role == (index == primary ? "original" : resourceRole(resource.type)),
                      expected.uniformTypeIdentifier == uti,
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
              albums == (try captureAlbumMemberships(selectedLocators: selectedLocators)) else {
            throw LocalArchiveExportError.sourceChanged
        }
        return verification
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

    static func export(
        snapshot: LocalSharedSnapshot
    ) async throws -> (URL, ImageAllMigrationVerification) {
        let manager = FileManager.default
        let support = try manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let parent = support.appendingPathComponent("LocalLibrary/MigrationArchives", isDirectory: true)
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        var parentValues = URLResourceValues()
        parentValues.isExcludedFromBackup = true
        var mutableParent = parent
        try mutableParent.setResourceValues(parentValues)
        let migrationID = UUID()
        let staging = parent.appendingPathComponent(".staging-\(migrationID.uuidString)", isDirectory: true)
        let published = parent.appendingPathComponent("\(migrationID.uuidString).imageallarchive", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        try manager.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: staging.path
        )
        var shouldRemoveStaging = true
        defer { if shouldRemoveStaging { try? manager.removeItem(at: staging) } }

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
        let albumMemberships = try captureAlbumMemberships(selectedLocators: selectedLocators)

        var items: [ImageAllMigrationItem] = []
        for selected in snapshot.assets {
            guard let source = byLocator[selected.localIdentifier] else {
                throw LocalArchiveExportError.selectionNotVisible
            }
            let sourceResources = PHAssetResource.assetResources(for: source)
            let primary = primaryResourceIndex(mediaType: source.mediaType, resources: sourceResources)
            var exported: [ImageAllMigrationResource] = []
            for (index, resource) in sourceResources.enumerated() {
                let id = UUID()
                let uti = resource.uniformTypeIdentifier.isEmpty
                    ? UTType.data.identifier : resource.uniformTypeIdentifier
                let role = index == primary ? "original" : resourceRole(resource.type)
                let preferredExtension = UTType(uti)?.preferredFilenameExtension ?? "bin"
                let fileExtension = preferredExtension.count <= 12
                    && preferredExtension.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
                    ? preferredExtension : "bin"
                let relativePath = "resources/\(id.uuidString.lowercased()).\(fileExtension)"
                let destination = staging.appendingPathComponent(relativePath)
                try manager.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                do {
                    try await writeLocalResource(resource, to: destination)
                    let digest = try await Task.detached {
                        try hashFile(destination)
                    }.value
                    try manager.setAttributes(
                        [.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path
                    )
                    exported.append(ImageAllMigrationResource(
                        id: id, role: role, version: 1, uniformTypeIdentifier: uti,
                        required: true, status: .present, relativePath: relativePath,
                        byteCount: digest.0, sha256: digest.1
                    ))
                } catch {
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
                        byteCount: nil, sha256: nil
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
                createdAtMs: selected.creationDate.map { Int64($0.timeIntervalSince1970 * 1_000) },
                favoriteTarget: selected.favoriteTarget,
                observedFavorite: selected.observedFavorite,
                factRevision: snapshot.outboxWatermark,
                tagDecisions: decisions, collections: collections, resources: exported,
                appleAlbums: albumMemberships[selected.localIdentifier] ?? []
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
                  selectedLocators: selectedLocators
              )) else {
            throw LocalArchiveExportError.sourceChanged
        }
        let header = ImageAllMigrationHeader(
            migrationID: migrationID, sourceDeviceID: snapshot.installID,
            sourceEpoch: snapshot.sourceEpoch, scopeRevision: snapshot.scopeRevision,
            inventoryWatermark: snapshot.snapshotSequence, declaredItemCount: items.count,
            appleAlbumCoverage: .selectedAssetsOnly
        )
        let resourcesDirectory = staging.appendingPathComponent("resources", isDirectory: true)
        if manager.fileExists(atPath: resourcesDirectory.path),
           try manager.contentsOfDirectory(atPath: resourcesDirectory.path).isEmpty {
            try manager.removeItem(at: resourcesDirectory)
        }
        try ImageAllMigrationArchive.write(header: header, items: items, to: staging)
        let verification = try ImageAllMigrationArchive.verify(at: staging)
        try manager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: staging.appendingPathComponent(ImageAllMigrationArchive.manifestFilename).path
        )
        try manager.moveItem(at: staging, to: published)
        shouldRemoveStaging = false
        return (published, verification)
    }

    /// Traverse only user-created Photos albums/folders. A membership is kept
    /// only for an asset in the explicit export scope; unrelated album members
    /// never enter the portable manifest.
    private static func captureAlbumMemberships(
        selectedLocators: Set<String>
    ) throws -> [String: [ImageAllMigrationAppleAlbumMembership]] {
        var result: [String: [ImageAllMigrationAppleAlbumMembership]] = [:]
        var visited: Set<String> = []
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
                    let path = folders + [.init(
                        localIdentifier: folder.localIdentifier, title: folder.localizedTitle
                    )]
                    try walk(PHCollection.fetchCollections(in: folder, options: nil), folders: path)
                } else if let album = collection as? PHAssetCollection,
                          album.assetCollectionType == .album {
                    let assets = PHAsset.fetchAssets(in: album, options: nil)
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
        return result
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
            resourceSignature: PHAssetResource.assetResources(for: asset).map {
                "\($0.type.rawValue):\($0.uniformTypeIdentifier)"
            }
        )
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
                                Task { await model.setDecision(value, asset: asset, tag: tag) }
                            }
                        )) {
                            Text("清除").tag(LocalDecision.cleared)
                            Text("接受").tag(LocalDecision.accepted)
                            Text("拒绝").tag(LocalDecision.rejected)
                        }
                        .labelsHidden()
                    }
                }
            }
            Section("ImageAll 集合") {
                ForEach(model.collections) { collection in
                    Toggle(collection.name, isOn: Binding(
                        get: { memberships.contains(collection.id) },
                        set: { included in
                            if included { memberships.insert(collection.id) }
                            else { memberships.remove(collection.id) }
                            Task { await model.setMembership(included, asset: asset, collection: collection) }
                        }
                    ))
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
            decisions = await model.decisions(for: asset)
            memberships = await model.memberships(for: asset)
        }
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
