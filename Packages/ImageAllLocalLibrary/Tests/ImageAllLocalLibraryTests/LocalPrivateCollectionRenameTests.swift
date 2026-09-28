import Foundation
import SQLite3
import Testing
@testable import ImageAllLocalLibrary

@Test func privateCollectionRenameKeepsMembersAndRejectsStaleNameABA() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    let collection = try await store.createCollection(name: "旧名")
    try await store.observe([.init(localIdentifier: "synthetic", kind: "image", creationDate: nil, isFavorite: false)])
    let asset = try #require(await store.assets(visibleIdentifiers: ["synthetic"]).first)
    let undo = try await store.setMembership(assetID: asset.id, collectionID: collection, included: true)
    try await store.renamePrivateCollection(collectionID: collection, expectedName: "旧名", expectedRevision: 0, newName: "新名")
    let reopened = try LocalLibraryStore(url: url)
    #expect(try await reopened.collections().first?.name == "新名")
    #expect(try await reopened.memberships(assetID: asset.id) == [collection])
    #expect(try await reopened.pendingSharedOperations().isEmpty)
    #expect(try await reopened.collectionUndoCandidates(assetID: asset.id)[collection] != undo)
    try await reopened.renamePrivateCollection(collectionID: collection, expectedName: "新名", expectedRevision: 1, newName: "旧名")
    await #expect(throws: LocalLibraryError.syncRemoteCollectionMismatch) {
        try await reopened.renamePrivateCollection(collectionID: collection, expectedName: "旧名", expectedRevision: 0, newName: "过期")
    }
    let empty = try await reopened.createCollection(name: "空集合")
    try await reopened.renamePrivateCollection(collectionID: empty, expectedName: "空集合", expectedRevision: 0, newName: "空集合新名")
    await #expect(throws: LocalLibraryError.syncRemoteCollectionMismatch) {
        try await reopened.renamePrivateCollection(collectionID: collection, expectedName: "旧名", expectedRevision: 2, newName: "空集合新名")
    }
    #expect(try await reopened.privateCollectionNameRevisions()[collection] == 2)
}

@Test(arguments: [false, true])
func collectionShareHistoryNeverRevertsToPrivate(addMemberAfterSharing: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    let collection = try await store.createCollection(name: "家庭")
    try await store.observe([.init(localIdentifier: "synthetic", kind: "image", creationDate: nil, isFavorite: false)])
    let asset = try #require(await store.assets(visibleIdentifiers: ["synthetic"]).first)
    if addMemberAfterSharing { try await store.setShared(assetID: asset.id, shared: true) }
    try await store.setMembership(assetID: asset.id, collectionID: collection, included: true)
    if !addMemberAfterSharing { try await store.setShared(assetID: asset.id, shared: true) }
    try await store.setShared(assetID: asset.id, shared: false)
    let reopened = try LocalLibraryStore(url: url)
    #expect(try await reopened.privateCollectionNameRevisions()[collection] == nil)
    await #expect(throws: LocalLibraryError.syncRemoteCollectionMismatch) {
        try await reopened.renamePrivateCollection(collectionID: collection, expectedName: "家庭", expectedRevision: 0, newName: "不能绕过")
    }
    // Simulate an older database with no provenance table: opening must not invent private history.
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "DROP TABLE private_collection_names", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let legacy = try LocalLibraryStore(url: url)
    #expect(try await legacy.privateCollectionNameRevisions().isEmpty)
}
