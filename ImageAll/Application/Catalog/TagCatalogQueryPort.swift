import Foundation

protocol TagCatalogQueryPort: Sendable {
    func listTags(includeArchived: Bool) throws -> [TagListItem]
    func listTagGroups() throws -> [TagGroupListItem]
    func selectionAggregate(tagIDs: [UUID], assetIDs: [UUID]) throws -> [TagSelectionAggregate]
}

protocol StandardOntologyCatalogPort: Sendable {
    func installStandardOntologyPackage(
        _ package: StandardOntologyPackageInput,
        timestampMs: Int64
    ) throws -> StandardOntologyInstallResult
}
