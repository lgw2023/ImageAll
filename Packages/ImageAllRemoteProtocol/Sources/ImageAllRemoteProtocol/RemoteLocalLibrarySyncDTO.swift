import Foundation

public extension RemoteHTTPPaths {
    static let localLibrarySnapshot = "/v1/sync/local-library/snapshot"
    static let localLibraryTagDecision = "/v1/sync/local-library/tag-decision"
    static let localLibraryTagChanges = "/v1/sync/local-library/tag-changes"
    static let localLibraryCollectionMembership = "/v1/sync/local-library/collection-membership"
    static let localLibraryCollectionChanges = "/v1/sync/local-library/collection-changes"
    static let localLibraryFavoriteTarget = "/v1/sync/local-library/favorite-target"
    static let localLibraryFavoriteChanges = "/v1/sync/local-library/favorite-changes"
}

public struct RemoteLocalLibraryFavoriteChange: Codable, Sendable, Equatable {
    public let sequence: Int64
    public let scopeRevision: Int64
    public let assetID: UUID
    public let target: Bool
    public let fieldRevision: Int64

    public init(
        sequence: Int64, scopeRevision: Int64, assetID: UUID,
        target: Bool, fieldRevision: Int64
    ) {
        self.sequence = sequence
        self.scopeRevision = scopeRevision
        self.assetID = assetID
        self.target = target
        self.fieldRevision = fieldRevision
    }
}

public struct RemoteLocalLibraryFavoriteChangesPage: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let changes: [RemoteLocalLibraryFavoriteChange]
    public let nextCursor: Int64
    public let hasMore: Bool

    public init(
        hostID: UUID, deviceID: UUID, sourceEpoch: UUID,
        scopeRevision: Int64, changes: [RemoteLocalLibraryFavoriteChange],
        nextCursor: Int64, hasMore: Bool
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.changes = changes
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct RemoteLocalLibraryCollectionChange: Codable, Sendable, Equatable {
    public let sequence: Int64
    public let scopeRevision: Int64
    public let assetID: UUID
    public let collectionID: UUID
    public let collectionName: String
    public let included: Bool
    public let fieldRevision: Int64

    public init(
        sequence: Int64, scopeRevision: Int64, assetID: UUID,
        collectionID: UUID, collectionName: String,
        included: Bool, fieldRevision: Int64
    ) {
        self.sequence = sequence
        self.scopeRevision = scopeRevision
        self.assetID = assetID
        self.collectionID = collectionID
        self.collectionName = collectionName
        self.included = included
        self.fieldRevision = fieldRevision
    }
}

public struct RemoteLocalLibraryCollectionChangesPage: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let changes: [RemoteLocalLibraryCollectionChange]
    public let nextCursor: Int64
    public let hasMore: Bool

    public init(
        hostID: UUID, deviceID: UUID, sourceEpoch: UUID,
        scopeRevision: Int64, changes: [RemoteLocalLibraryCollectionChange],
        nextCursor: Int64, hasMore: Bool
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.changes = changes
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct RemoteLocalLibraryTagChange: Codable, Sendable, Equatable {
    public let sequence: Int64
    public let scopeRevision: Int64
    public let assetID: UUID
    public let tagID: UUID
    public let tagName: String
    public let decision: RemoteLocalLibraryDecision
    public let fieldRevision: Int64

    public init(
        sequence: Int64, scopeRevision: Int64,
        assetID: UUID, tagID: UUID, tagName: String,
        decision: RemoteLocalLibraryDecision, fieldRevision: Int64
    ) {
        self.sequence = sequence
        self.scopeRevision = scopeRevision
        self.assetID = assetID
        self.tagID = tagID
        self.tagName = tagName
        self.decision = decision
        self.fieldRevision = fieldRevision
    }
}

public struct RemoteLocalLibraryTagChangesPage: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let changes: [RemoteLocalLibraryTagChange]
    public let nextCursor: Int64
    public let hasMore: Bool

    public init(
        hostID: UUID, deviceID: UUID, sourceEpoch: UUID, scopeRevision: Int64,
        changes: [RemoteLocalLibraryTagChange], nextCursor: Int64, hasMore: Bool
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.changes = changes
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

/// One bounded, explicitly selected directory/fact snapshot. The authenticated Host derives
/// the device ID from the access token; a client-supplied device ID is never trusted.
public struct RemoteLocalLibrarySnapshotRequest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let hostID: UUID
    public let installID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let snapshotSequence: Int64
    public let selectedAssetIDs: [UUID]
    public let assets: [RemoteLocalLibraryAsset]

    public init(
        hostID: UUID,
        installID: UUID,
        sourceEpoch: UUID,
        scopeRevision: Int64,
        snapshotSequence: Int64,
        selectedAssetIDs: [UUID],
        assets: [RemoteLocalLibraryAsset]
    ) {
        self.schemaVersion = 1
        self.hostID = hostID
        self.installID = installID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.snapshotSequence = snapshotSequence
        self.selectedAssetIDs = selectedAssetIDs
        self.assets = assets
    }
}

public struct RemoteLocalLibraryAsset: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let localIdentifier: String
    public let mediaKind: RemoteAssetMediaKind
    public let createdAtMs: Int64?
    public let observedFavorite: Bool
    public let favoriteTarget: Bool?
    public let tagDecisions: [RemoteLocalLibraryTagDecision]
    public let collections: [RemoteLocalLibraryCollection]

    public init(
        id: UUID,
        localIdentifier: String,
        mediaKind: RemoteAssetMediaKind,
        createdAtMs: Int64?,
        observedFavorite: Bool,
        favoriteTarget: Bool?,
        tagDecisions: [RemoteLocalLibraryTagDecision],
        collections: [RemoteLocalLibraryCollection]
    ) {
        self.id = id
        self.localIdentifier = localIdentifier
        self.mediaKind = mediaKind
        self.createdAtMs = createdAtMs
        self.observedFavorite = observedFavorite
        self.favoriteTarget = favoriteTarget
        self.tagDecisions = tagDecisions
        self.collections = collections
    }
}

public enum RemoteLocalLibraryDecision: String, Codable, Sendable, Equatable {
    case accepted, rejected, cleared
}

public struct RemoteLocalLibraryTagDecision: Codable, Sendable, Equatable {
    public let tagID: UUID
    public let tagName: String
    public let decision: RemoteLocalLibraryDecision

    public init(tagID: UUID, tagName: String, decision: RemoteLocalLibraryDecision) {
        self.tagID = tagID
        self.tagName = tagName
        self.decision = decision
    }
}

public struct RemoteLocalLibraryCollection: Codable, Sendable, Equatable {
    public let collectionID: UUID
    public let collectionName: String

    public init(collectionID: UUID, collectionName: String) {
        self.collectionID = collectionID
        self.collectionName = collectionName
    }
}

public struct RemoteLocalLibrarySnapshotReceipt: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let sourceEpoch: UUID
    public let snapshotSequence: Int64
    public let acceptedAssetCount: Int
    public let replayed: Bool
    /// Assets whose tag facts were first bound to the Mac shared-fact ledger by this snapshot.
    /// Missing on older Hosts; clients must not infer this list from acceptedAssetCount.
    public let importedAssetIDs: [UUID]?

    public init(
        hostID: UUID,
        deviceID: UUID,
        sourceEpoch: UUID,
        snapshotSequence: Int64,
        acceptedAssetCount: Int,
        replayed: Bool,
        importedAssetIDs: [UUID]? = nil
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.sourceEpoch = sourceEpoch
        self.snapshotSequence = snapshotSequence
        self.acceptedAssetCount = acceptedAssetCount
        self.replayed = replayed
        self.importedAssetIDs = importedAssetIDs
    }
}

/// A single versioned decision on an explicitly shared iPhone asset. The authenticated
/// device is derived from its token; deviceSequence is its durable local outbox sequence.
public struct RemoteLocalLibraryTagDecisionRequest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let hostID: UUID
    public let installID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let operationID: UUID
    public let deviceSequence: Int64
    public let assetID: UUID
    public let tagID: UUID
    public let tagName: String
    public let decision: RemoteLocalLibraryDecision
    public let baseRevision: Int64

    public init(
        hostID: UUID, installID: UUID, sourceEpoch: UUID,
        scopeRevision: Int64, operationID: UUID, deviceSequence: Int64,
        assetID: UUID, tagID: UUID, tagName: String,
        decision: RemoteLocalLibraryDecision, baseRevision: Int64
    ) {
        self.schemaVersion = 1
        self.hostID = hostID
        self.installID = installID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.operationID = operationID
        self.deviceSequence = deviceSequence
        self.assetID = assetID
        self.tagID = tagID
        self.tagName = tagName
        self.decision = decision
        self.baseRevision = baseRevision
    }
}

public enum RemoteLocalLibraryTagDecisionDisposition: String, Codable, Sendable, Equatable {
    case applied, unchanged, conflict
}

public enum RemoteLocalLibraryTagConflictReason: String, Codable, Sendable, Equatable {
    case fieldVersion
    case tagIdentity
    case nameAlias
}

public struct RemoteLocalLibraryTagDecisionReceipt: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let operationID: UUID
    public let disposition: RemoteLocalLibraryTagDecisionDisposition
    public let fieldRevision: Int64
    public let currentDecision: RemoteLocalLibraryDecision?
    public let replayed: Bool
    /// Absent on older Hosts; a client must leave that conflict unresolved.
    public let conflictReason: RemoteLocalLibraryTagConflictReason?

    public init(
        hostID: UUID, deviceID: UUID, operationID: UUID,
        disposition: RemoteLocalLibraryTagDecisionDisposition,
        fieldRevision: Int64, currentDecision: RemoteLocalLibraryDecision?, replayed: Bool,
        conflictReason: RemoteLocalLibraryTagConflictReason? = nil
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.operationID = operationID
        self.disposition = disposition
        self.fieldRevision = fieldRevision
        self.currentDecision = currentDecision
        self.replayed = replayed
        self.conflictReason = conflictReason
    }
}

/// A membership is an independent versioned field. `included=false` is an explicit
/// removal, not an omitted item in a PhotoKit directory snapshot.
public struct RemoteLocalLibraryCollectionMembershipRequest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let hostID: UUID
    public let installID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let operationID: UUID
    public let deviceSequence: Int64
    public let assetID: UUID
    public let collectionID: UUID
    public let collectionName: String
    public let included: Bool
    public let baseRevision: Int64

    public init(
        hostID: UUID, installID: UUID, sourceEpoch: UUID,
        scopeRevision: Int64, operationID: UUID, deviceSequence: Int64,
        assetID: UUID, collectionID: UUID, collectionName: String,
        included: Bool, baseRevision: Int64
    ) {
        self.schemaVersion = 1
        self.hostID = hostID
        self.installID = installID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.operationID = operationID
        self.deviceSequence = deviceSequence
        self.assetID = assetID
        self.collectionID = collectionID
        self.collectionName = collectionName
        self.included = included
        self.baseRevision = baseRevision
    }
}

public enum RemoteLocalLibraryCollectionConflictReason: String, Codable, Sendable, Equatable {
    case fieldVersion, collectionIdentity, nameAlias
}

public struct RemoteLocalLibraryCollectionMembershipReceipt: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let operationID: UUID
    public let disposition: RemoteLocalLibraryTagDecisionDisposition
    public let fieldRevision: Int64
    public let currentIncluded: Bool?
    public let replayed: Bool
    public let conflictReason: RemoteLocalLibraryCollectionConflictReason?

    public init(
        hostID: UUID, deviceID: UUID, operationID: UUID,
        disposition: RemoteLocalLibraryTagDecisionDisposition,
        fieldRevision: Int64, currentIncluded: Bool?, replayed: Bool,
        conflictReason: RemoteLocalLibraryCollectionConflictReason? = nil
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.operationID = operationID
        self.disposition = disposition
        self.fieldRevision = fieldRevision
        self.currentIncluded = currentIncluded
        self.replayed = replayed
        self.conflictReason = conflictReason
    }
}

/// ImageAll's desired favorite is a shared human fact. It is distinct from the
/// source PhotoKit observation and its writeback result.
public struct RemoteLocalLibraryFavoriteTargetRequest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let hostID: UUID
    public let installID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let operationID: UUID
    public let deviceSequence: Int64
    public let assetID: UUID
    public let target: Bool
    public let baseRevision: Int64

    public init(
        hostID: UUID, installID: UUID, sourceEpoch: UUID,
        scopeRevision: Int64, operationID: UUID, deviceSequence: Int64,
        assetID: UUID, target: Bool, baseRevision: Int64
    ) {
        self.schemaVersion = 1
        self.hostID = hostID
        self.installID = installID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.operationID = operationID
        self.deviceSequence = deviceSequence
        self.assetID = assetID
        self.target = target
        self.baseRevision = baseRevision
    }
}

public struct RemoteLocalLibraryFavoriteTargetReceipt: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let operationID: UUID
    public let disposition: RemoteLocalLibraryTagDecisionDisposition
    public let fieldRevision: Int64
    public let currentTarget: Bool?
    public let replayed: Bool

    public init(
        hostID: UUID, deviceID: UUID, operationID: UUID,
        disposition: RemoteLocalLibraryTagDecisionDisposition,
        fieldRevision: Int64, currentTarget: Bool?, replayed: Bool
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.operationID = operationID
        self.disposition = disposition
        self.fieldRevision = fieldRevision
        self.currentTarget = currentTarget
        self.replayed = replayed
    }
}
