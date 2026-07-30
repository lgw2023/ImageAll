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
        height: Int?
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
        tagPresence: RemoteAssetTagPresence = .any
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
