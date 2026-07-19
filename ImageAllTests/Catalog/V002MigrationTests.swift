import GRDB
import XCTest
@testable import ImageAll

final class V002MigrationTests: XCTestCase {
    func testFreshDatabaseAppliesV001ThenV002() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        XCTAssertEqual(
            try database.appliedMigrationIDs(),
            CatalogMigrationID.knownOrdered
        )
    }

    func testReopeningAfterV002IsIdempotent() throws {
        let url = try makeTempDatabaseURL()
        _ = try CatalogDatabase.open(at: url)
        let second = try CatalogDatabase.open(at: url)
        XCTAssertEqual(try second.appliedMigrationIDs(), CatalogMigrationID.knownOrdered)
    }

    func testV001SentinelFactsSurviveUpgrade() throws {
        let url = try makeTempDatabaseURL()
        let v001Database = try CatalogQueryTestSupport.openV001OnlyDatabase(at: url)
        let sourceID = UUID()
        let assetID = UUID()
        let tagID = UUID()
        let repository = CatalogRepository(database: v001Database)

        try repository.createSourceWithAsset(
            NewSourceWithAssetInput(
                sourceID: sourceID,
                sourceKind: .folder,
                displayName: "Sentinel",
                bookmark: DatabaseTestSupport.folderBookmark(),
                assetID: assetID,
                locatorKind: .file,
                relativePath: "sentinel/photo.jpg",
                photosLocalIdentifier: nil,
                mediaType: "public.jpeg",
                timestampMs: DatabaseTestSupport.timestampMs
            )
        )

        try v001Database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES (?, 'SentinelTag', 'sentineltag', 'active', ?, ?)
                """,
                arguments: [tagID.uuidString.lowercased(), DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs]
            )
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'accepted', ?)
                """,
                arguments: [assetID.uuidString.lowercased(), tagID.uuidString.lowercased(), DatabaseTestSupport.timestampMs]
            )
        }

        let upgraded = try CatalogDatabase.open(at: url)
        try upgraded.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") ?? 0, 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0, 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag") ?? 0, 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_tag_decision") ?? 0, 1)
            let fileName: String? = try String.fetchOne(
                db,
                sql: "SELECT file_name FROM asset WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
            XCTAssertNil(fileName)
        }
    }

    func testFileNameValidAndInvalidValues() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        try repository.createSourceWithAsset(
            NewSourceWithAssetInput(
                sourceID: UUID(),
                sourceKind: .folder,
                displayName: "Folder",
                bookmark: DatabaseTestSupport.folderBookmark(),
                assetID: UUID(),
                locatorKind: .file,
                relativePath: "valid/photo.jpg",
                photosLocalIdentifier: nil,
                mediaType: "public.jpeg",
                timestampMs: DatabaseTestSupport.timestampMs
            )
        )

        let assetID = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM asset LIMIT 1")!
        }

        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET file_name = 'photo.jpg' WHERE id = ?",
                arguments: [assetID]
            )
        }

        let updated: String? = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT file_name FROM asset WHERE id = ?", arguments: [assetID])
        }
        XCTAssertEqual(updated, "photo.jpg")

        for invalid in ["", ".", "..", "bad/name"] {
            var didThrow = false
            do {
                try database.pool.write { db in
                    try db.execute(
                        sql: "UPDATE asset SET file_name = ? WHERE id = ?",
                        arguments: [invalid, assetID]
                    )
                }
            } catch {
                didThrow = true
            }
            XCTAssertTrue(didThrow, "Expected rejection for \(invalid.debugDescription)")
        }

        var rejectedNUL = false
        do {
            try database.pool.write { db in
                try db.execute(
                    sql: "UPDATE asset SET file_name = 'nul' || char(0) || 'byte' WHERE id = ?",
                    arguments: [assetID]
                )
            }
        } catch {
            rejectedNUL = true
        }
        XCTAssertTrue(rejectedNUL, "Expected rejection for embedded NUL byte in file_name")
    }

    func testSixV002IndexesExistViaIntrospection() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let expected = Set([
            "asset_current_time_idx",
            "asset_current_source_time_idx",
            "asset_current_file_name_idx",
            "asset_generation_missing_idx",
            "file_fingerprint_resource_id_idx",
            "file_fingerprint_sha256_idx",
        ])

        try database.pool.read { db in
            let names = try DatabaseTestSupport.indexNames(db)
            XCTAssertTrue(expected.isSubset(of: Set(names)))
            for indexName in expected {
                let ddl = try String.fetchOne(
                    db,
                    sql: "SELECT sql FROM sqlite_schema WHERE type = 'index' AND name = ?",
                    arguments: [indexName]
                )
                XCTAssertNotNil(ddl)
            }
        }
    }

    func testV001TableDDLRemainsUnchangedAfterV002Exists() throws {
        let v001URL = try makeTempDatabaseURL()
        let v001Only = try CatalogQueryTestSupport.openV001OnlyDatabase(at: v001URL)
        let v001EraTables = CatalogSchemaExpectations.businessTables.filter {
            ![
                "catalog_scope", "derived_image_cache_entry", "feature", "tag_model_revision",
                "tag_model_sample", "tag_model", "prediction", "personal_suggestion_model",
                "personal_suggestion_tag", "personal_prediction",
            ].contains($0)
        }
        let v001Dump = try v001Only.pool.read { db in
            try DatabaseTestSupport.schemaObjects(db)
                .filter { $0.type == "table" && v001EraTables.contains($0.name) }
                .map(\.sql)
        }

        let fullURL = try makeTempDatabaseURL()
        let full = try CatalogDatabase.open(at: fullURL)
        let fullV001Tables = try full.pool.read { db in
            try DatabaseTestSupport.schemaObjects(db)
                .filter { $0.type == "table" && $0.name != "grdb_migrations" }
                .filter { !($0.name == "asset" && $0.sql?.contains("file_name") == true) }
                .filter { CatalogSchemaExpectations.businessTables.contains($0.name) || $0.name == "grdb_migrations" }
        }

        for table in v001EraTables where table != "asset" {
            let v001SQL = try v001Only.pool.read { db in
                try String.fetchOne(db, sql: "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?", arguments: [table])
            }
            let currentSQL = try full.pool.read { db in
                try String.fetchOne(db, sql: "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?", arguments: [table])
            }
            XCTAssertEqual(currentSQL, v001SQL, "\(table) DDL must remain unchanged")
        }
        XCTAssertFalse(fullV001Tables.isEmpty)
        XCTAssertEqual(v001Dump.count, v001EraTables.count)
    }

    func testFailedV002MigrationRollsBack() throws {
        let url = try makeTempDatabaseURL()
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        let v001Migrator = DatabaseTestSupport.makeV001OnlyMigrator()
        try v001Migrator.migrate(pool)

        var failingMigrator = DatabaseTestSupport.makeV001OnlyMigrator()
        failingMigrator.registerMigration("v002_test_fail") { db in
            try db.execute(sql: "CREATE TABLE v002_fail_marker (id INTEGER PRIMARY KEY) STRICT")
            throw TestMigrationFailure.intentional
        }

        XCTAssertThrowsError(try failingMigrator.migrate(pool))
        try pool.read { db in
            let tables = try DatabaseTestSupport.tableNames(db)
            XCTAssertFalse(tables.contains("v002_fail_marker"))
        }
    }
}

private enum TestMigrationFailure: Error {
    case intentional
}
