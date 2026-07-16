import Foundation
import GRDB

struct LibraryAssetImageLoader: Sendable {
    let database: CatalogDatabase
    let fileImages: any DerivedImageCachePort
    let photosImages: any PhotosLibraryAccessPort
    let cloudPreviews: (any PhotosCloudPreviewPort)?
    let downloadedPreviews: (any DownloadedPreviewCachePort)?
    private let loadCoordinator: LibraryAssetImageLoadCoordinator

    init(
        database: CatalogDatabase,
        fileImages: any DerivedImageCachePort,
        photosImages: any PhotosLibraryAccessPort,
        cloudPreviews: (any PhotosCloudPreviewPort)? = nil,
        downloadedPreviews: (any DownloadedPreviewCachePort)? = nil,
        maximumConcurrentLoads: Int = 4
    ) {
        self.database = database
        self.fileImages = fileImages
        self.photosImages = photosImages
        self.cloudPreviews = cloudPreviews
        self.downloadedPreviews = downloadedPreviews
        loadCoordinator = LibraryAssetImageLoadCoordinator(
            maximumConcurrentLoads: maximumConcurrentLoads
        )
    }

    func load(assetID: UUID, variant: PhotosImageVariant) async throws -> Data {
        try await loadCoordinator.run { [self] in
            try await loadWithoutConcurrencyLimit(assetID: assetID, variant: variant)
        }
    }

    func downloadCloudPreview(
        assetID: UUID,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        try await loadCoordinator.run { [self] in
            guard let cloudPreviews, let downloadedPreviews else {
                throw PhotosLibraryError.libraryUnavailable
            }
            let locator = try await locator(assetID: assetID)
            guard locator.kind == AssetLocatorKind.photos.rawValue,
                  let identifier = locator.identifier
            else {
                throw PhotosLibraryError.libraryUnavailable
            }
            let sourceBytes = try await cloudPreviews.requestCloudPreview(
                localIdentifier: identifier,
                grant: .issue(),
                onProgress: onProgress
            )
            return try await downloadedPreviews.storeDownloadedPreview(
                assetID: assetID,
                sourceBytes: sourceBytes
            )
        }
    }

    private func loadWithoutConcurrencyLimit(
        assetID: UUID,
        variant: PhotosImageVariant
    ) async throws -> Data {
        let locator = try await locator(assetID: assetID)

        if locator.kind == AssetLocatorKind.photos.rawValue {
            guard let identifier = locator.identifier else {
                throw PhotosLibraryError.libraryUnavailable
            }
            if variant == .preview,
               let downloadedPreviews,
               let cached = try downloadedPreviews.loadDownloadedPreview(assetID: assetID)
            {
                return cached
            }
            return try await photosImages.requestLocalImage(
                localIdentifier: identifier,
                variant: variant
            )
        }

        let derivedVariant: DerivedImageVariant = switch variant {
        case .grid: .gridRegular
        case .preview: .preview
        }
        return try await fileImages.loadOrGenerate(
            DerivedImageRequest(
                assetID: assetID,
                variant: derivedVariant,
                persistence: .memoryFallbackAllowed
            )
        ).encodedBytes
    }

    private func locator(assetID: UUID) async throws -> (kind: String, identifier: String?) {
        try await database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT locator_kind, photos_local_identifier
                FROM asset WHERE id = ? AND locator_state = 'current'
                """,
                arguments: [assetID.uuidString.lowercased()]
            ) else {
                throw PhotosLibraryError.libraryUnavailable
            }
            return (row["locator_kind"], row["photos_local_identifier"])
        }
    }
}

private actor LibraryAssetImageLoadCoordinator {
    private let maximumConcurrentLoads: Int
    private var activeLoads = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maximumConcurrentLoads: Int) {
        precondition(maximumConcurrentLoads > 0)
        self.maximumConcurrentLoads = maximumConcurrentLoads
    }

    func run<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async {
        if activeLoads < maximumConcurrentLoads {
            activeLoads += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            activeLoads -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
