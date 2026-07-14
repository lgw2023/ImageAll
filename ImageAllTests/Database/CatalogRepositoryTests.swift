import GRDB
import XCTest
@testable import ImageAll

final class CatalogRepositoryTests: XCTestCase {
    func testFolderSourceWithPhotosLocatorIsRejected() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)

        XCTAssertThrowsError(
            try repository.createSourceWithAsset(
                NewSourceWithAssetInput(
                    sourceID: UUID(),
                    sourceKind: .folder,
                    displayName: "Folder",
                    bookmark: DatabaseTestSupport.folderBookmark(),
                    assetID: UUID(),
                    locatorKind: .photos,
                    relativePath: nil,
                    photosLocalIdentifier: "photo-1",
                    mediaType: "public.heic",
                    timestampMs: DatabaseTestSupport.timestampMs
                )
            )
        ) { error in
            XCTAssertEqual(error as? CatalogRepositoryError, .sourceLocatorKindMismatch)
        }
    }

    func testPhotosSourceWithFileLocatorIsRejected() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)

        XCTAssertThrowsError(
            try repository.createSourceWithAsset(
                NewSourceWithAssetInput(
                    sourceID: UUID(),
                    sourceKind: .photos,
                    displayName: "Library",
                    bookmark: nil,
                    assetID: UUID(),
                    locatorKind: .file,
                    relativePath: "album/photo.jpg",
                    photosLocalIdentifier: nil,
                    mediaType: "public.jpeg",
                    timestampMs: DatabaseTestSupport.timestampMs
                )
            )
        ) { error in
            XCTAssertEqual(error as? CatalogRepositoryError, .sourceLocatorKindMismatch)
        }
    }

    func testPhotosAssetFingerprintWriteIsRejected() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let assetID = UUID()
        try DatabaseTestSupport.makePhotosSourceWithPhotosAsset(repository: repository, assetID: assetID)

        XCTAssertThrowsError(
            try repository.upsertFileFingerprint(
                FileFingerprintInput(
                    assetID: assetID,
                    sizeBytes: 10,
                    modifiedAtNs: 20,
                    resourceID: nil,
                    sha256: Data(repeating: 0x01, count: 32)
                )
            )
        ) { error in
            XCTAssertEqual(error as? CatalogRepositoryError, .photosFingerprintNotAllowed)
        }
    }

    func testMultiStepWriteRollsBackWhenLaterValidationFails() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let sourceID = UUID()

        XCTAssertThrowsError(
            try repository.createSourceWithAsset(
                NewSourceWithAssetInput(
                    sourceID: sourceID,
                    sourceKind: .folder,
                    displayName: "Folder",
                    bookmark: DatabaseTestSupport.folderBookmark(),
                    assetID: UUID(),
                    locatorKind: .photos,
                    relativePath: nil,
                    photosLocalIdentifier: "photo-1",
                    mediaType: "public.heic",
                    timestampMs: DatabaseTestSupport.timestampMs
                )
            )
        )

        let sourceCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") ?? 0
        }
        let assetCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0
        }
        XCTAssertEqual(sourceCount, 0)
        XCTAssertEqual(assetCount, 0)
    }

    func testValidFolderFileWritePersistsSourceAndAsset() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let sourceID = UUID()
        let assetID = UUID()

        try DatabaseTestSupport.makeFolderSourceWithFileAsset(
            repository: repository,
            sourceID: sourceID,
            assetID: assetID
        )

        try repository.upsertFileFingerprint(
            FileFingerprintInput(
                assetID: assetID,
                sizeBytes: 42,
                modifiedAtNs: 99,
                resourceID: Data([0x10]),
                sha256: Data(repeating: 0xCD, count: 32)
            )
        )

        let fingerprintCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file_fingerprint") ?? 0
        }
        XCTAssertEqual(fingerprintCount, 1)
    }
}
