import Foundation

enum PersonalizationConstants {
    static let provider = "vision-feature-print"
    static let requestRevision = 2
    static let preprocessingRevision = 1
    static let elementType = "float32"
    static let maximumCandidateCount = 500
}

struct FeatureIdentity: Equatable, Hashable, Sendable {
    let assetID: UUID
    let provider: String
    let requestRevision: Int
    let preprocessingRevision: Int
    let contentRevision: Int

    init(
        assetID: UUID,
        provider: String = PersonalizationConstants.provider,
        requestRevision: Int = PersonalizationConstants.requestRevision,
        preprocessingRevision: Int = PersonalizationConstants.preprocessingRevision,
        contentRevision: Int
    ) {
        self.assetID = assetID
        self.provider = provider
        self.requestRevision = requestRevision
        self.preprocessingRevision = preprocessingRevision
        self.contentRevision = contentRevision
    }
}

struct FeatureRegistration: Equatable, Sendable {
    let identity: FeatureIdentity
    let elementCount: Int
    let byteCount: Int
    let vectorSHA256: Data
    let cacheKey: String
    let createdAtMs: Int64
}

enum FeatureVectorOrigin: Equatable, Sendable {
    case generated
    case cacheHit
}

struct FeatureVectorPayload: Equatable, Sendable {
    let identity: FeatureIdentity
    let elementCount: Int
    let vectorData: Data
    let vectorSHA256: Data
    let origin: FeatureVectorOrigin
}

struct FeaturePrintInput: Sendable {
    let identity: FeatureIdentity
    let sourceBytes: Data
    let expectedMediaType: String?
    let validationToken: Data
}

enum FeaturePrintError: Error, Equatable, Sendable {
    case assetNotFound
    case assetIneligible
    case authorizationRequired
    case sourceUnavailable
    case sourceChanged
    case decodeFailed
    case generationFailed
    case cacheUnsafePath
    case cachePersistenceFailed
}

protocol FeatureVectorLoading: Sendable {
    func loadOrGenerate(assetID: UUID) async throws -> FeatureVectorPayload
}

protocol FeaturePrintInputLoading: Sendable {
    func resolveIdentity(assetID: UUID) throws -> FeatureIdentity
    func loadInput(assetID: UUID, expectedIdentity: FeatureIdentity) throws -> FeaturePrintInput
    func isCurrent(_ input: FeaturePrintInput) throws -> Bool
}

enum ModelSampleRole: String, Equatable, Sendable {
    case positive
    case negative
}

struct ModelSampleRegistration: Equatable, Sendable {
    let identity: FeatureIdentity
    let role: ModelSampleRole
    let rank: Int
}

struct ModelRevisionRegistration: Equatable, Sendable {
    let tagID: UUID
    let revision: Int
    let threshold: Double
    let neighborCount: Int
    let sampleBudgetPerRole: Int
    let samples: [ModelSampleRegistration]
    let createdAtMs: Int64
}

struct PredictionRegistration: Equatable, Sendable {
    let assetID: UUID
    let contentRevision: Int
    let score: Double
}

struct PendingPrediction: Equatable, Sendable {
    let assetID: UUID
    let tagID: UUID
    let contentRevision: Int
    let modelRevision: Int
    let score: Double
}

enum PersonalizationCatalogError: Error, Equatable, Sendable {
    case invalidInput
    case notFound
    case archivedTag
    case staleAssetRevision
    case missingFeature
    case staleModelRevision
    case persistenceFailure
}

struct PersonalizedSuggestionResult: Equatable, Sendable {
    let modelRevision: Int
    let positiveSampleCount: Int
    let negativeSampleCount: Int
    let evaluatedCandidateCount: Int
    let predictedCandidateCount: Int
}

enum PersonalizedSuggestionError: Error, Equatable, Sendable {
    case invalidCandidates
    case tagNotFound
    case archivedTag
    case insufficientSamples
    case inconsistentFeatureDimensions
    case invalidFeatureVector
    case persistenceFailure
}

protocol PersonalizationCatalogPort: Sendable {
    func registerFeature(_ registration: FeatureRegistration) throws
    func featureRegistration(identity: FeatureIdentity) throws -> FeatureRegistration?
    func publishModelRevision(_ registration: ModelRevisionRegistration) throws
    func replacePredictions(
        tagID: UUID,
        modelRevision: Int,
        candidateAssetIDs: [UUID],
        predictions: [PredictionRegistration],
        createdAtMs: Int64
    ) throws
    func pendingPredictions(tagID: UUID, limit: Int) throws -> [PendingPrediction]
    func appendPredictions(
        tagID: UUID,
        modelRevision: Int,
        predictions: [PredictionRegistration],
        createdAtMs: Int64
    ) throws
}

enum ModelSuggestionTrack: String, Codable, Equatable, Sendable {
    case standard
    case personal
}

enum ModelSuggestionRecommendedState: String, Codable, Equatable, Sendable {
    case suggested
    case autoAssigned
}

struct StandardModelSuggestionTarget: Equatable, Sendable {
    let standardPackID: String
    let standardPackRevision: String
}

struct PersonalModelSuggestionTarget: Equatable, Sendable {
    let catalogScopeID: String
    let bundleID: String
    let bundleRevision: String
    let labelVocabularyRevision: String
}

enum ModelSuggestionTarget: Equatable, Sendable {
    case standard(StandardModelSuggestionTarget)
    case personal(PersonalModelSuggestionTarget)
}

struct LocalModelSuggestion: Codable, Equatable, Sendable {
    let track: ModelSuggestionTrack
    let conceptID: String?
    let tagID: UUID?
    let score: Double
    let recommendedState: ModelSuggestionRecommendedState
    let catalogScopeID: String?
    let bundleID: String?
    let bundleRevision: String?
    let standardPackID: String?
    let standardPackRevision: String?
    let provider: String
    let modelID: String?
    let modelRevision: String
    let preprocessingRevision: String
    let labelVocabularyRevision: String?
    let ontologyID: String?
    let ontologyRevision: String?
    let mappingRevision: String?
    let policyRevision: String

    enum CodingKeys: String, CodingKey {
        case track
        case conceptID = "concept_id"
        case tagID = "tag_id"
        case score
        case recommendedState = "recommended_state"
        case catalogScopeID = "catalog_scope_id"
        case bundleID = "bundle_id"
        case bundleRevision = "bundle_revision"
        case standardPackID = "standard_pack_id"
        case standardPackRevision = "standard_pack_revision"
        case provider
        case modelID = "model_id"
        case modelRevision = "model_revision"
        case preprocessingRevision = "preprocessing_revision"
        case labelVocabularyRevision = "label_vocabulary_revision"
        case ontologyID = "ontology_id"
        case ontologyRevision = "ontology_revision"
        case mappingRevision = "mapping_revision"
        case policyRevision = "policy_revision"
    }
}

enum LocalModelSuggestionClientError: Error, Equatable, Sendable {
    case invalidEndpoint
    case serviceUnavailable
    case rejected(statusCode: Int, code: String?)
    case invalidResponse
    case identityMismatch
}

protocol LocalModelSuggestionClient: Sendable {
    func suggestions(
        imageData: Data,
        requestID: String,
        target: ModelSuggestionTarget
    ) async throws -> [LocalModelSuggestion]
}
