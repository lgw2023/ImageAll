import Foundation

enum AppPersonalSampleSuggestionError: Error, Equatable {
    case alreadyRunning
    case personalUnavailable
    case modelUnavailable
    case identityMismatch
}

struct AppPersonalSampleSuggestionAssetResult: Equatable, Sendable {
    let candidate: PersonalSuggestionCandidate
    let predictions: [PersonalSuggestionPrediction]
}

struct AppPersonalSampleSuggestionBatch: Equatable, Sendable {
    /// One single-tag capability per active personal model used in this batch.
    let capabilities: [PersonalModelSuggestionCapability]
    let results: [AppPersonalSampleSuggestionAssetResult]
    let skippedCount: Int

    /// Convenience for single-tag call sites and fixtures.
    var capability: PersonalModelSuggestionCapability {
        get {
            precondition(!capabilities.isEmpty, "sample suggestion batch requires capabilities")
            return capabilities[0]
        }
    }

    init(
        capability: PersonalModelSuggestionCapability,
        results: [AppPersonalSampleSuggestionAssetResult],
        skippedCount: Int
    ) {
        self.init(capabilities: [capability], results: results, skippedCount: skippedCount)
    }

    init(
        capabilities: [PersonalModelSuggestionCapability],
        results: [AppPersonalSampleSuggestionAssetResult],
        skippedCount: Int
    ) {
        self.capabilities = capabilities
        self.results = results
        self.skippedCount = skippedCount
    }
}

protocol AppPersonalSampleSuggesting: Sendable {
    func suggest(
        candidates: [PersonalSuggestionCandidate],
        maximumSuggestionsPerAsset: Int,
        embedding: @escaping @Sendable (PersonalSuggestionCandidate) async throws -> AppCoreMLEmbedding
    ) async throws -> AppPersonalSampleSuggestionBatch
}

enum AppPersonalSuggestionCapabilityMapper {
    static let bundleID = "app.personal.linear-head.v1"
    static let policyRevision = "app-personal-positive-centroid-v1"
    static let adamWBundleID = "app.personal.adamw-head.v1"
    static let adamWPolicyRevision = "app-personal-positive-adamw-v1"

    static func capability(
        from identity: AppPersonalLinearHeadIdentity,
        family: AppPersonalLinearHeadFamily = .centroid
    ) -> PersonalModelSuggestionCapability {
        let bundleID: String
        let policyRevision: String
        switch family {
        case .centroid:
            bundleID = Self.bundleID
            policyRevision = Self.policyRevision
        case .adamW:
            bundleID = Self.adamWBundleID
            policyRevision = Self.adamWPolicyRevision
        }
        return PersonalModelSuggestionCapability(
            target: PersonalModelSuggestionTarget(
                catalogScopeID: identity.catalogScopeID,
                bundleID: bundleID,
                bundleRevision: identity.decisionSnapshotRevision,
                provider: identity.encoderIdentity.provider,
                modelID: identity.encoderIdentity.modelID,
                modelRevision: identity.encoderIdentity.modelRevision,
                preprocessingRevision: identity.encoderIdentity.preprocessingRevision,
                elementCount: identity.encoderIdentity.elementCount,
                labelVocabularyRevision: identity.labelVocabularyRevision,
                weightsSHA256: identity.weightsSHA256,
                policyRevision: policyRevision
            ),
            tagIDs: identity.personalTagIDs
        )
    }
}

enum AppPersonalSampleSuggestionLimits {
    static let defaultSampleCount = PendingSuggestionGenerationLimits.defaultMaxCount
    static let defaultMaximumSuggestionsPerAsset = 5
}
