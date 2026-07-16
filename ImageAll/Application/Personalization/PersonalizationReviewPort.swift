import Foundation

enum SuggestionTaskPresentation: String, Equatable, Sendable {
    case notReady
    case ready
    case waiting
    case running
    case paused
    case retryableFailure
    case completed
    case terminalFailure
    case cancelled
}

struct SuggestionTagOverview: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let acceptedSampleCount: Int
    let rejectedSampleCount: Int
    let pendingSuggestionCount: Int
    let taskStatus: SuggestionTaskPresentation
    let checkedCount: Int
    let totalCount: Int?
    let skippedCount: Int
    let missingPositiveCount: Int
    let missingNegativeCount: Int
    let canGenerate: Bool
    let canUpdate: Bool
    let canReview: Bool
    let canPause: Bool
    let canResume: Bool
    let canCancel: Bool
    let activeJobID: UUID?
}

struct ReviewQueueItemProjection: Identifiable, Equatable, Sendable {
    let assetID: UUID
    let fileName: String?
    let availability: AssetAvailability
    let acceptedTagCount: Int
    let rejectedTagCount: Int

    var id: UUID { assetID }
}

struct ReviewQueueCursor: Equatable, Sendable, Codable {
    let score: Double
    let assetID: UUID
}

struct ReviewQueuePage: Equatable, Sendable {
    let items: [ReviewQueueItemProjection]
    let nextCursor: ReviewQueueCursor?
}

struct AssetPendingSuggestion: Identifiable, Equatable, Sendable {
    let tagID: UUID
    let displayName: String

    var id: UUID { tagID }
}

enum PersonalizationReviewError: Error, Equatable, Sendable {
    case tagNotFound
    case archivedTag
    case insufficientSamples(positiveMissing: Int, negativeMissing: Int)
    case activeJobConflict
    case jobNotFound
    case invalidTransition
    case persistenceFailure
}

enum PersonalizationReviewEnqueueMode: Equatable, Sendable {
    case generate
    case update
}

protocol PersonalizationReviewPort: Sendable {
    func totalPendingSuggestionCount() throws -> Int
    func tagOverviews() throws -> [SuggestionTagOverview]
    func fetchReviewQueue(
        tagID: UUID,
        cursor: ReviewQueueCursor?,
        limit: Int
    ) throws -> ReviewQueuePage
    func pendingSuggestionsForAsset(assetID: UUID) throws -> [AssetPendingSuggestion]
    func enqueueFullLibrarySuggestions(
        tagID: UUID,
        mode: PersonalizationReviewEnqueueMode
    ) throws -> UUID
    func pauseSuggestionJob(jobID: UUID) throws
    func resumeSuggestionJob(jobID: UUID) throws
    func cancelSuggestionJob(jobID: UUID) throws
    func runPendingSuggestionJobs(maxSteps: Int?) throws
}

struct EmptyPersonalizationReviewPort: PersonalizationReviewPort, Sendable {
    func totalPendingSuggestionCount() throws -> Int { 0 }
    func tagOverviews() throws -> [SuggestionTagOverview] { [] }
    func fetchReviewQueue(tagID: UUID, cursor: ReviewQueueCursor?, limit: Int) throws -> ReviewQueuePage {
        ReviewQueuePage(items: [], nextCursor: nil)
    }
    func pendingSuggestionsForAsset(assetID: UUID) throws -> [AssetPendingSuggestion] { [] }
    func enqueueFullLibrarySuggestions(tagID: UUID, mode: PersonalizationReviewEnqueueMode) throws -> UUID {
        UUID()
    }
    func pauseSuggestionJob(jobID: UUID) throws {}
    func resumeSuggestionJob(jobID: UUID) throws {}
    func cancelSuggestionJob(jobID: UUID) throws {}
    func runPendingSuggestionJobs(maxSteps: Int?) throws {}
}
