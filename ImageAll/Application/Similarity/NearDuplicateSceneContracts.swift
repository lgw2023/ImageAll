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

    /// Closed-world scene clustering activates capture-day buckets at or above this count.
    static let sceneBucketActivationAssetCount = 256
}

/// User-overridable scene-clustering thresholds. Factory defaults match `NearDuplicateScenePolicy`.
struct NearDuplicateSceneThresholds: Sendable, Equatable {
    var featurePrintRecallTopK: Int
    var featurePrintMaxL2Distance: Double
    var dinoCosineMinSimilarity: Double
    var sceneBucketActivationAssetCount: Int

    static let factory = NearDuplicateSceneThresholds(
        featurePrintRecallTopK: NearDuplicateScenePolicy.featurePrintRecallTopK,
        featurePrintMaxL2Distance: NearDuplicateScenePolicy.featurePrintMaxL2Distance,
        dinoCosineMinSimilarity: NearDuplicateScenePolicy.dinoCosineMinSimilarity,
        sceneBucketActivationAssetCount: NearDuplicateScenePolicy.sceneBucketActivationAssetCount
    )

    /// Encodes base policy identity plus effective numeric thresholds.
    var policyVersion: String {
        String(
            format: "%@;topk=%d;l2=%.2f;dino=%.3f;bucket=%d",
            NearDuplicateScenePolicy.policyVersion,
            featurePrintRecallTopK,
            featurePrintMaxL2Distance,
            dinoCosineMinSimilarity,
            sceneBucketActivationAssetCount
        )
    }

    func clamped() -> NearDuplicateSceneThresholds {
        NearDuplicateSceneThresholds(
            featurePrintRecallTopK: min(max(featurePrintRecallTopK, 1), 128),
            featurePrintMaxL2Distance: min(max(featurePrintMaxL2Distance, 0.1), 200),
            dinoCosineMinSimilarity: min(max(dinoCosineMinSimilarity, 0.5), 0.999),
            sceneBucketActivationAssetCount: min(max(sceneBucketActivationAssetCount, 2), 10_000)
        )
    }
}

protocol NearDuplicateSceneThresholdReading: Sendable {
    func thresholds() -> NearDuplicateSceneThresholds
}

protocol NearDuplicateSceneThresholdWriting: NearDuplicateSceneThresholdReading {
    func setThresholds(_ thresholds: NearDuplicateSceneThresholds)
    func resetToFactory()
}

struct StaticNearDuplicateSceneThresholds: NearDuplicateSceneThresholdReading {
    let value: NearDuplicateSceneThresholds

    func thresholds() -> NearDuplicateSceneThresholds { value }
}

enum SlimmingCaptureDayBucketing {
    /// Local calendar day `YYYY-MM-DD`, or `unknown` when `media_created_at_ms` is missing.
    static func bucketKey(mediaCreatedAtMs: Int64?, calendar: Calendar = .current) -> String {
        guard let mediaCreatedAtMs else { return "unknown" }
        let date = Date(timeIntervalSince1970: TimeInterval(mediaCreatedAtMs) / 1_000)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else {
            return "unknown"
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// Hardware-scaled per-scan generation caps (cache hits never consume budget).
enum SlimmingScanBudgetPolicy {
    struct Budgets: Sendable, Equatable {
        let featurePrintGenerations: Int
        let embeddingGenerations: Int
    }

    static func budgets(forAssetCount assetCount: Int) -> Budgets {
        let cappedAssets = max(0, assetCount)
        let memoryGB = ProcessInfo.processInfo.physicalMemory / (1_024 * 1_024 * 1_024)
        let cores = ProcessInfo.processInfo.activeProcessorCount

        let memoryTier = min(max(Int(memoryGB / 8), 1), 4)
        let coreTier = min(max(cores / 4, 1), 3)
        let scale = memoryTier + coreTier - 1

        let fpCap = min(cappedAssets, 96 * scale)
        let embeddingCap = min(cappedAssets, 64 * scale)
        return Budgets(
            featurePrintGenerations: cappedAssets == 0 ? 0 : max(fpCap, min(cappedAssets, 96)),
            embeddingGenerations: cappedAssets == 0 ? 0 : max(embeddingCap, min(cappedAssets, 64))
        )
    }
}

struct SlimmingVectorModelIdentity: Sendable, Equatable {
    let featurePrintProvider: String?
    let featurePrintRequestRevision: Int?
    let featurePrintPreprocessingRevision: Int?
    let embeddingProvider: String?
    let embeddingModelID: String?
    let embeddingModelRevision: String?
    let embeddingPreprocessingRevision: String?
    let perceptualAlgoVersion: String?
    let policyVersion: String

    static let featurePrintOnly = SlimmingVectorModelIdentity(
        featurePrintProvider: PersonalizationConstants.provider,
        featurePrintRequestRevision: PersonalizationConstants.requestRevision,
        featurePrintPreprocessingRevision: PersonalizationConstants.preprocessingRevision,
        embeddingProvider: nil,
        embeddingModelID: nil,
        embeddingModelRevision: nil,
        embeddingPreprocessingRevision: nil,
        perceptualAlgoVersion: nil,
        policyVersion: NearDuplicateScenePolicy.policyVersion
    )

    var revisionCaption: String {
        var parts: [String] = []
        if let featurePrintProvider,
           let featurePrintRequestRevision
        {
            var fp = "fp:\(featurePrintProvider)/r\(featurePrintRequestRevision)"
            if let featurePrintPreprocessingRevision {
                fp += "/p\(featurePrintPreprocessingRevision)"
            }
            parts.append(fp)
        }
        if let embeddingProvider,
           let embeddingModelID,
           let embeddingModelRevision
        {
            var dino = "dino:\(embeddingProvider)/\(embeddingModelID)/\(embeddingModelRevision)"
            if let embeddingPreprocessingRevision {
                dino += "/prep\(embeddingPreprocessingRevision)"
            }
            parts.append(dino)
        }
        if let perceptualAlgoVersion {
            parts.append("dup:\(perceptualAlgoVersion)")
        }
        parts.append("policy:\(policyVersion)")
        return parts.joined(separator: ";")
    }
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
    /// Higher is better. byteIdentical → 1.0; perceptual → 1 - maxHamming/64; scene → min pairwise cosine.
    let score: Double
    let modelIdentity: SlimmingVectorModelIdentity
}

struct LibrarySlimmingScanProgress: Sendable, Equatable {
    enum Phase: String, Sendable, Equatable {
        case preparingFingerprints
        case loadingFeaturePrints
        case loadingEmbeddings
        case clustering
    }

    let phase: Phase
    let completed: Int
    let total: Int

    var caption: String {
        switch phase {
        case .preparingFingerprints:
            "补全内容指纹 \(completed)/\(total)"
        case .loadingFeaturePrints:
            "加载 Feature Print \(completed)/\(total)"
        case .loadingEmbeddings:
            "加载 DINOv2 向量 \(completed)/\(total)"
        case .clustering:
            "聚类分析 \(completed)/\(total)"
        }
    }

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

struct LibrarySlimmingScanResult: Sendable, Equatable {
    let clusters: [SlimmingCluster]
    let pendingAnalysisAssetIDs: [UUID]
    let analyzedAssetCount: Int
    let policyVersion: String
}

protocol SlimmingBudgetResetting: Sendable {
    func resetScanBudgets(forAssetCount assetCount: Int)
}

protocol SlimmingFeatureVectorLoading: Sendable {
    /// Returns Feature Print float32 values, or `nil` when unavailable / ineligible / budget exhausted.
    func featureVector(assetID: UUID) throws -> [Float]?
}

protocol SlimmingEmbeddingLoading: Sendable {
    /// Returns DINOv2 embedding values, or `nil` when unavailable / ineligible / budget exhausted.
    func embedding(assetID: UUID) throws -> [Float]?

    /// When implemented, supplies encoder identity for cluster provenance.
    func embeddingModelIdentity() -> SlimmingVectorModelIdentity?
}

extension SlimmingEmbeddingLoading {
    func embeddingModelIdentity() -> SlimmingVectorModelIdentity? { nil }
}

typealias LibrarySlimmingScanProgressHandler = @Sendable (LibrarySlimmingScanProgress) -> Void

enum LibrarySlimmingAnalyzeMode: String, Sendable, Equatable {
    /// Closed-world scan of all available catalog assets.
    case catalog
    /// Closed-world scan of a caller-resolved filter universe (tag/source/search).
    case currentFilter
    /// Seeds as queries against a search universe (catalog or narrowed).
    case seeds
}

protocol LibrarySlimmingScanPort: Sendable {
    /// Clusters the given assets. Incomplete fingerprints / vectors become pending.
    func scan(
        assetIDs: [UUID],
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws -> LibrarySlimmingScanResult

    /// Scans all current available catalog assets (deterministic UUID order).
    func scanCatalog(onProgress: LibrarySlimmingScanProgressHandler?) throws -> LibrarySlimmingScanResult

    /// Uses `seedAssetIDs` as queries against `universeAssetIDs` (full catalog or narrowed).
    /// Hits are merged with seeds into clusters. Must not reduce to closed-world `scan(seeds)`.
    func scanSeeds(
        seedAssetIDs: [UUID],
        universeAssetIDs: [UUID],
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws -> LibrarySlimmingScanResult
}

extension LibrarySlimmingScanPort {
    func scan(assetIDs: [UUID]) throws -> LibrarySlimmingScanResult {
        try scan(assetIDs: assetIDs, onProgress: nil)
    }

    func scanCatalog() throws -> LibrarySlimmingScanResult {
        try scanCatalog(onProgress: nil)
    }

    func scanSeeds(seedAssetIDs: [UUID], universeAssetIDs: [UUID]) throws -> LibrarySlimmingScanResult {
        try scanSeeds(
            seedAssetIDs: seedAssetIDs,
            universeAssetIDs: universeAssetIDs,
            onProgress: nil
        )
    }
}
