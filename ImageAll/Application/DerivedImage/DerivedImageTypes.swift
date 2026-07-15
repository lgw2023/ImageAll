import Foundation

enum DerivedImageVariant: String, Equatable, Sendable, CaseIterable {
    case gridSmall
    case gridRegular
    case preview
}

enum DerivedImageStorageFormat: String, Equatable, Sendable {
    case jpeg
    case png
}

enum DerivedImageOrigin: String, Equatable, Sendable {
    case cacheHit
    case generated
}

struct DerivedImageRequest: Equatable, Sendable {
    let assetID: UUID
    let variant: DerivedImageVariant
}

struct DerivedImagePayload: Equatable, Sendable {
    let entryID: UUID
    let assetID: UUID
    let contentRevision: Int
    let representationVersion: Int
    let variant: DerivedImageVariant
    let storageFormat: DerivedImageStorageFormat
    let pixelWidth: Int
    let pixelHeight: Int
    let encodedBytes: Data
    let origin: DerivedImageOrigin
}

struct DerivedImageMaintenanceResult: Equatable, Sendable {
    let removedEntries: Int
    let removedObjects: Int
    let removedBytes: UInt64
    let unsafeObjects: Int
}

enum DerivedImageRepresentationVersion {
    static let production = 1
}
