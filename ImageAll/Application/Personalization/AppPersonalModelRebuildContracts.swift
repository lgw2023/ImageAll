import Foundation

enum AppPersonalModelRebuildError: Error, Equatable {
    case alreadyRunning
    case cancelled
    case invalidSnapshot
    case embeddingUnavailable
    case staleSnapshot
}

protocol AppPersonalTrainingSnapshotSource: Sendable {
    func currentSnapshot() async throws -> PersonalTrainingSnapshot
}

protocol AppPersonalTrainingEmbeddingSource: Sendable {
    func cachedEmbedding(
        for key: PersonalTrainingEmbeddingCacheKey
    ) async throws -> PersonalTrainingEmbedding?
}
