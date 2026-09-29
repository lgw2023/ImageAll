import SwiftUI
import ImageAllRemoteClient
import ImageAllRemoteProtocol

@main
struct ImageAllMobileApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--adr102-local-probe") {
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
            model.setSceneActive(phase == .active)
        }
    }
}

#if DEBUG
import ImageAllLocalLibrary

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
