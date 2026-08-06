import Foundation

/// Narrow catalog surface for the auxiliary remote host. Keeps remote code off the full
/// `LibraryWorkspacePort` and away from UI state machines.
protocol RemoteCatalogServing: Sendable {
    func fetchSources() throws -> [LibrarySourceSummary]
    func listTags() throws -> [TagListItem]
    func listTagsIncludingArchived() throws -> [TagListItem]
    func listTagGroups() throws -> [TagGroupListItem]
    func installPresetTags() throws -> TagPresetInstallResult
    func fetchGalleryOverview() throws -> GalleryOverviewSnapshot
    func fetchAssetPage(
        filter: AssetPageFilter,
        sort: AssetPageSort,
        cursor: AssetPageCursor?,
        limit: Int
    ) throws -> AssetPageResult
    func loadThumbnail(assetID: UUID) async throws -> Data
    func loadPreview(assetID: UUID) async throws -> Data
    func downloadCloudPreview(
        assetID: UUID,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data
    func fetchInspectorDetail(assetID: UUID) throws -> AssetInspectorDetail
    func selectionAggregate(tagIDs: [UUID], assetIDs: [UUID]) throws -> [TagSelectionAggregate]
    func mutateTag(
        tagID: UUID,
        assetIDs: [UUID],
        action: LibraryTagDecisionAction
    ) throws -> TagMutationPriorStateSnapshot
    func createTagAndAccept(rawName: String, assetIDs: [UUID]) throws -> TagCreateAndApplyResult
    func restoreTagMutation(_ snapshot: TagMutationPriorStateSnapshot) throws
    func renameTag(tagID: UUID, rawName: String) throws -> TagListItem
    func archiveTag(tagID: UUID) throws
    func moveTag(tagID: UUID, toGroupID: UUID) throws -> TagListItem
    func createTagGroup(rawName: String) throws -> TagGroupListItem
    func renameTagGroup(groupID: UUID, rawName: String) throws -> TagGroupListItem
    func deleteTagGroup(groupID: UUID) throws
    func fetchJobActivity() throws -> [JobActivityItem]
    func applyJobActivityAction(_ action: JobActivityAction, jobID: UUID) throws
    func fetchWorldMapSnapshot(query: WorldMapCatalogQuery) throws -> WorldMapCatalogSnapshot
    func fetchWorldMapSelection(
        query: WorldMapCatalogSelectionQuery
    ) throws -> WorldMapCatalogSelection
    func fetchWorldMapLocationBackfillSnapshots() throws
        -> [WorldMapLocationBackfillSnapshot]
    func startWorldMapLocationBackfill(sourceID: UUID) throws
    func cancelWorldMapLocationBackfill(sourceID: UUID) throws
    func runPendingWorldMapLocationBackfill(sourceID: UUID, sourceKind: SourceKind) throws
    func fetchWorldMapPlaceTagResolutions() throws -> [WorldMapPlaceTagResolution]
    func searchWorldMapPlaceTag(
        tagID: UUID,
        query: String
    ) async throws -> WorldMapPlaceTagResolution
    func confirmWorldMapPlaceCandidate(
        tagID: UUID,
        placeID: String
    ) throws -> WorldMapPlaceTagResolution
}

extension RemoteCatalogServing {
    func downloadCloudPreview(
        assetID _: UUID,
        onProgress _: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        throw PhotosLibraryError.libraryUnavailable
    }

    func listTagsIncludingArchived() throws -> [TagListItem] { try listTags() }

    func listTagGroups() throws -> [TagGroupListItem] { [] }

    func installPresetTags() throws -> TagPresetInstallResult {
        TagPresetInstallResult(createdTags: [])
    }

    func fetchGalleryOverview() throws -> GalleryOverviewSnapshot { .empty }

    func restoreTagMutation(_: TagMutationPriorStateSnapshot) throws {
        throw CatalogQueryError.notFound
    }

    func renameTag(tagID _: UUID, rawName _: String) throws -> TagListItem {
        throw CatalogQueryError.notFound
    }

    func archiveTag(tagID _: UUID) throws {
        throw CatalogQueryError.notFound
    }

    func moveTag(tagID _: UUID, toGroupID _: UUID) throws -> TagListItem {
        throw CatalogQueryError.notFound
    }

    func createTagGroup(rawName _: String) throws -> TagGroupListItem {
        throw CatalogQueryError.notFound
    }

    func renameTagGroup(groupID _: UUID, rawName _: String) throws -> TagGroupListItem {
        throw CatalogQueryError.notFound
    }

    func deleteTagGroup(groupID _: UUID) throws {
        throw CatalogQueryError.notFound
    }

    func fetchWorldMapSnapshot(query _: WorldMapCatalogQuery) throws -> WorldMapCatalogSnapshot {
        .empty
    }

    func fetchWorldMapSelection(
        query _: WorldMapCatalogSelectionQuery
    ) throws -> WorldMapCatalogSelection {
        .empty
    }

    func fetchWorldMapLocationBackfillSnapshots() throws
        -> [WorldMapLocationBackfillSnapshot]
    {
        []
    }

    func startWorldMapLocationBackfill(sourceID _: UUID) throws {
        throw CatalogQueryError.notFound
    }

    func cancelWorldMapLocationBackfill(sourceID _: UUID) throws {
        throw CatalogQueryError.notFound
    }

    func runPendingWorldMapLocationBackfill(sourceID _: UUID, sourceKind _: SourceKind) throws {}

    func fetchWorldMapPlaceTagResolutions() throws -> [WorldMapPlaceTagResolution] { [] }

    func searchWorldMapPlaceTag(
        tagID _: UUID,
        query _: String
    ) async throws -> WorldMapPlaceTagResolution {
        throw CatalogQueryError.notFound
    }

    func confirmWorldMapPlaceCandidate(
        tagID _: UUID,
        placeID _: String
    ) throws -> WorldMapPlaceTagResolution {
        throw CatalogQueryError.notFound
    }
}
