import Foundation

protocol DerivedImageCachePort: Sendable {
    func loadCached(_ request: DerivedImageRequest) async throws -> DerivedImagePayload?
    func loadOrGenerate(_ request: DerivedImageRequest) async throws -> DerivedImagePayload
    func cacheUsage() throws -> DerivedImageCacheUsage
    func clearCache() async throws -> DerivedImageCacheClearResult
    func performMaintenance() async throws -> DerivedImageMaintenanceResult
}

extension DerivedImageCachePort {
    func loadCached(_: DerivedImageRequest) async throws -> DerivedImagePayload? {
        nil
    }
}

protocol DownloadedPreviewCachePort: Sendable {
    func loadDownloadedPreview(assetID: UUID) throws -> Data?
    func storeDownloadedPreview(assetID: UUID, sourceBytes: Data) async throws -> Data
}

protocol PhotoThumbnailCachePort: Sendable {
    func loadPhotoThumbnail(assetID: UUID) throws -> Data?
    func storePhotoThumbnail(assetID: UUID, sourceBytes: Data) async throws -> Data
    func loadPhotoOriginalAspectThumbnail(assetID: UUID) throws -> Data?
    func storePhotoOriginalAspectThumbnail(assetID: UUID, sourceBytes: Data) async throws -> Data
}
