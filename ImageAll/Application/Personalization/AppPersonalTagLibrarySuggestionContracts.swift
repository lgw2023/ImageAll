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
    let skippedCount: Int
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
