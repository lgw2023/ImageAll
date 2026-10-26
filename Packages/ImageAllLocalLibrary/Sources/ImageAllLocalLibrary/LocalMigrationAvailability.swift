import Foundation

/// A partial visible projection may transfer bytes, but may never certify the
/// complete retained selection. This does not mutate selection or authorization.
public struct LocalMigrationAvailability: Sendable {
    public let selectedCount: Int
    public let availableCount: Int
    public var pendingCount: Int { selectedCount - availableCount }

    public init(snapshot: LocalSharedSnapshot) throws {
        let selected = Set(snapshot.selectedAssetIDs)
        let available = Set(snapshot.assets.map(\.id))
        guard selected.count == snapshot.selectedAssetIDs.count,
              available.count == snapshot.assets.count,
              Set(snapshot.assets.map(\.localIdentifier)).count == snapshot.assets.count,
              available.isSubset(of: selected) else {
            throw LocalLibraryError.syncIdentityChanged
        }
        selectedCount = selected.count
        availableCount = available.count
    }

    public func requireComplete() throws {
        guard selectedCount > 0, pendingCount == 0 else {
            throw LocalLibraryError.migrationScopeIncomplete
        }
    }
}

/// Projects facts for the explicitly authorized, completely received visible scope.
/// The retained selection in the store and original snapshot is never changed.
extension LocalSharedSnapshot {
    public func archiveSnapshot(mediaIDs: Set<UUID>, allowVerifiedSubset: Bool) throws -> LocalSharedSnapshot {
        let availability = try LocalMigrationAvailability(snapshot: self)
        guard !mediaIDs.isEmpty, mediaIDs == Set(assets.map(\.id)) else {
            throw LocalLibraryError.migrationScopeIncomplete
        }
        if !allowVerifiedSubset { try availability.requireComplete() }
        var result = LocalSharedSnapshot(installID: installID, sourceEpoch: sourceEpoch,
            scopeRevision: scopeRevision, snapshotSequence: snapshotSequence,
            outboxWatermark: outboxWatermark,
            selectedAssetIDs: selectedAssetIDs.filter { mediaIDs.contains($0) }, assets: assets)
        result.auditRecords = auditRecords?.filter { mediaIDs.contains($0.assetID) }
        return result
    }
}
