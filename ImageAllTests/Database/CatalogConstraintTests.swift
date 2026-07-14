import GRDB
import XCTest
@testable import ImageAll

final class CatalogConstraintTests: XCTestCase {
    // MARK: - UUID

    func testCanonicalLowercaseUUIDIsAccepted() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let sourceID = DatabaseTestSupport.lowercaseUUIDString()

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'folder', 'Name', ?, 0, 0, 'active', ?, ?)
                """,
                arguments: [
                    sourceID,
                    DatabaseTestSupport.folderBookmark(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        }
    }

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

    // MARK: - Source / Asset

    func testFolderSourceWithFileAssetPersists() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository)
    }

    func testPhotosSourceWithPhotosAssetPersists() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        try DatabaseTestSupport.makePhotosSourceWithPhotosAsset(repository: repository)
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

    func testFolderSourceRejectsMissingBookmark() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'folder', 'Name', NULL, 0, 0, 'active', ?, ?)
                """,
                arguments: [
                    DatabaseTestSupport.lowercaseUUIDString(),
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

    // MARK: - Unknown enum raw values

    func testSourceRejectsUnknownKind() throws {
        try assertSourceInsertRejected(kind: "cloud")
    }

    func testSourceRejectsUnknownState() throws {
        try assertSourceInsertRejected(state: "deleted")
    }

    func testAssetRejectsUnknownLocatorKind() throws {
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
                ) VALUES (?, ?, 'cloud', 'a.jpg', NULL, 'public.jpeg', ?, ?)
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

    func testAssetRejectsUnknownLocatorState() throws {
        try assertAssetInsertRejected(locatorState: "stale")
    }

    func testAssetRejectsUnknownAvailability() throws {
        try assertAssetInsertRejected(availability: "offline")
    }

    func testTagRejectsUnknownState() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES (?, 'Work', 'work', 'deleted', ?, ?)
                """,
                arguments: [
                    DatabaseTestSupport.lowercaseUUIDString(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        })
    }

    func testTagDecisionRejectsUnknownDecision() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let assetID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, assetID: assetID)
        let tagID = DatabaseTestSupport.lowercaseUUIDString()

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES (?, 'Work', 'work', 'active', ?, ?)
                """,
                arguments: [tagID, DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs]
            )
        }

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'unknown', ?)
                """,
                arguments: [assetID.uuidString.lowercased(), tagID, DatabaseTestSupport.timestampMs]
            )
        })
    }

    func testJobRejectsUnknownState() throws {
        try assertJobInsertRejected(state: "invalidState")
    }

    func testJobRejectsUnknownControlRequest() throws {
        try assertJobInsertRejected(controlRequest: "halt")
    }

    // MARK: - Numeric / blob

    func testAssetAcceptsPositiveDimensionsAndValidHash() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let assetID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, assetID: assetID)

        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET width = 1920, height = 1080 WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }

        try repository.upsertFileFingerprint(
            FileFingerprintInput(
                assetID: assetID,
                sizeBytes: 100,
                modifiedAtNs: 200,
                resourceID: nil,
                sha256: Data(repeating: 0xAB, count: 32)
            )
        )
    }

    func testAssetRejectsContentRevisionZero() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let assetID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, assetID: assetID)

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET content_revision = 0 WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        })
    }

    func testFingerprintRejectsNegativeSizeBytes() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let assetID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, assetID: assetID)

        XCTAssertThrowsError(try repository.upsertFileFingerprint(
            FileFingerprintInput(
                assetID: assetID,
                sizeBytes: -1,
                modifiedAtNs: 0,
                resourceID: nil,
                sha256: nil
            )
        ))
    }

    func testFingerprintRejectsInvalidSha256Length() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let assetID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, assetID: assetID)

        XCTAssertThrowsError(try repository.upsertFileFingerprint(
            FileFingerprintInput(
                assetID: assetID,
                sizeBytes: 1,
                modifiedAtNs: 1,
                resourceID: nil,
                sha256: Data(repeating: 0x01, count: 31)
            )
        ))
    }

    func testSourceRejectsNegativeScanGeneration() throws {
        try assertSourceInsertRejected(scanGeneration: -1)
    }

    func testAssetRejectsZeroWidth() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let assetID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, assetID: assetID)

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET width = 0 WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        })
    }

    func testSourceBookmarkRejectsTextStorageClass() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'folder', 'Name', 'text-not-blob', 0, 0, 'active', ?, ?)
                """,
                arguments: [
                    DatabaseTestSupport.lowercaseUUIDString(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        })
    }

    func testFingerprintBlobColumnsRejectTextStorageClass() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
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
    }

    func testJobPayloadRejectsTextStorageClass() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let timestamp = DatabaseTestSupport.timestampMs

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

    // MARK: - Locator uniqueness

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

    func testCurrentFileLocatorDuplicateRejectedHistoricalAllowed() throws {
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

    func testCurrentPhotosLocatorDuplicateRejectedHistoricalAllowed() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        let sourceID = UUID()
        try DatabaseTestSupport.makePhotosSourceWithPhotosAsset(
            repository: repository,
            sourceID: sourceID,
            assetID: UUID()
        )

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, record_created_at_ms, record_updated_at_ms
                ) VALUES (?, ?, 'photos', NULL, 'ABC-DEF-123', 'current', 'public.heic', ?, ?)
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
                ) VALUES (?, ?, 'photos', NULL, 'ABC-DEF-123', 'historical', 'public.heic', ?, ?)
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

    // MARK: - Tag / decision

    func testTagDecisionAcceptedAndRejectedPersist() throws {
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
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'accepted', ?)
                """,
                arguments: [assetID.uuidString.lowercased(), tagID, timestamp]
            )
            try db.execute(
                sql: """
                UPDATE asset_tag_decision SET decision = 'rejected', updated_at_ms = ?
                WHERE asset_id = ? AND tag_id = ?
                """,
                arguments: [timestamp, assetID.uuidString.lowercased(), tagID]
            )
        }
    }

    func testTagDecisionDuplicatePairIsRejected() throws {
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

    func testAllowedVocabularyRawValuesPersist() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let timestamp = DatabaseTestSupport.timestampMs

        try database.pool.write { db in
            for state in ["active", "disabled", "unavailable", "authorizationRequired"] {
                try db.execute(
                    sql: """
                    INSERT INTO source (
                        id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                        state, created_at_ms, updated_at_ms
                    ) VALUES (?, 'folder', ?, ?, 0, 0, ?, ?, ?)
                    """,
                    arguments: [
                        DatabaseTestSupport.lowercaseUUIDString(),
                        "Source-\(state)",
                        DatabaseTestSupport.folderBookmark(),
                        state,
                        timestamp,
                        timestamp,
                    ]
                )
            }
        }

        let repository = CatalogRepository(database: database)
        let sourceID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(repository: repository, sourceID: sourceID)

        try database.pool.write { db in
            for availability in ["available", "missing", "unreadable", "unsupported"] {
                try db.execute(
                    sql: """
                    INSERT INTO asset (
                        id, source_id, locator_kind, relative_path, photos_local_identifier,
                        availability, media_type, record_created_at_ms, record_updated_at_ms
                    ) VALUES (?, ?, 'file', ?, NULL, ?, 'public.jpeg', ?, ?)
                    """,
                    arguments: [
                        DatabaseTestSupport.lowercaseUUIDString(),
                        sourceID.uuidString.lowercased(),
                        "paths/\(availability).jpg",
                        availability,
                        timestamp,
                        timestamp,
                    ]
                )
            }
        }
    }

    func testJobAllowedStatesPersist() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let timestamp = DatabaseTestSupport.timestampMs
        let states = [
            "pending", "running", "paused", "retryableFailed",
            "completed", "terminalFailed", "cancelled",
        ]

        try database.pool.write { db in
            for state in states {
                if state == "running" {
                    try db.execute(
                        sql: """
                        INSERT INTO job (
                            id, kind, payload_version, payload, state, control_request,
                            max_attempts, not_before_ms, lease_owner, lease_expires_at_ms,
                            created_at_ms, updated_at_ms
                        ) VALUES (?, 'scan', 1, ?, ?, 'none', 3, ?, 'worker', ?, ?, ?)
                        """,
                        arguments: [
                            DatabaseTestSupport.lowercaseUUIDString(),
                            Data([0x01]),
                            state,
                            timestamp,
                            timestamp + 60_000,
                            timestamp,
                            timestamp,
                        ]
                    )
                } else {
                    try db.execute(
                        sql: """
                        INSERT INTO job (
                            id, kind, payload_version, payload, state, control_request,
                            max_attempts, not_before_ms, created_at_ms, updated_at_ms
                        ) VALUES (?, 'scan', 1, ?, ?, 'none', 3, ?, ?, ?)
                        """,
                        arguments: [
                            DatabaseTestSupport.lowercaseUUIDString(),
                            Data([0x01]),
                            state,
                            timestamp,
                            timestamp,
                            timestamp,
                        ]
                    )
                }
            }
        }
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
                arguments: [
                    DatabaseTestSupport.lowercaseUUIDString(),
                    Data([0x01]),
                    timestamp,
                    timestamp + 60_000,
                    timestamp,
                    timestamp,
                ]
            )
        }
    }

    func testJobPendingRejectsLeaseFields() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let timestamp = DatabaseTestSupport.timestampMs

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, state, control_request,
                    max_attempts, not_before_ms, lease_owner, lease_expires_at_ms,
                    created_at_ms, updated_at_ms
                ) VALUES (?, 'scan', 1, ?, 'pending', 'none', 1, ?, 'worker', ?, ?, ?)
                """,
                arguments: [
                    DatabaseTestSupport.lowercaseUUIDString(),
                    Data([0x01]),
                    timestamp,
                    timestamp + 60,
                    timestamp,
                    timestamp,
                ]
            )
        })
    }

    func testJobPendingRejectsPauseControlRequest() throws {
        try assertJobInsertRejected(state: "pending", controlRequest: "pause")
    }

    func testJobRejectsAttemptsExceedingMaxAttempts() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let jobID = DatabaseTestSupport.lowercaseUUIDString()
        let timestamp = DatabaseTestSupport.timestampMs

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
                sql: "UPDATE job SET attempts = 2 WHERE id = ?",
                arguments: [jobID]
            )
        })
    }

    func testJobRejectsCheckpointVersionWithoutCheckpoint() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let jobID = DatabaseTestSupport.lowercaseUUIDString()
        let timestamp = DatabaseTestSupport.timestampMs

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, state, control_request,
                    max_attempts, not_before_ms, created_at_ms, updated_at_ms
                ) VALUES (?, 'scan', 1, ?, 'pending', 'none', 1, ?, ?, ?)
                """,
                arguments: [jobID, Data([0x01]), timestamp, timestamp, timestamp]
            )
        }

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: "UPDATE job SET checkpoint_version = 1 WHERE id = ?",
                arguments: [jobID]
            )
        })
    }

    func testJobRejectsProgressCompletedExceedingTotal() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let jobID = DatabaseTestSupport.lowercaseUUIDString()
        let timestamp = DatabaseTestSupport.timestampMs

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, state, control_request,
                    max_attempts, not_before_ms, created_at_ms, updated_at_ms
                ) VALUES (?, 'scan', 1, ?, 'pending', 'none', 1, ?, ?, ?)
                """,
                arguments: [jobID, Data([0x01]), timestamp, timestamp, timestamp]
            )
        }

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: "UPDATE job SET progress_total = 1, progress_completed = 5 WHERE id = ?",
                arguments: [jobID]
            )
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

    // MARK: - Delete actions

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

    func testAssetDeleteIsRestrictedByTagDecision() throws {
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
            try db.execute(sql: "DELETE FROM asset WHERE id = ?", arguments: [assetID.uuidString.lowercased()])
        })
    }

    func testTagDeleteIsRestrictedByDecision() throws {
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
    }

    func testJobSourceSetNullOnSourceDelete() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let sourceID = DatabaseTestSupport.lowercaseUUIDString()
        let jobID = DatabaseTestSupport.lowercaseUUIDString()
        let timestamp = DatabaseTestSupport.timestampMs

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
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, source_id, state, control_request,
                    max_attempts, not_before_ms, created_at_ms, updated_at_ms
                ) VALUES (?, 'scan', 1, ?, ?, 'pending', 'none', 1, ?, ?, ?)
                """,
                arguments: [jobID, Data([0x01]), sourceID, timestamp, timestamp, timestamp]
            )
            try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [sourceID])
        }

        let jobSourceID = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT source_id FROM job WHERE id = ?", arguments: [jobID])
        }
        XCTAssertNil(jobSourceID)
    }
}

private extension CatalogConstraintTests {
    func assertSourceInsertRejected(
        kind: String = "folder",
        state: String = "active",
        scanGeneration: Int = 0
    ) throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'Name', ?, ?, 0, ?, ?, ?)
                """,
                arguments: [
                    DatabaseTestSupport.lowercaseUUIDString(),
                    kind,
                    kind == "photos" ? nil : DatabaseTestSupport.folderBookmark(),
                    scanGeneration,
                    state,
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        })
    }

    func assertAssetInsertRejected(
        locatorState: String = "current",
        availability: String = "available"
    ) throws {
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
                    locator_state, availability, media_type, record_created_at_ms, record_updated_at_ms
                ) VALUES (?, ?, 'file', 'other.jpg', NULL, ?, ?, 'public.jpeg', ?, ?)
                """,
                arguments: [
                    DatabaseTestSupport.lowercaseUUIDString(),
                    sourceID.uuidString.lowercased(),
                    locatorState,
                    availability,
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        })
    }

    func assertJobInsertRejected(
        state: String = "pending",
        controlRequest: String = "none"
    ) throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let timestamp = DatabaseTestSupport.timestampMs

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, state, control_request,
                    max_attempts, not_before_ms, created_at_ms, updated_at_ms
                ) VALUES (?, 'scan', 1, ?, ?, ?, 1, ?, ?, ?)
                """,
                arguments: [
                    DatabaseTestSupport.lowercaseUUIDString(),
                    Data([0x01]),
                    state,
                    controlRequest,
                    timestamp,
                    timestamp,
                    timestamp,
                ]
            )
        })
    }
}
