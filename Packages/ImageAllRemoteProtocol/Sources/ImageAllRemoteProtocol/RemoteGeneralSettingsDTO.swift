import Foundation

public enum RemoteGeneralSettingsModelState: String, Codable, Sendable, Equatable {
    case disabled
    case validating
    case ready
    case unavailable
}

public enum RemoteToolbarDisplayMode: String, Codable, Sendable, Equatable {
    case iconOnly
    case iconAndTitle
}

public enum RemoteSuggestionThresholdMethod: String, Codable, Sendable, Equatable, CaseIterable {
    case featureKnn
    case personalCentroid
    case personalAdamW
}

public struct RemoteSuggestionThresholdDefault: Codable, Sendable, Equatable {
    public let method: RemoteSuggestionThresholdMethod
    public let minScore: Double

    public init(method: RemoteSuggestionThresholdMethod, minScore: Double) {
        self.method = method
        self.minScore = minScore
    }
}

public struct RemoteSuggestionThresholdReference: Codable, Sendable, Equatable {
    public let minScore: Double
    public let acceptedSampleCount: Int
    public let rejectedSampleCount: Int

    public init(minScore: Double, acceptedSampleCount: Int, rejectedSampleCount: Int) {
        self.minScore = minScore
        self.acceptedSampleCount = acceptedSampleCount
        self.rejectedSampleCount = rejectedSampleCount
    }
}

public struct RemoteSuggestionThresholdMethodRow: Codable, Sendable, Equatable {
    public let method: RemoteSuggestionThresholdMethod
    public let effectiveMinScore: Double
    public let overrideMinScore: Double?
    public let reference: RemoteSuggestionThresholdReference?

    public init(
        method: RemoteSuggestionThresholdMethod,
        effectiveMinScore: Double,
        overrideMinScore: Double?,
        reference: RemoteSuggestionThresholdReference?
    ) {
        self.method = method
        self.effectiveMinScore = effectiveMinScore
        self.overrideMinScore = overrideMinScore
        self.reference = reference
    }
}

public struct RemoteSuggestionThresholdTagRow: Codable, Sendable, Equatable {
    public let tagID: UUID
    public let displayName: String
    public let methods: [RemoteSuggestionThresholdMethodRow]

    public init(
        tagID: UUID,
        displayName: String,
        methods: [RemoteSuggestionThresholdMethodRow]
    ) {
        self.tagID = tagID
        self.displayName = displayName
        self.methods = methods
    }
}

public struct RemoteSuggestionThresholdSnapshot: Codable, Sendable, Equatable {
    public let defaults: [RemoteSuggestionThresholdDefault]
    public let tags: [RemoteSuggestionThresholdTagRow]

    public init(
        defaults: [RemoteSuggestionThresholdDefault],
        tags: [RemoteSuggestionThresholdTagRow]
    ) {
        self.defaults = defaults
        self.tags = tags
    }
}

public enum RemoteSuggestionThresholdMutationAction: String, Codable, Sendable, Equatable {
    case setDefault
    case setOverride
    case clearOverride
}

public struct RemoteSuggestionThresholdMutation: Codable, Sendable, Equatable {
    public let action: RemoteSuggestionThresholdMutationAction
    public let method: RemoteSuggestionThresholdMethod
    public let tagID: UUID?
    public let minScore: Double?

    public init(
        action: RemoteSuggestionThresholdMutationAction,
        method: RemoteSuggestionThresholdMethod,
        tagID: UUID? = nil,
        minScore: Double? = nil
    ) {
        self.action = action
        self.method = method
        self.tagID = tagID
        self.minScore = minScore
    }
}

public struct RemoteLocalModelSettings: Codable, Sendable, Equatable {
    public let isEnabled: Bool
    public let state: RemoteGeneralSettingsModelState
    public let modelName: String
    public let runtimeName: String
    public let detail: String

    public init(
        isEnabled: Bool,
        state: RemoteGeneralSettingsModelState,
        modelName: String,
        runtimeName: String,
        detail: String
    ) {
        self.isEnabled = isEnabled
        self.state = state
        self.modelName = modelName
        self.runtimeName = runtimeName
        self.detail = detail
    }
}

public struct RemoteGeneralSettingsSnapshot: Codable, Sendable, Equatable {
    public let localModel: RemoteLocalModelSettings
    public let idleThumbnailPrewarmEnabled: Bool
    public let idleThresholdSeconds: Int
    public let toolbarDisplayMode: RemoteToolbarDisplayMode
    public let suggestionThresholds: RemoteSuggestionThresholdSnapshot?

    public init(
        localModel: RemoteLocalModelSettings,
        idleThumbnailPrewarmEnabled: Bool,
        idleThresholdSeconds: Int,
        toolbarDisplayMode: RemoteToolbarDisplayMode,
        suggestionThresholds: RemoteSuggestionThresholdSnapshot? = nil
    ) {
        self.localModel = localModel
        self.idleThumbnailPrewarmEnabled = idleThumbnailPrewarmEnabled
        self.idleThresholdSeconds = idleThresholdSeconds
        self.toolbarDisplayMode = toolbarDisplayMode
        self.suggestionThresholds = suggestionThresholds
    }
}

/// Every field except operationID is optional so one control can update without overwriting
/// values that changed concurrently in the native Settings scene. At least one setting is
/// required by the Host.
public struct RemoteGeneralSettingsUpdateRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let modelEnabled: Bool?
    public let idleThumbnailPrewarmEnabled: Bool?
    public let toolbarDisplayMode: RemoteToolbarDisplayMode?
    public let suggestionThresholdMutation: RemoteSuggestionThresholdMutation?

    public init(
        operationID: UUID,
        modelEnabled: Bool? = nil,
        idleThumbnailPrewarmEnabled: Bool? = nil,
        toolbarDisplayMode: RemoteToolbarDisplayMode? = nil,
        suggestionThresholdMutation: RemoteSuggestionThresholdMutation? = nil
    ) {
        self.operationID = operationID
        self.modelEnabled = modelEnabled
        self.idleThumbnailPrewarmEnabled = idleThumbnailPrewarmEnabled
        self.toolbarDisplayMode = toolbarDisplayMode
        self.suggestionThresholdMutation = suggestionThresholdMutation
    }
}

public struct RemoteGeneralSettingsUpdateResponse: Codable, Sendable, Equatable {
    public let settings: RemoteGeneralSettingsSnapshot
    public let replayed: Bool

    public init(settings: RemoteGeneralSettingsSnapshot, replayed: Bool) {
        self.settings = settings
        self.replayed = replayed
    }
}
