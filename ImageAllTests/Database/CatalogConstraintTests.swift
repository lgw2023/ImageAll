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

    func testMalformedUUIDIsRejected() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        for malformedID in ["not-a-uuid", "0123456789abcdef0123456789abcdef"] {
            XCTAssertThrowsError(try database.pool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO source (
                        id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                        state, created_at_ms, updated_at_ms
                    ) VALUES (?, 'folder', 'Name', ?, 0, 0, 'active', ?, ?)
                    """,
                    arguments: [
                        malformedID,
                        DatabaseTestSupport.folderBookmark(),
                        DatabaseTestSupport.timestampMs,
                        DatabaseTestSupport.timestampMs,
                    ]
                )
            }, "Expected rejection for \(malformedID)")
        }
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

    func testBlobStorageClassRejectsTextSubstitutes() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let timestamp = DatabaseTestSupport.timestampMs

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'folder', 'Name', 'text-not-blob', 0, 0, 'active', ?, ?)
                """,
                arguments: [DatabaseTestSupport.lowercaseUUIDString(), timestamp, timestamp]
            )
        })

        let repository = CatalogRepository(database: database)
        let assetID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, assetID: assetID)

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO file_fingerprint (
                    asset_id, size_bytes, modified_at_ns, resource_id, sha256
                ) VALUES (?, 1, 1, 'text-not-blob', ?)
                """,
                arguments: [assetID.uuidString.lowercased(), String(repeating: "a", count: 32)]
            )
        })

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, state, control_request,
                    max_attempts, not_before_ms, created_at_ms, updated_at_ms
                ) VALUES (?, 'scan', 1, 'text-not-blob', 'pending', 'none', 1, ?, ?, ?)
                """,
                arguments: [DatabaseTestSupport.lowercaseUUIDString(), timestamp, timestamp, timestamp]
            )
        })
    }

    func testUnknownEnumRawValuesAreRejected() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let timestamp = DatabaseTestSupport.timestampMs
        let sourceID = DatabaseTestSupport.lowercaseUUIDString()

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'cloud', 'Name', ?, 0, 0, 'active', ?, ?)
                """,
                arguments: [sourceID, DatabaseTestSupport.folderBookmark(), timestamp, timestamp]
            )
        })
    }

    func testNumericAndHashConstraintsAreRejected() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let sourceID = UUID()
        let assetID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, sourceID: sourceID, assetID: assetID)

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE asset SET content_revision = 0 WHERE id = ?
                """,
                arguments: [assetID.uuidString.lowercased()]
            )
        })

        XCTAssertThrowsError(try repository.upsertFileFingerprint(
            FileFingerprintInput(
                assetID: assetID,
                sizeBytes: -1,
                modifiedAtNs: 0,
                resourceID: nil,
                sha256: Data(repeating: 0x01, count: 31)
            )
        ))
    }

    func testTagDecisionConstraintsAndDuplicatePair() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let assetID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, assetID: assetID)
        let tagID = DatabaseTestSupport.lowercaseUUIDString()
        let timestamp = DatabaseTestSupport.timestampMs

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES (?, 'Work', 'work', 'active', ?, ?)
                """,
                arguments: [tagID, timestamp, timestamp]
            )
        }

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'unknown', ?)
                """,
                arguments: [assetID.uuidString.lowercased(), tagID, timestamp]
            )
        })

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'accepted', ?)
                """,
                arguments: [assetID.uuidString.lowercased(), tagID, timestamp]
            )
        }

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'rejected', ?)
                """,
                arguments: [assetID.uuidString.lowercased(), tagID, timestamp]
            )
        })
    }

    func testDeleteRestrictionsAndJobSourceSetNull() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let assetID = UUID()
        let tagID = DatabaseTestSupport.lowercaseUUIDString()
        let timestamp = DatabaseTestSupport.timestampMs
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, assetID: assetID)

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES (?, 'Work', 'work', 'active', ?, ?)
                """,
                arguments: [tagID, timestamp, timestamp]
            )
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'accepted', ?)
                """,
                arguments: [assetID.uuidString.lowercased(), tagID, timestamp]
            )
        }

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [tagID])
        })

        let sourceID = DatabaseTestSupport.lowercaseUUIDString()
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'photos', 'Library', NULL, 0, 0, 'active', ?, ?)
                """,
                arguments: [sourceID, timestamp, timestamp]
            )
        }

        let jobID = DatabaseTestSupport.lowercaseUUIDString()
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, source_id, state, control_request,
                    max_attempts, not_before_ms, created_at_ms, updated_at_ms
                ) VALUES (?, 'scan', 1, ?, ?, 'pending', 'none', 1, ?, ?, ?)
                """,
                arguments: [jobID, Data([0x01]), sourceID, timestamp, timestamp, timestamp]
            )
        }

        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [sourceID])
        }

        let jobSourceID = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT source_id FROM job WHERE id = ?", arguments: [jobID])
        }
        XCTAssertNil(jobSourceID)
    }

    func testJobDDLRejectsInvalidRows() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let timestamp = DatabaseTestSupport.timestampMs
        let jobID = DatabaseTestSupport.lowercaseUUIDString()

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, state, control_request,
                    max_attempts, not_before_ms, created_at_ms, updated_at_ms
                ) VALUES (?, 'scan', 1, ?, 'invalidState', 'none', 1, ?, ?, ?)
                """,
                arguments: [jobID, Data([0x01]), timestamp, timestamp, timestamp]
            )
        })

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, state, control_request,
                    max_attempts, not_before_ms, lease_owner, lease_expires_at_ms,
                    created_at_ms, updated_at_ms
                ) VALUES (?, 'scan', 1, ?, 'pending', 'none', 1, ?, 'worker', ?, ?, ?)
                """,
                arguments: [DatabaseTestSupport.lowercaseUUIDString(), Data([0x01]), timestamp, timestamp + 60, timestamp, timestamp]
            )
        })

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, state, control_request,
                    max_attempts, not_before_ms, created_at_ms, updated_at_ms
                ) VALUES (?, 'scan', 1, ?, 'pending', 'pause', 1, ?, ?, ?)
                """,
                arguments: [jobID, Data([0x01]), timestamp, timestamp, timestamp]
            )
        })

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, state, control_request,
                    max_attempts, attempts, not_before_ms, created_at_ms, updated_at_ms
                ) VALUES (?, 'scan', 1, ?, 'pending', 'none', 1, 0, ?, ?, ?)
                """,
                arguments: [jobID, Data([0x01]), timestamp, timestamp, timestamp]
            )
        }

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE job SET attempts = 2 WHERE id = ?
                """,
                arguments: [jobID]
            )
        })

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE job SET checkpoint_version = 1 WHERE id = ?
                """,
                arguments: [jobID]
            )
        })

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE job SET progress_total = 1, progress_completed = 5 WHERE id = ?
                """,
                arguments: [jobID]
            )
        })
    }

    func testJobRunningRowRequiresLease() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let timestamp = DatabaseTestSupport.timestampMs

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, state, control_request,
                    max_attempts, not_before_ms, lease_owner, lease_expires_at_ms,
                    created_at_ms, updated_at_ms
                ) VALUES (?, 'scan', 1, ?, 'running', 'none', 3, ?, 'worker-1', ?, ?, ?)
                """,
                arguments: [DatabaseTestSupport.lowercaseUUIDString(), Data([0x01]), timestamp, timestamp + 60_000, timestamp, timestamp]
            )
        }
    }
}
