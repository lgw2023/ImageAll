import Foundation
import SQLite3
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

@Test func explicitShareScopeFiltersPrivateFactsAndSurvivesPermissionContraction() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    try await store.observe([
        LocalObservedAsset(localIdentifier: "selected", kind: "image", creationDate: nil, isFavorite: false),
        LocalObservedAsset(localIdentifier: "private", kind: "video", creationDate: nil, isFavorite: true),
    ])
    let selected = try #require(await store.assets(visibleIdentifiers: ["selected"]).first)
    let privateAsset = try #require(await store.assets(visibleIdentifiers: ["private"]).first)
    let usedTag = try await store.createTag(name: "visible tag")
    let privateTag = try await store.createTag(name: "private tag")
    let collection = try await store.createCollection(name: "visible collection")
    try await store.setDecision(assetID: selected.id, tagID: usedTag, decision: .accepted)
    try await store.setDecision(assetID: privateAsset.id, tagID: privateTag, decision: .rejected)
    try await store.setMembership(assetID: selected.id, collectionID: collection, included: true)
    try await store.setFavoriteTarget(assetID: selected.id, isFavorite: true)

    let defaultSnapshot = try await store.sharedSnapshot(visibleIdentifiers: ["selected", "private"])
    #expect(defaultSnapshot.assets.isEmpty)
    #expect(defaultSnapshot.scopeRevision == 0)

    try await store.setShared(assetID: selected.id, shared: true)
    #expect(try await store.assets(visibleIdentifiers: ["selected"]).first?.isShared == true)
    #expect(try await store.sharedSelections().map(\.id) == [selected.id])
    let shared = try await store.sharedSnapshot(visibleIdentifiers: ["selected", "private"])
    #expect(shared.assets.count == 1)
    #expect(shared.assets.first?.id == selected.id)
    #expect(shared.assets.first?.observedFavorite == false)
    #expect(shared.assets.first?.favoriteTarget == true)
    #expect(shared.assets.first?.tagDecisions.map(\.tagName) == ["visible tag"])
    #expect(shared.assets.first?.collections.map(\.collectionName) == ["visible collection"])
    #expect(shared.scopeRevision == 1)
    #expect(shared.selectedAssetIDs == [selected.id])

    let firstAttempt = try await store.prepareSharedSnapshot(visibleIdentifiers: ["selected"])
    #expect(firstAttempt.snapshotSequence == 1)
    let secondAttempt = try await store.prepareSharedSnapshot(visibleIdentifiers: [])
    #expect(secondAttempt.snapshotSequence == 2)
    #expect(secondAttempt.assets.isEmpty)
    #expect(secondAttempt.selectedAssetIDs == [selected.id])

    let reopened = try LocalLibraryStore(url: url)
    #expect(try await reopened.isShared(assetID: selected.id))
    #expect(try await reopened.prepareSharedSnapshot(visibleIdentifiers: []).snapshotSequence == 2)
    #expect(try await reopened.sharedSnapshot(visibleIdentifiers: []).assets.isEmpty)
    #expect(try await reopened.sharedSnapshot(visibleIdentifiers: ["selected"]).assets.count == 1)
    try await reopened.setShared(assetID: selected.id, shared: false)
    #expect(try await reopened.sharedSelections().isEmpty)
    let revoked = try await reopened.sharedSnapshot(visibleIdentifiers: ["selected"])
    #expect(revoked.assets.isEmpty)
    #expect(revoked.scopeRevision == 2)
}

@Test func sharedSnapshotRetryKeepsPayloadAndWatermarkAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    try await store.observe([
        LocalObservedAsset(localIdentifier: "selected", kind: "image", creationDate: nil, isFavorite: false)
    ])
    let asset = try #require(await store.assets(visibleIdentifiers: ["selected"]).first)
    let tag = try await store.createTag(name: "shared")
    try await store.setShared(assetID: asset.id, shared: true)
    try await store.setDecision(assetID: asset.id, tagID: tag, decision: .accepted)
    let first = try await store.prepareSharedSnapshot(visibleIdentifiers: ["selected"])
    try await store.setDecision(assetID: asset.id, tagID: tag, decision: .rejected)
    let reopened = try LocalLibraryStore(url: url)
    let retry = try await reopened.prepareSharedSnapshot(visibleIdentifiers: ["selected"])
    #expect(retry.snapshotSequence == first.snapshotSequence)
    #expect(retry.outboxWatermark == first.outboxWatermark)
    #expect(retry.assets.first?.tagDecisions.first?.decision == .accepted)
    try await reopened.acknowledgeSharedSnapshot(
        retry, hostID: UUID(), deviceID: UUID(), importedAssetIDs: [asset.id]
    )
    let pending = try await reopened.pendingSharedOperations()
    #expect(pending.count == 1)
    #expect(pending.first?.value == LocalDecision.rejected.rawValue)
    let fresh = try await reopened.prepareSharedSnapshot(visibleIdentifiers: ["selected"])
    #expect(fresh.snapshotSequence == first.snapshotSequence + 1)
    #expect(fresh.assets.first?.tagDecisions.first?.decision == .rejected)
}

@Test func sharedOutboxContainsOnlyExplicitlySharedAssetEditsAndSurvivesRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    try await store.observe([
        LocalObservedAsset(localIdentifier: "shared", kind: "image", creationDate: nil, isFavorite: false),
        LocalObservedAsset(localIdentifier: "private", kind: "image", creationDate: nil, isFavorite: false),
    ])
    let shared = try #require(await store.assets(visibleIdentifiers: ["shared"]).first)
    let privateAsset = try #require(await store.assets(visibleIdentifiers: ["private"]).first)
    let tagID = try await store.createTag(name: "家庭")
    let collectionID = try await store.createCollection(name: "周末")

    try await store.setDecision(assetID: privateAsset.id, tagID: tagID, decision: .accepted)
    try await store.setDecision(assetID: shared.id, tagID: tagID, decision: .rejected)
    #expect(try await store.pendingSharedOperations().isEmpty)

    try await store.setShared(assetID: shared.id, shared: true)
    try await store.setDecision(assetID: shared.id, tagID: tagID, decision: .accepted)
    try await store.setMembership(assetID: shared.id, collectionID: collectionID, included: true)
    try await store.setFavoriteTarget(assetID: shared.id, isFavorite: true)
    try await store.setFavoriteTarget(assetID: privateAsset.id, isFavorite: true)
    let pending = try await store.pendingSharedOperations()
    #expect(pending.count == 3)
    #expect(pending.map(\.field) == ["tag.\(tagID.uuidString)", "collection.\(collectionID.uuidString)", "favorite.target"])
    #expect(pending.map(\.referenceName) == ["家庭", "周末", nil])
    #expect(pending.allSatisfy { $0.assetID == shared.id && $0.scopeRevision == 1 })
    #expect(Set(pending.map(\.id)).count == 3)
    let localIDs = Set(try await store.pendingOperations().map(\.id))
    #expect(Set(pending.map(\.id)).isSubset(of: localIDs))

    let reopened = try LocalLibraryStore(url: url)
    #expect(try await reopened.pendingSharedOperations().map(\.id) == pending.map(\.id))
    try await reopened.setShared(assetID: shared.id, shared: false)
    #expect(try await reopened.pendingSharedOperations().isEmpty)
    #expect(try await reopened.decisions(assetID: shared.id)[tagID] == .accepted)
    try await reopened.setShared(assetID: shared.id, shared: true)
    #expect(try await reopened.pendingSharedOperations().isEmpty)
    try await reopened.setDecision(assetID: shared.id, tagID: tagID, decision: .cleared)
    #expect(try await reopened.pendingSharedOperations().count == 1)
}

@Test func sharedOutboxWriteFailureRollsBackTheLocalFact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    try await store.observe([
        LocalObservedAsset(localIdentifier: "fixture", kind: "image", creationDate: nil, isFavorite: false)
    ])
    let asset = try #require(await store.assets(visibleIdentifiers: ["fixture"]).first)
    let tagID = try await store.createTag(name: "test")
    try await store.setShared(assetID: asset.id, shared: true)
    let outboxCount = try await store.pendingOperations().count

    var rawDB: OpaquePointer?
    #expect(sqlite3_open(url.path, &rawDB) == SQLITE_OK)
    defer { if let rawDB { sqlite3_close(rawDB) } }
    #expect(sqlite3_exec(rawDB, "DROP TABLE shared_outbox", nil, nil, nil) == SQLITE_OK)

    do {
        try await store.setDecision(assetID: asset.id, tagID: tagID, decision: .accepted)
        Issue.record("a shared outbox failure must reject the whole local fact transaction")
    } catch {
        #expect(try await store.decisions(assetID: asset.id).isEmpty)
        #expect(try await store.pendingOperations().count == outboxCount)
    }
}

@Test func sharedTagDeliveryFreezesBaseAndKeepsConflictsAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let hostID = UUID()
    let deviceID = UUID()
    let store = try LocalLibraryStore(url: url)
    try await store.observe([
        LocalObservedAsset(localIdentifier: "selected", kind: "image", creationDate: nil, isFavorite: false)
    ])
    let asset = try #require(await store.assets(visibleIdentifiers: ["selected"]).first)
    let tagID = try await store.createTag(name: "家庭")
    try await store.setShared(assetID: asset.id, shared: true)
    try await store.setDecision(assetID: asset.id, tagID: tagID, decision: .accepted)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["selected"])
    #expect(snapshot.outboxWatermark > 0)
    try await store.acknowledgeSharedSnapshot(
        snapshot, hostID: hostID, deviceID: deviceID, importedAssetIDs: [asset.id]
    )
    #expect(try await store.pendingSharedOperations().isEmpty)

    try await store.setDecision(assetID: asset.id, tagID: tagID, decision: .rejected)
    let pending = try #require(await store.pendingSharedOperations().first)
    let prepared = try #require(await store.prepareSharedTagOperation(
        id: pending.id, hostID: hostID, deviceID: deviceID
    ))
    #expect(prepared.baseRevision == 1)
    #expect(prepared.operation.id == pending.id)
    #expect(prepared.operation.sequence == pending.sequence)

    let reopened = try LocalLibraryStore(url: url)
    let retry = try #require(await reopened.prepareSharedTagOperation(
        id: pending.id, hostID: hostID, deviceID: deviceID
    ))
    #expect(retry.baseRevision == 1)
    #expect(retry.operation.id == pending.id)
    try await reopened.recordSharedTagResult(
        operationID: pending.id, hostID: hostID, deviceID: deviceID,
        disposition: .conflict, fieldRevision: 2, currentDecision: .accepted
    )
    #expect(try await reopened.pendingSharedOperations().first?.isConflicted == true)
    do {
        _ = try await reopened.prepareSharedTagOperation(
            id: pending.id, hostID: hostID, deviceID: deviceID
        )
        Issue.record("conflicted operation must remain pending for explicit resolution")
    } catch LocalLibraryError.syncConflictRequiresResolution {
        #expect(try await reopened.pendingSharedOperations().count == 1)
    }
}

@Test func sharedTagAppliedReceiptAdvancesNextFieldBaseWithoutDeletingAudit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    try await store.observe([
        LocalObservedAsset(localIdentifier: "selected", kind: "image", creationDate: nil, isFavorite: false)
    ])
    let asset = try #require(await store.assets(visibleIdentifiers: ["selected"]).first)
    let tagID = try await store.createTag(name: "旅行")
    let hostID = UUID()
    let deviceID = UUID()
    try await store.setShared(assetID: asset.id, shared: true)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["selected"])
    try await store.acknowledgeSharedSnapshot(
        snapshot, hostID: hostID, deviceID: deviceID, importedAssetIDs: [asset.id]
    )
    try await store.setDecision(assetID: asset.id, tagID: tagID, decision: .accepted)
    let first = try #require(await store.pendingSharedOperations().first)
    let prepared = try #require(await store.prepareSharedTagOperation(
        id: first.id, hostID: hostID, deviceID: deviceID
    ))
    #expect(prepared.baseRevision == 0)
    let auditCount = try await store.pendingOperations().count
    try await store.recordSharedTagResult(
        operationID: first.id, hostID: hostID, deviceID: deviceID,
        disposition: .applied, fieldRevision: 1, currentDecision: .accepted
    )
    #expect(try await store.pendingSharedOperations().isEmpty)
    #expect(try await store.pendingOperations().count == auditCount)
    try await store.setDecision(assetID: asset.id, tagID: tagID, decision: .rejected)
    let second = try #require(await store.pendingSharedOperations().first)
    let secondPrepared = try #require(await store.prepareSharedTagOperation(
        id: second.id, hostID: hostID, deviceID: deviceID
    ))
    #expect(secondPrepared.baseRevision == 1)
}
