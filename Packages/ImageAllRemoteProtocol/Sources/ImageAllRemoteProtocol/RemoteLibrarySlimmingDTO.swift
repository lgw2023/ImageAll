import Foundation

public enum RemoteLibrarySlimmingAnalyzeMode: String, Codable, Sendable, Equatable {
    case catalog
    case currentFilter
    case seeds
}

public enum RemoteLibrarySlimmingClusterKind: String, Codable, Sendable, Equatable {
    case byteIdentical
    case perceptualDuplicate
    case nearDuplicateScene
}

public enum RemoteLibrarySlimmingJobControlRequest: String, Codable, Sendable, Equatable {
    case none
    case pause
    case cancel
}

public enum RemoteLibrarySlimmingScanPhase: String, Codable, Sendable, Equatable {
    case preparingFingerprints
    case loadingFeaturePrints
    case loadingEmbeddings
    case clustering
}

public struct RemoteLibrarySlimmingScanProgress: Codable, Sendable, Equatable {
    public let phase: RemoteLibrarySlimmingScanPhase
    public let completedUnitCount: Int64
    public let totalUnitCount: Int64

    public init(
        phase: RemoteLibrarySlimmingScanPhase,
        completedUnitCount: Int64,
        totalUnitCount: Int64
    ) {
        self.phase = phase
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
    }
}

public struct RemoteLibrarySlimmingJob: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let mode: RemoteLibrarySlimmingAnalyzeMode
    public let mediaKind: RemoteAssetMediaKind
    public let state: RemoteJobState
    public let progress: RemoteJobProgress
    public let attempts: Int
    public let maxAttempts: Int
    public let memberCount: Int
    public let seedCount: Int
    public let clusterCount: Int
    public let hasResult: Bool
    public let createdAtMs: Int64
    public let updatedAtMs: Int64
    public let sourceNames: [String]
    public let availableActions: [RemoteJobAction]
    public let controlRequest: RemoteLibrarySlimmingJobControlRequest
    public let scanProgress: RemoteLibrarySlimmingScanProgress?
    public let lastErrorCode: String?

    public init(
        id: UUID,
        mode: RemoteLibrarySlimmingAnalyzeMode,
        mediaKind: RemoteAssetMediaKind,
        state: RemoteJobState,
        progress: RemoteJobProgress,
        attempts: Int,
        maxAttempts: Int,
        memberCount: Int,
        seedCount: Int,
        clusterCount: Int,
        hasResult: Bool,
        createdAtMs: Int64,
        updatedAtMs: Int64,
        sourceNames: [String],
        availableActions: [RemoteJobAction],
        controlRequest: RemoteLibrarySlimmingJobControlRequest = .none,
        scanProgress: RemoteLibrarySlimmingScanProgress? = nil,
        lastErrorCode: String? = nil
    ) {
        self.id = id
        self.mode = mode
        self.mediaKind = mediaKind
        self.state = state
        self.progress = progress
        self.attempts = attempts
        self.maxAttempts = maxAttempts
        self.memberCount = memberCount
        self.seedCount = seedCount
        self.clusterCount = clusterCount
        self.hasResult = hasResult
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.sourceNames = sourceNames
        self.availableActions = availableActions
        self.controlRequest = controlRequest
        self.scanProgress = scanProgress
        self.lastErrorCode = lastErrorCode
    }
}

public struct RemoteLibrarySlimmingCluster: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: RemoteLibrarySlimmingClusterKind
    public let memberCount: Int
    public let representativeAssetID: UUID
    public let score: Double
    public let isSeedOnlyResult: Bool
    public let technicalSummary: String?

    public init(
        id: UUID,
        kind: RemoteLibrarySlimmingClusterKind,
        memberCount: Int,
        representativeAssetID: UUID,
        score: Double,
        isSeedOnlyResult: Bool = false,
        technicalSummary: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.memberCount = memberCount
        self.representativeAssetID = representativeAssetID
        self.score = score
        self.isSeedOnlyResult = isSeedOnlyResult
        self.technicalSummary = technicalSummary
    }
}

public struct RemoteLibrarySlimmingMember: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceID: UUID?
    public let sourceName: String?
    public let fileName: String?
    public let mediaType: String?
    public let availability: RemoteAssetAvailability
    public let contentRevision: Int
    public let width: Int?
    public let height: Int?
    public let durationMs: Int64?

    public init(
        id: UUID,
        sourceID: UUID? = nil,
        sourceName: String? = nil,
        fileName: String? = nil,
        mediaType: String? = nil,
        availability: RemoteAssetAvailability,
        contentRevision: Int = 0,
        width: Int? = nil,
        height: Int? = nil,
        durationMs: Int64? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.fileName = fileName
        self.mediaType = mediaType
        self.availability = availability
        self.contentRevision = contentRevision
        self.width = width
        self.height = height
        self.durationMs = durationMs
    }
}

public struct RemoteLibrarySlimmingWorkspaceSnapshot: Codable, Sendable, Equatable {
    public let mediaKind: RemoteAssetMediaKind
    public let jobs: [RemoteLibrarySlimmingJob]
    public let selectedJobID: UUID?
    public let clusters: [RemoteLibrarySlimmingCluster]
    public let selectedClusterID: UUID?
    public let members: [RemoteLibrarySlimmingMember]
    public let pendingAnalysisCount: Int
    public let analyzedAssetCount: Int
    public let policyVersion: String?

    public init(
        mediaKind: RemoteAssetMediaKind,
        jobs: [RemoteLibrarySlimmingJob],
        selectedJobID: UUID?,
        clusters: [RemoteLibrarySlimmingCluster],
        selectedClusterID: UUID?,
        members: [RemoteLibrarySlimmingMember],
        pendingAnalysisCount: Int,
        analyzedAssetCount: Int,
        policyVersion: String?
    ) {
        self.mediaKind = mediaKind
        self.jobs = jobs
        self.selectedJobID = selectedJobID
        self.clusters = clusters
        self.selectedClusterID = selectedClusterID
        self.members = members
        self.pendingAnalysisCount = pendingAnalysisCount
        self.analyzedAssetCount = analyzedAssetCount
        self.policyVersion = policyVersion
    }
}

public enum RemoteFeaturePrintRecallMode: String, Codable, Sendable, Equatable {
    case topK
    case allCandidates
}

public enum RemoteFeaturePrintL2Mode: String, Codable, Sendable, Equatable {
    case radius
    case unlimited
}

public enum RemoteDINOCosineMode: String, Codable, Sendable, Equatable {
    case minimum
    case unlimited
}

public enum RemoteSceneBucketingMode: String, Codable, Sendable, Equatable {
    case always
    case automatic
    case never
}

public struct RemoteLibrarySlimmingThresholds: Codable, Sendable, Equatable {
    public let featurePrintRecallTopK: Int
    public let featurePrintMaxL2Distance: Double
    public let dinoCosineMinSimilarity: Double
    public let sceneBucketActivationAssetCount: Int
    public let featurePrintRecallMode: RemoteFeaturePrintRecallMode
    public let featurePrintL2Mode: RemoteFeaturePrintL2Mode
    public let dinoCosineMode: RemoteDINOCosineMode
    public let sceneBucketingMode: RemoteSceneBucketingMode

    public init(
        featurePrintRecallTopK: Int,
        featurePrintMaxL2Distance: Double,
        dinoCosineMinSimilarity: Double,
        sceneBucketActivationAssetCount: Int,
        featurePrintRecallMode: RemoteFeaturePrintRecallMode,
        featurePrintL2Mode: RemoteFeaturePrintL2Mode,
        dinoCosineMode: RemoteDINOCosineMode,
        sceneBucketingMode: RemoteSceneBucketingMode
    ) {
        self.featurePrintRecallTopK = featurePrintRecallTopK
        self.featurePrintMaxL2Distance = featurePrintMaxL2Distance
        self.dinoCosineMinSimilarity = dinoCosineMinSimilarity
        self.sceneBucketActivationAssetCount = sceneBucketActivationAssetCount
        self.featurePrintRecallMode = featurePrintRecallMode
        self.featurePrintL2Mode = featurePrintL2Mode
        self.dinoCosineMode = dinoCosineMode
        self.sceneBucketingMode = sceneBucketingMode
    }
}

public struct RemoteLibrarySlimmingSourceOption: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let kind: RemoteSourceKind

    public init(id: UUID, displayName: String, kind: RemoteSourceKind) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
    }
}

public struct RemoteLibrarySlimmingSetupSnapshot: Codable, Sendable, Equatable {
    public let mediaKind: RemoteAssetMediaKind
    public let sources: [RemoteLibrarySlimmingSourceOption]
    public let thresholds: RemoteLibrarySlimmingThresholds
    public let factoryThresholds: RemoteLibrarySlimmingThresholds

    public init(
        mediaKind: RemoteAssetMediaKind,
        sources: [RemoteLibrarySlimmingSourceOption],
        thresholds: RemoteLibrarySlimmingThresholds,
        factoryThresholds: RemoteLibrarySlimmingThresholds
    ) {
        self.mediaKind = mediaKind
        self.sources = sources
        self.thresholds = thresholds
        self.factoryThresholds = factoryThresholds
    }
}

public struct RemoteLibrarySlimmingLaunchRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let mediaKind: RemoteAssetMediaKind
    public let mode: RemoteLibrarySlimmingAnalyzeMode
    /// `nil` means all active sources; `[]` means explicitly no source.
    public let sourceIDs: [UUID]?
    public let seedAssetIDs: [UUID]
    public let filter: RemoteAssetPageRequest?

    public init(
        operationID: UUID,
        mediaKind: RemoteAssetMediaKind,
        mode: RemoteLibrarySlimmingAnalyzeMode,
        sourceIDs: [UUID]? = nil,
        seedAssetIDs: [UUID] = [],
        filter: RemoteAssetPageRequest? = nil
    ) {
        self.operationID = operationID
        self.mediaKind = mediaKind
        self.mode = mode
        self.sourceIDs = sourceIDs
        self.seedAssetIDs = seedAssetIDs
        self.filter = filter
    }
}

public struct RemoteLibrarySlimmingLaunchResponse: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let jobID: UUID
    public let acceptedAtMs: Int64
    public let memberCount: Int
    public let replayed: Bool

    public init(
        operationID: UUID,
        jobID: UUID,
        acceptedAtMs: Int64,
        memberCount: Int,
        replayed: Bool
    ) {
        self.operationID = operationID
        self.jobID = jobID
        self.acceptedAtMs = acceptedAtMs
        self.memberCount = memberCount
        self.replayed = replayed
    }
}

public enum RemoteLibrarySlimmingJobAction: String, Codable, Sendable, Equatable {
    case pause
    case resume
    case deleteRecord
}

public struct RemoteLibrarySlimmingJobActionRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let action: RemoteLibrarySlimmingJobAction

    public init(operationID: UUID, action: RemoteLibrarySlimmingJobAction) {
        self.operationID = operationID
        self.action = action
    }
}

public struct RemoteLibrarySlimmingJobActionResponse: Codable, Sendable, Equatable {
    public let job: RemoteLibrarySlimmingJob?
    public let deleted: Bool
    public let replayed: Bool

    public init(job: RemoteLibrarySlimmingJob?, deleted: Bool, replayed: Bool) {
        self.job = job
        self.deleted = deleted
        self.replayed = replayed
    }
}

public struct RemoteLibrarySlimmingThresholdUpdateRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let thresholds: RemoteLibrarySlimmingThresholds

    public init(operationID: UUID, thresholds: RemoteLibrarySlimmingThresholds) {
        self.operationID = operationID
        self.thresholds = thresholds
    }
}

public struct RemoteLibrarySlimmingThresholdUpdateResponse: Codable, Sendable, Equatable {
    public let thresholds: RemoteLibrarySlimmingThresholds
    public let replayed: Bool

    public init(thresholds: RemoteLibrarySlimmingThresholds, replayed: Bool) {
        self.thresholds = thresholds
        self.replayed = replayed
    }
}

public enum RemoteLibrarySlimmingRecycleSourceKind: String, Codable, Sendable, Equatable {
    case file
    case photos
}

public enum RemoteLibrarySlimmingRecycleEntryState: String, Codable, Sendable, Equatable {
    case pending
    case recycled
    case restoring
    case purging
    case restored
    case purged
    case failed
}

public enum RemoteLibrarySlimmingRecycleResolution: String, Codable, Sendable, Equatable {
    case restoreOrPurge
    case discardPreflightFailure
    case retryInterruptedOperation
    case inspect
    case photosManagedBySystem
}

public enum RemoteLibrarySlimmingRecycleAction: String, Codable, Sendable, Equatable {
    case restore
    case discardPreflightFailure
    case retryInterruptedOperation
    case purge
}

public enum RemoteLibrarySlimmingRecycleRequestPhase: String, Codable, Sendable, Equatable {
    case awaitingMac
    case running
    case completed
    case cancelled
    case failed
}

public struct RemoteLibrarySlimmingRecycleEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let assetID: UUID
    public let sourceID: UUID
    public let sourceDisplayName: String
    public let sourceKind: RemoteLibrarySlimmingRecycleSourceKind
    public let mediaKind: RemoteAssetMediaKind
    public let fileName: String?
    public let trashedAtMs: Int64
    public let purgeAfterMs: Int64
    public let state: RemoteLibrarySlimmingRecycleEntryState
    public let errorCode: String?
    public let resolution: RemoteLibrarySlimmingRecycleResolution
    public let availableActions: [RemoteLibrarySlimmingRecycleAction]

    public init(
        id: UUID,
        assetID: UUID,
        sourceID: UUID,
        sourceDisplayName: String,
        sourceKind: RemoteLibrarySlimmingRecycleSourceKind,
        mediaKind: RemoteAssetMediaKind,
        fileName: String?,
        trashedAtMs: Int64,
        purgeAfterMs: Int64,
        state: RemoteLibrarySlimmingRecycleEntryState,
        errorCode: String?,
        resolution: RemoteLibrarySlimmingRecycleResolution,
        availableActions: [RemoteLibrarySlimmingRecycleAction]
    ) {
        self.id = id
        self.assetID = assetID
        self.sourceID = sourceID
        self.sourceDisplayName = sourceDisplayName
        self.sourceKind = sourceKind
        self.mediaKind = mediaKind
        self.fileName = fileName
        self.trashedAtMs = trashedAtMs
        self.purgeAfterMs = purgeAfterMs
        self.state = state
        self.errorCode = errorCode
        self.resolution = resolution
        self.availableActions = availableActions
    }
}

public struct RemoteLibrarySlimmingRecycleRequestSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let operationID: UUID
    public let entryID: UUID
    public let action: RemoteLibrarySlimmingRecycleAction
    public let fileName: String?
    public let phase: RemoteLibrarySlimmingRecycleRequestPhase
    public let message: String
    public let updatedAtMs: Int64

    public init(
        id: UUID,
        operationID: UUID,
        entryID: UUID,
        action: RemoteLibrarySlimmingRecycleAction,
        fileName: String?,
        phase: RemoteLibrarySlimmingRecycleRequestPhase,
        message: String,
        updatedAtMs: Int64
    ) {
        self.id = id
        self.operationID = operationID
        self.entryID = entryID
        self.action = action
        self.fileName = fileName
        self.phase = phase
        self.message = message
        self.updatedAtMs = updatedAtMs
    }
}

public struct RemoteLibrarySlimmingRecycleSnapshot: Codable, Sendable, Equatable {
    public let mediaKind: RemoteAssetMediaKind
    public let entries: [RemoteLibrarySlimmingRecycleEntry]
    public let totalCount: Int
    public let requests: [RemoteLibrarySlimmingRecycleRequestSnapshot]

    public init(
        mediaKind: RemoteAssetMediaKind,
        entries: [RemoteLibrarySlimmingRecycleEntry],
        totalCount: Int,
        requests: [RemoteLibrarySlimmingRecycleRequestSnapshot]
    ) {
        self.mediaKind = mediaKind
        self.entries = entries
        self.totalCount = totalCount
        self.requests = requests
    }
}

public struct RemoteLibrarySlimmingRecycleSubmitRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let entryID: UUID
    public let action: RemoteLibrarySlimmingRecycleAction

    public init(
        operationID: UUID,
        entryID: UUID,
        action: RemoteLibrarySlimmingRecycleAction
    ) {
        self.operationID = operationID
        self.entryID = entryID
        self.action = action
    }
}

public enum RemoteLibrarySlimmingRemovalMode: String, Codable, Sendable, Equatable {
    case recoverableRecycle
    case releaseSourceSpace
}

public enum RemoteLibrarySlimmingRemovalRequestPhase: String, Codable, Sendable, Equatable {
    case awaitingMac
    case running
    case completed
    case cancelled
    case failed
}

public enum RemoteLibrarySlimmingRemovalProgressPhase: String, Codable, Sendable, Equatable {
    case waitingForBackgroundIO
    case preparing
    case copying
    case syncingDestination
    case verifyingDestination
    case verifyingSource
    case deletingSource
    case syncingSourceDirectory
    case photosSystemMutation
    case completedAsset
}

public struct RemoteLibrarySlimmingRemovalProgress: Codable, Sendable, Equatable {
    public let phase: RemoteLibrarySlimmingRemovalProgressPhase
    public let completedAssetCount: Int
    public let totalAssetCount: Int
    public let copiedBytes: Int64
    public let totalFileBytes: Int64

    public init(
        phase: RemoteLibrarySlimmingRemovalProgressPhase,
        completedAssetCount: Int,
        totalAssetCount: Int,
        copiedBytes: Int64,
        totalFileBytes: Int64
    ) {
        self.phase = phase
        self.completedAssetCount = completedAssetCount
        self.totalAssetCount = totalAssetCount
        self.copiedBytes = copiedBytes
        self.totalFileBytes = totalFileBytes
    }
}

/// Safe per-item outcome. Asset IDs are catalog identities; source paths and
/// Photos local identifiers never cross the remote boundary.
public struct RemoteLibrarySlimmingRemovalAudit: Codable, Sendable, Equatable {
    public let hiddenAssetIDs: [UUID]
    public let recycledEntryIDs: [UUID]
    public let permanentlyDeletedAssetIDs: [UUID]
    public let durabilityPendingAssetIDs: [UUID]
    public let failedAssetIDs: [UUID]
    public let authorizationRequiredSourceIDs: [UUID]
    public let authorizationRequiredAssetIDs: [UUID]
    public let authorizationDeniedPhotosAssetIDs: [UUID]
    public let mutationAuthorizationInvalidAssetIDs: [UUID]
    public let photosMutationFailedAssetIDs: [UUID]
    public let photosMutationFailureCategories: [String]
    public let photosMutationFailureCodes: [String]
    public let sourceChangedAssetIDs: [UUID]

    public init(
        hiddenAssetIDs: [UUID],
        recycledEntryIDs: [UUID],
        permanentlyDeletedAssetIDs: [UUID],
        durabilityPendingAssetIDs: [UUID],
        failedAssetIDs: [UUID],
        authorizationRequiredSourceIDs: [UUID],
        authorizationRequiredAssetIDs: [UUID],
        authorizationDeniedPhotosAssetIDs: [UUID],
        mutationAuthorizationInvalidAssetIDs: [UUID],
        photosMutationFailedAssetIDs: [UUID],
        photosMutationFailureCategories: [String],
        photosMutationFailureCodes: [String],
        sourceChangedAssetIDs: [UUID]
    ) {
        self.hiddenAssetIDs = hiddenAssetIDs
        self.recycledEntryIDs = recycledEntryIDs
        self.permanentlyDeletedAssetIDs = permanentlyDeletedAssetIDs
        self.durabilityPendingAssetIDs = durabilityPendingAssetIDs
        self.failedAssetIDs = failedAssetIDs
        self.authorizationRequiredSourceIDs = authorizationRequiredSourceIDs
        self.authorizationRequiredAssetIDs = authorizationRequiredAssetIDs
        self.authorizationDeniedPhotosAssetIDs = authorizationDeniedPhotosAssetIDs
        self.mutationAuthorizationInvalidAssetIDs = mutationAuthorizationInvalidAssetIDs
        self.photosMutationFailedAssetIDs = photosMutationFailedAssetIDs
        self.photosMutationFailureCategories = photosMutationFailureCategories
        self.photosMutationFailureCodes = photosMutationFailureCodes
        self.sourceChangedAssetIDs = sourceChangedAssetIDs
    }
}

public struct RemoteLibrarySlimmingRemovalRequestSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let operationID: UUID
    public let jobID: UUID
    public let clusterID: UUID
    public let mediaKind: RemoteAssetMediaKind
    /// Immutable, canonical selection captured when the Host accepts the command.
    public let assetIDs: [UUID]
    public let mode: RemoteLibrarySlimmingRemovalMode
    public let phase: RemoteLibrarySlimmingRemovalRequestPhase
    public let progress: RemoteLibrarySlimmingRemovalProgress?
    public let audit: RemoteLibrarySlimmingRemovalAudit?
    public let message: String
    public let updatedAtMs: Int64

    public init(
        id: UUID,
        operationID: UUID,
        jobID: UUID,
        clusterID: UUID,
        mediaKind: RemoteAssetMediaKind,
        assetIDs: [UUID],
        mode: RemoteLibrarySlimmingRemovalMode,
        phase: RemoteLibrarySlimmingRemovalRequestPhase,
        progress: RemoteLibrarySlimmingRemovalProgress?,
        audit: RemoteLibrarySlimmingRemovalAudit?,
        message: String,
        updatedAtMs: Int64
    ) {
        self.id = id
        self.operationID = operationID
        self.jobID = jobID
        self.clusterID = clusterID
        self.mediaKind = mediaKind
        self.assetIDs = assetIDs
        self.mode = mode
        self.phase = phase
        self.progress = progress
        self.audit = audit
        self.message = message
        self.updatedAtMs = updatedAtMs
    }
}

public struct RemoteLibrarySlimmingRemovalSnapshot: Codable, Sendable, Equatable {
    public let mediaKind: RemoteAssetMediaKind
    public let requests: [RemoteLibrarySlimmingRemovalRequestSnapshot]

    public init(
        mediaKind: RemoteAssetMediaKind,
        requests: [RemoteLibrarySlimmingRemovalRequestSnapshot]
    ) {
        self.mediaKind = mediaKind
        self.requests = requests
    }
}

public struct RemoteLibrarySlimmingRemovalSubmitRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let jobID: UUID
    public let clusterID: UUID
    public let mediaKind: RemoteAssetMediaKind
    public let assetIDs: [UUID]
    public let mode: RemoteLibrarySlimmingRemovalMode

    public init(
        operationID: UUID,
        jobID: UUID,
        clusterID: UUID,
        mediaKind: RemoteAssetMediaKind,
        assetIDs: [UUID],
        mode: RemoteLibrarySlimmingRemovalMode
    ) {
        self.operationID = operationID
        self.jobID = jobID
        self.clusterID = clusterID
        self.mediaKind = mediaKind
        self.assetIDs = assetIDs
        self.mode = mode
    }
}

public struct RemoteLibrarySlimmingIdenticalCleanupPlanRequest: Codable, Sendable, Equatable {
    public let jobID: UUID
    public let mediaKind: RemoteAssetMediaKind

    public init(jobID: UUID, mediaKind: RemoteAssetMediaKind) {
        self.jobID = jobID
        self.mediaKind = mediaKind
    }
}

public struct RemoteLibrarySlimmingIdenticalCleanupPlanSnapshot:
    Codable, Sendable, Equatable, Identifiable
{
    public let id: UUID
    public let jobID: UUID
    public let mediaKind: RemoteAssetMediaKind
    public let groupCount: Int
    public let verifiedAssetCount: Int
    public let retainedAssetCount: Int
    public let removalAssetCount: Int
    public let skippedGroupCount: Int
    public let photosAssetCount: Int
    public let fileAssetCount: Int
    public let groupSizeHistogram: [Int: Int]
    public let preparedAtMs: Int64

    public init(
        id: UUID,
        jobID: UUID,
        mediaKind: RemoteAssetMediaKind,
        groupCount: Int,
        verifiedAssetCount: Int,
        retainedAssetCount: Int,
        removalAssetCount: Int,
        skippedGroupCount: Int,
        photosAssetCount: Int,
        fileAssetCount: Int,
        groupSizeHistogram: [Int: Int],
        preparedAtMs: Int64
    ) {
        self.id = id
        self.jobID = jobID
        self.mediaKind = mediaKind
        self.groupCount = groupCount
        self.verifiedAssetCount = verifiedAssetCount
        self.retainedAssetCount = retainedAssetCount
        self.removalAssetCount = removalAssetCount
        self.skippedGroupCount = skippedGroupCount
        self.photosAssetCount = photosAssetCount
        self.fileAssetCount = fileAssetCount
        self.groupSizeHistogram = groupSizeHistogram
        self.preparedAtMs = preparedAtMs
    }
}

public struct RemoteLibrarySlimmingIdenticalCleanupSubmitRequest:
    Codable, Sendable, Equatable
{
    public let operationID: UUID
    public let planID: UUID
    public let mode: RemoteLibrarySlimmingRemovalMode

    public init(
        operationID: UUID,
        planID: UUID,
        mode: RemoteLibrarySlimmingRemovalMode
    ) {
        self.operationID = operationID
        self.planID = planID
        self.mode = mode
    }
}

public struct RemoteLibrarySlimmingIdenticalCleanupVerification:
    Codable, Sendable, Equatable
{
    public let verifiedGroupCount: Int
    public let targetGroupCount: Int
    public let targetRetainedAssetCount: Int
    public let observedAssetCount: Int
    public let currentAvailableAssetCount: Int
    public let retainedNonredundantAssetCount: Int
    public let recycledRedundantAssetCount: Int
    public let remainingRedundantAssetCount: Int
    public let unresolvedAssetCount: Int
    public let unresolvedGroupCount: Int
    public let isComplete: Bool

    public init(
        verifiedGroupCount: Int,
        targetGroupCount: Int,
        targetRetainedAssetCount: Int,
        observedAssetCount: Int,
        currentAvailableAssetCount: Int,
        retainedNonredundantAssetCount: Int,
        recycledRedundantAssetCount: Int,
        remainingRedundantAssetCount: Int,
        unresolvedAssetCount: Int,
        unresolvedGroupCount: Int,
        isComplete: Bool
    ) {
        self.verifiedGroupCount = verifiedGroupCount
        self.targetGroupCount = targetGroupCount
        self.targetRetainedAssetCount = targetRetainedAssetCount
        self.observedAssetCount = observedAssetCount
        self.currentAvailableAssetCount = currentAvailableAssetCount
        self.retainedNonredundantAssetCount = retainedNonredundantAssetCount
        self.recycledRedundantAssetCount = recycledRedundantAssetCount
        self.remainingRedundantAssetCount = remainingRedundantAssetCount
        self.unresolvedAssetCount = unresolvedAssetCount
        self.unresolvedGroupCount = unresolvedGroupCount
        self.isComplete = isComplete
    }
}

public struct RemoteLibrarySlimmingIdenticalCleanupRequestSnapshot:
    Codable, Sendable, Equatable, Identifiable
{
    public let id: UUID
    public let operationID: UUID
    public let planID: UUID
    public let jobID: UUID
    public let mediaKind: RemoteAssetMediaKind
    public let mode: RemoteLibrarySlimmingRemovalMode
    public let phase: RemoteLibrarySlimmingRemovalRequestPhase
    public let progress: RemoteLibrarySlimmingRemovalProgress?
    public let audit: RemoteLibrarySlimmingRemovalAudit?
    public let verification: RemoteLibrarySlimmingIdenticalCleanupVerification?
    public let message: String
    public let updatedAtMs: Int64

    public init(
        id: UUID,
        operationID: UUID,
        planID: UUID,
        jobID: UUID,
        mediaKind: RemoteAssetMediaKind,
        mode: RemoteLibrarySlimmingRemovalMode,
        phase: RemoteLibrarySlimmingRemovalRequestPhase,
        progress: RemoteLibrarySlimmingRemovalProgress?,
        audit: RemoteLibrarySlimmingRemovalAudit?,
        verification: RemoteLibrarySlimmingIdenticalCleanupVerification?,
        message: String,
        updatedAtMs: Int64
    ) {
        self.id = id
        self.operationID = operationID
        self.planID = planID
        self.jobID = jobID
        self.mediaKind = mediaKind
        self.mode = mode
        self.phase = phase
        self.progress = progress
        self.audit = audit
        self.verification = verification
        self.message = message
        self.updatedAtMs = updatedAtMs
    }
}

public struct RemoteLibrarySlimmingIdenticalCleanupSnapshot: Codable, Sendable, Equatable {
    public let mediaKind: RemoteAssetMediaKind
    public let requests: [RemoteLibrarySlimmingIdenticalCleanupRequestSnapshot]

    public init(
        mediaKind: RemoteAssetMediaKind,
        requests: [RemoteLibrarySlimmingIdenticalCleanupRequestSnapshot]
    ) {
        self.mediaKind = mediaKind
        self.requests = requests
    }
}
