import Foundation

/// Narrow catalog surface for the auxiliary remote host. Keeps remote code off the full
/// `LibraryWorkspacePort` and away from UI state machines.
protocol RemoteCatalogServing: Sendable {
    func fetchSources() throws -> [LibrarySourceSummary]
    func fetchAssetPage(
        filter: AssetPageFilter,
        sort: AssetPageSort,
        cursor: AssetPageCursor?,
        limit: Int
    ) throws -> AssetPageResult
    func loadThumbnail(assetID: UUID) async throws -> Data
    func mutateTag(
        tagID: UUID,
        assetIDs: [UUID],
        action: LibraryTagDecisionAction
    ) throws -> TagMutationPriorStateSnapshot
}
