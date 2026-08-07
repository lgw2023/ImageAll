import Foundation

enum AppPersonalTagLibrarySuggestionError: Error, Equatable {
    case alreadyRunning
    case personalUnavailable
    case modelUnavailable
    case identityMismatch
    case tagNotInPersonalModel
}

struct AppPersonalTagLibrarySuggestionHit: Equatable, Sendable {
    let candidate: PersonalSuggestionCandidate
    let score: Double
}

struct AppPersonalTagLibrarySuggestionBatch: Equatable, Sendable {
    let tagID: UUID
    let capability: PersonalModelSuggestionCapability
    let hits: [AppPersonalTagLibrarySuggestionHit]
    let checkedCount: Int
    let aboveThresholdCount: Int
    let skippedCount: Int

    init(
        tagID: UUID,
        capability: PersonalModelSuggestionCapability,
        hits: [AppPersonalTagLibrarySuggestionHit],
        checkedCount: Int,
        aboveThresholdCount: Int? = nil,
        skippedCount: Int
    ) {
        self.tagID = tagID
        self.capability = capability
        self.hits = hits
        self.checkedCount = checkedCount
        self.aboveThresholdCount = aboveThresholdCount ?? hits.count
        self.skippedCount = skippedCount
    }
}

protocol AppPersonalTagLibrarySuggesting: Sendable {
    func capability(
        mediaKind: MediaKind,
        tagID: UUID
    ) async throws -> PersonalModelSuggestionCapability

    func suggest(
        tagID: UUID,
        candidates: [PersonalSuggestionCandidate],
        maximumPendingCount: Int,
        minimumScore: Double,
        embedding: @escaping @Sendable (PersonalSuggestionCandidate) async throws -> AppCoreMLEmbedding,
        progress: (@Sendable (Int, Int, Int) -> Void)?
    ) async throws -> AppPersonalTagLibrarySuggestionBatch
    func suggest(
        mediaKind: MediaKind,
        tagID: UUID,
        candidates: [PersonalSuggestionCandidate],
        maximumPendingCount: Int,
        minimumScore: Double,
        embedding: @escaping @Sendable (PersonalSuggestionCandidate) async throws -> AppCoreMLEmbedding,
        progress: (@Sendable (Int, Int, Int) -> Void)?
    ) async throws -> AppPersonalTagLibrarySuggestionBatch

    func suggest(
        mediaKind: MediaKind,
        tagID: UUID,
        candidates: [PersonalSuggestionCandidate],
        maximumPendingCount: Int,
        minimumScore: Double,
        embeddingBatch: @escaping @Sendable ([PersonalSuggestionCandidate]) async throws -> [AppCoreMLEmbedding?],
        progress: (@Sendable (Int, Int, Int) -> Void)?
    ) async throws -> AppPersonalTagLibrarySuggestionBatch
}

extension AppPersonalTagLibrarySuggesting {
    func capability(
        mediaKind _: MediaKind,
        tagID _: UUID
    ) async throws -> PersonalModelSuggestionCapability {
        throw AppPersonalTagLibrarySuggestionError.personalUnavailable
    }

    func suggest(
        mediaKind: MediaKind,
        tagID: UUID,
        candidates: [PersonalSuggestionCandidate],
        maximumPendingCount: Int,
        minimumScore: Double,
        embedding: @escaping @Sendable (PersonalSuggestionCandidate) async throws -> AppCoreMLEmbedding,
        progress: (@Sendable (Int, Int, Int) -> Void)?
    ) async throws -> AppPersonalTagLibrarySuggestionBatch {
        guard mediaKind == .image else {
            throw AppPersonalTagLibrarySuggestionError.personalUnavailable
        }
        return try await suggest(
            tagID: tagID,
            candidates: candidates,
            maximumPendingCount: maximumPendingCount,
            minimumScore: minimumScore,
            embedding: embedding,
            progress: progress
        )
    }

    func suggest(
        mediaKind: MediaKind,
        tagID: UUID,
        candidates: [PersonalSuggestionCandidate],
        maximumPendingCount: Int,
        minimumScore: Double,
        embeddingBatch: @escaping @Sendable ([PersonalSuggestionCandidate]) async throws -> [AppCoreMLEmbedding?],
        progress: (@Sendable (Int, Int, Int) -> Void)?
    ) async throws -> AppPersonalTagLibrarySuggestionBatch {
        let embeddings = try await embeddingBatch(candidates)
        guard embeddings.count == candidates.count else {
            throw AppPersonalTagLibrarySuggestionError.identityMismatch
        }
        let valuesByAssetID = Dictionary(
            uniqueKeysWithValues: zip(candidates, embeddings).compactMap { candidate, embedding in
                embedding.map { (candidate.assetID, $0) }
            }
        )
        return try await suggest(
            mediaKind: mediaKind,
            tagID: tagID,
            candidates: candidates,
            maximumPendingCount: maximumPendingCount,
            minimumScore: minimumScore,
            embedding: { candidate in
                guard let embedding = valuesByAssetID[candidate.assetID] else {
                    throw AppSelectedAssetEmbeddingCacheError.invalidAsset
                }
                return embedding
            },
            progress: progress
        )
    }
}

enum AppPersonalTagLibrarySuggestionLimits {
    static let maxPendingSuggestionsPerTag = FullLibrarySuggestionsJobFactory.maxPendingSuggestionsPerTag
    static let candidatePageSize = 500
    static let persistentBatchSize = 64
    static let maximumConcurrentImageLoads = 2
}
