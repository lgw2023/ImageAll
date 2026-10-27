import Foundation
import ImageAllRemoteProtocol

@main
struct ShareCleanupQueueTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = root.appendingPathComponent(UUID().uuidString)
        let queue = LocalShareCleanupQueue(directory: directory)
        var task = LocalShareTaskRecord()
        let host = UUID().uuidString, migration = UUID()
        try task.begin(selectionIDs: [UUID()], includeAlbumCatalog: false, hostID: host,
            fingerprint: "synthetic", target: "fixture", intent: .transferSelection)
        try task.bind(sourceInstallID: UUID(), sourceEpoch: UUID())
        try task.bind(migrationID: migration)
        try task.bindExportRoot(root.appendingPathComponent(".staging-" + String(repeating: "c", count: 64)), migrationID: migration)
        let receipt = try JSONDecoder().decode(ImageAllMigrationTransferSealReceipt.self,
            from: JSONSerialization.data(withJSONObject: ["migrationID": migration.uuidString,
                "manifestSHA256": String(repeating: "a", count: 64), "itemCount": 1,
                "resourceCount": 1, "verifiedBytes": 4096]))
        try task.receive(receipt)
        let attempt = task.beginAutomaticCleanup(nowMs: 1000, connected: true, ready: true)!
        task.finishAutomaticCleanup(attempt, nowMs: 2000)
        try queue.retain(task)
        let saved = directory.appendingPathComponent(task.taskID.uuidString.lowercased())
        let before = try Data(contentsOf: saved.appendingPathComponent("active-task.json"))
        try queue.retain(task)
        let after = try Data(contentsOf: saved.appendingPathComponent("active-task.json"))
        precondition(before == after)
        let next = try queue.next(hostID: host, fingerprint: "synthetic", nowMs: 999999)
        precondition(next == nil)
        let moved = root.appendingPathComponent("retained-" + UUID().uuidString)
        try FileManager.default.moveItem(at: saved, to: moved)
        try FileManager.default.createSymbolicLink(at: saved, withDestinationURL: moved)
        do { try queue.retain(task); preconditionFailure("symlink must be rejected") } catch { }
        let unchanged = try Data(contentsOf: moved.appendingPathComponent("active-task.json"))
        precondition(unchanged == before)
        print("PASS: repeated completed-task retention is idempotent; substituted symlink rejected")
    }
}
