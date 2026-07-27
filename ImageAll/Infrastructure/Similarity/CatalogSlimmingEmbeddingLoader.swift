import CoreGraphics
import Foundation
import ImageIO

/// Loads or generates DINOv2 embeddings for slimming scans, with a per-scan generation budget.
final class CatalogSlimmingEmbeddingLoader: SlimmingEmbeddingLoading, SlimmingBudgetResetting,
    @unchecked Sendable
{
    private let catalogScopeID: UUID
    private let cachesDirectory: URL
    private let inputLoader: any FeaturePrintInputLoading
    private let serviceProvider: @Sendable () -> AppCoreMLEmbeddingService?
    private let lock = NSLock()
    private var generationBudget = 0
    private var generationsUsed = 0

    init(
        catalogScopeID: UUID,
        cachesDirectory: URL,
        inputLoader: any FeaturePrintInputLoading,
        serviceProvider: @escaping @Sendable () -> AppCoreMLEmbeddingService?,
        generationBudget: Int = 0
    ) {
        self.catalogScopeID = catalogScopeID
        self.cachesDirectory = cachesDirectory
        self.inputLoader = inputLoader
        self.serviceProvider = serviceProvider
        self.generationBudget = max(0, generationBudget)
    }

    func resetScanBudgets(forAssetCount assetCount: Int) {
        let budgets = SlimmingScanBudgetPolicy.budgets(forAssetCount: assetCount)
        lock.lock()
        generationBudget = budgets.embeddingGenerations
        generationsUsed = 0
        lock.unlock()
    }

    func embeddingModelIdentity() -> SlimmingVectorModelIdentity? {
        guard let service = serviceProvider(),
              case let .ready(identity) = service.availability
        else {
            return nil
        }
        return SlimmingVectorModelIdentity(
            featurePrintProvider: PersonalizationConstants.provider,
            featurePrintRequestRevision: PersonalizationConstants.requestRevision,
            featurePrintPreprocessingRevision: PersonalizationConstants.preprocessingRevision,
            embeddingProvider: identity.provider,
            embeddingModelID: identity.modelID,
            embeddingModelRevision: identity.modelRevision,
            embeddingPreprocessingRevision: identity.preprocessingRevision,
            perceptualAlgoVersion: nil,
            policyVersion: NearDuplicateScenePolicy.policyVersion
        )
    }

    func embedding(assetID: UUID) throws -> [Float]? {
        guard let service = serviceProvider(), case .ready = service.availability else {
            return nil
        }
        let identity: FeatureIdentity
        do {
            identity = try inputLoader.resolveIdentity(assetID: assetID)
        } catch {
            return nil
        }
        let key = AppCoreMLEmbeddingCacheKey(
            catalogScopeID: catalogScopeID,
            assetID: assetID,
            contentRevision: Int64(identity.contentRevision)
        )
        let cache = AppCoreMLEmbeddingCache(
            cachesDirectory: cachesDirectory,
            service: service
        )
        if let hit = try? cache.cachedEmbedding(for: key) {
            return hit.values
        }

        lock.lock()
        let allowed = generationsUsed < generationBudget
        if allowed { generationsUsed += 1 }
        lock.unlock()
        guard allowed else { return nil }

        do {
            let input = try inputLoader.loadInput(assetID: assetID, expectedIdentity: identity)
            guard let image = Self.makeCGImage(from: input.sourceBytes) else { return nil }
            guard try inputLoader.isCurrent(input) else { return nil }
            let cached = try cache.embedding(for: image, key: key)
            return cached.values
        } catch {
            return nil
        }
    }

    private static func makeCGImage(from sourceBytes: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(sourceBytes as CFData, nil),
              CGImageSourceGetCount(source) >= 1
        else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 518,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
