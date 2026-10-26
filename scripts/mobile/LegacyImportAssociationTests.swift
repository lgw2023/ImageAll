import Foundation
import ImageAllRemoteProtocol

@main
struct LegacyImportAssociationTests {
    static func main() throws {
        func check(_ value: Bool) { precondition(value) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        let stage = root.appendingPathComponent(".staging-" + String(repeating: "a", count: 64))
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = (0..<2_889).map { _ in UUID() }
        let items = ids.prefix(2_866).enumerated().map { index, id in
            ImageAllMigrationItem(mediaID: id, sourceLocalIdentifier: "synthetic-\(index)",
                mediaKind: .image, createdAtMs: nil, favoriteTarget: nil, observedFavorite: false,
                factRevision: 0, tagDecisions: [], collections: [], resources: [
                    .init(id: UUID(), role: "original", version: 1, uniformTypeIdentifier: "public.data",
                          required: true, status: .present, relativePath: "resources/\(id.uuidString).bin",
                          byteCount: 1, sha256: String(repeating: "a", count: 64))
                ])
        }
        let header = ImageAllMigrationHeader(migrationID: UUID(), sourceDeviceID: UUID(), sourceEpoch: UUID(),
            scopeRevision: 2, inventoryWatermark: 75, declaredItemCount: items.count,
            appleAlbumCoverage: .selectedAssetsOnly, appleAlbumCatalog: [], retainedSelectionIDs: ids)
        try ImageAllMigrationArchive.write(header: header, items: items, to: stage)
        let hash = try ImageAllMigrationStreamRecord.manifestSHA256(header: header, items: items)
        let receipt = try JSONDecoder().decode(ImageAllMigrationTransferSealReceipt.self,
            from: JSONSerialization.data(withJSONObject: [
                "migrationID": header.migrationID.uuidString, "manifestSHA256": hash,
                "itemCount": items.count, "resourceCount": items.count, "verifiedBytes": items.count]))
        let host = UUID(), device = UUID()
        let record = try ImageAllMigrationStreamRecord(hostID: host, deviceID: device,
            header: header, items: items, receipt: receipt)
        try record.save(in: stage)
        let before = try FileManager.default.contentsOfDirectory(atPath: stage.path).sorted()
        let oldManifest = try Data(contentsOf: stage.appendingPathComponent("manifest.jsonl"))
        var candidates: [LocalShareLegacyCandidate] = []
        try ImageAllMigrationStreamRecord.visitExisting(in: root) { record in
            if let candidate = try LocalShareLegacyCandidate(record: record, hostID: host, deviceID: device,
                sourceInstallID: header.sourceDeviceID, sourceEpoch: header.sourceEpoch,
                selectionIDs: Set(ids), includeAlbumCatalog: true) { candidates.append(candidate) }
        }
        check(candidates.count == 1)
        check(!FileManager.default.fileExists(atPath: stage.appendingPathComponent("resources").path))
        check(try FileManager.default.contentsOfDirectory(atPath: stage.path).sorted() == before)
        check(try Data(contentsOf: stage.appendingPathComponent("manifest.jsonl")) == oldManifest)
        check(try FileManager.default.contentsOfDirectory(atPath: root.path) == [stage.lastPathComponent])
        var task = LocalShareTaskRecord()
        let taskID = task.taskID, candidate = candidates[0], sourceID = UUID()
        let status = RemoteImportTaskStatus(query: candidate.query(taskID: taskID), phase: .browsable,
                                           sourceID: sourceID, itemCount: 2_866)
        try task.associate(candidate, status: status, selectionIDs: Set(ids), includeAlbumCatalog: true,
            hostID: host.uuidString, fingerprint: "synthetic-pin", target: "Fixture Mac")
        check(task.taskID == taskID && task.migrationID == header.migrationID)
        check(task.task.phase == .received && task.task.itemCount == 2_889 && task.task.receivedItemCount == 2_866)
        let journal = LocalShareTaskJournal(directory: root)
        try journal.save(task)
        let restored = try journal.load()!
        check(restored.taskID == taskID && restored.statusQuery == status.query && restored.task.macStatus == nil)
        func reject(_ action: () throws -> Void) {
            do { try action(); preconditionFailure("invalid association accepted") } catch {}
        }
        var fresh = LocalShareTaskRecord()
        reject {
            try fresh.associate(candidate, status: status, selectionIDs: Set(ids), includeAlbumCatalog: true,
                hostID: host.uuidString, fingerprint: "pin", target: "Mac")
        }
        check(fresh.task.phase == .idle)
        let unconfirmed = RemoteImportTaskStatus(query: candidate.query(taskID: fresh.taskID), phase: .awaitingImport)
        reject {
            try fresh.associate(candidate, status: unconfirmed, selectionIDs: Set(ids), includeAlbumCatalog: true,
                hostID: host.uuidString, fingerprint: "pin", target: "Mac")
        }
        check(try LocalShareLegacyCandidate(record: record, hostID: UUID(), deviceID: device,
            sourceInstallID: header.sourceDeviceID, sourceEpoch: header.sourceEpoch,
            selectionIDs: Set(ids), includeAlbumCatalog: true) == nil)
        check(try LocalShareLegacyCandidate(record: record, hostID: host, deviceID: device,
            sourceInstallID: header.sourceDeviceID, sourceEpoch: UUID(),
            selectionIDs: Set(ids), includeAlbumCatalog: true) == nil)
        check(try LocalShareLegacyCandidate(record: record, hostID: host, deviceID: device,
            sourceInstallID: header.sourceDeviceID, sourceEpoch: header.sourceEpoch,
            selectionIDs: Set(ids.dropLast()), includeAlbumCatalog: true) == nil)
        check(try LocalShareLegacyCandidate(record: record, hostID: host, deviceID: device,
            sourceInstallID: header.sourceDeviceID, sourceEpoch: header.sourceEpoch,
            selectionIDs: Set(ids), includeAlbumCatalog: false) == nil)
        task.task.pause(reason: .userRequested)
        reject {
            try task.associate(candidate, status: status, selectionIDs: Set(ids), includeAlbumCatalog: true,
                hostID: host.uuidString, fingerprint: "pin", target: "Mac")
        }
        check(task.task.phase == .paused && task.task.pauseReason == .userRequested)
        try Data("corrupt".utf8).write(to: stage.appendingPathComponent("manifest.jsonl"))
        reject { try ImageAllMigrationStreamRecord.visitExisting(in: root) { _ in preconditionFailure() } }
        let absent = root.appendingPathComponent("missing")
        try ImageAllMigrationStreamRecord.visitExisting(in: absent) { _ in preconditionFailure() }
        check(!FileManager.default.fileExists(atPath: absent.path))
        print("PASS: 2889/2866 legacy association with missing resource directory; no lock/staging/manifest writes")
        print("PASS: same task persisted; wrong target/epoch/range/options/task, unconfirmed publication, paused task and corrupt manifest rejected")
    }
}
