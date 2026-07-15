import Foundation

struct FolderReconcileJobContext: Equatable, Sendable {
    let jobID: UUID
    let kind: String
    let payloadVersion: Int
    let sourceID: UUID?
    let scanGeneration: Int?
    let startedDirtyEpoch: Int?
    let progressCompleted: Int
}

protocol FolderReconcileJobLookupPort: Sendable {
    func fetchJobContext(jobID: UUID) throws -> FolderReconcileJobContext
}

struct FolderMoveCandidate: Equatable, Sendable {
    let assetID: UUID
    let relativePath: String
    let sizeBytes: Int64
    let modifiedAtNs: Int64
    let resourceID: Data?
}

protocol FolderReconcileBatchPort: FolderReconcileJobLookupPort, Sendable {
    func beginGeneration(_ input: FolderBeginGenerationInput) throws -> FolderBeginGenerationResult
    func commitAssetBatch(_ input: FolderAssetBatchInput) throws -> FolderBatchCommitResult
    func completeGeneration(_ input: FolderCompleteGenerationInput) throws -> FolderCompleteGenerationResult
    func stopIncomplete(_ input: FolderStopIncompleteInput) throws -> FolderBatchCommitResult
    func lookupMoveCandidates(sourceID: UUID, resourceID: Data, excludingGeneration: Int) throws -> [FolderMoveCandidate]
}
