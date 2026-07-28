import CryptoKit
import Foundation
import ImageAllRemoteClient
import ImageAllRemoteProtocol
import SwiftUI
import UIKit

@MainActor
final class RemoteCompanionModel: ObservableObject {
    @Published var host: String
    @Published var port: String
    @Published var accessToken: String
    @Published var pairingOfferJSON: String = ""
    @Published var isConnected = false
    @Published var isBusy = false
    @Published var statusMessage: String?
    @Published var discoveredHosts: [RemoteDiscoveredHost] = []
    @Published var isBrowsing = false
    @Published var capabilities: RemoteCapabilities?
    @Published var sources: [RemoteSourceSummary] = []
    @Published var tags: [RemoteTagSummary] = []
    @Published var jobs: [RemoteJobSummary] = []
    @Published var selectedSourceID: UUID?
    @Published var selectedTagID: UUID?
    @Published var assets: [RemoteAssetSummary] = []
    @Published var nextCursor: String?
    @Published var selectedAssetIDs: Set<UUID> = []
    @Published var thumbnailDataByAssetID: [UUID: Data] = [:]

    private var client: RemoteLibraryClient?
    private var sessionTokens: RemoteSessionTokens?
    private var certificateFingerprint: String?
    private let hostBrowser = RemoteHostBrowser()
    private let eventSocket = RemoteEventSocket()
    private let defaults = UserDefaults.standard

    private enum DefaultsKey {
        static let host = "imageall.mobile.host"
        static let port = "imageall.mobile.port"
        static let token = "imageall.mobile.accessToken"
        static let refresh = "imageall.mobile.refreshToken"
        static let deviceID = "imageall.mobile.deviceID"
        static let fingerprint = "imageall.mobile.certFingerprint"
        static let usesTLS = "imageall.mobile.usesTLS"
    }

    init() {
        host = defaults.string(forKey: DefaultsKey.host) ?? "127.0.0.1"
        port = defaults.string(forKey: DefaultsKey.port) ?? "8787"
        accessToken = defaults.string(forKey: DefaultsKey.token) ?? ""
        certificateFingerprint = defaults.string(forKey: DefaultsKey.fingerprint)
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
        statusMessage = "已选择 \(discovered.name)"
    }

    func pairUsingOfferJSON() async {
        isBusy = true
        defer { isBusy = false }
        guard let data = pairingOfferJSON.data(using: .utf8),
              let offer = try? JSONDecoder().decode(RemotePairingOffer.self, from: data)
        else {
            statusMessage = "配对 JSON 无效"
            return
        }
        do {
            let deviceKey = SHA256.hash(data: Data(UUID().uuidString.utf8))
                .map { String(format: "%02x", $0) }.joined()
            let bootstrap = try RemoteLibraryClient(
                endpoint: RemoteHostEndpoint(
                    host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                    port: offer.listenPort,
                    accessToken: "",
                    usesTLS: offer.usesTLS
                ),
                transport: offer.usesTLS
                    ? URLSessionRemoteHTTPTransport(
                        session: RemotePinnedURLSessionFactory.makeSession(
                            certificateFingerprintSHA256: offer.certificateFingerprintSHA256
                        )
                    )
                    : URLSessionRemoteHTTPTransport(),
                sendAuthorization: false
            )
            let tokens = try await bootstrap.completePairing(
                RemotePairingCompleteRequest(
                    pairingToken: offer.pairingToken,
                    deviceName: UIDevice.current.name,
                    devicePublicKeySPKI_SHA256: deviceKey
                )
            )
            applySession(tokens)
            statusMessage = "配对成功"
            await connectWithStoredSession()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func connect() async {
        if defaults.string(forKey: DefaultsKey.refresh) != nil {
            await connectWithStoredSession()
            return
        }
        await connectWithManualToken()
    }

    func disconnect() {
        eventSocket.stop()
        client = nil
        sessionTokens = nil
        isConnected = false
        capabilities = nil
        sources = []
        tags = []
        jobs = []
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

    func reloadJobs() async {
        guard let client else { return }
        do {
            jobs = try await client.fetchJobs()
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

    private func connectWithManualToken() async {
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
            statusMessage = "需要 access token 或先完成配对"
            return
        }
        do {
            let usesTLS = defaults.bool(forKey: DefaultsKey.usesTLS)
            let endpoint = try RemoteHostEndpoint(
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: portValue,
                accessToken: token,
                usesTLS: usesTLS
            )
            let transport: any RemoteHTTPTransporting
            if usesTLS, let fingerprint = certificateFingerprint {
                transport = URLSessionRemoteHTTPTransport(
                    session: RemotePinnedURLSessionFactory.makeSession(
                        certificateFingerprintSHA256: fingerprint
                    )
                )
            } else {
                transport = URLSessionRemoteHTTPTransport()
            }
            try await finishConnect(
                RemoteLibraryClient(endpoint: endpoint, transport: transport)
            )
        } catch {
            isConnected = false
            client = nil
            statusMessage = error.localizedDescription
        }
    }

    private func connectWithStoredSession() async {
        isBusy = true
        defer { isBusy = false }
        guard let refresh = defaults.string(forKey: DefaultsKey.refresh),
              let deviceIDRaw = defaults.string(forKey: DefaultsKey.deviceID),
              let deviceID = UUID(uuidString: deviceIDRaw),
              let fingerprint = defaults.string(forKey: DefaultsKey.fingerprint),
              let portValue = Int(port)
        else {
            await connectWithManualToken()
            return
        }
        do {
            let usesTLS = defaults.bool(forKey: DefaultsKey.usesTLS)
            let bootstrap = try RemoteLibraryClient(
                endpoint: RemoteHostEndpoint(
                    host: host,
                    port: portValue,
                    accessToken: "",
                    usesTLS: usesTLS
                ),
                transport: usesTLS
                    ? URLSessionRemoteHTTPTransport(
                        session: RemotePinnedURLSessionFactory.makeSession(
                            certificateFingerprintSHA256: fingerprint
                        )
                    )
                    : URLSessionRemoteHTTPTransport(),
                sendAuthorization: false
            )
            let tokens = try await bootstrap.refreshSession(
                RemoteTokenRefreshRequest(deviceID: deviceID, refreshToken: refresh)
            )
            applySession(tokens)
            let client = try RemoteLibraryClient.pinned(
                host: host,
                port: tokens.listenPort,
                accessToken: tokens.accessToken,
                certificateFingerprintSHA256: tokens.certificateFingerprintSHA256
            )
            try await finishConnect(client)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func finishConnect(_ nextClient: RemoteLibraryClient) async throws {
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
        stopBrowsing()
        await reloadAssets(reset: true)
        await reloadJobs()
        startEvents()
        statusMessage = "已连接 \(caps.hostAppVersion)\(caps.usesTLS ? " · TLS" : "")"
    }

    private func applySession(_ tokens: RemoteSessionTokens) {
        sessionTokens = tokens
        accessToken = tokens.accessToken
        port = String(tokens.listenPort)
        certificateFingerprint = tokens.certificateFingerprintSHA256
        defaults.set(tokens.accessToken, forKey: DefaultsKey.token)
        defaults.set(tokens.refreshToken, forKey: DefaultsKey.refresh)
        defaults.set(tokens.deviceID.uuidString, forKey: DefaultsKey.deviceID)
        defaults.set(tokens.certificateFingerprintSHA256, forKey: DefaultsKey.fingerprint)
        defaults.set(tokens.usesTLS, forKey: DefaultsKey.usesTLS)
        defaults.set(tokens.listenPort, forKey: DefaultsKey.port)
    }

    private func startEvents() {
        eventSocket.stop()
        // Reconstruct endpoint from client is not exposed; use stored values.
        guard let portValue = Int(port) else { return }
        do {
            let endpoint = try RemoteHostEndpoint(
                host: host,
                port: portValue,
                accessToken: accessToken,
                usesTLS: defaults.bool(forKey: DefaultsKey.usesTLS)
            )
            try eventSocket.connect(
                endpoint: endpoint,
                certificateFingerprintSHA256: certificateFingerprint
            ) { [weak self] event in
                Task { @MainActor in
                    await self?.handle(event: event)
                }
            }
        } catch {
            statusMessage = "事件通道失败：\(error.localizedDescription)"
        }
    }

    private func handle(event: RemoteEvent) async {
        switch event.kind {
        case .ping:
            break
        case .sourcesChanged, .assetsChanged:
            await reloadAssets(reset: true)
        case .tagsChanged:
            if let client {
                tags = (try? await client.fetchTags())?.filter { $0.state == .active } ?? tags
            }
        case .jobsChanged, .reviewChanged:
            await reloadJobs()
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