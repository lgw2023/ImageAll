import Foundation

protocol AssetCatalogQueryPort: Sendable {
    func fetchAssetPage(_ request: AssetPageRequest) throws -> AssetPageResult
    func fetchSourceFolders(sourceID: UUID) throws -> [LibrarySourceFolder]
    func fetchGalleryOverview() throws -> GalleryOverviewSnapshot
    func fetchInspectorDetail(assetID: UUID) throws -> AssetInspectorDetail
    func fetchPhotosCatalogAssetCount(sourceID: UUID) throws -> Int
}
