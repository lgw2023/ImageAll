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

    public init(
        sourceIDs: [UUID] = [],
        searchText: String? = nil,
        sort: RemoteAssetSort = .newest,
        limit: Int = 60,
        cursor: String? = nil
    ) {
        self.sourceIDs = sourceIDs
        self.searchText = searchText
        self.sort = sort
        self.limit = limit
        self.cursor = cursor
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
