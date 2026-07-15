import Foundation

struct FolderReconcileCheckpointV1: Equatable, Sendable, Codable {
    let contractVersion: Int
    let generation: Int
    let startedDirtyEpoch: Int
    let attempt: Int
    let enumeratedEntries: Int
    let candidateFiles: Int
    let committedAssets: Int
    let ignoredEntries: Int
    let unsupportedAssets: Int
    let unreadableAssets: Int
    let identityConflicts: Int

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case generation
        case startedDirtyEpoch = "started_dirty_epoch"
        case attempt
        case enumeratedEntries = "enumerated_entries"
        case candidateFiles = "candidate_files"
        case committedAssets = "committed_assets"
        case ignoredEntries = "ignored_entries"
        case unsupportedAssets = "unsupported_assets"
        case unreadableAssets = "unreadable_assets"
        case identityConflicts = "identity_conflicts"
    }

    static let contractVersionValue = 1

    init(
        generation: Int,
        startedDirtyEpoch: Int,
        attempt: Int,
        enumeratedEntries: Int = 0,
        candidateFiles: Int = 0,
        committedAssets: Int = 0,
        ignoredEntries: Int = 0,
        unsupportedAssets: Int = 0,
        unreadableAssets: Int = 0,
        identityConflicts: Int = 0
    ) {
        self.contractVersion = Self.contractVersionValue
        self.generation = generation
        self.startedDirtyEpoch = startedDirtyEpoch
        self.attempt = attempt
        self.enumeratedEntries = enumeratedEntries
        self.candidateFiles = candidateFiles
        self.committedAssets = committedAssets
        self.ignoredEntries = ignoredEntries
        self.unsupportedAssets = unsupportedAssets
        self.unreadableAssets = unreadableAssets
        self.identityConflicts = identityConflicts
    }
}

struct FolderReconcileAssetObservation: Equatable, Sendable {
    let relativePath: String
    let fileName: String
    let mediaType: String
    let width: Int?
    let height: Int?
    let mediaCreatedAtMs: Int64?
    let availability: AssetAvailability
    let sizeBytes: Int64
    let modifiedAtNs: Int64
    let resourceID: Data?
    let reconnectAssetID: UUID?
}

struct FolderBeginGenerationResult: Equatable, Sendable {
    let generation: Int
    let startedDirtyEpoch: Int
    let checkpoint: FolderReconcileCheckpointV1
}

struct FolderBatchCommitResult: Equatable, Sendable {
    let jobSnapshot: JobRecordSnapshot
    let checkpoint: FolderReconcileCheckpointV1
    let identityConflictsAdded: Int
}

struct FolderCompleteGenerationResult: Equatable, Sendable {
    let jobSnapshot: JobRecordSnapshot
    let checkpoint: FolderReconcileCheckpointV1
    let successorJobID: UUID?
}

struct FolderBeginGenerationInput: Sendable {
    let lease: JobLeaseToken
    let sourceID: UUID
    let leaseDurationMs: Int64
}

struct FolderAssetBatchInput: Sendable {
    let lease: JobLeaseToken
    let sourceID: UUID
    let generation: Int
    let startedDirtyEpoch: Int
    let checkpoint: FolderReconcileCheckpointV1
    let observations: [FolderReconcileAssetObservation]
    let leaseDurationMs: Int64
    let outcome: JobHandlerOutcome
}

struct FolderCompleteGenerationInput: Sendable {
    let lease: JobLeaseToken
    let sourceID: UUID
    let generation: Int
    let startedDirtyEpoch: Int
    let checkpoint: FolderReconcileCheckpointV1
    let leaseDurationMs: Int64
}

struct FolderStopIncompleteInput: Sendable {
    let lease: JobLeaseToken
    let sourceID: UUID
    let checkpoint: FolderReconcileCheckpointV1
    let leaseDurationMs: Int64
    let errorCode: JobSafeErrorCode
    let outcome: JobHandlerOutcome
}
