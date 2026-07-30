import Foundation

public enum RemoteTagState: String, Codable, Sendable, Equatable {
    case active
    case archived
}

public struct RemoteTagSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let state: RemoteTagState
    public let groupID: UUID

    public init(
        id: UUID,
        displayName: String,
        state: RemoteTagState,
        groupID: UUID
    ) {
        self.id = id
        self.displayName = displayName
        self.state = state
        self.groupID = groupID
    }
}

public enum RemoteTagDecisionAction: String, Codable, Sendable, Equatable {
    case accept
    case reject
    case clear
}

public struct RemoteBatchTagDecisionRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let tagID: UUID
    public let assetIDs: [UUID]
    public let action: RemoteTagDecisionAction

    public init(
        operationID: UUID,
        tagID: UUID,
        assetIDs: [UUID],
        action: RemoteTagDecisionAction
    ) {
        self.operationID = operationID
        self.tagID = tagID
        self.assetIDs = assetIDs
        self.action = action
    }
}

public struct RemoteBatchTagDecisionResponse: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let appliedAssetCount: Int
    public let replayed: Bool

    public init(operationID: UUID, appliedAssetCount: Int, replayed: Bool) {
        self.operationID = operationID
        self.appliedAssetCount = appliedAssetCount
        self.replayed = replayed
    }
}

public struct RemoteCreateTagAndApplyRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let name: String
    public let assetIDs: [UUID]

    public init(operationID: UUID, name: String, assetIDs: [UUID]) {
        self.operationID = operationID
        self.name = name
        self.assetIDs = assetIDs
    }
}

public struct RemoteCreateTagAndApplyResponse: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let tagID: UUID
    public let displayName: String
    public let appliedAssetCount: Int
    public let replayed: Bool

    public init(
        operationID: UUID,
        tagID: UUID,
        displayName: String,
        appliedAssetCount: Int,
        replayed: Bool
    ) {
        self.operationID = operationID
        self.tagID = tagID
        self.displayName = displayName
        self.appliedAssetCount = appliedAssetCount
        self.replayed = replayed
    }
}
