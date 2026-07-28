import Foundation
import ImageAllRemoteClient
import ImageAllRemoteProtocol
import SwiftUI

@MainActor
final class RemoteCompanionModel: ObservableObject {
    @Published var host: String
    @Published var port: String
    @Published var accessToken: String
    @Published var isConnected = false
    @Published var isBusy = false
    @Published var statusMessage: String?
    @Published var discoveredHosts: [RemoteDiscoveredHost] = []
    @Published var isBrowsing = false
    @Published var capabilities: RemoteCapabilities?
    @Published var sources: [RemoteSourceSummary] = []
    @Published var tags: [RemoteTagSummary] = []
    @Published var selectedSourceID: UUID?
    @Published var selectedTagID: UUID?
    @Published var assets: [RemoteAssetSummary] = []
    @Published var nextCursor: String?
    @Published var selectedAssetIDs: Set<UUID> = []
    @Published var thumbnailDataByAssetID: [UUID: Data] = [:]

    private var client: RemoteLibraryClient?
    private let hostBrowser = RemoteHostBrowser()
    private let defaults = UserDefaults.standard

    private enum DefaultsKey {
        static let host = "imageall.mobile.host"
        static let port = "imageall.mobile.port"
        static let token = "imageall.mobile.accessToken"
    }

    init() {
        host = defaults.string(forKey: DefaultsKey.host) ?? "127.0.0.1"
        port = defaults.string(forKey: DefaultsKey.port) ?? "8787"
        accessToken = defaults.string(forKey: DefaultsKey.token) ?? ""
    }

    func startBrowsing() {
        guard !isBrowsing else { return }
        isBrowsing = true
        hostBrowser.start { [weak self] hosts in
            Task { @MainActor in
                self?.discoveredHosts = hosts
            }
        }
    }

    func stopBrowsing() {
        hostBrowser.stop()
        isBrowsing = false
        discoveredHosts = []
    }

    func selectDiscoveredHost(_ discovered: RemoteDiscoveredHost) {
        host = discovered.host
        port = String(discovered.port)
        if let protocolVersion = discovered.protocolVersion,
           protocolVersion < RemoteProtocolVersion.minimumClient {
            statusMessage = "Host 协议版本过旧（\(protocolVersion)）"
        } else {
            statusMessage = "已选择 \(discovered.name)"
        }
    }

    func connect() async {
        isBusy = true
        defer { isBusy = false }
        statusMessage = nil
        guard let portValue = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              portValue > 0,
              portValue < 65_536
        else {
            statusMessage = "端口无效"
            return
        }
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            statusMessage = "需要访问 token"
            return
        }
        do {
            let endpoint = try RemoteHostEndpoint(
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: portValue,
                accessToken: token
            )
            let nextClient = RemoteLibraryClient(endpoint: endpoint)
            let caps = try await nextClient.fetchCapabilities()
            let nextSources = try await nextClient.fetchSources()
            let nextTags = try await nextClient.fetchTags()
            client = nextClient
            capabilities = caps
            sources = nextSources
            tags = nextTags.filter { $0.state == .active }
            selectedSourceID = nextSources.first?.id
            selectedTagID = tags.first?.id
            isConnected = true
            defaults.set(host, forKey: DefaultsKey.host)
            defaults.set(port, forKey: DefaultsKey.port)
            defaults.set(token, forKey: DefaultsKey.token)
            await reloadAssets(reset: true)
            statusMessage = "已连接 \(caps.hostAppVersion)"
            stopBrowsing()
        } catch {
            isConnected = false
            client = nil
            statusMessage = error.localizedDescription
        }
    }

    func disconnect() {
        client = nil
        isConnected = false
        capabilities = nil
        sources = []
        tags = []
        assets = []
        nextCursor = nil
        selectedAssetIDs = []
        thumbnailDataByAssetID = [:]
        statusMessage = "已断开"
        startBrowsing()
    }

    func reloadAssets(reset: Bool) async {
        guard let client else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let page = try await client.fetchAssets(
                RemoteAssetPageRequest(
                    sourceIDs: selectedSourceID.map { [$0] } ?? [],
                    sort: .newest,
                    limit: 60,
                    cursor: reset ? nil : nextCursor
                )
            )
            if reset {
                assets = page.items
                selectedAssetIDs = []
                thumbnailDataByAssetID = [:]
            } else {
                let existing = Set(assets.map(\.id))
                assets.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            }
            nextCursor = page.nextCursor
            await prefetchThumbnails(for: page.items)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(current asset: RemoteAssetSummary) async {
        guard asset.id == assets.last?.id, nextCursor != nil, !isBusy else { return }
        await reloadAssets(reset: false)
    }

    func toggleSelection(_ assetID: UUID) {
        if selectedAssetIDs.contains(assetID) {
            selectedAssetIDs.remove(assetID)
        } else {
            selectedAssetIDs.insert(assetID)
        }
    }

    func applyTagDecision(_ action: RemoteTagDecisionAction) async {
        guard let client, let tagID = selectedTagID else {
            statusMessage = "请先选择标签"
            return
        }
        let assetIDs = Array(selectedAssetIDs)
        guard !assetIDs.isEmpty else {
            statusMessage = "请先选择资产"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await client.applyTagDecision(
                RemoteBatchTagDecisionRequest(
                    operationID: UUID(),
                    tagID: tagID,
                    assetIDs: assetIDs,
                    action: action
                )
            )
            statusMessage = "已应用到 \(response.appliedAssetCount) 项\(response.replayed ? "（重放）" : "")"
            selectedAssetIDs = []
            await reloadAssets(reset: true)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func prefetchThumbnails(for items: [RemoteAssetSummary]) async {
        guard let client else { return }
        await withTaskGroup(of: (UUID, Data?).self) { group in
            for item in items.prefix(40) {
                if thumbnailDataByAssetID[item.id] != nil { continue }
                group.addTask {
                    do {
                        let data = try await client.loadThumbnail(assetID: item.id, targetPixelWidth: 256)
                        return (item.id, data)
                    } catch {
                        return (item.id, nil)
                    }
                }
            }
            for await (id, data) in group {
                if let data {
                    thumbnailDataByAssetID[id] = data
                }
            }
        }
    }
}

extension RemoteAPIError: LocalizedError {
    public var errorDescription: String? { message }
}
