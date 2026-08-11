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

    func cacheSelectedAssets(
        _ requests: [AppSelectedAssetEmbeddingRequest]
    ) async throws -> [AppCoreMLCachedEmbedding?]
}

struct AppSelectedAssetEmbeddingRequest: Sendable {
    let assetID: UUID
    let contentRevision: Int
    let imageData: @Sendable () async throws -> Data

    init(
        assetID: UUID,
        contentRevision: Int,
        imageData: @escaping @Sendable () async throws -> Data
    ) {
        self.assetID = assetID
        self.contentRevision = contentRevision
        self.imageData = imageData
    }
}

extension AppSelectedAssetEmbeddingCaching {
    func cacheSelectedAssets(
        _ requests: [AppSelectedAssetEmbeddingRequest]
    ) async throws -> [AppCoreMLCachedEmbedding?] {
        var results: [AppCoreMLCachedEmbedding?] = []
        results.reserveCapacity(requests.count)
        for request in requests {
            try Task.checkCancellation()
            do {
                results.append(
                    try await cacheSelectedAsset(
                        assetID: request.assetID,
                        contentRevision: request.contentRevision,
                        imageData: request.imageData
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                results.append(nil)
            }
        }
        return results
    }
}
