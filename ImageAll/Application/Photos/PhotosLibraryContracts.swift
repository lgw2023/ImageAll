import Foundation

enum PhotosAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

enum PhotosImageVariant: Equatable, Sendable {
    case grid
    case preview
}

struct PhotosAssetMetadata: Equatable, Sendable {
    let localIdentifier: String
    let fileName: String?
    let mediaType: String
    let width: Int
    let height: Int
    let createdAtMs: Int64?
    let modifiedAtMs: Int64?
}

enum PhotosLibraryError: Error, Equatable, Sendable {
    case authorizationDenied
    case authorizationRestricted
    case libraryUnavailable
    case cloudOnly
    case persistenceFailure
}

protocol PhotosLibraryAccessPort: Sendable {
    func authorizationState() -> PhotosAuthorizationState
    func requestAuthorization() async -> PhotosAuthorizationState
    func enumerateStaticImages(
        batchSize: Int,
        onBatch: ([PhotosAssetMetadata]) throws -> Void
    ) throws
    func requestLocalImage(
        localIdentifier: String,
        variant: PhotosImageVariant
    ) async throws -> Data
}
