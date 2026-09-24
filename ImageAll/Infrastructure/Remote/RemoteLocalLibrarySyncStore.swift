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
    }

    private struct TagOperationRecord: Codable {
        let request: RemoteLocalLibraryTagDecisionRequest
        let payloadSHA256: String
        let receipt: RemoteLocalLibraryTagDecisionReceipt
    }

    private struct Record: Codable {
        let deviceID: UUID
        let request: RemoteLocalLibrarySnapshotRequest
        let projectedAssets: [ProjectedAsset]
        let acceptedAtMs: Int64?
        /// Optional for snapshots written before the versioned fact ledger existed.
        let sharedTagFacts: [SharedTagFact]?
        let tagOperations: [TagOperationRecord]?
        let lastPhoneOperationSequence: Int64?
        let importedAssetIDs: [UUID]?
        let tagChanges: [RemoteLocalLibraryTagChange]?
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
                      let operationIDs = (record.tagOperations ?? []).map(\.request.operationID)
                      let changes = record.tagChanges ?? []
                      return record.request.hostID == hostID
                          && record.request.schemaVersion == 1
                          && Set(projectedIDs).count == projectedIDs.count
                          && Set(projectedIDs).isSubset(of: selectedIDs)
                          && Set(record.importedAssetIDs ?? []).count ==
                              (record.importedAssetIDs ?? []).count
                          && Set(record.importedAssetIDs ?? []).isSubset(of: Set(projectedIDs))
                          && Set(factKeys).count == factKeys.count
                          && (record.sharedTagFacts ?? []).allSatisfy {
                              selectedIDs.contains($0.assetID) && $0.revision > 0
                          }
                          && Set(operationIDs).count == operationIDs.count
                          && (record.tagOperations ?? []).allSatisfy {
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
        let record = Record(
            deviceID: authenticatedDeviceID, request: request,
            projectedAssets: projectedAssets,
            acceptedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded()),
            sharedTagFacts: sharedTagFacts,
            tagOperations: previous?.tagOperations ?? [],
            lastPhoneOperationSequence: previous?.lastPhoneOperationSequence ?? 0,
            importedAssetIDs: importedAssetIDs,
            tagChanges: previous?.tagChanges ?? []
        )
        var updated = records
        updated[authenticatedDeviceID] = record
        try persist(updated)
        return receipt(for: record, replayed: false)
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
            sharedTagFacts: record.sharedTagFacts ?? Self.seedTagFacts(from: record.projectedAssets)
        )
    }

    func projections() -> [Projection] {
        records.keys.sorted { $0.uuidString < $1.uuidString }
            .compactMap { projection(deviceID: $0) }
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
            tagOperations: (previous.tagOperations ?? []) + [operation],
            lastPhoneOperationSequence: request.deviceSequence,
            importedAssetIDs: previous.importedAssetIDs,
            tagChanges: previous.tagChanges
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
        decision: RemoteLocalLibraryDecision, expectedRevision: Int64
    ) throws -> Projection {
        guard let previous = records[deviceID],
              previous.request.selectedAssetIDs.contains(assetID),
              previous.projectedAssets.contains(where: { $0.asset.id == assetID }) else {
            throw RemoteAPIError(code: .notFound, message: "shared phone asset unavailable")
        }
        var facts = previous.sharedTagFacts ?? Self.seedTagFacts(from: previous.projectedAssets)
        guard let index = facts.firstIndex(where: {
            $0.assetID == assetID && $0.tagID == tagID
        }) else {
            throw RemoteAPIError(code: .notFound, message: "shared phone tag unavailable")
        }
        let current = facts[index]
        guard current.revision == expectedRevision else {
            throw RemoteAPIError(code: .conflict, message: "shared phone tag changed")
        }
        if current.decision == decision {
            return projection(deviceID: deviceID)!
        }
        guard current.revision < Int64.max,
              (previous.tagChanges?.last?.sequence ?? 0) < Int64.max else {
            throw RemoteAPIError(code: .internalError, message: "shared change revision exhausted")
        }
        let nextRevision = current.revision + 1
        let nextSequence = (previous.tagChanges?.last?.sequence ?? 0) + 1
        facts[index] = SharedTagFact(
            assetID: assetID, tagID: tagID, tagName: current.tagName,
            decision: decision, revision: nextRevision
        )
        let change = RemoteLocalLibraryTagChange(
            sequence: nextSequence, scopeRevision: previous.request.scopeRevision,
            assetID: assetID, tagID: tagID,
            tagName: current.tagName, decision: decision, fieldRevision: nextRevision
        )
        let record = Record(
            deviceID: previous.deviceID, request: previous.request,
            projectedAssets: previous.projectedAssets,
            acceptedAtMs: previous.acceptedAtMs,
            sharedTagFacts: facts, tagOperations: previous.tagOperations,
            lastPhoneOperationSequence: previous.lastPhoneOperationSequence,
            importedAssetIDs: previous.importedAssetIDs,
            tagChanges: (previous.tagChanges ?? []) + [change]
        )
        var updated = records
        updated[deviceID] = record
        try persist(updated)
        return projection(deviceID: deviceID)!
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

    private static func payloadSHA256(
        _ request: RemoteLocalLibraryTagDecisionRequest
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
