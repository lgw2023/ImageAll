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
    let capability: PersonalModelSuggestionCapability
    let results: [AppPersonalSampleSuggestionAssetResult]
    let skippedCount: Int
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
    static let defaultSampleCount = 100
    static let defaultMaximumSuggestionsPerAsset = 5
}
