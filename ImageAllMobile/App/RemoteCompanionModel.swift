import CryptoKit
import Foundation
import ImageAllRemoteClient
import ImageAllRemoteProtocol
import ImageAllLocalLibrary
import Network
import SwiftUI
import UIKit

enum RemoteLibraryTagFilterMode: String, CaseIterable, Identifiable {
    case none
    case accepted
    case rejected
    case excluded

    var id: String { rawValue }
}

private struct RemotePreviewImageCacheEntry {
    let data: Data
    let contentRevision: Int?
}

@MainActor
final class RemoteCompanionModel: ObservableObject {
    @Published var host: String
    @Published var port: String
    @Published var accessToken: String
    @Published var pairingOfferJSON: String = ""
    @Published var isConnected = false
    @Published private(set) var usbSelected = false
    @Published private(set) var usbStatus = "USB 有线连接未开启"
    @Published private(set) var usbPendingOffer: RemotePairingOffer?
    #if DEBUG
    private(set) var usbExplicitRejectionCount = 0
    #endif
    @Published private(set) var migrationConfirmedBytes: Int64 = 0
    @Published private(set) var migrationItemIndex = 0
    @Published private(set) var migrationItemCount = 0
    private var migrationMetrics = RemoteMigrationTransferMetrics()
    @Published private(set) var migrationPhase = "准备目录与整理信息"
    @Published private(set) var sourceRevalidation = LocalShareSourceRevalidationProgress()
    private let usbBridge = ImageAllUSBPhoneTunnel()
    private var usbManuallyPaused = false
    private var usbLoopbackPort: UInt16?
    private var usbOffer: RemotePairingOffer?
    private(set) var transportGeneration = UUID()
    var importTransportLabel: String { usbSelected ? (usbLoopbackPort == nil ? "USB 已暂停" : "USB 有线") : "网络连接" }
    var migrationProgressText: String {
        let now = ProcessInfo.processInfo.systemUptime
        let amount = ByteCountFormatter.string(fromByteCount: migrationConfirmedBytes, countStyle: .binary)
        let rate: String
        if migrationPhase == "传输原件", let value = migrationMetrics.uploadBytesPerSecond(at: now) {
            rate = "传输均速 " + ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary) + "/s"
        } else { rate = migrationIntent == .sealReceived ? "仅封存，不上传原件" : "本阶段暂无原件传输速率" }
        let elapsed = Int(migrationMetrics.elapsedSeconds(at: now))
        let item = migrationItemCount > 0 ? " · 第 \(migrationItemIndex)/\(migrationItemCount) 项" : ""
        let pending = migrationPendingAssetCount > 0 ? " · \(migrationPendingAssetCount) 项不可访问，保留待处理" : ""
        let phase = migrationPhase == "核对旧批次手机原件，保留已确认进度"
            ? sourceRevalidation.message : migrationPhase
        return "\(phase)\(item)\(pending) · 已确认原件 \(amount) · \(rate) · 总耗时 \(elapsed)s · \(importTransportLabel)"
    }
    private var migrationIdleTimerWasDisabled: Bool?
    private var sessionRefreshWork: (id: UUID, generation: UInt64, task: Task<RemoteLibraryClient, Error>)?
    private var migrationLastDiagnosticAt: TimeInterval = 0
    private var migrationDiagnosticError: [String: Any] = [:]
    private var migrationRecoveryEvidence: [String: Any] = [:]

    private let migrationDiagnosticHeartbeat = RemoteMigrationDiagnosticHeartbeat()
    private var migrationIntent: LocalShareTask.Intent = .transferSelection

    func beginMigrationProgress(intent: LocalShareTask.Intent = .transferSelection) {
        migrationDiagnosticHeartbeat.stop()
        migrationIntent = intent
        migrationDiagnosticError = [:]
        migrationRecoveryEvidence = [:]
        sourceRevalidation = LocalShareSourceRevalidationProgress()
        migrationItemIndex = 0; migrationItemCount = 0; migrationPendingAssetCount = 0
        if migrationIdleTimerWasDisabled == nil {
            migrationIdleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        migrationConfirmedBytes = 0
        migrationMetrics.begin(at: ProcessInfo.processInfo.systemUptime)
        migrationPhase = "准备目录与整理信息"
        recordMigrationOutcome("running")
        migrationDiagnosticHeartbeat.start { [weak self] in
            self?.recordMigrationOutcome("running")
        }
    }
    @Published private(set) var migrationPendingAssetCount = 0
    func setMigrationAvailability(available: Int, pending: Int) {
        migrationPendingAssetCount = pending
        migrationItemCount = available + pending
    }
    func recordMigrationTask(id: UUID) {
        migrationRecoveryEvidence["taskID"] = id.uuidString
        recordMigrationOutcome("running")
    }
    func recordMigrationRecovery(id: UUID, receiptCount: Int) {
        migrationRecoveryEvidence["migrationID"] = id.uuidString
        migrationRecoveryEvidence["resumeReceiptCount"] = receiptCount
        recordMigrationOutcome("running")
    }
    func beginSourceRevalidation(expectedBytes: Int64) {
        sourceRevalidation.begin(expectedBytes: expectedBytes)
        setMigrationPhase("核对旧批次手机原件，保留已确认进度")
        recordMigrationOutcome("running")
    }
    func recordSourceRevalidationRead(_ bytes: Int64) {
        sourceRevalidation.recordReadBytes(bytes)
    }
    func finishSourceRevalidation() {
        sourceRevalidation.didVerify()
        recordMigrationOutcome("running")
    }
    func setMigrationPhase(_ phase: String) {
        migrationPhase = phase
        let category: RemoteMigrationTransferMetrics.Phase
        switch phase {
        case "传输原件": category = .upload
        case "Mac 复验原件", "核对 Mac 已接收原件，跳过手机重复导出",
             "核对旧批次手机原件，保留已确认进度": category = .verification
        case "恢复 Mac 已确认断点": category = .recovery
        case "同步整理信息与封存批次": category = .finalization
        default: category = phase.hasPrefix("连接短暂中断") ? .recovery : .preparation
        }
        let now = ProcessInfo.processInfo.systemUptime
        migrationMetrics.enterPhase(category, at: now)
        if migrationDiagnosticHeartbeat.isRunning,
           category == .finalization || now - migrationLastDiagnosticAt >= 1 {
            recordMigrationOutcome("running")
        }
    }
    func reportMigrationItem(index: Int, total: Int) {
        migrationItemIndex = index; migrationItemCount = total
        if ProcessInfo.processInfo.systemUptime - migrationLastDiagnosticAt >= 10 { recordMigrationOutcome("running") }
    }
    func beginMigrationUpload() {
        migrationMetrics.beginUpload(at: ProcessInfo.processInfo.systemUptime)
        setMigrationPhase("传输原件")
    }
    func endMigrationUpload() { migrationMetrics.endUpload(at: ProcessInfo.processInfo.systemUptime) }
    func finishMigrationProgress() {
        migrationDiagnosticHeartbeat.stop()
        sourceRevalidation.stopReading()
        migrationMetrics.finish(at: ProcessInfo.processInfo.systemUptime)
        restoreMigrationIdleTimer()
    }
    private func restoreMigrationIdleTimer() {
        if let previous = migrationIdleTimerWasDisabled {
            UIApplication.shared.isIdleTimerDisabled = previous
            migrationIdleTimerWasDisabled = nil
        }
    }
    func recordMigrationBytes(_ count: Int64) {
        migrationMetrics.recordCommittedBytes(count)
        migrationConfirmedBytes = migrationMetrics.confirmedBytes
        if ProcessInfo.processInfo.systemUptime - migrationLastDiagnosticAt >= 10 {
            recordMigrationOutcome("running")
        }
    }
    /// Aggregate local diagnostics only: no bearer, locator, filename or error
    /// description (system descriptions may contain private source paths).
    func recordMigrationOutcome(_ outcome: String, error: Error? = nil, stopReason: String? = nil) {
        if let error {
            let value = error as NSError
            migrationDiagnosticError = ["errorDomain": value.domain, "errorCode": value.code]
            if let api = error as? RemoteAPIError { migrationDiagnosticError["apiCode"] = api.code.rawValue }
        }
        migrationLastDiagnosticAt = ProcessInfo.processInfo.systemUptime
        var record: [String: Any] = ["outcome": outcome, "phase": migrationPhase, "intent": migrationIntent.rawValue,
            "itemIndex": migrationItemIndex, "itemCount": migrationItemCount, "pendingAssetCount": migrationPendingAssetCount,
            "confirmedBytes": migrationConfirmedBytes, "atMs": Int64(Date().timeIntervalSince1970 * 1_000),
            "elapsedSeconds": migrationMetrics.elapsedSeconds(at: migrationLastDiagnosticAt),
            "activeUploadSeconds": migrationMetrics.activeUploadSeconds(at: migrationLastDiagnosticAt),
            "phaseSeconds": migrationMetrics.phaseSeconds(at: migrationLastDiagnosticAt)]
        if let rate = migrationMetrics.uploadBytesPerSecond(at: migrationLastDiagnosticAt) {
            record["uploadBytesPerSecond"] = rate
        }
        if let stopReason { record["stopReason"] = stopReason }
        record.merge(migrationDiagnosticError) { _, new in new }
        record.merge(migrationRecoveryEvidence) { _, new in new }
        if sourceRevalidation.wasRequired {
            record["sourceRevalidation"] = [
                "reason": LocalShareSourceRevalidationProgress.reasonCode,
                "reading": sourceRevalidation.isReading,
                "readBytes": sourceRevalidation.readBytes,
                "expectedBytes": sourceRevalidation.expectedBytes,
                "verifiedResources": sourceRevalidation.verifiedResources
            ] as [String: Any]
        }
        do {
            let parent = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("ImportDiagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                .write(to: parent.appendingPathComponent("latest.json"), options: .atomic)
        } catch { /* Diagnostics must not interrupt the transfer. */ }
    }
    var usbPairingConflict: ImageAllUSBPairingConflict? {
        guard let offer = usbPendingOffer else { return nil }
        return ImageAllUSBPairingConflict.detect(hasStoredPairing: hasStoredPairing,
            storedHostID: defaults.string(forKey: DefaultsKey.hostID),
            storedFingerprint: defaults.string(forKey: DefaultsKey.fingerprint), offer: offer)
    }
    private func canAutomaticallyResumeUSB(_ offer: RemotePairingOffer) -> Bool {
        ImageAllUSBAutomaticResume.permits(hasStoredPairing: hasStoredPairing,
            storedDeviceID: defaults.string(forKey: DefaultsKey.deviceID),
            storedUsesTLS: defaults.bool(forKey: DefaultsKey.usesTLS),
            storedHostID: defaults.string(forKey: DefaultsKey.hostID),
            storedFingerprint: defaults.string(forKey: DefaultsKey.fingerprint), offer: offer)
    }
    var requiresUSBIdentityConfirmation: Bool {
        guard let offer = usbPendingOffer else { return false }
        return !canAutomaticallyResumeUSB(offer)
    }
    var savedPairingHostID: String { defaults.string(forKey: DefaultsKey.hostID) ?? "未保存" }
    var savedPairingFingerprint: String { defaults.string(forKey: DefaultsKey.fingerprint) ?? "未保存" }
    var usbPairingConflictText: String {
        switch usbPairingConflict {
        case .differentHost: "当前 Mac ID 与旧配对不同。请核对 Mac 设置中的身份后重新配对。"
        case .differentCertificate: "Mac ID 相同，但证书指纹已变化。请核对 Mac 设置中的指纹后重新配对。"
        case .missingSavedIdentity: "旧配对缺少身份信息。请核对 Mac 设置中的身份后重新配对。"
        case nil: ""
        }
    }
    @Published var isBusy = false
    @Published var statusMessage: String?
    @Published var discoveredHosts: [RemoteDiscoveredHost] = []
    @Published var isBrowsing = false
    @Published var capabilities: RemoteCapabilities?
    @Published var sources: [RemoteSourceSummary] = []
    @Published var tags: [RemoteTagSummary] = []
    @Published var tagGroups: [RemoteTagGroupSummary] = []
    @Published var jobs: [RemoteJobSummary] = []
    @Published var reviewOverview: RemoteReviewOverview?
    @Published var reviewItems: [RemoteReviewQueueItem] = []
    @Published var librarySourceID: UUID?
    @Published var reviewSourceID: UUID?
    @Published var libraryActionTagID: UUID?
    @Published var reviewTagID: UUID?
    @Published var librarySearchText = ""
    @Published var librarySort: RemoteAssetSort = .fileNameAscending
    @Published var libraryTagDecisionFilters: [UUID: RemoteAssetTagDecision] = [:]
    @Published var libraryExcludedTagIDs: Set<UUID> = []
    @Published var libraryTagMatchMode: RemoteAssetTagMatchMode = .all
    @Published var libraryAvailabilities: Set<RemoteAssetAvailability> = []
    @Published var libraryMediaKinds: Set<RemoteAssetMediaKind> = [] {
        didSet {
            if !libraryMediaKinds.contains(.video) {
                libraryVideoDuration = .any
                libraryVideoOrientation = .any
                if librarySort.isDurationSort { librarySort = .fileNameAscending }
            }
        }
    }
    @Published var libraryVideoDuration: RemoteVideoDurationFilter = .any {
        didSet { if libraryVideoDuration != .any { libraryMediaKinds = [.video] } }
    }
    @Published var libraryVideoOrientation: RemoteVideoOrientationFilter = .any {
        didSet { if libraryVideoOrientation != .any { libraryMediaKinds = [.video] } }
    }
    var supportsVideoQueries: Bool { capabilities?.videoQueryVersion == 1 }
    @Published var libraryTagPresence: RemoteAssetTagPresence = .any
    @Published var reviewMediaKind: RemoteAssetMediaKind = .image
    @Published var isReviewOverviewPresented = true
    @Published var isLibrarySelectionMode = false
    @Published var tagSelectionAggregates: [UUID: RemoteTagSelectionAggregate] = [:]
    @Published var assets: [RemoteAssetSummary] = []
    @Published var nextCursor: String?
    @Published var reviewNextCursor: String?
    @Published var selectedAssetIDs: Set<UUID> = []
    @Published var selectedReviewAssetIDs: Set<UUID> = []
    @Published var thumbnailDataByAssetID: [UUID: Data] = [:]
    @Published var reviewThumbnailDataByAssetID: [UUID: Data] = [:]
    @Published var previewDetail: RemoteAssetDetail?
    let videoPlayback = RemoteVideoPlayback()
    @Published private(set) var videoPreviewMessage: String?
    @Published var previewData: Data?
    @Published var isLoadingPreview = false
    @Published var jobActionInFlightIDs: Set<UUID> = []
    @Published private(set) var publicBaseURL: String?
    @Published private(set) var hasStoredPairing = false
    @Published private(set) var connectionHealth: RemoteEventConnectionHealth = .stopped
    @Published private(set) var latestUndoID: UUID?
    @Published private(set) var isRefreshingHostStatus = false
    @Published private(set) var lastHostStatusRefreshAt: Date?

    var canSendCommands: Bool {
        connectionHealth == .connected
    }

    private var client: RemoteLibraryClient?
    private var sessionTokens: RemoteSessionTokens?
    private var certificateFingerprint: String?
    private let hostBrowser = RemoteHostBrowser()
    private let eventSocket = RemoteEventSocket()
    private let defaults: UserDefaults
    private let credentialVault: RemoteSessionCredentialVault
    private var storedRefreshToken: String?
    private var previewRequestID: UUID?
    private var activePreviewAssetID: UUID?
    private var activePreviewMediaKind: RemoteAssetMediaKind?
    private var previewImageCacheByAssetID: [UUID: RemotePreviewImageCacheEntry] = [:]
    private var previewImageLRU: [UUID] = []
    private let previewImageCacheLimit = 8
    private var previewCacheGeneration: UInt64 = 0
    private var recoveryMachine = RemoteEventRecoveryStateMachine()
    private var reconnectTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(
        label: "com.gwlee.ImageAllMobile.remote-network-path"
    )
    private var networkPathSignature: String?
    private var networkAvailable = true
    private var networkUsesCellular = false
    private var isForeground = true
    private var assetQueryGeneration: UInt64 = 0
    private var reviewQueryGeneration: UInt64 = 0
    private var selectionAggregateGeneration: UInt64 = 0
    private var thumbnailInFlightIDs: Set<UUID> = []

    var activeLibraryFilterCount: Int {
        libraryTagDecisionFilters.count
            + libraryExcludedTagIDs.count
            + (libraryAvailabilities.isEmpty ? 0 : 1)
            + (libraryMediaKinds.isEmpty ? 0 : 1)
            + (libraryTagPresence == .any ? 0 : 1)
            + (libraryVideoDuration == .any ? 0 : 1)
            + (libraryVideoOrientation == .any ? 0 : 1)
    }

    private enum DefaultsKey {
        static let usbMode = "imageall.mobile.usbMode"
        static let host = "imageall.mobile.host"
        static let port = "imageall.mobile.port"
        static let token = "imageall.mobile.accessToken"
        static let refresh = "imageall.mobile.refreshToken"
        static let deviceID = "imageall.mobile.deviceID"
        static let hostID = "imageall.mobile.hostID"
        static let fingerprint = "imageall.mobile.certFingerprint"
        static let usesTLS = "imageall.mobile.usesTLS"
        static let publicBaseURL = "imageall.mobile.publicBaseURL"
    }

    init(defaults: UserDefaults = .standard, credentialVault: RemoteSessionCredentialVault = RemoteSessionCredentialVault(
            service: "com.gwlee.ImageAllMobile.remote-session",
            account: "paired-refresh-token"
        )) {
        var storedRefreshToken: String?
        var initialStatusMessage: String?
        var shouldPreserveLegacyCredentials = false
        do {
            let result = try credentialVault.loadMigratingLegacy(
                loadLegacy: {
                    defaults.string(forKey: DefaultsKey.refresh)
                },
                removeLegacy: {
                    defaults.removeObject(forKey: DefaultsKey.token)
                    defaults.removeObject(forKey: DefaultsKey.refresh)
                }
            )
            storedRefreshToken = result?.refreshToken
            if result?.source == .migratedLegacy {
                initialStatusMessage = "已将旧配对凭据迁入系统 Keychain"
            }
            if result == nil {
                defaults.removeObject(forKey: DefaultsKey.token)
            }
        } catch {
            shouldPreserveLegacyCredentials = true
            initialStatusMessage = "旧配对凭据未迁移，已保留原值：\(error.localizedDescription)"
        }

        self.defaults = defaults
        self.credentialVault = credentialVault
        self.storedRefreshToken = storedRefreshToken
        host = defaults.string(forKey: DefaultsKey.host) ?? "127.0.0.1"
        port = defaults.string(forKey: DefaultsKey.port) ?? "8787"
        accessToken = shouldPreserveLegacyCredentials
            ? defaults.string(forKey: DefaultsKey.token) ?? ""
            : ""
        certificateFingerprint = defaults.string(forKey: DefaultsKey.fingerprint)
        publicBaseURL = RemotePublicEndpoint.normalizedHTTPSBaseURL(
            defaults.string(forKey: DefaultsKey.publicBaseURL)
        )
        statusMessage = initialStatusMessage
        hasStoredPairing = storedRefreshToken != nil
        startNetworkMonitoring()
        if defaults.object(forKey: DefaultsKey.usbMode) == nil || defaults.bool(forKey: DefaultsKey.usbMode) { enableUSB() }
    }

    deinit {
        pathMonitor.cancel()
        reconnectTask?.cancel()
    }

    func enableUSB() {
        usbManuallyPaused = false
        usbBridge.stop(); usbLoopbackPort = nil; usbOffer = nil; usbPendingOffer = nil
        usbSelected = true; transportGeneration = UUID()
        defaults.set(true, forKey: DefaultsKey.usbMode)
        disconnect(); stopBrowsing()
        usbBridge.onOffer = { [weak self] hello in
            guard let self else { return }
            self.transportGeneration = UUID()
            self.usbPendingOffer = hello.offer
            if let offer = hello.offer, self.canAutomaticallyResumeUSB(offer) {
                self.usbStatus = "正在自动连接已配对的 Mac"
                self.approveUSB()
            } else {
                self.usbStatus = self.usbPairingConflict == nil
                    ? "首次连接此 Mac，请确认身份" : self.usbPairingConflictText
            }
        }
        usbBridge.onReady = { [weak self] port, offer in
            guard let self else { return }
            self.usbLoopbackPort = port; self.usbOffer = offer
            self.usbPendingOffer = nil; self.transportGeneration = UUID()
            let transportID = self.transportGeneration
            self.usbStatus = "USB 通道已连接，正在验证 Mac 配对身份"
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.hasStoredPairing { await self.reconnectStoredSession() }
                else if let data = try? JSONEncoder().encode(offer), let json = String(data: data, encoding: .utf8) {
                    await self.pair(using: json)
                }
                guard self.transportGeneration == transportID, self.usbOffer == offer else { return }
                self.usbStatus = self.isConnected ? "USB 有线已连接 · 数据沿线缆传输" : "USB 通道已建立，但配对未完成：\(self.statusMessage ?? "请重试")"
            }
        }
        usbBridge.onClosed = { [weak self] reason in
            guard let self, self.usbSelected else { return }
            self.usbLoopbackPort = nil; self.usbOffer = nil; self.usbPendingOffer = nil
            self.transportGeneration = UUID(); self.disconnect()
            self.usbStatus = reason
        }
        do { try usbBridge.start(); usbStatus = "插线并打开 Mac ImageAll 后将自动连接" }
        catch { usbStatus = error.localizedDescription }
    }
    func approveUSB() {
        guard let offer = usbPendingOffer else { return }
        guard usbPairingConflict == nil else {
            usbStatus = usbPairingConflictText
            return
        }
        guard offer.expiresAtMs > Int64(Date().timeIntervalSince1970 * 1000) else {
            usbBridge.reject(); usbStatus = "配对请求已过期，请在 Mac 重新发起 USB 连接"; return
        }
        do { try usbBridge.approve() } catch { usbStatus = error.localizedDescription }
    }
    func replaceUSBPairing(confirming consent: ImageAllUSBPairingConsent) {
        // Bind consent to the request that was displayed, before deleting credentials.
        guard usbSelected, consent.isCurrent(pendingOffer: usbPendingOffer, transportID: transportGeneration) else {
            let reason: String
            if !usbSelected { reason = "当前已切换到网络连接" }
            else if usbPendingOffer == nil { reason = "USB 请求已关闭（\(usbStatus)）" }
            else if consent.offer.expiresAtMs <= Int64(Date().timeIntervalSince1970 * 1000) { reason = "配对确认已超时" }
            else { reason = "USB 请求已更换，请核实新的连接请求" }
            usbStatus = "\(reason)。旧配对未清除，请从 Mac 重新连接。"
            return
        }
        guard forgetStoredPairing() else { usbStatus = statusMessage ?? "清除旧配对失败"; return }
        approveUSB()
    }
    func rejectUSB() {
        #if DEBUG
        usbExplicitRejectionCount += 1
        #endif
        usbManuallyPaused = true
        usbBridge.reject()
        usbBridge.stop()
        usbStatus = "USB 自动连接已暂停"
    }
    func useNetworkConnection() {
        usbSelected = false; transportGeneration = UUID()
        defaults.set(false, forKey: DefaultsKey.usbMode)
        usbBridge.stop(); usbLoopbackPort = nil; usbOffer = nil; usbPendingOffer = nil
        usbStatus = "已选择网络连接"; disconnect()
    }

    func startBrowsing() {
        guard !usbSelected else { return }
        guard publicBaseURL == nil else {
            isBrowsing = false
            discoveredHosts = []
            return
        }
        guard !isBrowsing else { return }
        isBrowsing = true
        hostBrowser.start { [weak self] hosts in
            Task { @MainActor in
                self?.applyDiscoveredHosts(hosts)
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
        let generation = beginConnectionAttempt()
        isBusy = true
        defer { isBusy = false }
        do {
            let offer = try RemotePairingPayloadDecoder.decode(payload)
            let publicURL = RemotePublicEndpoint.normalizedHTTPSBaseURL(
                offer.publicBaseURL
            )
            publicBaseURL = publicURL
            let pairingHost: String
            if usbSelected {
                guard usbOffer?.hostID == offer.hostID, usbLoopbackPort != nil else { throw ImageAllUSBError.disconnected }
                pairingHost = offer.hostDisplayName
                host = pairingHost; port = String(offer.listenPort)
            } else if let publicURL,
               let publicHost = URL(string: publicURL)?.host
            {
                pairingHost = publicHost
                host = publicHost
                port = "443"
            } else {
                pairingHost = try RemotePairingHostResolver.resolve(
                    hostID: offer.hostID,
                    displayName: offer.hostDisplayName,
                    currentHost: host,
                    discoveredHosts: discoveredHosts
                )
                host = pairingHost
                port = String(offer.listenPort)
            }
            let deviceKey = SHA256.hash(data: Data(UUID().uuidString.utf8))
                .map { String(format: "%02x", $0) }.joined()
            let bootstrap = try makeClient(
                accessToken: "",
                publicBaseURL: publicURL,
                localHost: pairingHost,
                localPort: offer.listenPort,
                usesTLS: offer.usesTLS,
                certificateFingerprint: offer.certificateFingerprintSHA256,
                sendAuthorization: false
            )
            let tokens = try await bootstrap.completePairing(
                RemotePairingCompleteRequest(
                    pairingToken: offer.pairingToken,
                    deviceName: UIDevice.current.name,
                    devicePublicKeySPKI_SHA256: deviceKey
                )
            )
            try RemoteSessionIdentityValidator.validate(
                tokens,
                expectedHostID: offer.hostID,
                expectedUsesTLS: offer.usesTLS,
                expectedCertificateFingerprintSHA256: offer.certificateFingerprintSHA256,
                expectedPublicBaseURL: publicURL
            )
            guard recoveryMachine.isCurrent(generation) else { throw CancellationError() }
            let storageWarning = applySession(tokens)
            let pairedClient = try makeClient(
                accessToken: tokens.accessToken,
                publicBaseURL: tokens.publicBaseURL,
                localHost: host,
                localPort: tokens.listenPort,
                usesTLS: tokens.usesTLS,
                certificateFingerprint: tokens.certificateFingerprintSHA256
            )
            try await finishConnect(pairedClient, generation: generation)
            pairingOfferJSON = ""
            if let storageWarning {
                statusMessage = "\(statusMessage ?? "已连接")；\(storageWarning)"
            } else {
                statusMessage = "配对成功 · \(statusMessage ?? "已连接")"
            }
        } catch {
            failConnectionAttempt(generation: generation, error: error)
        }
    }

    func loadPairingOfferFromPasteboard() {
        guard let payload = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !payload.isEmpty
        else {
            statusMessage = "剪贴板中没有配对 JSON"
            return
        }
        pairingOfferJSON = payload
        statusMessage = "已从剪贴板读取配对 JSON"
    }

    func rememberEndpointHint() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHost.isEmpty {
            defaults.set(trimmedHost, forKey: DefaultsKey.host)
        }
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPort.isEmpty {
            defaults.set(trimmedPort, forKey: DefaultsKey.port)
        }
    }

    func connect() async {
        if storedRefreshToken != nil {
            await connectWithStoredSession()
            return
        }
        await connectWithManualToken()
    }

    func reconnectStoredSession() async {
        guard hasStoredPairing else {
            statusMessage = "当前没有已保存的配对，请扫描 Mac 上的新二维码"
            return
        }
        statusMessage = publicBaseURL == nil
            ? "正在重新连接已配对 Host…"
            : "正在重新连接公网 Host…"
        await connectWithStoredSession()
    }

    func restoreStoredSessionIfAvailable() async {
        guard storedRefreshToken != nil, !isConnected, !isBusy else { return }
        statusMessage = publicBaseURL == nil
            ? "正在恢复已配对会话…"
            : "正在恢复公网会话…"
        await connectWithStoredSession()
    }

    func disconnect() {
        stopEventRecovery()
        videoPlayback.stop()
        client = nil
        sessionTokens = nil
        accessToken = ""
        isConnected = false
        capabilities = nil
        sources = []
        tags = []
        tagGroups = []
        jobs = []
        reviewOverview = nil
        reviewItems = []
        assets = []
        librarySourceID = nil
        reviewSourceID = nil
        libraryActionTagID = nil
        reviewTagID = nil
        librarySearchText = ""
        librarySort = .fileNameAscending
        resetLibraryFilters()
        reviewMediaKind = .image
        isReviewOverviewPresented = true
        latestUndoID = nil
        isRefreshingHostStatus = false
        lastHostStatusRefreshAt = nil
        nextCursor = nil
        reviewNextCursor = nil
        selectedAssetIDs = []
        selectedReviewAssetIDs = []
        isLibrarySelectionMode = false
        tagSelectionAggregates = [:]
        thumbnailDataByAssetID = [:]
        reviewThumbnailDataByAssetID = [:]
        resetPreview()
        clearPreviewImageCache()
        statusMessage = "已断开"
        startBrowsing()
    }

    @discardableResult
    func forgetStoredPairing() -> Bool {
        do {
            try credentialVault.deleteRefreshToken()
        } catch {
            statusMessage = "无法清除此 iPhone 的配对：\(error.localizedDescription)"
            return false
        }

        stopEventRecovery()
        videoPlayback.stop()
        client = nil
        sessionTokens = nil
        storedRefreshToken = nil
        hasStoredPairing = false
        accessToken = ""
        certificateFingerprint = nil
        publicBaseURL = nil
        isConnected = false
        capabilities = nil
        sources = []
        tags = []
        tagGroups = []
        jobs = []
        reviewOverview = nil
        reviewItems = []
        assets = []
        librarySourceID = nil
        reviewSourceID = nil
        libraryActionTagID = nil
        reviewTagID = nil
        librarySearchText = ""
        librarySort = .fileNameAscending
        resetLibraryFilters()
        reviewMediaKind = .image
        isReviewOverviewPresented = true
        latestUndoID = nil
        isRefreshingHostStatus = false
        lastHostStatusRefreshAt = nil
        nextCursor = nil
        reviewNextCursor = nil
        selectedAssetIDs = []
        selectedReviewAssetIDs = []
        isLibrarySelectionMode = false
        tagSelectionAggregates = [:]
        thumbnailDataByAssetID = [:]
        reviewThumbnailDataByAssetID = [:]
        resetPreview()
        clearPreviewImageCache()

        defaults.removeObject(forKey: DefaultsKey.token)
        defaults.removeObject(forKey: DefaultsKey.refresh)
        defaults.removeObject(forKey: DefaultsKey.deviceID)
        defaults.removeObject(forKey: DefaultsKey.hostID)
        defaults.removeObject(forKey: DefaultsKey.fingerprint)
        defaults.removeObject(forKey: DefaultsKey.usesTLS)
        defaults.removeObject(forKey: DefaultsKey.publicBaseURL)
        statusMessage = usbSelected
            ? "已清除旧配对，请通过 USB 确认 Mac 身份"
            : "已清除此 iPhone 的配对，请扫描 Mac 上的新配对二维码"
        startBrowsing()
        return true
    }

    func setScenePhase(_ phase: ScenePhase) {
        // Temporary loss of focus (including system confirmation UI) is not
        // background execution and must not invalidate a pending USB consent.
        switch phase {
        case .active: setSceneActive(true)
        case .background: setSceneActive(false)
        case .inactive: break
        @unknown default: break
        }
    }

    private func setSceneActive(_ isActive: Bool) {
        guard isForeground != isActive else { return }
        isForeground = isActive
        if !isActive { restoreMigrationIdleTimer() }
        if usbSelected {
            if isActive {
                if !usbManuallyPaused { enableUSB() }
            } else { usbBridge.stop() }
        }
        if isActive {
            resumeEventRecoveryIfNeeded()
        } else {
            suspendEventRecovery()
        }
    }

    func reloadAssets(
        reset: Bool,
        preservingLoadedWindow: Bool = false
    ) async {
        guard let client else { return }
        guard supportsVideoQueries || (!librarySort.requiresVideoQueryCapability
            && libraryVideoDuration == .any && libraryVideoOrientation == .any) else {
            statusMessage = "此 Mac 尚不支持视频条件，请升级 Host 或重置筛选与排序。"
            return
        }
        if reset {
            assetQueryGeneration &+= 1
        }
        let generation = assetQueryGeneration
        let requestedLimit = reset && preservingLoadedWindow
            ? min(200, max(60, assets.count))
            : 60
        let searchText = librarySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true
        defer {
            if generation == assetQueryGeneration {
                isBusy = false
            }
        }
        do {
            let page = try await client.fetchAssets(
                RemoteAssetPageRequest(
                    sourceIDs: librarySourceID.map { [$0] } ?? [],
                    searchText: searchText.isEmpty ? nil : searchText,
                    sort: librarySort,
                    limit: requestedLimit,
                    cursor: reset ? nil : nextCursor,
                    tagDecisionFilters: libraryTagDecisionFilters
                        .sorted { $0.key.uuidString < $1.key.uuidString }
                        .map {
                            RemoteAssetTagDecisionFilter(tagID: $0.key, decision: $0.value)
                        },
                    excludedTagIDs: libraryExcludedTagIDs
                        .sorted { $0.uuidString < $1.uuidString },
                    tagMatchMode: libraryTagMatchMode,
                    availabilities: libraryAvailabilities.sorted { $0.rawValue < $1.rawValue },
                    mediaKinds: libraryMediaKinds.sorted { $0.rawValue < $1.rawValue },
                    videoDuration: supportsVideoQueries ? libraryVideoDuration : nil,
                    videoOrientation: supportsVideoQueries ? libraryVideoOrientation : nil,
                    tagPresence: libraryTagPresence
                )
            )
            guard generation == assetQueryGeneration else { return }
            if reset {
                assets = page.items
                let visibleIDs = Set(page.items.map(\.id))
                selectedAssetIDs.formIntersection(visibleIDs)
            } else {
                let existing = Set(assets.map(\.id))
                assets.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            }
            nextCursor = page.nextCursor
            await prefetchThumbnails(for: page.items)
            if reset, !selectedAssetIDs.isEmpty {
                refreshTagSelectionAggregates()
            }
        } catch {
            guard generation == assetQueryGeneration else { return }
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

    func submitLocalLibrarySnapshot(
        _ snapshot: LocalSharedSnapshot,
        validateScope: @Sendable () async throws -> Void
    ) async throws -> RemoteLocalLibrarySnapshotReceipt {
        guard isConnected, let client, let sessionTokens,
              let capabilities,
              capabilities.capabilities.contains(.localLibrarySnapshot),
              capabilities.hostID == sessionTokens.hostID
        else {
            throw RemoteAPIError(
                code: .unauthorized,
                message: "请先以配对设备连接支持本机图库同步的 Mac"
            )
        }
        let request = Self.localLibraryRequest(snapshot, hostID: sessionTokens.hostID)
        let receipt: RemoteLocalLibrarySnapshotReceipt
        if try JSONEncoder().encode(request).count > 200 * 1_024 || request.selectedAssetIDs.count > 1_024 {
            guard capabilities.localLibrarySnapshotChunkBytes == RemoteLocalLibrarySnapshotChunk.maximumChunkBytes else {
                throw RemoteAPIError(code: .badRequest, message: "请升级 Mac，以分批同步这份较大的目录；手机整理信息仍保留")
            }
            receipt = try await client.submitLocalLibrarySnapshotInChunks(
                request, deviceID: sessionTokens.deviceID, beforeChunk: validateScope
            )
        } else {
            try await validateScope()
            receipt = try await client.submitLocalLibrarySnapshot(request)
        }
        guard receipt.hostID == sessionTokens.hostID,
              receipt.deviceID == sessionTokens.deviceID,
              receipt.sourceEpoch == snapshot.sourceEpoch,
              receipt.snapshotSequence == snapshot.snapshotSequence else {
            throw RemoteAPIError(code: .conflict, message: "Mac 回执身份与本次提交不一致")
        }
        return receipt
    }

    /// A missing receipt means the exact frozen request was not committed.
    /// A 404 means this Host predates the lookup route.
    func lookupLocalLibrarySnapshotReceipt(
        _ snapshot: LocalSharedSnapshot
    ) async throws -> (supported: Bool, receipt: RemoteLocalLibrarySnapshotReceipt?) {
        guard isConnected, let client, let sessionTokens,
              let capabilities,
              capabilities.capabilities.contains(.localLibrarySnapshot),
              capabilities.hostID == sessionTokens.hostID else {
            throw RemoteAPIError(code: .unauthorized, message: "请先连接已配对的 Mac")
        }
        let request = Self.localLibraryRequest(snapshot, hostID: sessionTokens.hostID)
        let lookup = try RemoteLocalLibrarySnapshotReceiptLookup(request: request)
        let result: RemoteLocalLibrarySnapshotReceiptLookupResult
        do {
            result = try await client.lookupLocalLibrarySnapshotReceipt(lookup)
        } catch let error as RemoteAPIError where error.code == .notFound {
            return (false, nil)
        }
        if let receipt = result.receipt {
            guard receipt.hostID == sessionTokens.hostID,
                  receipt.deviceID == sessionTokens.deviceID,
                  receipt.sourceEpoch == snapshot.sourceEpoch,
                  receipt.snapshotSequence == snapshot.snapshotSequence,
                  receipt.importedAssetIDs != nil else {
                throw RemoteAPIError(code: .conflict, message: "Mac 的旧快照回执身份不一致")
            }
        }
        return (true, result.receipt)
    }

    private static func localLibraryRequest(
        _ snapshot: LocalSharedSnapshot, hostID: UUID
    ) -> RemoteLocalLibrarySnapshotRequest {
        RemoteLocalLibrarySnapshotRequest(
            hostID: hostID,
            installID: snapshot.installID,
            sourceEpoch: snapshot.sourceEpoch,
            scopeRevision: snapshot.scopeRevision,
            snapshotSequence: snapshot.snapshotSequence,
            selectedAssetIDs: snapshot.selectedAssetIDs,
            assets: snapshot.assets.map { asset in
                RemoteLocalLibraryAsset(
                    id: asset.id,
                    localIdentifier: asset.localIdentifier,
                    mediaKind: asset.kind == "video" ? .video : .image,
                    createdAtMs: asset.creationDate.map {
                        Int64(($0.timeIntervalSince1970 * 1_000).rounded())
                    },
                    observedFavorite: asset.observedFavorite,
                    favoriteTarget: asset.favoriteTarget,
                    tagDecisions: asset.tagDecisions.map { fact in
                        let decision: RemoteLocalLibraryDecision
                        switch fact.decision {
                        case .accepted: decision = .accepted
                        case .rejected: decision = .rejected
                        case .cleared: decision = .cleared
                        }
                        return .init(
                            tagID: fact.tagID, tagName: fact.tagName, decision: decision
                        )
                    },
                    collections: asset.collections.map {
                        .init(collectionID: $0.collectionID, collectionName: $0.collectionName)
                    }
                )
            }
        )
    }

    private func validateMigrationNetwork() throws {
        if usbSelected {
            guard usbLoopbackPort != nil else { throw ImageAllUSBError.disconnected }
            return
        }
        guard networkPathSignature != nil, networkAvailable else {
            throw RemoteAPIError(code: .conflict, message: "迁移已暂停：等待可用的 Wi-Fi 或有线网络；恢复后可重试原批次。")
        }
        guard !networkUsesCellular else {
            throw RemoteAPIError(code: .conflict, message: "迁移已暂停：不使用蜂窝网络传输归档；连接 Wi-Fi 或有线网络后重试原批次。")
        }
    }

    private func validateMigrationConnection(hostID: UUID, deviceID: UUID) throws {
        try validateMigrationNetwork()
        guard isConnected, client != nil, let sessionTokens, let capabilities,
              capabilities.capabilities.contains(.migrationTransfer),
              capabilities.hostID == hostID, sessionTokens.hostID == hostID,
              sessionTokens.deviceID == deviceID else {
            throw RemoteAPIError(code: .conflict, message: "迁移连接或配对已变化，请重新连接原 Mac 后重试。")
        }
    }

    func requireMigrationAlbumCatalogSupport() throws {
        guard (capabilities?.migrationAlbumCatalogVersion ?? 0) >= 1 else {
            throw RemoteAPIError(code: .conflict, message: "请更新 Mac 后再传输包含用户相册目录的归档。")
        }
    }

    func fetchPhoneCleanupRecheck() async throws -> RemotePhoneCleanupRecheck? {
        guard isConnected, let client, let sessionTokens else {
            throw RemoteAPIError(code: .unauthorized, message: "请先连接原配对 Mac")
        }
        let inbox = try await client.fetchPhoneCleanupRecheck()
        guard isConnected, self.sessionTokens?.hostID == sessionTokens.hostID,
              self.sessionTokens?.deviceID == sessionTokens.deviceID,
              inbox.hostID == sessionTokens.hostID, inbox.deviceID == sessionTokens.deviceID else {
            throw RemoteAPIError(code: .conflict, message: "核对请求的配对身份已变化")
        }
        return inbox.request
    }

    func submitSourceRetirement(_ report: RemotePhoneSourceRetirement) async throws {
        guard isConnected, let client, let sessionTokens,
              sessionTokens.hostID == report.binding.hostID, sessionTokens.deviceID == report.binding.deviceID else {
            throw RemoteAPIError(code: .unauthorized, message: "请连接原配对 Mac 回传记录")
        }
        _ = try await client.submitPhoneSourceRetirement(report)
        guard isConnected, self.sessionTokens?.hostID == sessionTokens.hostID,
              self.sessionTokens?.deviceID == sessionTokens.deviceID else {
            throw RemoteAPIError(code: .conflict, message: "回传期间配对身份已变化")
        }
    }

    func recheckMacCopies(for report: RemotePhoneCleanupSourceReport) async throws -> RemotePhoneCopyAudit {
        guard isConnected, let client, let sessionTokens,
              sessionTokens.hostID == report.request.hostID, sessionTokens.deviceID == report.request.deviceID else {
            throw RemoteAPIError(code: .unauthorized, message: "请连接原配对 Mac")
        }
        let request = RemotePhoneCopyAuditRequest(id: UUID(), sourceReport: report)
        var result = try await client.startPhoneCopyAudit(request)
        while result.state == .running {
            try Task.checkCancellation()
            guard isConnected, self.sessionTokens?.hostID == sessionTokens.hostID,
                  self.sessionTokens?.deviceID == sessionTokens.deviceID else {
                throw RemoteAPIError(code: .conflict, message: "副本核验期间配对身份已变化")
            }
            try await Task.sleep(for: .seconds(1))
            result = try await client.fetchPhoneCopyAudit(request)
        }
        try Task.checkCancellation()
        guard isConnected, self.sessionTokens?.hostID == sessionTokens.hostID,
              self.sessionTokens?.deviceID == sessionTokens.deviceID,
              result.state == .passed else {
            throw RemoteAPIError(code: .conflict, message: "Mac 副本未通过当前复核，请在 Mac 检查归档、备份与共享状态")
        }
        return result
    }

    func submitPhoneCleanupSourceReport(_ report: RemotePhoneCleanupSourceReport) async throws {
        guard isConnected, let client, let sessionTokens,
              sessionTokens.hostID == report.request.hostID, sessionTokens.deviceID == report.request.deviceID else {
            throw RemoteAPIError(code: .unauthorized, message: "请先连接原配对 Mac")
        }
        _ = try await client.submitPhoneCleanupSourceReport(report)
        guard isConnected, self.sessionTokens?.hostID == sessionTokens.hostID,
              self.sessionTokens?.deviceID == sessionTokens.deviceID else {
            throw RemoteAPIError(code: .conflict, message: "来源复查回传期间配对身份已变化")
        }
    }

    func migrationStreamingConnection() throws -> (client: RemoteLibraryClient, hostID: UUID, deviceID: UUID, transportID: UUID) {
        try validateMigrationNetwork()
        guard isConnected, let client, let sessionTokens, let capabilities,
              capabilities.hostID == sessionTokens.hostID,
              capabilities.capabilities.contains(.migrationTransfer),
              capabilities.capabilities.contains(.migrationResourceVerification) else {
            throw RemoteAPIError(code: .unauthorized, message: "请连接支持逐资源校验且已设置接收目录的 Mac")
        }
        return (client, sessionTokens.hostID, sessionTokens.deviceID, transportGeneration)
    }

    // Status remains available after receiver staging/target is retired.
    func importStatusConnection() throws -> (client: RemoteLibraryClient, hostID: UUID, deviceID: UUID, transportID: UUID) {
        try validateMigrationNetwork()
        guard isConnected, let client, let sessionTokens,
              capabilities?.hostID == sessionTokens.hostID else {
            throw RemoteAPIError(code: .unauthorized, message: "请连接原配对 Mac")
        }
        return (client, sessionTokens.hostID, sessionTokens.deviceID, transportGeneration)
    }

    func validateImportStatusConnection(hostID: UUID, deviceID: UUID, transportID: UUID) throws {
        let current = try importStatusConnection()
        guard current.hostID == hostID, current.deviceID == deviceID, current.transportID == transportID else {
            throw RemoteAPIError(code: .conflict, message: "Mac 连接已变化，已丢弃旧状态")
        }
    }

    func validateMigrationStreamingConnection(hostID: UUID, deviceID: UUID, transportID: UUID? = nil) throws {
        let current = try migrationStreamingConnection()
        guard current.hostID == hostID, current.deviceID == deviceID,
              transportID == nil || transportID == current.transportID else {
            throw RemoteAPIError(code: .conflict, message: "迁移期间配对身份已变化，请重新连接原 Mac")
        }
    }

    func migrationAccessToken(rejected: String?, hostID: UUID, deviceID: UUID, transportID: UUID) async throws -> String {
        try validateMigrationStreamingConnection(hostID: hostID, deviceID: deviceID, transportID: transportID)
        guard let tokens = sessionTokens else { throw ImageAllUSBError.disconnected }
        if tokens.accessExpiresAtMs <= Int64(Date().timeIntervalSince1970 * 1_000) + 60_000
            || rejected == tokens.accessToken {
            let refreshed = try await refreshClientForEventRecovery(generation: recoveryMachine.generation)
            try Task.checkCancellation()
            try validateMigrationStreamingConnection(hostID: hostID, deviceID: deviceID, transportID: transportID)
            client = refreshed
        }
        guard let current = sessionTokens else { throw ImageAllUSBError.disconnected }
        return current.accessToken
    }

    func uploadMigrationArchive(
        at archiveRoot: URL
    ) async throws -> ImageAllMigrationTransferSealReceipt {
        guard isConnected, let client, let sessionTokens,
              let capabilities,
              capabilities.capabilities.contains(.migrationTransfer),
              capabilities.hostID == sessionTokens.hostID else {
            throw RemoteAPIError(
                code: .unauthorized,
                message: "请先连接已设置网络归档接收目录的 Mac"
            )
        }
        try validateMigrationConnection(hostID: sessionTokens.hostID, deviceID: sessionTokens.deviceID)
        return try await client.uploadMigrationArchive(at: archiveRoot, pairedDeviceID: sessionTokens.deviceID,
            beforeChunk: { [self] in
                try await validateMigrationConnection(hostID: sessionTokens.hostID, deviceID: sessionTokens.deviceID)
            })
    }

    func submitLocalLibraryTagDecision(
        _ prepared: LocalPreparedSharedTagOperation
    ) async throws -> RemoteLocalLibraryTagDecisionReceipt {
        guard isConnected, let client, let sessionTokens,
              let capabilities,
              capabilities.capabilities.contains(.localLibraryTagOperations),
              capabilities.hostID == sessionTokens.hostID,
              prepared.hostID == sessionTokens.hostID,
              prepared.deviceID == sessionTokens.deviceID else {
            throw RemoteAPIError(
                code: .unauthorized,
                message: "请先连接支持手机标签提交的已配对 Mac"
            )
        }
        let decision: RemoteLocalLibraryDecision = switch prepared.decision {
        case .accepted: .accepted
        case .rejected: .rejected
        case .cleared: .cleared
        }
        let request = RemoteLocalLibraryTagDecisionRequest(
            hostID: prepared.hostID,
            installID: prepared.installID,
            sourceEpoch: prepared.sourceEpoch,
            scopeRevision: prepared.operation.scopeRevision,
            operationID: prepared.operation.id,
            deviceSequence: prepared.operation.sequence,
            assetID: prepared.operation.assetID,
            tagID: prepared.tagID,
            tagName: prepared.tagName,
            decision: decision,
            baseRevision: prepared.baseRevision
        )
        let receipt = try await client.submitLocalLibraryTagDecision(request)
        guard receipt.hostID == sessionTokens.hostID,
              receipt.deviceID == sessionTokens.deviceID,
              receipt.operationID == prepared.operation.id else {
            throw RemoteAPIError(code: .conflict, message: "Mac 标签回执身份不匹配")
        }
        return receipt
    }

    func submitLocalLibraryCollectionMembership(
        _ prepared: LocalPreparedSharedCollectionOperation
    ) async throws -> RemoteLocalLibraryCollectionMembershipReceipt {
        guard isConnected, let client, let sessionTokens,
              let capabilities,
              capabilities.capabilities.contains(.localLibraryCollectionMembership),
              capabilities.hostID == sessionTokens.hostID,
              prepared.hostID == sessionTokens.hostID,
              prepared.deviceID == sessionTokens.deviceID else {
            throw RemoteAPIError(
                code: .unauthorized,
                message: "请先连接支持手机集合提交的已配对 Mac"
            )
        }
        let request = RemoteLocalLibraryCollectionMembershipRequest(
            hostID: prepared.hostID,
            installID: prepared.installID,
            sourceEpoch: prepared.sourceEpoch,
            scopeRevision: prepared.operation.scopeRevision,
            operationID: prepared.operation.id,
            deviceSequence: prepared.operation.sequence,
            assetID: prepared.operation.assetID,
            collectionID: prepared.collectionID,
            collectionName: prepared.collectionName,
            included: prepared.included,
            baseRevision: prepared.baseRevision
        )
        let receipt = try await client.submitLocalLibraryCollectionMembership(request)
        guard receipt.hostID == sessionTokens.hostID,
              receipt.deviceID == sessionTokens.deviceID,
              receipt.operationID == prepared.operation.id else {
            throw RemoteAPIError(code: .conflict, message: "Mac 集合回执身份不匹配")
        }
        return receipt
    }

    func renameLocalLibraryCollection(_ command: LocalCollectionRenameCommand) async throws -> RemoteLocalCollectionRenameReceipt {
        guard isConnected, let client, let sessionTokens, let capabilities,
              capabilities.capabilities.contains(.localLibraryCollectionRename),
              capabilities.hostID == sessionTokens.hostID,
              command.hostID == sessionTokens.hostID, command.deviceID == sessionTokens.deviceID else {
            throw RemoteAPIError(code: .unauthorized, message: "请连接支持集合改名的原配对 Mac 后重试")
        }
        let request = RemoteLocalCollectionRenameRequest(commandID: command.commandID, hostID: command.hostID,
            installID: command.installID, sourceEpoch: command.sourceEpoch, scopeRevision: command.scopeRevision,
            snapshotSequence: command.snapshotSequence, expectedChangeCursor: command.expectedChangeCursor,
            collectionID: command.collectionID, expectedName: command.expectedName, newName: command.newName)
        let receipt = try await client.renameLocalLibraryCollection(request)
        guard receipt.request == request, receipt.deviceID == command.deviceID,
              receipt.resultingChangeCursor > command.expectedChangeCursor else {
            throw RemoteAPIError(code: .conflict, message: "Mac 集合改名回执不匹配")
        }
        return receipt
    }

    func submitLocalLibraryFavoriteTarget(
        _ prepared: LocalPreparedSharedFavoriteOperation
    ) async throws -> RemoteLocalLibraryFavoriteTargetReceipt {
        guard isConnected, let client, let sessionTokens,
              let capabilities,
              capabilities.capabilities.contains(.localLibraryFavoriteTarget),
              capabilities.hostID == sessionTokens.hostID,
              prepared.hostID == sessionTokens.hostID,
              prepared.deviceID == sessionTokens.deviceID else {
            throw RemoteAPIError(
                code: .unauthorized,
                message: "请先连接支持手机收藏目标提交的已配对 Mac"
            )
        }
        let request = RemoteLocalLibraryFavoriteTargetRequest(
            hostID: prepared.hostID,
            installID: prepared.installID,
            sourceEpoch: prepared.sourceEpoch,
            scopeRevision: prepared.operation.scopeRevision,
            operationID: prepared.operation.id,
            deviceSequence: prepared.operation.sequence,
            assetID: prepared.operation.assetID,
            target: prepared.target,
            baseRevision: prepared.baseRevision
        )
        let receipt = try await client.submitLocalLibraryFavoriteTarget(request)
        guard receipt.hostID == sessionTokens.hostID,
              receipt.deviceID == sessionTokens.deviceID,
              receipt.operationID == prepared.operation.id else {
            throw RemoteAPIError(code: .conflict, message: "Mac 收藏目标回执身份不匹配")
        }
        return receipt
    }

    func fetchLocalLibraryTagChanges(
        sourceEpoch: UUID, scopeRevision: Int64, afterCursor: Int64
    ) async throws -> RemoteLocalLibraryTagChangesPage {
        guard isConnected, let client, let sessionTokens,
              let capabilities,
              capabilities.capabilities.contains(.localLibraryTagChanges),
              capabilities.hostID == sessionTokens.hostID else {
            throw RemoteAPIError(code: .unauthorized, message: "请先连接支持共享标签的已配对 Mac")
        }
        let page = try await client.fetchLocalLibraryTagChanges(
            sourceEpoch: sourceEpoch, scopeRevision: scopeRevision,
            afterCursor: afterCursor
        )
        guard page.hostID == sessionTokens.hostID,
              page.deviceID == sessionTokens.deviceID,
              page.sourceEpoch == sourceEpoch,
              page.scopeRevision == scopeRevision,
              page.changes.allSatisfy({ $0.scopeRevision == scopeRevision }) else {
            throw RemoteAPIError(code: .conflict, message: "Mac 标签变化页身份不匹配")
        }
        return page
    }

    func fetchLocalLibraryCollectionChanges(
        sourceEpoch: UUID, scopeRevision: Int64, afterCursor: Int64
    ) async throws -> RemoteLocalLibraryCollectionChangesPage {
        guard isConnected, let client, let sessionTokens,
              let capabilities,
              capabilities.capabilities.contains(.localLibraryCollectionChanges),
              capabilities.hostID == sessionTokens.hostID else {
            throw RemoteAPIError(code: .unauthorized, message: "请先连接支持共享集合的已配对 Mac")
        }
        let page = try await client.fetchLocalLibraryCollectionChanges(
            sourceEpoch: sourceEpoch, scopeRevision: scopeRevision,
            afterCursor: afterCursor
        )
        guard page.hostID == sessionTokens.hostID,
              page.deviceID == sessionTokens.deviceID,
              page.sourceEpoch == sourceEpoch,
              page.scopeRevision == scopeRevision,
              page.changes.allSatisfy({ $0.scopeRevision == scopeRevision }) else {
            throw RemoteAPIError(code: .conflict, message: "Mac 集合变化页身份不匹配")
        }
        return page
    }

    func fetchLocalLibraryFavoriteChanges(
        sourceEpoch: UUID, scopeRevision: Int64, afterCursor: Int64
    ) async throws -> RemoteLocalLibraryFavoriteChangesPage {
        guard isConnected, let client, let sessionTokens,
              let capabilities,
              capabilities.capabilities.contains(.localLibraryFavoriteChanges),
              capabilities.hostID == sessionTokens.hostID else {
            throw RemoteAPIError(code: .unauthorized, message: "请先连接支持共享收藏的已配对 Mac")
        }
        let page = try await client.fetchLocalLibraryFavoriteChanges(
            sourceEpoch: sourceEpoch, scopeRevision: scopeRevision,
            afterCursor: afterCursor
        )
        guard page.hostID == sessionTokens.hostID,
              page.deviceID == sessionTokens.deviceID,
              page.sourceEpoch == sourceEpoch,
              page.scopeRevision == scopeRevision,
              page.changes.allSatisfy({ $0.scopeRevision == scopeRevision }) else {
            throw RemoteAPIError(code: .conflict, message: "Mac 收藏变化页身份不匹配")
        }
        return page
    }

    var supportsLocalLibraryTagChanges: Bool {
        isConnected && capabilities?.capabilities.contains(.localLibraryTagChanges) == true
    }

    var supportsLocalLibraryCollectionMembership: Bool {
        isConnected && capabilities?.capabilities.contains(.localLibraryCollectionMembership) == true
    }

    var supportsLocalLibraryCollectionChanges: Bool {
        isConnected && capabilities?.capabilities.contains(.localLibraryCollectionChanges) == true
    }

    var supportsLocalLibraryFavoriteTarget: Bool {
        isConnected && capabilities?.capabilities.contains(.localLibraryFavoriteTarget) == true
    }

    var supportsLocalLibraryFavoriteChanges: Bool {
        isConnected && capabilities?.capabilities.contains(.localLibraryFavoriteChanges) == true
    }

    func reloadHostStatus() async {
        guard let client, !isRefreshingHostStatus else { return }
        isRefreshingHostStatus = true
        defer { isRefreshingHostStatus = false }
        do {
            async let nextCapabilities = client.fetchCapabilities()
            async let nextSources = client.fetchSources()
            capabilities = try await nextCapabilities
            sources = try await nextSources
            lastHostStatusRefreshAt = Date()
            reconcileRemoteFilters()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func reloadTagLibrary() async {
        guard let client else { return }
        do {
            async let nextTags = client.fetchTags()
            async let nextGroups = client.fetchTagGroups()
            tags = (try await nextTags).filter { $0.state == .active }
            tagGroups = (try await nextGroups).sorted {
                $0.sortOrder < $1.sortOrder
                    || ($0.sortOrder == $1.sortOrder && $0.displayName < $1.displayName)
            }
            reconcileRemoteFilters()
            refreshTagSelectionAggregates()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func reloadReviewOverview() async {
        guard let client,
              capabilities?.capabilities.contains(.reviewQueue) == true
        else {
            reviewOverview = nil
            return
        }
        do {
            reviewOverview = try await client.fetchReviewOverview(
                mediaKind: reviewMediaKind,
                sourceIDs: reviewSourceID.map { [$0] } ?? []
            )
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func showReviewOverview() async {
        isReviewOverviewPresented = true
        selectedReviewAssetIDs = []
        await reloadReviewOverview()
    }

    func prepareReviewQueue(mediaKind: RemoteAssetMediaKind, tagID: UUID) {
        reviewQueryGeneration &+= 1
        reviewMediaKind = mediaKind
        reviewTagID = tagID
        reviewSourceID = nil
        isReviewOverviewPresented = false
        reviewItems = []
        reviewNextCursor = nil
        selectedReviewAssetIDs = []
    }

    func openReviewQueue(tagID: UUID) async {
        reviewTagID = tagID
        isReviewOverviewPresented = false
        selectedReviewAssetIDs = []
        await reloadReviewQueue(reset: true)
    }

    func reloadReviewQueue(reset: Bool) async {
        guard let client,
              capabilities?.capabilities.contains(.reviewQueue) == true,
              let tagID = reviewTagID
        else {
            reviewItems = []
            reviewNextCursor = nil
            selectedReviewAssetIDs = []
            return
        }
        if reset {
            reviewQueryGeneration &+= 1
        }
        let generation = reviewQueryGeneration
        isBusy = true
        defer {
            if generation == reviewQueryGeneration {
                isBusy = false
            }
        }
        do {
            let page = try await client.fetchReviewQueue(
                RemoteReviewQueueRequest(
                    tagID: tagID,
                    sourceIDs: reviewSourceID.map { [$0] } ?? [],
                    mediaKind: reviewMediaKind,
                    limit: 40,
                    cursor: reset ? nil : reviewNextCursor
                )
            )
            guard generation == reviewQueryGeneration else { return }
            if reset {
                reviewItems = page.items
                selectedReviewAssetIDs.formIntersection(Set(page.items.map(\.assetID)))
            } else {
                let existing = Set(reviewItems.map(\.id))
                reviewItems.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            }
            reviewNextCursor = page.nextCursor
            await prefetchReviewThumbnails(for: page.items)
        } catch {
            guard generation == reviewQueryGeneration else { return }
            statusMessage = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(current asset: RemoteAssetSummary) async {
        guard asset.id == assets.last?.id, nextCursor != nil, !isBusy else { return }
        await reloadAssets(reset: false)
    }

    func loadThumbnailIfNeeded(for asset: RemoteAssetSummary) async {
        guard let client,
              thumbnailDataByAssetID[asset.id] == nil,
              !thumbnailInFlightIDs.contains(asset.id)
        else { return }
        thumbnailInFlightIDs.insert(asset.id)
        defer { thumbnailInFlightIDs.remove(asset.id) }
        if let data = try? await client.loadThumbnail(assetID: asset.id, targetPixelWidth: 320) {
            thumbnailDataByAssetID[asset.id] = data
        }
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
        refreshTagSelectionAggregates()
    }

    func beginLibrarySelection() {
        isLibrarySelectionMode = true
    }

    func finishLibrarySelection() {
        isLibrarySelectionMode = false
        selectedAssetIDs = []
        tagSelectionAggregates = [:]
        selectionAggregateGeneration &+= 1
    }

    func selectAllLoadedAssets() {
        selectedAssetIDs = Set(assets.map(\.id))
        refreshTagSelectionAggregates()
    }

    func invertLoadedAssetSelection() {
        let loadedIDs = Set(assets.map(\.id))
        selectedAssetIDs = loadedIDs.subtracting(selectedAssetIDs)
        refreshTagSelectionAggregates()
    }

    func clearLibrarySelection() {
        selectedAssetIDs = []
        tagSelectionAggregates = [:]
        selectionAggregateGeneration &+= 1
    }

    func tagFilterMode(for tagID: UUID) -> RemoteLibraryTagFilterMode {
        if libraryExcludedTagIDs.contains(tagID) { return .excluded }
        switch libraryTagDecisionFilters[tagID] {
        case .accepted: return .accepted
        case .rejected: return .rejected
        case nil: return .none
        }
    }

    func setTagFilterMode(_ mode: RemoteLibraryTagFilterMode, for tagID: UUID) {
        libraryTagDecisionFilters.removeValue(forKey: tagID)
        libraryExcludedTagIDs.remove(tagID)
        switch mode {
        case .none:
            break
        case .accepted:
            libraryTagDecisionFilters[tagID] = .accepted
        case .rejected:
            libraryTagDecisionFilters[tagID] = .rejected
        case .excluded:
            libraryExcludedTagIDs.insert(tagID)
        }
    }

    func toggleAvailabilityFilter(_ availability: RemoteAssetAvailability) {
        if libraryAvailabilities.contains(availability) {
            libraryAvailabilities.remove(availability)
        } else {
            libraryAvailabilities.insert(availability)
        }
    }

    func toggleMediaKindFilter(_ mediaKind: RemoteAssetMediaKind) {
        if libraryMediaKinds.contains(mediaKind) {
            libraryMediaKinds.remove(mediaKind)
        } else {
            libraryMediaKinds.insert(mediaKind)
        }
    }

    func resetLibraryFilters() {
        libraryTagDecisionFilters = [:]
        libraryExcludedTagIDs = []
        libraryTagMatchMode = .all
        libraryAvailabilities = []
        libraryMediaKinds = []
        libraryTagPresence = .any
    }

    func toggleReviewSelection(_ assetID: UUID) {
        if selectedReviewAssetIDs.contains(assetID) {
            selectedReviewAssetIDs.remove(assetID)
        } else {
            selectedReviewAssetIDs.insert(assetID)
        }
    }

    @discardableResult
    func applyTagDecision(_ action: RemoteTagDecisionAction) async -> Bool {
        guard let tagID = libraryActionTagID else {
            statusMessage = "请先选择标签"
            return false
        }
        return await applyTagDecision(
            action,
            tagID: tagID,
            assetIDs: Array(selectedAssetIDs)
        )
    }

    @discardableResult
    func applyTagDecision(
        _ action: RemoteTagDecisionAction,
        assetIDs: [UUID]
    ) async -> Bool {
        guard let tagID = libraryActionTagID else {
            statusMessage = "请先选择标签"
            return false
        }
        return await applyTagDecision(action, tagID: tagID, assetIDs: assetIDs)
    }

    @discardableResult
    func applyTagDecision(
        _ action: RemoteTagDecisionAction,
        tagID: UUID,
        assetIDs: [UUID]
    ) async -> Bool {
        await applyTagDecision(
            action,
            tagID: tagID,
            assetIDs: assetIDs,
            preservesSelection: false
        )
    }

    @discardableResult
    func applyTagDecisionToSelection(
        _ action: RemoteTagDecisionAction,
        tagID: UUID
    ) async -> Bool {
        await applyTagDecision(
            action,
            tagID: tagID,
            assetIDs: Array(selectedAssetIDs),
            preservesSelection: true
        )
    }

    private func applyTagDecision(
        _ action: RemoteTagDecisionAction,
        tagID: UUID,
        assetIDs: [UUID],
        preservesSelection: Bool
    ) async -> Bool {
        guard canSendCommands else {
            statusMessage = "Host 未实时连接，已暂停标签写入；恢复连接后再试。"
            return false
        }
        guard let client else { return false }
        guard !assetIDs.isEmpty else {
            statusMessage = "请先选择资产"
            return false
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
            latestUndoID = response.undoID
            statusMessage = "已应用到 \(response.appliedAssetCount) 项\(response.replayed ? "（重放）" : "")"
            if !preservesSelection {
                selectedAssetIDs.subtract(assetIDs)
            }
            await reloadAssets(reset: true, preservingLoadedWindow: true)
            if selectedAssetIDs.isEmpty {
                refreshTagSelectionAggregates()
            }
            if previewDetail?.assetID == assetIDs.first, assetIDs.count == 1 {
                await loadPreview(assetID: assetIDs[0])
            }
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func createTagAndApply(name: String) async {
        guard canSendCommands else {
            statusMessage = "Host 未实时连接，已暂停标签写入；恢复连接后再试。"
            return
        }
        guard let client else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            statusMessage = "请输入标签名称"
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
            let response = try await client.createTagAndApply(
                RemoteCreateTagAndApplyRequest(
                    operationID: UUID(),
                    name: trimmedName,
                    assetIDs: assetIDs
                )
            )
            latestUndoID = response.undoID
            tags = (try await client.fetchTags()).filter { $0.state == .active }
            libraryActionTagID = response.tagID
            statusMessage = "已创建“\(response.displayName)”并应用到 \(response.appliedAssetCount) 项"
            await reloadAssets(reset: true, preservingLoadedWindow: true)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @discardableResult
    func applyReviewDecision(_ action: RemoteReviewDecisionAction) async -> Bool {
        await applyReviewDecision(action, assetIDs: Array(selectedReviewAssetIDs))
    }

    @discardableResult
    func applyReviewDecision(
        _ action: RemoteReviewDecisionAction,
        assetIDs: [UUID]
    ) async -> Bool {
        guard canSendCommands else {
            statusMessage = "Host 未实时连接，已暂停审核写入；恢复连接后再试。"
            return false
        }
        guard let client,
              capabilities?.capabilities.contains(.reviewDecisions) == true,
              let tagID = reviewTagID
        else {
            statusMessage = "Host 不支持远程审核决定"
            return false
        }
        guard !assetIDs.isEmpty else {
            statusMessage = "请先选择审核项"
            return false
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
            latestUndoID = response.undoID
            statusMessage = "已审核 \(response.appliedAssetCount) 项\(response.replayed ? "（重放）" : "")"
            selectedReviewAssetIDs.subtract(assetIDs)
            await reloadReviewQueue(reset: true)
            await reloadReviewOverview()
            if previewDetail?.assetID == assetIDs.first, assetIDs.count == 1 {
                await loadPreview(assetID: assetIDs[0])
            }
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func undoLatestTagDecision(expectedUndoID: UUID? = nil) async -> Bool {
        guard canSendCommands else {
            statusMessage = "Host 未实时连接，恢复连接后才能撤销。"
            return false
        }
        guard let client, let undoID = latestUndoID else { return false }
        if let expectedUndoID, expectedUndoID != undoID {
            statusMessage = "最近操作已变化，未撤销较早的决定。"
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await client.undoTagDecision(
                RemoteUndoTagDecisionRequest(operationID: UUID(), undoID: undoID)
            )
            latestUndoID = nil
            statusMessage = "已撤销，恢复 \(response.restoredAssetCount) 项"
            await reloadAssets(reset: true, preservingLoadedWindow: true)
            await reloadReviewOverview()
            if !isReviewOverviewPresented {
                await reloadReviewQueue(reset: true)
            }
            if let assetID = previewDetail?.assetID {
                await loadPreview(assetID: assetID)
            }
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    func renameTag(tagID: UUID, name: String) async {
        guard let client, canSendCommands else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "请输入标签名称"
            return
        }
        await performTagLibraryMutation(successMessage: "标签已重命名") {
            _ = try await client.renameTag(
                tagID: tagID,
                request: RemoteRenameTagRequest(operationID: UUID(), name: trimmed)
            )
        }
    }

    func moveTag(tagID: UUID, to groupID: UUID) async {
        guard let client, canSendCommands else { return }
        await performTagLibraryMutation(successMessage: "标签已移动") {
            _ = try await client.moveTag(
                tagID: tagID,
                request: RemoteMoveTagRequest(operationID: UUID(), groupID: groupID)
            )
        }
    }

    func archiveTag(tagID: UUID) async {
        guard let client, canSendCommands else { return }
        await performTagLibraryMutation(successMessage: "标签已归档") {
            _ = try await client.archiveTag(
                tagID: tagID,
                request: RemoteArchiveTagRequest(operationID: UUID())
            )
        }
    }

    func createTagGroup(name: String) async {
        guard let client, canSendCommands else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "请输入分组名称"
            return
        }
        await performTagLibraryMutation(successMessage: "标签分组已创建") {
            _ = try await client.createTagGroup(
                RemoteCreateTagGroupRequest(operationID: UUID(), name: trimmed)
            )
        }
    }

    func renameTagGroup(groupID: UUID, name: String) async {
        guard let client, canSendCommands else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "请输入分组名称"
            return
        }
        await performTagLibraryMutation(successMessage: "标签分组已重命名") {
            _ = try await client.renameTagGroup(
                groupID: groupID,
                request: RemoteRenameTagGroupRequest(operationID: UUID(), name: trimmed)
            )
        }
    }

    func deleteTagGroup(groupID: UUID) async {
        guard let client, canSendCommands else { return }
        await performTagLibraryMutation(successMessage: "标签分组已删除") {
            _ = try await client.deleteTagGroup(
                groupID: groupID,
                request: RemoteDeleteTagGroupRequest(operationID: UUID())
            )
        }
    }

    func applyJobAction(_ action: RemoteJobAction, to jobID: UUID) async {
        guard canSendCommands else {
            statusMessage = "Host 未实时连接，已暂停任务操作；恢复连接后再试。"
            return
        }
        guard !jobActionInFlightIDs.contains(jobID) else { return }
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

    private func trainingClient() throws -> RemoteLibraryClient {
        guard canSendCommands, capabilities?.capabilities.contains(.trainingActivities) == true,
              let client else {
            throw RemoteAPIError(code: .conflict, message: "Mac Host 当前不支持远程训练")
        }
        return client
    }

    func tagLibrarySuggestions(mediaKind: RemoteAssetMediaKind) async throws -> RemoteTagLibrarySuggestionSnapshot {
        try await trainingClient().fetchTagLibrarySuggestions(mediaKind: mediaKind)
    }

    func submitTagLibrarySuggestions(_ request: RemoteTagLibrarySuggestionRequest) async throws -> RemoteTagLibrarySuggestionResponse {
        try await trainingClient().submitTagLibrarySuggestions(request)
    }

    func cancelTagLibrarySuggestions(activity: RemoteTagLibrarySuggestionActivity) async throws {
        _ = try await trainingClient().cancelTagLibrarySuggestions(activity: activity)
    }

    func trainingSetup(mediaKind: RemoteAssetMediaKind) async throws -> RemoteTrainingSetupSnapshot {
        try await trainingClient().fetchTrainingSetup(mediaKind: mediaKind)
    }

    func trainingActivities(mediaKind: RemoteAssetMediaKind) async throws -> [RemoteTrainingActivity] {
        try await trainingClient().fetchTrainingActivities(mediaKind: mediaKind)
    }

    func launchTraining(_ request: RemoteTrainingLaunchRequest) async throws -> RemoteTrainingLaunchResponse {
        try await trainingClient().launchTraining(request)
    }

    func cancelTraining(operationID: UUID, mediaKind: RemoteAssetMediaKind) async throws {
        _ = try await trainingClient().cancelTraining(operationID: operationID, mediaKind: mediaKind)
    }

    func supportsPersonalSampleSuggestions(mediaKind: RemoteAssetMediaKind) async -> Bool {
        guard canSendCommands, let client else { return false }
        return (try? await client.fetchSampleSuggestions(mediaKind: mediaKind).isAvailable) == true
    }

    func generatePersonalSampleSuggestions(assetID: UUID, mediaKind: RemoteAssetMediaKind,
        operationID: UUID, progress: @MainActor (RemoteSampleSuggestionActivity) -> Void
    ) async throws -> RemoteSampleSuggestionActivity {
        try await generatePersonalSampleSuggestions(assetIDs: [assetID], mediaKind: mediaKind,
            operationID: operationID, progress: progress)
    }

    func sampleSuggestionSetup(mediaKind: RemoteAssetMediaKind) async throws -> RemoteSampleSuggestionSnapshot {
        guard canSendCommands, let client else { throw RemoteAPIError(code: .conflict, message: "Mac Host 当前不可用") }
        return try await client.fetchSampleSuggestions(mediaKind: mediaKind)
    }

    func generatePersonalSampleSuggestions(assetIDs: [UUID], mediaKind: RemoteAssetMediaKind,
        operationID: UUID, progress: @MainActor (RemoteSampleSuggestionActivity) -> Void
    ) async throws -> RemoteSampleSuggestionActivity {
        guard canSendCommands, let client else { throw RemoteAPIError(code: .conflict, message: "Mac Host 当前不可用") }
        var activity = try await client.submitSelectedSampleSuggestions(assetIDs: assetIDs,
            mediaKind: mediaKind, operationID: operationID).activity
        progress(activity)
        while activity.phase == .running {
            try await Task.sleep(for: .seconds(1))
            let snapshot = try await client.fetchSampleSuggestions(mediaKind: mediaKind)
            guard let current = snapshot.activities.first(where: { $0.operationID == operationID }) else {
                throw RemoteAPIError(code: .notFound, message: "Mac 任务已不可查询，请在 Mac 检查结果")
            }
            activity = current
            progress(activity)
        }
        return activity
    }

    func cancelPersonalSampleSuggestions(operationID: UUID) async throws {
        guard canSendCommands, let client else { throw RemoteAPIError(code: .conflict, message: "Mac Host 当前不可用") }
        _ = try await client.cancelSampleSuggestions(operationID: operationID)
    }

    func supportsStandardSuggestions(mediaKind: RemoteAssetMediaKind) async -> Bool {
        guard canSendCommands, capabilities?.capabilities.contains(.assetLocalSuggestions) == true,
              let client else { return false }
        return (try? await client.fetchLibrarySuggestions(mediaKind: mediaKind).standardAvailable) == true
    }

    func analyzeStandardSuggestions(assetID: UUID, operationID: UUID) async throws -> RemoteAssetLocalSuggestionResponse {
        guard canSendCommands, capabilities?.capabilities.contains(.assetLocalSuggestions) == true,
              let client else {
            throw RemoteAPIError(code: .conflict, message: "Mac Host 当前不可用")
        }
        return try await client.analyzeAssetLocalSuggestions(assetID: assetID,
            request: RemoteAssetLocalSuggestionRequest(operationID: operationID, track: .standard))
    }

    func loadPreview(assetID: UUID, mediaKindHint: RemoteAssetMediaKind? = nil) async {
        guard let client else { return }
        let retainPlayingVideo = videoPlayback.assetID == assetID && videoPlayback.state == .ready
        if !retainPlayingVideo { videoPlayback.stop() }
        videoPreviewMessage = nil
        let knownKind = mediaKindHint ?? assets.first(where: { $0.id == assetID })?.resolvedMediaKind
            ?? (previewDetail?.assetID == assetID ? previewDetail?.resolvedMediaKind : nil)
            ?? (activePreviewAssetID == assetID ? activePreviewMediaKind : nil)
        let requestID = UUID()
        let cacheGeneration = previewCacheGeneration
        let expectedRevision = assets.first(where: { $0.id == assetID })?.contentRevision
        let cachedData = cachedPreviewData(
            assetID: assetID,
            expectedRevision: expectedRevision
        )
        previewRequestID = requestID
        activePreviewAssetID = assetID
        activePreviewMediaKind = knownKind
        if !retainPlayingVideo { previewDetail = nil }
        previewData = cachedData
        isLoadingPreview = cachedData == nil
        defer {
            if previewRequestID == requestID {
                isLoadingPreview = false
            }
        }
        do {
            let supportsDetail = capabilities?.capabilities.contains(.assetDetail) == true
            let supportsPreview = capabilities?.capabilities.contains(.previews) == true
            async let fetchedDetail = Self.fetchPreviewDetail(
                client: client,
                assetID: assetID,
                supported: supportsDetail
            )
            async let fetchedData = Self.fetchPreviewImage(
                client: client,
                assetID: assetID,
                supportsPreview: supportsPreview,
                shouldFetch: cachedData == nil && knownKind != .video
            )
            let (detail, data) = try await (fetchedDetail, fetchedData)
            guard previewRequestID == requestID else { return }
            previewDetail = detail
            activePreviewMediaKind = detail?.resolvedMediaKind ?? knownKind
            if detail == nil, knownKind == .video {
                videoPlayback.stop()
                videoPreviewMessage = "此 Mac 不提供视频详情，请升级 Mac Host 后重试。"
                return
            }
            if let detail, detail.resolvedMediaKind == .video {
                previewData = nil
                guard capabilities?.videoRangeStreamingVersion == 1 else {
                    videoPlayback.stop()
                    videoPreviewMessage = "此 Mac 尚不支持受控视频播放，请升级 Mac Host 后重试。"
                    return
                }
                guard detail.availability == .available else {
                    videoPlayback.stop()
                    videoPreviewMessage = "视频来源当前不可读取，请在 Mac 检查来源与原件是否可用。"
                    return
                }
                if videoPlayback.assetID == assetID, videoPlayback.contentRevision == detail.contentRevision,
                   videoPlayback.state == .ready { return }
                await videoPlayback.load(assetID: assetID, contentRevision: detail.contentRevision, client: client)
                guard previewRequestID == requestID else { return }
                return
            }
            videoPlayback.stop()
            if let data {
                previewData = data
                if previewCacheGeneration == cacheGeneration {
                    storePreviewData(
                        data,
                        assetID: assetID,
                        contentRevision: detail?.contentRevision ?? expectedRevision
                    )
                }
            }
        } catch {
            guard previewRequestID == requestID else { return }
            videoPlayback.stop()
            videoPreviewMessage = "视频详情暂不可用，请检查 Mac 连接后重试。"
            statusMessage = error.localizedDescription
        }
    }

    func prefetchPreviews(assetIDs: [UUID]) async {
        guard let client else { return }
        let cacheGeneration = previewCacheGeneration
        let supportsPreview = capabilities?.capabilities.contains(.previews) == true
        var seen: Set<UUID> = []
        let candidates = assetIDs.filter { assetID in
            guard seen.insert(assetID).inserted,
                  assets.first(where: { $0.id == assetID })?.resolvedMediaKind == .image else { return false }
            let revision = assets.first(where: { $0.id == assetID })?.contentRevision
            return cachedPreviewData(assetID: assetID, expectedRevision: revision) == nil
        }.prefix(2)
        guard !candidates.isEmpty else { return }

        let revisions = Dictionary(
            uniqueKeysWithValues: candidates.compactMap { assetID in
                assets.first(where: { $0.id == assetID }).map {
                    (assetID, $0.contentRevision)
                }
            }
        )
        await withTaskGroup(of: (UUID, Data?).self) { group in
            for assetID in candidates {
                group.addTask {
                    let data = try? await Self.fetchPreviewImage(
                        client: client,
                        assetID: assetID,
                        supportsPreview: supportsPreview,
                        shouldFetch: true
                    )
                    return (assetID, data)
                }
            }
            for await (assetID, data) in group {
                guard previewCacheGeneration == cacheGeneration, let data else { continue }
                storePreviewData(
                    data,
                    assetID: assetID,
                    contentRevision: revisions[assetID]
                )
            }
        }
    }

    func resetPreview() {
        videoPlayback.stop()
        videoPreviewMessage = nil
        previewRequestID = nil
        activePreviewAssetID = nil
        activePreviewMediaKind = nil
        previewDetail = nil
        previewData = nil
        isLoadingPreview = false
    }

    private func connectWithManualToken(generation suppliedGeneration: UInt64? = nil) async {
        let generation = suppliedGeneration ?? beginConnectionAttempt()
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
            let nextClient = try makeClient(
                accessToken: token,
                publicBaseURL: publicBaseURL,
                localHost: host.trimmingCharacters(in: .whitespacesAndNewlines),
                localPort: portValue,
                usesTLS: usesTLS,
                certificateFingerprint: certificateFingerprint
            )
            try await finishConnect(nextClient, generation: generation)
        } catch {
            failConnectionAttempt(generation: generation, error: error)
        }
    }

    private func connectWithStoredSession(generation suppliedGeneration: UInt64? = nil) async {
        let generation = suppliedGeneration ?? beginConnectionAttempt()
        isBusy = true
        defer { isBusy = false }
        guard let refresh = storedRefreshToken,
              let deviceIDRaw = defaults.string(forKey: DefaultsKey.deviceID),
              let deviceID = UUID(uuidString: deviceIDRaw),
              let fingerprint = defaults.string(forKey: DefaultsKey.fingerprint),
              let portValue = Int(port)
        else {
            await connectWithManualToken(generation: generation)
            return
        }
        do {
            let usesTLS = defaults.bool(forKey: DefaultsKey.usesTLS)
            let expectedPublicURL = RemotePublicEndpoint.normalizedHTTPSBaseURL(
                defaults.string(forKey: DefaultsKey.publicBaseURL)
            )
            let bootstrap = try makeClient(
                accessToken: "",
                publicBaseURL: expectedPublicURL,
                localHost: host,
                localPort: portValue,
                usesTLS: usesTLS,
                certificateFingerprint: fingerprint,
                sendAuthorization: false
            )
            let tokens = try await bootstrap.refreshSession(
                RemoteTokenRefreshRequest(deviceID: deviceID, refreshToken: refresh)
            )
            try RemoteSessionIdentityValidator.validate(
                tokens,
                expectedHostID: defaults
                    .string(forKey: DefaultsKey.hostID)
                    .flatMap(UUID.init(uuidString:)),
                expectedUsesTLS: usesTLS,
                expectedCertificateFingerprintSHA256: fingerprint,
                expectedPublicBaseURL: expectedPublicURL
            )
            guard recoveryMachine.isCurrent(generation) else { throw CancellationError() }
            let storageWarning = applySession(tokens)
            let client = try makeClient(
                accessToken: tokens.accessToken,
                publicBaseURL: tokens.publicBaseURL,
                localHost: host,
                localPort: tokens.listenPort,
                usesTLS: tokens.usesTLS,
                certificateFingerprint: tokens.certificateFingerprintSHA256
            )
            try await finishConnect(client, generation: generation)
            if let storageWarning {
                statusMessage = "\(statusMessage ?? "已连接")；\(storageWarning)"
            }
        } catch {
            failConnectionAttempt(generation: generation, error: error)
        }
    }

    private func connectionStatusMessage(for error: Error) -> String {
        if let apiError = error as? RemoteAPIError {
            switch (apiError.code, apiError.message) {
            case (.badRequest, "noActiveOffer"):
                return """
                Mac 当前没有活动配对二维码。若此 iPhone 已配对，请点“重新连接已配对 Host”；\
                否则请在 Mac 上刷新二维码后再扫码。
                """
            case (.badRequest, "offerExpired"):
                return "配对二维码已过期，请在 Mac 上刷新后重新扫码。"
            case (.badRequest, "invalidToken"):
                return "配对二维码已失效或已使用，请在 Mac 上刷新后重新扫码。"
            case (.unauthorized, "unknownDevice"),
                 (.unauthorized, "invalidRefreshToken"):
                return "此设备的配对授权已失效。请先清除此 iPhone 的配对，再扫描 Mac 上的新二维码。"
            default:
                return apiError.localizedDescription
            }
        }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return error.localizedDescription
        }
        let usesPublicEndpoint = publicBaseURL != nil

        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut:
            if usesPublicEndpoint {
                return "连接公网 Mac Host 超时。请确认 Mac 上 ImageAll Host 与 cloudflared Tunnel 正在运行。"
            }
            return """
            连接 Mac Host 超时。请确认两台设备在同一局域网，并在 Mac 的“网络 > 防火墙 > \
            选项”中关闭“阻止所有传入连接”、允许 ImageAll 传入连接。
            """
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            if usesPublicEndpoint {
                return "无法连接公网 Mac Host。请确认公网域名、ImageAll Host 和 cloudflared Tunnel 状态。"
            }
            return """
            无法连接 Mac Host。请确认 Host 正在运行、地址正确，并在 Mac 防火墙中允许 \
            ImageAll 传入连接。
            """
        case .notConnectedToInternet:
            return usesPublicEndpoint
                ? "iPhone 当前没有可用互联网连接。"
                : "iPhone 当前没有可用网络。请先连接与 Mac 相同的局域网。"
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return "TLS 证书校验失败。请在 Mac 重新开始配对，并扫描最新二维码。"
        default:
            return error.localizedDescription
        }
    }

    private func finishConnect(
        _ nextClient: RemoteLibraryClient,
        generation: UInt64
    ) async throws {
        let caps = try await nextClient.fetchCapabilities()
        let nextSources = try await nextClient.fetchSources()
        let nextTags = try await nextClient.fetchTags()
        let nextTagGroups = (try? await nextClient.fetchTagGroups()) ?? []
        guard recoveryMachine.isCurrent(generation) else {
            throw CancellationError()
        }
        client = nextClient
        capabilities = caps
        sources = nextSources
        lastHostStatusRefreshAt = Date()
        tags = nextTags.filter { $0.state == .active }
        tagGroups = nextTagGroups.sorted {
            $0.sortOrder < $1.sortOrder
                || ($0.sortOrder == $1.sortOrder && $0.displayName < $1.displayName)
        }
        librarySourceID = nil
        reviewSourceID = nil
        libraryActionTagID = tags.first?.id
        reviewTagID = tags.first?.id
        librarySearchText = ""
        librarySort = .fileNameAscending
        resetLibraryFilters()
        reviewMediaKind = .image
        isReviewOverviewPresented = true
        latestUndoID = nil
        isConnected = true
        defaults.set(host, forKey: DefaultsKey.host)
        defaults.set(port, forKey: DefaultsKey.port)
        stopBrowsing()
        await reloadAssets(reset: true)
        guard recoveryMachine.isCurrent(generation) else { return }
        await reloadJobs()
        guard recoveryMachine.isCurrent(generation) else { return }
        await reloadReviewOverview()
        guard recoveryMachine.isCurrent(generation) else { return }
        startEvents(generation: generation)
        let transportText: String
        if publicBaseURL != nil {
            transportText = " · 公网 TLS"
        } else {
            transportText = caps.usesTLS ? " · TLS" : ""
        }
        statusMessage = "HTTP 已连接 \(caps.hostAppVersion)\(transportText)，正在建立实时事件通道…"
    }

    private func applySession(_ tokens: RemoteSessionTokens) -> String? {
        sessionTokens = tokens
        accessToken = tokens.accessToken
        publicBaseURL = RemotePublicEndpoint.normalizedHTTPSBaseURL(
            tokens.publicBaseURL
        )
        if let publicBaseURL,
           let endpointURL = URL(string: publicBaseURL),
           let publicHost = endpointURL.host
        {
            host = publicHost
            port = String(endpointURL.port ?? 443)
        } else {
            port = String(tokens.listenPort)
        }
        certificateFingerprint = tokens.certificateFingerprintSHA256
        var storageWarning: String?
        do {
            try credentialVault.saveRefreshToken(tokens.refreshToken)
            storedRefreshToken = tokens.refreshToken
            hasStoredPairing = true
        } catch {
            storedRefreshToken = tokens.refreshToken
            hasStoredPairing = true
            try? credentialVault.deleteRefreshToken()
            storageWarning = "Keychain 保存失败，当前会话可用，重启后需重新配对：\(error.localizedDescription)"
        }
        defaults.removeObject(forKey: DefaultsKey.token)
        defaults.removeObject(forKey: DefaultsKey.refresh)
        defaults.set(tokens.deviceID.uuidString, forKey: DefaultsKey.deviceID)
        defaults.set(tokens.hostID.uuidString, forKey: DefaultsKey.hostID)
        defaults.set(tokens.certificateFingerprintSHA256, forKey: DefaultsKey.fingerprint)
        defaults.set(tokens.usesTLS, forKey: DefaultsKey.usesTLS)
        defaults.set(port, forKey: DefaultsKey.port)
        if let publicBaseURL {
            defaults.set(publicBaseURL, forKey: DefaultsKey.publicBaseURL)
        } else {
            defaults.removeObject(forKey: DefaultsKey.publicBaseURL)
        }
        return storageWarning
    }

    private func applyDiscoveredHosts(_ hosts: [RemoteDiscoveredHost]) {
        discoveredHosts = hosts
        guard !isConnected,
              storedRefreshToken != nil,
              publicBaseURL == nil,
              let hostIDRaw = defaults.string(forKey: DefaultsKey.hostID),
              let hostID = UUID(uuidString: hostIDRaw),
              let matched = RemoteHostSelection.bestMatch(hostID: hostID, in: hosts)
        else {
            return
        }
        let endpointChanged = host != matched.host || port != String(matched.port)
        host = matched.host
        port = String(matched.port)
        if endpointChanged {
            statusMessage = "已找到已配对的 \(matched.name)"
        }
    }

    private func startEvents(generation: UInt64) {
        eventSocket.stop()
        do {
            let endpoint: RemoteHostEndpoint
            let pinnedFingerprint: String?
            if usbSelected {
                guard let port = usbLoopbackPort else { throw ImageAllUSBError.disconnected }
                endpoint = try RemoteHostEndpoint(host: "127.0.0.1", port: Int(port), accessToken: accessToken, usesTLS: true)
                pinnedFingerprint = certificateFingerprint
            } else if let publicBaseURL {
                endpoint = try RemoteHostEndpoint(
                    publicHTTPSBaseURL: publicBaseURL,
                    accessToken: accessToken
                )
                pinnedFingerprint = nil
            } else {
                guard let portValue = Int(port) else { return }
                endpoint = try RemoteHostEndpoint(
                    host: host,
                    port: portValue,
                    accessToken: accessToken,
                    usesTLS: defaults.bool(forKey: DefaultsKey.usesTLS)
                )
                pinnedFingerprint = certificateFingerprint
            }
            try eventSocket.connect(
                endpoint: endpoint,
                certificateFingerprintSHA256: pinnedFingerprint
            ) { [weak self] event in
                Task { @MainActor in
                    guard self?.recoveryMachine.isCurrent(generation) == true else { return }
                    await self?.handle(event: event)
                }
            } onStateChange: { [weak self] state in
                Task { @MainActor in
                    self?.handleEventSocketState(state, generation: generation)
                }
            }
        } catch {
            guard let retry = recoveryMachine.unexpectedDisconnect(
                generation: generation
            ) else {
                return
            }
            scheduleReconnect(retry)
        }
    }

    private func beginConnectionAttempt() -> UInt64 {
        reconnectTask?.cancel()
        reconnectTask = nil
        eventSocket.stop()
        clearPreviewImageCache()
        let generation = recoveryMachine.beginConnection()
        connectionHealth = recoveryMachine.health
        return generation
    }

    private func failConnectionAttempt(generation: UInt64, error: Error) {
        guard recoveryMachine.isCurrent(generation) else { return }
        stopEventRecovery()
        isConnected = false
        videoPlayback.stop()
        client = nil
        if !(error is CancellationError) {
            statusMessage = connectionStatusMessage(for: error)
        }
    }

    private func stopEventRecovery() {
        reconnectTask?.cancel()
        reconnectTask = nil
        eventSocket.stop()
        recoveryMachine.stop()
        connectionHealth = recoveryMachine.health
    }

    private func suspendEventRecovery() {
        guard isConnected, recoveryMachine.automaticRecoveryEnabled else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        eventSocket.stop()
        recoveryMachine.suspend()
        connectionHealth = recoveryMachine.health
        statusMessage = "事件通道已暂停；当前显示上次同步内容，返回前台后会自动恢复。"
    }

    private func resumeEventRecoveryIfNeeded() {
        guard isConnected,
              isForeground,
              (usbSelected ? usbLoopbackPort != nil : networkAvailable),
              let retry = recoveryMachine.resumeImmediately()
        else {
            return
        }
        eventSocket.stop()
        scheduleReconnect(retry)
    }

    private func handleEventSocketState(
        _ state: RemoteEventSocketState,
        generation: UInt64
    ) {
        switch state {
        case .connected:
            guard recoveryMachine.markConnected(generation: generation) else { return }
            reconnectTask?.cancel()
            reconnectTask = nil
            connectionHealth = recoveryMachine.health
            statusMessage = "实时事件已连接"
            Task { [weak self] in
                await self?.reloadAfterEventRecovery(generation: generation)
            }
        case .disconnected:
            guard let retry = recoveryMachine.unexpectedDisconnect(
                generation: generation
            ) else {
                return
            }
            scheduleReconnect(retry)
        }
    }

    private func scheduleReconnect(_ retry: RemoteEventRetryPlan) {
        guard recoveryMachine.isCurrent(retry.generation),
              recoveryMachine.automaticRecoveryEnabled
        else {
            return
        }
        reconnectTask?.cancel()
        connectionHealth = retry.health
        switch retry.health {
        case let .reconnecting(attempt):
            statusMessage = "事件通道断开，正在第 \(attempt) 次重连；当前内容可能已过期。"
        case .hostOffline:
            statusMessage = "Host 离线；当前显示上次同步内容，App 会继续自动重试。"
        case .connected, .stopped:
            break
        }
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Int(retry.delaySeconds)))
            } catch {
                return
            }
            await self?.performReconnect(retry)
        }
    }

    private func performReconnect(_ retry: RemoteEventRetryPlan) async {
        guard recoveryMachine.isCurrent(retry.generation),
              recoveryMachine.automaticRecoveryEnabled,
              isConnected,
              isForeground,
              (usbSelected ? usbLoopbackPort != nil : networkAvailable),
              let activeClient = client
        else {
            return
        }
        do {
            _ = try await activeClient.fetchCapabilities()
            guard recoveryMachine.isCurrent(retry.generation) else { return }
            reconnectTask = nil
            startEvents(generation: retry.generation)
        } catch {
            if isUnauthorized(error) {
                await recoverExpiredAccessToken(generation: retry.generation)
                return
            }
            guard let next = recoveryMachine.retryFailed(
                generation: retry.generation
            ) else {
                return
            }
            reconnectTask = nil
            scheduleReconnect(next)
        }
    }

    private func recoverExpiredAccessToken(generation: UInt64) async {
        guard recoveryMachine.claimRefreshAttempt(generation: generation) else {
            markCredentialsRejected(generation: generation)
            return
        }
        do {
            let refreshedClient = try await refreshClientForEventRecovery(
                generation: generation
            )
            _ = try await refreshedClient.fetchCapabilities()
            guard recoveryMachine.isCurrent(generation) else { return }
            client = refreshedClient
            reconnectTask = nil
            startEvents(generation: generation)
        } catch {
            guard recoveryMachine.isCurrent(generation) else { return }
            if isUnauthorized(error) {
                markCredentialsRejected(generation: generation)
            } else if let next = recoveryMachine.retryFailed(generation: generation) {
                reconnectTask = nil
                scheduleReconnect(next)
            }
        }
    }

    private func refreshClientForEventRecovery(
        generation: UInt64
    ) async throws -> RemoteLibraryClient {
        if let pending = sessionRefreshWork, pending.generation == generation {
            return try await pending.task.value
        }
        let id = UUID()
        let work = Task { try await self.performSessionRefresh(generation: generation) }
        sessionRefreshWork = (id, generation, work)
        defer { if sessionRefreshWork?.id == id { sessionRefreshWork = nil } }
        return try await work.value
    }

    private func performSessionRefresh(generation: UInt64) async throws -> RemoteLibraryClient {
        guard let refresh = storedRefreshToken,
              let deviceIDRaw = defaults.string(forKey: DefaultsKey.deviceID),
              let deviceID = UUID(uuidString: deviceIDRaw),
              let fingerprint = defaults.string(forKey: DefaultsKey.fingerprint),
              let portValue = Int(port)
        else {
            throw RemoteAPIError(code: .unauthorized, message: "missingRefreshToken")
        }
        let usesTLS = defaults.bool(forKey: DefaultsKey.usesTLS)
        let expectedPublicURL = RemotePublicEndpoint.normalizedHTTPSBaseURL(
            defaults.string(forKey: DefaultsKey.publicBaseURL)
        )
        let bootstrap = try makeClient(
            accessToken: "",
            publicBaseURL: expectedPublicURL,
            localHost: host,
            localPort: portValue,
            usesTLS: usesTLS,
            certificateFingerprint: fingerprint,
            sendAuthorization: false
        )
        let tokens = try await bootstrap.refreshSession(
            RemoteTokenRefreshRequest(deviceID: deviceID, refreshToken: refresh)
        )
        try RemoteSessionIdentityValidator.validate(
            tokens,
            expectedHostID: defaults
                .string(forKey: DefaultsKey.hostID)
                .flatMap(UUID.init(uuidString:)),
            expectedUsesTLS: usesTLS,
            expectedCertificateFingerprintSHA256: fingerprint,
            expectedPublicBaseURL: expectedPublicURL
        )
        guard recoveryMachine.isCurrent(generation) else {
            throw CancellationError()
        }
        let storageWarning = applySession(tokens)
        if let storageWarning {
            statusMessage = storageWarning
        }
        return try makeClient(
            accessToken: tokens.accessToken,
            publicBaseURL: tokens.publicBaseURL,
            localHost: host,
            localPort: tokens.listenPort,
            usesTLS: tokens.usesTLS,
            certificateFingerprint: tokens.certificateFingerprintSHA256
        )
    }

    private func markCredentialsRejected(generation: UInt64) {
        guard recoveryMachine.markCredentialsRejected(generation: generation) else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionHealth = recoveryMachine.health
        statusMessage = "Host 拒绝当前会话，自动 refresh 已停止；请重新连接已配对 Host。"
    }

    private func reloadAfterEventRecovery(generation: UInt64) async {
        guard recoveryMachine.isCurrent(generation) else { return }
        await reloadAssets(reset: true, preservingLoadedWindow: true)
        guard recoveryMachine.isCurrent(generation) else { return }
        await reloadJobs()
        guard recoveryMachine.isCurrent(generation) else { return }
        await reloadReviewQueue(reset: true)
        guard recoveryMachine.isCurrent(generation) else { return }
        await reloadReviewOverview()
    }

    private func isUnauthorized(_ error: Error) -> Bool {
        (error as? RemoteAPIError)?.code == .unauthorized
    }

    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isAvailable = path.status == .satisfied
            let usesCellular = path.usesInterfaceType(.cellular)
            let signature = [
                String(describing: path.status),
                path.usesInterfaceType(.wifi) ? "wifi" : "",
                path.usesInterfaceType(.cellular) ? "cellular" : "",
                path.usesInterfaceType(.wiredEthernet) ? "wired" : "",
            ].joined(separator: ":")
            Task { @MainActor [weak self] in
                self?.applyNetworkPath(
                    signature: signature,
                    isAvailable: isAvailable, usesCellular: usesCellular
                )
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func applyNetworkPath(signature: String, isAvailable: Bool, usesCellular: Bool) {
        let previous = networkPathSignature
        networkPathSignature = signature
        networkAvailable = isAvailable
        networkUsesCellular = usesCellular
        guard !usbSelected else { return }
        guard previous != nil, previous != signature, isConnected else { return }
        if isAvailable {
            resumeEventRecoveryIfNeeded()
        } else {
            suspendEventRecovery()
            statusMessage = "网络不可用；当前显示上次同步内容，网络恢复后会自动重连。"
        }
    }

    private func makeClient(
        accessToken: String,
        publicBaseURL: String?,
        localHost: String,
        localPort: Int,
        usesTLS: Bool,
        certificateFingerprint: String?,
        sendAuthorization: Bool = true
    ) throws -> RemoteLibraryClient {
        if usbSelected {
            guard let port = usbLoopbackPort, let offer = usbOffer,
                  usesTLS, certificateFingerprint?.lowercased() == offer.certificateFingerprintSHA256.lowercased() else {
                throw ImageAllUSBError.disconnected
            }
            return try RemoteLibraryClient.pinned(host: "127.0.0.1", port: Int(port), accessToken: accessToken,
                certificateFingerprintSHA256: offer.certificateFingerprintSHA256,
                sendAuthorization: sendAuthorization)
        }
        if let publicBaseURL {
            return RemoteLibraryClient(
                endpoint: try RemoteHostEndpoint(
                    publicHTTPSBaseURL: publicBaseURL,
                    accessToken: accessToken
                ),
                transport: URLSessionRemoteHTTPTransport(),
                sendAuthorization: sendAuthorization
            )
        }

        let endpoint = try RemoteHostEndpoint(
            host: localHost,
            port: localPort,
            accessToken: accessToken,
            usesTLS: usesTLS
        )
        let transport: any RemoteHTTPTransporting
        if usesTLS, let certificateFingerprint {
            transport = URLSessionRemoteHTTPTransport(
                session: RemotePinnedURLSessionFactory.makeSession(
                    certificateFingerprintSHA256: certificateFingerprint
                )
            )
        } else {
            transport = URLSessionRemoteHTTPTransport()
        }
        return RemoteLibraryClient(
            endpoint: endpoint,
            transport: transport,
            sendAuthorization: sendAuthorization
        )
    }

    private func refreshTagSelectionAggregates() {
        selectionAggregateGeneration &+= 1
        let generation = selectionAggregateGeneration
        let assetIDs = Array(selectedAssetIDs)
        let tagIDs = tags.map(\.id)
        guard capabilities?.capabilities.contains(.tagSelection) == true,
              let client,
              !assetIDs.isEmpty,
              !tagIDs.isEmpty
        else {
            tagSelectionAggregates = [:]
            return
        }
        Task { @MainActor [weak self] in
            do {
                let aggregates = try await client.fetchTagSelection(
                    RemoteTagSelectionRequest(tagIDs: tagIDs, assetIDs: assetIDs)
                )
                guard let self, generation == self.selectionAggregateGeneration else { return }
                self.tagSelectionAggregates = Dictionary(
                    uniqueKeysWithValues: aggregates.map { ($0.tagID, $0) }
                )
            } catch {
                guard let self, generation == self.selectionAggregateGeneration else { return }
                self.statusMessage = error.localizedDescription
            }
        }
    }

    private func handle(event: RemoteEvent) async {
        switch event.kind {
        case .ping:
            break
        case .sourcesChanged:
            let previewAssetID = activePreviewAssetID
            clearPreviewImageCache()
            if let client {
                if let nextSources = try? await client.fetchSources() {
                    sources = nextSources
                    lastHostStatusRefreshAt = Date()
                }
            }
            reconcileRemoteFilters()
            await reloadAssets(reset: true, preservingLoadedWindow: true)
            await reloadReviewQueue(reset: true)
            await reloadReviewOverview()
            if let previewAssetID {
                await loadPreview(assetID: previewAssetID)
            }
        case .assetsChanged:
            let previewAssetID = activePreviewAssetID
            clearPreviewImageCache()
            await reloadAssets(reset: true, preservingLoadedWindow: true)
            await reloadReviewQueue(reset: true)
            await reloadReviewOverview()
            if let previewAssetID {
                await loadPreview(assetID: previewAssetID)
            }
        case .tagsChanged:
            await reloadTagLibrary()
            await reloadAssets(reset: true, preservingLoadedWindow: true)
            await reloadReviewQueue(reset: true)
            await reloadReviewOverview()
        case .jobsChanged:
            await reloadJobs()
        case .reviewChanged:
            await reloadReviewQueue(reset: true)
            await reloadReviewOverview()
        }
    }

    private func performTagLibraryMutation(
        successMessage: String,
        operation: @MainActor () async throws -> Void
    ) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
            statusMessage = successMessage
            await reloadTagLibrary()
            await reloadAssets(reset: true, preservingLoadedWindow: true)
            await reloadReviewOverview()
            if !isReviewOverviewPresented {
                await reloadReviewQueue(reset: true)
            }
            if let assetID = previewDetail?.assetID {
                await loadPreview(assetID: assetID)
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func reconcileRemoteFilters() {
        let validSourceIDs = Set(sources.map(\.id))
        if let librarySourceID, !validSourceIDs.contains(librarySourceID) {
            self.librarySourceID = nil
        }
        if let reviewSourceID, !validSourceIDs.contains(reviewSourceID) {
            self.reviewSourceID = nil
        }

        let validTagIDs = Set(tags.map(\.id))
        libraryTagDecisionFilters = libraryTagDecisionFilters.filter {
            validTagIDs.contains($0.key)
        }
        libraryExcludedTagIDs.formIntersection(validTagIDs)
        if let libraryActionTagID, !validTagIDs.contains(libraryActionTagID) {
            self.libraryActionTagID = tags.first?.id
        }
        if let reviewTagID, !validTagIDs.contains(reviewTagID) {
            self.reviewTagID = tags.first?.id
        }
    }

    private func cachedPreviewData(
        assetID: UUID,
        expectedRevision: Int?
    ) -> Data? {
        guard let entry = previewImageCacheByAssetID[assetID] else { return nil }
        if let expectedRevision, entry.contentRevision != expectedRevision {
            previewImageCacheByAssetID.removeValue(forKey: assetID)
            previewImageLRU.removeAll { $0 == assetID }
            return nil
        }
        previewImageLRU.removeAll { $0 == assetID }
        previewImageLRU.append(assetID)
        return entry.data
    }

    private func storePreviewData(
        _ data: Data,
        assetID: UUID,
        contentRevision: Int?
    ) {
        previewImageCacheByAssetID[assetID] = RemotePreviewImageCacheEntry(
            data: data,
            contentRevision: contentRevision
        )
        previewImageLRU.removeAll { $0 == assetID }
        previewImageLRU.append(assetID)
        while previewImageLRU.count > previewImageCacheLimit {
            let evictedID = previewImageLRU.removeFirst()
            previewImageCacheByAssetID.removeValue(forKey: evictedID)
        }
    }

    private func clearPreviewImageCache() {
        previewCacheGeneration &+= 1
        previewImageCacheByAssetID = [:]
        previewImageLRU = []
    }

    private nonisolated static func fetchPreviewDetail(
        client: RemoteLibraryClient,
        assetID: UUID,
        supported: Bool
    ) async throws -> RemoteAssetDetail? {
        guard supported else { return nil }
        return try await client.fetchAssetDetail(assetID: assetID)
    }

    private nonisolated static func fetchPreviewImage(
        client: RemoteLibraryClient,
        assetID: UUID,
        supportsPreview: Bool,
        shouldFetch: Bool
    ) async throws -> Data? {
        guard shouldFetch else { return nil }
        if supportsPreview {
            return try await client.loadPreview(assetID: assetID, targetPixelWidth: 1_600)
        }
        return try await client.loadThumbnail(assetID: assetID, targetPixelWidth: 1_024)
    }

    private func prefetchThumbnails(for items: [RemoteAssetSummary]) async {
        guard let client else { return }
        await withTaskGroup(of: (UUID, Data?).self) { group in
            for item in items.prefix(24) {
                if thumbnailDataByAssetID[item.id] != nil
                    || thumbnailInFlightIDs.contains(item.id)
                {
                    continue
                }
                thumbnailInFlightIDs.insert(item.id)
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
                thumbnailInFlightIDs.remove(id)
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
