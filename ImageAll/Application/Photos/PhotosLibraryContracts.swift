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

struct PhotosAssetEnumerationBatch: Equatable, Sendable {
    let assets: [PhotosAssetMetadata]
    let completedCount: Int
    let totalCount: Int
}

struct PhotosPersistentChangeBatch: Equatable, Sendable {
    let upsertedAssets: [PhotosAssetMetadata]
    let deletedLocalIdentifiers: [String]
    let changeToken: Data
}

struct PhotosCloudDownloadGrant: Equatable, Sendable {
    private let scopeID: UUID

    static func issue() -> PhotosCloudDownloadGrant {
        PhotosCloudDownloadGrant(scopeID: UUID())
    }
}

enum PhotosLibraryError: Error, Equatable, Sendable {
    case authorizationDenied
    case authorizationRestricted
    case libraryUnavailable
    case cloudOnly
    case changeTokenInvalid
    case persistenceFailure
}

protocol PhotosLibraryAccessPort: Sendable {
    func authorizationState() -> PhotosAuthorizationState
    func requestAuthorization() async -> PhotosAuthorizationState
    func enumerateStaticImages(
        startingAt startOffset: Int,
        batchSize: Int,
        onBatch: (PhotosAssetEnumerationBatch) throws -> Void
    ) throws
    func requestLocalImage(
        localIdentifier: String,
        variant: PhotosImageVariant
    ) async throws -> Data
}

protocol PhotosChangeHistoryPort: Sendable {
    func currentChangeToken() throws -> Data
    func enumeratePersistentChanges(
        since changeToken: Data,
        onBatch: (PhotosPersistentChangeBatch) throws -> Void
    ) throws
}

protocol PhotosChangeObserverPort: Sendable {
    func startObservingChanges(_ onChange: @escaping @Sendable () -> Void)
    func stopObservingChanges()
}

enum PhotosLibraryUnavailabilityReason: Equatable, Sendable {
    case systemLibrarySwitch
    case other
}

protocol PhotosLibraryAvailabilityObserverPort: Sendable {
    func startObservingAvailability(
        _ onUnavailable: @escaping @Sendable (PhotosLibraryUnavailabilityReason) -> Void
    )
    func stopObservingAvailability()
}

protocol PhotosCloudPreviewPort: Sendable {
    func requestCloudPreview(
        localIdentifier: String,
        grant: PhotosCloudDownloadGrant,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data
}

protocol PhotosFeaturePrintImagePort: Sendable {
    func requestLocalFeatureImage(localIdentifier: String) throws -> Data
}
