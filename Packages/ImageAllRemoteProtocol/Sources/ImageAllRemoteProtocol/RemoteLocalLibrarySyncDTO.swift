import Foundation

public extension RemoteHTTPPaths {
    static let localLibrarySnapshot = "/v1/sync/local-library/snapshot"
    static let localLibraryTagDecision = "/v1/sync/local-library/tag-decision"
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

    public init(
        hostID: UUID,
        deviceID: UUID,
        sourceEpoch: UUID,
        snapshotSequence: Int64,
        acceptedAssetCount: Int,
        replayed: Bool
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.sourceEpoch = sourceEpoch
        self.snapshotSequence = snapshotSequence
        self.acceptedAssetCount = acceptedAssetCount
        self.replayed = replayed
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

public struct RemoteLocalLibraryTagDecisionReceipt: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let operationID: UUID
    public let disposition: RemoteLocalLibraryTagDecisionDisposition
    public let fieldRevision: Int64
    public let currentDecision: RemoteLocalLibraryDecision?
    public let replayed: Bool

    public init(
        hostID: UUID, deviceID: UUID, operationID: UUID,
        disposition: RemoteLocalLibraryTagDecisionDisposition,
        fieldRevision: Int64, currentDecision: RemoteLocalLibraryDecision?, replayed: Bool
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.operationID = operationID
        self.disposition = disposition
        self.fieldRevision = fieldRevision
        self.currentDecision = currentDecision
        self.replayed = replayed
    }
}
