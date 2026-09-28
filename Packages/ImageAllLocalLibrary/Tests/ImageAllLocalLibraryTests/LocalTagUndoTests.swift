import Foundation
import Testing
@testable import ImageAllLocalLibrary

@Test func tagUndoSurvivesRestartAndQueuesCompensationOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    try await store.observe([.init(localIdentifier: "synthetic", kind: "image", creationDate: nil, isFavorite: false)])
    let asset = try #require(await store.assets(visibleIdentifiers: ["synthetic"]).first)
    let tag = try await store.createTag(name: "家庭")
    try await store.setShared(assetID: asset.id, shared: true)
    let original = try await store.setDecision(assetID: asset.id, tagID: tag, decision: .accepted)
    let reopened = try LocalLibraryStore(url: url)
    #expect(try await reopened.tagUndoCandidates(assetID: asset.id)[tag] == original)
    let compensation = try await reopened.undoTagDecision(operationID: original)
    #expect(compensation != original)
    #expect(try await reopened.decisions(assetID: asset.id)[tag] == .cleared)
    let pending = try await reopened.pendingSharedOperations()
    #expect(pending.map(\.id) == [original, compensation])
    #expect(pending.map(\.value) == ["accepted", "cleared"])
    #expect(try await reopened.tagUndoCandidates(assetID: asset.id).isEmpty)
    let count = try await reopened.pendingOperations().count
    await #expect(throws: LocalLibraryError.undoUnavailable) {
        try await reopened.undoTagDecision(operationID: original)
    }
    #expect(try await reopened.pendingOperations().count == count)
    // A later local decision can itself be undone back to the prior explicit value.
    try await reopened.setDecision(assetID: asset.id, tagID: tag, decision: .accepted)
    let rejected = try await reopened.setDecision(assetID: asset.id, tagID: tag, decision: .rejected)
    try await reopened.undoTagDecision(operationID: rejected)
    #expect(try await reopened.decisions(assetID: asset.id)[tag] == .accepted)
}

private enum UndoChange: CaseIterable, Sendable {
    case laterLocal, shareScope, inFlight, acknowledged, remoteConflict
}

@Test(arguments: UndoChange.allCases)
private func staleTagUndoNeverOverwritesNewerState(change: UndoChange) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    try await store.observe([.init(localIdentifier: "synthetic", kind: "image", creationDate: nil, isFavorite: false)])
    let asset = try #require(await store.assets(visibleIdentifiers: ["synthetic"]).first)
    let tag = try await store.createTag(name: "家庭")
    try await store.setShared(assetID: asset.id, shared: true)
    try await store.setDecision(assetID: asset.id, tagID: tag, decision: .accepted)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["synthetic"])
    let host = UUID(), device = UUID()
    try await store.acknowledgeSharedSnapshot(snapshot, hostID: host, deviceID: device, importedAssetIDs: [asset.id])
    let undo = try await store.setDecision(assetID: asset.id, tagID: tag, decision: .rejected)
    #expect(try await store.tagUndoCandidates(assetID: asset.id)[tag] == undo)
    switch change {
    case .laterLocal:
        try await store.setDecision(assetID: asset.id, tagID: tag, decision: .accepted)
        try await store.setDecision(assetID: asset.id, tagID: tag, decision: .rejected)
    case .shareScope:
        try await store.setShared(assetID: asset.id, shared: false)
        try await store.setShared(assetID: asset.id, shared: true)
    case .inFlight, .acknowledged:
        _ = try #require(await store.prepareSharedTagOperation(id: undo, hostID: host, deviceID: device))
        if change == .acknowledged {
            try await store.recordSharedTagResult(operationID: undo, hostID: host, deviceID: device,
                disposition: .applied, fieldRevision: 2, currentDecision: .rejected)
        }
    case .remoteConflict:
        _ = try await store.applySharedTagChanges(hostID: host, deviceID: device,
            sourceEpoch: snapshot.sourceEpoch, scopeRevision: snapshot.scopeRevision, afterCursor: 0,
            changes: [.init(sequence: 1, assetID: asset.id, tagID: tag, tagName: "家庭",
                            decision: .cleared, fieldRevision: 2)], nextCursor: 1)
    }
    let before = try await store.pendingOperations().count
    await #expect(throws: LocalLibraryError.undoUnavailable) { try await store.undoTagDecision(operationID: undo) }
    #expect(try await store.decisions(assetID: asset.id)[tag] == .rejected)
    #expect(try await store.pendingOperations().count == before)
    #expect(try await store.tagUndoCandidates(assetID: asset.id)[tag] != undo)
}
