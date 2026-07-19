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
    private static let recommendedSampleCountPerRole = 4

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

    var recommendedPositiveSampleGap: Int {
        max(0, Self.recommendedSampleCountPerRole - acceptedSampleCount)
    }

    var recommendedNegativeSampleGap: Int {
        max(0, Self.recommendedSampleCountPerRole - rejectedSampleCount)
    }
}

enum ReviewQueueSuggestionOrigin: String, Equatable, Sendable {
    case featurePrint
    case standardModel
    case personalModel
}

struct ReviewQueueItemProjection: Identifiable, Equatable, Sendable {
    let assetID: UUID
    let fileName: String?
    let availability: AssetAvailability
    let acceptedTagCount: Int
    let rejectedTagCount: Int
    let suggestionOrigin: ReviewQueueSuggestionOrigin

    init(
        assetID: UUID,
        fileName: String?,
        availability: AssetAvailability,
        acceptedTagCount: Int,
        rejectedTagCount: Int,
        suggestionOrigin: ReviewQueueSuggestionOrigin = .featurePrint
    ) {
        self.assetID = assetID
        self.fileName = fileName
        self.availability = availability
        self.acceptedTagCount = acceptedTagCount
        self.rejectedTagCount = rejectedTagCount
        self.suggestionOrigin = suggestionOrigin
    }

    var id: UUID { assetID }
}

struct ReviewQueueCursor: Equatable, Sendable, Codable {
    let token: Data
}

struct ReviewQueuePage: Equatable, Sendable {
    let items: [ReviewQueueItemProjection]
    let nextCursor: ReviewQueueCursor?
}

struct AssetPendingSuggestion: Identifiable, Equatable, Sendable {
    let tagID: UUID
    let displayName: String
    let suggestionOrigin: ReviewQueueSuggestionOrigin

    init(
        tagID: UUID,
        displayName: String,
        suggestionOrigin: ReviewQueueSuggestionOrigin = .featurePrint
    ) {
        self.tagID = tagID
        self.displayName = displayName
        self.suggestionOrigin = suggestionOrigin
    }

    var id: UUID { tagID }
}

struct PersonalSuggestionCandidate: Equatable, Sendable {
    let assetID: UUID
    let contentRevision: Int
}

struct PersonalSuggestionPrediction: Equatable, Sendable {
    let tagID: UUID
    let score: Double
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

struct SuggestionEnqueueConfirmation: Identifiable, Equatable, Sendable {
    let tagID: UUID
    let displayName: String
    let mode: PersonalizationReviewEnqueueMode
    let sourceCount: Int

    var id: UUID { tagID }
}

struct PersonalLibrarySuggestionJobProjection: Equatable, Sendable {
    let id: UUID
    let state: JobState
    let checkedCount: Int
    let totalCount: Int?
    let suggestedCount: Int
    let skippedCount: Int
    let lastErrorCode: JobSafeErrorCode?
}

protocol PersonalizationReviewPort: Sendable {
    func totalPendingSuggestionCount() throws -> Int
    func tagOverviews() throws -> [SuggestionTagOverview]
    func personalTrainingSnapshot() throws -> PersonalTrainingSnapshot
    func fetchReviewQueue(
        tagID: UUID,
        cursor: ReviewQueueCursor?,
        limit: Int
    ) throws -> ReviewQueuePage
    func pendingSuggestionsForAsset(assetID: UUID) throws -> [AssetPendingSuggestion]
    func personalSuggestionCandidates(
        afterAssetID: UUID?,
        limit: Int
    ) throws -> [PersonalSuggestionCandidate]
    func activatePersonalSuggestionBundle(
        _ capability: PersonalModelSuggestionCapability
    ) throws
    func replacePersonalSuggestions(
        candidate: PersonalSuggestionCandidate,
        predictions: [PersonalSuggestionPrediction],
        expectedCapability: PersonalModelSuggestionCapability
    ) throws -> Int
    func replaceStandardSuggestions(
        assetID: UUID,
        contentRevision: Int,
        suggestions: [LocalModelSuggestion],
        expectedTarget: StandardModelSuggestionTarget
    ) throws -> Int
    func invalidatePersonalSuggestionBundle() throws
    func enqueueFullLibrarySuggestions(
        tagID: UUID,
        mode: PersonalizationReviewEnqueueMode
    ) throws -> UUID
    func enqueuePersonalLibrarySuggestions(
        capability: PersonalModelSuggestionCapability
    ) throws -> UUID
    func personalLibrarySuggestionJob() throws -> PersonalLibrarySuggestionJobProjection?
    func pauseSuggestionJob(jobID: UUID) throws
    func resumeSuggestionJob(jobID: UUID) throws
    func cancelSuggestionJob(jobID: UUID) throws
    func runPendingSuggestionJobs(maxSteps: Int?) throws -> Bool
    func runPendingSuggestionJobsAsync(maxSteps: Int?) async throws -> Bool
    func nextSuggestionRetryDelayNanoseconds() throws -> UInt64?
}

extension PersonalizationReviewPort {
    func personalTrainingSnapshot() throws -> PersonalTrainingSnapshot {
        throw PersonalizationReviewError.persistenceFailure
    }

    func personalSuggestionCandidates(
        afterAssetID _: UUID?,
        limit _: Int
    ) throws -> [PersonalSuggestionCandidate] {
        throw PersonalizationReviewError.persistenceFailure
    }

    func activatePersonalSuggestionBundle(
        _: PersonalModelSuggestionCapability
    ) throws {
        throw PersonalizationReviewError.persistenceFailure
    }

    func replacePersonalSuggestions(
        candidate _: PersonalSuggestionCandidate,
        predictions _: [PersonalSuggestionPrediction],
        expectedCapability _: PersonalModelSuggestionCapability
    ) throws -> Int {
        throw PersonalizationReviewError.persistenceFailure
    }

    func invalidatePersonalSuggestionBundle() throws {
        throw PersonalizationReviewError.persistenceFailure
    }

    func replaceStandardSuggestions(
        assetID _: UUID,
        contentRevision _: Int,
        suggestions _: [LocalModelSuggestion],
        expectedTarget _: StandardModelSuggestionTarget
    ) throws -> Int {
        throw PersonalizationReviewError.persistenceFailure
    }

    func enqueuePersonalLibrarySuggestions(
        capability _: PersonalModelSuggestionCapability
    ) throws -> UUID {
        throw PersonalizationReviewError.persistenceFailure
    }

    func personalLibrarySuggestionJob() throws -> PersonalLibrarySuggestionJobProjection? {
        nil
    }

    func runPendingSuggestionJobsAsync(maxSteps: Int?) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(
                        returning: try runPendingSuggestionJobs(maxSteps: maxSteps)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func nextSuggestionRetryDelayNanoseconds() throws -> UInt64? {
        nil
    }
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
    func runPendingSuggestionJobs(maxSteps: Int? = nil) throws -> Bool { false }
}
