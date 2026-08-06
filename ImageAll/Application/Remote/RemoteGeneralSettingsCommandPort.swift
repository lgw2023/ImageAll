import Foundation

enum GeneralSettingsCommandError: Error, Equatable, Sendable {
    case unavailable
    case emptyUpdate
    case invalidSuggestionMutation
}

enum GeneralSettingsModelState: String, Equatable, Sendable {
    case disabled
    case validating
    case ready
    case unavailable
}

enum GeneralSettingsToolbarDisplayMode: String, Equatable, Sendable {
    case iconOnly
    case iconAndTitle
}

enum GeneralSettingsSuggestionMethod: String, CaseIterable, Equatable, Sendable {
    case featureKnn
    case personalCentroid
    case personalAdamW
}

struct GeneralSettingsSuggestionDefault: Equatable, Sendable {
    let method: GeneralSettingsSuggestionMethod
    let minScore: Double
}

struct GeneralSettingsSuggestionReference: Equatable, Sendable {
    let minScore: Double
    let acceptedSampleCount: Int
    let rejectedSampleCount: Int
}

struct GeneralSettingsSuggestionMethodRow: Equatable, Sendable {
    let method: GeneralSettingsSuggestionMethod
    let effectiveMinScore: Double
    let overrideMinScore: Double?
    let reference: GeneralSettingsSuggestionReference?
}

struct GeneralSettingsSuggestionTagRow: Equatable, Sendable {
    let tagID: UUID
    let displayName: String
    let methods: [GeneralSettingsSuggestionMethodRow]
}

struct GeneralSettingsSuggestionThresholds: Equatable, Sendable {
    let defaults: [GeneralSettingsSuggestionDefault]
    let tags: [GeneralSettingsSuggestionTagRow]
}

enum GeneralSettingsSuggestionMutationAction: String, Equatable, Sendable {
    case setDefault
    case setOverride
    case clearOverride
}

struct GeneralSettingsSuggestionMutation: Equatable, Sendable {
    let action: GeneralSettingsSuggestionMutationAction
    let method: GeneralSettingsSuggestionMethod
    let tagID: UUID?
    let minScore: Double?
}

struct GeneralSettingsLocalModelSummary: Equatable, Sendable {
    let isEnabled: Bool
    let state: GeneralSettingsModelState
    let modelName: String
    let runtimeName: String
    let detail: String
}

struct GeneralSettingsSnapshot: Equatable, Sendable {
    let localModel: GeneralSettingsLocalModelSummary
    let idleThumbnailPrewarmEnabled: Bool
    let idleThresholdSeconds: Int
    let toolbarDisplayMode: GeneralSettingsToolbarDisplayMode
    let suggestionThresholds: GeneralSettingsSuggestionThresholds?

    init(
        localModel: GeneralSettingsLocalModelSummary,
        idleThumbnailPrewarmEnabled: Bool,
        idleThresholdSeconds: Int,
        toolbarDisplayMode: GeneralSettingsToolbarDisplayMode,
        suggestionThresholds: GeneralSettingsSuggestionThresholds? = nil
    ) {
        self.localModel = localModel
        self.idleThumbnailPrewarmEnabled = idleThumbnailPrewarmEnabled
        self.idleThresholdSeconds = idleThresholdSeconds
        self.toolbarDisplayMode = toolbarDisplayMode
        self.suggestionThresholds = suggestionThresholds
    }
}

struct GeneralSettingsUpdate: Equatable, Sendable {
    let modelEnabled: Bool?
    let idleThumbnailPrewarmEnabled: Bool?
    let toolbarDisplayMode: GeneralSettingsToolbarDisplayMode?
    let suggestionThresholdMutation: GeneralSettingsSuggestionMutation?

    init(
        modelEnabled: Bool?,
        idleThumbnailPrewarmEnabled: Bool?,
        toolbarDisplayMode: GeneralSettingsToolbarDisplayMode?,
        suggestionThresholdMutation: GeneralSettingsSuggestionMutation? = nil
    ) {
        self.modelEnabled = modelEnabled
        self.idleThumbnailPrewarmEnabled = idleThumbnailPrewarmEnabled
        self.toolbarDisplayMode = toolbarDisplayMode
        self.suggestionThresholdMutation = suggestionThresholdMutation
    }

    var isEmpty: Bool {
        modelEnabled == nil
            && idleThumbnailPrewarmEnabled == nil
            && toolbarDisplayMode == nil
            && suggestionThresholdMutation == nil
    }
}

protocol RemoteGeneralSettingsCommandPort: Sendable {
    func snapshot() async throws -> GeneralSettingsSnapshot
    func update(_ update: GeneralSettingsUpdate) async throws -> GeneralSettingsSnapshot
}
