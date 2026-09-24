import ImageAllLocalLibrary
import Photos
import SwiftUI
import UIKit

@MainActor
final class LocalLibraryModel: ObservableObject {
    @Published private(set) var authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var assets: [LocalAsset] = []
    @Published private(set) var tags: [LocalTag] = []
    @Published private(set) var collections: [LocalCollection] = []
    @Published private(set) var pendingCount = 0
    @Published private(set) var hasMore = false
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

    func setFavoriteTarget(_ favorite: Bool, asset: LocalAsset) async {
        guard let store else { return }
        do {
            try await store.setFavoriteTarget(assetID: asset.id, isFavorite: favorite)
            if let index = assets.firstIndex(where: { $0.id == asset.id }) {
                // Refresh from the durable row rather than assuming the write succeeded.
                let result = try await store.assets(visibleIdentifiers: [asset.localIdentifier])
                if let refreshed = result.first { assets[index] = refreshed }
            }
            await reloadFacts()
        } catch { errorMessage = "保存收藏目标失败：\(error.localizedDescription)" }
    }

    private func reloadFacts() async {
        guard let store else { return }
        do {
            tags = try await store.tags()
            collections = try await store.collections()
            pendingCount = try await store.pendingOperations().count
        } catch { errorMessage = "读取本机资料失败：\(error.localizedDescription)" }
    }
}

struct LocalLibraryView: View {
    @ObservedObject var model: LocalLibraryModel
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
                LabeledContent("待同步整理操作", value: "\(model.pendingCount)")
                Text("本机整理会持久保存；分享范围与 Mac 同步将在后续阶段提供。")
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
                Button(currentAsset.favoriteTarget ?? currentAsset.observedFavorite ? "取消收藏目标" : "设为收藏目标") {
                    Task {
                        await model.setFavoriteTarget(
                            !(currentAsset.favoriteTarget ?? currentAsset.observedFavorite), asset: currentAsset
                        )
                    }
                }
                Text("这是 ImageAll 本机收藏目标；Photos 写回状态需要单独确认。")
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
        }
        .navigationTitle("本机照片")
        .task(id: asset.id) {
            decisions = await model.decisions(for: asset)
            memberships = await model.memberships(for: asset)
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
