import Foundation

/// Persists Library Slimming scene-clustering thresholds in UserDefaults.
final class UserDefaultsNearDuplicateSceneThresholdStore: NearDuplicateSceneThresholdWriting,
    @unchecked Sendable
{
    private static let topKKey = "library.slimming.thresholds.v1.featurePrintRecallTopK"
    private static let l2Key = "library.slimming.thresholds.v1.featurePrintMaxL2Distance"
    private static let dinoKey = "library.slimming.thresholds.v1.dinoCosineMinSimilarity"
    private static let bucketKey = "library.slimming.thresholds.v1.sceneBucketActivationAssetCount"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func thresholds() -> NearDuplicateSceneThresholds {
        lock.lock()
        defer { lock.unlock() }
        let factory = NearDuplicateSceneThresholds.factory
        let topK = defaults.object(forKey: Self.topKKey) as? Int
            ?? factory.featurePrintRecallTopK
        let l2 = defaults.object(forKey: Self.l2Key) as? Double
            ?? factory.featurePrintMaxL2Distance
        let dino = defaults.object(forKey: Self.dinoKey) as? Double
            ?? factory.dinoCosineMinSimilarity
        let bucket = defaults.object(forKey: Self.bucketKey) as? Int
            ?? factory.sceneBucketActivationAssetCount
        return NearDuplicateSceneThresholds(
            featurePrintRecallTopK: topK,
            featurePrintMaxL2Distance: l2,
            dinoCosineMinSimilarity: dino,
            sceneBucketActivationAssetCount: bucket
        ).clamped()
    }

    func setThresholds(_ thresholds: NearDuplicateSceneThresholds) {
        let value = thresholds.clamped()
        lock.lock()
        defer { lock.unlock() }
        defaults.set(value.featurePrintRecallTopK, forKey: Self.topKKey)
        defaults.set(value.featurePrintMaxL2Distance, forKey: Self.l2Key)
        defaults.set(value.dinoCosineMinSimilarity, forKey: Self.dinoKey)
        defaults.set(value.sceneBucketActivationAssetCount, forKey: Self.bucketKey)
    }

    func resetToFactory() {
        setThresholds(.factory)
    }
}
