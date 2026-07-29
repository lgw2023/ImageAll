import Foundation

/// ADR-045: per-source Feature Print LSH neighborhood index used to accelerate seed search.
enum SourceSimilarityIndexState: String, Sendable, Equatable, Codable {
    case building
    case ready
    case stale
    case failed
}

struct SourceSimilarityIndexStatus: Sendable, Equatable {
    let sourceID: UUID
    let mediaKind: MediaKind
    let state: SourceSimilarityIndexState
    let assetCount: Int
    let indexedCount: Int
    let clusterCount: Int
    let pendingCount: Int
    let updatedAtMs: Int64
    let lastError: String?
}

/// Result of narrowing a seed search universe using ready source indexes.
/// `.fullUniverse` is the safe fallback whenever any universe asset's source
/// lacks a compatible ready index (ADR-045 LS-P11).
enum SourceSimilarityCandidatePlan: Sendable, Equatable {
    case restricted(candidates: [UUID])
    case fullUniverse
}

protocol SourceSimilarityIndexPort: Sendable {
    func status(sourceID: UUID) throws -> SourceSimilarityIndexStatus?
    func status(sourceID: UUID, mediaKind: MediaKind) throws -> SourceSimilarityIndexStatus?

    /// Enqueues (or returns the already-running) durable build job for `sourceID`.
    func enqueueBuild(sourceID: UUID) throws -> UUID
    func enqueueBuild(sourceID: UUID, mediaKind: MediaKind) throws -> UUID

    /// Drives the underlying job queue to completion for pending source-index builds.
    func runPending() throws

    /// Narrows `universeAssetIDs` to each seed's Feature Print LSH neighborhood when every
    /// universe asset belongs to a compatible ready index; otherwise falls back to the full
    /// universe so correctness never depends on index freshness.
    func candidateAssetIDs(
        seedAssetIDs: [UUID],
        universeAssetIDs: [UUID]
    ) throws -> SourceSimilarityCandidatePlan
    func candidateAssetIDs(
        seedAssetIDs: [UUID],
        universeAssetIDs: [UUID],
        mediaKind: MediaKind
    ) throws -> SourceSimilarityCandidatePlan
}

extension SourceSimilarityIndexPort {
    func status(sourceID: UUID, mediaKind _: MediaKind) throws -> SourceSimilarityIndexStatus? {
        try status(sourceID: sourceID)
    }

    func enqueueBuild(sourceID: UUID, mediaKind _: MediaKind) throws -> UUID {
        try enqueueBuild(sourceID: sourceID)
    }

    func candidateAssetIDs(
        seedAssetIDs: [UUID],
        universeAssetIDs: [UUID],
        mediaKind _: MediaKind
    ) throws -> SourceSimilarityCandidatePlan {
        try candidateAssetIDs(
            seedAssetIDs: seedAssetIDs,
            universeAssetIDs: universeAssetIDs
        )
    }
}
