import Foundation

@main
struct ShareTaskRecoveryTests {
    static func main() throws {
        try verifyFreshProcessRecovery()
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let journal = LocalShareTaskJournal(directory: root)
        precondition(tryLoad(journal) == nil)
        let selection = Set((0..<2_889).map { _ in UUID() })
        let host = UUID().uuidString, source = UUID(), epoch = UUID(), migration = UUID()
        var original = LocalShareTaskRecord()
        try original.begin(selectionIDs: selection, includeAlbumCatalog: true, hostID: host,
            fingerprint: "synthetic-pin", target: "Fixture Mac", intent: .sealReceived)
        try original.bind(sourceInstallID: source, sourceEpoch: epoch)
        try original.bind(migrationID: migration)
        original.task.detail = "not-for-persistence-private-path"
        try journal.save(original)
        let bytes = try Data(contentsOf: root.appendingPathComponent("active-task.json"))
        precondition(!String(decoding: bytes, as: UTF8.self).contains("private-path"))
        var restored = try journal.load()!
        precondition(restored.taskID == original.taskID && restored.migrationID == migration)
        precondition(restored.selectionIDs == selection && restored.includeAlbumCatalog)
        precondition(restored.task.phase == .paused && restored.task.pauseReason == .processInterrupted)
        precondition(restored.task.intent == .sealReceived)
        let ui = LocalSharePresentation.resolve(task: restored.task, selectedCount: 2_889,
            canReadPhotos: true, needsFullAccess: false, connected: true,
            awaitingConsent: false, otherWork: false, selectionMatches: true)
        precondition(ui.action == .resume && ui.message.contains("仅封存"))
        try restored.begin(selectionIDs: selection, includeAlbumCatalog: true, hostID: host,
            fingerprint: "synthetic-pin", target: "Fixture Mac", intent: restored.task.intent)
        restored.task.requestPause(.userRequested)
        try journal.save(restored)
        let paused = try journal.load()!
        precondition(paused.task.pauseReason == .userRequested && paused.task.phase == .paused)
        precondition(paused.taskID == original.taskID && paused.migrationID == migration)
        try journal.save(paused)
        precondition(tryLoad(journal)?.task.pauseReason == .userRequested)
        print("PASS: 2889-item restart retains IDs, range, seal-only intent and explicit pause; no automatic resume")

        func rejects(_ body: () throws -> Void) {
            do { try body(); preconditionFailure("expected rejection") } catch { }
        }
        for mutation in 0..<3 {
            var conflict = paused
            rejects {
                try conflict.begin(selectionIDs: mutation == 0 ? [UUID()] : selection,
                    includeAlbumCatalog: true, hostID: mutation == 1 ? UUID().uuidString : host,
                    fingerprint: mutation == 2 ? "changed-pin" : "synthetic-pin", target: "Fixture",
                    intent: .sealReceived)
            }
            precondition(conflict.task.phase == .paused && conflict.migrationID == migration)
        }
        var conflict = paused
        rejects { try conflict.bind(sourceInstallID: source, sourceEpoch: UUID()) }
        rejects { try conflict.bind(migrationID: UUID()) }
        precondition(tryLoad(journal)?.migrationID == migration)
        print("PASS: changed selection, target, pin, source epoch and migration cannot replace original task")

        var received = restored
        received.task.receive(itemCount: 2_866)
        try journal.save(received)
        let receivedAgain = try journal.load()!
        precondition(receivedAgain.task.phase == .received && receivedAgain.task.receivedItemCount == 2_866)
        precondition(receivedAgain.task.itemCount == 2_889)
        print("PASS: received subset survives restart without claiming Mac publication")

        let file = root.appendingPathComponent("active-task.json")
        try Data("{}".utf8).write(to: file)
        rejects { _ = try journal.load() }
        var unknown = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        unknown["version"] = 999
        try JSONSerialization.data(withJSONObject: unknown).write(to: file)
        rejects { _ = try journal.load() }
        try FileManager.default.removeItem(at: file)
        let protected = root.appendingPathComponent("synthetic-sentinel")
        try bytes.write(to: protected)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: protected)
        rejects { _ = try journal.load() }
        rejects { try journal.save(original) }
        let retained = try Data(contentsOf: protected)
        precondition(retained == bytes)
        let missing = LocalShareTaskJournal(directory: root.appendingPathComponent("missing"))
        rejects { try missing.save(original) }
        print("PASS: corrupt/unknown records, symlinks and write failures are rejected without touching targets")
    }

    private static func tryLoad(_ journal: LocalShareTaskJournal) -> LocalShareTaskRecord? {
        try! journal.load()
    }

    private static func verifyFreshProcessRecovery() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("restart-fixture")
        let expectedURL = root.appendingPathComponent("expected.json")
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            var record = LocalShareTaskRecord()
            try record.begin(selectionIDs: Set((0..<2_889).map { _ in UUID() }), includeAlbumCatalog: true,
                hostID: UUID().uuidString, fingerprint: "synthetic-pin", target: "Fixture", intent: .sealReceived)
            try record.bind(sourceInstallID: UUID(), sourceEpoch: UUID())
            try record.bind(migrationID: UUID())
            record.task.requestPause(.appBackground)
            try LocalShareTaskJournal(directory: root).save(record)
            try JSONEncoder().encode(record).write(to: expectedURL)
            print("PASS: fresh-process fixture persisted 2889-item task before exit")
        } else {
            let expected = try JSONDecoder().decode(LocalShareTaskRecord.self, from: Data(contentsOf: expectedURL))
            let restored = try LocalShareTaskJournal(directory: root).load()!
            precondition(restored.taskID == expected.taskID && restored.migrationID == expected.migrationID)
            precondition(restored.selectionIDs == expected.selectionIDs && restored.selectionIDs.count == 2_889)
            precondition(restored.task.phase == .paused && restored.task.pauseReason == .appBackground)
            precondition(restored.task.intent == .sealReceived)
            print("PASS: separate process recovered same 2889-item task and migration, paused with seal-only intent")
        }
    }
}
