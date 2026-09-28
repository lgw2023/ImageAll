import Foundation
import SQLite3
import Testing
@testable import ImageAllLocalLibrary

enum CollectionRecoveryScenario: CaseIterable, Sendable {
    case acceptMac, keepPhone, changedScope, historyRecovery, missingHistory, historyScopeRace
}

@Test(arguments: CollectionRecoveryScenario.allCases, [false, true])
func explicitCollectionRenameRecoveryKeepsIdentityChecks(scenario: CollectionRecoveryScenario, legacy: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    var store = try LocalLibraryStore(url: url)
    try await store.observe([.init(localIdentifier: "shared", kind: "image", creationDate: nil, isFavorite: false)])
    let asset = try #require(await store.assets(visibleIdentifiers: ["shared"]).first)
    let localID = try await store.createCollection(name: "Journey")
    let remoteID = UUID(), hostID = UUID(), deviceID = UUID()
    try await store.setShared(assetID: asset.id, shared: true)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["shared"])
    try await store.acknowledgeSharedSnapshot(snapshot, hostID: hostID, deviceID: deviceID, importedAssetIDs: [asset.id])
    let created = LocalSharedCollectionChange(sequence: 1, assetID: asset.id, collectionID: remoteID,
                                             collectionName: "Journey", included: true, fieldRevision: 1)
    do {
        _ = try await store.applySharedCollectionChanges(
            hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
            scopeRevision: snapshot.scopeRevision, afterCursor: 0, changes: [created], nextCursor: 1
        )
        Issue.record("an alias must require confirmation")
    } catch LocalLibraryError.syncRemoteCollectionAliasRequired(let candidate) {
        try await store.confirmSharedCollectionAlias(candidate)
    }
    _ = try await store.applySharedCollectionChanges(
        hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
        scopeRevision: snapshot.scopeRevision, afterCursor: 0, changes: [created], nextCursor: 1
    )
    try await store.setMembership(assetID: asset.id, collectionID: localID, included: false)
    let pending = try #require(await store.pendingSharedOperations().first)
    _ = try await store.prepareSharedCollectionOperation(id: pending.id, hostID: hostID, deviceID: deviceID)
    try await store.recordSharedCollectionResult(
        operationID: pending.id, hostID: hostID, deviceID: deviceID, disposition: .conflict,
        fieldRevision: 1, currentIncluded: true, conflictReason: .collectionIdentity
    )
    #expect(try await store.pendingSharedOperations().first?.verifiedCollectionRename == nil)
    do {
        _ = try await store.resolveSharedCollectionConflict(operationID: pending.id, resolution: .keepPhone)
        Issue.record("identity conflict without rename proof must remain pending")
    } catch LocalLibraryError.syncConflictDetailsUnavailable {}
    if legacy {
        var rawDB: OpaquePointer?
        #expect(sqlite3_open(url.path, &rawDB) == SQLITE_OK)
        #expect(sqlite3_exec(rawDB, "DROP TABLE shared_collection_delivery_identity", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(rawDB)
        store = try LocalLibraryStore(url: url)
    }
    for (sequence, oldName, newName) in [(Int64(2), "Journey", "Trip"), (Int64(3), "Trip", "Holiday")] {
        _ = try await store.applySharedCollectionChanges(
            hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
            scopeRevision: snapshot.scopeRevision, afterCursor: sequence - 1,
            changes: [.init(sequence: sequence, assetID: asset.id, collectionID: remoteID,
                            collectionName: newName, included: true, fieldRevision: 1, renamedFrom: oldName)],
            nextCursor: sequence
        )
    }
    store = try LocalLibraryStore(url: url)
    if scenario == .historyRecovery || scenario == .missingHistory || scenario == .historyScopeRace {
        // An older app already consumed these renames, leaving no recovery proof.
        var rawDB: OpaquePointer?
        #expect(sqlite3_open(url.path, &rawDB) == SQLITE_OK)
        #expect(sqlite3_exec(rawDB, "DROP TABLE shared_collection_rename_recovery", nil, nil, nil) == SQLITE_OK)
        if legacy {
            #expect(sqlite3_exec(rawDB, "DROP TABLE shared_collection_delivery_identity", nil, nil, nil) == SQLITE_OK)
        }
        sqlite3_close(rawDB)
        store = try LocalLibraryStore(url: url)
        #expect(try await store.pendingSharedOperations().first?.verifiedCollectionRename == nil)
        try await store.observe([.init(localIdentifier: "race", kind: "image", creationDate: nil, isFavorite: false)])
        let raceAsset = try #require(await store.assets(visibleIdentifiers: ["race"]).first)
        let recoveryStore = store
        do {
            let name = try await recoveryStore.recoverSharedCollectionRenameHistory(operationID: pending.id) {
                epoch, scope, cursor in
                if scenario == .historyScopeRace, cursor == 1 {
                    try await recoveryStore.setShared(assetID: raceAsset.id, shared: true)
                }
                let change: LocalSharedCollectionChange
                switch cursor {
                case 0:
                    change = .init(sequence: 1, assetID: asset.id, collectionID: remoteID,
                                   collectionName: "Journey", included: true, fieldRevision: 1,
                                   createdCollectionID: scenario == .missingHistory ? nil : remoteID)
                case 1:
                    change = .init(sequence: 2, assetID: asset.id, collectionID: remoteID,
                                   collectionName: "Trip", included: true, fieldRevision: 1, renamedFrom: "Journey")
                case 2:
                    change = .init(sequence: 3, assetID: asset.id, collectionID: remoteID,
                                   collectionName: "Holiday", included: true, fieldRevision: 1, renamedFrom: "Trip")
                default: throw LocalLibraryError.syncIdentityChanged
                }
                return .init(hostID: hostID, deviceID: deviceID, sourceEpoch: epoch, scopeRevision: scope,
                             changes: [change], nextCursor: cursor + 1)
            }
            #expect(scenario == .historyRecovery)
            #expect(name == "Holiday")
        } catch {
            if scenario == .historyRecovery { throw error }
            switch error {
            case LocalLibraryError.syncRemoteCollectionMismatch:
                #expect(scenario == .missingHistory)
            case LocalLibraryError.syncConflictDetailsUnavailable, LocalLibraryError.syncIdentityChanged:
                #expect(scenario == .historyScopeRace)
            default: throw error
            }
            #expect(try await recoveryStore.pendingSharedOperations().first?.verifiedCollectionRename == nil)
            #expect(try await recoveryStore.sharedCollectionChangeCursor() == 3)
            return
        }
        #expect(try await store.sharedCollectionChangeCursor() == 3)
        store = try LocalLibraryStore(url: url)
    }
    let conflict = try #require(await store.pendingSharedOperations().first)
    #expect(conflict.isConflicted)
    #expect(conflict.conflictReason == .collectionIdentity)
    #expect(conflict.verifiedCollectionRename == "Holiday")
    if scenario == .changedScope {
        try await store.observe([.init(localIdentifier: "another", kind: "image", creationDate: nil, isFavorite: false)])
        let another = try #require(await store.assets(visibleIdentifiers: ["another"]).first)
        try await store.setShared(assetID: another.id, shared: true)
        let nextScope = try await store.prepareSharedSnapshot(visibleIdentifiers: ["shared", "another"])
        try await store.acknowledgeSharedSnapshot(nextScope, hostID: hostID, deviceID: deviceID, importedAssetIDs: [another.id])
        #expect(try await store.pendingSharedOperations().first?.verifiedCollectionRename == nil)
        do {
            _ = try await store.resolveSharedCollectionConflict(operationID: pending.id, resolution: .keepPhone)
            Issue.record("rename proof from an old share scope must not resolve the conflict")
        } catch LocalLibraryError.syncConflictDetailsUnavailable {}
        return
    }
    let newID = try await store.resolveSharedCollectionConflict(
        operationID: pending.id, resolution: scenario == .keepPhone || scenario == .historyRecovery ? .keepPhone : .acceptMac
    )
    if scenario == .keepPhone || scenario == .historyRecovery {
        let id = try #require(newID)
        #expect(id != pending.id)
        let request = try #require(await store.prepareSharedCollectionOperation(id: id, hostID: hostID, deviceID: deviceID))
        #expect(request.collectionID == remoteID)
        #expect(request.collectionName == "Holiday")
        #expect(request.baseRevision == 1)
        #expect(!request.included)
    } else {
        #expect(newID == nil)
        #expect(try await store.pendingSharedOperations().isEmpty)
        #expect(try await store.memberships(assetID: asset.id).contains(localID))
    }
}

@Test func migrationCheckpointRequiresVisibleAcknowledgedConflictFreeScope() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    try await store.observe([
        LocalObservedAsset(
            localIdentifier: "selected", kind: "image",
            creationDate: nil, isFavorite: false
        )
    ])
    let asset = try #require(await store.assets(visibleIdentifiers: ["selected"]).first)
    try await store.setShared(assetID: asset.id, shared: true)
    do {
        _ = try await store.migrationCompletionCheckpoint(visibleIdentifiers: ["selected"])
        Issue.record("unacknowledged scope produced a completion checkpoint")
    } catch LocalLibraryError.syncScopeNotAcknowledged { }

    let hostID = UUID()
    let deviceID = UUID()
    let directory = try await store.prepareSharedSnapshot(visibleIdentifiers: ["selected"])
    try await store.acknowledgeSharedSnapshot(
        directory, hostID: hostID, deviceID: deviceID,
        importedAssetIDs: [asset.id]
    )
    do {
        _ = try await store.migrationCompletionCheckpoint(visibleIdentifiers: [])
        Issue.record("permission-reduced scope produced a completion checkpoint")
    } catch LocalLibraryError.migrationScopeIncomplete { }

    let candidate = try await store.migrationCompletionCheckpoint(
        visibleIdentifiers: ["selected"]
    )
    #expect(candidate.checkpoint.hostID == hostID)
    #expect(candidate.checkpoint.deviceID == deviceID)
    #expect(candidate.checkpoint.acknowledgedScopeRevision == candidate.snapshot.scopeRevision)
    #expect(candidate.checkpoint.acknowledgedSnapshotSequence == directory.snapshotSequence)
    #expect(candidate.snapshot.snapshotSequence > directory.snapshotSequence)
    #expect(candidate.snapshot.selectedAssetIDs == [asset.id])

    let tagID = try await store.createTag(name: "later")
    try await store.setDecision(assetID: asset.id, tagID: tagID, decision: .accepted)
    do {
        _ = try await store.migrationCompletionCheckpoint(visibleIdentifiers: ["selected"])
        Issue.record("pending shared edit produced a completion checkpoint")
    } catch LocalLibraryError.migrationSyncPending { }
}

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
    let firstIntent = try await store.prepareFavoriteWriteback(assetID: asset.id, expectedTarget: true)
    try await store.finishFavoriteWriteback(firstIntent, observedValue: nil)
    #expect(try await store.assets(visibleIdentifiers: ["fixture-favorite"]).first?.favoriteWritebackState == .failed)

    try await store.setFavoriteTarget(assetID: asset.id, isFavorite: false)
    try await store.finishFavoriteWriteback(firstIntent, observedValue: true)
    let afterLateReply = try #require(await store.assets(visibleIdentifiers: ["fixture-favorite"]).first)
    #expect(afterLateReply.favoriteTarget == false)
    #expect(afterLateReply.observedFavorite == false)
    #expect(afterLateReply.favoriteWritebackState == .pending)

    let secondIntent = try await store.prepareFavoriteWriteback(assetID: asset.id, expectedTarget: false)
    try await store.finishFavoriteWriteback(secondIntent, observedValue: false)
    #expect(try await store.assets(visibleIdentifiers: ["fixture-favorite"]).first?.favoriteWritebackState == .matched)

    try await store.observe([LocalObservedAsset(
        localIdentifier: "fixture-favorite", kind: "image", creationDate: nil, isFavorite: true
    )])
    let afterExternalChange = try #require(await store.assets(visibleIdentifiers: ["fixture-favorite"]).first)
    #expect(afterExternalChange.observedFavorite == true)
    #expect(afterExternalChange.favoriteTarget == false)
    #expect(afterExternalChange.favoriteWritebackState == .failed)
}

@Test func sharedFavoriteTargetHasDurableVersionAndExplicitConflictResolution() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    try await store.observe([
        LocalObservedAsset(localIdentifier: "shared", kind: "image", creationDate: nil, isFavorite: false)
    ])
    let asset = try #require(await store.assets(visibleIdentifiers: ["shared"]).first)
    let hostID = UUID()
    let deviceID = UUID()
    try await store.setShared(assetID: asset.id, shared: true)
    try await store.setFavoriteTarget(assetID: asset.id, isFavorite: true)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["shared"])
    try await store.acknowledgeSharedSnapshot(
        snapshot, hostID: hostID, deviceID: deviceID, importedAssetIDs: [asset.id]
    )
    #expect(try await store.pendingSharedOperations().isEmpty)
    try await store.setFavoriteTarget(assetID: asset.id, isFavorite: false)
    let first = try #require(await store.pendingSharedOperations().first)
    let prepared = try #require(await store.prepareSharedFavoriteOperation(
        id: first.id, hostID: hostID, deviceID: deviceID
    ))
    #expect(prepared.baseRevision == 1)
    #expect(prepared.target == false)
    let reopened = try LocalLibraryStore(url: url)
    let retry = try #require(await reopened.prepareSharedFavoriteOperation(
        id: first.id, hostID: hostID, deviceID: deviceID
    ))
    #expect(retry.operation.id == first.id)
    #expect(retry.baseRevision == 1)
    try await reopened.recordSharedFavoriteResult(
        operationID: first.id, hostID: hostID, deviceID: deviceID,
        disposition: .applied, fieldRevision: 2, currentTarget: false
    )
    #expect(try await reopened.pendingSharedOperations().isEmpty)
    try await reopened.setFavoriteTarget(assetID: asset.id, isFavorite: true)
    let second = try #require(await reopened.pendingSharedOperations().first)
    let secondPrepared = try #require(await reopened.prepareSharedFavoriteOperation(
        id: second.id, hostID: hostID, deviceID: deviceID
    ))
    #expect(secondPrepared.baseRevision == 2)
    try await reopened.recordSharedFavoriteResult(
        operationID: second.id, hostID: hostID, deviceID: deviceID,
        disposition: .conflict, fieldRevision: 3, currentTarget: false
    )
    let conflict = try #require(await reopened.pendingSharedOperations().first)
    #expect(conflict.isConflicted)
    #expect(conflict.localCurrentFavoriteTarget == true)
    let auditCount = try await reopened.pendingOperations().count
    _ = try await reopened.resolveSharedFavoriteConflict(
        operationID: second.id, resolution: .acceptMac
    )
    let resolved = try #require(await reopened.assets(visibleIdentifiers: ["shared"]).first)
    #expect(resolved.favoriteTarget == false)
    #expect(resolved.favoriteWritebackState == .matched)
    #expect(try await reopened.pendingSharedOperations().isEmpty)
    #expect(try await reopened.pendingOperations().count == auditCount + 1)
    try await reopened.setFavoriteTarget(assetID: asset.id, isFavorite: true)
    let third = try #require(await reopened.pendingSharedOperations().first)
    let rebased = try #require(await reopened.prepareSharedFavoriteOperation(
        id: third.id, hostID: hostID, deviceID: deviceID
    ))
    #expect(rebased.baseRevision == 3)
    try await reopened.recordSharedFavoriteResult(
        operationID: third.id, hostID: hostID, deviceID: deviceID,
        disposition: .conflict, fieldRevision: 4, currentTarget: false
    )
    let keepID = try #require(await reopened.resolveSharedFavoriteConflict(
        operationID: third.id, resolution: .keepPhone
    ))
    let keep = try #require(await reopened.prepareSharedFavoriteOperation(
        id: keepID, hostID: hostID, deviceID: deviceID
    ))
    #expect(keep.baseRevision == 4)
    #expect(keep.target == true)
}

@Test func macFavoriteChangesCommitTargetWritebackAndCursorWithoutEcho() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    try await store.observe([
        LocalObservedAsset(localIdentifier: "shared", kind: "image", creationDate: nil, isFavorite: false)
    ])
    let asset = try #require(await store.assets(visibleIdentifiers: ["shared"]).first)
    let hostID = UUID()
    let deviceID = UUID()
    try await store.setShared(assetID: asset.id, shared: true)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["shared"])
    try await store.acknowledgeSharedSnapshot(
        snapshot, hostID: hostID, deviceID: deviceID, importedAssetIDs: [asset.id]
    )
    let auditBefore = try await store.pendingOperations().count
    let first = try await store.applySharedFavoriteChanges(
        hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
        scopeRevision: snapshot.scopeRevision, afterCursor: 0,
        changes: [.init(sequence: 1, assetID: asset.id, target: true, fieldRevision: 1)],
        nextCursor: 1
    )
    #expect(first.applied == 1)
    #expect(first.conflicts == 0)
    #expect(try await store.migrationFactSnapshot(visibleIdentifiers: ["shared"]).auditRecords?.last?.origin == .remoteSync)
    let changed = try #require(await store.assets(visibleIdentifiers: ["shared"]).first)
    #expect(changed.favoriteTarget == true)
    #expect(changed.observedFavorite == false)
    #expect(changed.favoriteWritebackState == .pending)
    #expect(try await store.pendingSharedOperations().isEmpty)
    #expect(try await store.pendingOperations().count == auditBefore + 1)
    let reopened = try LocalLibraryStore(url: url)
    #expect(try await reopened.sharedFavoriteChangeCursor() == 1)
    let duplicate = try await reopened.applySharedFavoriteChanges(
        hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
        scopeRevision: snapshot.scopeRevision, afterCursor: 1,
        changes: [], nextCursor: 1
    )
    #expect(duplicate.applied == 0)
    do {
        _ = try await reopened.applySharedFavoriteChanges(
            hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
            scopeRevision: snapshot.scopeRevision, afterCursor: 1,
            changes: [.init(sequence: 2, assetID: UUID(), target: false, fieldRevision: 2)],
            nextCursor: 2
        )
        Issue.record("unknown asset must roll back the whole page")
    } catch LocalLibraryError.unknownAsset {
        #expect(try await reopened.sharedFavoriteChangeCursor() == 1)
    }
    try await reopened.setFavoriteTarget(assetID: asset.id, isFavorite: false)
    let pending = try #require(await reopened.pendingSharedOperations().first)
    let conflict = try await reopened.applySharedFavoriteChanges(
        hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
        scopeRevision: snapshot.scopeRevision, afterCursor: 1,
        changes: [.init(sequence: 2, assetID: asset.id, target: true, fieldRevision: 2)],
        nextCursor: 2
    )
    #expect(conflict.conflicts == 1)
    #expect(try await reopened.sharedFavoriteChangeCursor() == 2)
    #expect(try await reopened.pendingSharedOperations().first?.id == pending.id)
    #expect(try await reopened.pendingSharedOperations().first?.isConflicted == true)
    #expect(try await reopened.assets(visibleIdentifiers: ["shared"]).first?.favoriteTarget == false)
    _ = try await reopened.resolveSharedFavoriteConflict(operationID: pending.id, resolution: .acceptMac)
    #expect(try await reopened.migrationFactSnapshot(visibleIdentifiers: ["shared"]).auditRecords?.last?.origin == .conflictResolution)
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
    #expect(try await store.pendingSharedSnapshot() == firstAttempt)
    let secondAttempt = try await store.prepareSharedSnapshot(visibleIdentifiers: [])
    #expect(secondAttempt.snapshotSequence == 2)
    #expect(secondAttempt.assets.isEmpty)
    #expect(secondAttempt.selectedAssetIDs == [selected.id])

    let reopened = try LocalLibraryStore(url: url)
    #expect(try await reopened.pendingSharedSnapshot() == secondAttempt)
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

@Test func migrationAuditPreservesOnlySelectedVisibleAssetHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    try await store.observe(["selected", "private"].map {
        LocalObservedAsset(localIdentifier: $0, kind: "image", creationDate: nil, isFavorite: false)
    })
    let assets = try await store.assets(visibleIdentifiers: ["selected", "private"])
    let selected = try #require(assets.first { $0.localIdentifier == "selected" })
    for asset in assets { try await store.setFavoriteTarget(assetID: asset.id, isFavorite: true) }
    try await store.setShared(assetID: selected.id, shared: true)
    let network = try await store.prepareSharedSnapshot(visibleIdentifiers: ["selected", "private"])
    #expect(network.auditRecords == nil)
    let frozen = try await store.migrationFactSnapshot(visibleIdentifiers: ["selected", "private"])
    #expect(frozen.auditRecords?.count == 1)
    #expect(frozen.auditRecords?.first?.assetID == selected.id)
    #expect(frozen.auditRecords?.first?.value == "1")
    #expect(frozen.auditRecords?.first?.origin == .localEdit)
    try await store.setFavoriteTarget(assetID: selected.id, isFavorite: false)
    let newer = try await store.migrationFactSnapshot(visibleIdentifiers: ["selected"])
    #expect(newer.auditRecords?.map(\.value) == ["1", "0"])
    #expect(newer.auditRecords?.allSatisfy { $0.sequence <= newer.outboxWatermark } == true)
    #expect(try await store.migrationFactSnapshot(visibleIdentifiers: []).auditRecords == [])
    #expect(try await store.pendingSharedSnapshot()?.auditRecords == nil)
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
    try await store.validateSharedSnapshotScope(first, visibleIdentifiers: ["selected"])
    await #expect(throws: LocalLibraryError.syncIdentityChanged) {
        try await store.validateSharedSnapshotScope(first, visibleIdentifiers: [])
    }
    try await store.setDecision(assetID: asset.id, tagID: tag, decision: .rejected)
    let facts = try await store.migrationFactSnapshot(visibleIdentifiers: ["selected"])
    #expect(facts.snapshotSequence > first.snapshotSequence)
    #expect(facts.assets.first?.tagDecisions.first?.decision == .rejected)
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
    #expect(fresh.snapshotSequence == facts.snapshotSequence + 1)
    #expect(fresh.assets.first?.tagDecisions.first?.decision == .rejected)
    try await reopened.setShared(assetID: asset.id, shared: false)
    await #expect(throws: LocalLibraryError.syncIdentityChanged) {
        try await reopened.validateSharedSnapshotScope(fresh, visibleIdentifiers: ["selected"])
    }
}

@Test func lostSnapshotReceiptCanBeAppliedAfterVisibilityContracts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    try await store.observe([.init(
        localIdentifier: "selected", kind: "image", creationDate: nil, isFavorite: false
    )])
    let asset = try #require(await store.assets(visibleIdentifiers: ["selected"]).first)
    let tagID = try await store.createTag(name: "shared")
    try await store.setShared(assetID: asset.id, shared: true)
    try await store.setDecision(assetID: asset.id, tagID: tagID, decision: .accepted)
    let submitted = try await store.prepareSharedSnapshot(visibleIdentifiers: ["selected"])
    let reopened = try LocalLibraryStore(url: url)
    let frozen = try #require(await reopened.pendingSharedSnapshot())
    #expect(frozen == submitted)
    #expect(try await reopened.sharedSnapshot(visibleIdentifiers: []).assets.isEmpty)
    try await reopened.acknowledgeSharedSnapshot(
        frozen, hostID: UUID(), deviceID: UUID(), importedAssetIDs: [asset.id]
    )
    #expect(try await reopened.pendingSharedSnapshot() == nil)
    #expect(try await reopened.pendingSharedOperations().isEmpty)
    let hidden = try await reopened.prepareSharedSnapshot(visibleIdentifiers: [])
    #expect(hidden.snapshotSequence > submitted.snapshotSequence)
    #expect(hidden.assets.isEmpty)
    #expect(hidden.selectedAssetIDs == [asset.id])
    #expect(try await reopened.decisions(assetID: asset.id)[tagID] == .accepted)
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
    #expect(try await store.sharedSnapshot(
        visibleIdentifiers: ["selected"]
    ).outboxWatermark >= snapshot.outboxWatermark)

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

@Test func macTagChangesApplyAtomicallyAndPreservePhoneConflict() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    try await store.observe([
        LocalObservedAsset(localIdentifier: "shared", kind: "image", creationDate: nil, isFavorite: false)
    ])
    let asset = try #require(await store.assets(visibleIdentifiers: ["shared"]).first)
    let tagID = try await store.createTag(name: "family")
    let hostID = UUID()
    let deviceID = UUID()
    try await store.setShared(assetID: asset.id, shared: true)
    try await store.setDecision(assetID: asset.id, tagID: tagID, decision: .accepted)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["shared"])
    try await store.acknowledgeSharedSnapshot(
        snapshot, hostID: hostID, deviceID: deviceID, importedAssetIDs: [asset.id]
    )
    let remote = LocalSharedTagChange(
        sequence: 1, assetID: asset.id, tagID: tagID,
        tagName: "family", decision: .rejected, fieldRevision: 2
    )
    let applied = try await store.applySharedTagChanges(
        hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
        scopeRevision: snapshot.scopeRevision, afterCursor: 0,
        changes: [remote], nextCursor: 1
    )
    #expect(applied.applied == 1)
    #expect(try await store.decisions(assetID: asset.id)[tagID] == .rejected)
    #expect(try await store.pendingSharedOperations().isEmpty)
    #expect(try await store.sharedTagChangeCursor() == 1)
    try await store.setDecision(assetID: asset.id, tagID: tagID, decision: .accepted)
    let conflicting = LocalSharedTagChange(
        sequence: 2, assetID: asset.id, tagID: tagID,
        tagName: "family", decision: .cleared, fieldRevision: 3
    )
    let conflict = try await store.applySharedTagChanges(
        hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
        scopeRevision: snapshot.scopeRevision, afterCursor: 1,
        changes: [conflicting], nextCursor: 2
    )
    #expect(conflict.conflicts == 1)
    #expect(try await store.decisions(assetID: asset.id)[tagID] == .accepted)
    #expect(try await store.pendingSharedOperations().first?.isConflicted == true)
    #expect(try await store.pendingSharedOperations().first?.conflictReason == .fieldVersion)
    #expect(try await store.sharedTagChangeCursor() == 2)
    do {
        _ = try await store.applySharedTagChanges(
            hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
            scopeRevision: snapshot.scopeRevision, afterCursor: 2,
            changes: [.init(
                sequence: 3, assetID: asset.id, tagID: tagID,
                tagName: "wrong-name", decision: .accepted, fieldRevision: 4
            )], nextCursor: 3
        )
        Issue.record("a tag identity mismatch must not advance the cursor")
    } catch LocalLibraryError.syncRemoteTagMismatch {
        #expect(try await store.sharedTagChangeCursor() == 2)
    }
}

@Test func macNewTagIdentityAppliesWithoutEchoAndNameCollisionRollsBackPage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    try await store.observe([
        LocalObservedAsset(
            localIdentifier: "shared", kind: "image", creationDate: nil, isFavorite: false
        )
    ])
    let asset = try #require(await store.assets(visibleIdentifiers: ["shared"]).first)
    let hostID = UUID()
    let deviceID = UUID()
    try await store.setShared(assetID: asset.id, shared: true)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["shared"])
    try await store.acknowledgeSharedSnapshot(
        snapshot, hostID: hostID, deviceID: deviceID, importedAssetIDs: [asset.id]
    )
    let macTagID = UUID()
    let received = try await store.applySharedTagChanges(
        hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
        scopeRevision: snapshot.scopeRevision, afterCursor: 0,
        changes: [.init(
            sequence: 1, assetID: asset.id, tagID: macTagID,
            tagName: "Journey", decision: .accepted, fieldRevision: 1
        )], nextCursor: 1
    )
    #expect(received.applied == 1)
    #expect(try await store.tags().contains { $0.id == macTagID && $0.name == "Journey" })
    #expect(try await store.decisions(assetID: asset.id)[macTagID] == .accepted)
    #expect(try await store.sharedTagChangeCursor() == 1)
    #expect(try await store.pendingSharedOperations().isEmpty)

    let localTagID = try await store.createTag(name: "Café")
    let wouldBeCreated = UUID()
    let colliding = UUID()
    var aliasCandidate: LocalSharedTagAliasCandidate?
    do {
        _ = try await store.applySharedTagChanges(
            hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
            scopeRevision: snapshot.scopeRevision, afterCursor: 1,
            changes: [
                .init(sequence: 2, assetID: asset.id, tagID: wouldBeCreated,
                      tagName: "Other", decision: .rejected, fieldRevision: 1),
                .init(sequence: 3, assetID: asset.id, tagID: colliding,
                      tagName: "Cafe\u{301}", decision: .accepted, fieldRevision: 1),
            ], nextCursor: 3
        )
        Issue.record("same-name different-ID must stop the whole page")
    } catch LocalLibraryError.syncRemoteTagAliasRequired(let candidate) {
        aliasCandidate = candidate
        #expect(try await store.sharedTagChangeCursor() == 1)
        #expect(try await store.tags().contains { $0.id == localTagID })
        #expect(try await !store.tags().contains { $0.id == wouldBeCreated })
        #expect(try await !store.tags().contains { $0.id == colliding })
        #expect(try await store.pendingSharedOperations().isEmpty)
    }
    let candidate = try #require(aliasCandidate)
    #expect(candidate.localTagID == localTagID)
    #expect(candidate.remoteTagID == colliding)
    try await store.confirmSharedTagAlias(candidate)
    let reopened = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    let replay = try await reopened.applySharedTagChanges(
        hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
        scopeRevision: snapshot.scopeRevision, afterCursor: 1,
        changes: [
            .init(sequence: 2, assetID: asset.id, tagID: wouldBeCreated,
                  tagName: "Other", decision: .rejected, fieldRevision: 1),
            .init(sequence: 3, assetID: asset.id, tagID: colliding,
                  tagName: "Cafe\u{301}", decision: .accepted, fieldRevision: 1),
        ], nextCursor: 3
    )
    #expect(replay.applied == 2)
    #expect(try await reopened.sharedTagChangeCursor() == 3)
    #expect(try await reopened.decisions(assetID: asset.id)[localTagID] == .accepted)
    #expect(try await !reopened.tags().contains { $0.id == colliding })
    #expect(try await reopened.pendingSharedOperations().isEmpty)

    // A later snapshot uses the confirmed Mac identity, while migration facts
    // retain the phone's original tag ID. The snapshot ACK keys its baseline
    // to the phone field so a later edit can send the correct Mac revision.
    try await reopened.observe([.init(
        localIdentifier: "later", kind: "image", creationDate: nil, isFavorite: false
    )])
    let later = try #require(await reopened.assets(visibleIdentifiers: ["later"]).first)
    try await reopened.setDecision(assetID: later.id, tagID: localTagID, decision: .accepted)
    try await reopened.setShared(assetID: later.id, shared: true)
    let network = try await reopened.prepareSharedSnapshot(visibleIdentifiers: ["shared", "later"])
    let networkTag = try #require(network.assets.first { $0.id == later.id }?.tagDecisions.first)
    #expect(networkTag.tagID == colliding)
    #expect(networkTag.tagName == "Cafe\u{301}")
    let facts = try await reopened.migrationFactSnapshot(visibleIdentifiers: ["shared", "later"])
    #expect(facts.assets.first { $0.id == later.id }?.tagDecisions.first?.tagID == localTagID)
    try await reopened.acknowledgeSharedSnapshot(
        network, hostID: hostID, deviceID: deviceID, importedAssetIDs: [later.id]
    )
    try await reopened.setDecision(assetID: later.id, tagID: localTagID, decision: .rejected)
    let pending = try #require(await reopened.pendingSharedOperations().first)
    let prepared = try #require(await reopened.prepareSharedTagOperation(
        id: pending.id, hostID: hostID, deviceID: deviceID
    ))
    #expect(prepared.tagID == colliding)
    #expect(prepared.tagName == "Cafe\u{301}")
    #expect(prepared.baseRevision == 1)
    try await reopened.recordSharedTagResult(
        operationID: pending.id, hostID: hostID, deviceID: deviceID,
        disposition: .applied, fieldRevision: 2, currentDecision: .rejected
    )
    let completion = try await reopened.migrationCompletionCheckpoint(
        visibleIdentifiers: ["shared", "later"]
    )
    #expect(completion.checkpoint.tagAliases == [.init(
        localTagID: localTagID, localTagName: "Café",
        remoteTagID: colliding, remoteTagName: "Cafe\u{301}"
    )])
    #expect(completion.snapshot.assets.first {
        $0.id == later.id
    }?.tagDecisions.first?.tagID == localTagID)
}

@Test func sharedPhoneTagCannotBeSilentlyReboundToDifferentMacTag() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    try await store.observe([.init(
        localIdentifier: "shared", kind: "image", creationDate: nil, isFavorite: false
    )])
    let asset = try #require(await store.assets(visibleIdentifiers: ["shared"]).first)
    let localTagID = try await store.createTag(name: "Family")
    try await store.setDecision(assetID: asset.id, tagID: localTagID, decision: .accepted)
    try await store.setShared(assetID: asset.id, shared: true)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["shared"])
    let hostID = UUID(), deviceID = UUID()
    try await store.acknowledgeSharedSnapshot(
        snapshot, hostID: hostID, deviceID: deviceID, importedAssetIDs: [asset.id]
    )
    do {
        _ = try await store.applySharedTagChanges(
            hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
            scopeRevision: snapshot.scopeRevision, afterCursor: 0,
            changes: [.init(
                sequence: 1, assetID: asset.id, tagID: UUID(),
                tagName: "family", decision: .rejected, fieldRevision: 1
            )], nextCursor: 1
        )
        Issue.record("an established shared tag identity must not be rebound")
    } catch LocalLibraryError.syncRemoteTagMismatch {
        #expect(try await store.sharedTagChangeCursor() == 0)
        #expect(try await store.decisions(assetID: asset.id)[localTagID] == .accepted)
    }
}

@Test func explicitPhoneConflictChoiceCreatesNewOperationAtMacRevision() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    try await store.observe([
        LocalObservedAsset(localIdentifier: "shared", kind: "image", creationDate: nil, isFavorite: false)
    ])
    let asset = try #require(await store.assets(visibleIdentifiers: ["shared"]).first)
    let tagID = try await store.createTag(name: "family")
    let hostID = UUID()
    let deviceID = UUID()
    try await store.setShared(assetID: asset.id, shared: true)
    try await store.setDecision(assetID: asset.id, tagID: tagID, decision: .accepted)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["shared"])
    try await store.acknowledgeSharedSnapshot(
        snapshot, hostID: hostID, deviceID: deviceID, importedAssetIDs: [asset.id]
    )
    try await store.setDecision(assetID: asset.id, tagID: tagID, decision: .rejected)
    let conflicted = try #require(await store.pendingSharedOperations().first)
    _ = try await store.prepareSharedTagOperation(
        id: conflicted.id, hostID: hostID, deviceID: deviceID
    )
    try await store.recordSharedTagResult(
        operationID: conflicted.id, hostID: hostID, deviceID: deviceID,
        disposition: .conflict, fieldRevision: 2,
        currentDecision: .accepted, conflictReason: .fieldVersion
    )
    try await store.setDecision(assetID: asset.id, tagID: tagID, decision: .cleared)
    let auditCount = try await store.pendingOperations().count
    let reopened = try LocalLibraryStore(url: url)
    let conflict = try #require(await reopened.pendingSharedOperations().first)
    #expect(conflict.conflictDecision == .accepted)
    #expect(conflict.conflictRevision == 2)
    #expect(conflict.conflictReason == .fieldVersion)
    #expect(conflict.localCurrentDecision == .cleared)
    let replacementID = try #require(await reopened.resolveSharedTagConflict(
        operationID: conflict.id, resolution: .keepPhone
    ))
    let pending = try await reopened.pendingSharedOperations()
    #expect(pending.count == 1)
    #expect(pending.first?.id == replacementID)
    #expect(pending.first?.value == LocalDecision.cleared.rawValue)
    #expect(try await reopened.pendingOperations().count == auditCount + 1)
    let prepared = try #require(await reopened.prepareSharedTagOperation(
        id: replacementID, hostID: hostID, deviceID: deviceID
    ))
    #expect(prepared.baseRevision == 2)
    #expect(prepared.operation.sequence > conflict.sequence)
}

@Test func acceptingMacConflictUpdatesLocalFactButAliasConflictStaysPending() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    try await store.observe([
        LocalObservedAsset(localIdentifier: "shared", kind: "image", creationDate: nil, isFavorite: false)
    ])
    let asset = try #require(await store.assets(visibleIdentifiers: ["shared"]).first)
    let tagID = try await store.createTag(name: "family")
    let hostID = UUID()
    let deviceID = UUID()
    try await store.setShared(assetID: asset.id, shared: true)
    try await store.setDecision(assetID: asset.id, tagID: tagID, decision: .accepted)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["shared"])
    try await store.acknowledgeSharedSnapshot(
        snapshot, hostID: hostID, deviceID: deviceID, importedAssetIDs: [asset.id]
    )
    try await store.setDecision(assetID: asset.id, tagID: tagID, decision: .rejected)
    let first = try #require(await store.pendingSharedOperations().first)
    _ = try await store.prepareSharedTagOperation(
        id: first.id, hostID: hostID, deviceID: deviceID
    )
    try await store.recordSharedTagResult(
        operationID: first.id, hostID: hostID, deviceID: deviceID,
        disposition: .conflict, fieldRevision: 2,
        currentDecision: .cleared, conflictReason: .fieldVersion
    )
    let auditCount = try await store.pendingOperations().count
    _ = try await store.resolveSharedTagConflict(
        operationID: first.id, resolution: .acceptMac
    )
    #expect(try await store.decisions(assetID: asset.id)[tagID] == .cleared)
    #expect(try await store.pendingSharedOperations().isEmpty)
    #expect(try await store.pendingOperations().count == auditCount + 1)
    try await store.setDecision(assetID: asset.id, tagID: tagID, decision: .accepted)
    let second = try #require(await store.pendingSharedOperations().first)
    let prepared = try #require(await store.prepareSharedTagOperation(
        id: second.id, hostID: hostID, deviceID: deviceID
    ))
    #expect(prepared.baseRevision == 2)
    try await store.recordSharedTagResult(
        operationID: second.id, hostID: hostID, deviceID: deviceID,
        disposition: .conflict, fieldRevision: 2,
        currentDecision: nil, conflictReason: .nameAlias
    )
    do {
        _ = try await store.resolveSharedTagConflict(
            operationID: second.id, resolution: .keepPhone
        )
        Issue.record("same-name different-ID tag must not be silently rebased")
    } catch LocalLibraryError.syncConflictDetailsUnavailable {
        #expect(try await store.pendingSharedOperations().first?.isConflicted == true)
    }
}

@Test func sharedCollectionMembershipKeepsVersionedRemovalAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    try await store.observe([
        LocalObservedAsset(localIdentifier: "shared", kind: "image", creationDate: nil, isFavorite: false)
    ])
    let asset = try #require(await store.assets(visibleIdentifiers: ["shared"]).first)
    let collectionID = try await store.createCollection(name: "trip")
    let hostID = UUID()
    let deviceID = UUID()
    try await store.setShared(assetID: asset.id, shared: true)
    try await store.setMembership(assetID: asset.id, collectionID: collectionID, included: true)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["shared"])
    try await store.acknowledgeSharedSnapshot(
        snapshot, hostID: hostID, deviceID: deviceID, importedAssetIDs: [asset.id]
    )
    #expect(try await store.pendingSharedOperations().isEmpty)
    try await store.setMembership(assetID: asset.id, collectionID: collectionID, included: false)
    let pending = try #require(await store.pendingSharedOperations().first)
    let prepared = try #require(await store.prepareSharedCollectionOperation(
        id: pending.id, hostID: hostID, deviceID: deviceID
    ))
    #expect(prepared.baseRevision == 1)
    #expect(prepared.included == false)
    let reopened = try LocalLibraryStore(url: url)
    let retry = try #require(await reopened.prepareSharedCollectionOperation(
        id: pending.id, hostID: hostID, deviceID: deviceID
    ))
    #expect(retry.operation.id == prepared.operation.id)
    #expect(retry.baseRevision == 1)
    try await reopened.recordSharedCollectionResult(
        operationID: pending.id, hostID: hostID, deviceID: deviceID,
        disposition: .applied, fieldRevision: 2, currentIncluded: false
    )
    #expect(try await reopened.pendingSharedOperations().isEmpty)
    try await reopened.setMembership(assetID: asset.id, collectionID: collectionID, included: true)
    let next = try #require(await reopened.pendingSharedOperations().first)
    let nextPrepared = try #require(await reopened.prepareSharedCollectionOperation(
        id: next.id, hostID: hostID, deviceID: deviceID
    ))
    #expect(nextPrepared.baseRevision == 2)
    #expect(nextPrepared.operation.sequence > prepared.operation.sequence)
    try await reopened.recordSharedCollectionResult(
        operationID: next.id, hostID: hostID, deviceID: deviceID,
        disposition: .conflict, fieldRevision: 3, currentIncluded: false,
        conflictReason: .fieldVersion
    )
    let conflict = try #require(await reopened.pendingSharedOperations().first)
    #expect(conflict.isConflicted)
    #expect(conflict.conflictReason == .fieldVersion)
    #expect(conflict.conflictValue == "0")
    #expect(conflict.localCurrentIncluded == true)
    let retryID = try #require(await reopened.resolveSharedCollectionConflict(
        operationID: conflict.id, resolution: .keepPhone
    ))
    let rebased = try #require(await reopened.prepareSharedCollectionOperation(
        id: retryID, hostID: hostID, deviceID: deviceID
    ))
    #expect(rebased.baseRevision == 3)
    #expect(rebased.operation.id != conflict.id)
    try await reopened.recordSharedCollectionResult(
        operationID: retryID, hostID: hostID, deviceID: deviceID,
        disposition: .conflict, fieldRevision: 4, currentIncluded: false,
        conflictReason: .fieldVersion
    )
    _ = try await reopened.resolveSharedCollectionConflict(
        operationID: retryID, resolution: .acceptMac
    )
    #expect(try await reopened.memberships(assetID: asset.id).isEmpty)
    #expect(try await reopened.pendingSharedOperations().isEmpty)
}

@Test func macCollectionChangesApplyAtomicallyAndPreservePhoneIntent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    try await store.observe([
        LocalObservedAsset(localIdentifier: "shared", kind: "image", creationDate: nil, isFavorite: false)
    ])
    let asset = try #require(await store.assets(visibleIdentifiers: ["shared"]).first)
    let collectionID = try await store.createCollection(name: "旅行")
    let hostID = UUID()
    let deviceID = UUID()
    try await store.setShared(assetID: asset.id, shared: true)
    try await store.setMembership(assetID: asset.id, collectionID: collectionID, included: true)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["shared"])
    try await store.acknowledgeSharedSnapshot(
        snapshot, hostID: hostID, deviceID: deviceID, importedAssetIDs: [asset.id]
    )
    let epoch = try await store.sourceEpoch()
    let removed = LocalSharedCollectionChange(
        sequence: 1, assetID: asset.id, collectionID: collectionID,
        collectionName: "旅行", included: false, fieldRevision: 2
    )
    let first = try await store.applySharedCollectionChanges(
        hostID: hostID, deviceID: deviceID, sourceEpoch: epoch,
        scopeRevision: snapshot.scopeRevision, afterCursor: 0,
        changes: [removed], nextCursor: 1
    )
    #expect(first.applied == 1)
    #expect(try await store.memberships(assetID: asset.id).isEmpty)
    #expect(try await store.pendingSharedOperations().isEmpty)
    #expect(try await store.sharedCollectionChangeCursor() == 1)
    try await store.setMembership(assetID: asset.id, collectionID: collectionID, included: true)
    let conflicting = LocalSharedCollectionChange(
        sequence: 2, assetID: asset.id, collectionID: collectionID,
        collectionName: "旅行", included: false, fieldRevision: 3
    )
    let second = try await store.applySharedCollectionChanges(
        hostID: hostID, deviceID: deviceID, sourceEpoch: epoch,
        scopeRevision: snapshot.scopeRevision, afterCursor: 1,
        changes: [conflicting], nextCursor: 2
    )
    #expect(second.conflicts == 1)
    #expect(try await store.memberships(assetID: asset.id).contains(collectionID))
    let reopened = try LocalLibraryStore(url: url)
    let conflict = try #require(await reopened.pendingSharedOperations().first)
    #expect(conflict.conflictValue == "0")
    #expect(conflict.conflictReason == .fieldVersion)
    #expect(try await reopened.sharedCollectionChangeCursor() == 2)
    do {
        _ = try await reopened.applySharedCollectionChanges(
            hostID: hostID, deviceID: deviceID, sourceEpoch: epoch,
            scopeRevision: snapshot.scopeRevision, afterCursor: 2,
            changes: [.init(
                sequence: 3, assetID: asset.id, collectionID: collectionID,
                collectionName: "别名", included: true, fieldRevision: 4
            )], nextCursor: 3
        )
        Issue.record("collection identity mismatch must not advance cursor")
    } catch LocalLibraryError.syncRemoteCollectionMismatch {
        #expect(try await reopened.sharedCollectionChangeCursor() == 2)
    }
    let retryID = try #require(await reopened.resolveSharedCollectionConflict(
        operationID: conflict.id, resolution: .keepPhone
    ))
    let retry = try #require(await reopened.prepareSharedCollectionOperation(
        id: retryID, hostID: hostID, deviceID: deviceID
    ))
    #expect(retry.baseRevision == 3)
}

@Test func macNewCollectionIdentityInstallsWithMemberAndCollisionRollsBackPage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    try await store.observe([.init(
        localIdentifier: "shared", kind: "image", creationDate: nil, isFavorite: false
    )])
    let asset = try #require(await store.assets(visibleIdentifiers: ["shared"]).first)
    let existingID = try await store.createCollection(name: "Café")
    let hostID = UUID(), deviceID = UUID()
    try await store.setShared(assetID: asset.id, shared: true)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["shared"])
    try await store.acknowledgeSharedSnapshot(
        snapshot, hostID: hostID, deviceID: deviceID, importedAssetIDs: [asset.id]
    )
    let createdID = UUID(), collidingID = UUID()
    let first = LocalSharedCollectionChange(
        sequence: 1, assetID: asset.id, collectionID: createdID,
        collectionName: "Journey", included: true, fieldRevision: 1
    )
    let collision = LocalSharedCollectionChange(
        sequence: 2, assetID: asset.id, collectionID: collidingID,
        collectionName: "Cafe\u{301}", included: true, fieldRevision: 1
    )
    do {
        _ = try await store.applySharedCollectionChanges(
            hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
            scopeRevision: snapshot.scopeRevision, afterCursor: 0,
            changes: [first, collision], nextCursor: 2
        )
        Issue.record("name collision must roll back the entire collection page")
    } catch LocalLibraryError.syncRemoteCollectionAliasRequired(let candidate) {
        #expect(try await store.sharedCollectionChangeCursor() == 0)
        #expect(try await !store.collections().contains { $0.id == createdID })
        #expect(try await store.collections().contains { $0.id == existingID })
        #expect(candidate.localCollectionID == existingID)
        #expect(candidate.remoteCollectionID == collidingID)
        try await store.confirmSharedCollectionAlias(candidate)
    }
    let received = try await store.applySharedCollectionChanges(
        hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
        scopeRevision: snapshot.scopeRevision, afterCursor: 0,
        changes: [first, collision], nextCursor: 2
    )
    #expect(received.applied == 2)
    #expect(try await store.collections().contains {
        $0.id == createdID && $0.name == "Journey"
    })
    #expect(Set(try await store.memberships(assetID: asset.id)) == [createdID, existingID])
    #expect(try await store.pendingSharedOperations().isEmpty)
    let reopened = try LocalLibraryStore(url: url)
    let wire = try await reopened.prepareSharedSnapshot(visibleIdentifiers: ["shared"])
    let wireCollections = try #require(wire.assets.first?.collections)
    #expect(wireCollections.contains {
        $0.collectionID == collidingID && $0.collectionName == "Cafe\u{301}"
    })
    try await reopened.acknowledgeSharedSnapshot(
        wire, hostID: hostID, deviceID: deviceID, importedAssetIDs: []
    )
    let migration = try await reopened.migrationCompletionCheckpoint(
        visibleIdentifiers: ["shared"]
    )
    #expect(migration.snapshot.assets.first?.collections.contains {
        $0.collectionID == existingID && $0.collectionName == "Café"
    } == true)
    #expect(migration.checkpoint.collectionAliases == [.init(
        localCollectionID: existingID, localCollectionName: "Café",
        remoteCollectionID: collidingID, remoteCollectionName: "Cafe\u{301}"
    )])
    do {
        _ = try await reopened.applySharedCollectionChanges(
            hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
            scopeRevision: snapshot.scopeRevision, afterCursor: 2,
            changes: [.init(
                sequence: 3, assetID: asset.id, collectionID: UUID(),
                collectionName: "Café", included: true, fieldRevision: 1
            )], nextCursor: 3
        )
        Issue.record("one local collection must not acquire a second Mac identity")
    } catch LocalLibraryError.syncRemoteCollectionMismatch {
        #expect(try await reopened.sharedCollectionChangeCursor() == 2)
    }
    try await reopened.setMembership(assetID: asset.id, collectionID: existingID, included: false)
    let pending = try #require(await reopened.pendingSharedOperations().first)
    let prepared = try #require(await reopened.prepareSharedCollectionOperation(
        id: pending.id, hostID: hostID, deviceID: deviceID
    ))
    #expect(prepared.collectionID == collidingID)
    #expect(prepared.baseRevision == 1)
}

@Test func macCreatedCollectionRenameAppliesAcrossPagesWithoutMemberEcho() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalLibraryStore(url: root.appendingPathComponent("local.sqlite"))
    try await store.observe([
        .init(localIdentifier: "one", kind: "image", creationDate: nil, isFavorite: false),
        .init(localIdentifier: "two", kind: "image", creationDate: nil, isFavorite: false),
    ])
    let assets = try await store.assets(visibleIdentifiers: ["one", "two"])
    let firstID = try #require(assets.first(where: { $0.localIdentifier == "one" })?.id)
    let secondID = try #require(assets.first(where: { $0.localIdentifier == "two" })?.id)
    let collectionID = UUID(), hostID = UUID(), deviceID = UUID()
    try await store.setShared(assetID: firstID, shared: true)
    try await store.setShared(assetID: secondID, shared: true)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["one", "two"])
    try await store.acknowledgeSharedSnapshot(
        snapshot, hostID: hostID, deviceID: deviceID,
        importedAssetIDs: [firstID, secondID]
    )
    _ = try await store.applySharedCollectionChanges(
        hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
        scopeRevision: snapshot.scopeRevision, afterCursor: 0,
        changes: [
            .init(sequence: 1, assetID: firstID, collectionID: collectionID,
                  collectionName: "Journey", included: true, fieldRevision: 1),
            .init(sequence: 2, assetID: secondID, collectionID: collectionID,
                  collectionName: "Journey", included: true, fieldRevision: 1),
        ], nextCursor: 2
    )
    _ = try await store.applySharedCollectionChanges(
        hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
        scopeRevision: snapshot.scopeRevision, afterCursor: 2,
        changes: [.init(
            sequence: 3, assetID: firstID, collectionID: collectionID,
            collectionName: "Trip", included: true, fieldRevision: 1,
            renamedFrom: "Journey"
        )], nextCursor: 3
    )
    #expect(try await store.collections().first { $0.id == collectionID }?.name == "Trip")
    _ = try await store.applySharedCollectionChanges(
        hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
        scopeRevision: snapshot.scopeRevision, afterCursor: 3,
        changes: [.init(
            sequence: 4, assetID: secondID, collectionID: collectionID,
            collectionName: "Trip", included: true, fieldRevision: 1,
            renamedFrom: "Journey"
        )], nextCursor: 4
    )
    #expect(try await store.pendingSharedOperations().isEmpty)
    #expect(try await store.sharedCollectionChangeCursor() == 4)
    _ = try await store.createCollection(name: "Taken")
    do {
        _ = try await store.applySharedCollectionChanges(
            hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
            scopeRevision: snapshot.scopeRevision, afterCursor: 4,
            changes: [.init(
                sequence: 5, assetID: firstID, collectionID: collectionID,
                collectionName: "Taken", included: true, fieldRevision: 1,
                renamedFrom: "Trip"
            )], nextCursor: 5
        )
        Issue.record("a colliding rename must leave the name and cursor unchanged")
    } catch LocalLibraryError.syncRemoteCollectionMismatch {
        #expect(try await store.sharedCollectionChangeCursor() == 4)
        #expect(try await store.collections().first { $0.id == collectionID }?.name == "Trip")
    }
    let wire = try await store.prepareSharedSnapshot(visibleIdentifiers: ["one", "two"])
    #expect(wire.assets.allSatisfy {
        $0.collections.contains { $0.collectionID == collectionID && $0.collectionName == "Trip" }
    })
    try await store.setMembership(assetID: secondID, collectionID: collectionID, included: false)
    let pending = try #require(await store.pendingSharedOperations().first)
    let preparedBefore = try #require(await store.prepareSharedCollectionOperation(
        id: pending.id, hostID: hostID, deviceID: deviceID
    ))
    _ = try await store.applySharedCollectionChanges(
        hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
        scopeRevision: snapshot.scopeRevision, afterCursor: 4,
        changes: [
            .init(sequence: 5, assetID: firstID, collectionID: collectionID,
                  collectionName: "Later", included: true, fieldRevision: 1,
                  renamedFrom: "Trip"),
            .init(sequence: 6, assetID: secondID, collectionID: collectionID,
                  collectionName: "Later", included: true, fieldRevision: 1,
                  renamedFrom: "Trip"),
        ], nextCursor: 6
    )
    let afterRename = try #require(await store.pendingSharedOperations().first)
    #expect(afterRename.id == pending.id)
    #expect(!afterRename.isConflicted)
    let preparedAfter = try #require(await store.prepareSharedCollectionOperation(
        id: pending.id, hostID: hostID, deviceID: deviceID
    ))
    #expect(preparedAfter.baseRevision == preparedBefore.baseRevision)
    #expect(try await store.collections().first { $0.id == collectionID }?.name == "Later")
}

@Test(arguments: [false, true])
func confirmedCollectionAliasFollowsExplicitMacRename(legacyPrepared: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    var store = try LocalLibraryStore(url: url)
    try await store.observe([.init(
        localIdentifier: "shared", kind: "image", creationDate: nil, isFavorite: false
    )])
    let asset = try #require(await store.assets(visibleIdentifiers: ["shared"]).first)
    let localID = try await store.createCollection(name: "Café")
    let remoteID = UUID(), hostID = UUID(), deviceID = UUID()
    try await store.setShared(assetID: asset.id, shared: true)
    let snapshot = try await store.prepareSharedSnapshot(visibleIdentifiers: ["shared"])
    try await store.acknowledgeSharedSnapshot(
        snapshot, hostID: hostID, deviceID: deviceID,
        importedAssetIDs: [asset.id]
    )
    let created = LocalSharedCollectionChange(
        sequence: 1, assetID: asset.id, collectionID: remoteID,
        collectionName: "Cafe\u{301}", included: true, fieldRevision: 1
    )
    do {
        _ = try await store.applySharedCollectionChanges(
            hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
            scopeRevision: snapshot.scopeRevision, afterCursor: 0,
            changes: [created], nextCursor: 1
        )
        Issue.record("same-name different-ID collection needs owner confirmation")
    } catch LocalLibraryError.syncRemoteCollectionAliasRequired(let candidate) {
        try await store.confirmSharedCollectionAlias(candidate)
    }
    _ = try await store.applySharedCollectionChanges(
        hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
        scopeRevision: snapshot.scopeRevision, afterCursor: 0,
        changes: [created], nextCursor: 1
    )
    try await store.setMembership(assetID: asset.id, collectionID: localID, included: false)
    let firstOperation = try #require(await store.pendingSharedOperations().first)
    let beforeRename = try #require(await store.prepareSharedCollectionOperation(
        id: firstOperation.id, hostID: hostID, deviceID: deviceID
    ))
    try await store.setMembership(assetID: asset.id, collectionID: localID, included: true)
    if legacyPrepared {
        // Emulate a database prepared by the preceding app version.
        var rawDB: OpaquePointer?
        #expect(sqlite3_open(url.path, &rawDB) == SQLITE_OK)
        #expect(sqlite3_exec(rawDB, "DROP TABLE shared_collection_delivery_identity", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(rawDB)
        store = try LocalLibraryStore(url: url)
    }
    _ = try await store.applySharedCollectionChanges(
        hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch,
        scopeRevision: snapshot.scopeRevision, afterCursor: 1,
        changes: [.init(
            sequence: 2, assetID: asset.id, collectionID: remoteID,
            collectionName: "Trip", included: true, fieldRevision: 1,
            renamedFrom: "Cafe\u{301}"
        )], nextCursor: 2
    )
    #expect(try await store.collections().first { $0.id == localID }?.name == "Trip")
    store = try LocalLibraryStore(url: url)
    let retry = try #require(await store.prepareSharedCollectionOperation(
        id: firstOperation.id, hostID: hostID, deviceID: deviceID
    ))
    #expect(retry.collectionID == beforeRename.collectionID)
    #expect(retry.collectionName == beforeRename.collectionName)
    #expect(Array(retry.collectionName.utf8) == Array(beforeRename.collectionName.utf8))
    #expect(retry.baseRevision == beforeRename.baseRevision)
    #expect(retry.included == beforeRename.included)
    try await store.recordSharedCollectionResult(
        operationID: firstOperation.id, hostID: hostID, deviceID: deviceID,
        disposition: .applied, fieldRevision: 2, currentIncluded: false
    )
    let nextOperation = try #require(await store.pendingSharedOperations().first)
    let next = try #require(await store.prepareSharedCollectionOperation(
        id: nextOperation.id, hostID: hostID, deviceID: deviceID
    ))
    #expect(next.collectionID == remoteID)
    #expect(next.collectionName == "Trip")
    #expect(next.baseRevision == 2)
    try await store.recordSharedCollectionResult(
        operationID: nextOperation.id, hostID: hostID, deviceID: deviceID,
        disposition: .applied, fieldRevision: 3, currentIncluded: true
    )
    let wire = try await store.prepareSharedSnapshot(visibleIdentifiers: ["shared"])
    #expect(wire.assets.first?.collections.contains {
        $0.collectionID == remoteID && $0.collectionName == "Trip"
    } == true)
    try await store.acknowledgeSharedSnapshot(
        wire, hostID: hostID, deviceID: deviceID, importedAssetIDs: []
    )
    let checkpoint = try await store.migrationCompletionCheckpoint(
        visibleIdentifiers: ["shared"]
    )
    #expect(checkpoint.checkpoint.collectionAliases == [.init(
        localCollectionID: localID, localCollectionName: "Trip",
        remoteCollectionID: remoteID, remoteCollectionName: "Trip"
    )])
}

@Test func migrationAuditKeepsHistoricalNamesAndLegacyUnknownOrigin() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("local.sqlite")
    let store = try LocalLibraryStore(url: url)
    try await store.observe([.init(localIdentifier: "selected", kind: "image", creationDate: nil, isFavorite: false)])
    let asset = try #require(await store.assets(visibleIdentifiers: ["selected"]).first)
    try await store.setShared(assetID: asset.id, shared: true)
    let tag = try await store.createTag(name: "旧标签")
    let collection = try await store.createCollection(name: "旧集合")
    try await store.setDecision(assetID: asset.id, tagID: tag, decision: .accepted)
    try await store.setMembership(assetID: asset.id, collectionID: collection, included: true)
    var rawDB: OpaquePointer?
    #expect(sqlite3_open(url.path, &rawDB) == SQLITE_OK)
    defer { sqlite3_close(rawDB) }
    #expect(sqlite3_exec(rawDB, "UPDATE tags SET name='新标签'; UPDATE collections SET name='新集合'", nil, nil, nil) == SQLITE_OK)
    let reopened = try LocalLibraryStore(url: url)
    let snapshot = try await reopened.migrationFactSnapshot(visibleIdentifiers: ["selected"])
    #expect(snapshot.auditRecords?.map(\.referenceName) == ["旧标签", "旧集合"])
    #expect(snapshot.assets.first?.tagDecisions.first?.tagName == "新标签")
    // Simulate an earlier database that has no event context table.
    #expect(sqlite3_exec(rawDB, "DROP TABLE audit_context", nil, nil, nil) == SQLITE_OK)
    let upgraded = try LocalLibraryStore(url: url)
    let legacy = try await upgraded.migrationFactSnapshot(visibleIdentifiers: ["selected"])
    #expect(legacy.auditRecords?.allSatisfy { $0.origin == nil && $0.referenceName == nil } == true)
    try await upgraded.setDecision(assetID: asset.id, tagID: tag, decision: .rejected)
    let current = try await upgraded.migrationFactSnapshot(visibleIdentifiers: ["selected"])
    #expect(current.auditRecords?.last?.origin == .localEdit)
    #expect(current.auditRecords?.last?.referenceName == "新标签")
}
