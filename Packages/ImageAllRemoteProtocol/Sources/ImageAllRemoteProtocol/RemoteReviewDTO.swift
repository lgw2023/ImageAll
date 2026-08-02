import Foundation

public enum RemoteReviewSuggestionOrigin: String, Codable, Sendable, Equatable {
    case featurePrint
    case standardModel
    case personalModel
    case personalAdamW
}

public enum RemoteSuggestionTaskStatus: String, Codable, Sendable, Equatable {
    case notReady
    case ready
    case waiting
    case running
    case paused
    case retryableFailure
    case completed
    case terminalFailure
    case cancelled
}

public struct RemoteSuggestionOriginCounts: Codable, Sendable, Equatable {
    public let featurePrint: Int
    public let standardModel: Int
    public let personalModel: Int
    public let personalAdamW: Int

    public init(featurePrint: Int, standardModel: Int, personalModel: Int, personalAdamW: Int) {
        self.featurePrint = featurePrint
        self.standardModel = standardModel
        self.personalModel = personalModel
        self.personalAdamW = personalAdamW
    }
}

public struct RemoteSuggestionTagOverview: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let acceptedSampleCount: Int
    public let rejectedSampleCount: Int
    public let pendingSuggestionCount: Int
    public let pendingSuggestionCounts: RemoteSuggestionOriginCounts
    public let taskStatus: RemoteSuggestionTaskStatus
    public let checkedCount: Int
    public let totalCount: Int?
    public let skippedCount: Int
    public let missingPositiveCount: Int
    public let missingNegativeCount: Int
    public let canReview: Bool

    public init(
        id: UUID,
        displayName: String,
        acceptedSampleCount: Int,
        rejectedSampleCount: Int,
        pendingSuggestionCount: Int,
        pendingSuggestionCounts: RemoteSuggestionOriginCounts,
        taskStatus: RemoteSuggestionTaskStatus,
        checkedCount: Int,
        totalCount: Int?,
        skippedCount: Int,
        missingPositiveCount: Int,
        missingNegativeCount: Int,
        canReview: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.acceptedSampleCount = acceptedSampleCount
        self.rejectedSampleCount = rejectedSampleCount
        self.pendingSuggestionCount = pendingSuggestionCount
        self.pendingSuggestionCounts = pendingSuggestionCounts
        self.taskStatus = taskStatus
        self.checkedCount = checkedCount
        self.totalCount = totalCount
        self.skippedCount = skippedCount
        self.missingPositiveCount = missingPositiveCount
        self.missingNegativeCount = missingNegativeCount
        self.canReview = canReview
    }
}

public struct RemoteReviewOverview: Codable, Sendable, Equatable {
    public let totalPendingSuggestionCount: Int
    public let tags: [RemoteSuggestionTagOverview]

    public init(totalPendingSuggestionCount: Int, tags: [RemoteSuggestionTagOverview]) {
        self.totalPendingSuggestionCount = totalPendingSuggestionCount
        self.tags = tags
    }
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
    public var mediaKind: RemoteAssetMediaKind
    public var limit: Int
    public var cursor: String?

    public init(
        tagID: UUID,
        sourceIDs: [UUID] = [],
        mediaKind: RemoteAssetMediaKind = .image,
        limit: Int = 40,
        cursor: String? = nil
    ) {
        self.tagID = tagID
        self.sourceIDs = sourceIDs
        self.mediaKind = mediaKind
        self.limit = limit
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey {
        case tagID
        case sourceIDs
        case mediaKind
        case limit
        case cursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagID = try container.decode(UUID.self, forKey: .tagID)
        sourceIDs = try container.decodeIfPresent([UUID].self, forKey: .sourceIDs) ?? []
        mediaKind = try container.decodeIfPresent(RemoteAssetMediaKind.self, forKey: .mediaKind)
            ?? .image
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 40
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tagID, forKey: .tagID)
        try container.encode(sourceIDs, forKey: .sourceIDs)
        try container.encode(mediaKind, forKey: .mediaKind)
        try container.encode(limit, forKey: .limit)
        try container.encodeIfPresent(cursor, forKey: .cursor)
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
    public let undoID: UUID?

    public init(operationID: UUID, appliedAssetCount: Int, replayed: Bool, undoID: UUID? = nil) {
        self.operationID = operationID
        self.appliedAssetCount = appliedAssetCount
        self.replayed = replayed
        self.undoID = undoID
    }
}
