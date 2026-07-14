import Foundation

protocol TagCatalogQueryPort: Sendable {
    func listTags(includeArchived: Bool) throws -> [TagListItem]
    func selectionAggregate(tagIDs: [UUID], assetIDs: [UUID]) throws -> [TagSelectionAggregate]
}
