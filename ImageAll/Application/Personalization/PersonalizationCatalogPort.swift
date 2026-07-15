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

protocol PersonalizationCatalogPort: Sendable {
    func registerFeature(_ registration: FeatureRegistration) throws
    func publishModelRevision(_ registration: ModelRevisionRegistration) throws
    func replacePredictions(
        tagID: UUID,
        modelRevision: Int,
        candidateAssetIDs: [UUID],
        predictions: [PredictionRegistration],
        createdAtMs: Int64
    ) throws
    func pendingPredictions(tagID: UUID, limit: Int) throws -> [PendingPrediction]
}
