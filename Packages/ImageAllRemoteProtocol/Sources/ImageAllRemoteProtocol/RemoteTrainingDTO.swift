import Foundation

public enum RemoteTrainingRunMethod: String, Codable, CaseIterable, Sendable {
    case featureKnn
    case personalCentroid
    case personalAdamW
}

public enum RemoteTrainingRunState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

public enum RemoteTrainingFeatureMode: String, Codable, Sendable, Equatable {
    case generate
    case update
}

public enum RemoteTrainingActivityPhase: String, Codable, Sendable, Equatable {
    case preparingSamples
    case preparingEmbeddings
    case trainingAndPublishing
    case completed
    case failed
    case cancelled
}

public enum RemoteTrainingActivityAction: String, Codable, Sendable, Equatable {
    case cancel
}

public enum RemoteTrainingTagActivityPhase: String, Codable, Sendable, Equatable {
    case pending
    case preparingSamples
    case preparingEmbeddings
    case trainingAndPublishing
    case succeeded
    case skipped
    case failed
    case cancelled
}

public struct RemoteTrainingTagActivity: Codable, Equatable, Identifiable, Sendable {
    public let tagID: UUID
    public let displayName: String
    public let phase: RemoteTrainingTagActivityPhase
    public let sampleCount: Int?
    public let errorCode: String?

    public var id: UUID { tagID }

    public init(
        tagID: UUID,
        displayName: String,
        phase: RemoteTrainingTagActivityPhase,
        sampleCount: Int? = nil,
        errorCode: String? = nil
    ) {
        self.tagID = tagID
        self.displayName = displayName
        self.phase = phase
        self.sampleCount = sampleCount
        self.errorCode = errorCode
    }
}

public struct RemoteTrainingTagOption: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let displayName: String
    public let acceptedSampleCount: Int
    public let rejectedSampleCount: Int
    public let featureMode: RemoteTrainingFeatureMode?
    public let personalEligible: Bool

    public init(
        id: UUID,
        displayName: String,
        acceptedSampleCount: Int,
        rejectedSampleCount: Int,
        featureMode: RemoteTrainingFeatureMode?,
        personalEligible: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.acceptedSampleCount = acceptedSampleCount
        self.rejectedSampleCount = rejectedSampleCount
        self.featureMode = featureMode
        self.personalEligible = personalEligible
    }
}

public struct RemoteTrainingSourceOption: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let displayName: String

    public init(id: UUID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct RemoteTrainingMethodAvailability: Codable, Equatable, Identifiable, Sendable {
    public let method: RemoteTrainingRunMethod
    public let isAvailable: Bool
    public var id: RemoteTrainingRunMethod { method }

    public init(method: RemoteTrainingRunMethod, isAvailable: Bool) {
        self.method = method
        self.isAvailable = isAvailable
    }
}

public struct RemoteTrainingSetupSnapshot: Codable, Equatable, Sendable {
    public let mediaKind: RemoteAssetMediaKind
    public let tags: [RemoteTrainingTagOption]
    public let sources: [RemoteTrainingSourceOption]
    public let methods: [RemoteTrainingMethodAvailability]

    public init(
        mediaKind: RemoteAssetMediaKind,
        tags: [RemoteTrainingTagOption],
        sources: [RemoteTrainingSourceOption],
        methods: [RemoteTrainingMethodAvailability]
    ) {
        self.mediaKind = mediaKind
        self.tags = tags
        self.sources = sources
        self.methods = methods
    }
}

public struct RemoteTrainingLaunchRequest: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let mediaKind: RemoteAssetMediaKind
    public let method: RemoteTrainingRunMethod
    public let tagIDs: [UUID]
    public let sourceIDs: [UUID]
    public let assetIDs: [UUID]

    public init(
        operationID: UUID,
        mediaKind: RemoteAssetMediaKind,
        method: RemoteTrainingRunMethod,
        tagIDs: [UUID],
        sourceIDs: [UUID] = [],
        assetIDs: [UUID] = []
    ) {
        self.operationID = operationID
        self.mediaKind = mediaKind
        self.method = method
        self.tagIDs = tagIDs
        self.sourceIDs = sourceIDs
        self.assetIDs = assetIDs
    }
}

public struct RemoteTrainingLaunchResponse: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let method: RemoteTrainingRunMethod
    public let acceptedAtMs: Int64
    public let scheduledTagCount: Int
    public let jobID: UUID?
    public let replayed: Bool

    public init(
        operationID: UUID,
        method: RemoteTrainingRunMethod,
        acceptedAtMs: Int64,
        scheduledTagCount: Int,
        jobID: UUID? = nil,
        replayed: Bool
    ) {
        self.operationID = operationID
        self.method = method
        self.acceptedAtMs = acceptedAtMs
        self.scheduledTagCount = scheduledTagCount
        self.jobID = jobID
        self.replayed = replayed
    }
}

public struct RemoteTrainingActivity: Codable, Equatable, Identifiable, Sendable {
    public let operationID: UUID
    public let mediaKind: RemoteAssetMediaKind
    public let method: RemoteTrainingRunMethod
    public let phase: RemoteTrainingActivityPhase
    public let completedUnitCount: Int
    public let totalUnitCount: Int
    public let sampleCount: Int?
    public let errorCode: String?
    public let availableActions: [RemoteTrainingActivityAction]
    public let tagActivities: [RemoteTrainingTagActivity]
    public let acceptedAtMs: Int64
    public let updatedAtMs: Int64

    public var id: UUID { operationID }

    private enum CodingKeys: String, CodingKey {
        case operationID
        case mediaKind
        case method
        case phase
        case completedUnitCount
        case totalUnitCount
        case sampleCount
        case errorCode
        case availableActions
        case tagActivities
        case acceptedAtMs
        case updatedAtMs
    }

    public init(
        operationID: UUID,
        mediaKind: RemoteAssetMediaKind,
        method: RemoteTrainingRunMethod,
        phase: RemoteTrainingActivityPhase,
        completedUnitCount: Int,
        totalUnitCount: Int,
        sampleCount: Int? = nil,
        errorCode: String? = nil,
        availableActions: [RemoteTrainingActivityAction] = [],
        tagActivities: [RemoteTrainingTagActivity] = [],
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
        self.availableActions = availableActions
        self.tagActivities = tagActivities
        self.acceptedAtMs = acceptedAtMs
        self.updatedAtMs = updatedAtMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try container.decode(UUID.self, forKey: .operationID)
        mediaKind = try container.decode(RemoteAssetMediaKind.self, forKey: .mediaKind)
        method = try container.decode(RemoteTrainingRunMethod.self, forKey: .method)
        phase = try container.decode(RemoteTrainingActivityPhase.self, forKey: .phase)
        completedUnitCount = try container.decode(Int.self, forKey: .completedUnitCount)
        totalUnitCount = try container.decode(Int.self, forKey: .totalUnitCount)
        sampleCount = try container.decodeIfPresent(Int.self, forKey: .sampleCount)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        availableActions = try container.decodeIfPresent(
            [RemoteTrainingActivityAction].self,
            forKey: .availableActions
        ) ?? []
        tagActivities = try container.decodeIfPresent(
            [RemoteTrainingTagActivity].self,
            forKey: .tagActivities
        ) ?? []
        acceptedAtMs = try container.decodeIfPresent(Int64.self, forKey: .acceptedAtMs) ?? 0
        updatedAtMs = try container.decodeIfPresent(Int64.self, forKey: .updatedAtMs) ?? 0
    }
}

public struct RemoteTrainingActivityActionRequest: Codable, Equatable, Sendable {
    public let action: RemoteTrainingActivityAction

    public init(action: RemoteTrainingActivityAction) {
        self.action = action
    }
}

public struct RemoteTrainingActivityActionResponse: Codable, Equatable, Sendable {
    public let activity: RemoteTrainingActivity

    public init(activity: RemoteTrainingActivity) {
        self.activity = activity
    }
}

public enum RemoteTrainingRecoveryScope: String, Codable, Equatable, Sendable {
    case allSources
    case selectedSources
    case unresolved
}

public struct RemoteTrainingRecoveryContext: Codable, Equatable, Sendable {
    public let tagIDs: [UUID]
    public let sourceIDs: [UUID]
    public let scope: RemoteTrainingRecoveryScope
    public let isExact: Bool
    public let note: String?

    public init(
        tagIDs: [UUID] = [],
        sourceIDs: [UUID] = [],
        scope: RemoteTrainingRecoveryScope,
        isExact: Bool,
        note: String? = nil
    ) {
        self.tagIDs = tagIDs
        self.sourceIDs = sourceIDs
        self.scope = scope
        self.isExact = isExact
        self.note = note
    }
}

public struct RemoteTrainingFailureGuidance: Codable, Equatable, Sendable {
    public let title: String
    public let message: String
    public let suggestedAction: String

    public init(title: String, message: String, suggestedAction: String) {
        self.title = title
        self.message = message
        self.suggestedAction = suggestedAction
    }
}

public struct RemoteTrainingRun: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let mediaKind: RemoteAssetMediaKind
    public let method: RemoteTrainingRunMethod
    public let state: RemoteTrainingRunState
    public let createdAtMs: Int64
    public let startedAtMs: Int64?
    public let finishedAtMs: Int64?
    public let catalogScopeID: String
    public let jobID: UUID?
    public let tagID: UUID?
    public let tagDisplayName: String?
    public let batchID: UUID?
    public let batchTagIndex: Int?
    public let batchTagCount: Int?
    public let sampleCount: Int?
    public let positiveSampleCount: Int?
    public let negativeSampleCount: Int?
    public let sampleSummaryJSON: String?
    public let sampleManifestSHA256: String?
    public let configJSON: String?
    public let metricsJSON: String?
    public let artifactKind: String?
    public let artifactRef: String?
    public let artifactSHA256: String?
    public let resultSummaryJSON: String?
    public let errorCode: String?
    public let recoveryContext: RemoteTrainingRecoveryContext?
    public let failureGuidance: RemoteTrainingFailureGuidance?

    public init(
        id: UUID,
        mediaKind: RemoteAssetMediaKind,
        method: RemoteTrainingRunMethod,
        state: RemoteTrainingRunState,
        createdAtMs: Int64,
        startedAtMs: Int64? = nil,
        finishedAtMs: Int64? = nil,
        catalogScopeID: String,
        jobID: UUID? = nil,
        tagID: UUID? = nil,
        tagDisplayName: String? = nil,
        batchID: UUID? = nil,
        batchTagIndex: Int? = nil,
        batchTagCount: Int? = nil,
        sampleCount: Int? = nil,
        positiveSampleCount: Int? = nil,
        negativeSampleCount: Int? = nil,
        sampleSummaryJSON: String? = nil,
        sampleManifestSHA256: String? = nil,
        configJSON: String? = nil,
        metricsJSON: String? = nil,
        artifactKind: String? = nil,
        artifactRef: String? = nil,
        artifactSHA256: String? = nil,
        resultSummaryJSON: String? = nil,
        errorCode: String? = nil,
        recoveryContext: RemoteTrainingRecoveryContext? = nil,
        failureGuidance: RemoteTrainingFailureGuidance? = nil
    ) {
        self.id = id
        self.mediaKind = mediaKind
        self.method = method
        self.state = state
        self.createdAtMs = createdAtMs
        self.startedAtMs = startedAtMs
        self.finishedAtMs = finishedAtMs
        self.catalogScopeID = catalogScopeID
        self.jobID = jobID
        self.tagID = tagID
        self.tagDisplayName = tagDisplayName
        self.batchID = batchID
        self.batchTagIndex = batchTagIndex
        self.batchTagCount = batchTagCount
        self.sampleCount = sampleCount
        self.positiveSampleCount = positiveSampleCount
        self.negativeSampleCount = negativeSampleCount
        self.sampleSummaryJSON = sampleSummaryJSON
        self.sampleManifestSHA256 = sampleManifestSHA256
        self.configJSON = configJSON
        self.metricsJSON = metricsJSON
        self.artifactKind = artifactKind
        self.artifactRef = artifactRef
        self.artifactSHA256 = artifactSHA256
        self.resultSummaryJSON = resultSummaryJSON
        self.errorCode = errorCode
        self.recoveryContext = recoveryContext
        self.failureGuidance = failureGuidance
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case mediaKind
        case method
        case state
        case createdAtMs
        case startedAtMs
        case finishedAtMs
        case catalogScopeID
        case jobID
        case tagID
        case tagDisplayName
        case batchID
        case batchTagIndex
        case batchTagCount
        case sampleCount
        case positiveSampleCount
        case negativeSampleCount
        case sampleSummaryJSON
        case sampleManifestSHA256
        case configJSON
        case metricsJSON
        case artifactKind
        case artifactRef
        case artifactSHA256
        case resultSummaryJSON
        case errorCode
        case recoveryContext
        case failureGuidance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        mediaKind = try container.decode(RemoteAssetMediaKind.self, forKey: .mediaKind)
        method = try container.decode(RemoteTrainingRunMethod.self, forKey: .method)
        state = try container.decode(RemoteTrainingRunState.self, forKey: .state)
        createdAtMs = try container.decode(Int64.self, forKey: .createdAtMs)
        startedAtMs = try container.decodeIfPresent(Int64.self, forKey: .startedAtMs)
        finishedAtMs = try container.decodeIfPresent(Int64.self, forKey: .finishedAtMs)
        catalogScopeID = try container.decode(String.self, forKey: .catalogScopeID)
        jobID = try container.decodeIfPresent(UUID.self, forKey: .jobID)
        tagID = try container.decodeIfPresent(UUID.self, forKey: .tagID)
        tagDisplayName = try container.decodeIfPresent(String.self, forKey: .tagDisplayName)
        batchID = try container.decodeIfPresent(UUID.self, forKey: .batchID)
        batchTagIndex = try container.decodeIfPresent(Int.self, forKey: .batchTagIndex)
        batchTagCount = try container.decodeIfPresent(Int.self, forKey: .batchTagCount)
        sampleCount = try container.decodeIfPresent(Int.self, forKey: .sampleCount)
        positiveSampleCount = try container.decodeIfPresent(Int.self, forKey: .positiveSampleCount)
        negativeSampleCount = try container.decodeIfPresent(Int.self, forKey: .negativeSampleCount)
        sampleSummaryJSON = try container.decodeIfPresent(String.self, forKey: .sampleSummaryJSON)
        sampleManifestSHA256 = try container.decodeIfPresent(String.self, forKey: .sampleManifestSHA256)
        configJSON = try container.decodeIfPresent(String.self, forKey: .configJSON)
        metricsJSON = try container.decodeIfPresent(String.self, forKey: .metricsJSON)
        artifactKind = try container.decodeIfPresent(String.self, forKey: .artifactKind)
        artifactRef = try container.decodeIfPresent(String.self, forKey: .artifactRef)
        artifactSHA256 = try container.decodeIfPresent(String.self, forKey: .artifactSHA256)
        resultSummaryJSON = try container.decodeIfPresent(String.self, forKey: .resultSummaryJSON)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        recoveryContext = try container.decodeIfPresent(
            RemoteTrainingRecoveryContext.self,
            forKey: .recoveryContext
        )
        failureGuidance = try container.decodeIfPresent(
            RemoteTrainingFailureGuidance.self,
            forKey: .failureGuidance
        )
    }
}

public struct RemoteTrainingSlot: Codable, Equatable, Identifiable, Sendable {
    public let method: RemoteTrainingRunMethod
    public let isPublished: Bool
    public let publishedRunID: UUID?
    public let artifactRef: String?

    public var id: RemoteTrainingRunMethod { method }

    public init(
        method: RemoteTrainingRunMethod,
        isPublished: Bool,
        publishedRunID: UUID? = nil,
        artifactRef: String? = nil
    ) {
        self.method = method
        self.isPublished = isPublished
        self.publishedRunID = publishedRunID
        self.artifactRef = artifactRef
    }
}

public struct RemoteTrainingWorkspaceSnapshot: Codable, Equatable, Sendable {
    public let mediaKind: RemoteAssetMediaKind
    public let methodFilter: RemoteTrainingRunMethod?
    public let runs: [RemoteTrainingRun]
    public let slots: [RemoteTrainingSlot]
    public let activities: [RemoteTrainingActivity]

    public init(
        mediaKind: RemoteAssetMediaKind,
        methodFilter: RemoteTrainingRunMethod? = nil,
        runs: [RemoteTrainingRun],
        slots: [RemoteTrainingSlot],
        activities: [RemoteTrainingActivity] = []
    ) {
        self.mediaKind = mediaKind
        self.methodFilter = methodFilter
        self.runs = runs
        self.slots = slots
        self.activities = activities
    }

    private enum CodingKeys: String, CodingKey {
        case mediaKind
        case methodFilter
        case runs
        case slots
        case activities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mediaKind = try container.decode(RemoteAssetMediaKind.self, forKey: .mediaKind)
        methodFilter = try container.decodeIfPresent(RemoteTrainingRunMethod.self, forKey: .methodFilter)
        runs = try container.decode([RemoteTrainingRun].self, forKey: .runs)
        slots = try container.decode([RemoteTrainingSlot].self, forKey: .slots)
        activities = try container.decodeIfPresent(
            [RemoteTrainingActivity].self,
            forKey: .activities
        ) ?? []
    }
}

public enum RemoteEmbeddingPreparationPhase: String, Codable, Sendable, Equatable {
    case running
    case completed
    case failed
    case cancelled
}

public enum RemoteEmbeddingPreparationAction: String, Codable, Sendable, Equatable {
    case cancel
}

public struct RemoteEmbeddingPreparationRequest: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let mediaKind: RemoteAssetMediaKind
    public let assetIDs: [UUID]

    public init(operationID: UUID, mediaKind: RemoteAssetMediaKind, assetIDs: [UUID]) {
        self.operationID = operationID
        self.mediaKind = mediaKind
        self.assetIDs = assetIDs
    }
}

public struct RemoteEmbeddingPreparationActivity: Codable, Equatable, Identifiable, Sendable {
    public let operationID: UUID
    public let mediaKind: RemoteAssetMediaKind
    public let phase: RemoteEmbeddingPreparationPhase
    public let completedUnitCount: Int
    public let totalUnitCount: Int
    public let preparedCount: Int
    public let cachedCount: Int
    public let cloudOnlyCount: Int
    public let failedCount: Int
    public let errorCode: String?
    public let availableActions: [RemoteEmbeddingPreparationAction]

    public var id: UUID { operationID }

    public init(
        operationID: UUID,
        mediaKind: RemoteAssetMediaKind,
        phase: RemoteEmbeddingPreparationPhase,
        completedUnitCount: Int,
        totalUnitCount: Int,
        preparedCount: Int = 0,
        cachedCount: Int = 0,
        cloudOnlyCount: Int = 0,
        failedCount: Int = 0,
        errorCode: String? = nil,
        availableActions: [RemoteEmbeddingPreparationAction] = []
    ) {
        self.operationID = operationID
        self.mediaKind = mediaKind
        self.phase = phase
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
        self.preparedCount = preparedCount
        self.cachedCount = cachedCount
        self.cloudOnlyCount = cloudOnlyCount
        self.failedCount = failedCount
        self.errorCode = errorCode
        self.availableActions = availableActions
    }
}

public struct RemoteEmbeddingPreparationSnapshot: Codable, Equatable, Sendable {
    public let mediaKind: RemoteAssetMediaKind
    public let isAvailable: Bool
    public let activities: [RemoteEmbeddingPreparationActivity]

    public init(
        mediaKind: RemoteAssetMediaKind,
        isAvailable: Bool,
        activities: [RemoteEmbeddingPreparationActivity]
    ) {
        self.mediaKind = mediaKind
        self.isAvailable = isAvailable
        self.activities = activities
    }
}

public struct RemoteEmbeddingPreparationResponse: Codable, Equatable, Sendable {
    public let activity: RemoteEmbeddingPreparationActivity
    public let replayed: Bool

    public init(activity: RemoteEmbeddingPreparationActivity, replayed: Bool) {
        self.activity = activity
        self.replayed = replayed
    }
}

public struct RemoteEmbeddingPreparationActionRequest: Codable, Equatable, Sendable {
    public let action: RemoteEmbeddingPreparationAction

    public init(action: RemoteEmbeddingPreparationAction) {
        self.action = action
    }
}

public struct RemoteEmbeddingPreparationActionResponse: Codable, Equatable, Sendable {
    public let activity: RemoteEmbeddingPreparationActivity

    public init(activity: RemoteEmbeddingPreparationActivity) {
        self.activity = activity
    }
}

public enum RemoteSampleSuggestionPhase: String, Codable, Sendable, Equatable {
    case running
    case completed
    case failed
    case cancelled
}

public enum RemoteSampleSuggestionAction: String, Codable, Sendable, Equatable {
    case cancel
}

public struct RemoteSampleSuggestionRequest: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let mediaKind: RemoteAssetMediaKind
    /// Empty requests the Mac-style whole-library sample.
    public let assetIDs: [UUID]

    public init(operationID: UUID, mediaKind: RemoteAssetMediaKind, assetIDs: [UUID]) {
        self.operationID = operationID
        self.mediaKind = mediaKind
        self.assetIDs = assetIDs
    }
}

public struct RemoteSampleSuggestionActivity: Codable, Equatable, Identifiable, Sendable {
    public let operationID: UUID
    public let mediaKind: RemoteAssetMediaKind
    public let phase: RemoteSampleSuggestionPhase
    public let completedUnitCount: Int
    public let totalUnitCount: Int
    public let suggestedCount: Int
    public let skippedCount: Int
    public let errorCode: String?
    public let availableActions: [RemoteSampleSuggestionAction]

    public var id: UUID { operationID }

    public init(
        operationID: UUID,
        mediaKind: RemoteAssetMediaKind,
        phase: RemoteSampleSuggestionPhase,
        completedUnitCount: Int,
        totalUnitCount: Int,
        suggestedCount: Int = 0,
        skippedCount: Int = 0,
        errorCode: String? = nil,
        availableActions: [RemoteSampleSuggestionAction] = []
    ) {
        self.operationID = operationID
        self.mediaKind = mediaKind
        self.phase = phase
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
        self.suggestedCount = suggestedCount
        self.skippedCount = skippedCount
        self.errorCode = errorCode
        self.availableActions = availableActions
    }
}

public struct RemoteSampleSuggestionSnapshot: Codable, Equatable, Sendable {
    public let mediaKind: RemoteAssetMediaKind
    public let isAvailable: Bool
    public let maximumSampleCount: Int
    public let activities: [RemoteSampleSuggestionActivity]

    public init(
        mediaKind: RemoteAssetMediaKind,
        isAvailable: Bool,
        maximumSampleCount: Int,
        activities: [RemoteSampleSuggestionActivity]
    ) {
        self.mediaKind = mediaKind
        self.isAvailable = isAvailable
        self.maximumSampleCount = maximumSampleCount
        self.activities = activities
    }
}

public struct RemoteSampleSuggestionResponse: Codable, Equatable, Sendable {
    public let activity: RemoteSampleSuggestionActivity
    public let replayed: Bool

    public init(activity: RemoteSampleSuggestionActivity, replayed: Bool) {
        self.activity = activity
        self.replayed = replayed
    }
}

public struct RemoteSampleSuggestionActionRequest: Codable, Equatable, Sendable {
    public let action: RemoteSampleSuggestionAction

    public init(action: RemoteSampleSuggestionAction) {
        self.action = action
    }
}

public struct RemoteSampleSuggestionActionResponse: Codable, Equatable, Sendable {
    public let activity: RemoteSampleSuggestionActivity

    public init(activity: RemoteSampleSuggestionActivity) {
        self.activity = activity
    }
}

public enum RemoteTagLibrarySuggestionMethod: String, Codable, Sendable, Equatable {
    case personalCentroid
    case personalAdamW
}

public enum RemoteTagLibrarySuggestionPhase: String, Codable, Sendable, Equatable {
    case preparingCandidates
    case scoring
    case publishing
    case completed
    case failed
    case cancelled
}

public enum RemoteTagLibrarySuggestionAction: String, Codable, Sendable, Equatable {
    case cancel
}

public struct RemoteTagLibrarySuggestionRequest: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let mediaKind: RemoteAssetMediaKind
    public let method: RemoteTagLibrarySuggestionMethod
    public let tagID: UUID
    public let sourceIDs: [UUID]

    public init(
        operationID: UUID,
        mediaKind: RemoteAssetMediaKind,
        method: RemoteTagLibrarySuggestionMethod,
        tagID: UUID,
        sourceIDs: [UUID]
    ) {
        self.operationID = operationID
        self.mediaKind = mediaKind
        self.method = method
        self.tagID = tagID
        self.sourceIDs = sourceIDs
    }
}

public struct RemoteTagLibrarySuggestionActivity: Codable, Equatable, Identifiable, Sendable {
    public let operationID: UUID
    public let mediaKind: RemoteAssetMediaKind
    public let method: RemoteTagLibrarySuggestionMethod
    public let tagID: UUID
    public let phase: RemoteTagLibrarySuggestionPhase
    public let completedUnitCount: Int
    public let totalUnitCount: Int
    public let aboveThresholdCount: Int
    public let insertedCount: Int
    public let skippedCount: Int
    public let errorCode: String?
    public let availableActions: [RemoteTagLibrarySuggestionAction]

    public var id: UUID { operationID }

    public init(
        operationID: UUID,
        mediaKind: RemoteAssetMediaKind,
        method: RemoteTagLibrarySuggestionMethod,
        tagID: UUID,
        phase: RemoteTagLibrarySuggestionPhase,
        completedUnitCount: Int,
        totalUnitCount: Int,
        aboveThresholdCount: Int = 0,
        insertedCount: Int = 0,
        skippedCount: Int = 0,
        errorCode: String? = nil,
        availableActions: [RemoteTagLibrarySuggestionAction] = []
    ) {
        self.operationID = operationID
        self.mediaKind = mediaKind
        self.method = method
        self.tagID = tagID
        self.phase = phase
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
        self.aboveThresholdCount = aboveThresholdCount
        self.insertedCount = insertedCount
        self.skippedCount = skippedCount
        self.errorCode = errorCode
        self.availableActions = availableActions
    }
}

public struct RemoteTagLibrarySuggestionTagOption: Codable, Equatable, Identifiable, Sendable {
    public let tagID: UUID
    public let personalEligible: Bool
    public let personalCentroidMinScore: Double
    public let personalAdamWMinScore: Double

    public var id: UUID { tagID }

    public init(
        tagID: UUID,
        personalEligible: Bool,
        personalCentroidMinScore: Double,
        personalAdamWMinScore: Double
    ) {
        self.tagID = tagID
        self.personalEligible = personalEligible
        self.personalCentroidMinScore = personalCentroidMinScore
        self.personalAdamWMinScore = personalAdamWMinScore
    }
}

public struct RemoteTagLibrarySuggestionSnapshot: Codable, Equatable, Sendable {
    public let mediaKind: RemoteAssetMediaKind
    public let maximumPendingCount: Int
    public let personalCentroidAvailable: Bool
    public let personalAdamWAvailable: Bool
    public let tags: [RemoteTagLibrarySuggestionTagOption]
    public let activities: [RemoteTagLibrarySuggestionActivity]

    public init(
        mediaKind: RemoteAssetMediaKind,
        maximumPendingCount: Int,
        personalCentroidAvailable: Bool,
        personalAdamWAvailable: Bool,
        tags: [RemoteTagLibrarySuggestionTagOption] = [],
        activities: [RemoteTagLibrarySuggestionActivity]
    ) {
        self.mediaKind = mediaKind
        self.maximumPendingCount = maximumPendingCount
        self.personalCentroidAvailable = personalCentroidAvailable
        self.personalAdamWAvailable = personalAdamWAvailable
        self.tags = tags
        self.activities = activities
    }
}

public struct RemoteTagLibrarySuggestionResponse: Codable, Equatable, Sendable {
    public let activity: RemoteTagLibrarySuggestionActivity
    public let replayed: Bool

    public init(activity: RemoteTagLibrarySuggestionActivity, replayed: Bool) {
        self.activity = activity
        self.replayed = replayed
    }
}

public struct RemoteTagLibrarySuggestionActionRequest: Codable, Equatable, Sendable {
    public let action: RemoteTagLibrarySuggestionAction

    public init(action: RemoteTagLibrarySuggestionAction) {
        self.action = action
    }
}

public struct RemoteTagLibrarySuggestionActionResponse: Codable, Equatable, Sendable {
    public let activity: RemoteTagLibrarySuggestionActivity

    public init(activity: RemoteTagLibrarySuggestionActivity) {
        self.activity = activity
    }
}
