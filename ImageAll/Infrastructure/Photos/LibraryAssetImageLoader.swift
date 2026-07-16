import Foundation
import GRDB

struct LibraryAssetImageLoader: Sendable {
    let database: CatalogDatabase
    let fileImages: any DerivedImageCachePort
    let photosImages: any PhotosLibraryAccessPort

    func load(assetID: UUID, variant: PhotosImageVariant) async throws -> Data {
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
