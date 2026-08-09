import Foundation

/// Main-actor bridge to the same observable setting models used by the native Settings scene.
/// Remote callers never write UserDefaults behind those models, so the Mac UI and runtime stay
/// synchronized with an authenticated Web Companion update.
@MainActor
final class RemoteGeneralSettingsCommandService:
    RemoteGeneralSettingsCommandPort,
    @unchecked Sendable
{
    private let modelSettings: AppModelSettingsModel
    private let idlePrewarmSettings: IdleThumbnailPrewarmSettingsModel
    private let toolbarDisplayModeSettings: ToolbarDisplayModeSettingsModel
    private unowned let workspace: LibraryWorkspaceModel

    init(
        modelSettings: AppModelSettingsModel,
        idlePrewarmSettings: IdleThumbnailPrewarmSettingsModel,
        toolbarDisplayModeSettings: ToolbarDisplayModeSettingsModel,
        workspace: LibraryWorkspaceModel
    ) {
        self.modelSettings = modelSettings
        self.idlePrewarmSettings = idlePrewarmSettings
        self.toolbarDisplayModeSettings = toolbarDisplayModeSettings
        self.workspace = workspace
    }

    func snapshot() -> GeneralSettingsSnapshot {
        modelSettings.refreshSuggestionThresholds()
        return makeSnapshot()
    }

    func update(_ update: GeneralSettingsUpdate) async throws -> GeneralSettingsSnapshot {
        guard !update.isEmpty else {
            throw GeneralSettingsCommandError.emptyUpdate
        }
        if let modelEnabled = update.modelEnabled {
            await modelSettings.setEnabledAndWait(modelEnabled)
        }
        if let prewarmEnabled = update.idleThumbnailPrewarmEnabled {
            idlePrewarmSettings.setEnabled(prewarmEnabled)
            workspace.setIdleThumbnailPrewarmEnabled(prewarmEnabled)
        }
        if let displayMode = update.toolbarDisplayMode {
            toolbarDisplayModeSettings.setDisplayMode(Self.mapToolbarMode(displayMode))
        }
        if let mutation = update.suggestionThresholdMutation {
            try applySuggestionThresholdMutation(mutation)
        }
        if let maximumPendingCount = update.maxPendingSuggestionsPerTag {
            workspace.setMaxPendingSuggestionsPerTag(maximumPendingCount)
        }
        return makeSnapshot()
    }

    private func applySuggestionThresholdMutation(
        _ mutation: GeneralSettingsSuggestionMutation
    ) throws {
        let method = Self.mapSuggestionMethod(mutation.method)
        do {
            switch mutation.action {
            case .setDefault:
                guard mutation.tagID == nil,
                      let minScore = mutation.minScore,
                      minScore.isFinite
                else { throw GeneralSettingsCommandError.invalidSuggestionMutation }
                try modelSettings.setSuggestionDefaultAndRefresh(
                    method: method,
                    minScore: minScore
                )
            case .setOverride:
                guard let tagID = mutation.tagID,
                      let minScore = mutation.minScore,
                      minScore.isFinite
                else { throw GeneralSettingsCommandError.invalidSuggestionMutation }
                try modelSettings.setSuggestionOverrideAndRefresh(
                    tagID: tagID,
                    method: method,
                    minScore: minScore
                )
            case .clearOverride:
                guard let tagID = mutation.tagID, mutation.minScore == nil else {
                    throw GeneralSettingsCommandError.invalidSuggestionMutation
                }
                try modelSettings.clearSuggestionOverrideAndRefresh(
                    tagID: tagID,
                    method: method
                )
            case .prune:
                guard let tagID = mutation.tagID, mutation.minScore == nil else {
                    throw GeneralSettingsCommandError.invalidSuggestionMutation
                }
                _ = try modelSettings.prunePendingSuggestionsBelowThreshold(
                    tagID: tagID,
                    method: method
                )
            }
        } catch AppModelSettingsMutationError.suggestionThresholdsUnavailable {
            throw GeneralSettingsCommandError.unavailable
        } catch SuggestionThresholdError.invalidScore {
            throw GeneralSettingsCommandError.invalidSuggestionMutation
        }
    }

    private func makeSnapshot() -> GeneralSettingsSnapshot {
        GeneralSettingsSnapshot(
            localModel: GeneralSettingsLocalModelSummary(
                isEnabled: modelSettings.isEnabled,
                state: Self.mapModelState(modelSettings.state),
                modelName: modelSettings.modelText,
                runtimeName: modelSettings.runtimeText,
                detail: modelSettings.detailText
            ),
            idleThumbnailPrewarmEnabled: idlePrewarmSettings.isEnabled,
            idleThresholdSeconds: Int(IdleThumbnailPrewarmDefaults.idleThresholdSeconds),
            toolbarDisplayMode: Self.mapToolbarMode(toolbarDisplayModeSettings.displayMode),
            suggestionThresholds: makeSuggestionThresholdSnapshot(),
            maxPendingSuggestionsPerTag: workspace.maxPendingSuggestionsPerTag
        )
    }

    private func makeSuggestionThresholdSnapshot() -> GeneralSettingsSuggestionThresholds? {
        guard modelSettings.hasSuggestionThresholdPort else { return nil }
        let defaults = GeneralSettingsSuggestionMethod.allCases.map { method in
            GeneralSettingsSuggestionDefault(
                method: method,
                minScore: modelSettings.suggestionDefaults[Self.mapSuggestionMethod(method)]
            )
        }
        let tags = modelSettings.suggestionOverrides.map { row in
            GeneralSettingsSuggestionTagRow(
                tagID: row.tagID,
                displayName: row.displayName,
                methods: GeneralSettingsSuggestionMethod.allCases.map { method in
                    let domainMethod = Self.mapSuggestionMethod(method)
                    let override = row.overrides[domainMethod]
                    return GeneralSettingsSuggestionMethodRow(
                        method: method,
                        effectiveMinScore: override
                            ?? modelSettings.suggestionDefaults[domainMethod],
                        overrideMinScore: override,
                        reference: modelSettings.suggestionReference(
                            tagID: row.tagID,
                            method: domainMethod
                        ).map {
                            GeneralSettingsSuggestionReference(
                                minScore: $0.minScore,
                                acceptedSampleCount: $0.acceptedSampleCount,
                                rejectedSampleCount: $0.rejectedSampleCount
                            )
                        }
                    )
                }
            )
        }
        return GeneralSettingsSuggestionThresholds(defaults: defaults, tags: tags)
    }

    private static func mapSuggestionMethod(
        _ method: GeneralSettingsSuggestionMethod
    ) -> SuggestionScoreThresholdMethod {
        switch method {
        case .featureKnn: .featureKnn
        case .personalCentroid: .personalCentroid
        case .personalAdamW: .personalAdamW
        }
    }

    private static func mapModelState(_ state: AppModelActivationState) -> GeneralSettingsModelState {
        switch state {
        case .disabled: .disabled
        case .validating: .validating
        case .ready: .ready
        case .unavailable: .unavailable
        }
    }

    private static func mapToolbarMode(
        _ mode: LibraryToolbarDisplayMode
    ) -> GeneralSettingsToolbarDisplayMode {
        switch mode {
        case .iconOnly: .iconOnly
        case .iconAndTitle: .iconAndTitle
        }
    }

    private static func mapToolbarMode(
        _ mode: GeneralSettingsToolbarDisplayMode
    ) -> LibraryToolbarDisplayMode {
        switch mode {
        case .iconOnly: .iconOnly
        case .iconAndTitle: .iconAndTitle
        }
    }
}
