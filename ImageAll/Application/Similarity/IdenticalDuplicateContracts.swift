import Foundation

/// Versioned policy for S1 identical / perceptual-duplicate clustering.
enum IdenticalDuplicatePolicy {
    /// Difference-hash algorithm identity persisted in `asset_similarity_fingerprint.algo_version`.
    static let perceptualAlgoVersion = "dhash-v1"

    /// Maximum Hamming distance (inclusive) for `perceptualDuplicate` under `dhash-v1`.
    static let perceptualDuplicateMaxHammingDistance = 8
}

enum IdenticalDuplicateKind: String, Sendable, Equatable {
    case byteIdentical
    case perceptualDuplicate
}

struct IdenticalDuplicateCluster: Sendable, Equatable {
    let kind: IdenticalDuplicateKind
    let memberAssetIDs: [UUID]
    /// Stable pick: lexicographically smallest UUID among members.
    let representativeAssetID: UUID
    /// For `byteIdentical` this is 0; for perceptual, max pairwise Hamming among members.
    let score: Int
}

enum FingerprintCompletionError: Error, Equatable, Sendable {
    case notFound
    case ineligible
    case sourceChanged
    case sourceUnavailable
    case authorizationRequired
    case decodeFailed
    case persistenceFailed
}

struct AssetContentFingerprint: Sendable, Equatable {
    let assetID: UUID
    let contentRevision: Int
    let sha256: Data
    let perceptualHash: Data
    let perceptualAlgoVersion: String
}

protocol FingerprintCompletionPort: Sendable {
    /// Completes SHA-256 + perceptual hash for one folder asset. Idempotent when facts unchanged.
    func completeFolderAsset(assetID: UUID) throws -> AssetContentFingerprint

    /// Completes up to `limit` eligible folder assets that still need SHA-256 or current perceptual hash.
    func completePendingFolderAssets(limit: Int) throws -> [AssetContentFingerprint]
}

protocol IdenticalDuplicateScanPort: Sendable {
    /// Clusters assets that already have completed fingerprints. Incomplete assets are ignored.
    func clusterIdenticalDuplicates(assetIDs: [UUID]) throws -> [IdenticalDuplicateCluster]
}
