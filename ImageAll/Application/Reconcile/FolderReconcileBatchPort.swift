import Foundation

protocol FolderReconcileBatchPort: Sendable {
    func beginGeneration(_ input: FolderBeginGenerationInput) throws -> FolderBeginGenerationResult
    func commitAssetBatch(_ input: FolderAssetBatchInput) throws -> FolderBatchCommitResult
    func completeGeneration(_ input: FolderCompleteGenerationInput) throws -> FolderCompleteGenerationResult
    func stopIncomplete(_ input: FolderStopIncompleteInput) throws -> FolderBatchCommitResult
}
