import Foundation

enum TrainingCommandError: Error, Equatable, Sendable {
    case unavailable
    case invalidSelection
    case insufficientSamples
    case activeConflict
    case activityNotFound
}

enum TrainingCommandFeatureMode: String, Equatable, Sendable {
    case generate
    case update
}

enum TrainingCommandActivityPhase: String, Codable, Equatable, Sendable {
    case preparingSamples
    case preparingEmbeddings
    case trainingAndPublishing
    case completed
    case failed
    case cancelled
}

enum TrainingCommandActivityAction: String, Equatable, Sendable {
    case cancel
}

enum TrainingCommandTagActivityPhase: String, Codable, Equatable, Sendable {
    case pending
    case preparingSamples
    case preparingEmbeddings
    case trainingAndPublishing
    case succeeded
    case skipped
    case failed
    case cancelled
}

struct TrainingCommandTagActivitySnapshot: Codable, Equatable, Sendable {
    let tagID: UUID
    let displayName: String
    let phase: TrainingCommandTagActivityPhase
    let sampleCount: Int?
    let errorCode: String?
}

struct TrainingCommandTagOption: Equatable, Sendable {
    let id: UUID
    let displayName: String
    let acceptedSampleCount: Int
    let rejectedSampleCount: Int
    let featureMode: TrainingCommandFeatureMode?
    let personalEligible: Bool
}

struct TrainingCommandSourceOption: Equatable, Sendable {
    let id: UUID
    let displayName: String
}

struct TrainingCommandSetupSnapshot: Equatable, Sendable {
    let mediaKind: MediaKind
    let tags: [TrainingCommandTagOption]
    let sources: [TrainingCommandSourceOption]
    let supportsPersonalCentroid: Bool
    let supportsPersonalAdamW: Bool
}

struct TrainingLaunchCommand: Equatable, Sendable {
    let operationID: UUID
    let mediaKind: MediaKind
    let method: TrainingRunMethod
    let tagIDs: Set<UUID>
    let sourceIDs: Set<UUID>
    let assetIDs: Set<UUID>
}

struct TrainingLaunchReceipt: Equatable, Sendable {
    let operationID: UUID
    let method: TrainingRunMethod
    let acceptedAtMs: Int64
    let scheduledTagCount: Int
    let jobID: UUID?
}

struct TrainingCommandActivitySnapshot: Codable, Equatable, Sendable {
    let operationID: UUID
    let mediaKind: MediaKind
    let method: TrainingRunMethod
    let phase: TrainingCommandActivityPhase
    let completedUnitCount: Int
    let totalUnitCount: Int
    let sampleCount: Int?
    let errorCode: String?
    let tagActivities: [TrainingCommandTagActivitySnapshot]
    let acceptedAtMs: Int64
    let updatedAtMs: Int64

    init(
        operationID: UUID,
        mediaKind: MediaKind,
        method: TrainingRunMethod,
        phase: TrainingCommandActivityPhase,
        completedUnitCount: Int,
        totalUnitCount: Int,
        sampleCount: Int?,
        errorCode: String?,
        tagActivities: [TrainingCommandTagActivitySnapshot] = [],
        acceptedAtMs: Int64 = 0,
        updatedAtMs: Int64 = 0
    ) {
        self.operationID = operationID
        self.mediaKind = mediaKind
        self.method = method
        self.phase = phase
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
        self.sampleCount = sampleCount
        self.errorCode = errorCode
        self.tagActivities = tagActivities
        self.acceptedAtMs = acceptedAtMs
        self.updatedAtMs = updatedAtMs
    }

    var availableActions: [TrainingCommandActivityAction] {
        switch phase {
        case .preparingSamples, .preparingEmbeddings, .trainingAndPublishing:
            [.cancel]
        case .completed, .failed, .cancelled:
            []
        }
    }
}

enum EmbeddingPreparationPhase: String, Equatable, Sendable {
    case running
    case completed
    case failed
    case cancelled
}

enum EmbeddingPreparationAction: String, Equatable, Sendable {
    case cancel
}

struct EmbeddingPreparationCommand: Equatable, Sendable {
    let operationID: UUID
    let mediaKind: MediaKind
    let assetIDs: Set<UUID>
}

struct EmbeddingPreparationActivitySnapshot: Equatable, Sendable {
    let operationID: UUID
    let mediaKind: MediaKind
    let phase: EmbeddingPreparationPhase
    let completedUnitCount: Int
    let totalUnitCount: Int
    let preparedCount: Int
    let cachedCount: Int
    let cloudOnlyCount: Int
    let failedCount: Int
    let errorCode: String?

    var availableActions: [EmbeddingPreparationAction] {
        phase == .running ? [.cancel] : []
    }
}

struct EmbeddingPreparationReceipt: Equatable, Sendable {
    let activity: EmbeddingPreparationActivitySnapshot
    let replayed: Bool
}

enum SampleSuggestionPhase: String, Equatable, Sendable {
    case running
    case completed
    case failed
    case cancelled
}

enum SampleSuggestionAction: String, Equatable, Sendable {
    case cancel
}

struct SampleSuggestionCommand: Equatable, Sendable {
    let operationID: UUID
    let mediaKind: MediaKind
    /// Empty means “sample from the whole library”, matching the Mac toolbar.
    let assetIDs: [UUID]
}

struct SampleSuggestionActivitySnapshot: Equatable, Sendable {
    let operationID: UUID
    let mediaKind: MediaKind
    let phase: SampleSuggestionPhase
    let completedUnitCount: Int
    let totalUnitCount: Int
    let suggestedCount: Int
    let skippedCount: Int
    let errorCode: String?

    var availableActions: [SampleSuggestionAction] {
        phase == .running ? [.cancel] : []
    }
}

struct SampleSuggestionReceipt: Equatable, Sendable {
    let activity: SampleSuggestionActivitySnapshot
    let replayed: Bool
}

enum TagLibrarySuggestionMethod: String, Equatable, Sendable {
    case personalCentroid
    case personalAdamW
}

enum TagLibrarySuggestionPhase: String, Equatable, Sendable {
    case preparingCandidates
    case scoring
    case publishing
    case completed
    case failed
    case cancelled
}

enum TagLibrarySuggestionAction: String, Equatable, Sendable {
    case cancel
}

struct TagLibrarySuggestionCommand: Equatable, Sendable {
    let operationID: UUID
    let mediaKind: MediaKind
    let method: TagLibrarySuggestionMethod
    let tagID: UUID
    let sourceIDs: Set<UUID>
}

struct TagLibrarySuggestionActivitySnapshot: Equatable, Sendable {
    let operationID: UUID
    let mediaKind: MediaKind
    let method: TagLibrarySuggestionMethod
    let tagID: UUID
    let phase: TagLibrarySuggestionPhase
    let completedUnitCount: Int
    let totalUnitCount: Int
    let aboveThresholdCount: Int
    let insertedCount: Int
    let skippedCount: Int
    let errorCode: String?

    var availableActions: [TagLibrarySuggestionAction] {
        switch phase {
        case .preparingCandidates, .scoring, .publishing: [.cancel]
        case .completed, .failed, .cancelled: []
        }
    }
}

struct TagLibrarySuggestionReceipt: Equatable, Sendable {
    let activity: TagLibrarySuggestionActivitySnapshot
    let replayed: Bool
}

struct TagLibrarySuggestionTagOption: Equatable, Sendable {
    let tagID: UUID
    let personalEligible: Bool
    let personalCentroidMinScore: Double
    let personalAdamWMinScore: Double
}

protocol RemoteTrainingCommandPort: Sendable {
    func setup(mediaKind: MediaKind) async throws -> TrainingCommandSetupSnapshot
    func launch(_ command: TrainingLaunchCommand) async throws -> TrainingLaunchReceipt
    func activities(mediaKind: MediaKind) async -> [TrainingCommandActivitySnapshot]
    func cancelActivity(operationID: UUID) async throws -> TrainingCommandActivitySnapshot
    func embeddingPreparationAvailable() async -> Bool
    func prepareEmbeddings(
        _ command: EmbeddingPreparationCommand
    ) async throws -> EmbeddingPreparationReceipt
    func embeddingPreparationActivities(
        mediaKind: MediaKind
    ) async -> [EmbeddingPreparationActivitySnapshot]
    func cancelEmbeddingPreparation(
        operationID: UUID
    ) async throws -> EmbeddingPreparationActivitySnapshot
    func sampleSuggestionsAvailable(mediaKind: MediaKind) async -> Bool
    func sampleSuggestionMaximumCount() async -> Int
    func generateSampleSuggestions(
        _ command: SampleSuggestionCommand
    ) async throws -> SampleSuggestionReceipt
    func sampleSuggestionActivities(
        mediaKind: MediaKind
    ) async -> [SampleSuggestionActivitySnapshot]
    func cancelSampleSuggestions(
        operationID: UUID
    ) async throws -> SampleSuggestionActivitySnapshot
    func tagLibrarySuggestionsAvailable(
        mediaKind: MediaKind,
        method: TagLibrarySuggestionMethod
    ) async -> Bool
    func tagLibrarySuggestionTagOptions(
        mediaKind: MediaKind
    ) async throws -> [TagLibrarySuggestionTagOption]
    func generateTagLibrarySuggestions(
        _ command: TagLibrarySuggestionCommand
    ) async throws -> TagLibrarySuggestionReceipt
    func tagLibrarySuggestionActivities(
        mediaKind: MediaKind
    ) async -> [TagLibrarySuggestionActivitySnapshot]
    func cancelTagLibrarySuggestions(
        operationID: UUID
    ) async throws -> TagLibrarySuggestionActivitySnapshot
    func ensureSuggestionRunnerRunning() async
}

extension RemoteTrainingCommandPort {
    func embeddingPreparationAvailable() async -> Bool { false }

    func prepareEmbeddings(
        _: EmbeddingPreparationCommand
    ) async throws -> EmbeddingPreparationReceipt {
        throw TrainingCommandError.unavailable
    }

    func embeddingPreparationActivities(
        mediaKind _: MediaKind
    ) async -> [EmbeddingPreparationActivitySnapshot] { [] }

    func cancelEmbeddingPreparation(
        operationID _: UUID
    ) async throws -> EmbeddingPreparationActivitySnapshot {
        throw TrainingCommandError.activityNotFound
    }

    func sampleSuggestionsAvailable(mediaKind _: MediaKind) async -> Bool { false }

    func sampleSuggestionMaximumCount() async -> Int {
        AppPersonalSampleSuggestionLimits.defaultSampleCount
    }

    func generateSampleSuggestions(
        _: SampleSuggestionCommand
    ) async throws -> SampleSuggestionReceipt {
        throw TrainingCommandError.unavailable
    }

    func sampleSuggestionActivities(
        mediaKind _: MediaKind
    ) async -> [SampleSuggestionActivitySnapshot] { [] }

    func cancelSampleSuggestions(
        operationID _: UUID
    ) async throws -> SampleSuggestionActivitySnapshot {
        throw TrainingCommandError.activityNotFound
    }

    func tagLibrarySuggestionsAvailable(
        mediaKind _: MediaKind,
        method _: TagLibrarySuggestionMethod
    ) async -> Bool { false }

    func tagLibrarySuggestionTagOptions(
        mediaKind _: MediaKind
    ) async throws -> [TagLibrarySuggestionTagOption] { [] }

    func generateTagLibrarySuggestions(
        _: TagLibrarySuggestionCommand
    ) async throws -> TagLibrarySuggestionReceipt {
        throw TrainingCommandError.unavailable
    }

    func tagLibrarySuggestionActivities(
        mediaKind _: MediaKind
    ) async -> [TagLibrarySuggestionActivitySnapshot] { [] }

    func cancelTagLibrarySuggestions(
        operationID _: UUID
    ) async throws -> TagLibrarySuggestionActivitySnapshot {
        throw TrainingCommandError.activityNotFound
    }

    func ensureSuggestionRunnerRunning() async {}
}
