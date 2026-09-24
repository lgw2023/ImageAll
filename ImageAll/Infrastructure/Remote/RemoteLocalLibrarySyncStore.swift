import Foundation
import ImageAllRemoteProtocol

/// Mac-owned projection of explicitly shared iPhone directory and human facts.
/// It never receives media bytes and never treats temporary PhotoKit invisibility as deletion.
actor RemoteLocalLibrarySyncStore {
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
    }

    private struct Record: Codable {
        let deviceID: UUID
        let request: RemoteLocalLibrarySnapshotRequest
        let projectedAssets: [ProjectedAsset]
        let acceptedAtMs: Int64?
    }

    private struct PersistedState: Codable {
        var records: [Record]
    }

    private let hostID: UUID
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
                      return record.request.hostID == hostID
                          && record.request.schemaVersion == 1
                          && Set(projectedIDs).count == projectedIDs.count
                          && Set(projectedIDs).isSubset(of: Set(record.request.selectedAssetIDs))
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
        if let previous = records[authenticatedDeviceID] {
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
        var projection = Dictionary(uniqueKeysWithValues: (records[authenticatedDeviceID]?
            .projectedAssets ?? []).filter { selected.contains($0.asset.id) }.map {
                ($0.asset.id, $0)
            })
        for asset in request.assets {
            projection[asset.id] = ProjectedAsset(
                asset: asset, lastVisibleSnapshotSequence: request.snapshotSequence
            )
        }
        let record = Record(
            deviceID: authenticatedDeviceID, request: request,
            projectedAssets: projection.values.sorted {
                $0.asset.id.uuidString < $1.asset.id.uuidString
            },
            acceptedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        )
        var updated = records
        updated[authenticatedDeviceID] = record
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
            assets: record.projectedAssets
        )
    }

    func projections() -> [Projection] {
        records.keys.sorted { $0.uuidString < $1.uuidString }
            .compactMap { projection(deviceID: $0) }
    }

    private func receipt(
        for record: Record, replayed: Bool
    ) -> RemoteLocalLibrarySnapshotReceipt {
        RemoteLocalLibrarySnapshotReceipt(
            hostID: hostID, deviceID: record.deviceID,
            sourceEpoch: record.request.sourceEpoch,
            snapshotSequence: record.request.snapshotSequence,
            acceptedAssetCount: record.projectedAssets.count, replayed: replayed
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
