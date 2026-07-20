import Foundation

enum AppPersonalModelRebuildError: Error, Equatable {
    case alreadyRunning
    case cancelled
    case invalidSnapshot
    case modelUnavailable
    case embeddingUnavailable
    case staleSnapshot
}

protocol AppPersonalModelRebuilding: Sendable {
    func rebuild() async throws -> AppPersonalLinearHeadIdentity
}

protocol AppPersonalTrainingSnapshotSource: Sendable {
    func currentSnapshot() async throws -> PersonalTrainingSnapshot
}

protocol AppPersonalTrainingEmbeddingSource: Sendable {
    func cachedEmbedding(
        for key: PersonalTrainingEmbeddingCacheKey
    ) async throws -> PersonalTrainingEmbedding?
}
