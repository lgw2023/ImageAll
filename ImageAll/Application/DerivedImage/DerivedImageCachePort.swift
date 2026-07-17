import Foundation

protocol DerivedImageCachePort: Sendable {
    func loadOrGenerate(_ request: DerivedImageRequest) async throws -> DerivedImagePayload
    func cacheUsage() throws -> DerivedImageCacheUsage
    func clearCache() async throws -> DerivedImageCacheClearResult
    func performMaintenance() async throws -> DerivedImageMaintenanceResult
}

protocol DownloadedPreviewCachePort: Sendable {
    func loadDownloadedPreview(assetID: UUID) throws -> Data?
    func storeDownloadedPreview(assetID: UUID, sourceBytes: Data) async throws -> Data
}

protocol PhotoThumbnailCachePort: Sendable {
    func loadPhotoThumbnail(assetID: UUID) throws -> Data?
    func storePhotoThumbnail(assetID: UUID, sourceBytes: Data) async throws -> Data
}
