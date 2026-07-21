import Foundation

protocol AssetCatalogQueryPort: Sendable {
    func fetchAssetPage(_ request: AssetPageRequest) throws -> AssetPageResult
    func fetchInspectorDetail(assetID: UUID) throws -> AssetInspectorDetail
    func fetchPhotosCatalogAssetCount(sourceID: UUID) throws -> Int
}
