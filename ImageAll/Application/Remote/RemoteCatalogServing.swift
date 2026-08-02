import Foundation

/// Narrow catalog surface for the auxiliary remote host. Keeps remote code off the full
/// `LibraryWorkspacePort` and away from UI state machines.
protocol RemoteCatalogServing: Sendable {
    func fetchSources() throws -> [LibrarySourceSummary]
    func listTags() throws -> [TagListItem]
    func listTagGroups() throws -> [TagGroupListItem]
    func fetchAssetPage(
        filter: AssetPageFilter,
        sort: AssetPageSort,
        cursor: AssetPageCursor?,
        limit: Int
    ) throws -> AssetPageResult
    func loadThumbnail(assetID: UUID) async throws -> Data
    func loadPreview(assetID: UUID) async throws -> Data
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
}

extension RemoteCatalogServing {
    func listTagGroups() throws -> [TagGroupListItem] { [] }

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
}
