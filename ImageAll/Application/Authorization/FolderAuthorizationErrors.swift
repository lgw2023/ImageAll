import Foundation

enum FolderAuthorizationError: Error, Equatable, Sendable {
    case sourceNotFound
    case sourceKindMismatch
    case invalidSourceState
    case invalidRoot
    case sourceOverlap
    case overlapIndeterminate
    case identityMismatch
    case identityIndeterminate
    case bookmarkCreationFailed
    case authorizationUnavailable
    case persistenceFailure
}
