import CryptoKit
import Foundation
import ImageAllRemoteProtocol

/// Mac-owned projection of explicitly shared iPhone directory and human facts.
/// It never receives media bytes and never treats temporary PhotoKit invisibility as deletion.
actor RemoteLocalLibrarySyncStore {
    struct SharedTagFact: Codable, Sendable, Equatable {
        let assetID: UUID
        let tagID: UUID
        let tagName: String
        let decision: RemoteLocalLibraryDecision
        let revision: Int64
    }

    struct SharedCollectionFact: Codable, Sendable, Equatable {
        let assetID: UUID
        let collectionID: UUID
        let collectionName: String
        let included: Bool
        let revision: Int64
    }

    struct SharedFavoriteFact: Codable, Sendable, Equatable {
        let assetID: UUID
        let target: Bool
        let revision: Int64
    }

    struct ProjectedAsset: Codable, Sendable, Identifiable {
        var id: UUID { asset.id }
        let asset: RemoteLocalLibraryAsset
        let lastVisibleSnapshotSequence: Int64
    }

    struct Projection: Sendable, Identifiable {
        var id: UUID { deviceID }
        let deviceID: UUID
        let installID: UUID
        let sourceEpoch: UUID
        let scopeRevision: Int64
        let snapshotSequence: Int64
        let acceptedAtMs: Int64?
        let selectedAssetIDs: [UUID]
        let assets: [ProjectedAsset]
        let sharedTagFacts: [SharedTagFact]
        let sharedCollectionFacts: [SharedCollectionFact]
        let sharedFavoriteFacts: [SharedFavoriteFact]
    }

    struct MacTagOperationReceipt: Codable, Sendable, Equatable {
        let operationID: UUID
        let deviceID: UUID
        let installID: UUID
        let sourceEpoch: UUID
        let scopeRevision: Int64
        let assetID: UUID
        let tagID: UUID
        /// Present when this operation created the shared field and tag identity.
        let createdTagName: String?
        let decision: RemoteLocalLibraryDecision
        let expectedRevision: Int64
        let resultingRevision: Int64
        let changeSequence: Int64
    }

    private struct TagOperationRecord: Codable {
        let request: RemoteLocalLibraryTagDecisionRequest
        let payloadSHA256: String
        let receipt: RemoteLocalLibraryTagDecisionReceipt
    }

    private struct CollectionOperationRecord: Codable {
        let request: RemoteLocalLibraryCollectionMembershipRequest
        let payloadSHA256: String
        let receipt: RemoteLocalLibraryCollectionMembershipReceipt
    }

    private struct FavoriteOperationRecord: Codable {
        let request: RemoteLocalLibraryFavoriteTargetRequest
        let payloadSHA256: String
        let receipt: RemoteLocalLibraryFavoriteTargetReceipt
    }

    private struct Record: Codable {
        let deviceID: UUID
        let request: RemoteLocalLibrarySnapshotRequest
        let projectedAssets: [ProjectedAsset]
        let acceptedAtMs: Int64?
        /// Optional for snapshots written before the versioned fact ledger existed.
        let sharedTagFacts: [SharedTagFact]?
        let sharedCollectionFacts: [SharedCollectionFact]?
        let sharedFavoriteFacts: [SharedFavoriteFact]?
        let tagOperations: [TagOperationRecord]?
        let collectionOperations: [CollectionOperationRecord]?
        let favoriteOperations: [FavoriteOperationRecord]?
        /// Mac-originated operations are stored atomically with the outbound change.
        /// Old JSON ledgers decode this optional field as nil.
        let macTagOperations: [MacTagOperationReceipt]?
        let lastPhoneOperationSequence: Int64?
        let importedAssetIDs: [UUID]?
        let tagChanges: [RemoteLocalLibraryTagChange]?
        let collectionChanges: [RemoteLocalLibraryCollectionChange]?
        let favoriteChanges: [RemoteLocalLibraryFavoriteChange]?
    }

    private struct PersistedState: Codable {
        var records: [Record]
    }

    nonisolated let hostID: UUID
    private let storageURL: URL
    private var records: [UUID: Record]

    init(hostID: UUID, storageURL: URL) throws {
        self.hostID = hostID
        self.storageURL = storageURL
        if FileManager.default.fileExists(atPath: storageURL.path) {
            let decoded = try JSONDecoder().decode(
                PersistedState.self, from: Data(contentsOf: storageURL)
            )
            guard Set(decoded.records.map(\.deviceID)).count == decoded.records.count,
                  decoded.records.allSatisfy({ record in
                      let projectedIDs = record.projectedAssets.map(\.asset.id)
                      let selectedIDs = Set(record.request.selectedAssetIDs)
                      let factKeys = (record.sharedTagFacts ?? []).map {
                          "\($0.assetID.uuidString)|\($0.tagID.uuidString)"
                      }
                      let collectionKeys = (record.sharedCollectionFacts ?? []).map {
                          "\($0.assetID.uuidString)|\($0.collectionID.uuidString)"
                      }
                      let operationIDs = (record.tagOperations ?? []).map(\.request.operationID)
                          + (record.collectionOperations ?? []).map(\.request.operationID)
                          + (record.favoriteOperations ?? []).map(\.request.operationID)
                      let changes = record.tagChanges ?? []
                      let collectionChanges = record.collectionChanges ?? []
                      let favoriteChanges = record.favoriteChanges ?? []
                      return record.request.hostID == hostID
                          && record.request.schemaVersion == 1
                          && Set(projectedIDs).count == projectedIDs.count
                          && Set(projectedIDs).isSubset(of: selectedIDs)
                          && Set(record.importedAssetIDs ?? []).count ==
                              (record.importedAssetIDs ?? []).count
                          && Set(record.importedAssetIDs ?? []).isSubset(of: Set(projectedIDs))
                          && Set(factKeys).count == factKeys.count
                          && Set(collectionKeys).count == collectionKeys.count
                          && Set((record.sharedFavoriteFacts ?? []).map(\.assetID)).count ==
                              (record.sharedFavoriteFacts ?? []).count
                          && (record.sharedTagFacts ?? []).allSatisfy {
                              selectedIDs.contains($0.assetID) && $0.revision > 0
                          }
                          && (record.sharedCollectionFacts ?? []).allSatisfy {
                              selectedIDs.contains($0.assetID) && $0.revision > 0
                          }
                          && (record.sharedFavoriteFacts ?? []).allSatisfy {
                              selectedIDs.contains($0.assetID) && $0.revision > 0
                          }
                          && Set(operationIDs).count == operationIDs.count
                          && Set((record.macTagOperations ?? []).map(\.operationID)).count ==
                              (record.macTagOperations ?? []).count
                          && (record.macTagOperations ?? []).allSatisfy { operation in
                              operation.deviceID == record.deviceID
                                  && operation.installID == record.request.installID
                                  && operation.sourceEpoch == record.request.sourceEpoch
                                  && operation.scopeRevision >= 0
                                  && operation.scopeRevision <= record.request.scopeRevision
                                  && operation.expectedRevision >= 0
                                  && operation.expectedRevision < Int64.max
                                  && operation.resultingRevision == operation.expectedRevision + 1
                                  && (operation.expectedRevision > 0
                                      || operation.createdTagName != nil)
                                  && changes.contains { change in
                                      change.sequence == operation.changeSequence
                                          && change.scopeRevision == operation.scopeRevision
                                          && change.assetID == operation.assetID
                                          && change.tagID == operation.tagID
                                          && (operation.createdTagName == nil
                                              || change.tagName == operation.createdTagName)
                                          && change.decision == operation.decision
                                          && change.fieldRevision == operation.resultingRevision
                                  }
                          }
                          && (record.tagOperations ?? []).allSatisfy {
                              $0.receipt.hostID == hostID
                                  && $0.receipt.deviceID == record.deviceID
                                  && $0.receipt.operationID == $0.request.operationID
                          }
                          && (record.collectionOperations ?? []).allSatisfy {
                              $0.receipt.hostID == hostID
                                  && $0.receipt.deviceID == record.deviceID
                                  && $0.receipt.operationID == $0.request.operationID
                          }
                          && (record.favoriteOperations ?? []).allSatisfy {
                              $0.receipt.hostID == hostID
                                  && $0.receipt.deviceID == record.deviceID
                                  && $0.receipt.operationID == $0.request.operationID
                          }
                          && (record.lastPhoneOperationSequence ?? 0) >= 0
                          && zip(changes, changes.dropFirst()).allSatisfy {
                              $0.0.sequence < $0.1.sequence
                          }
                          && changes.allSatisfy {
                              $0.sequence > 0 && $0.fieldRevision > 0
                                  && $0.scopeRevision >= 0
                                  && $0.scopeRevision <= record.request.scopeRevision
                          }
                          && zip(collectionChanges, collectionChanges.dropFirst()).allSatisfy {
                              $0.0.sequence < $0.1.sequence
                          }
                          && collectionChanges.allSatisfy {
                              $0.sequence > 0 && $0.fieldRevision > 0
                                  && $0.scopeRevision >= 0
                                  && $0.scopeRevision <= record.request.scopeRevision
                          }
                          && zip(favoriteChanges, favoriteChanges.dropFirst()).allSatisfy {
                              $0.0.sequence < $0.1.sequence
                          }
                          && favoriteChanges.allSatisfy {
                              $0.sequence > 0 && $0.fieldRevision > 0
                                  && $0.scopeRevision >= 0
                                  && $0.scopeRevision <= record.request.scopeRevision
                          }
                  }) else {
                throw RemoteAPIError(code: .internalError, message: "invalid sync store identity")
            }
            records = Dictionary(uniqueKeysWithValues: decoded.records.map { ($0.deviceID, $0) })
        } else {
            records = [:]
        }
    }

    func submit(
        _ request: RemoteLocalLibrarySnapshotRequest, authenticatedDeviceID: UUID
    ) throws -> RemoteLocalLibrarySnapshotReceipt {
        try validate(request)
        let previous = records[authenticatedDeviceID]
        if let previous {
            guard previous.request.hostID == hostID,
                  previous.request.installID == request.installID,
                  previous.request.sourceEpoch == request.sourceEpoch else {
                throw RemoteAPIError(code: .conflict, message: "source identity changed; rebind required")
            }
            if request.snapshotSequence == previous.request.snapshotSequence,
               request == previous.request {
                return receipt(for: previous, replayed: true)
            }
            guard request.snapshotSequence > previous.request.snapshotSequence,
                  request.scopeRevision >= previous.request.scopeRevision else {
                throw RemoteAPIError(code: .conflict, message: "stale local library snapshot")
            }
            if request.scopeRevision == previous.request.scopeRevision,
               request.selectedAssetIDs != previous.request.selectedAssetIDs {
                throw RemoteAPIError(code: .conflict, message: "share scope changed without revision")
            }
        }

        let selected = Set(request.selectedAssetIDs)
        // An omitted payload row means not visible to PhotoKit now, not an explicit revoke.
        var projection = Dictionary(uniqueKeysWithValues: (previous?
            .projectedAssets ?? []).filter { selected.contains($0.asset.id) }.map {
                ($0.asset.id, $0)
            })
        for asset in request.assets {
            projection[asset.id] = ProjectedAsset(
                asset: asset, lastVisibleSnapshotSequence: request.snapshotSequence
            )
        }
        let projectedAssets = projection.values.sorted {
            $0.asset.id.uuidString < $1.asset.id.uuidString
        }
        let previouslyProjected = Set(previous?.projectedAssets.map(\.asset.id) ?? [])
        let sharedTagFacts: [SharedTagFact]
        let sharedCollectionFacts: [SharedCollectionFact]
        let sharedFavoriteFacts: [SharedFavoriteFact]
        let importedAssetIDs: [UUID]
        if let established = previous?.sharedTagFacts {
            importedAssetIDs = projectedAssets.map(\.asset.id).filter {
                !previouslyProjected.contains($0)
            }
            let newlyImported = Set(importedAssetIDs)
            sharedTagFacts = established.filter { selected.contains($0.assetID) }
                + Self.seedTagFacts(from: projectedAssets.filter {
                    newlyImported.contains($0.asset.id)
                })
        } else {
            // One-time bootstrap for records created before the fact ledger existed.
            importedAssetIDs = projectedAssets.map(\.asset.id)
            sharedTagFacts = Self.seedTagFacts(from: projectedAssets)
        }
        if let established = previous?.sharedCollectionFacts {
            let newlyImported = Set(importedAssetIDs)
            sharedCollectionFacts = established.filter { selected.contains($0.assetID) }
                + Self.seedCollectionFacts(from: projectedAssets.filter {
                    newlyImported.contains($0.asset.id)
                })
        } else {
            sharedCollectionFacts = Self.seedCollectionFacts(from: projectedAssets)
        }
        if let established = previous?.sharedFavoriteFacts {
            let newlyImported = Set(importedAssetIDs)
            sharedFavoriteFacts = established.filter { selected.contains($0.assetID) }
                + Self.seedFavoriteFacts(from: projectedAssets.filter {
                    newlyImported.contains($0.asset.id)
                })
        } else {
            sharedFavoriteFacts = Self.seedFavoriteFacts(from: projectedAssets)
        }
        let record = Record(
            deviceID: authenticatedDeviceID, request: request,
            projectedAssets: projectedAssets,
            acceptedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded()),
            sharedTagFacts: sharedTagFacts,
            sharedCollectionFacts: sharedCollectionFacts,
            sharedFavoriteFacts: sharedFavoriteFacts,
            tagOperations: previous?.tagOperations ?? [],
            collectionOperations: previous?.collectionOperations ?? [],
            favoriteOperations: previous?.favoriteOperations ?? [],
            macTagOperations: previous?.macTagOperations ?? [],
            lastPhoneOperationSequence: previous?.lastPhoneOperationSequence ?? 0,
            importedAssetIDs: importedAssetIDs,
            tagChanges: previous?.tagChanges ?? [],
            collectionChanges: previous?.collectionChanges ?? [],
            favoriteChanges: previous?.favoriteChanges ?? []
        )
        var updated = records
        updated[authenticatedDeviceID] = record
        try persist(updated)
        return receipt(for: record, replayed: false)
    }

    /// Looks up only the current exact request. It cannot replay an old asset
    /// payload after PhotoKit permission has contracted.
    func lookupSnapshotReceipt(
        _ lookup: RemoteLocalLibrarySnapshotReceiptLookup,
        authenticatedDeviceID: UUID
    ) throws -> RemoteLocalLibrarySnapshotReceiptLookupResult {
        guard lookup.hostID == hostID,
              lookup.snapshotSequence > 0,
              lookup.scopeRevision >= 0,
              lookup.requestSHA256.count == 64,
              lookup.requestSHA256.allSatisfy({ $0.isHexDigit }) else {
            throw RemoteAPIError(code: .badRequest, message: "invalid snapshot receipt lookup")
        }
        guard let record = records[authenticatedDeviceID] else {
            return .init(receipt: nil)
        }
        guard record.request.installID == lookup.installID,
              record.request.sourceEpoch == lookup.sourceEpoch else {
            throw RemoteAPIError(code: .conflict, message: "source identity changed; rebind required")
        }
        if record.request.snapshotSequence < lookup.snapshotSequence {
            return .init(receipt: nil)
        }
        guard record.request.snapshotSequence == lookup.snapshotSequence,
              record.request.scopeRevision == lookup.scopeRevision,
              try record.request.canonicalSHA256() == lookup.requestSHA256 else {
            throw RemoteAPIError(code: .conflict, message: "snapshot receipt no longer matches")
        }
        return .init(receipt: receipt(for: record, replayed: true))
    }

    func projection(deviceID: UUID) -> Projection? {
        guard let record = records[deviceID] else { return nil }
        return Projection(
            deviceID: deviceID,
            installID: record.request.installID,
            sourceEpoch: record.request.sourceEpoch,
            scopeRevision: record.request.scopeRevision,
            snapshotSequence: record.request.snapshotSequence,
            acceptedAtMs: record.acceptedAtMs,
            selectedAssetIDs: record.request.selectedAssetIDs,
            assets: record.projectedAssets,
            sharedTagFacts: record.sharedTagFacts ?? Self.seedTagFacts(from: record.projectedAssets),
            sharedCollectionFacts: record.sharedCollectionFacts
                ?? Self.seedCollectionFacts(from: record.projectedAssets),
            sharedFavoriteFacts: record.sharedFavoriteFacts
                ?? Self.seedFavoriteFacts(from: record.projectedAssets)
        )
    }

    func projections() -> [Projection] {
        records.keys.sorted { $0.uuidString < $1.uuidString }
            .compactMap { projection(deviceID: $0) }
    }

    /// Compares a phone-local candidate checkpoint with this Host's current
    /// projection and change-log heads. A later Mac edit or phone snapshot
    /// invalidates the candidate; no completion receipt is issued here.
    func matchesMigrationCheckpoint(
        _ snapshot: ImageAllMigrationFactSnapshot, manifestSHA256: String
    ) -> Bool {
        guard let checkpoint = snapshot.syncCheckpoint,
              checkpoint.archiveManifestSHA256 == manifestSHA256,
              checkpoint.sourceVerifiedAtMs != nil,
              checkpoint.hostID == hostID,
              let record = records[checkpoint.deviceID],
              record.request.installID == snapshot.sourceDeviceID,
              record.request.sourceEpoch == snapshot.sourceEpoch,
              record.request.scopeRevision == snapshot.scopeRevision,
              record.request.snapshotSequence == checkpoint.acknowledgedSnapshotSequence,
              checkpoint.acknowledgedScopeRevision == snapshot.scopeRevision,
              checkpoint.tagChangeCursor == (record.tagChanges?.last?.sequence ?? 0),
              checkpoint.collectionChangeCursor == (record.collectionChanges?.last?.sequence ?? 0),
              checkpoint.favoriteChangeCursor == (record.favoriteChanges?.last?.sequence ?? 0),
              let view = projection(deviceID: checkpoint.deviceID) else { return false }
        let selected = Set(record.request.selectedAssetIDs)
        let candidateIDs = snapshot.items.map(\.mediaID)
        guard Set(candidateIDs).count == candidateIDs.count else { return false }
        let factsByID = Dictionary(uniqueKeysWithValues: snapshot.items.map {
            ($0.mediaID, $0)
        })
        guard selected.count == record.request.selectedAssetIDs.count,
              selected == Set(factsByID.keys),
              Set(view.assets.map(\.asset.id)) == selected,
              view.assets.allSatisfy({
                  $0.lastVisibleSnapshotSequence == record.request.snapshotSequence
              }) else { return false }
        let aliases = checkpoint.tagAliases ?? []
        var localTagNames: [UUID: String] = [:]
        for fact in snapshot.items {
            for tag in fact.tagDecisions {
                if let earlier = localTagNames[tag.tagID], earlier != tag.tagName {
                    return false
                }
                localTagNames[tag.tagID] = tag.tagName
            }
        }
        guard Set(aliases.map(\.localTagID)).count == aliases.count,
              Set(aliases.map(\.remoteTagID)).count == aliases.count,
              aliases.allSatisfy({
                  $0.localTagID != $0.remoteTagID &&
                  localTagNames[$0.localTagID] == $0.localTagName &&
                  Self.sameTagIdentityName($0.localTagName, $0.remoteTagName)
              }) else {
            return false
        }
        let aliasesByLocal = Dictionary(uniqueKeysWithValues: aliases.map {
            ($0.localTagID, $0)
        })
        let resolvedTagIDs = localTagNames.keys.map {
            aliasesByLocal[$0]?.remoteTagID ?? $0
        }
        guard Set(resolvedTagIDs).count == resolvedTagIDs.count else { return false }
        let collectionAliases = checkpoint.collectionAliases ?? []
        var localCollectionNames: [UUID: String] = [:]
        for fact in snapshot.items {
            for collection in fact.collections {
                if let earlier = localCollectionNames[collection.collectionID],
                   earlier != collection.collectionName {
                    return false
                }
                localCollectionNames[collection.collectionID] = collection.collectionName
            }
        }
        guard Set(collectionAliases.map(\.localCollectionID)).count == collectionAliases.count,
              Set(collectionAliases.map(\.remoteCollectionID)).count == collectionAliases.count,
              collectionAliases.allSatisfy({
                  $0.localCollectionID != $0.remoteCollectionID &&
                  localCollectionNames[$0.localCollectionID] == $0.localCollectionName &&
                  Self.sameCollectionIdentityName(
                      $0.localCollectionName, $0.remoteCollectionName
                  )
              }) else { return false }
        let collectionAliasesByLocal = Dictionary(uniqueKeysWithValues: collectionAliases.map {
            ($0.localCollectionID, $0)
        })
        let resolvedCollectionIDs = localCollectionNames.keys.map {
            collectionAliasesByLocal[$0]?.remoteCollectionID ?? $0
        }
        guard Set(resolvedCollectionIDs).count == resolvedCollectionIDs.count else { return false }
        for projected in view.assets {
            let asset = projected.asset
            guard let fact = factsByID[asset.id],
                  fact.observedFavorite == asset.observedFavorite else { return false }
            let tags = view.sharedTagFacts.filter { $0.assetID == asset.id }
            guard tags.count == fact.tagDecisions.count,
                  Set(tags.map(\.tagID)).count == tags.count else { return false }
            let tagsByID = Dictionary(uniqueKeysWithValues: tags.map { ($0.tagID, $0) })
            let expectedTagIDs = Set(fact.tagDecisions.map {
                aliasesByLocal[$0.tagID]?.remoteTagID ?? $0.tagID
            })
            guard expectedTagIDs.count == fact.tagDecisions.count,
                  expectedTagIDs == Set(tagsByID.keys) else { return false }
            for expected in fact.tagDecisions {
                let alias = aliasesByLocal[expected.tagID]
                let remoteID = alias?.remoteTagID ?? expected.tagID
                let remoteName = alias?.remoteTagName ?? expected.tagName
                guard let actual = tagsByID[remoteID],
                      actual.tagName == remoteName,
                      actual.decision == expected.decision else { return false }
            }
            let included = view.sharedCollectionFacts.filter {
                $0.assetID == asset.id && $0.included
            }
            let expectedIncluded = fact.collections.filter(\.included)
            guard included.count == expectedIncluded.count,
                  Set(included.map(\.collectionID)).count == included.count else { return false }
            let collectionsByID = Dictionary(uniqueKeysWithValues: included.map {
                ($0.collectionID, $0)
            })
            let expectedCollectionIDs = Set(expectedIncluded.map {
                collectionAliasesByLocal[$0.collectionID]?.remoteCollectionID ?? $0.collectionID
            })
            guard expectedCollectionIDs.count == expectedIncluded.count,
                  expectedCollectionIDs == Set(collectionsByID.keys) else { return false }
            for expected in expectedIncluded {
                let alias = collectionAliasesByLocal[expected.collectionID]
                let remoteID = alias?.remoteCollectionID ?? expected.collectionID
                let remoteName = alias?.remoteCollectionName ?? expected.collectionName
                guard let actual = collectionsByID[remoteID],
                      actual.collectionName == remoteName else { return false }
            }
            let targets = view.sharedFavoriteFacts.filter { $0.assetID == asset.id }
            guard targets.count <= 1,
                  targets.first?.target == fact.favoriteTarget else { return false }
        }
        return true
    }

    func submitTagDecision(
        _ request: RemoteLocalLibraryTagDecisionRequest,
        authenticatedDeviceID: UUID
    ) throws -> RemoteLocalLibraryTagDecisionReceipt {
        guard request.schemaVersion == 1,
              request.hostID == hostID,
              request.deviceSequence > 0,
              request.baseRevision >= 0,
              !request.tagName.isEmpty,
              request.tagName == request.tagName.trimmingCharacters(in: .whitespacesAndNewlines),
              request.tagName.count <= 120,
              request.tagName.utf8.count <= 512 else {
            throw RemoteAPIError(code: .badRequest, message: "invalid shared tag decision")
        }
        guard let previous = records[authenticatedDeviceID] else {
            throw RemoteAPIError(code: .notFound, message: "phone share scope not established")
        }
        let digest = try Self.payloadSHA256(request)
        if let prior = previous.tagOperations?.first(where: {
            $0.request.operationID == request.operationID
        }) {
            guard prior.payloadSHA256 == digest else {
                throw RemoteAPIError(code: .conflict, message: "operation ID reused with different payload")
            }
            let saved = prior.receipt
            return RemoteLocalLibraryTagDecisionReceipt(
                hostID: saved.hostID, deviceID: saved.deviceID,
                operationID: saved.operationID, disposition: saved.disposition,
                fieldRevision: saved.fieldRevision, currentDecision: saved.currentDecision,
                replayed: true, conflictReason: saved.conflictReason
            )
        }
        guard !(previous.collectionOperations ?? []).contains(where: {
            $0.request.operationID == request.operationID
        }), !(previous.favoriteOperations ?? []).contains(where: {
            $0.request.operationID == request.operationID
        }) else {
            throw RemoteAPIError(code: .conflict, message: "operation ID reused for another field")
        }
        guard request.installID == previous.request.installID,
              request.sourceEpoch == previous.request.sourceEpoch,
              request.scopeRevision == previous.request.scopeRevision,
              request.deviceSequence > (previous.lastPhoneOperationSequence ?? 0),
              previous.request.selectedAssetIDs.contains(request.assetID),
              previous.projectedAssets.contains(where: {
                  $0.asset.id == request.assetID
                      && $0.lastVisibleSnapshotSequence == previous.request.snapshotSequence
              }) else {
            throw RemoteAPIError(code: .conflict, message: "stale or unauthorized phone tag decision")
        }
        var facts = previous.sharedTagFacts ?? Self.seedTagFacts(from: previous.projectedAssets)
        let index = facts.firstIndex {
            $0.assetID == request.assetID && $0.tagID == request.tagID
        }
        let current = index.map { facts[$0] }
        let revision = current?.revision ?? 0
        let disposition: RemoteLocalLibraryTagDecisionDisposition
        let resultingRevision: Int64
        let resultingDecision: RemoteLocalLibraryDecision?
        let conflictReason: RemoteLocalLibraryTagConflictReason?
        if let current, current.tagName != request.tagName {
            disposition = .conflict
            resultingRevision = revision
            resultingDecision = current.decision
            conflictReason = .tagIdentity
        } else if facts.contains(where: {
            $0.tagID != request.tagID
                && $0.tagName.localizedCaseInsensitiveCompare(request.tagName) == .orderedSame
        }) {
            // A same-name/different-ID tag needs an explicit alias decision.
            disposition = .conflict
            resultingRevision = revision
            resultingDecision = current?.decision
            conflictReason = .nameAlias
        } else if current?.decision == request.decision {
            disposition = .unchanged
            resultingRevision = revision
            resultingDecision = current?.decision
            conflictReason = nil
        } else if request.baseRevision != revision {
            disposition = .conflict
            resultingRevision = revision
            resultingDecision = current?.decision
            conflictReason = .fieldVersion
        } else {
            guard revision < Int64.max else {
                throw RemoteAPIError(code: .internalError, message: "shared field revision exhausted")
            }
            disposition = .applied
            resultingRevision = revision + 1
            resultingDecision = request.decision
            conflictReason = nil
            let fact = SharedTagFact(
                assetID: request.assetID, tagID: request.tagID,
                tagName: request.tagName, decision: request.decision,
                revision: resultingRevision
            )
            if let index { facts[index] = fact } else { facts.append(fact) }
        }
        let receipt = RemoteLocalLibraryTagDecisionReceipt(
            hostID: hostID, deviceID: authenticatedDeviceID,
            operationID: request.operationID, disposition: disposition,
            fieldRevision: resultingRevision, currentDecision: resultingDecision,
            replayed: false, conflictReason: conflictReason
        )
        let operation = TagOperationRecord(
            request: request, payloadSHA256: digest, receipt: receipt
        )
        let record = Record(
            deviceID: previous.deviceID, request: previous.request,
            projectedAssets: previous.projectedAssets,
            acceptedAtMs: previous.acceptedAtMs,
            sharedTagFacts: facts.sorted {
                ($0.assetID.uuidString, $0.tagID.uuidString)
                    < ($1.assetID.uuidString, $1.tagID.uuidString)
            },
            sharedCollectionFacts: previous.sharedCollectionFacts,
            sharedFavoriteFacts: previous.sharedFavoriteFacts,
            tagOperations: (previous.tagOperations ?? []) + [operation],
            collectionOperations: previous.collectionOperations,
            favoriteOperations: previous.favoriteOperations,
            macTagOperations: previous.macTagOperations,
            lastPhoneOperationSequence: request.deviceSequence,
            importedAssetIDs: previous.importedAssetIDs,
            tagChanges: previous.tagChanges,
            collectionChanges: previous.collectionChanges,
            favoriteChanges: previous.favoriteChanges
        )
        var updated = records
        updated[authenticatedDeviceID] = record
        try persist(updated)
        return receipt
    }

    func submitCollectionMembership(
        _ request: RemoteLocalLibraryCollectionMembershipRequest,
        authenticatedDeviceID: UUID
    ) throws -> RemoteLocalLibraryCollectionMembershipReceipt {
        guard request.schemaVersion == 1,
              request.hostID == hostID,
              request.deviceSequence > 0,
              request.baseRevision >= 0,
              !request.collectionName.isEmpty,
              request.collectionName == request.collectionName.trimmingCharacters(in: .whitespacesAndNewlines),
              request.collectionName.count <= 160,
              request.collectionName.utf8.count <= 640 else {
            throw RemoteAPIError(code: .badRequest, message: "invalid shared collection membership")
        }
        guard let previous = records[authenticatedDeviceID] else {
            throw RemoteAPIError(code: .notFound, message: "phone share scope not established")
        }
        let digest = try Self.payloadSHA256(request)
        if let prior = previous.collectionOperations?.first(where: {
            $0.request.operationID == request.operationID
        }) {
            guard prior.payloadSHA256 == digest else {
                throw RemoteAPIError(code: .conflict, message: "operation ID reused with different payload")
            }
            let saved = prior.receipt
            return RemoteLocalLibraryCollectionMembershipReceipt(
                hostID: saved.hostID, deviceID: saved.deviceID,
                operationID: saved.operationID, disposition: saved.disposition,
                fieldRevision: saved.fieldRevision, currentIncluded: saved.currentIncluded,
                replayed: true, conflictReason: saved.conflictReason
            )
        }
        guard !(previous.tagOperations ?? []).contains(where: {
            $0.request.operationID == request.operationID
        }), !(previous.favoriteOperations ?? []).contains(where: {
            $0.request.operationID == request.operationID
        }),
              request.installID == previous.request.installID,
              request.sourceEpoch == previous.request.sourceEpoch,
              request.scopeRevision == previous.request.scopeRevision,
              request.deviceSequence > (previous.lastPhoneOperationSequence ?? 0),
              previous.request.selectedAssetIDs.contains(request.assetID),
              previous.projectedAssets.contains(where: {
                  $0.asset.id == request.assetID
                      && $0.lastVisibleSnapshotSequence == previous.request.snapshotSequence
              }) else {
            throw RemoteAPIError(code: .conflict, message: "stale or unauthorized phone collection membership")
        }
        var facts = previous.sharedCollectionFacts
            ?? Self.seedCollectionFacts(from: previous.projectedAssets)
        let index = facts.firstIndex {
            $0.assetID == request.assetID && $0.collectionID == request.collectionID
        }
        let current = index.map { facts[$0] }
        let revision = current?.revision ?? 0
        let disposition: RemoteLocalLibraryTagDecisionDisposition
        let resultingRevision: Int64
        let resultingIncluded: Bool?
        let conflictReason: RemoteLocalLibraryCollectionConflictReason?
        if facts.contains(where: {
            $0.collectionID == request.collectionID
                && $0.collectionName != request.collectionName
        }) {
            disposition = .conflict
            resultingRevision = revision
            resultingIncluded = current?.included
            conflictReason = .collectionIdentity
        } else if facts.contains(where: {
            $0.collectionID != request.collectionID
                && $0.collectionName.localizedCaseInsensitiveCompare(request.collectionName) == .orderedSame
        }) {
            disposition = .conflict
            resultingRevision = revision
            resultingIncluded = current?.included
            conflictReason = .nameAlias
        } else if current?.included == request.included {
            disposition = .unchanged
            resultingRevision = revision
            resultingIncluded = current?.included
            conflictReason = nil
        } else if request.baseRevision != revision {
            disposition = .conflict
            resultingRevision = revision
            resultingIncluded = current?.included
            conflictReason = .fieldVersion
        } else {
            guard revision < Int64.max else {
                throw RemoteAPIError(code: .internalError, message: "shared field revision exhausted")
            }
            disposition = .applied
            resultingRevision = revision + 1
            resultingIncluded = request.included
            conflictReason = nil
            let fact = SharedCollectionFact(
                assetID: request.assetID, collectionID: request.collectionID,
                collectionName: request.collectionName,
                included: request.included, revision: resultingRevision
            )
            if let index { facts[index] = fact } else { facts.append(fact) }
        }
        let receipt = RemoteLocalLibraryCollectionMembershipReceipt(
            hostID: hostID, deviceID: authenticatedDeviceID,
            operationID: request.operationID, disposition: disposition,
            fieldRevision: resultingRevision, currentIncluded: resultingIncluded,
            replayed: false, conflictReason: conflictReason
        )
        let record = Record(
            deviceID: previous.deviceID, request: previous.request,
            projectedAssets: previous.projectedAssets, acceptedAtMs: previous.acceptedAtMs,
            sharedTagFacts: previous.sharedTagFacts,
            sharedCollectionFacts: facts.sorted {
                ($0.assetID.uuidString, $0.collectionID.uuidString)
                    < ($1.assetID.uuidString, $1.collectionID.uuidString)
            },
            sharedFavoriteFacts: previous.sharedFavoriteFacts,
            tagOperations: previous.tagOperations,
            collectionOperations: (previous.collectionOperations ?? []) + [
                CollectionOperationRecord(
                    request: request, payloadSHA256: digest, receipt: receipt
                )
            ],
            favoriteOperations: previous.favoriteOperations,
            macTagOperations: previous.macTagOperations,
            lastPhoneOperationSequence: request.deviceSequence,
            importedAssetIDs: previous.importedAssetIDs,
            tagChanges: previous.tagChanges,
            collectionChanges: previous.collectionChanges,
            favoriteChanges: previous.favoriteChanges
        )
        var updated = records
        updated[authenticatedDeviceID] = record
        try persist(updated)
        return receipt
    }

    func submitFavoriteTarget(
        _ request: RemoteLocalLibraryFavoriteTargetRequest,
        authenticatedDeviceID: UUID
    ) throws -> RemoteLocalLibraryFavoriteTargetReceipt {
        guard request.schemaVersion == 1,
              request.hostID == hostID,
              request.deviceSequence > 0,
              request.baseRevision >= 0 else {
            throw RemoteAPIError(code: .badRequest, message: "invalid shared favorite target")
        }
        guard let previous = records[authenticatedDeviceID] else {
            throw RemoteAPIError(code: .notFound, message: "phone share scope not established")
        }
        let digest = try Self.payloadSHA256(request)
        if let prior = previous.favoriteOperations?.first(where: {
            $0.request.operationID == request.operationID
        }) {
            guard prior.payloadSHA256 == digest else {
                throw RemoteAPIError(code: .conflict, message: "operation ID reused with different payload")
            }
            let saved = prior.receipt
            return RemoteLocalLibraryFavoriteTargetReceipt(
                hostID: saved.hostID, deviceID: saved.deviceID,
                operationID: saved.operationID, disposition: saved.disposition,
                fieldRevision: saved.fieldRevision, currentTarget: saved.currentTarget,
                replayed: true
            )
        }
        guard !(previous.tagOperations ?? []).contains(where: {
            $0.request.operationID == request.operationID
        }), !(previous.collectionOperations ?? []).contains(where: {
            $0.request.operationID == request.operationID
        }),
              request.installID == previous.request.installID,
              request.sourceEpoch == previous.request.sourceEpoch,
              request.scopeRevision == previous.request.scopeRevision,
              request.deviceSequence > (previous.lastPhoneOperationSequence ?? 0),
              previous.request.selectedAssetIDs.contains(request.assetID),
              previous.projectedAssets.contains(where: {
                  $0.asset.id == request.assetID
                      && $0.lastVisibleSnapshotSequence == previous.request.snapshotSequence
              }) else {
            throw RemoteAPIError(code: .conflict, message: "stale or unauthorized phone favorite target")
        }
        var facts = previous.sharedFavoriteFacts
            ?? Self.seedFavoriteFacts(from: previous.projectedAssets)
        let index = facts.firstIndex { $0.assetID == request.assetID }
        let current = index.map { facts[$0] }
        let revision = current?.revision ?? 0
        let disposition: RemoteLocalLibraryTagDecisionDisposition
        let resultingRevision: Int64
        let resultingTarget: Bool?
        if current?.target == request.target {
            disposition = .unchanged
            resultingRevision = revision
            resultingTarget = current?.target
        } else if request.baseRevision != revision {
            disposition = .conflict
            resultingRevision = revision
            resultingTarget = current?.target
        } else {
            guard revision < Int64.max else {
                throw RemoteAPIError(code: .internalError, message: "shared field revision exhausted")
            }
            disposition = .applied
            resultingRevision = revision + 1
            resultingTarget = request.target
            let fact = SharedFavoriteFact(
                assetID: request.assetID, target: request.target,
                revision: resultingRevision
            )
            if let index { facts[index] = fact } else { facts.append(fact) }
        }
        let receipt = RemoteLocalLibraryFavoriteTargetReceipt(
            hostID: hostID, deviceID: authenticatedDeviceID,
            operationID: request.operationID, disposition: disposition,
            fieldRevision: resultingRevision, currentTarget: resultingTarget,
            replayed: false
        )
        let record = Record(
            deviceID: previous.deviceID, request: previous.request,
            projectedAssets: previous.projectedAssets,
            acceptedAtMs: previous.acceptedAtMs,
            sharedTagFacts: previous.sharedTagFacts,
            sharedCollectionFacts: previous.sharedCollectionFacts,
            sharedFavoriteFacts: facts.sorted {
                $0.assetID.uuidString < $1.assetID.uuidString
            },
            tagOperations: previous.tagOperations,
            collectionOperations: previous.collectionOperations,
            favoriteOperations: (previous.favoriteOperations ?? []) + [
                FavoriteOperationRecord(
                    request: request, payloadSHA256: digest, receipt: receipt
                )
            ],
            macTagOperations: previous.macTagOperations,
            lastPhoneOperationSequence: request.deviceSequence,
            importedAssetIDs: previous.importedAssetIDs,
            tagChanges: previous.tagChanges,
            collectionChanges: previous.collectionChanges,
            favoriteChanges: previous.favoriteChanges
        )
        var updated = records
        updated[authenticatedDeviceID] = record
        try persist(updated)
        return receipt
    }

    /// Mac owner changes a fact in the shared phone source. The field revision and
    /// outbound change are published together in the same atomic record replacement.
    func setTagDecisionFromMac(
        deviceID: UUID, assetID: UUID, tagID: UUID,
        decision: RemoteLocalLibraryDecision, expectedRevision: Int64,
        expectedInstallID: UUID? = nil, expectedSourceEpoch: UUID? = nil,
        expectedScopeRevision: Int64? = nil,
        operationID: UUID? = nil,
        tagNameForCreate: String? = nil
    ) throws -> Projection {
        guard let previous = records[deviceID] else {
            throw RemoteAPIError(code: .notFound, message: "shared phone source unavailable")
        }
        if let operationID,
           let applied = previous.macTagOperations?.first(where: {
               $0.operationID == operationID
           }) {
            guard applied.assetID == assetID, applied.tagID == tagID,
                  applied.createdTagName == tagNameForCreate,
                  applied.decision == decision,
                  applied.expectedRevision == expectedRevision,
                  expectedInstallID.map({ $0 == applied.installID }) ?? true,
                  expectedSourceEpoch.map({ $0 == applied.sourceEpoch }) ?? true,
                  expectedScopeRevision.map({ $0 == applied.scopeRevision }) ?? true else {
                throw RemoteAPIError(code: .conflict, message: "Mac tag operation payload changed")
            }
            return projection(deviceID: deviceID)!
        }
        guard previous.request.selectedAssetIDs.contains(assetID),
              previous.projectedAssets.contains(where: { $0.asset.id == assetID }) else {
            throw RemoteAPIError(code: .notFound, message: "shared phone asset unavailable")
        }
        guard expectedInstallID.map({ $0 == previous.request.installID }) ?? true,
              expectedSourceEpoch.map({ $0 == previous.request.sourceEpoch }) ?? true,
              expectedScopeRevision.map({ $0 == previous.request.scopeRevision }) ?? true else {
            throw RemoteAPIError(code: .conflict, message: "shared phone scope changed")
        }
        var facts = previous.sharedTagFacts ?? Self.seedTagFacts(from: previous.projectedAssets)
        let index = facts.firstIndex { $0.assetID == assetID && $0.tagID == tagID }
        let nextRevision: Int64
        let tagName: String
        if let index {
            guard tagNameForCreate == nil else {
                throw RemoteAPIError(code: .conflict, message: "shared tag already exists")
            }
            let current = facts[index]
            guard current.revision == expectedRevision else {
                throw RemoteAPIError(code: .conflict, message: "shared phone tag changed")
            }
            if current.decision == decision {
                return projection(deviceID: deviceID)!
            }
            guard current.revision < Int64.max else {
                throw RemoteAPIError(code: .internalError, message: "shared change revision exhausted")
            }
            nextRevision = current.revision + 1
            tagName = current.tagName
            facts[index] = SharedTagFact(
                assetID: assetID, tagID: tagID, tagName: tagName,
                decision: decision, revision: nextRevision
            )
        } else {
            guard expectedRevision == 0, operationID != nil,
                  decision != .cleared,
                  let candidate = tagNameForCreate,
                  candidate == candidate.trimmingCharacters(in: .whitespacesAndNewlines),
                  !candidate.isEmpty, candidate.count <= 120,
                  candidate.utf8.count <= 512,
                  !facts.contains(where: {
                      ($0.tagID == tagID && $0.tagName != candidate)
                          || ($0.tagID != tagID
                              && Self.sameTagIdentityName($0.tagName, candidate))
                  }),
                  !previous.projectedAssets.contains(where: { projected in
                      projected.asset.tagDecisions.contains { tag in
                          (tag.tagID == tagID && tag.tagName != candidate)
                              || (tag.tagID != tagID
                                  && Self.sameTagIdentityName(tag.tagName, candidate))
                      }
                  }) else {
                throw RemoteAPIError(code: .conflict, message: "new shared tag identity changed")
            }
            nextRevision = 1
            tagName = candidate
            facts.append(SharedTagFact(
                assetID: assetID, tagID: tagID, tagName: candidate,
                decision: decision, revision: 1
            ))
        }
        guard (previous.tagChanges?.last?.sequence ?? 0) < Int64.max else {
            throw RemoteAPIError(code: .internalError, message: "shared change revision exhausted")
        }
        let nextSequence = (previous.tagChanges?.last?.sequence ?? 0) + 1
        let change = RemoteLocalLibraryTagChange(
            sequence: nextSequence, scopeRevision: previous.request.scopeRevision,
            assetID: assetID, tagID: tagID,
            tagName: tagName, decision: decision, fieldRevision: nextRevision
        )
        let operation = operationID.map { id in
            MacTagOperationReceipt(
                operationID: id, deviceID: deviceID,
                installID: previous.request.installID,
                sourceEpoch: previous.request.sourceEpoch,
                scopeRevision: previous.request.scopeRevision,
                assetID: assetID, tagID: tagID,
                createdTagName: tagNameForCreate, decision: decision,
                expectedRevision: expectedRevision,
                resultingRevision: nextRevision,
                changeSequence: nextSequence
            )
        }
        let record = Record(
            deviceID: previous.deviceID, request: previous.request,
            projectedAssets: previous.projectedAssets,
            acceptedAtMs: previous.acceptedAtMs,
            sharedTagFacts: facts,
            sharedCollectionFacts: previous.sharedCollectionFacts,
            sharedFavoriteFacts: previous.sharedFavoriteFacts,
            tagOperations: previous.tagOperations,
            collectionOperations: previous.collectionOperations,
            favoriteOperations: previous.favoriteOperations,
            macTagOperations: (previous.macTagOperations ?? []) +
                (operation.map { [$0] } ?? []),
            lastPhoneOperationSequence: previous.lastPhoneOperationSequence,
            importedAssetIDs: previous.importedAssetIDs,
            tagChanges: (previous.tagChanges ?? []) + [change],
            collectionChanges: previous.collectionChanges,
            favoriteChanges: previous.favoriteChanges
        )
        var updated = records
        updated[deviceID] = record
        try persist(updated)
        return projection(deviceID: deviceID)!
    }

    func macTagOperation(
        deviceID: UUID, operationID: UUID
    ) -> MacTagOperationReceipt? {
        records[deviceID]?.macTagOperations?.first { $0.operationID == operationID }
    }

    func tagChanges(
        deviceID: UUID, sourceEpoch: UUID, scopeRevision: Int64,
        afterCursor: Int64, limit: Int = 100
    ) throws -> RemoteLocalLibraryTagChangesPage {
        guard let record = records[deviceID] else {
            throw RemoteAPIError(code: .notFound, message: "phone share scope not established")
        }
        guard sourceEpoch == record.request.sourceEpoch,
              scopeRevision == record.request.scopeRevision,
              afterCursor >= 0, limit > 0, limit <= 100 else {
            throw RemoteAPIError(code: .conflict, message: "shared tag cursor scope changed")
        }
        let all = record.tagChanges ?? []
        guard afterCursor <= (all.last?.sequence ?? 0) else {
            throw RemoteAPIError(code: .conflict, message: "shared tag cursor beyond log")
        }
        let selected = Set(record.request.selectedAssetIDs)
        let filtered = all.filter {
            $0.sequence > afterCursor && $0.scopeRevision == scopeRevision
                && selected.contains($0.assetID)
        }
        let page = Array(filtered.prefix(limit))
        return RemoteLocalLibraryTagChangesPage(
            hostID: hostID, deviceID: deviceID,
            sourceEpoch: sourceEpoch, scopeRevision: scopeRevision,
            changes: page,
            nextCursor: page.last?.sequence ?? (filtered.isEmpty ? (all.last?.sequence ?? afterCursor) : afterCursor),
            hasMore: filtered.count > page.count
        )
    }

    /// Mac creates one ImageAll collection in this phone's shared namespace and
    /// includes a currently visible shared asset. The generated ID is the retry key.
    func createCollectionFromMac(
        deviceID: UUID, assetID: UUID, collectionID: UUID,
        collectionName: String, expectedInstallID: UUID,
        expectedSourceEpoch: UUID, expectedScopeRevision: Int64,
        expectedSnapshotSequence: Int64
    ) throws -> Projection {
        guard let previous = records[deviceID] else {
            throw RemoteAPIError(code: .notFound, message: "shared phone source unavailable")
        }
        guard previous.request.installID == expectedInstallID,
              previous.request.sourceEpoch == expectedSourceEpoch,
              previous.request.scopeRevision == expectedScopeRevision,
              previous.request.snapshotSequence == expectedSnapshotSequence,
              previous.request.selectedAssetIDs.contains(assetID),
              previous.projectedAssets.contains(where: {
                  $0.asset.id == assetID &&
                  $0.lastVisibleSnapshotSequence == expectedSnapshotSequence
              }) else {
            throw RemoteAPIError(code: .conflict, message: "shared phone scope changed")
        }
        guard collectionName == collectionName.trimmingCharacters(in: .whitespacesAndNewlines),
              !collectionName.isEmpty,
              collectionName.count <= 160, collectionName.utf8.count <= 640 else {
            throw RemoteAPIError(code: .badRequest, message: "invalid shared collection name")
        }
        var facts = previous.sharedCollectionFacts
            ?? Self.seedCollectionFacts(from: previous.projectedAssets)
        if let existing = facts.first(where: { $0.collectionID == collectionID }) {
            guard existing.collectionName == collectionName,
                  existing.assetID == assetID, existing.included else {
                throw RemoteAPIError(code: .conflict, message: "shared collection identity changed")
            }
            return projection(deviceID: deviceID)!
        }
        guard !facts.contains(where: {
            Self.sameCollectionIdentityName($0.collectionName, collectionName)
        }) else {
            throw RemoteAPIError(code: .conflict, message: "shared collection name already exists")
        }
        guard (previous.collectionChanges?.last?.sequence ?? 0) < Int64.max else {
            throw RemoteAPIError(code: .internalError, message: "shared change revision exhausted")
        }
        let nextSequence = (previous.collectionChanges?.last?.sequence ?? 0) + 1
        facts.append(SharedCollectionFact(
            assetID: assetID, collectionID: collectionID,
            collectionName: collectionName, included: true, revision: 1
        ))
        let change = RemoteLocalLibraryCollectionChange(
            sequence: nextSequence, scopeRevision: expectedScopeRevision,
            assetID: assetID, collectionID: collectionID,
            collectionName: collectionName, included: true, fieldRevision: 1
        )
        let record = Record(
            deviceID: previous.deviceID, request: previous.request,
            projectedAssets: previous.projectedAssets,
            acceptedAtMs: previous.acceptedAtMs,
            sharedTagFacts: previous.sharedTagFacts,
            sharedCollectionFacts: facts.sorted {
                ($0.assetID.uuidString, $0.collectionID.uuidString)
                    < ($1.assetID.uuidString, $1.collectionID.uuidString)
            },
            sharedFavoriteFacts: previous.sharedFavoriteFacts,
            tagOperations: previous.tagOperations,
            collectionOperations: previous.collectionOperations,
            favoriteOperations: previous.favoriteOperations,
            macTagOperations: previous.macTagOperations,
            lastPhoneOperationSequence: previous.lastPhoneOperationSequence,
            importedAssetIDs: previous.importedAssetIDs,
            tagChanges: previous.tagChanges,
            collectionChanges: (previous.collectionChanges ?? []) + [change],
            favoriteChanges: previous.favoriteChanges
        )
        var updated = records
        updated[deviceID] = record
        try persist(updated)
        return projection(deviceID: deviceID)!
    }

    /// Mac edits a member field within the already shared phone collection namespace.
    /// The collection ID must have been introduced by the phone; no name-based merge occurs.
    func setCollectionMembershipFromMac(
        deviceID: UUID, assetID: UUID, collectionID: UUID,
        included: Bool, expectedRevision: Int64
    ) throws -> Projection {
        guard let previous = records[deviceID],
              previous.request.selectedAssetIDs.contains(assetID),
              previous.projectedAssets.contains(where: { $0.asset.id == assetID }),
              expectedRevision >= 0 else {
            throw RemoteAPIError(code: .notFound, message: "shared phone asset unavailable")
        }
        var facts = previous.sharedCollectionFacts
            ?? Self.seedCollectionFacts(from: previous.projectedAssets)
        let names = Set(facts.filter { $0.collectionID == collectionID }.map(\.collectionName))
        guard names.count == 1, let collectionName = names.first else {
            throw RemoteAPIError(code: .notFound, message: "shared phone collection unavailable")
        }
        let index = facts.firstIndex {
            $0.assetID == assetID && $0.collectionID == collectionID
        }
        let current = index.map { facts[$0] }
        guard (current?.revision ?? 0) == expectedRevision else {
            throw RemoteAPIError(code: .conflict, message: "shared phone collection member changed")
        }
        if current?.included == included || (current == nil && !included) {
            return projection(deviceID: deviceID)!
        }
        guard expectedRevision < Int64.max,
              (previous.collectionChanges?.last?.sequence ?? 0) < Int64.max else {
            throw RemoteAPIError(code: .internalError, message: "shared change revision exhausted")
        }
        let nextRevision = expectedRevision + 1
        let nextSequence = (previous.collectionChanges?.last?.sequence ?? 0) + 1
        let fact = SharedCollectionFact(
            assetID: assetID, collectionID: collectionID,
            collectionName: collectionName, included: included,
            revision: nextRevision
        )
        if let index { facts[index] = fact } else { facts.append(fact) }
        let change = RemoteLocalLibraryCollectionChange(
            sequence: nextSequence, scopeRevision: previous.request.scopeRevision,
            assetID: assetID, collectionID: collectionID,
            collectionName: collectionName, included: included,
            fieldRevision: nextRevision
        )
        let record = Record(
            deviceID: previous.deviceID, request: previous.request,
            projectedAssets: previous.projectedAssets,
            acceptedAtMs: previous.acceptedAtMs,
            sharedTagFacts: previous.sharedTagFacts,
            sharedCollectionFacts: facts.sorted {
                ($0.assetID.uuidString, $0.collectionID.uuidString)
                    < ($1.assetID.uuidString, $1.collectionID.uuidString)
            },
            sharedFavoriteFacts: previous.sharedFavoriteFacts,
            tagOperations: previous.tagOperations,
            collectionOperations: previous.collectionOperations,
            favoriteOperations: previous.favoriteOperations,
            macTagOperations: previous.macTagOperations,
            lastPhoneOperationSequence: previous.lastPhoneOperationSequence,
            importedAssetIDs: previous.importedAssetIDs,
            tagChanges: previous.tagChanges,
            collectionChanges: (previous.collectionChanges ?? []) + [change],
            favoriteChanges: previous.favoriteChanges
        )
        var updated = records
        updated[deviceID] = record
        try persist(updated)
        return projection(deviceID: deviceID)!
    }

    func collectionChanges(
        deviceID: UUID, sourceEpoch: UUID, scopeRevision: Int64,
        afterCursor: Int64, limit: Int = 100
    ) throws -> RemoteLocalLibraryCollectionChangesPage {
        guard let record = records[deviceID] else {
            throw RemoteAPIError(code: .notFound, message: "phone share scope not established")
        }
        guard sourceEpoch == record.request.sourceEpoch,
              scopeRevision == record.request.scopeRevision,
              afterCursor >= 0, limit > 0, limit <= 100 else {
            throw RemoteAPIError(code: .conflict, message: "shared collection cursor scope changed")
        }
        let all = record.collectionChanges ?? []
        guard afterCursor <= (all.last?.sequence ?? 0) else {
            throw RemoteAPIError(code: .conflict, message: "shared collection cursor beyond log")
        }
        let selected = Set(record.request.selectedAssetIDs)
        let filtered = all.filter {
            $0.sequence > afterCursor && $0.scopeRevision == scopeRevision
                && selected.contains($0.assetID)
        }
        let page = Array(filtered.prefix(limit))
        return RemoteLocalLibraryCollectionChangesPage(
            hostID: hostID, deviceID: deviceID,
            sourceEpoch: sourceEpoch, scopeRevision: scopeRevision,
            changes: page,
            nextCursor: page.last?.sequence
                ?? (filtered.isEmpty ? (all.last?.sequence ?? afterCursor) : afterCursor),
            hasMore: filtered.count > page.count
        )
    }

    /// Mac changes the shared desired value only. The phone separately decides
    /// when its authorized PhotoKit source can be written and read back.
    func setFavoriteTargetFromMac(
        deviceID: UUID, assetID: UUID, target: Bool,
        expectedRevision: Int64
    ) throws -> Projection {
        guard let previous = records[deviceID],
              previous.request.selectedAssetIDs.contains(assetID),
              previous.projectedAssets.contains(where: { $0.asset.id == assetID }),
              expectedRevision >= 0 else {
            throw RemoteAPIError(code: .notFound, message: "shared phone asset unavailable")
        }
        var facts = previous.sharedFavoriteFacts
            ?? Self.seedFavoriteFacts(from: previous.projectedAssets)
        let index = facts.firstIndex { $0.assetID == assetID }
        let current = index.map { facts[$0] }
        guard (current?.revision ?? 0) == expectedRevision else {
            throw RemoteAPIError(code: .conflict, message: "shared phone favorite target changed")
        }
        if current?.target == target { return projection(deviceID: deviceID)! }
        guard expectedRevision < Int64.max,
              (previous.favoriteChanges?.last?.sequence ?? 0) < Int64.max else {
            throw RemoteAPIError(code: .internalError, message: "shared change revision exhausted")
        }
        let nextRevision = expectedRevision + 1
        let nextSequence = (previous.favoriteChanges?.last?.sequence ?? 0) + 1
        let fact = SharedFavoriteFact(
            assetID: assetID, target: target, revision: nextRevision
        )
        if let index { facts[index] = fact } else { facts.append(fact) }
        let change = RemoteLocalLibraryFavoriteChange(
            sequence: nextSequence, scopeRevision: previous.request.scopeRevision,
            assetID: assetID, target: target, fieldRevision: nextRevision
        )
        let record = Record(
            deviceID: previous.deviceID, request: previous.request,
            projectedAssets: previous.projectedAssets,
            acceptedAtMs: previous.acceptedAtMs,
            sharedTagFacts: previous.sharedTagFacts,
            sharedCollectionFacts: previous.sharedCollectionFacts,
            sharedFavoriteFacts: facts.sorted {
                $0.assetID.uuidString < $1.assetID.uuidString
            },
            tagOperations: previous.tagOperations,
            collectionOperations: previous.collectionOperations,
            favoriteOperations: previous.favoriteOperations,
            macTagOperations: previous.macTagOperations,
            lastPhoneOperationSequence: previous.lastPhoneOperationSequence,
            importedAssetIDs: previous.importedAssetIDs,
            tagChanges: previous.tagChanges,
            collectionChanges: previous.collectionChanges,
            favoriteChanges: (previous.favoriteChanges ?? []) + [change]
        )
        var updated = records
        updated[deviceID] = record
        try persist(updated)
        return projection(deviceID: deviceID)!
    }

    func favoriteChanges(
        deviceID: UUID, sourceEpoch: UUID, scopeRevision: Int64,
        afterCursor: Int64, limit: Int = 100
    ) throws -> RemoteLocalLibraryFavoriteChangesPage {
        guard let record = records[deviceID] else {
            throw RemoteAPIError(code: .notFound, message: "phone share scope not established")
        }
        guard sourceEpoch == record.request.sourceEpoch,
              scopeRevision == record.request.scopeRevision,
              afterCursor >= 0, limit > 0, limit <= 100 else {
            throw RemoteAPIError(code: .conflict, message: "shared favorite cursor scope changed")
        }
        let all = record.favoriteChanges ?? []
        guard afterCursor <= (all.last?.sequence ?? 0) else {
            throw RemoteAPIError(code: .conflict, message: "shared favorite cursor beyond log")
        }
        let selected = Set(record.request.selectedAssetIDs)
        let filtered = all.filter {
            $0.sequence > afterCursor && $0.scopeRevision == scopeRevision
                && selected.contains($0.assetID)
        }
        let page = Array(filtered.prefix(limit))
        return RemoteLocalLibraryFavoriteChangesPage(
            hostID: hostID, deviceID: deviceID,
            sourceEpoch: sourceEpoch, scopeRevision: scopeRevision,
            changes: page,
            nextCursor: page.last?.sequence
                ?? (filtered.isEmpty ? (all.last?.sequence ?? afterCursor) : afterCursor),
            hasMore: filtered.count > page.count
        )
    }

    private static func payloadSHA256(
        _ request: RemoteLocalLibraryTagDecisionRequest
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func payloadSHA256(
        _ request: RemoteLocalLibraryCollectionMembershipRequest
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func payloadSHA256(
        _ request: RemoteLocalLibraryFavoriteTargetRequest
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sameTagIdentityName(_ lhs: String, _ rhs: String) -> Bool {
        if case .success(let left) = TagNameNormalizer.validateAndNormalize(lhs),
           case .success(let right) = TagNameNormalizer.validateAndNormalize(rhs) {
            return left.normalizedName == right.normalizedName
        }
        return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func sameCollectionIdentityName(_ lhs: String, _ rhs: String) -> Bool {
        func key(_ value: String) -> String {
            let scalars = Array(value.precomposedStringWithCanonicalMapping.unicodeScalars)
            var normalized: [Unicode.Scalar] = []
            var inWhitespace = false
            for scalar in scalars {
                if scalar.properties.isWhitespace {
                    if !inWhitespace {
                        normalized.append(Unicode.Scalar(0x20)!)
                        inWhitespace = true
                    }
                } else {
                    normalized.append(scalar)
                    inWhitespace = false
                }
            }
            return String(String.UnicodeScalarView(normalized))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: .caseInsensitive, locale: nil)
                .precomposedStringWithCanonicalMapping
        }
        return key(lhs) == key(rhs)
    }

    private static func seedTagFacts(from assets: [ProjectedAsset]) -> [SharedTagFact] {
        assets.flatMap { projected in
            projected.asset.tagDecisions.map { tag in
                SharedTagFact(
                    assetID: projected.asset.id, tagID: tag.tagID,
                    tagName: tag.tagName, decision: tag.decision, revision: 1
                )
            }
        }.sorted {
            ($0.assetID.uuidString, $0.tagID.uuidString)
                < ($1.assetID.uuidString, $1.tagID.uuidString)
        }
    }

    private static func seedCollectionFacts(from assets: [ProjectedAsset]) -> [SharedCollectionFact] {
        assets.flatMap { projected in
            projected.asset.collections.map { collection in
                SharedCollectionFact(
                    assetID: projected.asset.id,
                    collectionID: collection.collectionID,
                    collectionName: collection.collectionName,
                    included: true, revision: 1
                )
            }
        }.sorted {
            ($0.assetID.uuidString, $0.collectionID.uuidString)
                < ($1.assetID.uuidString, $1.collectionID.uuidString)
        }
    }

    private static func seedFavoriteFacts(from assets: [ProjectedAsset]) -> [SharedFavoriteFact] {
        assets.compactMap { projected in
            projected.asset.favoriteTarget.map {
                SharedFavoriteFact(assetID: projected.asset.id, target: $0, revision: 1)
            }
        }.sorted { $0.assetID.uuidString < $1.assetID.uuidString }
    }

    private func persist(_ updated: [UUID: Record]) throws {
        let persisted = PersistedState(records: updated.values.sorted {
            $0.deviceID.uuidString < $1.deviceID.uuidString
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(persisted)
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: storageURL, options: .atomic)
        records = updated
    }

    private func receipt(
        for record: Record, replayed: Bool
    ) -> RemoteLocalLibrarySnapshotReceipt {
        RemoteLocalLibrarySnapshotReceipt(
            hostID: hostID, deviceID: record.deviceID,
            sourceEpoch: record.request.sourceEpoch,
            snapshotSequence: record.request.snapshotSequence,
            acceptedAssetCount: record.projectedAssets.count, replayed: replayed,
            importedAssetIDs: record.importedAssetIDs
        )
    }

    private func validate(_ request: RemoteLocalLibrarySnapshotRequest) throws {
        guard request.schemaVersion == 1,
              request.hostID == hostID,
              request.scopeRevision >= 0,
              request.snapshotSequence > 0,
              request.selectedAssetIDs.count <= 1_024,
              request.assets.count <= 1_024,
              Set(request.selectedAssetIDs).count == request.selectedAssetIDs.count,
              Set(request.assets.map(\.id)).count == request.assets.count
        else {
            throw RemoteAPIError(code: .badRequest, message: "invalid local library snapshot")
        }
        let selected = Set(request.selectedAssetIDs)
        for asset in request.assets {
            guard selected.contains(asset.id),
                  !asset.localIdentifier.isEmpty,
                  asset.localIdentifier.utf8.count <= 1_024,
                  asset.tagDecisions.count <= 128,
                  asset.collections.count <= 128,
                  Set(asset.tagDecisions.map(\.tagID)).count == asset.tagDecisions.count,
                  Set(asset.collections.map(\.collectionID)).count == asset.collections.count,
                  asset.tagDecisions.allSatisfy({ !$0.tagName.isEmpty && $0.tagName.count <= 120 }),
                  asset.collections.allSatisfy({ !$0.collectionName.isEmpty && $0.collectionName.count <= 160 })
            else {
                throw RemoteAPIError(code: .badRequest, message: "invalid shared asset facts")
            }
        }
    }
}
