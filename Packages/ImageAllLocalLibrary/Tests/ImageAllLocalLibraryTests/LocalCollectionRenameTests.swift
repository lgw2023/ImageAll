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

@Test func aliasedCollectionRenameKeepsLocalMigrationIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    let localID = try await store.createCollection(name: "Café")
    let remoteID = UUID(), host = UUID(), device = UUID()
    try await store.observe([.init(localIdentifier: "synthetic", kind: "image", creationDate: nil, isFavorite: false)])
    let asset = try #require(await store.assets(visibleIdentifiers: ["synthetic"]).first)
    try await store.setShared(assetID: asset.id, shared: true)
    let initial = try await store.prepareSharedSnapshot(visibleIdentifiers: ["synthetic"])
    try await store.acknowledgeSharedSnapshot(initial, hostID: host, deviceID: device, importedAssetIDs: [asset.id])
    let change = LocalSharedCollectionChange(sequence: 1, assetID: asset.id, collectionID: remoteID,
        collectionName: "Cafe\u{301}", included: true, fieldRevision: 1, createdCollectionID: remoteID)
    do {
        _ = try await store.applySharedCollectionChanges(hostID: host, deviceID: device,
            sourceEpoch: initial.sourceEpoch, scopeRevision: initial.scopeRevision,
            afterCursor: 0, changes: [change], nextCursor: 1)
        Issue.record("different IDs require explicit alias confirmation")
    } catch LocalLibraryError.syncRemoteCollectionAliasRequired(let candidate) {
        try await store.confirmSharedCollectionAlias(candidate)
    }
    _ = try await store.applySharedCollectionChanges(hostID: host, deviceID: device,
        sourceEpoch: initial.sourceEpoch, scopeRevision: initial.scopeRevision,
        afterCursor: 0, changes: [change], nextCursor: 1)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["synthetic"])
    #expect(snapshot.assets.first?.collections.first?.collectionID == remoteID)
    try await store.acknowledgeSharedSnapshot(snapshot, hostID: host, deviceID: device, importedAssetIDs: [])
    let command = try await store.prepareCollectionRename(collectionID: localID, newName: "旅行",
                                                          visibleIdentifiers: ["synthetic"])
    #expect(command.localCollectionID == localID)
    #expect(command.collectionID == remoteID)
    #expect(command.expectedName == "Cafe\u{301}")
    _ = try await store.applySharedCollectionChanges(hostID: host, deviceID: device,
        sourceEpoch: initial.sourceEpoch, scopeRevision: initial.scopeRevision,
        afterCursor: 1, changes: [.init(sequence: 2, assetID: asset.id, collectionID: remoteID,
            collectionName: "旅行", included: true, fieldRevision: 1, renamedFrom: "Cafe\u{301}")], nextCursor: 2)
    // Receipt recovery after a pull must accept the same mapping with its updated name.
    try await store.validateCollectionRename(command, visibleIdentifiers: ["synthetic"])
    try await store.completeCollectionRename(command, resultingCursor: 2)
    let migration = try await store.migrationCompletionCheckpoint(visibleIdentifiers: ["synthetic"])
    #expect(migration.snapshot.assets.first?.collections == [.init(collectionID: localID, collectionName: "旅行")])
    #expect(migration.checkpoint.collectionAliases.first?.localCollectionID == localID)
    #expect(migration.checkpoint.collectionAliases.first?.remoteCollectionID == remoteID)
    #expect(migration.checkpoint.collectionAliases.first?.remoteCollectionName == "旅行")
    #expect(migration.checkpoint.collectionChangeCursor == 2)
    #expect(try await store.pendingSharedOperations().isEmpty)
}
