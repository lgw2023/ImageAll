import Foundation

enum PhotosAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

enum PhotosImageVariant: Equatable, Hashable, Sendable {
    case grid
    case originalAspectThumbnail
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
    let mediaKind: MediaKind
    let durationMs: Int64?
    let location: AssetLocationCoordinate?

    init(
        localIdentifier: String,
        fileName: String?,
        mediaType: String,
        width: Int,
        height: Int,
        createdAtMs: Int64?,
        modifiedAtMs: Int64?,
        mediaKind: MediaKind = .image,
        durationMs: Int64? = nil,
        location: AssetLocationCoordinate? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.fileName = fileName
        self.mediaType = mediaType
        self.width = width
        self.height = height
        self.createdAtMs = createdAtMs
        self.modifiedAtMs = modifiedAtMs
        self.mediaKind = mediaKind
        self.durationMs = durationMs
        self.location = location
    }
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
    func supportedStaticImageCount() throws -> Int
    func enumerateStaticImages(
        startingAt startOffset: Int,
        batchSize: Int,
        onAssetEnumerated: () throws -> Void,
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

/// Original encoded still bytes for durable exact analysis. A user-started
/// Library Slimming scan may let PhotoKit materialize an iCloud-backed original.
protocol PhotosOriginalContentPort: Sendable {
    func requestOriginalImageData(localIdentifier: String) throws -> Data
}

struct PhotosOriginalStorageUsage: Equatable, Sendable {
    let entryCount: Int
    let registeredBytes: Int64

    static let zero = PhotosOriginalStorageUsage(entryCount: 0, registeredBytes: 0)
}

struct PhotosOriginalStorageClearResult: Equatable, Sendable {
    let removedEntries: Int
    let removedBytes: Int64
    let partialReclaim: Bool
}

protocol PhotosFeaturePrintImagePort: Sendable {
    func requestLocalFeatureImage(localIdentifier: String) throws -> Data
}

/// Public PhotoKit visibility of a Photos asset.
///
/// Production PhotoKit can only distinguish an asset that is available in the
/// library from one that is no longer returned. `recentlyDeleted` is retained
/// for deterministic service tests and non-PhotoKit adapters.
enum PhotosAssetPresence: Equatable, Sendable {
    case available
    case recentlyDeleted
    case missing
}

enum PhotosLibraryMutationFailureCategory: String, Equatable, Sendable {
    case userCancelled
    case authorization
    case libraryUnavailable
    case unsupported
    case system
}

struct PhotosLibraryMutationFailureDiagnostic: Equatable, Sendable {
    let category: PhotosLibraryMutationFailureCategory
    let domain: String
    let code: Int

    var persistenceCode: String {
        let sanitizedDomain = String(domain.map { character in
            character.isLetter || character.isNumber || ".-_".contains(character)
                ? character
                : "-"
        }.prefix(96))
        let stableDomain = sanitizedDomain.isEmpty ? "unknown" : sanitizedDomain
        return "photosMutationFailed.\(category.rawValue).\(stableDomain).\(code)"
    }

    var displayCode: String {
        "\(domain.isEmpty ? "unknown" : domain)#\(code)"
    }
}

enum PhotosLibraryMutationError: Error, Equatable, Sendable {
    case authorizationDenied
    case authorizationRestricted
    case notDetermined
    case assetNotFound
    case changeFailed
    case systemChangeFailed(PhotosLibraryMutationFailureDiagnostic)
}

/// Sole application contract for PhotoKit write operations used by Library Slimming.
/// Production implementations must live in the dedicated Photos mutation adapter.
protocol PhotosLibraryMutationPort: Sendable {
    func authorizationState() -> PhotosAuthorizationState
    func requestAuthorization() async -> PhotosAuthorizationState
    /// Returns the exact normalized identifiers included in the completed
    /// PhotoKit mutation. Partial resolution must fail before mutation.
    func moveToRecentlyDeleted(localIdentifiers: [String]) throws -> [String]
    func presence(localIdentifier: String) throws -> PhotosAssetPresence
    func presences(
        localIdentifiers: [String]
    ) throws -> [String: PhotosAssetPresence]
}

extension PhotosLibraryMutationPort {
    func presences(
        localIdentifiers: [String]
    ) throws -> [String: PhotosAssetPresence] {
        var facts: [String: PhotosAssetPresence] = [:]
        for localIdentifier in localIdentifiers {
            let identifier = localIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty, facts[identifier] == nil else { continue }
            facts[identifier] = try presence(localIdentifier: identifier)
        }
        return facts
    }
}
