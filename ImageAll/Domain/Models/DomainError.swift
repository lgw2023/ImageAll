import Foundation

enum DomainError: Error, Equatable, Sendable {
    case invalidName
    case duplicateTag
    case invalidStateTransition
    case revisionRegression
    case locatorConflict
    case referenceNotFound
}
