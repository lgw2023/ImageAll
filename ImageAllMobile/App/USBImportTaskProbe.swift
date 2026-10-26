#if DEBUG
import SwiftUI
import UIKit
import CryptoKit
import Darwin
import ImageAllRemoteClient
import ImageAllRemoteProtocol

/// Separate bundle + explicit run identity. Never constructs LocalLibraryModel,
/// requests Photos permission, or opens the normal application's container.
@MainActor
final class USBImportTaskProbe: ObservableObject {
    @Published var remote: RemoteCompanionModel?
    @Published var record = LocalShareTaskRecord()
    @Published var message = "正在准备独立合成任务"
    @Published var uploadedBytes: Int64 = 0
    @Published var phaseEvents: [String] = []
    private var root: URL?
    private var payloadRoot: URL?
    private var cleanupRequests = 0
    private var cleanupNonces: [String] = []
    private var automaticScenario: Bool { ProcessInfo.processInfo.arguments.contains("--automatic-cleanup-probe") }
    private var handoffScenario: Bool { ProcessInfo.processInfo.arguments.contains("--mac-handoff-probe") }
    private var cleanupBusy = false
    private var consumedCleanup = false
    @Published var cleanupMessage = ""
    private var cleanupBytes: Int64?
    private var consumedControl = false
    private var cleanupScenario: Bool { ProcessInfo.processInfo.arguments.contains("--cleanup-probe") }
    private var journal: LocalShareTaskJournal?
    private var header: ImageAllMigrationHeader?
    private var item: ImageAllMigrationItem?
    private var worker: Task<Void, Never>?
    private var expectedHost: UUID?
    private var expectedPin = ""
    private var runID: UUID?
    private var pauses: [String] = []
    private var scenes: [String] = []
    private var resumeOffsets: [Int64] = []
    private var currentOffset: Int64 = 0
    private var statusPolls = 0
    private var peakFootprint: UInt64 = 0
    private var started = false
    private var failed = false
    private let totalBytes: Int64 = 16 * 1_024 * 1_024
    var canTransfer: Bool {
        !failed && worker == nil && remote?.isConnected == true &&
        (record.task.phase == .idle || record.task.phase == .paused)
    }
    var title: String {
        LocalSharePresentation.resolve(task: record.task, selectedCount: 1, canReadPhotos: true,
            needsFullAccess: false, connected: remote?.isConnected == true, awaitingConsent: false,
            otherWork: false, selectionMatches: true, transferPhase: "合成原件").title
    }
    func start() async {
        guard !started else { return }; started = true
        do {
            let args = ProcessInfo.processInfo.arguments
            guard Bundle.main.bundleIdentifier == "com.gwlee.ImageAllMobile.USBAcceptance",
                  let i = args.firstIndex(of: "--usb-import-task-probe"), i + 3 < args.count,
                  let run = UUID(uuidString: args[i + 1]), let host = UUID(uuidString: args[i + 2]),
                  args[i + 3].count == 64 else {
                throw ImageAllUSBError.unavailable("缺少独立身份或运行参数，未打开任何图库")
            }
            runID = run; expectedHost = host; expectedPin = args[i + 3]
            let documents = try FileManager.default.url(for: .documentDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = documents.appendingPathComponent("USB-Import-Acceptance/\(run.uuidString)")
            root = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let lease = LocalShareTaskJournal(directory: directory); journal = lease
            let fixtureURL = directory.appendingPathComponent("fixture.json")
            if FileManager.default.fileExists(atPath: fixtureURL.path) {
                let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
                header = fixture.header; item = fixture.item
                payloadRoot = fixture.payloadDirectory.map { directory.appendingPathComponent($0, isDirectory: true) } ?? directory
                record = try XCTlessUnwrap(lease.load())
            } else {
                let checkpoint = cleanupScenario ? try ImageAllMigrationExportCheckpoint(parent: directory,
                    binding: Data("USB-cleanup-\(run.uuidString)".utf8)) : nil
                defer { checkpoint?.close() }
                let payload = checkpoint?.root ?? directory
                payloadRoot = payload
                let resourceID = UUID()
                let relative = "resources/\(resourceID.uuidString.lowercased()).bin"
                try FileManager.default.createDirectory(at: payload.appendingPathComponent("resources"), withIntermediateDirectories: false)
                let file = payload.appendingPathComponent(relative)
                FileManager.default.createFile(atPath: file.path, contents: nil)
                let handle = try FileHandle(forWritingTo: file)
                var hash = SHA256()
                for n in 0..<16 {
                    let bytes = Data(repeating: UInt8(31 + n), count: 1_024 * 1_024)
                    try handle.write(contentsOf: bytes); hash.update(data: bytes)
                }
                try handle.close()
                let resource = ImageAllMigrationResource(id: resourceID, role: "original", version: 1,
                    uniformTypeIdentifier: "public.data", required: true, status: .present,
                    relativePath: relative, byteCount: totalBytes,
                    sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
                let h = ImageAllMigrationHeader(migrationID: checkpoint?.migrationID ?? UUID(), sourceDeviceID: UUID(),
                    sourceEpoch: UUID(), scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: 1)
                let a = ImageAllMigrationItem(mediaID: UUID(), sourceLocalIdentifier: "synthetic-only",
                    mediaKind: .image, createdAtMs: nil, favoriteTarget: nil, observedFavorite: false,
                    factRevision: 1, tagDecisions: [], collections: [], resources: [resource])
                try ImageAllMigrationArchive.write(header: h, items: [a], to: payload)
                try JSONEncoder().encode(Fixture(header: h, item: a, payloadDirectory: checkpoint?.root.lastPathComponent)).write(to: fixtureURL, options: .atomic)
                header = h; item = a; try lease.save(record)
            }
            let suite = "imageall.usb-import-acceptance.\(run.uuidString)"
            let defaults = try XCTlessUnwrap(UserDefaults(suiteName: suite))
            let model = RemoteCompanionModel(defaults: defaults,
                credentialVault: RemoteSessionCredentialVault(service: suite, account: "synthetic-only"))
            remote = model
            if !model.usbSelected { model.enableUSB() }
            message = "合成文件已准备；等待隔离 Mac Host 的 USB 请求"
            save()
        } catch { fail(error) }
    }
    func tick() async {
        guard !failed, let remote else { return }
        objectWillChange.send()
        if let offer = remote.usbPendingOffer {
            guard offer.hostID == expectedHost,
                  offer.certificateFingerprintSHA256 == expectedPin,
                  offer.hostDisplayName == "ImageAll USB task acceptance" else {
                remote.rejectUSB(); fail(ImageAllUSBError.unavailable("拒绝非本轮合成 Host")); return
            }
            remote.approveUSB()
        }
        if record.task.phase == .running && !remote.isConnected {
            pause(.usbDisconnected)
        }
        if record.task.phase == .received, remote.isConnected, let query = record.statusQuery {
            do {
                let connection = try remote.importStatusConnection()
                let status = try await connection.client.importTaskStatus(query)
                try remote.validateImportStatusConnection(hostID: connection.hostID,
                    deviceID: connection.deviceID, transportID: connection.transportID)
                try record.observe(status)
                statusPolls += 1
                if phaseEvents.last != status.phase.rawValue { phaseEvents.append(status.phase.rawValue) }
                message = status.phase == .browsable ? "合成任务已发布到隔离 Mac 图库" : "Mac 阶段：\(status.phase.rawValue)"
            } catch { message = "等待状态查询恢复：\(error.localizedDescription)" }
        }
        if cleanupScenario, !consumedControl, let root,
           let data = try? Data(contentsOf: root.appendingPathComponent("continue.json")),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           value["runID"] as? String == runID?.uuidString,
           value["processID"] as? Int == Int(getpid()), canTransfer {
            consumedControl = true; transfer()
        }
        if cleanupScenario, !consumedCleanup, record.task.phase == .received, remote.isConnected, let root,
           let data = try? Data(contentsOf: root.appendingPathComponent("cleanup.json")),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           value["runID"] as? String == runID?.uuidString,
           value["processID"] as? Int == Int(getpid()) {
            consumedCleanup = true
            await releasePayload()
        }
        if automaticScenario, scenes.last == "active", !cleanupBusy, !Task.isCancelled {
            var next = record
            let nonce = next.beginAutomaticCleanup(nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                connected: remote.isConnected, ready: record.task.macStatus?.phase == .browsable)
            if next.automaticCleanup != record.automaticCleanup {
                do { try journal?.save(next); record = next } catch { fail(error); return }
            }
            if let nonce { await releasePayload(automaticNonce: nonce) }
        }
        save()
    }
    func releasePayload(automaticNonce: UUID? = nil) async {
        guard !cleanupBusy, let remote, let query = record.statusQuery, let payloadRoot else { return }
        cleanupBusy = true; cleanupMessage = "正在核验 Mac 最终副本…"
        defer { cleanupBusy = false; save() }
        do {
            let connection = try remote.importStatusConnection(), nonce = automaticNonce ?? UUID()
            cleanupRequests += 1; cleanupNonces.append(nonce.uuidString)
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
            try remote.validateImportStatusConnection(hostID: connection.hostID, deviceID: connection.deviceID,
                transportID: connection.transportID)
            let result = try await Task.detached(priority: .utility) {
                try ImageAllMigrationExportCleanup.release(root: payloadRoot, query: query,
                    hostID: connection.hostID, deviceID: connection.deviceID, nonce: nonce, receipt: receipt)
            }.value
            if let automaticNonce {
                record.finishAutomaticCleanup(automaticNonce, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
                try journal?.save(record)
            }
            cleanupBytes = result.logicalBytesReleased
            cleanupMessage = "导出暂存已收尾 · 释放 \(result.logicalBytesReleased / 1_024 / 1_024) MiB"
        } catch {
            if let automaticNonce {
                record.finishAutomaticCleanup(automaticNonce, failure: remote.isConnected ? .failed : .connectionUnavailable,
                    nowMs: Int64(Date().timeIntervalSince1970 * 1000))
                do { try journal?.save(record) } catch { fail(error) }
                cleanupMessage = "自动收尾已延期，已发布图库不受影响：\(error.localizedDescription)"
            } else { cleanupMessage = "收尾失败：\(error.localizedDescription)"; fail(error) }
        }
    }
    func scene(_ phase: ScenePhase) {
        scenes.append(String(describing: phase))
        if phase == .background { pause(.appBackground) }
        remote?.setScenePhase(phase)
        save()
    }
    func pause(_ reason: LocalShareTask.PauseReason) {
        guard record.task.phase == .running else { return }
        record.task.requestPause(reason)
        pauses.append(reason.rawValue)
        worker?.cancel()
        do { try journal?.save(record) } catch { fail(error) }
        message = reason.message
        save()
    }
    func transfer() {
        guard canTransfer, let remote, let root = payloadRoot, let header, let item else { return }
        worker = Task {
            defer { worker = nil; save() }
            do {
                let connection = try remote.migrationStreamingConnection()
                guard connection.hostID == expectedHost else { throw ImageAllUSBError.disconnected }
                try record.begin(selectionIDs: [item.mediaID], includeAlbumCatalog: false,
                    hostID: connection.hostID.uuidString, fingerprint: expectedPin,
                    target: "独立合成 Mac", intent: .transferSelection)
                try record.bind(sourceInstallID: header.sourceDeviceID, sourceEpoch: header.sourceEpoch)
                try record.bind(migrationID: header.migrationID)
                try journal?.save(record)
                _ = try await connection.client.submitLocalLibrarySnapshot(.init(hostID: connection.hostID,
                    installID: header.sourceDeviceID, sourceEpoch: header.sourceEpoch,
                    scopeRevision: 1, snapshotSequence: 1, selectedAssetIDs: [], assets: []))
                let progress = try await connection.client.beginMigrationTransfer(
                    migrationID: header.migrationID, sourceInstallID: header.sourceDeviceID)
                let resource = item.resources[0]
                currentOffset = progress.files.first { $0.relativePath == resource.relativePath }?.committedBytes ?? 0
                resumeOffsets.append(currentOffset)
                message = "正在传输合成原件；起点 \(currentOffset / 1_024 / 1_024) MiB"
                _ = try await connection.client.uploadMigrationFile(at: root.appendingPathComponent(resource.relativePath!),
                    migrationID: header.migrationID, relativePath: resource.relativePath!,
                    byteCount: totalBytes, sha256: resource.sha256!, sourceInstallID: header.sourceDeviceID,
                    beforeChunk: { [weak self] in
                        guard let self else { throw CancellationError() }
                        try await self.beforeChunk(transportID: connection.transportID)
                    }, onCommittedBytes: { [weak self] bytes in
                        await self?.committed(bytes)
                    })
                if handoffScenario {
                    _ = try await connection.client.acceptMigrationResource(migrationID: header.migrationID,
                        deviceID: connection.deviceID, request: .init(
                            relativePath: resource.relativePath!, byteCount: totalBytes, sha256: resource.sha256!))
                }
                let receipt = try await connection.client.finishPreparedMigration(at: root, header: header,
                    items: [item], handoffToMac: handoffScenario)
                try ImageAllMigrationStreamRecord(hostID: connection.hostID, deviceID: connection.deviceID,
                    header: header, items: [item], receipt: receipt).save(in: root)
                if automaticScenario { try record.bindExportRoot(root, migrationID: header.migrationID) }
                try record.receive(receipt); try journal?.save(record)
                message = handoffScenario ? "传输完成 · 可以拔线，Mac 独立继续" : "隔离 Mac 已接收；等待验证和发布"
            } catch {
                if record.task.phase == .pausing || error is CancellationError {
                    record.task.pause()
                } else if !remote.isConnected || error is ImageAllUSBError {
                    record.task.pause(reason: .usbDisconnected)
                    if pauses.last != "usbDisconnected" { pauses.append("usbDisconnected") }
                } else { record.task.phase = .failed }
                message = "本轮停止：\(error.localizedDescription)"
                do { try journal?.save(record) } catch { fail(error) }
            }
        }
    }
    private func beforeChunk(transportID: UUID) async throws {
        try Task.checkCancellation()
        guard let remote, remote.isConnected, remote.transportGeneration == transportID else {
            throw ImageAllUSBError.disconnected
        }
        if cleanupScenario { return }
        // Deterministic observation windows; do not call these throughput timings.
        while (!pauses.contains("usbDisconnected") && currentOffset >= 4 * 1_024 * 1_024) ||
              (!pauses.contains("appBackground") && pauses.contains("usbDisconnected") && currentOffset >= 12 * 1_024 * 1_024) {
            message = pauses.contains("usbDisconnected") ? "已确认 12 MiB：请切到主屏幕，再返回" : "已确认 4 MiB：等待真实 USB 断开"
            save()
            try await Task.sleep(for: .milliseconds(200))
            guard remote.isConnected, remote.transportGeneration == transportID else {
                throw ImageAllUSBError.disconnected
            }
        }
    }
    private func committed(_ bytes: Int64) {
        currentOffset += bytes; uploadedBytes += bytes; save()
    }
    private func fail(_ error: Error) {
        failed = true; message = "验收停止：\(error.localizedDescription)"; worker?.cancel(); save()
    }
    private func save() {
        guard let root else { return }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let code = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if code == KERN_SUCCESS { peakFootprint = max(peakFootprint, info.phys_footprint) }
        if peakFootprint > 512 * 1_024 * 1_024 { failed = true; worker?.cancel(); message = "合成内存保护已触发" }
        let report: [String: Any] = [
            "runID": runID?.uuidString ?? "", "processID": Int(getpid()), "taskID": record.taskID.uuidString,
            "payloadDirectory": payloadRoot?.lastPathComponent ?? "",
            "cleanupBytes": cleanupBytes ?? -1, "cleanupMessage": cleanupMessage,
            "cleanupRequests": cleanupRequests, "cleanupNonces": cleanupNonces,
            "automaticPhase": record.automaticCleanup?.phase.rawValue ?? "legacy",
            "macOwnsProcessing": record.task.macOwnsProcessing == true, "visibleTitle": title,
            "automaticReason": record.automaticCleanup?.reason?.rawValue ?? "",
            "automaticAttempts": record.automaticCleanup?.attempts ?? 0,
            "automaticNextAtMs": record.automaticCleanup?.nextAttemptAtMs ?? 0,
            "migrationID": header?.migrationID.uuidString ?? "", "phase": record.task.phase.rawValue,
            "pauseReasons": pauses, "sceneEvents": scenes, "resumeOffsets": resumeOffsets,
            "resourceUploadBytes": uploadedBytes, "committedOffset": currentOffset,
            "macPhases": phaseEvents, "statusPolls": statusPolls,
            "connected": remote?.isConnected == true, "message": message,
            "usbStatus": remote?.usbStatus ?? "", "connectionStatus": remote?.statusMessage ?? "",
            "peakFootprintBytes": peakFootprint, "failed": failed, "photosAccessed": false,
            "atMs": Int64(Date().timeIntervalSince1970 * 1000)]
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: root.appendingPathComponent("report.json"), options: .atomic)
        }
    }
    private struct Fixture: Codable { let header: ImageAllMigrationHeader; let item: ImageAllMigrationItem; let payloadDirectory: String? }
    private func XCTlessUnwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw ImageAllUSBError.unavailable("合成记录缺失") }; return value
    }
}

struct USBImportTaskProbeView: View {
    @StateObject private var model = USBImportTaskProbe()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("USB 独立任务验收").font(.title.bold())
            Text("16 MiB 合成数据 · 不访问照片").foregroundStyle(.secondary)
            Text(model.title).font(.headline)
            Text(model.message).accessibilityIdentifier("usbAcceptance.status")
            Text("本轮已上传 \(model.uploadedBytes / 1_024 / 1_024) MiB")
            Text(model.phaseEvents.joined(separator: " → ")).font(.footnote)
            Button(model.record.task.phase == .paused ? "继续同一合成任务" : "开始合成任务") {
                model.transfer()
            }.buttonStyle(.borderedProminent).disabled(!model.canTransfer)
                .accessibilityIdentifier("usbAcceptance.resume")
            Button("恢复 USB 等待") { model.remote?.enableUSB() }
                .disabled(model.record.task.phase == .running || model.record.task.phase == .pausing)
            Button("释放导出暂存") { Task { await model.releasePayload() } }
                .disabled(model.record.task.phase != .received || model.remote?.isConnected != true)
            Text(model.record.automaticCleanup?.phase == .complete ? "自动收尾完成 · 记录保留" : model.cleanupMessage).font(.footnote)
            Spacer()
            Text("独立 App、配对、任务和接收目录；仅使用生成的合成数据。")
                .font(.footnote).foregroundStyle(.secondary)
        }.padding(24)
        .task {
            await model.start()
            while !Task.isCancelled {
                await model.tick()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: phase) { _, value in model.scene(value) }
    }
}
#endif

#if DEBUG
/// Full-size cold fixture; intentionally separate from the interactive interruption run.
@MainActor
final class USBColdResumeProbe: ObservableObject {
    struct Scenario: Codable {
        let migrationID: UUID, installID: UUID, sourceEpoch: UUID
        let resources: [ImageAllMigrationResource]
        let prefixBytes: Int64, totalBytes: Int64
        let remainingBytes: Int64?
    }
    @Published var remote: RemoteCompanionModel?
    @Published var record = LocalShareTaskRecord()
    @Published var message = "读取独立冷恢复任务"
    @Published var uploaded: Int64 = 0
    @Published var busy = false
    @Published var revalidationText = ""
    private var root: URL?, scenario: Scenario?, header: ImageAllMigrationHeader?
    private var items: [ImageAllMigrationItem] = []
    private var hostID: UUID?, runID: UUID?
    private var pin = ""
    private var journal: LocalShareTaskJournal?
    private var worker: Task<Void, Never>?
    private var evidence: [String: Any] = [:]
    private var phases: [String] = []
    private var consumedControl = false
    private var peak: UInt64 = 0
    private var failed = false
    var canRun: Bool { !busy && !failed && remote?.isConnected == true && record.task.phase != .running }
    func start() async {
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let args = ProcessInfo.processInfo.arguments
            guard Bundle.main.bundleIdentifier == "com.gwlee.ImageAllMobile.USBAcceptance",
                  let i = args.firstIndex(of: "--usb-import-task-probe"), i + 3 < args.count,
                  let run = UUID(uuidString: args[i+1]), let host = UUID(uuidString: args[i+2]), args[i+3].count == 64
            else { throw ImageAllUSBError.unavailable("独立冷恢复身份缺失") }
            runID = run; hostID = host; pin = args[i+3]
            let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = docs.appendingPathComponent("USB-Cold-Acceptance/\(run.uuidString)")
            root = directory
            let s = try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: directory.appendingPathComponent("scenario.json")))
            guard s.resources.count == 2889, let largeBytes = s.resources.last?.byteCount,
                  [64 * 1024 * 1024, 4 * 1024 * 1024 * 1024].contains(largeBytes),
                  [8 * 1024 * 1024, 32 * 1024 * 1024].contains(s.remainingBytes ?? 8 * 1024 * 1024),
                  s.prefixBytes == largeBytes - (s.remainingBytes ?? 8 * 1024 * 1024) else {
                throw ImageAllUSBError.unavailable("合成范围错误")
            }
            scenario = s
            let h = ImageAllMigrationHeader(migrationID: s.migrationID, sourceDeviceID: s.installID,
                sourceEpoch: s.sourceEpoch, scopeRevision: 1, inventoryWatermark: 1, declaredItemCount: s.resources.count)
            header = h
            items = s.resources.enumerated().map { n, r in
                ImageAllMigrationItem(mediaID: r.id, sourceLocalIdentifier: "synthetic-\(n)", mediaKind: .image,
                    createdAtMs: nil, favoriteTarget: nil, observedFavorite: false, factRevision: 1,
                    tagDecisions: [], collections: [], resources: [r])
            }
            let lease = LocalShareTaskJournal(directory: directory); journal = lease
            if let restored = try lease.load() {
                record = restored
                evidence["restored"] = true
                message = "已恢复同一任务；等待手动继续"
            } else {
                // Device file service can drop large copy operations. Generate
                // the exact non-sparse fixture locally, outside resume timing.
                message = "在独立容器生成 \(largeBytes / 1024 / 1024) MiB 合成资源"
                let file = directory.appendingPathComponent("pending.bin")
                let expected = s.resources.last!.sha256!
                let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
                guard let free = attributes[.systemFreeSize] as? NSNumber,
                      free.int64Value > largeBytes + 256 * 1024 * 1024 else {
                    throw ImageAllUSBError.unavailable("手机剩余空间不足；未生成大文件")
                }
                evidence["freeBytesBeforeGeneration"] = free.int64Value
                evidence["pendingResourceBytes"] = largeBytes
                let digest = try await Task.detached(priority: .utility) { [weak self] in
                    FileManager.default.createFile(atPath: file.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.truncate(atOffset: 0)
                    let prefix = Data(repeating: 37, count: 4 * 1024 * 1024)
                    let suffix = Data(repeating: 73, count: 4 * 1024 * 1024)
                    var hash = SHA256()
                    let chunks = Int(largeBytes / (4 * 1024 * 1024))
                    for n in 0..<chunks {
                        try Task.checkCancellation()
                        let bytes = Int64(n) * 4 * 1024 * 1024 < s.prefixBytes ? prefix : suffix
                        try autoreleasepool { try handle.write(contentsOf: bytes); hash.update(data: bytes) }
                        if n % 32 == 0 { await self?.save() }
                    }
                    try handle.synchronize()
                    return hash.finalize().map { String(format: "%02x", $0) }.joined()
                }.value
                guard digest == expected else { throw LocalShareTaskRecoveryError.invalidRecord }
                evidence["generatedNonSparseSHA256"] = digest
                try ImageAllMigrationArchive.write(header: h, items: items, to: directory)
                try record.begin(selectionIDs: Set(items.map(\.mediaID)), includeAlbumCatalog: false,
                    hostID: host.uuidString, fingerprint: pin, target: "独立合成 Mac", intent: .transferSelection)
                try record.bind(sourceInstallID: s.installID, sourceEpoch: s.sourceEpoch)
                try record.bind(migrationID: s.migrationID)
                try lease.save(record)
                evidence["restored"] = false
                message = "任务已持久保存；请终止并冷启动本验收 App"
            }
            evidence["taskLoadSeconds"] = ProcessInfo.processInfo.systemUptime - start
            evidence["initialPhase"] = record.task.phase.rawValue
            evidence["initialPauseReason"] = record.task.pauseReason?.rawValue ?? ""
            evidence["processID"] = ProcessInfo.processInfo.processIdentifier
            let suite = "imageall.cold-acceptance.\(run.uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { throw LocalShareTaskRecoveryError.unavailable }
            let model = RemoteCompanionModel(defaults: defaults,
                credentialVault: RemoteSessionCredentialVault(service: suite, account: "synthetic-only"))
            remote = model
            // Restored defaults already start the USB listener in model.init.
            // Starting it twice races the first listener's cancellation.
            if !model.usbSelected { model.enableUSB() }
            save()
        } catch { stop(error) }
    }
    func tick() async {
        guard !failed, let remote else { return }
        objectWillChange.send()
        if let offer = remote.usbPendingOffer {
            guard offer.hostID == hostID, offer.certificateFingerprintSHA256 == pin,
                  offer.hostDisplayName == "ImageAll USB task acceptance" else {
                remote.rejectUSB(); stop(ImageAllUSBError.unavailable("非本轮 Host")); return
            }
            remote.approveUSB()
        }
        // Explicit isolated-probe control only; bind a signal to this process so
        // a stale file cannot trigger a later cold-run measurement.
        if ProcessInfo.processInfo.arguments.contains("--controlled-run"),
           !consumedControl, canRun, let root,
           let data = try? Data(contentsOf: root.appendingPathComponent("continue.json")),
           let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           command["runID"] as? String == runID?.uuidString,
           command["processID"] as? Int == Int(ProcessInfo.processInfo.processIdentifier) {
            consumedControl = true
            run()
        }
        if record.task.phase == .received && !busy, let query = record.statusQuery, remote.isConnected {
            do {
                let c = try remote.importStatusConnection()
                let status = try await c.client.importTaskStatus(query)
                try remote.validateImportStatusConnection(hostID: c.hostID, deviceID: c.deviceID, transportID: c.transportID)
                try record.observe(status)
                if phases.last != status.phase.rawValue { phases.append(status.phase.rawValue) }
                message = status.phase == .browsable ? "2,889 项已发布，可浏览" : "Mac 阶段：\(status.phase.rawValue)"
            } catch { message = "等待只读状态刷新：\(error.localizedDescription)" }
        }
        save()
    }
    func run() {
        guard canRun, let remote, let root, let scenario, let header else { return }
        busy = true
        worker = Task {
            defer { busy = false; worker = nil; save() }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let c = try remote.migrationStreamingConnection()
                let repeatRun = record.task.phase == .received
                evidence["repeatRun"] = repeatRun
                if !repeatRun {
                    try record.begin(selectionIDs: Set(items.map(\.mediaID)), includeAlbumCatalog: false,
                        hostID: c.hostID.uuidString, fingerprint: pin, target: "独立合成 Mac", intent: .transferSelection)
                    try journal?.save(record)
                }
                evidence["timingTaskSavedSeconds"] = ProcessInfo.processInfo.systemUptime - started
                _ = try await c.client.submitLocalLibrarySnapshot(.init(hostID: c.hostID, installID: header.sourceDeviceID,
                    sourceEpoch: header.sourceEpoch, scopeRevision: 1, snapshotSequence: 1, selectedAssetIDs: [], assets: []))
                evidence["timingSnapshotSeconds"] = ProcessInfo.processInfo.systemUptime - started
                message = "恢复 Mac 接收进度"; save()
                let p = try await c.client.beginMigrationTransfer(migrationID: header.migrationID, sourceInstallID: header.sourceDeviceID)
                evidence["timingBeginSeconds"] = ProcessInfo.processInfo.systemUptime - started
                let receipts = try await c.client.migrationResumeCheckpoint(migrationID: header.migrationID,
                    deviceID: c.deviceID, sourceInstallID: header.sourceDeviceID)
                evidence["timingReceiptsSeconds"] = ProcessInfo.processInfo.systemUptime - started
                let pending = scenario.resources.last!, path = pending.relativePath!
                let offset = p.files.first { $0.relativePath == path }?.committedBytes
                // A second interruption can occur after any acknowledged suffix
                // block or after its verification but before the sealed response.
                let pendingReceipt = receipts[path]?.resource
                guard let offset, let size = pending.byteCount,
                      offset >= scenario.prefixBytes, offset <= size,
                      receipts.count == (pendingReceipt == nil ? 2888 : 2889),
                      pendingReceipt == nil || (pendingReceipt?.sha256 == pending.sha256 && pendingReceipt?.byteCount == size),
                      !repeatRun || (offset == size && pendingReceipt != nil),
                      scenario.resources.dropLast().allSatisfy({ r in
                          receipts[r.relativePath!]?.resource.sha256 == r.sha256 && receipts[r.relativePath!]?.resource.byteCount == r.byteCount
                      }) else { throw ImageAllUSBError.unavailable("断点或已验证资源不匹配") }
                evidence["recoveryMetric"] = "receive-progress-integrity-pending-v1"
                evidence["firstEffectiveProgressSeconds"] = ProcessInfo.processInfo.systemUptime - started
                evidence["resumeOffset"] = offset
                evidence["skippedResources"] = receipts.count
                message = "接收进度已恢复（\(receipts.count) 项），完整性待核验；从 \(offset / 1024 / 1024) MiB 继续"; save()
                if !repeatRun {
                    evidence["uploadStartedSeconds"] = ProcessInfo.processInfo.systemUptime - started
                    _ = try await c.client.uploadMigrationFile(at: root.appendingPathComponent("pending.bin"),
                        migrationID: header.migrationID, relativePath: path, byteCount: pending.byteCount!, sha256: pending.sha256!,
                        sourceInstallID: header.sourceDeviceID, onCommittedBytes: { [weak self] bytes in
                            await self?.committed(bytes, started: started)
                        })
                    evidence["uploadFinishedSeconds"] = ProcessInfo.processInfo.systemUptime - started
                    _ = try await c.client.verifyMigrationResource(migrationID: header.migrationID, deviceID: c.deviceID,
                        request: .init(relativePath: path, byteCount: pending.byteCount!, sha256: pending.sha256!))
                } else {
                    guard receipts[path]?.resource.sha256 == pending.sha256 else { throw LocalShareTaskRecoveryError.bindingChanged }
                }
                let receipt = try await c.client.finishPreparedMigration(at: root, header: header, items: items)
                try record.receive(receipt); try journal?.save(record)
                evidence["totalResumeSeconds"] = ProcessInfo.processInfo.systemUptime - started
                evidence["sealedItems"] = receipt.itemCount
                evidence["sealedResources"] = receipt.resourceCount
                evidence["verifiedBytes"] = receipt.verifiedBytes
                message = "封存完成，等待 Mac 验证与发布"
            } catch { stop(error) }
        }
    }
    private func committed(_ bytes: Int64, started: TimeInterval) {
        if uploaded == 0 { evidence["firstNewACKSeconds"] = ProcessInfo.processInfo.systemUptime - started }
        uploaded += bytes
        var acks = evidence["chunkACKs"] as? [[String: Any]] ?? []
        acks.append(["bytes": uploaded, "seconds": ProcessInfo.processInfo.systemUptime - started])
        evidence["chunkACKs"] = acks
        save()
    }
    func verifyProgressUI() {
        guard !busy, let remote else { return }
        busy = true
        worker = Task {
            defer { remote.finishMigrationProgress(); busy = false; worker = nil; save() }
            remote.beginMigrationProgress()
            remote.beginSourceRevalidation(expectedBytes: 1_048_576)
            do {
                var samples: [Int64] = []
                let result = try await runSyntheticPhotoResourceCallbackProbe { [weak self] bytes in
                    samples.append(bytes)
                    remote.recordSourceRevalidationRead(bytes)
                    self?.revalidationText = remote.migrationProgressText
                }
                guard result["passed"] as? Bool == true else { throw LocalShareTaskRecoveryError.invalidRecord }
                remote.finishSourceRevalidation()
                revalidationText = remote.migrationProgressText
                evidence["revalidationSamples"] = samples
                evidence["revalidationPassed"] = true
                evidence["revalidationText"] = revalidationText
            } catch { stop(error) }
        }
    }
    func scene(_ phase: ScenePhase) {
        if phase == .background && busy {
            record.task.requestPause(.appBackground); worker?.cancel()
            try? journal?.save(record)
        }
        remote?.setScenePhase(phase); save()
    }
    private func stop(_ error: Error) {
        failed = true; worker?.cancel(); message = "验收停止：\(error.localizedDescription)"; save()
    }
    private func save() {
        guard let root else { return }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS { peak = max(peak, info.phys_footprint) }
        if peak > 512 * 1024 * 1024 { failed = true; worker?.cancel(); message = "512 MiB 保护触发" }
        evidence.merge(["taskID":record.taskID.uuidString,"migrationID":scenario?.migrationID.uuidString ?? "",
            "runID":runID?.uuidString ?? "", "phase":record.task.phase.rawValue,"itemCount":record.selectionIDs.count,
            "resourceUploadBytes":uploaded,"macPhases":phases,"message":message,"failed":failed,
            "connected":remote?.isConnected == true,"peakFootprintBytes":peak,"photosAccessed":false,
            "authenticatedDeviceID":(try? remote?.migrationStreamingConnection().deviceID.uuidString) ?? "",
            "usbStatus":remote?.usbStatus ?? "",
            "atMs":Int64(Date().timeIntervalSince1970 * 1000)], uniquingKeysWith: { _, new in new })
        if let bytes = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted,.sortedKeys]) {
            try? bytes.write(to: root.appendingPathComponent("report.json"), options: .atomic)
        }
    }
}
struct USBColdResumeProbeView: View {
    @StateObject private var model = USBColdResumeProbe()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("USB 冷恢复验收").font(.title.bold())
            Text("2,889 项 · 非零合成资源（大小见记录）").foregroundStyle(.secondary)
            Text(model.message)
            Text("本进程新增原件 \(model.uploaded / 1024 / 1024) MiB")
            Button(model.record.task.phase == .received ? "重复恢复核对（零上传）" : "继续同一合成任务") { model.run() }
                .buttonStyle(.borderedProminent).disabled(!model.canRun)
            Text(model.remote?.statusMessage ?? "等待独立 USB 连接").font(.footnote)
            Text(model.remote?.usbStatus ?? "").font(.footnote)
            Button("恢复 USB 等待") { model.remote?.enableUSB() }.disabled(model.busy)
            Button("验证来源重验进度（合成回调）") { model.verifyProgressUI() }
                .disabled(model.busy || model.record.task.phase == .running)
            if !model.revalidationText.isEmpty {
                Text(model.revalidationText).font(.footnote)
            }
            Spacer()
            Text("独立容器与 Mac 接收目录；仅使用合成资源，不访问真实照片。").font(.footnote)
        }.padding(24).task {
            await model.start()
            while !Task.isCancelled {
                await model.tick()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }.onAppear { UIApplication.shared.isIdleTimerDisabled = true }
         .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
         .onChange(of: phase) { _, value in model.scene(value) }
    }
}
#endif
