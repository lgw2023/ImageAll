import Foundation
import Testing
@testable import ImageAllLocalLibrary

@Test func unavailableSelectionAllowsVisibleTransferButPreventsCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    let locators: Set<String> = ["available", "temporarily-unavailable"]
    try await store.observe(locators.map {
        .init(localIdentifier: $0, kind: "image", creationDate: nil, isFavorite: false)
    })
    for asset in try await store.assets(visibleIdentifiers: locators) {
        try await store.setShared(assetID: asset.id, shared: true)
    }
    let partial = try await store.migrationFactSnapshot(visibleIdentifiers: ["available"])
    let availability = try LocalMigrationAvailability(snapshot: partial)
    #expect(availability.selectedCount == 2)
    #expect(availability.availableCount == 1)
    #expect(availability.pendingCount == 1)
    #expect(throws: LocalLibraryError.migrationScopeIncomplete) { try availability.requireComplete() }
    let validator = LocalSharedSnapshotScopeValidator(snapshot: partial, store: store,
        generation: LocalLibraryVisibilityGeneration(), visibleIdentifiers: { ["available"] })
    try await validator.validate(permissionVersion: 3)
    #expect(try await store.sharedSelections().count == 2)
    let restored = try await store.migrationFactSnapshot(visibleIdentifiers: locators)
    try LocalMigrationAvailability(snapshot: restored).requireComplete()
    #expect(restored.scopeRevision == partial.scopeRevision)
    #expect(restored.selectedAssetIDs == partial.selectedAssetIDs)
}

@Test func noVisibleAssetsCannotCertifyCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    let empty = try await store.migrationFactSnapshot(visibleIdentifiers: [])
    let availability = try LocalMigrationAvailability(snapshot: empty)
    #expect(availability.availableCount == 0)
    #expect(throws: LocalLibraryError.migrationScopeIncomplete) { try availability.requireComplete() }
}

@Test func explicitVisibleArchiveProjectionPreservesRetainedSelectionAndFacts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    let locators: Set<String> = ["received", "unavailable"]
    try await store.observe(locators.map {
        .init(localIdentifier: $0, kind: "image", creationDate: nil, isFavorite: true)
    })
    for asset in try await store.assets(visibleIdentifiers: locators) {
        try await store.setShared(assetID: asset.id, shared: true)
    }
    let original = try await store.migrationFactSnapshot(visibleIdentifiers: ["received"])
    let ids = Set(original.assets.map(\.id))
    #expect(throws: LocalLibraryError.migrationScopeIncomplete) {
        try original.archiveSnapshot(mediaIDs: ids, allowVerifiedSubset: false)
    }
    let archived = try original.archiveSnapshot(mediaIDs: ids, allowVerifiedSubset: true)
    #expect(archived.assets == original.assets)
    #expect(Set(archived.selectedAssetIDs) == ids)
    #expect(original.selectedAssetIDs.count == 2)
    #expect(try await store.sharedSelections().count == 2)
    #expect(archived.sourceEpoch == original.sourceEpoch)
    #expect(archived.scopeRevision == original.scopeRevision)
    #expect(throws: LocalLibraryError.migrationScopeIncomplete) {
        try original.archiveSnapshot(mediaIDs: [UUID()], allowVerifiedSubset: true)
    }
}
