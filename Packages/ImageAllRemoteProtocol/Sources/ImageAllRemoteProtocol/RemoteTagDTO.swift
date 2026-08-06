import Foundation

public enum RemoteTagState: String, Codable, Sendable, Equatable {
    case active
    case archived
}

public struct RemoteTagSummary: Codable, Sendable, Equatable, Identifiable {
    /// Stable `other` group used when decoding protocol-v1/v2 Hosts that predate tag groups.
    public static let legacyFallbackGroupID =
        UUID(uuidString: "a0000000-0000-4000-8000-000000000007")!

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

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case state
        case groupID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        state = try container.decode(RemoteTagState.self, forKey: .state)
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
            ?? Self.legacyFallbackGroupID
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(state, forKey: .state)
        try container.encode(groupID, forKey: .groupID)
    }
}

public struct RemoteTagGroupSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let sortOrder: Int
    public let isSystem: Bool

    public init(id: UUID, displayName: String, sortOrder: Int, isSystem: Bool) {
        self.id = id
        self.displayName = displayName
        self.sortOrder = sortOrder
        self.isSystem = isSystem
    }
}

public struct RemoteInstallPresetTagsRequest: Codable, Sendable, Equatable {
    public let operationID: UUID

    public init(operationID: UUID) {
        self.operationID = operationID
    }
}

public struct RemoteInstallPresetTagsResponse: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let createdTags: [RemoteTagSummary]
    public let replayed: Bool

    public init(
        operationID: UUID,
        createdTags: [RemoteTagSummary],
        replayed: Bool
    ) {
        self.operationID = operationID
        self.createdTags = createdTags
        self.replayed = replayed
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
    public let undoID: UUID?

    public init(operationID: UUID, appliedAssetCount: Int, replayed: Bool, undoID: UUID? = nil) {
        self.operationID = operationID
        self.appliedAssetCount = appliedAssetCount
        self.replayed = replayed
        self.undoID = undoID
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
    public let undoID: UUID?

    public init(
        operationID: UUID,
        tagID: UUID,
        displayName: String,
        appliedAssetCount: Int,
        replayed: Bool,
        undoID: UUID? = nil
    ) {
        self.operationID = operationID
        self.tagID = tagID
        self.displayName = displayName
        self.appliedAssetCount = appliedAssetCount
        self.replayed = replayed
        self.undoID = undoID
    }
}

public struct RemoteRenameTagRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let name: String

    public init(operationID: UUID, name: String) {
        self.operationID = operationID
        self.name = name
    }
}

public struct RemoteMoveTagRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let groupID: UUID

    public init(operationID: UUID, groupID: UUID) {
        self.operationID = operationID
        self.groupID = groupID
    }
}

public struct RemoteArchiveTagRequest: Codable, Sendable, Equatable {
    public let operationID: UUID

    public init(operationID: UUID) {
        self.operationID = operationID
    }
}

public struct RemoteTagMutationResponse: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let tag: RemoteTagSummary?
    public let replayed: Bool

    public init(operationID: UUID, tag: RemoteTagSummary?, replayed: Bool) {
        self.operationID = operationID
        self.tag = tag
        self.replayed = replayed
    }
}

public struct RemoteCreateTagGroupRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let name: String

    public init(operationID: UUID, name: String) {
        self.operationID = operationID
        self.name = name
    }
}

public struct RemoteRenameTagGroupRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let name: String

    public init(operationID: UUID, name: String) {
        self.operationID = operationID
        self.name = name
    }
}

public struct RemoteDeleteTagGroupRequest: Codable, Sendable, Equatable {
    public let operationID: UUID

    public init(operationID: UUID) {
        self.operationID = operationID
    }
}

public struct RemoteTagGroupMutationResponse: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let group: RemoteTagGroupSummary?
    public let replayed: Bool

    public init(operationID: UUID, group: RemoteTagGroupSummary?, replayed: Bool) {
        self.operationID = operationID
        self.group = group
        self.replayed = replayed
    }
}

public struct RemoteUndoTagDecisionRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let undoID: UUID

    public init(operationID: UUID, undoID: UUID) {
        self.operationID = operationID
        self.undoID = undoID
    }
}

public struct RemoteUndoTagDecisionResponse: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let restoredAssetCount: Int
    public let replayed: Bool

    public init(operationID: UUID, restoredAssetCount: Int, replayed: Bool) {
        self.operationID = operationID
        self.restoredAssetCount = restoredAssetCount
        self.replayed = replayed
    }
}
