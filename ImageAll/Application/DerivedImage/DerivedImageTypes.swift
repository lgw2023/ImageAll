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
    case memoryOnly
}

enum DerivedImagePersistence: Hashable, Sendable {
    case required
    case memoryFallbackAllowed
}

struct DerivedImageRequest: Equatable, Sendable {
    let assetID: UUID
    let variant: DerivedImageVariant
    let persistence: DerivedImagePersistence

    init(
        assetID: UUID,
        variant: DerivedImageVariant,
        persistence: DerivedImagePersistence = .required
    ) {
        self.assetID = assetID
        self.variant = variant
        self.persistence = persistence
    }
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

struct DerivedImageCacheUsage: Equatable, Sendable {
    let entryCount: Int
    let registeredBytes: UInt64

    static let zero = DerivedImageCacheUsage(entryCount: 0, registeredBytes: 0)
}

struct DerivedImageCacheClearResult: Equatable, Sendable {
    let removedEntries: Int
    let registeredBytesInvalidated: UInt64
    let removedObjects: Int
    let removedBytes: UInt64
    let partialReclaim: Bool
}

enum DerivedImageRepresentationVersion {
    static let production = 1
}
