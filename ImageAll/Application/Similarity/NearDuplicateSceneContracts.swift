import Foundation

/// Versioned policy for S2 near-duplicate scene clustering (Feature Print recall + DINOv2 refine).
enum NearDuplicateScenePolicy {
    static let policyVersion = "near-dup-scene-v1"

    /// Feature Print coarse recall: keep up to this many nearest neighbors per asset (by L2).
    static let featurePrintRecallTopK = 16

    /// Feature Print coarse recall: discard neighbors with L2 distance above this radius.
    static let featurePrintMaxL2Distance = 25.0

    /// DINOv2 cosine similarity threshold (inclusive) for `nearDuplicateScene`.
    static let dinoCosineMinSimilarity = 0.88

    /// Cap embedding generations per scan so the S2 sync path stays interactive.
    static let maxEmbeddingGenerationsPerScan = 48

    /// Cap catalog assets considered by a full-library S2 scan.
    static let defaultCatalogScanLimit = 200
}

enum SlimmingClusterKind: String, Sendable, Equatable {
    case byteIdentical
    case perceptualDuplicate
    case nearDuplicateScene
}

struct SlimmingCluster: Sendable, Equatable, Identifiable {
    let id: UUID
    let kind: SlimmingClusterKind
    let memberAssetIDs: [UUID]
    /// Stable pick: lexicographically smallest UUID among members.
    let representativeAssetID: UUID
    /// Higher is better. byteIdentical → 1.0; perceptual → 1 - maxHamming/64; scene → max pairwise cosine.
    let score: Double
    let scoreVersion: String
}

struct LibrarySlimmingScanResult: Sendable, Equatable {
    let clusters: [SlimmingCluster]
    let pendingAnalysisAssetIDs: [UUID]
    let analyzedAssetCount: Int
    let policyVersion: String
}

protocol SlimmingFeatureVectorLoading: Sendable {
    /// Returns Feature Print float32 values, or `nil` when unavailable / ineligible.
    func featureVector(assetID: UUID) throws -> [Float]?
}

protocol SlimmingEmbeddingLoading: Sendable {
    /// Returns DINOv2 embedding values, or `nil` when unavailable / ineligible.
    func embedding(assetID: UUID) throws -> [Float]?
}

protocol LibrarySlimmingScanPort: Sendable {
    /// Clusters the given assets. Incomplete fingerprints / vectors become pending.
    func scan(assetIDs: [UUID]) throws -> LibrarySlimmingScanResult

    /// Scans up to `limit` current available catalog assets (deterministic UUID order).
    func scanCatalog(limit: Int) throws -> LibrarySlimmingScanResult
}
