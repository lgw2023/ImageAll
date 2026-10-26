import Foundation
import ImageAllRemoteProtocol

@main
struct ImportTaskStatusTests {
    static func main() throws {
        var record = LocalShareTaskRecord()
        let selection = Set((0..<2_889).map { _ in UUID() })
        try record.begin(selectionIDs: selection, includeAlbumCatalog: true,
            hostID: UUID().uuidString, fingerprint: "synthetic-pin", target: "Fixture Mac", intent: .sealReceived)
        try record.bind(sourceInstallID: UUID(), sourceEpoch: UUID())
        try record.bind(migrationID: UUID())
        // Decode a synthetic seal receipt just as a network response would.
        let json: [String: Any] = ["migrationID": record.migrationID!.uuidString,
            "manifestSHA256": String(repeating: "a", count: 64), "itemCount": 2_866,
            "resourceCount": 4_169, "verifiedBytes": 100]
        let receipt = try JSONDecoder().decode(ImageAllMigrationTransferSealReceipt.self,
            from: JSONSerialization.data(withJSONObject: json))
        try record.receive(receipt)
        let query = record.statusQuery!
        func ui(_ task: LocalShareTask, connected: Bool = true) -> LocalSharePresentation {
            .resolve(task: task, selectedCount: 2_889, canReadPhotos: true, needsFullAccess: false,
                connected: connected, awaitingConsent: false, otherWork: false, selectionMatches: true)
        }
        for phase in [RemoteImportTaskStatus.Phase.awaitingImport, .verifying, .publishing, .needsAttention, .browsable] {
            try record.observe(.init(query: query, phase: phase, sourceID: phase == .browsable ? UUID() : nil,
                                     itemCount: 2_866))
            precondition(record.task.phase == .received && record.taskID == query.taskID)
            precondition(ui(record.task).action == .macNextStep)
            precondition(!ui(record.task).message.contains("保留待处理"))
        }
        precondition(ui(record.task).title == "已导入 Mac · 可浏览")
        precondition(ui(record.task, connected: false).action == .connect)
        let restored = try JSONDecoder().decode(LocalShareTaskRecord.self, from: JSONEncoder().encode(record)).restored()
        precondition(restored.statusQuery == query && restored.task.macStatus == nil)
        precondition(ui(restored.task).title == "Mac 已接收 · 状态待核对")
        func rejects(_ value: RemoteImportTaskStatus) {
            do { try record.observe(value); preconditionFailure("must reject stale/mismatched status") }
            catch {}
        }
        rejects(.init(query: .init(taskID: UUID(), migrationID: query.migrationID,
            sourceInstallID: query.sourceInstallID, sourceEpoch: query.sourceEpoch,
            manifestSHA256: query.manifestSHA256), phase: .browsable, sourceID: UUID(), itemCount: 2_866))
        rejects(.init(query: query, phase: .browsable, sourceID: UUID(), itemCount: 2_889))
        record.task.pause(reason: .userRequested)
        rejects(.init(query: query, phase: .browsable, sourceID: UUID(), itemCount: 2_866))
        precondition(record.task.pauseReason == .userRequested && record.task.phase == .paused)
        print("PASS: task/batch binding, five Mac stages, subset, cold reload, stale response and pause protection")
    }
}
