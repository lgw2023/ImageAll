import SwiftUI
import ImageAllRemoteClient
import ImageAllRemoteProtocol

@main
struct ImageAllMobileApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG && USB_IMPORT_ACCEPTANCE
            if ProcessInfo.processInfo.arguments.contains("--cold-resume") {
                USBColdResumeProbeView()
            } else {
                USBImportTaskProbeView()
            }
            #elseif DEBUG
            if ProcessInfo.processInfo.arguments.contains("--share-ui-probe") || ProcessInfo.processInfo.arguments.contains("--photos-ui-probe") {
                LocalShareUIProbeView()
            } else if ProcessInfo.processInfo.arguments.contains("--resource-callback-probe") {
                ResourceCallbackProbeView()
            } else if ProcessInfo.processInfo.arguments.contains("--usb-import-preparation-probe") {
                USBImportPreparationProbeView()
            } else if ProcessInfo.processInfo.arguments.contains("--usb-pairing-ui-probe") {
                USBPairingUIProbeView()
            } else if ProcessInfo.processInfo.arguments.contains("--usb-pairing-lifecycle-probe") {
                USBPairingLifecycleProbeView()
            } else if ProcessInfo.processInfo.arguments.contains("--usb-synthetic-probe") {
                USBDeviceProbeView()
            } else if ProcessInfo.processInfo.arguments.contains("--adr102-local-probe") {
                if let run = DeviceLocalLibraryProbe.arguments {
                    DeviceLocalLibraryProbeView(run: run)
                } else {
                    Text("合成库验收参数无效；未打开资料库。")
                }
            } else {
                ImageAllMobileRootView()
            }
            #else
            ImageAllMobileRootView()
            #endif
        }
    }
}

private struct ImageAllMobileRootView: View {
    @StateObject private var model = RemoteCompanionModel()
    @StateObject private var localModel = LocalLibraryModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            NavigationStack {
                LocalLibraryView(model: localModel, remoteModel: model)
            }
            .tabItem { Label("此 iPhone", systemImage: "iphone.gen3") }

            RemoteCompanionRootView(model: model)
                .tabItem { Label("Mac 图库", systemImage: "desktopcomputer") }
        }
        .onChange(of: scenePhase) { _, phase in
            model.setScenePhase(phase)
            if phase == .background { localModel.pauseActiveImport(reason: .appBackground) }
        }
    }
}

#if DEBUG
private struct ResourceCallbackProbeView: View {
    @State private var status = "验证原件回调线程（合成数据）"
    var body: some View {
        Text(status).task {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "--resource-callback-probe"), index + 1 < args.count,
                  let run = UUID(uuidString: args[index + 1]) else { return }
            do {
                let report = try await runSyntheticPhotoResourceCallbackProbe()
                let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                           appropriateFor: nil, create: true)
                let root = documents.appendingPathComponent("Resource-Callback-Probe/" + run.uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("report.json"), options: .atomic)
                status = report["passed"] as? Bool == true ? "回调线程验证通过；未访问照片。" : "回调验证失败"
            } catch { status = "回调验证失败：\(error.localizedDescription)" }
        }
    }
}

private struct USBImportPreparationProbeView: View {
    @State private var status = "只读核对所选目录与续传缓存"
    var body: some View {
        Text(status).task {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "--usb-import-preparation-probe"), index + 1 < args.count,
                  let run = UUID(uuidString: args[index + 1]) else { return }
            let model = LocalLibraryModel()
            let readOne = args.contains("--verify-pending-local-resource")
            let report = args.contains("--availability-only")
                ? await model.diagnoseSelectedAvailability()
                : await model.diagnoseImportPreparation(verifyOnePendingLocalResource: readOne)
            do {
                let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                           appropriateFor: nil, create: true)
                let root = documents.appendingPathComponent("USB-Preparation-Probe/" + run.uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("report.json"), options: .atomic)
                status = readOne ? "只读原件回调诊断已完成；未向 Mac 上传。" : "只读诊断已完成；未读取原件、未向 Mac 上传。"
            } catch { status = "无法保存诊断结果" }
        }
    }
}
#endif

#if DEBUG
import ImageAllLocalLibrary
import Network
import CryptoKit

/// Exercises the production companion model with isolated synthetic credentials
/// and a loopback control peer. Never constructs LocalLibraryModel or PhotoKit.
@MainActor
private final class USBPairingLifecycleProbe: ObservableObject {
    @Published var status = "正在验证合成配对生命周期（不读取照片）"
    @Published var companion: RemoteCompanionModel?
    func run(interactive: Bool = false) async {
        let args = ProcessInfo.processInfo.arguments
        let flag = interactive ? "--usb-pairing-ui-probe" : "--usb-pairing-lifecycle-probe"
        guard let index = args.firstIndex(of: flag), index + 1 < args.count,
              let id = UUID(uuidString: args[index + 1]) else { status = "缺少合成运行 ID"; return }
        let suite = "imageall.usb-pairing-probe.\(id.uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        #if targetEnvironment(simulator)
        let vault = RemoteSessionCredentialVault.syntheticInMemory()
        #else
        let vault = RemoteSessionCredentialVault(service: suite, account: "synthetic-only")
        #endif
        var model: RemoteCompanionModel?
        var peer: NWConnection?
        defer {
            model?.setScenePhase(.background); peer?.cancel()
            try? vault.deleteRefreshToken(); defaults.removePersistentDomain(forName: suite)
        }
        var checks: [String: Bool] = [:]
        var failure = ""
        do {
            try vault.saveRefreshToken("synthetic-only")
            defaults.set(UUID().uuidString, forKey: "imageall.mobile.hostID")
            defaults.set(String(repeating: "b", count: 64), forKey: "imageall.mobile.certFingerprint")
            let companion = RemoteCompanionModel(defaults: defaults, credentialVault: vault)
            model = companion
            self.companion = companion
            companion.enableUSB()
            let candidate = RemotePairingOffer(hostID: UUID(), hostDisplayName: "Synthetic lifecycle Mac",
                listenPort: 8787, usesTLS: true, certificateFingerprintSHA256: String(repeating: "a", count: 64),
                pairingToken: "synthetic-only", expiresAtMs: Int64(Date().addingTimeInterval(300).timeIntervalSince1970 * 1000))
            let control = NWConnection(host: "127.0.0.1", port: .init(rawValue: ImageAllUSBHello.devicePort)!, using: .tcp)
            peer = control; control.start(queue: .main)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                control.send(content: try? ImageAllUSBHello(role: .control, sessionKey: String(repeating: "1", count: 64), offer: candidate).framed(),
                             completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
            for _ in 0..<100 where companion.usbPendingOffer == nil { try await Task.sleep(for: .milliseconds(20)) }
            guard companion.usbPendingOffer == candidate else { throw ImageAllUSBError.unavailable("pending offer absent") }
            checks["mismatchVisible"] = companion.usbPairingConflict == .differentHost
            if !interactive {
                companion.replaceUSBPairing(confirming: .init(offer: candidate, transportID: UUID()))
                let preservedToken = try vault.loadRefreshToken()
                checks["staleConsentPreservesCredential"] = companion.hasStoredPairing && preservedToken == "synthetic-only"
                let consent = ImageAllUSBPairingConsent(offer: candidate, transportID: companion.transportGeneration)
                companion.setScenePhase(.inactive)
                companion.setScenePhase(.active)
                checks["inactivePreservesPendingConsent"] = consent.isCurrent(pendingOffer: companion.usbPendingOffer, transportID: companion.transportGeneration)
                guard checks["inactivePreservesPendingConsent"] == true else { throw ImageAllUSBError.unavailable("inactive invalidated pending consent") }
                companion.replaceUSBPairing(confirming: consent)
            }
            let ack: Data = try await withCheckedThrowingContinuation { continuation in
                control.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: ImageAllUSBError.disconnected) }
                }
            }
            let clearedToken = try vault.loadRefreshToken()
            checks["explicitReplacementAcknowledged"] = ack == Data([1]) && !companion.hasStoredPairing && clearedToken == nil
            companion.setScenePhase(.background)
            checks["backgroundPausesWithoutNetworkFallback"] = companion.usbSelected && !companion.isConnected && companion.usbPendingOffer == nil && companion.importTransportLabel == "USB 已暂停"
            guard checks.values.allSatisfy({ $0 }) else { throw ImageAllUSBError.unavailable("lifecycle check failed") }
            status = "合成配对生命周期通过"
        } catch { failure = error.localizedDescription; status = failure }
        if interactive { checks["noAccidentalRejection"] = model?.usbExplicitRejectionCount == 0 }
        if let documents = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let root = documents.appendingPathComponent("USB-Pairing-Probe").appendingPathComponent(id.uuidString)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let report: [String: Any] = ["checks": checks, "error": failure, "passed": failure.isEmpty && checks.count == (interactive ? 4 : 5) && checks.values.allSatisfy({ $0 }), "explicitRejectionCount": model?.usbExplicitRejectionCount ?? 0, "photosAccessed": false, "interactive": interactive, "route": "synthetic phone loopback control peer"]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("report.json"), options: .atomic)
            }
        }
    }
}
private struct USBPairingLifecycleProbeView: View {
    @StateObject private var probe = USBPairingLifecycleProbe()
    var body: some View { Text(probe.status).padding().task { await probe.run() } }
}
private struct USBPairingUIProbeView: View {
    @StateObject private var probe = USBPairingLifecycleProbe()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            Form {
                Section("合成验收 · 不读取照片") { Text(probe.status) }
                if let model = probe.companion {
                    Section("导入到 Mac") { USBPhoneConnectionSection(model: model) }
                }
            }.navigationTitle("USB 点击验收")
        }
        .task { await probe.run(interactive: true) }
        .onChange(of: phase) { _, phase in probe.companion?.setScenePhase(phase) }
    }
}

/// Explicit USB acceptance mode, with no production models or Photos access.
@MainActor
private final class USBDeviceProbe: ObservableObject {
    @Published var status = "USB 合成探针等待 Mac（不读取照片）"
    private let bridge = ImageAllUSBPhoneTunnel()
    private var started = false
    private var confirmedBytes = 0
    private var digest: String?
    private var tlsMismatchRejected = false
    private var mainActorBlockedSeconds = 0
    private var requestCount = 0
    private var expectedBytes = 8_388_608
    private var root: URL?
    func start() {
        guard !started else { return }; started = true
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--usb-synthetic-probe"), index + 1 < args.count,
           let runID = UUID(uuidString: args[index + 1]),
           let documents = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            root = documents.appendingPathComponent("USB-Synthetic-Probe").appendingPathComponent(runID.uuidString)
            try? FileManager.default.createDirectory(at: root!, withIntermediateDirectories: true)
        }
        bridge.onOffer = { [weak self] hello in
            guard let self else { return }
            guard hello.offer?.hostDisplayName == "ImageAll USB synthetic acceptance" else { self.bridge.reject(); return }
            do { try self.bridge.approve() } catch { self.status = error.localizedDescription }
        }
        bridge.onReady = { [weak self] port, offer in
            Task { @MainActor [weak self] in await self?.transfer(port: port, fingerprint: offer.certificateFingerprintSHA256) }
        }
        bridge.onClosed = { [weak self] reason in
            self?.status = "USB 已断开 · \(self?.confirmedBytes ?? 0) 合成字节已核验"
            self?.save(closed: true, error: nil)
        }
        do { try bridge.start(); save(closed: false, error: nil) }
        catch { status = error.localizedDescription; save(closed: false, error: status) }
    }
    private func transfer(port: UInt16, fingerprint: String) async {
        let session = RemotePinnedURLSessionFactory.makeSession(certificateFingerprintSHA256: fingerprint)
        defer { session.invalidateAndCancel() }
        do {
            if ProcessInfo.processInfo.arguments.contains("--usb-synthetic-ui-stall") {
                mainActorBlockedSeconds = 10
                blockUIForSyntheticProbe()
            }
            var hash = SHA256()
            let stress = ProcessInfo.processInfo.arguments.contains("--usb-synthetic-stress")
            let socketChurn = ProcessInfo.processInfo.arguments.contains("--usb-synthetic-websocket")
            let iterations = stress ? 8_192 : 128
            let payloadSize = stress ? 1_024 : 65_536
            expectedBytes = iterations * payloadSize
            for index in 0..<iterations {
                if socketChurn {
                    let events = RemoteEventSocket()
                    try events.connect(endpoint: RemoteHostEndpoint(host: "127.0.0.1", port: Int(port), accessToken: "synthetic-only", usesTLS: true),
                                       certificateFingerprintSHA256: fingerprint,
                                       onEvent: { _ in }, onStateChange: { _ in })
                    try await Task.sleep(for: .milliseconds(250))
                    events.stop()
                }
                let bytes = Data((0..<payloadSize).map { UInt8(($0 + index) % 251) })
                var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/synthetic")!)
                request.httpMethod = "POST"; request.httpBody = bytes
                request.allowsCellularAccess = false
                let (received, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ImageAllUSBError.invalidHeader }
                guard received == bytes else { throw ImageAllUSBError.invalidHeader }
                hash.update(data: received); confirmedBytes += bytes.count; requestCount += 1
                status = "USB 合成字节已核验：\(confirmedBytes) / 8388608"
                if socketChurn || (stress && requestCount.isMultiple(of: 100)) { save(closed: false, error: nil) }
            }
            digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            let wrongPin = RemotePinnedURLSessionFactory.makeSession(certificateFingerprintSHA256: String(repeating: "0", count: 64))
            defer { wrongPin.invalidateAndCancel() }
            do {
                _ = try await wrongPin.data(from: URL(string: "https://127.0.0.1:\(port)/synthetic")!)
                throw ImageAllUSBError.unavailable("TLS wrong pin unexpectedly accepted")
            } catch {
                guard !(error is ImageAllUSBError) else { throw error }
                tlsMismatchRejected = true
            }
            status = "USB 8 MiB 双向合成数据核验通过；等待断线验证"
            save(closed: false, error: nil)
        } catch { status = error.localizedDescription; save(closed: false, error: status) }
    }
    private func blockUIForSyntheticProbe() { Thread.sleep(forTimeInterval: 10) }
    private func save(closed: Bool, error: String?) {
        guard let root else { return }
        let report: [String: Any] = ["confirmedBytes": confirmedBytes, "sha256": digest ?? "",
            "passed": confirmedBytes == expectedBytes && digest != nil && tlsMismatchRejected && error == nil,
            "requestCount": requestCount,
            "mainActorBlockedSeconds": mainActorBlockedSeconds,
            "tlsMismatchRejected": tlsMismatchRejected,
            "controlClosed": closed, "error": error ?? "", "photosAccessed": false,
            "route": "phone-loopback -> USBMux -> Mac-loopback"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("report.json"), options: .atomic)
        }
    }
}
private struct USBDeviceProbeView: View {
    @StateObject private var probe = USBDeviceProbe()
    var body: some View {
        VStack(spacing: 16) {
            Text("USB 合成通道验收").font(.title)
            Text(probe.status)
            Text("不读取系统照片、不使用真实图库。正常启动 App 返回日常界面。")
                .font(.footnote).foregroundStyle(.secondary)
        }.padding().task { probe.start() }
    }
}

/// Explicit launch-only device acceptance. This branch never constructs either
/// production model, PhotoKit source, observer or network client.
private enum DeviceLocalLibraryProbe {
    struct Run { let id: UUID; let phase: String }
    struct Expected: Codable {
        let snapshot: LocalSharedSnapshot
        let operationIDs: [UUID]
        let backupSHA256: String
    }
    struct Report: Codable {
        let runID: UUID
        let phase: String
        let passed: Bool
        let checks: [String: Bool]
        let error: String?
        let processID: Int32
    }
    enum Failure: Error { case existingRun, invalidPhase, missingAsset, mismatch }

    static var arguments: Run? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--adr102-local-probe"), i + 2 < args.count,
              let id = UUID(uuidString: args[i + 1]), ["seed", "verify", "retirement-seed", "retirement-close"].contains(args[i + 2]) else { return nil }
        return Run(id: id, phase: args[i + 2])
    }

    static func execute(_ run: Run) async -> String {
        var checks: [String: Bool] = [:]
        var root: URL?
        do {
            let documents = try FileManager.default.url(for: .documentDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = documents.appendingPathComponent("ADR102-Device-Probe", isDirectory: true)
                .appendingPathComponent(run.id.uuidString.lowercased(), isDirectory: true)
            root = directory
            let databaseURL = directory.appendingPathComponent("synthetic.sqlite")
            let expectedURL = directory.appendingPathComponent("expected.json")
            let backupURL = directory.appendingPathComponent("synthetic-backup.sqlite")
            let visible: Set<String> = ["synthetic-shared", "synthetic-private"]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if run.phase == "retirement-seed" {
                guard !FileManager.default.fileExists(atPath: directory.path) else { throw Failure.existingRun }
                let store = try LocalLibraryStore(url: databaseURL)
                try await store.observe([LocalObservedAsset(localIdentifier: "synthetic-shared", kind: "image", creationDate: nil, isFavorite: false)])
                guard let asset = try await store.assets(visibleIdentifiers: visible).first else { throw Failure.missingAsset }
                try await store.setShared(assetID: asset.id, shared: true)
                let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: visible)
                try await store.acknowledgeSharedSnapshot(snapshot, hostID: UUID(), deviceID: UUID(), importedAssetIDs: [asset.id])
                let checkpoint = try await store.migrationCompletionCheckpoint(visibleIdentifiers: visible)
                let plan = LocalSourceRetirementPlan(id: UUID(), migrationID: UUID(), requestID: UUID(), sourceReportID: UUID(),
                    completionReceiptID: UUID(), backupReceiptID: UUID(), manifestSHA256: String(repeating: "a", count: 64),
                    factSnapshotSHA256: String(repeating: "b", count: 64), candidateAssetIDs: [asset.id],
                    snapshot: checkpoint.snapshot, checkpoint: checkpoint.checkpoint)
                _ = try await store.prepareSourceRetirement(plan, visibleIdentifiers: visible)
                try await store.markSourceRetirementSubmitted(id: plan.id, visibleIdentifiers: visible)
                // Deliberately no source adapter: only a synthetic journal entry.
                let record = try await store.sourceRetirementRecords().first
                checks["submitted_without_source_adapter"] = record?.state == .submitted
                checks["same_process_cannot_close"] = record?.canManuallyClose == false
                do {
                    try await store.manuallyCloseUnknownSourceRetirement(id: plan.id)
                    checks["same_process_close_rejected"] = false
                } catch { checks["same_process_close_rejected"] = true }
                try encoder.encode(plan).write(to: expectedURL, options: .atomic)
            } else if run.phase == "retirement-close" {
                let plan = try JSONDecoder().decode(LocalSourceRetirementPlan.self, from: Data(contentsOf: expectedURL))
                let previous = try JSONDecoder().decode(Report.self,
                    from: Data(contentsOf: directory.appendingPathComponent("retirement-seed-report.json")))
                checks["different_application_process"] = previous.passed && previous.processID != ProcessInfo.processInfo.processIdentifier
                guard checks["different_application_process"] == true else { throw Failure.mismatch }
                let store = try LocalLibraryStore(url: databaseURL)
                let pending = try await store.sourceRetirementRecords().first
                checks["restart_preserves_pending_operation"] = pending?.plan == plan && pending?.state == .submitted
                checks["restart_allows_manual_close"] = pending?.canManuallyClose == true
                try await store.manuallyCloseUnknownSourceRetirement(id: plan.id)
                let closed = try await store.sourceRetirementRecords().first
                checks["closure_remains_unknown"] = closed?.state == .closedUnknown && closed?.canManuallyClose == false
                checks["no_retired_replica"] = try await store.retiredSourcePresence(assetID: plan.candidateAssetIDs[0]) == nil
                checks["facts_preserved"] = try await store.sharedSnapshot(visibleIdentifiers: visible).assets == plan.snapshot.assets
                checks["no_shared_delete_operation"] = try await store.pendingSharedOperations().isEmpty
                do {
                    try await store.markSourceRetirementSubmitted(id: plan.id, visibleIdentifiers: visible)
                    checks["old_operation_replay_rejected"] = false
                } catch { checks["old_operation_replay_rejected"] = true }
            } else if run.phase == "seed" {
                guard !FileManager.default.fileExists(atPath: directory.path) else { throw Failure.existingRun }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let store = try LocalLibraryStore(url: databaseURL)
                try await store.observe(visible.sorted().map {
                    LocalObservedAsset(localIdentifier: $0, kind: "image", creationDate: nil, isFavorite: false)
                })
                guard let asset = try await store.assets(visibleIdentifiers: visible)
                    .first(where: { $0.localIdentifier == "synthetic-shared" }) else { throw Failure.missingAsset }
                let tag = try await store.createTag(name: "设备离线标签")
                let collection = try await store.createCollection(name: "设备离线集合")
                try await store.setShared(assetID: asset.id, shared: true)
                try await store.setDecision(assetID: asset.id, tagID: tag, decision: .accepted)
                try await store.setMembership(assetID: asset.id, collectionID: collection, included: true)
                try await store.setFavoriteTarget(assetID: asset.id, isFavorite: true)
                let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: visible)
                let ids = try await store.pendingSharedOperations().map(\.id)
                let backup = try await store.exportBackup(to: backupURL)
                checks["only_explicit_selection_shared"] = snapshot.assets.count == 1 && snapshot.selectedAssetIDs == [asset.id]
                checks["offline_operations_queued"] = ids.count == 3
                checks["backup_verified"] = try LocalLibraryBackup.verify(at: backupURL).sha256 == backup.sha256
                try encoder.encode(Expected(snapshot: snapshot, operationIDs: ids, backupSHA256: backup.sha256))
                    .write(to: expectedURL, options: .atomic)
            } else if run.phase == "verify" {
                let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: expectedURL))
                // No observe/seed call here: all identities and facts must have
                // survived termination of the previous application process.
                let store = try LocalLibraryStore(url: databaseURL)
                checks["identity_and_facts_after_process_restart"] = try await store.sharedSnapshot(visibleIdentifiers: visible) == expected.snapshot
                checks["frozen_delivery_after_process_restart"] = try await store.pendingSharedSnapshot() == expected.snapshot
                checks["operation_ids_after_process_restart"] = try await store.pendingSharedOperations().map(\.id) == expected.operationIDs
                let hidden = try await store.sharedSnapshot(visibleIdentifiers: [])
                checks["hidden_selection_retained"] = hidden.assets.isEmpty && hidden.selectedAssetIDs == expected.snapshot.selectedAssetIDs
                checks["visibility_restore_preserves_facts"] = try await store.sharedSnapshot(visibleIdentifiers: visible) == expected.snapshot
                checks["backup_bytes_unchanged"] = try LocalLibraryBackup.verify(at: backupURL).sha256 == expected.backupSHA256
                let restoredURL = directory.appendingPathComponent("restored-\(UUID().uuidString.lowercased()).sqlite")
                try FileManager.default.copyItem(at: backupURL, to: restoredURL)
                let restored = try LocalLibraryStore(url: restoredURL)
                checks["independent_restore_facts"] = try await restored.sharedSnapshot(visibleIdentifiers: visible) == expected.snapshot
                checks["independent_restore_queue"] = try await restored.pendingSharedOperations().map(\.id) == expected.operationIDs
            } else { throw Failure.invalidPhase }
            guard !checks.isEmpty, checks.values.allSatisfy({ $0 }) else { throw Failure.mismatch }
            try encoder.encode(Report(runID: run.id, phase: run.phase, passed: true,
                checks: checks, error: nil, processID: ProcessInfo.processInfo.processIdentifier))
                .write(to: directory.appendingPathComponent("\(run.phase)-report.json"), options: .atomic)
            return "\(run.phase) 通过：\(checks.count) 项检查。仅合成资料库。"
        } catch {
            if let root {
                let report = Report(runID: run.id, phase: run.phase, passed: false,
                    checks: checks, error: String(describing: error), processID: ProcessInfo.processInfo.processIdentifier)
                // Fixed failure filename: never turn an invalid launch argument into a path.
                try? JSONEncoder().encode(report).write(to: root.appendingPathComponent("failure-report.json"), options: .atomic)
            }
            return "设备验收未通过：\(error)"
        }
    }
}

private struct DeviceLocalLibraryProbeView: View {
    let run: DeviceLocalLibraryProbe.Run
    @State private var status = "正在检查合成本地资料库…"
    @State private var started = false
    var body: some View {
        VStack(spacing: 16) {
            Text("合成库设备验收").font(.title)
            Text(status)
            Text("此模式不连接 Mac，不访问系统照片。结束后正常启动 App 即返回图库。")
                .font(.footnote).foregroundStyle(.secondary)
        }.padding().task {
            guard !started else { return }
            started = true
            status = await DeviceLocalLibraryProbe.execute(run)
        }
    }
}
#endif
