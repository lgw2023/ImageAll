import Foundation

/// Versioned policy for S1 identical / perceptual-duplicate clustering.
enum IdenticalDuplicatePolicy {
    /// Difference-hash algorithm identity persisted in `asset_similarity_fingerprint.algo_version`.
    static let perceptualAlgoVersion = "dhash-rgbverify-v2"
    /// Video visual verification runs against the deterministic representative poster.
    static let videoPosterPerceptualAlgoVersion = "videoPoster.v1-dhash-rgbverify-v2"

    /// Maximum Hamming distance (inclusive) for the dHash candidate stage.
    static let perceptualDuplicateMaxHammingDistance = 8
}

extension IdenticalDuplicatePolicy {
    static func perceptualAlgoVersion(for mediaKind: MediaKind) -> String {
        switch mediaKind {
        case .image: perceptualAlgoVersion
        case .video: videoPosterPerceptualAlgoVersion
        }
    }
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
    let verificationSignature: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let perceptualAlgoVersion: String
}

protocol FingerprintCompletionPort: Sendable {
    /// Completes durable content + perceptual verification for one folder or
    /// Photos asset. Photos originals are implicitly materialized and cached.
    func completeAsset(assetID: UUID) throws -> AssetContentFingerprint

    /// Backward-compatible folder-only entry point.
    func completeFolderAsset(assetID: UUID) throws -> AssetContentFingerprint

    /// Completes up to `limit` eligible assets that still need current analysis.
    func completePendingAssets(limit: Int) throws -> [AssetContentFingerprint]

    /// Backward-compatible folder-only batch entry point.
    func completePendingFolderAssets(limit: Int) throws -> [AssetContentFingerprint]
}

protocol IdenticalDuplicateScanPort: Sendable {
    /// Clusters assets that already have completed fingerprints. Incomplete assets are ignored.
    func clusterIdenticalDuplicates(
        assetIDs: [UUID],
        mediaKind: MediaKind
    ) throws -> [IdenticalDuplicateCluster]
}

extension IdenticalDuplicateScanPort {
    func clusterIdenticalDuplicates(assetIDs: [UUID]) throws -> [IdenticalDuplicateCluster] {
        try clusterIdenticalDuplicates(assetIDs: assetIDs, mediaKind: .image)
    }
}
