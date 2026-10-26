import Foundation
import Testing
@testable import ImageAllLocalLibrary

private actor SyntheticTransferVisibility {
    var visible: Set<String> = ["synthetic"]
    private(set) var calls = 0
    func fetch() -> Set<String> { calls += 1; return visible }
    func revoke() { visible = [] }
}

@Test func transferVisibilityCacheRechecksBoundariesChangesAndSelectionRevision() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    try await store.observe([.init(localIdentifier: "synthetic", kind: "image", creationDate: nil, isFavorite: false)])
    let asset = try #require(await store.assets(visibleIdentifiers: ["synthetic"]).first)
    try await store.setShared(assetID: asset.id, shared: true)
    let snapshot = try await store.sharedSnapshot(visibleIdentifiers: ["synthetic"])
    let generation = LocalLibraryVisibilityGeneration(), source = SyntheticTransferVisibility()
    let validator = LocalSharedSnapshotScopeValidator(snapshot: snapshot, store: store, generation: generation,
        visibleIdentifiers: { await source.fetch() })
    for _ in 0..<100 { try await validator.validate(permissionVersion: 3) }
    #expect(await source.calls == 1)
    try await validator.validate(permissionVersion: 3, forceRefresh: true)
    try await validator.validate(permissionVersion: 4)
    #expect(await source.calls == 3)
    await source.revoke()
    generation.invalidate()
    await #expect(throws: LocalLibraryError.syncIdentityChanged) { try await validator.validate(permissionVersion: 4) }
    // Revocation never removes the retained selection.
    #expect(try await store.sharedSelections().count == 1)
    try await store.setShared(assetID: asset.id, shared: false)
    try await store.setShared(assetID: asset.id, shared: true)
    await #expect(throws: LocalLibraryError.syncIdentityChanged) { try await validator.validate(permissionVersion: 4) }
}

@Test func transferVisibilityChangeDuringFetchFailsClosed() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    let snapshot = try await store.sharedSnapshot(visibleIdentifiers: [])
    let generation = LocalLibraryVisibilityGeneration()
    let validator = LocalSharedSnapshotScopeValidator(snapshot: snapshot, store: store, generation: generation,
        visibleIdentifiers: { generation.invalidate(); return [] })
    await #expect(throws: LocalLibraryError.syncIdentityChanged) { try await validator.validate(permissionVersion: 3) }
}
