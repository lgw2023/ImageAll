import Foundation

enum CatalogQueryError: Error, Equatable, Sendable {
    case invalidPageLimit
    case cursorSortMismatch
    case notFound
    case emptySelection
    case selectionTooLarge
    case archivedTag
    case duplicateTag
    case invalidTagName
    case persistenceFailure
    case systemGroupProtected
}
