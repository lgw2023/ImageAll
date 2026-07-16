import Foundation

protocol DerivedImageCachePort: Sendable {
    func loadOrGenerate(_ request: DerivedImageRequest) async throws -> DerivedImagePayload
    func performMaintenance() async throws -> DerivedImageMaintenanceResult
}

protocol DownloadedPreviewCachePort: Sendable {
    func loadDownloadedPreview(assetID: UUID) async throws -> Data?
    func storeDownloadedPreview(assetID: UUID, sourceBytes: Data) async throws -> Data
}
