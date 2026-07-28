import Foundation

public enum RemoteReviewSuggestionOrigin: String, Codable, Sendable, Equatable {
    case featurePrint
    case standardModel
    case personalModel
    case personalAdamW
}

public struct RemoteReviewQueueItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(assetID.uuidString):\(suggestionOrigin.rawValue)" }
    public let assetID: UUID
    public let fileName: String?
    public let availability: RemoteAssetAvailability
    public let acceptedTagCount: Int
    public let rejectedTagCount: Int
    public let suggestionOrigin: RemoteReviewSuggestionOrigin
    public let score: Double?

    public init(
        assetID: UUID,
        fileName: String?,
        availability: RemoteAssetAvailability,
        acceptedTagCount: Int,
        rejectedTagCount: Int,
        suggestionOrigin: RemoteReviewSuggestionOrigin,
        score: Double?
    ) {
        self.assetID = assetID
        self.fileName = fileName
        self.availability = availability
        self.acceptedTagCount = acceptedTagCount
        self.rejectedTagCount = rejectedTagCount
        self.suggestionOrigin = suggestionOrigin
        self.score = score
    }
}

public struct RemoteReviewQueuePage: Codable, Sendable, Equatable {
    public let items: [RemoteReviewQueueItem]
    public let nextCursor: String?

    public init(items: [RemoteReviewQueueItem], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct RemoteReviewQueueRequest: Codable, Sendable, Equatable {
    public var tagID: UUID
    public var sourceIDs: [UUID]
    public var limit: Int
    public var cursor: String?

    public init(tagID: UUID, sourceIDs: [UUID] = [], limit: Int = 40, cursor: String? = nil) {
        self.tagID = tagID
        self.sourceIDs = sourceIDs
        self.limit = limit
        self.cursor = cursor
    }
}

public enum RemoteReviewDecisionAction: String, Codable, Sendable, Equatable {
    case accept
    case reject
    case clear
}

public struct RemoteBatchReviewDecisionRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let tagID: UUID
    public let assetIDs: [UUID]
    public let action: RemoteReviewDecisionAction

    public init(operationID: UUID, tagID: UUID, assetIDs: [UUID], action: RemoteReviewDecisionAction) {
        self.operationID = operationID
        self.tagID = tagID
        self.assetIDs = assetIDs
        self.action = action
    }
}

public struct RemoteBatchReviewDecisionResponse: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let appliedAssetCount: Int
    public let replayed: Bool

    public init(operationID: UUID, appliedAssetCount: Int, replayed: Bool) {
        self.operationID = operationID
        self.appliedAssetCount = appliedAssetCount
        self.replayed = replayed
    }
}
