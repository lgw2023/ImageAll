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
    func suggest(
        tagID: UUID,
        candidates: [PersonalSuggestionCandidate],
        maximumPendingCount: Int,
        minimumScore: Double,
        embedding: @escaping @Sendable (PersonalSuggestionCandidate) async throws -> AppCoreMLEmbedding,
        progress: (@Sendable (Int, Int, Int) -> Void)?
    ) async throws -> AppPersonalTagLibrarySuggestionBatch
}

enum AppPersonalTagLibrarySuggestionLimits {
    static let maxPendingSuggestionsPerTag = FullLibrarySuggestionsJobFactory.maxPendingSuggestionsPerTag
    static let candidatePageSize = 500
}
