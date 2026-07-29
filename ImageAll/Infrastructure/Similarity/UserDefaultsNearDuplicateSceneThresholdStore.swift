import Foundation

/// Persists Library Slimming scene-clustering thresholds in UserDefaults.
final class UserDefaultsNearDuplicateSceneThresholdStore: NearDuplicateSceneThresholdWriting,
    @unchecked Sendable
{
    private static let topKKey = "library.slimming.thresholds.v1.featurePrintRecallTopK"
    private static let l2Key = "library.slimming.thresholds.v1.featurePrintMaxL2Distance"
    private static let dinoKey = "library.slimming.thresholds.v1.dinoCosineMinSimilarity"
    private static let bucketKey = "library.slimming.thresholds.v1.sceneBucketActivationAssetCount"
    private static let recallModeKey = "library.slimming.thresholds.v1.featurePrintRecallMode"
    private static let l2ModeKey = "library.slimming.thresholds.v1.featurePrintL2Mode"
    private static let dinoModeKey = "library.slimming.thresholds.v1.dinoCosineMode"
    private static let bucketingModeKey = "library.slimming.thresholds.v1.sceneBucketingMode"

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
        let recallMode = (defaults.string(forKey: Self.recallModeKey))
            .flatMap(FeaturePrintRecallMode.init(rawValue:))
            ?? factory.featurePrintRecallMode
        let l2Mode = (defaults.string(forKey: Self.l2ModeKey))
            .flatMap(FeaturePrintL2Mode.init(rawValue:))
            ?? factory.featurePrintL2Mode
        let dinoMode = (defaults.string(forKey: Self.dinoModeKey))
            .flatMap(DINOCosineMode.init(rawValue:))
            ?? factory.dinoCosineMode
        let bucketingMode = (defaults.string(forKey: Self.bucketingModeKey))
            .flatMap(SceneBucketingMode.init(rawValue:))
            ?? factory.sceneBucketingMode
        return NearDuplicateSceneThresholds(
            featurePrintRecallTopK: topK,
            featurePrintMaxL2Distance: l2,
            dinoCosineMinSimilarity: dino,
            sceneBucketActivationAssetCount: bucket,
            featurePrintRecallMode: recallMode,
            featurePrintL2Mode: l2Mode,
            dinoCosineMode: dinoMode,
            sceneBucketingMode: bucketingMode
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
        defaults.set(value.featurePrintRecallMode.rawValue, forKey: Self.recallModeKey)
        defaults.set(value.featurePrintL2Mode.rawValue, forKey: Self.l2ModeKey)
        defaults.set(value.dinoCosineMode.rawValue, forKey: Self.dinoModeKey)
        defaults.set(value.sceneBucketingMode.rawValue, forKey: Self.bucketingModeKey)
    }

    func resetToFactory() {
        setThresholds(.factory)
    }
}
