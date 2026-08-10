import Foundation

public enum RemoteAssetSort: String, Codable, Sendable, Equatable {
    case newest
    case oldest
    case fileNameAscending
}

public enum RemoteAssetAvailability: String, Codable, Sendable, Equatable {
    case available
    case missing
    case unreadable
    case unsupported
}

public enum RemoteAssetTagDecision: String, Codable, Sendable, Equatable {
    case accepted
    case rejected
}

public struct RemoteAssetTagDecisionFilter: Codable, Sendable, Equatable {
    public let tagID: UUID
    public let decision: RemoteAssetTagDecision

    public init(tagID: UUID, decision: RemoteAssetTagDecision) {
        self.tagID = tagID
        self.decision = decision
    }
}

public enum RemoteAssetTagMatchMode: String, Codable, Sendable, Equatable {
    case all
    case any
}

public enum RemoteAssetMediaKind: String, Codable, Sendable, Equatable {
    case image
    case video
}

public enum RemoteAssetTagPresence: String, Codable, Sendable, Equatable {
    case any
    case tagged
    case untagged
}

public enum RemoteAssetFavoriteFilter: String, Codable, Sendable, Equatable {
    case favorited
}

public enum RemoteFavoriteSyncStatus: String, Codable, Sendable, Equatable {
    case localOnly
    case synced
    case pending
    case failed
}

public struct RemoteAssetFavoriteState: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { assetID }
    public let assetID: UUID
    public let isFavorite: Bool
    public let photosObservedValue: Bool?
    public let syncStatus: RemoteFavoriteSyncStatus
    public let lastErrorCode: String?

    public init(
        assetID: UUID,
        isFavorite: Bool,
        photosObservedValue: Bool? = nil,
        syncStatus: RemoteFavoriteSyncStatus,
        lastErrorCode: String? = nil
    ) {
        self.assetID = assetID
        self.isFavorite = isFavorite
        self.photosObservedValue = photosObservedValue
        self.syncStatus = syncStatus
        self.lastErrorCode = lastErrorCode
    }
}

public struct RemoteAssetSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceID: UUID
    public let sourceName: String
    public let fileName: String?
    public let mediaType: String
    public let availability: RemoteAssetAvailability
    public let contentRevision: Int
    public let acceptedTagCount: Int
    public let rejectedTagCount: Int
    public let mediaCreatedAtMs: Int64?
    public let width: Int?
    public let height: Int?
    /// `nil` when decoded from an older Host without the favorites capability.
    public let favorite: RemoteAssetFavoriteState?
    /// Optional grid-hover facts added after the initial companion protocol.
    /// Missing values remain compatible with older Hosts.
    public let relativePath: String?
    public let mediaModifiedAtMs: Int64?
    public let durationMs: Int64?

    public init(
        id: UUID,
        sourceID: UUID,
        sourceName: String,
        fileName: String?,
        mediaType: String,
        availability: RemoteAssetAvailability,
        contentRevision: Int,
        acceptedTagCount: Int,
        rejectedTagCount: Int,
        mediaCreatedAtMs: Int64?,
        width: Int?,
        height: Int?,
        favorite: RemoteAssetFavoriteState? = nil,
        relativePath: String? = nil,
        mediaModifiedAtMs: Int64? = nil,
        durationMs: Int64? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.fileName = fileName
        self.mediaType = mediaType
        self.availability = availability
        self.contentRevision = contentRevision
        self.acceptedTagCount = acceptedTagCount
        self.rejectedTagCount = rejectedTagCount
        self.mediaCreatedAtMs = mediaCreatedAtMs
        self.width = width
        self.height = height
        self.favorite = favorite
        self.relativePath = relativePath
        self.mediaModifiedAtMs = mediaModifiedAtMs
        self.durationMs = durationMs
    }
}

public struct RemoteAssetPageRequest: Codable, Sendable, Equatable {
    public var sourceIDs: [UUID]
    public var searchText: String?
    public var sort: RemoteAssetSort
    public var limit: Int
    public var cursor: String?
    public var tagDecisionFilters: [RemoteAssetTagDecisionFilter]
    public var excludedTagIDs: [UUID]
    public var tagMatchMode: RemoteAssetTagMatchMode
    public var availabilities: [RemoteAssetAvailability]
    public var mediaKinds: [RemoteAssetMediaKind]
    public var mediaTypes: [String]
    public var tagPresence: RemoteAssetTagPresence
    /// `nil` means no favorite constraint and remains compatible with older clients.
    public var favorite: RemoteAssetFavoriteFilter?
    /// Exact Host-issued spatial scope used when a photo tower opens in the gallery.
    /// `nil` keeps the ordinary all/source/favorite gallery behavior.
    public var worldMapSelection: RemoteWorldMapSelectionQuery?

    public init(
        sourceIDs: [UUID] = [],
        searchText: String? = nil,
        sort: RemoteAssetSort = .fileNameAscending,
        limit: Int = 60,
        cursor: String? = nil,
        tagDecisionFilters: [RemoteAssetTagDecisionFilter] = [],
        excludedTagIDs: [UUID] = [],
        tagMatchMode: RemoteAssetTagMatchMode = .all,
        availabilities: [RemoteAssetAvailability] = [],
        mediaKinds: [RemoteAssetMediaKind] = [],
        mediaTypes: [String] = [],
        tagPresence: RemoteAssetTagPresence = .any,
        favorite: RemoteAssetFavoriteFilter? = nil,
        worldMapSelection: RemoteWorldMapSelectionQuery? = nil
    ) {
        self.sourceIDs = sourceIDs
        self.searchText = searchText
        self.sort = sort
        self.limit = limit
        self.cursor = cursor
        self.tagDecisionFilters = tagDecisionFilters
        self.excludedTagIDs = excludedTagIDs
        self.tagMatchMode = tagMatchMode
        self.availabilities = availabilities
        self.mediaKinds = mediaKinds
        self.mediaTypes = mediaTypes
        self.tagPresence = tagPresence
        self.favorite = favorite
        self.worldMapSelection = worldMapSelection
    }
}

public struct RemoteFavoriteMutationRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let assetIDs: [UUID]
    public let isFavorite: Bool

    public init(operationID: UUID, assetIDs: [UUID], isFavorite: Bool) {
        self.operationID = operationID
        self.assetIDs = assetIDs
        self.isFavorite = isFavorite
    }
}

public struct RemoteFavoriteMutationResponse: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let changedCount: Int
    public let localOnlyCount: Int
    public let syncedCount: Int
    public let pendingCount: Int
    public let failedCount: Int
    public let states: [RemoteAssetFavoriteState]
    public let replayed: Bool

    public init(
        operationID: UUID,
        changedCount: Int,
        localOnlyCount: Int,
        syncedCount: Int,
        pendingCount: Int,
        failedCount: Int,
        states: [RemoteAssetFavoriteState],
        replayed: Bool
    ) {
        self.operationID = operationID
        self.changedCount = changedCount
        self.localOnlyCount = localOnlyCount
        self.syncedCount = syncedCount
        self.pendingCount = pendingCount
        self.failedCount = failedCount
        self.states = states
        self.replayed = replayed
    }
}

public struct RemoteFavoriteSyncRetryRequest: Codable, Sendable, Equatable {
    public let operationID: UUID

    public init(operationID: UUID) {
        self.operationID = operationID
    }
}

public struct RemoteFavoriteSyncRetryResponse: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let localOnlyCount: Int
    public let syncedCount: Int
    public let pendingCount: Int
    public let failedCount: Int
    public let replayed: Bool

    public init(
        operationID: UUID,
        localOnlyCount: Int,
        syncedCount: Int,
        pendingCount: Int,
        failedCount: Int,
        replayed: Bool
    ) {
        self.operationID = operationID
        self.localOnlyCount = localOnlyCount
        self.syncedCount = syncedCount
        self.pendingCount = pendingCount
        self.failedCount = failedCount
        self.replayed = replayed
    }
}

public struct RemoteAssetPage: Codable, Sendable, Equatable {
    public let items: [RemoteAssetSummary]
    public let nextCursor: String?

    public init(items: [RemoteAssetSummary], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct RemoteThumbnailRequest: Codable, Sendable, Equatable {
    public let assetID: UUID
    public let targetPixelWidth: Int

    public init(assetID: UUID, targetPixelWidth: Int = 320) {
        self.assetID = assetID
        self.targetPixelWidth = max(64, min(targetPixelWidth, 2048))
    }
}
