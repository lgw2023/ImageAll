import Foundation

enum CatalogDatabaseError: Error, Equatable, Sendable {
    case integrityCheckFailed
    case futureSchema(applied: [String], unknown: [String])
}

enum CatalogRepositoryError: Error, Equatable, Sendable {
    case referenceNotFound
    case sourceLocatorKindMismatch
    case photosFingerprintNotAllowed
}
