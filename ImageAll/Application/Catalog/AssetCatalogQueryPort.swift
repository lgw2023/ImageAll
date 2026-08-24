import Foundation

protocol AssetCatalogQueryPort: Sendable {
    func fetchAssetPage(_ request: AssetPageRequest) throws -> AssetPageResult
    func fetchSourceFolders(sourceID: UUID) throws -> [LibrarySourceFolder]
    func fetchSourceFolderPage(
        sourceID: UUID,
        parentRelativePath: String?,
        offset: Int,
        limit: Int
    ) throws -> LibrarySourceFolderPage
    func sourceFolderExists(_ scope: AssetFolderScope) throws -> Bool
    func searchSourceFolders(
        sourceID: UUID,
        text: String,
        limit: Int
    ) throws -> LibrarySourceFolderPage
    func fetchGalleryOverview() throws -> GalleryOverviewSnapshot
    func fetchInspectorDetail(assetID: UUID) throws -> AssetInspectorDetail
    func fetchPhotosCatalogAssetCount(sourceID: UUID) throws -> Int
}
