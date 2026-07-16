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
