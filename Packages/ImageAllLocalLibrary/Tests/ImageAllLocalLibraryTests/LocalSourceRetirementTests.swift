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
    let unknownRecord = try #require(await store.sourceRetirementRecords().first)
    try await store.acknowledgeSourceRetirement(id: plan.id, state: unknownRecord.state, updatedAtMs: unknownRecord.updatedAtMs)
    #expect(try await store.sourceRetirementRecords().first?.acknowledgedByMac == true)
    await #expect(throws: (any Error).self) { try await store.cancelSourceRetirement(id: plan.id) }
    #expect(try await store.retiredSourcePresence(assetID: asset.id) == nil)
    // Simulate an explicit successful source callback, never PhotoKit I/O.
    try await store.finishSourceRetirement(id: plan.id, outcome: .succeeded)
    try await store.finishSourceRetirement(id: plan.id, outcome: .succeeded)
    #expect(try await store.retiredSourcePresence(assetID: asset.id) == .retired)
    #expect(try await store.sourceRetirementRecords().first?.acknowledgedByMac == false)
    await #expect(throws: (any Error).self) {
        try await store.acknowledgeSourceRetirement(id: plan.id, state: unknownRecord.state, updatedAtMs: unknownRecord.updatedAtMs)
    }
    let completedRecord = try #require(await store.sourceRetirementRecords().first)
    try await store.acknowledgeSourceRetirement(id: plan.id, state: completedRecord.state, updatedAtMs: completedRecord.updatedAtMs)
    #expect(try await store.pendingSharedOperations().isEmpty)
    let retained = try await store.sharedSnapshot(visibleIdentifiers: ["synthetic"])
    #expect(retained.selectedAssetIDs == checked.snapshot.selectedAssetIDs)
    #expect(retained.assets == checked.snapshot.assets)
    #expect(retained.outboxWatermark == checked.snapshot.outboxWatermark)
    let backup = root.appendingPathComponent("backup.sqlite")
    _ = try await store.exportBackup(to: backup)
    let restored = try LocalLibraryStore(url: backup)
    #expect(try await restored.sourceRetirementRecords().first?.state == .completed)
    #expect(try await restored.sourceRetirementRecords().first?.acknowledgedByMac == true)
    #expect(try await restored.retiredSourcePresence(assetID: asset.id) == .retired)
    try await store.observe([.init(localIdentifier: "synthetic", kind: "image", creationDate: nil, isFavorite: false)])
    #expect(try await store.retiredSourcePresence(assetID: asset.id) == .observedAgain)
    #expect(try await store.sourceRetirementRecords().first?.state == .completed)
}

private actor SyntheticRetirementSource: LocalSourceRetiring {
    let store: LocalLibraryStore
    let mode: Int
    var calls = 0
    init(store: LocalLibraryStore, mode: Int) { self.store = store; self.mode = mode }
    func submitRetirement() async throws -> LocalSourceRetirementOutcome {
        calls += 1
        #expect(try await store.sourceRetirementRecords().first?.state == .submitted)
        if mode == 2 { throw LocalLibraryError.database("synthetic callback lost") }
        if mode == 3 { withUnsafeCurrentTask { $0?.cancel() } }
        return mode == 0 || mode == 3 ? .succeeded : .failed
    }
}

@Test(arguments: [0, 1, 2, 3])
func sourceRetirementExecutorPersistsActualCallbackAndNeverReplays(mode: Int) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    try await store.observe([.init(localIdentifier: "synthetic", kind: "image", creationDate: nil, isFavorite: false)])
    let asset = try #require(await store.assets(visibleIdentifiers: ["synthetic"]).first)
    try await store.setShared(assetID: asset.id, shared: true)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["synthetic"])
    try await store.acknowledgeSharedSnapshot(snapshot, hostID: UUID(), deviceID: UUID(), importedAssetIDs: [asset.id])
    let checked = try await store.migrationCompletionCheckpoint(visibleIdentifiers: ["synthetic"])
    let plan = LocalSourceRetirementPlan(id: UUID(), migrationID: UUID(), requestID: UUID(), sourceReportID: UUID(),
        completionReceiptID: UUID(), backupReceiptID: UUID(), manifestSHA256: String(repeating: "a", count: 64),
        factSnapshotSHA256: String(repeating: "b", count: 64), candidateAssetIDs: [asset.id],
        snapshot: checked.snapshot, checkpoint: checked.checkpoint)
    let source = SyntheticRetirementSource(store: store, mode: mode)
    let operation = Task {
        try await LocalSourceRetirementExecutor.perform(plan, store: store, visibleIdentifiers: ["synthetic"], source: source)
    }
    do { _ = try await operation.value }
    catch { #expect(mode == 2) }
    let succeeded = mode == 0 || mode == 3
    let expected: LocalSourceRetirementState = succeeded ? .completed : (mode == 1 ? .failed : .outcomeUnknown)
    #expect(try await store.sourceRetirementRecords().first?.state == expected)
    #expect(try await store.retiredSourcePresence(assetID: asset.id) == (succeeded ? .retired : nil))
    await #expect(throws: (any Error).self) {
        _ = try await LocalSourceRetirementExecutor.perform(plan, store: store, visibleIdentifiers: ["synthetic"], source: source)
    }
    #expect(await source.calls == 1)
    #expect(try await store.pendingSharedOperations().isEmpty)
}

@Test func unknownRetirementCanOnlyBeClosedAfterProcessRestartWithoutClaimingDeletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let session = UUID()
    let store = try LocalLibraryStore(url: url, retirementSessionID: session)
    try await store.observe([.init(localIdentifier: "synthetic", kind: "image", creationDate: nil, isFavorite: false)])
    let asset = try #require(await store.assets(visibleIdentifiers: ["synthetic"]).first)
    try await store.setShared(assetID: asset.id, shared: true)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["synthetic"])
    try await store.acknowledgeSharedSnapshot(snapshot, hostID: UUID(), deviceID: UUID(), importedAssetIDs: [asset.id])
    let checked = try await store.migrationCompletionCheckpoint(visibleIdentifiers: ["synthetic"])
    let plan = LocalSourceRetirementPlan(id: UUID(), migrationID: UUID(), requestID: UUID(), sourceReportID: UUID(),
        completionReceiptID: UUID(), backupReceiptID: UUID(), manifestSHA256: String(repeating: "a", count: 64),
        factSnapshotSHA256: String(repeating: "b", count: 64), candidateAssetIDs: [asset.id],
        snapshot: checked.snapshot, checkpoint: checked.checkpoint)
    _ = try await store.prepareSourceRetirement(plan, visibleIdentifiers: ["synthetic"])
    try await store.markSourceRetirementSubmitted(id: plan.id, visibleIdentifiers: ["synthetic"])
    let pending = try #require(await store.sourceRetirementRecords().first)
    try await store.acknowledgeSourceRetirement(id: plan.id, state: pending.state, updatedAtMs: pending.updatedAtMs)
    await #expect(throws: (any Error).self) { try await store.manuallyCloseUnknownSourceRetirement(id: plan.id) }
    let sameProcess = try LocalLibraryStore(url: url, retirementSessionID: session)
    #expect(try await sameProcess.sourceRetirementRecords().first?.canManuallyClose == false)
    let restarted = try LocalLibraryStore(url: url, retirementSessionID: UUID())
    #expect(try await restarted.sourceRetirementRecords().first?.canManuallyClose == true)
    try await restarted.manuallyCloseUnknownSourceRetirement(id: plan.id)
    try await restarted.manuallyCloseUnknownSourceRetirement(id: plan.id)
    let closed = try #require(await restarted.sourceRetirementRecords().first)
    #expect(closed.state == .closedUnknown)
    #expect(!closed.acknowledgedByMac && !closed.canManuallyClose)
    #expect(try await restarted.retiredSourcePresence(assetID: asset.id) == nil)
    await #expect(throws: (any Error).self) { try await restarted.finishSourceRetirement(id: plan.id, outcome: .succeeded) }
    let source = SyntheticRetirementSource(store: restarted, mode: 0)
    await #expect(throws: (any Error).self) {
        _ = try await LocalSourceRetirementExecutor.perform(plan, store: restarted, visibleIdentifiers: ["synthetic"], source: source)
    }
    #expect(await source.calls == 0)
    #expect(try await restarted.sharedSnapshot(visibleIdentifiers: ["synthetic"]).assets == checked.snapshot.assets)
    #expect(try await restarted.pendingSharedOperations().isEmpty)
    let backup = root.appendingPathComponent("backup.sqlite")
    _ = try await restarted.exportBackup(to: backup)
    let restored = try LocalLibraryStore(url: backup)
    #expect(try await restored.sourceRetirementRecords().first?.state == .closedUnknown)
    #expect(try await restored.retiredSourcePresence(assetID: asset.id) == nil)
}
