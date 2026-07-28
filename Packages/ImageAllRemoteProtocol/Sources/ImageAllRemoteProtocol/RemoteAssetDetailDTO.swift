import Foundation

public struct RemoteAssetDetail: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { assetID }
    public let assetID: UUID
    public let sourceID: UUID
    public let sourceName: String
    public let fileName: String?
    public let relativePath: String?
    public let mediaType: String
    public let availability: RemoteAssetAvailability
    public let contentRevision: Int
    public let acceptedTagCount: Int
    public let rejectedTagCount: Int
    public let mediaCreatedAtMs: Int64?
    public let mediaModifiedAtMs: Int64?
    public let width: Int?
    public let height: Int?
    public let tags: [RemoteInspectorTagState]

    public init(
        assetID: UUID,
        sourceID: UUID,
        sourceName: String,
        fileName: String?,
        relativePath: String?,
        mediaType: String,
        availability: RemoteAssetAvailability,
        contentRevision: Int,
        acceptedTagCount: Int,
        rejectedTagCount: Int,
        mediaCreatedAtMs: Int64?,
        mediaModifiedAtMs: Int64?,
        width: Int?,
        height: Int?,
        tags: [RemoteInspectorTagState]
    ) {
        self.assetID = assetID
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.fileName = fileName
        self.relativePath = relativePath
        self.mediaType = mediaType
        self.availability = availability
        self.contentRevision = contentRevision
        self.acceptedTagCount = acceptedTagCount
        self.rejectedTagCount = rejectedTagCount
        self.mediaCreatedAtMs = mediaCreatedAtMs
        self.mediaModifiedAtMs = mediaModifiedAtMs
        self.width = width
        self.height = height
        self.tags = tags
    }
}

public enum RemoteInspectorTagDecision: String, Codable, Sendable, Equatable {
    case unknown
    case accepted
    case rejected
}

public struct RemoteInspectorTagState: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { tagID }
    public let tagID: UUID
    public let displayName: String
    public let decision: RemoteInspectorTagDecision

    public init(tagID: UUID, displayName: String, decision: RemoteInspectorTagDecision) {
        self.tagID = tagID
        self.displayName = displayName
        self.decision = decision
    }
}

public struct RemoteTagSelectionAggregate: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { tagID }
    public let tagID: UUID
    public let acceptedCount: Int
    public let rejectedCount: Int
    public let unknownCount: Int

    public init(tagID: UUID, acceptedCount: Int, rejectedCount: Int, unknownCount: Int) {
        self.tagID = tagID
        self.acceptedCount = acceptedCount
        self.rejectedCount = rejectedCount
        self.unknownCount = unknownCount
    }
}

public struct RemoteTagSelectionRequest: Codable, Sendable, Equatable {
    public let tagIDs: [UUID]
    public let assetIDs: [UUID]

    public init(tagIDs: [UUID], assetIDs: [UUID]) {
        self.tagIDs = tagIDs
        self.assetIDs = assetIDs
    }
}
