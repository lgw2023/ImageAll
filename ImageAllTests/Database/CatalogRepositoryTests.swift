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
        ) { error in
            XCTAssertEqual(error as? CatalogRepositoryError, .sourceLocatorKindMismatch)
        }

        let sourceCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") ?? 0
        }
        let assetCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0
        }
        XCTAssertEqual(sourceCount, 0)
        XCTAssertEqual(assetCount, 0)
    }

    func testMultiStepWriteRollsBackWhenAssetSQLFails() throws {
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
                    locatorKind: .file,
                    relativePath: nil,
                    photosLocalIdentifier: nil,
                    mediaType: "public.jpeg",
                    timestampMs: DatabaseTestSupport.timestampMs
                )
            )
        )

        let sourceCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source WHERE id = ?", arguments: [sourceID.uuidString.lowercased()]) ?? 0
        }
        let assetCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0
        }
        XCTAssertEqual(sourceCount, 0, "Source insert must roll back when Asset SQL fails")
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

    func testInsertAssetAddsSecondAssetToExistingSource() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let sourceID = UUID()
        let firstAssetID = UUID()
        let secondAssetID = UUID()

        try DatabaseTestSupport.makeFolderSourceWithFileAsset(
            repository: repository,
            sourceID: sourceID,
            assetID: firstAssetID
        )

        try repository.insertAsset(
            NewAssetInput(
                assetID: secondAssetID,
                sourceID: sourceID,
                locatorKind: .file,
                relativePath: "album/second.jpg",
                photosLocalIdentifier: nil,
                mediaType: "public.jpeg",
                timestampMs: DatabaseTestSupport.timestampMs
            )
        )

        let assetCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE source_id = ?", arguments: [sourceID.uuidString.lowercased()]) ?? 0
        }
        XCTAssertEqual(assetCount, 2)
    }

    func testUpsertFileFingerprintReplacesExistingFingerprint() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let assetID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, assetID: assetID)

        try repository.upsertFileFingerprint(
            FileFingerprintInput(
                assetID: assetID,
                sizeBytes: 10,
                modifiedAtNs: 20,
                resourceID: nil,
                sha256: Data(repeating: 0x01, count: 32)
            )
        )
        try repository.upsertFileFingerprint(
            FileFingerprintInput(
                assetID: assetID,
                sizeBytes: 99,
                modifiedAtNs: 200,
                resourceID: Data([0xAA]),
                sha256: Data(repeating: 0xFF, count: 32)
            )
        )

        let row = try database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT size_bytes, modified_at_ns, resource_id, sha256
                FROM file_fingerprint WHERE asset_id = ?
                """,
                arguments: [assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(row?["size_bytes"] as Int64?, 99)
        XCTAssertEqual(row?["modified_at_ns"] as Int64?, 200)
        XCTAssertEqual(row?["resource_id"] as Data?, Data([0xAA]))
        XCTAssertEqual(row?["sha256"] as Data?, Data(repeating: 0xFF, count: 32))
    }

    func testInsertAssetMissingSourceReturnsReferenceNotFound() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)

        XCTAssertThrowsError(
            try repository.insertAsset(
                NewAssetInput(
                    assetID: UUID(),
                    sourceID: UUID(),
                    locatorKind: .file,
                    relativePath: "album/missing.jpg",
                    photosLocalIdentifier: nil,
                    mediaType: "public.jpeg",
                    timestampMs: DatabaseTestSupport.timestampMs
                )
            )
        ) { error in
            XCTAssertEqual(error as? CatalogRepositoryError, .referenceNotFound)
        }
    }

    func testUpsertFileFingerprintMissingAssetReturnsReferenceNotFound() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)

        XCTAssertThrowsError(
            try repository.upsertFileFingerprint(
                FileFingerprintInput(
                    assetID: UUID(),
                    sizeBytes: 1,
                    modifiedAtNs: 1,
                    resourceID: nil,
                    sha256: nil
                )
            )
        ) { error in
            XCTAssertEqual(error as? CatalogRepositoryError, .referenceNotFound)
        }
    }
}
