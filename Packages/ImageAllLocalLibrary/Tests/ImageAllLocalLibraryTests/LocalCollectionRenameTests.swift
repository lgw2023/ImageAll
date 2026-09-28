import Foundation
import Testing
@testable import ImageAllLocalLibrary

@Test func collectionRenameWaitsForPullAndSurvivesRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    try await store.observe([.init(localIdentifier: "synthetic", kind: "image", creationDate: nil, isFavorite: false)])
    let asset = try #require(await store.assets(visibleIdentifiers: ["synthetic"]).first)
    let collection = try await store.createCollection(name: "旧名")
    try await store.setMembership(assetID: asset.id, collectionID: collection, included: true)
    try await store.setShared(assetID: asset.id, shared: true)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["synthetic"])
    let host = UUID(), device = UUID()
    try await store.acknowledgeSharedSnapshot(snapshot, hostID: host, deviceID: device, importedAssetIDs: [asset.id])
    let command = try await store.prepareCollectionRename(collectionID: collection, newName: " 新名 ", visibleIdentifiers: ["synthetic"])
    #expect(command.newName == "新名")
    #expect(command.collectionID == collection)
    #expect(try await store.collections().first?.name == "旧名")
    let reopened = try LocalLibraryStore(url: url)
    #expect(try await reopened.pendingCollectionRename() == command)
    #expect(try await reopened.prepareCollectionRename(collectionID: collection, newName: "新名", visibleIdentifiers: ["synthetic"]) == command)
    await #expect(throws: LocalLibraryError.migrationSyncPending) {
        try await reopened.migrationCompletionCheckpoint(visibleIdentifiers: ["synthetic"])
    }
    await #expect(throws: LocalLibraryError.syncIdentityChanged) {
        try await reopened.completeCollectionRename(command, resultingCursor: 1)
    }
    await #expect(throws: LocalLibraryError.syncIdentityChanged) {
        try await reopened.validateCollectionRename(command, visibleIdentifiers: [])
    }
    _ = try await reopened.applySharedCollectionChanges(hostID: host, deviceID: device,
        sourceEpoch: snapshot.sourceEpoch, scopeRevision: snapshot.scopeRevision, afterCursor: 0,
        changes: [.init(sequence: 1, assetID: asset.id, collectionID: collection, collectionName: "新名",
                        included: true, fieldRevision: 1, renamedFrom: "旧名")], nextCursor: 1)
    try await reopened.completeCollectionRename(command, resultingCursor: 1)
    #expect(try await reopened.pendingCollectionRename() == nil)
    #expect(try await reopened.collections().first?.name == "新名")
    #expect(try await reopened.memberships(assetID: asset.id) == [collection])
    #expect(try await reopened.pendingSharedOperations().isEmpty)
    let final = try LocalLibraryStore(url: url)
    #expect(try await final.pendingCollectionRename() == nil)
}

@Test func collectionRenameScopeChangeRequiresExplicitAbandon() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    try await store.observe([.init(localIdentifier: "synthetic", kind: "image", creationDate: nil, isFavorite: false)])
    let asset = try #require(await store.assets(visibleIdentifiers: ["synthetic"]).first)
    let collection = try await store.createCollection(name: "旧名")
    try await store.setMembership(assetID: asset.id, collectionID: collection, included: true)
    try await store.setShared(assetID: asset.id, shared: true)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["synthetic"])
    try await store.acknowledgeSharedSnapshot(snapshot, hostID: UUID(), deviceID: UUID(), importedAssetIDs: [asset.id])
    let command = try await store.prepareCollectionRename(collectionID: collection, newName: "新名", visibleIdentifiers: ["synthetic"])
    await #expect(throws: LocalLibraryError.migrationSyncPending) {
        try await store.prepareCollectionRename(collectionID: collection, newName: "另一个名", visibleIdentifiers: ["synthetic"])
    }
    try await store.setShared(assetID: asset.id, shared: false)
    try await store.setShared(assetID: asset.id, shared: true)
    await #expect(throws: LocalLibraryError.syncIdentityChanged) {
        try await store.validateCollectionRename(command, visibleIdentifiers: ["synthetic"])
    }
    #expect(try await store.pendingCollectionRename() == command)
    try await store.abandonCollectionRename(commandID: command.commandID)
    #expect(try await store.pendingCollectionRename() == nil)
    #expect(try await store.collections().first?.name == "旧名")
}
