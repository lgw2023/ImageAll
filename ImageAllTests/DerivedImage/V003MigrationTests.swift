import GRDB
import XCTest
@testable import ImageAll

final class V003MigrationTests: XCTestCase {
    // MARK: - 1. Fresh apply and v002 upgrade

    func testFreshDatabaseAppliesV001V002V003ExactlyOnce() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        XCTAssertEqual(try database.appliedMigrationIDs(), CatalogMigrationID.knownOrdered)
    }

    func testReopeningFreshDatabasePreservesMigrationList() throws {
        let url = try makeTempDatabaseURL()
        _ = try CatalogDatabase.open(at: url)
        let second = try CatalogDatabase.open(at: url)
        XCTAssertEqual(try second.appliedMigrationIDs(), CatalogMigrationID.knownOrdered)
    }

    func testV002SentinelFactsSurviveV003Upgrade() throws {
        let url = try makeTempDatabaseURL()
        let pool = try openV002OnlyPool(at: url)
        let sentinel = try seedV002SentinelFacts(in: pool)
        try CatalogDatabase.closePool(pool)

        let upgraded = try CatalogDatabase.open(at: url)
        try upgraded.pool.read { db in
            XCTAssertTrue(try db.tableExists("derived_image_cache_entry"))
            try assertV002SentinelFactsUnchanged(in: db, sentinel: sentinel)
        }
    }

    // MARK: - 2. Future migration rejection on v002-only file

    func testFutureMigrationAppendedToV002OnlyDatabaseIsRejectedBeforeV003() throws {
        let url = try makeTempDatabaseURL()
        let pool = try openV002OnlyPool(at: url)
        let sentinel = try seedV002SentinelFacts(in: pool)
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: ["v999_future_migration"]
            )
        }

        XCTAssertThrowsError(try CatalogDatabase.open(at: url)) { error in
            guard case let CatalogDatabaseError.futureSchema(applied, unknown) = error else {
                return XCTFail("expected futureSchema, got \(error)")
            }
            XCTAssertTrue(applied.contains("v999_future_migration"))
            XCTAssertEqual(unknown, ["v999_future_migration"])
        }

        try pool.read { db in
            let migrations = try String.fetchAll(
                db,
                sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"
            )
            XCTAssertEqual(
                migrations,
                [
                    CatalogMigrationID.v001CreateCatalogCore,
                    CatalogMigrationID.v002AddStage1CatalogQuerySupport,
                    "v999_future_migration",
                ]
            )
            XCTAssertFalse(try db.tableExists("derived_image_cache_entry"))
            try assertV002SentinelFactsUnchanged(in: db, sentinel: sentinel)
        }
    }

    // MARK: - 3. sqlite metadata for v003 delta

    func testV003AddsExactlyOneStrictTableTwoNamedIndexesAndZeroTriggers() throws {
        let v002URL = try makeTempDatabaseURL()
        let v002Pool = try openV002OnlyPool(at: v002URL)
        let v002Tables = try v002Pool.read { try DatabaseTestSupport.tableNames($0) }
        let v002Indexes = try v002Pool.read { try DatabaseTestSupport.indexNames($0) }
        try CatalogDatabase.closePool(v002Pool)

        let v003URL = try makeTempDatabaseURL()
        let v003Pool = try openV002OnlyPool(at: v003URL)
        var v003Migrator = DatabaseTestSupport.makeV002OnlyMigrator()
        V003AddDerivedImageCacheMigration.register(on: &v003Migrator)
        try v003Migrator.migrate(v003Pool)
        let v003Tables = try v003Pool.read { try DatabaseTestSupport.tableNames($0) }
        let v003Indexes = try v003Pool.read { try DatabaseTestSupport.indexNames($0) }

        let addedTables = Set(v003Tables).subtracting(v002Tables)
        XCTAssertEqual(addedTables, ["derived_image_cache_entry"])

        let addedIndexes = Set(v003Indexes).subtracting(v002Indexes)
        XCTAssertEqual(
            addedIndexes,
            ["derived_image_cache_key_uq", "derived_image_cache_lru_idx"]
        )

        try v003Pool.read { db in
            XCTAssertTrue(try DatabaseTestSupport.isStrictTable(db, table: "derived_image_cache_entry"))
            let triggers = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM sqlite_schema
                WHERE type = 'trigger' AND tbl_name = 'derived_image_cache_entry'
                """
            ) ?? -1
            XCTAssertEqual(triggers, 0)
        }
    }

    func testV003DerivedCacheColumnsExcludePathBookmarkAndFilenameFields() throws {
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        let forbidden = Set([
            "relative_path",
            "bookmark",
            "file_name",
            "display_name",
            "name",
            "normalized_name",
            "payload",
            "photos_local_identifier",
        ])
        try database.pool.read { db in
            let columns = try DatabaseTestSupport.tableInfo(db, table: "derived_image_cache_entry").map(\.name)
            XCTAssertFalse(columns.contains(where: forbidden.contains))
            XCTAssertEqual(columns, CatalogSchemaExpectations.columnsByTable["derived_image_cache_entry"]?.map(\.name))
        }
    }

    func testV003ForeignKeyAssetIDCascadesOnDelete() throws {
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        try database.pool.read { db in
            let foreignKeys = try DatabaseTestSupport.foreignKeyList(db, table: "derived_image_cache_entry")
            XCTAssertEqual(foreignKeys.count, 1)
            XCTAssertEqual(foreignKeys[0].from, "asset_id")
            XCTAssertEqual(foreignKeys[0].toTable, "asset")
            XCTAssertEqual(foreignKeys[0].to, "id")
            XCTAssertEqual(foreignKeys[0].onDelete, "CASCADE")
        }
    }

    // MARK: - 4. SQL constraint matrix

    func testLowercaseCanonicalUUIDAccepted() throws {
        let database = try seededDatabaseWithAsset()
        let assetID = try fetchOnlyAssetID(from: database)
        try insertValidEntry(database: database, id: UUID().uuidString.lowercased(), assetID: assetID)
    }

    func testUppercaseUUIDRejected() throws {
        let database = try seededDatabaseWithAsset()
        let assetID = try fetchOnlyAssetID(from: database)
        assertInsertFails(database, label: "uppercase id") { db in
            try insertValidEntry(db: db, id: UUID().uuidString.uppercased(), assetID: assetID)
        }
    }

    func testMalformedUUIDRejected() throws {
        let database = try seededDatabaseWithAsset()
        let assetID = try fetchOnlyAssetID(from: database)
        assertInsertFails(database, label: "malformed id") { db in
            try insertValidEntry(db: db, id: "not-a-valid-uuid", assetID: assetID)
        }
    }

    func testNonTextPrimaryKeyRejected() throws {
        let database = try seededDatabaseWithAsset()
        let assetID = try fetchOnlyAssetID(from: database)
        assertInsertFails(database, label: "non-text id") { db in
            try db.execute(
                sql: """
                INSERT INTO derived_image_cache_entry (
                    id, asset_id, content_revision, representation_version, variant,
                    storage_format, pixel_width, pixel_height, byte_size, encoded_sha256,
                    created_at_ms, last_accessed_at_ms
                ) VALUES (123, ?, 1, 1, 'gridSmall', 'jpeg', 256, 256, 1, ?, 0, 0)
                """,
                arguments: [assetID, validHash()]
            )
        }
    }

    func testMissingAssetForeignKeyRejected() throws {
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        assertInsertFails(database, label: "missing asset fk") { db in
            try insertValidEntry(
                db: db,
                id: UUID().uuidString.lowercased(),
                assetID: UUID().uuidString.lowercased()
            )
        }
    }

    func testContentRevisionOneAcceptedAndZeroRejected() throws {
        let database = try seededDatabaseWithAsset()
        let assetID = try fetchOnlyAssetID(from: database)
        try insertValidEntry(database: database, assetID: assetID, contentRevision: 1)
        assertInsertFails(database, label: "content_revision 0") { db in
            try insertValidEntry(db: db, assetID: assetID, contentRevision: 0, variant: "gridRegular", pixelWidth: 512, pixelHeight: 512)
        }
    }

    func testRepresentationVersionOneAcceptedAndZeroRejected() throws {
        let database = try seededDatabaseWithAsset()
        let assetID = try fetchOnlyAssetID(from: database)
        try insertValidEntry(database: database, assetID: assetID, representationVersion: 1, variant: "gridRegular", pixelWidth: 512, pixelHeight: 512)
        assertInsertFails(database, label: "representation_version 0") { db in
            try insertValidEntry(db: db, assetID: assetID, representationVersion: 0, variant: "preview", pixelWidth: 1024, pixelHeight: 768)
        }
    }

    func testGridSmallLegalDimensionsAccepted() throws {
        let database = try seededDatabaseWithAsset()
        try insertValidEntry(database: database, assetID: try fetchOnlyAssetID(from: database), variant: "gridSmall", pixelWidth: 256, pixelHeight: 256)
    }

    func testGridRegularLegalDimensionsAccepted() throws {
        let database = try seededDatabaseWithAsset()
        try insertValidEntry(
            database: database,
            assetID: try fetchOnlyAssetID(from: database),
            variant: "gridRegular",
            pixelWidth: 512,
            pixelHeight: 512
        )
    }

    func testPreviewLegalDimensionsAccepted() throws {
        let database = try seededDatabaseWithAsset()
        try insertValidEntry(
            database: database,
            assetID: try fetchOnlyAssetID(from: database),
            variant: "preview",
            pixelWidth: 2048,
            pixelHeight: 1536
        )
    }

    func testUnknownVariantRejected() throws {
        let database = try seededDatabaseWithAsset()
        assertInsertFails(database, label: "unknown variant") { db in
            try insertValidEntry(db: db, assetID: try fetchOnlyAssetID(from: database), variant: "hero")
        }
    }

    func testUnknownStorageFormatRejected() throws {
        let database = try seededDatabaseWithAsset()
        assertInsertFails(database, label: "unknown format") { db in
            try insertValidEntry(db: db, assetID: try fetchOnlyAssetID(from: database), storageFormat: "webp")
        }
    }

    func testPNGStorageFormatAccepted() throws {
        let database = try seededDatabaseWithAsset()
        try insertValidEntry(
            database: database,
            assetID: try fetchOnlyAssetID(from: database),
            variant: "gridRegular",
            storageFormat: "png",
            pixelWidth: 512,
            pixelHeight: 512
        )
    }

    func testGridSmallWrongDimensionsRejected() throws {
        let database = try seededDatabaseWithAsset()
        assertInsertFails(database, label: "gridSmall wrong size") { db in
            try insertValidEntry(db: db, assetID: try fetchOnlyAssetID(from: database), variant: "gridSmall", pixelWidth: 512, pixelHeight: 512)
        }
    }

    func testGridRegularWrongDimensionsRejected() throws {
        let database = try seededDatabaseWithAsset()
        assertInsertFails(database, label: "gridRegular wrong size") { db in
            try insertValidEntry(db: db, assetID: try fetchOnlyAssetID(from: database), variant: "gridRegular", pixelWidth: 256, pixelHeight: 256)
        }
    }

    func testPreviewZeroWidthRejected() throws {
        let database = try seededDatabaseWithAsset()
        assertInsertFails(database, label: "preview width 0") { db in
            try insertValidEntry(db: db, assetID: try fetchOnlyAssetID(from: database), variant: "preview", pixelWidth: 0, pixelHeight: 1024)
        }
    }

    func testPreviewZeroHeightRejected() throws {
        let database = try seededDatabaseWithAsset()
        assertInsertFails(database, label: "preview height 0") { db in
            try insertValidEntry(db: db, assetID: try fetchOnlyAssetID(from: database), variant: "preview", pixelWidth: 1024, pixelHeight: 0)
        }
    }

    func testPreviewLongEdge2049Rejected() throws {
        let database = try seededDatabaseWithAsset()
        assertInsertFails(database, label: "preview long edge 2049") { db in
            try insertValidEntry(db: db, assetID: try fetchOnlyAssetID(from: database), variant: "preview", pixelWidth: 2049, pixelHeight: 1024)
        }
    }

    func testByteSizeOneAcceptedAndZeroRejected() throws {
        let database = try seededDatabaseWithAsset()
        let assetID = try fetchOnlyAssetID(from: database)
        try insertValidEntry(database: database, assetID: assetID, byteSize: 1)
        assertInsertFails(database, label: "byte_size 0") { db in
            try insertValidEntry(
                db: db,
                assetID: assetID,
                variant: "gridRegular",
                pixelWidth: 512,
                pixelHeight: 512,
                byteSize: 0
            )
        }
    }

    func testEncodedSHA256ThirtyTwoByteBlobAccepted() throws {
        let database = try seededDatabaseWithAsset()
        try insertValidEntry(database: database, assetID: try fetchOnlyAssetID(from: database), hash: validHash())
    }

    func testEncodedSHA256ThirtyOneByteBlobRejected() throws {
        let database = try seededDatabaseWithAsset()
        assertInsertFails(database, label: "31-byte blob") { db in
            try insertValidEntry(db: db, assetID: try fetchOnlyAssetID(from: database), hash: Data(repeating: 0x01, count: 31))
        }
    }

    func testEncodedSHA256ThirtyThreeByteBlobRejected() throws {
        let database = try seededDatabaseWithAsset()
        assertInsertFails(database, label: "33-byte blob") { db in
            try insertValidEntry(db: db, assetID: try fetchOnlyAssetID(from: database), hash: Data(repeating: 0x01, count: 33))
        }
    }

    func testEncodedSHA256TextThirtyTwoCharsRejected() throws {
        let database = try seededDatabaseWithAsset()
        assertInsertFails(database, label: "text sha") { db in
            try db.execute(
                sql: """
                INSERT INTO derived_image_cache_entry (
                    id, asset_id, content_revision, representation_version, variant,
                    storage_format, pixel_width, pixel_height, byte_size, encoded_sha256,
                    created_at_ms, last_accessed_at_ms
                ) VALUES (?, ?, 1, 1, 'gridSmall', 'jpeg', 256, 256, 1, ?, 0, 0)
                """,
                arguments: [UUID().uuidString.lowercased(), try fetchOnlyAssetID(from: database), String(repeating: "a", count: 32)]
            )
        }
    }

    func testCreatedAtMsZeroAcceptedAndNegativeOneRejected() throws {
        let database = try seededDatabaseWithAsset()
        let assetID = try fetchOnlyAssetID(from: database)
        try insertValidEntry(database: database, assetID: assetID, createdAtMs: 0, lastAccessedAtMs: 0)
        assertInsertFails(database, label: "created_at_ms -1") { db in
            try insertValidEntry(
                db: db,
                assetID: assetID,
                variant: "gridRegular",
                pixelWidth: 512,
                pixelHeight: 512,
                createdAtMs: -1,
                lastAccessedAtMs: 0
            )
        }
    }

    func testLastAccessedAtMsZeroAcceptedAndNegativeOneRejected() throws {
        let database = try seededDatabaseWithAsset()
        let assetID = try fetchOnlyAssetID(from: database)
        try insertValidEntry(
            database: database,
            assetID: assetID,
            variant: "gridRegular",
            pixelWidth: 512,
            pixelHeight: 512,
            createdAtMs: 0,
            lastAccessedAtMs: 0
        )
        assertInsertFails(database, label: "last_accessed_at_ms -1") { db in
            try insertValidEntry(
                db: db,
                assetID: assetID,
                variant: "preview",
                pixelWidth: 1024,
                pixelHeight: 768,
                createdAtMs: 0,
                lastAccessedAtMs: -1
            )
        }
    }

    // MARK: - 5. Uniqueness, coexistence, cascade

    func testDuplicatePrimaryKeyRejected() throws {
        let database = try seededDatabaseWithAsset()
        let assetID = try fetchOnlyAssetID(from: database)
        let entryID = UUID().uuidString.lowercased()
        try insertValidEntry(database: database, id: entryID, assetID: assetID)
        assertInsertFails(database, label: "duplicate id") { db in
            try insertValidEntry(
                db: db,
                id: entryID,
                assetID: assetID,
                variant: "gridRegular",
                pixelWidth: 512,
                pixelHeight: 512
            )
        }
    }

    func testDuplicateCacheKeyRejected() throws {
        let database = try seededDatabaseWithAsset()
        let assetID = try fetchOnlyAssetID(from: database)
        try insertValidEntry(database: database, assetID: assetID)
        assertInsertFails(database, label: "duplicate cache key") { db in
            try insertValidEntry(db: db, id: UUID().uuidString.lowercased(), assetID: assetID)
        }
    }

    func testDifferentContentRevisionRepresentationVersionAndVariantAllowed() throws {
        let database = try seededDatabaseWithAsset()
        let assetID = try fetchOnlyAssetID(from: database)
        try insertValidEntry(database: database, assetID: assetID, contentRevision: 1, variant: "gridSmall")
        try insertValidEntry(
            database: database,
            assetID: assetID,
            contentRevision: 2,
            variant: "gridSmall",
            pixelWidth: 256,
            pixelHeight: 256
        )
        try insertValidEntry(
            database: database,
            assetID: assetID,
            contentRevision: 1,
            representationVersion: 2,
            variant: "gridSmall",
            pixelWidth: 256,
            pixelHeight: 256
        )
        try insertValidEntry(
            database: database,
            assetID: assetID,
            contentRevision: 1,
            representationVersion: 1,
            variant: "gridRegular",
            pixelWidth: 512,
            pixelHeight: 512
        )
        let count = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM derived_image_cache_entry") ?? 0
        }
        XCTAssertEqual(count, 4)
    }

    func testAssetDeleteCascadesCacheEntry() throws {
        let database = try seededDatabaseWithAsset()
        let assetID = try fetchOnlyAssetID(from: database)
        try insertValidEntry(database: database, assetID: assetID)
        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM asset WHERE id = ?", arguments: [assetID])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM derived_image_cache_entry") ?? -1, 0)
        }
    }

    func testSourceDeleteRestrictedPreservesSourceAssetAndCacheEntry() throws {
        let database = try seededDatabaseWithAsset()
        let assetID = try fetchOnlyAssetID(from: database)
        let sourceID = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT source_id FROM asset WHERE id = ?", arguments: [assetID])!
        }
        try insertValidEntry(database: database, assetID: assetID)
        assertInsertFails(database, label: "source delete restricted") { db in
            try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [sourceID])
        }
        try database.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") ?? 0, 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0, 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM derived_image_cache_entry") ?? 0, 1)
        }
    }

    // MARK: - 6. v001/v002 DDL unchanged

    func testV001AndV002DDLUnchangedAfterV003() throws {
        let v002URL = try makeTempDatabaseURL()
        let v002Pool = try openV002OnlyPool(at: v002URL)

        let fullURL = try makeTempDatabaseURL()
        let full = try CatalogDatabase.open(at: fullURL)
        let laterTables = Set([
            "catalog_scope", "feature", "tag_model_revision", "tag_model_sample", "tag_model",
            "prediction", "personal_suggestion_model", "personal_suggestion_tag",
            "personal_prediction", "ontology_pack", "ontology_concept", "ontology_edge",
            "standard_model_revision", "standard_tag_binding",
            "standard_prediction",
            "training_run",
        ])
        for table in CatalogSchemaExpectations.businessTables
            where table != "derived_image_cache_entry" && !laterTables.contains(table)
        {
            let baselineSQL = try v002Pool.read { db in
                try String.fetchOne(db, sql: "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?", arguments: [table])
            }
            let currentSQL = try full.pool.read { db in
                try String.fetchOne(db, sql: "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?", arguments: [table])
            }
            XCTAssertEqual(currentSQL, baselineSQL, "\(table) must remain unchanged")
        }
    }

    private func seededDatabaseWithAsset() throws -> CatalogDatabase {
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        let repository = CatalogRepository(database: database)
        try repository.createSourceWithAsset(
            NewSourceWithAssetInput(
                sourceID: UUID(),
                sourceKind: .folder,
                displayName: "Folder",
                bookmark: DatabaseTestSupport.folderBookmark(),
                assetID: UUID(),
                locatorKind: .file,
                relativePath: "photo.jpg",
                photosLocalIdentifier: nil,
                mediaType: "public.jpeg",
                timestampMs: DatabaseTestSupport.timestampMs
            )
        )
        return database
    }
}

// MARK: - Local helpers

private struct V002SentinelFacts: Equatable {
    let sourceID: UUID
    let assetID: UUID
    let tagID: UUID
    let jobID: UUID
    let sourceDisplayName: String
    let assetRelativePath: String
    let tagName: String
    let jobKind: String
}

private func openV002OnlyPool(at url: URL) throws -> DatabasePool {
    var config = Configuration()
    config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
    let pool = try DatabasePool(path: url.path, configuration: config)
    try DatabaseTestSupport.makeV002OnlyMigrator().migrate(pool)
    return pool
}

@discardableResult
private func seedV002SentinelFacts(in pool: DatabasePool) throws -> V002SentinelFacts {
    let sourceID = UUID()
    let assetID = UUID()
    let tagID = UUID()
    let jobID = UUID()
    let sourceDisplayName = "Sentinel"
    let assetRelativePath = "sentinel/photo.jpg"
    let tagName = "SentinelTag"
    let jobKind = "test.sentinel"

    try pool.write { db in
        try db.execute(
            sql: """
            INSERT INTO source (
                id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                state, created_at_ms, updated_at_ms
            ) VALUES (?, 'folder', ?, ?, 0, 0, 'active', ?, ?)
            """,
            arguments: [
                sourceID.uuidString.lowercased(),
                sourceDisplayName,
                DatabaseTestSupport.folderBookmark(),
                DatabaseTestSupport.timestampMs,
                DatabaseTestSupport.timestampMs,
            ]
        )
        try db.execute(
            sql: """
            INSERT INTO asset (
                id, source_id, locator_kind, relative_path, photos_local_identifier,
                locator_state, media_type, content_revision, availability,
                record_created_at_ms, record_updated_at_ms, file_name
            ) VALUES (?, ?, 'file', ?, NULL, 'current', 'public.jpeg', 1, 'available', ?, ?, 'sentinel.jpg')
            """,
            arguments: [
                assetID.uuidString.lowercased(),
                sourceID.uuidString.lowercased(),
                assetRelativePath,
                DatabaseTestSupport.timestampMs,
                DatabaseTestSupport.timestampMs,
            ]
        )
        try db.execute(
            sql: """
            INSERT INTO file_fingerprint (asset_id, size_bytes, modified_at_ns, resource_id, sha256)
            VALUES (?, 1234, 5678, ?, NULL)
            """,
            arguments: [assetID.uuidString.lowercased(), Data([0x01, 0x02])]
        )
        try db.execute(
            sql: """
            INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
            VALUES (?, ?, 'sentineltag', 'active', ?, ?)
            """,
            arguments: [tagID.uuidString.lowercased(), tagName, DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs]
        )
        try db.execute(
            sql: """
            INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
            VALUES (?, ?, 'accepted', ?)
            """,
            arguments: [assetID.uuidString.lowercased(), tagID.uuidString.lowercased(), DatabaseTestSupport.timestampMs]
        )
        try db.execute(
            sql: """
            INSERT INTO job (
                id, kind, payload_version, payload, state, control_request, priority,
                attempts, max_attempts, not_before_ms, progress_completed, created_at_ms, updated_at_ms
            ) VALUES (?, ?, 1, ?, 'pending', 'none', 0, 0, 3, ?, 0, ?, ?)
            """,
            arguments: [
                jobID.uuidString.lowercased(),
                jobKind,
                Data("sentinel-payload".utf8),
                DatabaseTestSupport.timestampMs,
                DatabaseTestSupport.timestampMs,
                DatabaseTestSupport.timestampMs,
            ]
        )
    }

    return V002SentinelFacts(
        sourceID: sourceID,
        assetID: assetID,
        tagID: tagID,
        jobID: jobID,
        sourceDisplayName: sourceDisplayName,
        assetRelativePath: assetRelativePath,
        tagName: tagName,
        jobKind: jobKind
    )
}

private func assertV002SentinelFactsUnchanged(in db: Database, sentinel: V002SentinelFacts) throws {
    let sourceDisplayName: String? = try String.fetchOne(
        db,
        sql: "SELECT display_name FROM source WHERE id = ?",
        arguments: [sentinel.sourceID.uuidString.lowercased()]
    )
    XCTAssertEqual(sourceDisplayName, sentinel.sourceDisplayName)

    let relativePath: String? = try String.fetchOne(
        db,
        sql: "SELECT relative_path FROM asset WHERE id = ?",
        arguments: [sentinel.assetID.uuidString.lowercased()]
    )
    XCTAssertEqual(relativePath, sentinel.assetRelativePath)

    let fingerprintSize: Int64? = try Int64.fetchOne(
        db,
        sql: "SELECT size_bytes FROM file_fingerprint WHERE asset_id = ?",
        arguments: [sentinel.assetID.uuidString.lowercased()]
    )
    XCTAssertEqual(fingerprintSize, 1234)

    let tagName: String? = try String.fetchOne(
        db,
        sql: "SELECT name FROM tag WHERE id = ?",
        arguments: [sentinel.tagID.uuidString.lowercased()]
    )
    XCTAssertEqual(tagName, sentinel.tagName)

    let jobKind: String? = try String.fetchOne(
        db,
        sql: "SELECT kind FROM job WHERE id = ?",
        arguments: [sentinel.jobID.uuidString.lowercased()]
    )
    XCTAssertEqual(jobKind, sentinel.jobKind)

    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") ?? 0, 1)
    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0, 1)
    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file_fingerprint") ?? 0, 1)
    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag") ?? 0, 1)
    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tag_decision") ?? 0, 1)
    XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job") ?? 0, 1)
}

private func validHash() -> Data {
    Data(repeating: 0xAB, count: 32)
}

private func fetchOnlyAssetID(from database: CatalogDatabase) throws -> String {
    try database.pool.read { db in
        try String.fetchOne(db, sql: "SELECT id FROM asset LIMIT 1")!
    }
}

private func insertValidEntry(
    database: CatalogDatabase,
    id: String = UUID().uuidString.lowercased(),
    assetID: String,
    contentRevision: Int = 1,
    representationVersion: Int = 1,
    variant: String = "gridSmall",
    storageFormat: String = "jpeg",
    pixelWidth: Int = 256,
    pixelHeight: Int = 256,
    byteSize: Int = 100,
    hash: Data = validHash(),
    createdAtMs: Int64 = 1,
    lastAccessedAtMs: Int64 = 1
) throws {
    try database.pool.write { db in
        try insertValidEntry(
            db: db,
            id: id,
            assetID: assetID,
            contentRevision: contentRevision,
            representationVersion: representationVersion,
            variant: variant,
            storageFormat: storageFormat,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            byteSize: byteSize,
            hash: hash,
            createdAtMs: createdAtMs,
            lastAccessedAtMs: lastAccessedAtMs
        )
    }
}

private func insertValidEntry(
    db: Database,
    id: String = UUID().uuidString.lowercased(),
    assetID: String,
    contentRevision: Int = 1,
    representationVersion: Int = 1,
    variant: String = "gridSmall",
    storageFormat: String = "jpeg",
    pixelWidth: Int = 256,
    pixelHeight: Int = 256,
    byteSize: Int = 100,
    hash: Data = validHash(),
    createdAtMs: Int64 = 1,
    lastAccessedAtMs: Int64 = 1
) throws {
    try db.execute(
        sql: """
        INSERT INTO derived_image_cache_entry (
            id, asset_id, content_revision, representation_version, variant,
            storage_format, pixel_width, pixel_height, byte_size, encoded_sha256,
            created_at_ms, last_accessed_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [
            id,
            assetID,
            contentRevision,
            representationVersion,
            variant,
            storageFormat,
            pixelWidth,
            pixelHeight,
            byteSize,
            hash,
            createdAtMs,
            lastAccessedAtMs,
        ]
    )
}

private func assertInsertFails(
    _ database: CatalogDatabase,
    label: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    insert: (Database) throws -> Void
) {
    var didThrow = false
    do {
        try database.pool.write { db in
            try insert(db)
        }
    } catch {
        didThrow = true
    }
    XCTAssertTrue(didThrow, "Expected rejection for \(label)", file: file, line: line)
}
