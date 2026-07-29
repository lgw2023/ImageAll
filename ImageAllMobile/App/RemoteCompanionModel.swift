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
    @Published var reviewItems: [RemoteReviewQueueItem] = []
    @Published var selectedSourceID: UUID?
    @Published var selectedTagID: UUID?
    @Published var assets: [RemoteAssetSummary] = []
    @Published var nextCursor: String?
    @Published var reviewNextCursor: String?
    @Published var selectedAssetIDs: Set<UUID> = []
    @Published var selectedReviewAssetIDs: Set<UUID> = []
    @Published var thumbnailDataByAssetID: [UUID: Data] = [:]
    @Published var reviewThumbnailDataByAssetID: [UUID: Data] = [:]
    @Published var previewDetail: RemoteAssetDetail?
    @Published var previewData: Data?
    @Published var isLoadingPreview = false
    @Published var jobActionInFlightIDs: Set<UUID> = []

    private var client: RemoteLibraryClient?
    private var sessionTokens: RemoteSessionTokens?
    private var certificateFingerprint: String?
    private let hostBrowser = RemoteHostBrowser()
    private let eventSocket = RemoteEventSocket()
    private let defaults = UserDefaults.standard
    private var previewRequestID: UUID?

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
        await pair(using: pairingOfferJSON)
    }

    func pairUsingScannedPayload(_ payload: String) async {
        pairingOfferJSON = payload
        await pair(using: payload)
    }

    private func pair(using payload: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let offer = try RemotePairingPayloadDecoder.decode(payload)
            if let discovered = discoveredHosts.first(where: { $0.hostID == offer.hostID })
                ?? discoveredHosts.first(where: {
                    $0.name.localizedCaseInsensitiveCompare(offer.hostDisplayName) == .orderedSame
                })
            {
                selectDiscoveredHost(discovered)
            }
            port = String(offer.listenPort)
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
        reviewItems = []
        assets = []
        nextCursor = nil
        reviewNextCursor = nil
        selectedAssetIDs = []
        selectedReviewAssetIDs = []
        thumbnailDataByAssetID = [:]
        reviewThumbnailDataByAssetID = [:]
        resetPreview()
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

    func reloadReviewQueue(reset: Bool) async {
        guard let client,
              capabilities?.capabilities.contains(.reviewQueue) == true,
              let tagID = selectedTagID
        else {
            reviewItems = []
            reviewNextCursor = nil
            selectedReviewAssetIDs = []
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let page = try await client.fetchReviewQueue(
                RemoteReviewQueueRequest(
                    tagID: tagID,
                    sourceIDs: selectedSourceID.map { [$0] } ?? [],
                    limit: 40,
                    cursor: reset ? nil : reviewNextCursor
                )
            )
            if reset {
                reviewItems = page.items
                selectedReviewAssetIDs = []
                reviewThumbnailDataByAssetID = [:]
            } else {
                let existing = Set(reviewItems.map(\.id))
                reviewItems.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            }
            reviewNextCursor = page.nextCursor
            await prefetchReviewThumbnails(for: page.items)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(current asset: RemoteAssetSummary) async {
        guard asset.id == assets.last?.id, nextCursor != nil, !isBusy else { return }
        await reloadAssets(reset: false)
    }

    func loadMoreReviewIfNeeded(current item: RemoteReviewQueueItem) async {
        guard item.id == reviewItems.last?.id, reviewNextCursor != nil, !isBusy else { return }
        await reloadReviewQueue(reset: false)
    }

    func toggleSelection(_ assetID: UUID) {
        if selectedAssetIDs.contains(assetID) {
            selectedAssetIDs.remove(assetID)
        } else {
            selectedAssetIDs.insert(assetID)
        }
    }

    func toggleReviewSelection(_ assetID: UUID) {
        if selectedReviewAssetIDs.contains(assetID) {
            selectedReviewAssetIDs.remove(assetID)
        } else {
            selectedReviewAssetIDs.insert(assetID)
        }
    }

    func applyTagDecision(_ action: RemoteTagDecisionAction) async {
        await applyTagDecision(action, assetIDs: Array(selectedAssetIDs))
    }

    func applyTagDecision(
        _ action: RemoteTagDecisionAction,
        assetIDs: [UUID]
    ) async {
        guard let client, let tagID = selectedTagID else {
            statusMessage = "请先选择标签"
            return
        }
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
            selectedAssetIDs.subtract(assetIDs)
            await reloadAssets(reset: true)
            if previewDetail?.assetID == assetIDs.first, assetIDs.count == 1 {
                await loadPreview(assetID: assetIDs[0])
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func applyReviewDecision(_ action: RemoteReviewDecisionAction) async {
        await applyReviewDecision(action, assetIDs: Array(selectedReviewAssetIDs))
    }

    func applyReviewDecision(
        _ action: RemoteReviewDecisionAction,
        assetIDs: [UUID]
    ) async {
        guard let client,
              capabilities?.capabilities.contains(.reviewDecisions) == true,
              let tagID = selectedTagID
        else {
            statusMessage = "Host 不支持远程审核决定"
            return
        }
        guard !assetIDs.isEmpty else {
            statusMessage = "请先选择审核项"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await client.applyReviewDecision(
                RemoteBatchReviewDecisionRequest(
                    operationID: UUID(),
                    tagID: tagID,
                    assetIDs: assetIDs,
                    action: action
                )
            )
            statusMessage = "已审核 \(response.appliedAssetCount) 项\(response.replayed ? "（重放）" : "")"
            selectedReviewAssetIDs.subtract(assetIDs)
            await reloadReviewQueue(reset: true)
            if previewDetail?.assetID == assetIDs.first, assetIDs.count == 1 {
                await loadPreview(assetID: assetIDs[0])
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func applyJobAction(_ action: RemoteJobAction, to jobID: UUID) async {
        guard let client else { return }
        jobActionInFlightIDs.insert(jobID)
        defer { jobActionInFlightIDs.remove(jobID) }
        do {
            try await client.applyJobAction(jobID: jobID, action: action)
            statusMessage = "任务操作已提交"
            await reloadJobs()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadPreview(assetID: UUID) async {
        guard let client else { return }
        let requestID = UUID()
        previewRequestID = requestID
        previewDetail = nil
        previewData = nil
        isLoadingPreview = true
        defer {
            if previewRequestID == requestID {
                isLoadingPreview = false
            }
        }
        do {
            let detail: RemoteAssetDetail? = if capabilities?.capabilities.contains(.assetDetail) == true {
                try await client.fetchAssetDetail(assetID: assetID)
            } else {
                nil
            }
            let data: Data? = if capabilities?.capabilities.contains(.previews) == true {
                try await client.loadPreview(assetID: assetID, targetPixelWidth: 1_600)
            } else {
                try await client.loadThumbnail(assetID: assetID, targetPixelWidth: 1_024)
            }
            guard previewRequestID == requestID else { return }
            previewDetail = detail
            previewData = data
        } catch {
            guard previewRequestID == requestID else { return }
            statusMessage = error.localizedDescription
        }
    }

    func resetPreview() {
        previewRequestID = nil
        previewDetail = nil
        previewData = nil
        isLoadingPreview = false
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
        await reloadReviewQueue(reset: true)
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
            await reloadReviewQueue(reset: true)
        case .tagsChanged:
            if let client {
                tags = (try? await client.fetchTags())?.filter { $0.state == .active } ?? tags
            }
            await reloadReviewQueue(reset: true)
        case .jobsChanged:
            await reloadJobs()
        case .reviewChanged:
            await reloadReviewQueue(reset: true)
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

    private func prefetchReviewThumbnails(for items: [RemoteReviewQueueItem]) async {
        guard let client else { return }
        await withTaskGroup(of: (UUID, Data?).self) { group in
            for item in items.prefix(40) {
                if reviewThumbnailDataByAssetID[item.assetID] != nil { continue }
                group.addTask {
                    do {
                        let data = try await client.loadThumbnail(
                            assetID: item.assetID,
                            targetPixelWidth: 320
                        )
                        return (item.assetID, data)
                    } catch {
                        return (item.assetID, nil)
                    }
                }
            }
            for await (id, data) in group {
                if let data {
                    reviewThumbnailDataByAssetID[id] = data
                }
            }
        }
    }
}
