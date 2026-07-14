import GRDB
import XCTest
@testable import ImageAll

final class CatalogConstraintTests: XCTestCase {
    func testUppercaseUUIDIsRejected() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let uppercaseID = UUID().uuidString.uppercased()

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'folder', 'Name', ?, 0, 0, 'active', ?, ?)
                """,
                arguments: [
                    uppercaseID,
                    DatabaseTestSupport.folderBookmark(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        })
    }

    func testPhotosSourceRejectsBookmark() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'photos', 'Library', ?, 0, 0, 'active', ?, ?)
                """,
                arguments: [
                    DatabaseTestSupport.lowercaseUUIDString(),
                    DatabaseTestSupport.folderBookmark(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        })
    }

    func testAssetLocatorColumnMismatchIsRejected() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let sourceID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, sourceID: sourceID)

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    media_type, record_created_at_ms, record_updated_at_ms
                ) VALUES (?, ?, 'file', NULL, NULL, 'public.jpeg', ?, ?)
                """,
                arguments: [
                    DatabaseTestSupport.lowercaseUUIDString(),
                    sourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        })
    }

    func testTagNormalizedNameIsBinaryUnique() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let tagID = DatabaseTestSupport.lowercaseUUIDString()
        let duplicateID = DatabaseTestSupport.lowercaseUUIDString()

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES (?, 'Family', 'family', 'active', ?, ?)
                """,
                arguments: [tagID, DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs]
            )
        }

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES (?, 'FAMILY', 'family', 'active', ?, ?)
                """,
                arguments: [duplicateID, DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs]
            )
        })

        let cafeID = DatabaseTestSupport.lowercaseUUIDString()
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES (?, 'Café', 'café', 'active', ?, ?)
                """,
                arguments: [cafeID, DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs]
            )
        }
    }

    func testCurrentLocatorDuplicateRejectedHistoricalAllowed() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let sourceID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, sourceID: sourceID)

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, record_created_at_ms, record_updated_at_ms
                ) VALUES (?, ?, 'file', 'album/photo.jpg', NULL, 'current', 'public.jpeg', ?, ?)
                """,
                arguments: [
                    DatabaseTestSupport.lowercaseUUIDString(),
                    sourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        })

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, record_created_at_ms, record_updated_at_ms
                ) VALUES (?, ?, 'file', 'album/photo.jpg', NULL, 'historical', 'public.jpeg', ?, ?)
                """,
                arguments: [
                    DatabaseTestSupport.lowercaseUUIDString(),
                    sourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        }
    }

    func testFingerprintCascadesOnAssetDelete() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let assetID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, assetID: assetID)
        try repository.upsertFileFingerprint(
            FileFingerprintInput(
                assetID: assetID,
                sizeBytes: 100,
                modifiedAtNs: 200,
                resourceID: nil,
                sha256: Data(repeating: 0xAB, count: 32)
            )
        )

        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM asset WHERE id = ?", arguments: [assetID.uuidString.lowercased()])
        }

        let count = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file_fingerprint") ?? 0
        }
        XCTAssertEqual(count, 0)
    }

    func testSourceDeleteIsRestrictedByAsset() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let sourceID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, sourceID: sourceID)

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [sourceID.uuidString.lowercased()])
        })
    }

    func testJobActiveCoalescingKeyConflictAndTerminalReuse() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let jobA = DatabaseTestSupport.lowercaseUUIDString()
        let jobB = DatabaseTestSupport.lowercaseUUIDString()
        let jobC = DatabaseTestSupport.lowercaseUUIDString()
        let timestamp = DatabaseTestSupport.timestampMs

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, coalescing_key, state, control_request,
                    max_attempts, not_before_ms, created_at_ms, updated_at_ms
                ) VALUES (?, 'scan', 1, ?, 'same-key', 'pending', 'none', 3, ?, ?, ?)
                """,
                arguments: [jobA, Data([0x01]), timestamp, timestamp, timestamp]
            )
        }

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, coalescing_key, state, control_request,
                    max_attempts, not_before_ms, lease_owner, lease_expires_at_ms,
                    created_at_ms, updated_at_ms
                ) VALUES (?, 'scan', 1, ?, 'same-key', 'running', 'none', 3, ?, 'worker', ?, ?, ?)
                """,
                arguments: [jobB, Data([0x02]), timestamp, timestamp + 60, timestamp, timestamp]
            )
        })

        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE job SET state = 'completed', lease_owner = NULL, lease_expires_at_ms = NULL
                WHERE id = ?
                """,
                arguments: [jobA]
            )
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, coalescing_key, state, control_request,
                    max_attempts, not_before_ms, created_at_ms, updated_at_ms
                ) VALUES (?, 'scan', 1, ?, 'same-key', 'pending', 'none', 3, ?, ?, ?)
                """,
                arguments: [jobC, Data([0x03]), timestamp, timestamp, timestamp]
            )
        }
    }
}
