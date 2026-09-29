import Foundation
import Testing
@testable import ImageAllLocalLibrary

@Test func sourceRetirementJournalSurvivesRestartWithoutDeletionPropagation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    var store = try LocalLibraryStore(url: url)
    try await store.observe([.init(localIdentifier: "synthetic", kind: "image", creationDate: nil, isFavorite: false)])
    let asset = try #require(await store.assets(visibleIdentifiers: ["synthetic"]).first)
    let tag = try await store.createTag(name: "Kept on Mac")
    _ = try await store.setDecision(assetID: asset.id, tagID: tag, decision: .accepted)
    try await store.setShared(assetID: asset.id, shared: true)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["synthetic"])
    try await store.acknowledgeSharedSnapshot(snapshot, hostID: UUID(), deviceID: UUID(), importedAssetIDs: [asset.id])
    let checked = try await store.migrationCompletionCheckpoint(visibleIdentifiers: ["synthetic"])
    let plan = LocalSourceRetirementPlan(id: UUID(), migrationID: UUID(), requestID: UUID(), sourceReportID: UUID(),
        completionReceiptID: UUID(), backupReceiptID: UUID(), manifestSHA256: String(repeating: "a", count: 64),
        factSnapshotSHA256: String(repeating: "b", count: 64), candidateAssetIDs: [asset.id],
        snapshot: checked.snapshot, checkpoint: checked.checkpoint)
    let prepared = try await store.prepareSourceRetirement(plan, visibleIdentifiers: ["synthetic"])
    #expect(prepared.state == .prepared)
    #expect(try await store.prepareSourceRetirement(plan, visibleIdentifiers: ["synthetic"]) == prepared)
    for field in ["id", "backupReceiptID"] {
        var changed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as! [String: Any]
        changed[field] = UUID().uuidString
        let conflicting = try JSONDecoder().decode(LocalSourceRetirementPlan.self,
            from: JSONSerialization.data(withJSONObject: changed))
        await #expect(throws: (any Error).self) {
            _ = try await store.prepareSourceRetirement(conflicting, visibleIdentifiers: ["synthetic"])
        }
    }
    await #expect(throws: (any Error).self) { try await store.finishSourceRetirement(id: plan.id, outcome: .succeeded) }
    // Source favorite drift is checked again at the submission boundary.
    try await store.observe([.init(localIdentifier: "synthetic", kind: "image", creationDate: nil, isFavorite: true)])
    await #expect(throws: (any Error).self) { try await store.markSourceRetirementSubmitted(id: plan.id, visibleIdentifiers: ["synthetic"]) }
    try await store.observe([.init(localIdentifier: "synthetic", kind: "image", creationDate: nil, isFavorite: false)])
    try await store.markSourceRetirementSubmitted(id: plan.id, visibleIdentifiers: ["synthetic"])
    store = try LocalLibraryStore(url: url)
    #expect(try await store.sourceRetirementRecords().first?.state == .submitted)
    await #expect(throws: (any Error).self) { try await store.markSourceRetirementSubmitted(id: plan.id, visibleIdentifiers: ["synthetic"]) }
    // Permission contraction provides no completion evidence.
    let hidden = try await store.sharedSnapshot(visibleIdentifiers: [])
    #expect(hidden.selectedAssetIDs == [asset.id])
    #expect(try await store.retiredSourcePresence(assetID: asset.id) == nil)
    try await store.finishSourceRetirement(id: plan.id, outcome: .unknown)
    await #expect(throws: (any Error).self) { try await store.cancelSourceRetirement(id: plan.id) }
    #expect(try await store.retiredSourcePresence(assetID: asset.id) == nil)
    // Simulate an explicit successful source callback, never PhotoKit I/O.
    try await store.finishSourceRetirement(id: plan.id, outcome: .succeeded)
    try await store.finishSourceRetirement(id: plan.id, outcome: .succeeded)
    #expect(try await store.retiredSourcePresence(assetID: asset.id) == .retired)
    #expect(try await store.pendingSharedOperations().isEmpty)
    let retained = try await store.sharedSnapshot(visibleIdentifiers: ["synthetic"])
    #expect(retained.selectedAssetIDs == checked.snapshot.selectedAssetIDs)
    #expect(retained.assets == checked.snapshot.assets)
    #expect(retained.outboxWatermark == checked.snapshot.outboxWatermark)
    let backup = root.appendingPathComponent("backup.sqlite")
    _ = try await store.exportBackup(to: backup)
    let restored = try LocalLibraryStore(url: backup)
    #expect(try await restored.sourceRetirementRecords().first?.state == .completed)
    #expect(try await restored.retiredSourcePresence(assetID: asset.id) == .retired)
    try await store.observe([.init(localIdentifier: "synthetic", kind: "image", creationDate: nil, isFavorite: false)])
    #expect(try await store.retiredSourcePresence(assetID: asset.id) == .observedAgain)
    #expect(try await store.sourceRetirementRecords().first?.state == .completed)
}
