import Foundation
import SQLite3
import Testing
@testable import ImageAllLocalLibrary

@Test func collectionUndoSurvivesRestartAndQueuesCompensationOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    try await store.observe([.init(localIdentifier: "synthetic", kind: "image", creationDate: nil, isFavorite: false)])
    let asset = try #require(await store.assets(visibleIdentifiers: ["synthetic"]).first)
    let collection = try await store.createCollection(name: "家庭")
    try await store.setShared(assetID: asset.id, shared: true)
    let original = try await store.setMembership(assetID: asset.id, collectionID: collection, included: true)
    let reopened = try LocalLibraryStore(url: url)
    #expect(try await reopened.collectionUndoCandidates(assetID: asset.id)[collection] == original)
    let compensation = try await reopened.undoMembership(operationID: original)
    #expect(compensation != original)
    // Both audit operations survive, and their causal link is stored durably.
    var db: OpaquePointer?
    #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    let sql = "SELECT compensation_operation_id FROM collection_undo_receipts WHERE original_operation_id='\(original.uuidString)'"
    #expect(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    let stored = try #require(sqlite3_column_text(statement, 0))
    #expect(String(cString: stored) == compensation.uuidString)
    #expect(sqlite3_step(statement) == SQLITE_DONE)
    #expect(try await !reopened.memberships(assetID: asset.id).contains(collection))
    let pending = try await reopened.pendingSharedOperations()
    #expect(pending.map(\.id) == [original, compensation])
    #expect(pending.map(\.value) == ["1", "0"])
    #expect(try await reopened.collectionUndoCandidates(assetID: asset.id).isEmpty)
    let count = try await reopened.pendingOperations().count
    await #expect(throws: LocalLibraryError.undoUnavailable) {
        try await reopened.undoMembership(operationID: original)
    }
    #expect(try await reopened.pendingOperations().count == count)
    // A later local member change can itself be undone back to the prior membership.
    try await reopened.setMembership(assetID: asset.id, collectionID: collection, included: true)
    let removed = try await reopened.setMembership(assetID: asset.id, collectionID: collection, included: false)
    try await reopened.undoMembership(operationID: removed)
    #expect(try await reopened.memberships(assetID: asset.id).contains(collection))
}

private enum CollectionUndoChange: CaseIterable, Sendable {
    case laterLocal, shareScope, inFlight, acknowledged, remoteConflict, remoteRename, remoteRenameABA
}

@Test(arguments: CollectionUndoChange.allCases)
private func staleCollectionUndoNeverOverwritesNewerState(change: CollectionUndoChange) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    try await store.observe([.init(localIdentifier: "synthetic", kind: "image", creationDate: nil, isFavorite: false)])
    let asset = try #require(await store.assets(visibleIdentifiers: ["synthetic"]).first)
    let collection = try await store.createCollection(name: "家庭")
    try await store.setShared(assetID: asset.id, shared: true)
    try await store.setMembership(assetID: asset.id, collectionID: collection, included: true)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["synthetic"])
    let host = UUID(), device = UUID()
    try await store.acknowledgeSharedSnapshot(snapshot, hostID: host, deviceID: device, importedAssetIDs: [asset.id])
    let undo = try await store.setMembership(assetID: asset.id, collectionID: collection, included: false)
    #expect(try await store.collectionUndoCandidates(assetID: asset.id)[collection] == undo)
    switch change {
    case .laterLocal:
        try await store.setMembership(assetID: asset.id, collectionID: collection, included: true)
        try await store.setMembership(assetID: asset.id, collectionID: collection, included: false)
    case .shareScope:
        try await store.setShared(assetID: asset.id, shared: false)
        try await store.setShared(assetID: asset.id, shared: true)
    case .inFlight, .acknowledged:
        _ = try #require(await store.prepareSharedCollectionOperation(id: undo, hostID: host, deviceID: device))
        if change == .acknowledged {
            try await store.recordSharedCollectionResult(operationID: undo, hostID: host, deviceID: device,
                disposition: .applied, fieldRevision: 2, currentIncluded: false)
        }
    case .remoteRename, .remoteRenameABA:
        _ = try await store.applySharedCollectionChanges(hostID: host, deviceID: device,
            sourceEpoch: snapshot.sourceEpoch, scopeRevision: snapshot.scopeRevision, afterCursor: 0,
            changes: [.init(sequence: 1, assetID: asset.id, collectionID: collection, collectionName: "家庭新名",
                            included: true, fieldRevision: 1, renamedFrom: "家庭")], nextCursor: 1)
        #expect(try await store.collections().first { $0.id == collection }?.name == "家庭新名")
        if change == .remoteRenameABA {
            _ = try await store.applySharedCollectionChanges(hostID: host, deviceID: device,
                sourceEpoch: snapshot.sourceEpoch, scopeRevision: snapshot.scopeRevision, afterCursor: 1,
                changes: [.init(sequence: 2, assetID: asset.id, collectionID: collection, collectionName: "家庭",
                                included: true, fieldRevision: 1, renamedFrom: "家庭新名")], nextCursor: 2)
            #expect(try await store.collections().first { $0.id == collection }?.name == "家庭")
        }
    case .remoteConflict:
        _ = try await store.applySharedCollectionChanges(hostID: host, deviceID: device,
            sourceEpoch: snapshot.sourceEpoch, scopeRevision: snapshot.scopeRevision, afterCursor: 0,
            changes: [.init(sequence: 1, assetID: asset.id, collectionID: collection, collectionName: "家庭",
                            included: false, fieldRevision: 2)], nextCursor: 1)
    }
    let before = try await store.pendingOperations().count
    await #expect(throws: LocalLibraryError.undoUnavailable) { try await store.undoMembership(operationID: undo) }
    #expect(try await !store.memberships(assetID: asset.id).contains(collection))
    #expect(try await store.pendingOperations().count == before)
    #expect(try await store.collectionUndoCandidates(assetID: asset.id)[collection] != undo)
}
