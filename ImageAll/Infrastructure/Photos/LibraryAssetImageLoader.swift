import Foundation
import GRDB

struct LibraryAssetImageLoader: Sendable {
    let database: CatalogDatabase
    let fileImages: any DerivedImageCachePort
    let photosImages: any PhotosLibraryAccessPort
    private let loadCoordinator: LibraryAssetImageLoadCoordinator

    init(
        database: CatalogDatabase,
        fileImages: any DerivedImageCachePort,
        photosImages: any PhotosLibraryAccessPort,
        maximumConcurrentLoads: Int = 4
    ) {
        self.database = database
        self.fileImages = fileImages
        self.photosImages = photosImages
        loadCoordinator = LibraryAssetImageLoadCoordinator(
            maximumConcurrentLoads: maximumConcurrentLoads
        )
    }

    func load(assetID: UUID, variant: PhotosImageVariant) async throws -> Data {
        try await loadCoordinator.run { [self] in
            try await loadWithoutConcurrencyLimit(assetID: assetID, variant: variant)
        }
    }

    private func loadWithoutConcurrencyLimit(
        assetID: UUID,
        variant: PhotosImageVariant
    ) async throws -> Data {
        let locator = try await database.pool.read { db -> (kind: String, identifier: String?) in
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

        if locator.kind == AssetLocatorKind.photos.rawValue {
            guard let identifier = locator.identifier else {
                throw PhotosLibraryError.libraryUnavailable
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
