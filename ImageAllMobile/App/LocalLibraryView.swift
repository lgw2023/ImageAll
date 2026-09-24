import ImageAllLocalLibrary
import ImageAllRemoteProtocol
import Photos
import SwiftUI
import UIKit

struct LocalSharedSyncSummary {
    let applied: Int
    let unchanged: Int
    let conflicts: Int
    let deferred: Int
    let received: Int
    let pullSupported: Bool
    let pullHasMore: Bool
    let remaining: Int
}

@MainActor
final class LocalLibraryModel: ObservableObject {
    @Published private(set) var authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var assets: [LocalAsset] = []
    @Published private(set) var tags: [LocalTag] = []
    @Published private(set) var collections: [LocalCollection] = []
    @Published private(set) var sharedSelections: [LocalShareSelection] = []
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

    func prepareSharedSnapshot() async throws -> LocalSharedSnapshot {
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
        return try await store.prepareSharedSnapshot(
            visibleIdentifiers: Set(visible.map(\.localIdentifier))
        )
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
            var sent = 0
            var blockedFields: Set<String> = []
            let visible = Dictionary(uniqueKeysWithValues: snapshot.assets.map { ($0.id, $0) })
            let pending = try await store.pendingSharedOperations()
            for operation in pending {
                guard operation.field.hasPrefix("tag.") else {
                    deferred += 1 // Collection/favorite have separate authority and protocol work.
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
                guard let prepared = try await store.prepareSharedTagOperation(
                    id: operation.id, hostID: receipt.hostID, deviceID: receipt.deviceID
                ) else { continue }
                let tagReceipt = try await remoteModel.submitLocalLibraryTagDecision(prepared)
                sent += 1
                let disposition: LocalSharedTagDisposition = switch tagReceipt.disposition {
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
                    currentDecision: currentDecision
                )
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
            let remaining = try await store.pendingSharedOperations().count
            await reloadFacts()
            return LocalSharedSyncSummary(
                applied: applied, unchanged: unchanged,
                conflicts: conflicts, deferred: deferred,
                received: received,
                pullSupported: pullSupported,
                pullHasMore: pullHasMore,
                remaining: remaining
            )
        } catch {
            await reloadFacts()
            throw error
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
            pendingCount = try await store.pendingSharedOperations().count
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
    @State private var statusMessage: String?

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
            Section {
                Button(isSending ? "正在提交…" : "同步目录与标签到 Mac") {
                    Task {
                        isSending = true
                        defer { isSending = false }
                        do {
                            let snapshot = try await model.prepareSharedSnapshot()
                            let receipt = try await remoteModel.submitLocalLibrarySnapshot(snapshot)
                            do {
                                let result = try await model.completeSharedSync(
                                    snapshot: snapshot, receipt: receipt,
                                    remoteModel: remoteModel
                                )
                                let pull = result.pullSupported
                                    ? "Mac 标签回传 \(result.received) 项"
                                    : "当前 Mac 版本尚无标签回传"
                                let continuation = result.pullHasMore
                                    ? "Mac 仍有后续变化页，请再次同步。" : ""
                                statusMessage = "Mac 已接收 \(receipt.acceptedAssetCount) 项目录；手机标签提交 \(result.applied) 项、已一致 \(result.unchanged) 项；\(pull)、冲突 \(result.conflicts) 项；仍待处理 \(result.remaining) 项。\(continuation)原件尚未传输。"
                            } catch {
                                statusMessage = "Mac 已接收目录，但整理信息提交未完成：\(error.localizedDescription)"
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
                Text("先在“Mac 图库”完成设备配对。标签冲突会保留在手机；集合与收藏仍待后续协议接入。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("待分享范围")
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
