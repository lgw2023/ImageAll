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

struct SuggestionOriginCounts: Equatable, Sendable {
    static let zero = SuggestionOriginCounts(
        featurePrint: 0,
        standardModel: 0,
        personalModel: 0,
        personalAdamW: 0
    )

    let featurePrint: Int
    let standardModel: Int
    let personalModel: Int
    let personalAdamW: Int

    var total: Int {
        featurePrint + standardModel + personalModel + personalAdamW
    }
}

struct SuggestionTagOverview: Identifiable, Equatable, Sendable {
    private static let recommendedSampleCountPerRole = 4

    let id: UUID
    let displayName: String
    let acceptedSampleCount: Int
    let rejectedSampleCount: Int
    let pendingSuggestionCount: Int
    var pendingSuggestionCounts: SuggestionOriginCounts = .zero
    let taskStatus: SuggestionTaskPresentation
    let checkedCount: Int
    let totalCount: Int?
    let skippedCount: Int
    let missingPositiveCount: Int
    let missingNegativeCount: Int
    let canGenerate: Bool
    let canUpdate: Bool
    /// Personal-model path needs ≥2 accepted samples; negatives are not required.
    let canGeneratePersonalModel: Bool
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

enum ReviewQueueSuggestionOrigin: String, Equatable, Hashable, Sendable {
    case featurePrint
    case standardModel
    case personalModel
    case personalAdamW
}

struct ReviewQueueItemID: Equatable, Hashable, Sendable {
    let assetID: UUID
    let suggestionOrigin: ReviewQueueSuggestionOrigin
}

struct ReviewQueueItemProjection: Identifiable, Equatable, Sendable {
    let assetID: UUID
    let fileName: String?
    let availability: AssetAvailability
    let acceptedTagCount: Int
    let rejectedTagCount: Int
    let suggestionOrigin: ReviewQueueSuggestionOrigin
    let score: Double

    init(
        assetID: UUID,
        fileName: String?,
        availability: AssetAvailability,
        acceptedTagCount: Int,
        rejectedTagCount: Int,
        suggestionOrigin: ReviewQueueSuggestionOrigin = .featurePrint,
        score: Double = 0
    ) {
        self.assetID = assetID
        self.fileName = fileName
        self.availability = availability
        self.acceptedTagCount = acceptedTagCount
        self.rejectedTagCount = rejectedTagCount
        self.suggestionOrigin = suggestionOrigin
        self.score = score
    }

    var id: ReviewQueueItemID {
        ReviewQueueItemID(assetID: assetID, suggestionOrigin: suggestionOrigin)
    }
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

    var id: AssetPendingSuggestionID {
        AssetPendingSuggestionID(tagID: tagID, suggestionOrigin: suggestionOrigin)
    }
}

struct AssetPendingSuggestionID: Equatable, Hashable, Sendable {
    let tagID: UUID
    let suggestionOrigin: ReviewQueueSuggestionOrigin
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

enum SuggestionGenerationMethod: Equatable, Sendable {
    /// Feature-vector k-NN over frozen accept/reject samples (writes `prediction`).
    case featureKnn
    /// Active App personal centroid linear head (writes `personal_prediction`).
    case personalModel
    /// Active App personal AdamW linear head (writes `personal_prediction`).
    case personalAdamW
}

struct SuggestionEnqueueSourceOption: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
}

struct SuggestionEnqueueConfirmation: Identifiable, Equatable, Sendable {
    let tagID: UUID
    let displayName: String
    let mode: PersonalizationReviewEnqueueMode
    let method: SuggestionGenerationMethod
    let availableSources: [SuggestionEnqueueSourceOption]
    var selectedSourceIDs: Set<UUID>
    let effectiveMinScore: Double

    init(
        tagID: UUID,
        displayName: String,
        mode: PersonalizationReviewEnqueueMode,
        method: SuggestionGenerationMethod = .featureKnn,
        availableSources: [SuggestionEnqueueSourceOption],
        selectedSourceIDs: Set<UUID>,
        effectiveMinScore: Double = 0
    ) {
        self.tagID = tagID
        self.displayName = displayName
        self.mode = mode
        self.method = method
        self.availableSources = availableSources
        self.selectedSourceIDs = selectedSourceIDs
        self.effectiveMinScore = effectiveMinScore
    }

    var id: String { "\(tagID.uuidString.lowercased()):\(method)" }

    var sourceCount: Int { selectedSourceIDs.count }

    var canStart: Bool { !selectedSourceIDs.isEmpty }
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

struct StandardLibrarySuggestionJobProjection: Equatable, Sendable {
    let id: UUID
    let state: JobState
    let checkedCount: Int
    let totalCount: Int?
    let suggestedCount: Int
    let skippedCount: Int
    let lastErrorCode: JobSafeErrorCode?
}

struct FeatureSuggestionJobProjection: Equatable, Sendable {
    let id: UUID
    let state: JobState
    let candidateCount: Int
    let aboveThresholdCount: Int
    let skippedCount: Int
}

protocol PersonalizationReviewPort: Sendable {
    /// `sourceIDs == nil` means all active sources; empty means match nothing.
    func totalPendingSuggestionCount(sourceIDs: [UUID]?) throws -> Int
    /// Pending counts respect `sourceIDs`; accept/reject sample counts stay catalog-wide.
    func tagOverviews(sourceIDs: [UUID]?) throws -> [SuggestionTagOverview]
    func personalTrainingSnapshot() throws -> PersonalTrainingSnapshot
    func personalTrainingSnapshot(limitingToAssetIDs assetIDs: Set<UUID>) throws -> PersonalTrainingSnapshot
    /// Tag-scoped training snapshot. Empty `tagIDs` yields an empty snapshot.
    /// `assetIDs == nil` keeps all eligible assets; non-empty restricts samples to those assets.
    func personalTrainingSnapshot(
        limitingToTagIDs tagIDs: Set<UUID>,
        limitingToAssetIDs assetIDs: Set<UUID>?
    ) throws -> PersonalTrainingSnapshot
    func enqueuePersonalModelRebuildIfReady() throws -> UUID?
    func fetchReviewQueue(
        tagID: UUID,
        sourceIDs: [UUID]?,
        cursor: ReviewQueueCursor?,
        limit: Int
    ) throws -> ReviewQueuePage
    func pendingSuggestionsForAsset(assetID: UUID) throws -> [AssetPendingSuggestion]
    func personalSuggestionCandidates(
        afterAssetID: UUID?,
        limit: Int,
        sourceIDs: [UUID]?,
        excludingDecisionsForTagID: UUID?
    ) throws -> [PersonalSuggestionCandidate]
    func activatePersonalSuggestionBundle(
        _ capability: PersonalModelSuggestionCapability
    ) throws
    func replacePersonalSuggestions(
        candidate: PersonalSuggestionCandidate,
        predictions: [PersonalSuggestionPrediction],
        expectedCapability: PersonalModelSuggestionCapability
    ) throws -> Int
    /// Replaces pending personal-model suggestions for one tag.
    /// Hits should already be above the user threshold and preferably exclude decided assets;
    /// persistence still skips decided rows and keeps at most `maximumPendingCount`.
    func replacePersonalTagLibrarySuggestions(
        tagID: UUID,
        hits: [AppPersonalTagLibrarySuggestionHit],
        expectedCapability: PersonalModelSuggestionCapability,
        maximumPendingCount: Int
    ) throws -> Int
    func replaceStandardSuggestions(
        assetID: UUID,
        contentRevision: Int,
        suggestions: [LocalModelSuggestion],
        expectedTarget: StandardModelSuggestionTarget
    ) throws -> Int
    func invalidateAllPersonalSuggestionBundles() throws
    /// `sourceIDs == nil` freezes all active personalization sources at enqueue time.
    func enqueueFullLibrarySuggestions(
        tagID: UUID,
        mode: PersonalizationReviewEnqueueMode,
        sourceIDs: [UUID]?
    ) throws -> UUID
    func featureSuggestionJob(jobID: UUID) throws -> FeatureSuggestionJobProjection?
    func enqueuePersonalLibrarySuggestions(
        capability: PersonalModelSuggestionCapability,
        sourceIDs: [UUID]?
    ) throws -> UUID
    func personalLibrarySuggestionJob() throws -> PersonalLibrarySuggestionJobProjection?
    func enqueueStandardLibrarySuggestions(
        target: StandardModelSuggestionTarget,
        sourceIDs: [UUID]?
    ) throws -> UUID
    func standardLibrarySuggestionJob() throws -> StandardLibrarySuggestionJobProjection?
    func pauseSuggestionJob(jobID: UUID) throws
    func resumeSuggestionJob(jobID: UUID) throws
    func cancelSuggestionJob(jobID: UUID) throws
    func runPendingSuggestionJobs(maxSteps: Int?) throws -> Bool
    func runPendingSuggestionJobsAsync(maxSteps: Int?) async throws -> Bool
    func nextSuggestionRetryDelayNanoseconds() throws -> UInt64?
}

extension PersonalizationReviewPort {
    func totalPendingSuggestionCount() throws -> Int {
        try totalPendingSuggestionCount(sourceIDs: nil)
    }

    func tagOverviews() throws -> [SuggestionTagOverview] {
        try tagOverviews(sourceIDs: nil)
    }

    func fetchReviewQueue(
        tagID: UUID,
        cursor: ReviewQueueCursor?,
        limit: Int
    ) throws -> ReviewQueuePage {
        try fetchReviewQueue(tagID: tagID, sourceIDs: nil, cursor: cursor, limit: limit)
    }

    func personalTrainingSnapshot() throws -> PersonalTrainingSnapshot {
        throw PersonalizationReviewError.persistenceFailure
    }

    func personalTrainingSnapshot(limitingToAssetIDs _: Set<UUID>) throws -> PersonalTrainingSnapshot {
        throw PersonalizationReviewError.persistenceFailure
    }

    func personalTrainingSnapshot(
        limitingToTagIDs _: Set<UUID>,
        limitingToAssetIDs _: Set<UUID>?
    ) throws -> PersonalTrainingSnapshot {
        throw PersonalizationReviewError.persistenceFailure
    }

    func enqueuePersonalModelRebuildIfReady() throws -> UUID? { nil }

    func personalSuggestionCandidates(
        afterAssetID: UUID?,
        limit: Int
    ) throws -> [PersonalSuggestionCandidate] {
        try personalSuggestionCandidates(
            afterAssetID: afterAssetID,
            limit: limit,
            sourceIDs: nil,
            excludingDecisionsForTagID: nil
        )
    }

    func personalSuggestionCandidates(
        afterAssetID: UUID?,
        limit: Int,
        sourceIDs: [UUID]?
    ) throws -> [PersonalSuggestionCandidate] {
        try personalSuggestionCandidates(
            afterAssetID: afterAssetID,
            limit: limit,
            sourceIDs: sourceIDs,
            excludingDecisionsForTagID: nil
        )
    }

    func personalSuggestionCandidates(
        afterAssetID _: UUID?,
        limit _: Int,
        sourceIDs _: [UUID]?,
        excludingDecisionsForTagID _: UUID?
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

    func replacePersonalTagLibrarySuggestions(
        tagID _: UUID,
        hits _: [AppPersonalTagLibrarySuggestionHit],
        expectedCapability _: PersonalModelSuggestionCapability,
        maximumPendingCount _: Int
    ) throws -> Int {
        throw PersonalizationReviewError.persistenceFailure
    }

    func invalidateAllPersonalSuggestionBundles() throws {
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
        capability: PersonalModelSuggestionCapability
    ) throws -> UUID {
        try enqueuePersonalLibrarySuggestions(capability: capability, sourceIDs: nil)
    }

    func enqueuePersonalLibrarySuggestions(
        capability _: PersonalModelSuggestionCapability,
        sourceIDs _: [UUID]?
    ) throws -> UUID {
        throw PersonalizationReviewError.persistenceFailure
    }

    func personalLibrarySuggestionJob() throws -> PersonalLibrarySuggestionJobProjection? {
        nil
    }

    func enqueueStandardLibrarySuggestions(
        target: StandardModelSuggestionTarget
    ) throws -> UUID {
        try enqueueStandardLibrarySuggestions(target: target, sourceIDs: nil)
    }

    func enqueueStandardLibrarySuggestions(
        target _: StandardModelSuggestionTarget,
        sourceIDs _: [UUID]?
    ) throws -> UUID {
        throw PersonalizationReviewError.persistenceFailure
    }

    func enqueueFullLibrarySuggestions(
        tagID: UUID,
        mode: PersonalizationReviewEnqueueMode
    ) throws -> UUID {
        try enqueueFullLibrarySuggestions(tagID: tagID, mode: mode, sourceIDs: nil)
    }

    func featureSuggestionJob(jobID _: UUID) throws -> FeatureSuggestionJobProjection? {
        nil
    }

    func standardLibrarySuggestionJob() throws -> StandardLibrarySuggestionJobProjection? {
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
    func totalPendingSuggestionCount(sourceIDs _: [UUID]?) throws -> Int { 0 }
    func tagOverviews(sourceIDs _: [UUID]?) throws -> [SuggestionTagOverview] { [] }
    func fetchReviewQueue(
        tagID _: UUID,
        sourceIDs _: [UUID]?,
        cursor _: ReviewQueueCursor?,
        limit _: Int
    ) throws -> ReviewQueuePage {
        ReviewQueuePage(items: [], nextCursor: nil)
    }
    func pendingSuggestionsForAsset(assetID _: UUID) throws -> [AssetPendingSuggestion] { [] }
    func enqueueFullLibrarySuggestions(
        tagID _: UUID,
        mode _: PersonalizationReviewEnqueueMode,
        sourceIDs _: [UUID]?
    ) throws -> UUID {
        UUID()
    }
    func pauseSuggestionJob(jobID _: UUID) throws {}
    func resumeSuggestionJob(jobID _: UUID) throws {}
    func cancelSuggestionJob(jobID _: UUID) throws {}
    func runPendingSuggestionJobs(maxSteps: Int? = nil) throws -> Bool { false }
}
