import Foundation
import Testing
@testable import ImageAllLocalLibrary

@Test func persistsOfflineFactsAndStableIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    let installID = try await store.installID()
    let epoch = try await store.sourceEpoch()
    try await store.observe([
        LocalObservedAsset(localIdentifier: "fixture-1", kind: "image", creationDate: nil, isFavorite: false)
    ])
    let tagID = try await store.createTag(name: "旅行")
    let collectionID = try await store.createCollection(name: "秋天")
    let asset = try #require(await store.assets(visibleIdentifiers: ["fixture-1"]).first)
    try await store.setDecision(assetID: asset.id, tagID: tagID, decision: .accepted)
    try await store.setMembership(assetID: asset.id, collectionID: collectionID, included: true)
    try await store.setFavoriteTarget(assetID: asset.id, isFavorite: true)
    #expect(try await store.assets(visibleIdentifiers: ["fixture-1"]).first?.favoriteWritebackState == .pending)
    let operations = try await store.pendingOperations()
    #expect(operations.count == 5)
    #expect(Set(operations.map(\.id)).count == 5)

    let reopened = try LocalLibraryStore(url: url)
    #expect(try await reopened.installID() == installID)
    #expect(try await reopened.sourceEpoch() == epoch)
    #expect(try await reopened.assets(visibleIdentifiers: ["fixture-1"]).first?.id == asset.id)
    #expect(try await reopened.decisions(assetID: asset.id)[tagID] == .accepted)
    #expect(try await reopened.assets(visibleIdentifiers: ["fixture-1"]).first?.favoriteWritebackState == .pending)
    #expect(try await reopened.memberships(assetID: asset.id) == [collectionID])
    #expect(try await reopened.pendingOperations().map(\.id) == operations.map(\.id))

    // A reduced PhotoKit authorization scope must hide, never erase, the local facts.
    #expect(try await reopened.assets(visibleIdentifiers: []).isEmpty)
    #expect(try await reopened.decisions(assetID: asset.id)[tagID] == .accepted)
}

@Test func favoriteWritebackPreservesNewerIntentAndReconcilesReadback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    let observation = LocalObservedAsset(
        localIdentifier: "fixture-favorite", kind: "image", creationDate: nil, isFavorite: false
    )
    try await store.observe([observation])
    let asset = try #require(await store.assets(visibleIdentifiers: ["fixture-favorite"]).first)

    try await store.setFavoriteTarget(assetID: asset.id, isFavorite: true)
    try await store.finishFavoriteWriteback(assetID: asset.id, requestedValue: true, observedValue: nil)
    #expect(try await store.assets(visibleIdentifiers: ["fixture-favorite"]).first?.favoriteWritebackState == .failed)

    try await store.setFavoriteTarget(assetID: asset.id, isFavorite: false)
    try await store.finishFavoriteWriteback(assetID: asset.id, requestedValue: true, observedValue: true)
    let afterLateReply = try #require(await store.assets(visibleIdentifiers: ["fixture-favorite"]).first)
    #expect(afterLateReply.favoriteTarget == false)
    #expect(afterLateReply.observedFavorite == false)
    #expect(afterLateReply.favoriteWritebackState == .pending)

    try await store.finishFavoriteWriteback(assetID: asset.id, requestedValue: false, observedValue: false)
    #expect(try await store.assets(visibleIdentifiers: ["fixture-favorite"]).first?.favoriteWritebackState == .matched)

    try await store.observe([LocalObservedAsset(
        localIdentifier: "fixture-favorite", kind: "image", creationDate: nil, isFavorite: true
    )])
    let afterExternalChange = try #require(await store.assets(visibleIdentifiers: ["fixture-favorite"]).first)
    #expect(afterExternalChange.observedFavorite == true)
    #expect(afterExternalChange.favoriteTarget == false)
    #expect(afterExternalChange.favoriteWritebackState == .failed)
}
