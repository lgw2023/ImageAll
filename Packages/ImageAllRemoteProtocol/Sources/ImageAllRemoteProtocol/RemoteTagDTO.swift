import Foundation

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
