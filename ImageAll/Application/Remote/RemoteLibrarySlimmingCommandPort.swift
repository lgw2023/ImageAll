import Foundation

enum LibrarySlimmingCommandError: Error, Equatable, Sendable {
    case unavailable
    case invalidSelection
    case activeConflict
    case jobNotFound
    case invalidAction
    case recycleEntryNotFound
    case operationConflict
    case cleanupPlanNotFound
    case cleanupPlanChanged
}

struct LibrarySlimmingCommandSetupSnapshot: Equatable, Sendable {
    let mediaKind: MediaKind
    let sources: [LibrarySourceSummary]
    let thresholds: NearDuplicateSceneThresholds
    let factoryThresholds: NearDuplicateSceneThresholds
}

struct LibrarySlimmingLaunchCommand: Equatable, Sendable {
    let operationID: UUID
    let mediaKind: MediaKind
    let mode: LibrarySlimmingAnalyzeMode
    /// `nil` means all active sources; an empty set is an explicit invalid selection.
    let sourceIDs: Set<UUID>?
    let seedAssetIDs: Set<UUID>
    let filter: AssetPageFilter?
    let sort: AssetPageSort
}

struct LibrarySlimmingLaunchReceipt: Equatable, Sendable {
    let operationID: UUID
    let jobID: UUID
    let acceptedAtMs: Int64
    let memberCount: Int
}

enum LibrarySlimmingJobCommandAction: String, Equatable, Sendable {
    case pause
    case resume
    case deleteRecord
}

struct LibrarySlimmingJobCommandResult: Equatable, Sendable {
    let snapshot: LibrarySlimmingAnalysisJobSnapshot?
    let deleted: Bool
}

enum LibrarySlimmingRecycleCommandAction: String, Equatable, Sendable {
    case restore
    case discardPreflightFailure
    case retryInterruptedOperation
    case purge
}

enum LibrarySlimmingRecycleCommandPhase: String, Equatable, Sendable {
    case awaitingMac
    case running
    case completed
    case cancelled
    case failed
}

struct LibrarySlimmingRecycleCommandRequest: Equatable, Sendable {
    let operationID: UUID
    let entryID: UUID
    let action: LibrarySlimmingRecycleCommandAction
}

struct LibrarySlimmingRecycleCommandRequestSnapshot: Equatable, Sendable {
    let id: UUID
    let operationID: UUID
    let entryID: UUID
    let action: LibrarySlimmingRecycleCommandAction
    let fileName: String?
    let phase: LibrarySlimmingRecycleCommandPhase
    let message: String
    let updatedAtMs: Int64
}

enum LibrarySlimmingRecycleCommandScope: String, Equatable, Sendable {
    case all
    case photos
    case files
    case attention
}

struct LibrarySlimmingRecycleCommandScopeCounts: Equatable, Sendable {
    let all: Int
    let photos: Int
    let files: Int
    let attention: Int
}

struct LibrarySlimmingRecycleCommandSnapshot: Equatable, Sendable {
    let entries: [RecycleEntryRecord]
    let totalCount: Int
    let sourceNames: [UUID: String]
    let requests: [LibrarySlimmingRecycleCommandRequestSnapshot]
    let scopeCounts: LibrarySlimmingRecycleCommandScopeCounts
}

enum LibrarySlimmingRemovalCommandMode: String, Equatable, Sendable {
    case recoverableRecycle
    case releaseSourceSpace
}

struct LibrarySlimmingRemovalCommand: Equatable, Sendable {
    let operationID: UUID
    let jobID: UUID
    let clusterID: UUID
    let mediaKind: MediaKind
    let assetIDs: [UUID]
    let mode: LibrarySlimmingRemovalCommandMode
}

struct LibrarySlimmingRemovalCommandProgress: Equatable, Sendable {
    let phase: LibrarySlimmingRecycleMovePhase
    let completedAssetCount: Int
    let totalAssetCount: Int
    let copiedBytes: Int64
    let totalFileBytes: Int64
}

struct LibrarySlimmingRemovalCommandAudit: Equatable, Sendable {
    let hiddenAssetIDs: [UUID]
    let recycledEntryIDs: [UUID]
    let permanentlyDeletedAssetIDs: [UUID]
    let durabilityPendingAssetIDs: [UUID]
    let failedAssetIDs: [UUID]
    let authorizationRequiredSourceIDs: [UUID]
    let authorizationRequiredAssetIDs: [UUID]
    let authorizationDeniedPhotosAssetIDs: [UUID]
    let mutationAuthorizationInvalidAssetIDs: [UUID]
    let photosMutationFailedAssetIDs: [UUID]
    let photosMutationFailureCategories: [PhotosLibraryMutationFailureCategory]
    let photosMutationFailureCodes: [String]
    let sourceChangedAssetIDs: [UUID]
}

struct LibrarySlimmingRemovalCommandRequestSnapshot: Equatable, Sendable {
    let id: UUID
    let operationID: UUID
    let jobID: UUID
    let clusterID: UUID
    let mediaKind: MediaKind
    let assetIDs: [UUID]
    let mode: LibrarySlimmingRemovalCommandMode
    let phase: LibrarySlimmingRecycleCommandPhase
    let progress: LibrarySlimmingRemovalCommandProgress?
    let audit: LibrarySlimmingRemovalCommandAudit?
    let message: String
    let updatedAtMs: Int64
}

struct LibrarySlimmingRemovalCommandSnapshot: Equatable, Sendable {
    let requests: [LibrarySlimmingRemovalCommandRequestSnapshot]
}

struct LibrarySlimmingIdenticalCleanupPlanSnapshot: Equatable, Sendable {
    let id: UUID
    let jobID: UUID
    let mediaKind: MediaKind
    let groupCount: Int
    let verifiedAssetCount: Int
    let retainedAssetCount: Int
    let removalAssetCount: Int
    let skippedGroupCount: Int
    let photosAssetCount: Int
    let fileAssetCount: Int
    let groupSizeHistogram: [Int: Int]
    let preparedAtMs: Int64
}

struct LibrarySlimmingIdenticalCleanupCommand: Equatable, Sendable {
    let operationID: UUID
    let planID: UUID
    let mode: LibrarySlimmingRemovalCommandMode
}

struct LibrarySlimmingIdenticalCleanupVerificationSnapshot: Equatable, Sendable {
    let verifiedGroupCount: Int
    let targetGroupCount: Int
    let targetRetainedAssetCount: Int
    let observedAssetCount: Int
    let currentAvailableAssetCount: Int
    let retainedNonredundantAssetCount: Int
    let recycledRedundantAssetCount: Int
    let remainingRedundantAssetCount: Int
    let unresolvedAssetCount: Int
    let unresolvedGroupCount: Int
    let isComplete: Bool
}

struct LibrarySlimmingIdenticalCleanupRequestSnapshot: Equatable, Sendable {
    let id: UUID
    let operationID: UUID
    let planID: UUID
    let jobID: UUID
    let mediaKind: MediaKind
    let mode: LibrarySlimmingRemovalCommandMode
    let phase: LibrarySlimmingRecycleCommandPhase
    let progress: LibrarySlimmingRemovalCommandProgress?
    let audit: LibrarySlimmingRemovalCommandAudit?
    let verification: LibrarySlimmingIdenticalCleanupVerificationSnapshot?
    let message: String
    let updatedAtMs: Int64
}

struct LibrarySlimmingIdenticalCleanupSnapshot: Equatable, Sendable {
    let requests: [LibrarySlimmingIdenticalCleanupRequestSnapshot]
}

enum RemoteLibrarySlimmingNativeApproval: Equatable, Sendable {
    case restore(fileName: String)
    case retry(fileName: String)
    case purge(fileName: String)
    case recoverableBatch(count: Int, mediaKind: MediaKind)
    case releaseSpaceBatch(count: Int, mediaKind: MediaKind)
    case identicalCleanup(
        groupCount: Int,
        removalCount: Int,
        mediaKind: MediaKind,
        mode: LibrarySlimmingRemovalCommandMode
    )
}

protocol RemoteLibrarySlimmingNativeApprovalPresenting: Sendable {
    @MainActor
    func confirm(_ approval: RemoteLibrarySlimmingNativeApproval) -> Bool
}

protocol RemoteLibrarySlimmingCommandPort: Sendable {
    func setup(mediaKind: MediaKind) async throws -> LibrarySlimmingCommandSetupSnapshot
    func launch(_ command: LibrarySlimmingLaunchCommand) async throws
        -> LibrarySlimmingLaunchReceipt
    func apply(
        jobID: UUID,
        action: LibrarySlimmingJobCommandAction
    ) async throws -> LibrarySlimmingJobCommandResult
    func updateThresholds(_ thresholds: NearDuplicateSceneThresholds) async throws
        -> NearDuplicateSceneThresholds
    func setClusterReviewDisposition(
        jobID: UUID,
        clusterID: UUID,
        disposition: LibrarySlimmingClusterReviewDisposition?
    ) async throws -> LibrarySlimmingClusterReviewDisposition?
    func recycleSnapshot(
        mediaKind: MediaKind,
        sourceID: UUID?,
        searchText: String?,
        scope: LibrarySlimmingRecycleCommandScope,
        limit: Int
    ) async throws -> LibrarySlimmingRecycleCommandSnapshot
    func submitRecycle(
        _ command: LibrarySlimmingRecycleCommandRequest
    ) async throws -> LibrarySlimmingRecycleCommandRequestSnapshot
    func removalSnapshot(
        mediaKind: MediaKind
    ) async throws -> LibrarySlimmingRemovalCommandSnapshot
    func submitRemoval(
        _ command: LibrarySlimmingRemovalCommand
    ) async throws -> LibrarySlimmingRemovalCommandRequestSnapshot
    func prepareIdenticalCleanup(
        jobID: UUID,
        mediaKind: MediaKind
    ) async throws -> LibrarySlimmingIdenticalCleanupPlanSnapshot
    func identicalCleanupSnapshot(
        mediaKind: MediaKind
    ) async throws -> LibrarySlimmingIdenticalCleanupSnapshot
    func submitIdenticalCleanup(
        _ command: LibrarySlimmingIdenticalCleanupCommand
    ) async throws -> LibrarySlimmingIdenticalCleanupRequestSnapshot
    func slimmingHiddenAssetIDs(from assetIDs: [UUID]) async throws -> Set<UUID>
}

extension RemoteLibrarySlimmingCommandPort {
    func setClusterReviewDisposition(
        jobID _: UUID,
        clusterID _: UUID,
        disposition _: LibrarySlimmingClusterReviewDisposition?
    ) async throws -> LibrarySlimmingClusterReviewDisposition? {
        throw LibrarySlimmingCommandError.unavailable
    }

    func recycleSnapshot(
        mediaKind _: MediaKind,
        sourceID _: UUID?,
        searchText _: String?,
        scope _: LibrarySlimmingRecycleCommandScope,
        limit _: Int
    ) async throws -> LibrarySlimmingRecycleCommandSnapshot {
        throw LibrarySlimmingCommandError.unavailable
    }

    func submitRecycle(
        _ command: LibrarySlimmingRecycleCommandRequest
    ) async throws -> LibrarySlimmingRecycleCommandRequestSnapshot {
        throw LibrarySlimmingCommandError.unavailable
    }

    func removalSnapshot(
        mediaKind _: MediaKind
    ) async throws -> LibrarySlimmingRemovalCommandSnapshot {
        throw LibrarySlimmingCommandError.unavailable
    }

    func submitRemoval(
        _ command: LibrarySlimmingRemovalCommand
    ) async throws -> LibrarySlimmingRemovalCommandRequestSnapshot {
        throw LibrarySlimmingCommandError.unavailable
    }

    func slimmingHiddenAssetIDs(from _: [UUID]) async throws -> Set<UUID> {
        []
    }

    func prepareIdenticalCleanup(
        jobID _: UUID,
        mediaKind _: MediaKind
    ) async throws -> LibrarySlimmingIdenticalCleanupPlanSnapshot {
        throw LibrarySlimmingCommandError.unavailable
    }

    func identicalCleanupSnapshot(
        mediaKind _: MediaKind
    ) async throws -> LibrarySlimmingIdenticalCleanupSnapshot {
        throw LibrarySlimmingCommandError.unavailable
    }

    func submitIdenticalCleanup(
        _ command: LibrarySlimmingIdenticalCleanupCommand
    ) async throws -> LibrarySlimmingIdenticalCleanupRequestSnapshot {
        throw LibrarySlimmingCommandError.unavailable
    }
}
