import Foundation

enum AppModelActivationState: Equatable, Sendable {
    case disabled
    case validating
    case ready(AppCoreMLModelIdentity)
    case unavailable(AppCoreMLModelFailure)
}

protocol ModelEnablementPreferenceStore: Sendable {
    var isEnabled: Bool { get set }
}

enum AppSelectedAssetEmbeddingCacheError: Error, Equatable {
    case modelUnavailable
    case invalidAsset
    case invalidImage
    case persistenceFailed
}

protocol AppSelectedAssetEmbeddingCaching: Sendable {
    func cacheSelectedAsset(
        assetID: UUID,
        contentRevision: Int,
        imageData: @escaping @Sendable () async throws -> Data
    ) async throws -> AppCoreMLCachedEmbedding
}
