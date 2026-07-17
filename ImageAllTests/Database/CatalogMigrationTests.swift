import GRDB
import XCTest
@testable import ImageAll

final class CatalogMigrationTests: XCTestCase {
    func testFreshDatabaseAppliesV001Once() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        XCTAssertEqual(
            try database.appliedMigrationIDs(),
            CatalogMigrationID.knownOrdered
        )
    }

    func testReopeningDatabaseIsIdempotentAndPreservesData() throws {
        let url = try makeTempDatabaseURL()
        let sourceID = UUID()
        let assetID = UUID()

        let first = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: first)
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(
            repository: repository,
            sourceID: sourceID,
            assetID: assetID
        )

        let second = try CatalogDatabase.open(at: url)
        XCTAssertEqual(
            try second.appliedMigrationIDs(),
            CatalogMigrationID.knownOrdered
        )

        let count = try second.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    func testCurrentSchemaMaintainsTrigramAssetSearchIndex() throws {
        let url = try makeTempDatabaseURL()
        let sourceID = UUID()
        let assetID = UUID()
        let database = try CatalogDatabase.open(at: url)
        let repository = CatalogRepository(database: database)
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(
            repository: repository,
            sourceID: sourceID,
            assetID: assetID
        )

        func matchedAssetIDs(_ query: String) throws -> [String] {
            try database.pool.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT asset.id
                    FROM asset_search
                    INNER JOIN asset ON asset.rowid = asset_search.rowid
                    WHERE asset_search MATCH ?
                    """,
                    arguments: [query]
                )
            }
        }

        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET file_name = 'needle-file.jpg', relative_path = 'archive/needle-file.jpg' WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(try matchedAssetIDs("\"needle-file\""), [assetID.uuidString.lowercased()])

        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET file_name = 'renamed-photo.jpg', relative_path = 'archive/renamed-photo.jpg' WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }
        XCTAssertTrue(try matchedAssetIDs("\"needle-file\"").isEmpty)
        XCTAssertEqual(try matchedAssetIDs("\"renamed-photo\""), [assetID.uuidString.lowercased()])

        try database.pool.write { db in
            try db.execute(sql: "DELETE FROM asset WHERE id = ?", arguments: [assetID.uuidString.lowercased()])
        }
        XCTAssertTrue(try matchedAssetIDs("\"renamed-photo\"").isEmpty)
        XCTAssertEqual(CatalogMigrationID.knownOrdered.last, "v006_add_asset_text_search")
    }

    func testV006BackfillsAssetTextFromExistingV005Database() throws {
        let url = try makeTempDatabaseURL()
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        try DatabaseTestSupport.makeV005OnlyMigrator().migrate(pool)

        let database = CatalogDatabase(pool: pool)
        let sourceID = UUID()
        let assetID = UUID()
        try DatabaseTestSupport.makeFolderSourceWithFileAsset(
            repository: CatalogRepository(database: database),
            sourceID: sourceID,
            assetID: assetID
        )
        try pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET file_name = 'before-upgrade.jpg', relative_path = 'archive/before-upgrade.jpg' WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }

        try CatalogDatabase.makeMigrator().migrate(pool)

        let matchedIDs = try pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT asset.id
                FROM asset_search
                INNER JOIN asset ON asset.rowid = asset_search.rowid
                WHERE asset_search MATCH '"before-upgrade"'
                """
            )
        }
        XCTAssertEqual(matchedIDs, [assetID.uuidString.lowercased()])
    }

    func testUnknownFutureMigrationIsRejected() throws {
        let url = try makeTempDatabaseURL()
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let seedPool = try DatabasePool(path: url.path, configuration: config)
        try seedPool.write { db in
            try db.execute(
                sql: """
                CREATE TABLE grdb_migrations (
                    identifier TEXT NOT NULL PRIMARY KEY
                )
                """
            )
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: ["v999_future_migration"]
            )
        }

        XCTAssertThrowsError(try CatalogDatabase.open(at: url)) { error in
            guard case let CatalogDatabaseError.futureSchema(applied, unknown) = error else {
                return XCTFail("Expected futureSchema, got \(error)")
            }
            XCTAssertEqual(applied, ["v999_future_migration"])
            XCTAssertEqual(unknown, ["v999_future_migration"])
        }

        try seedPool.read { db in
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
            XCTAssertEqual(applied, ["v999_future_migration"])
            let tables = try DatabaseTestSupport.tableNames(db)
            XCTAssertEqual(tables, [], "v001 must not be applied when future migration is present")
        }
    }

    func testFailedMigrationRollsBackDDLChanges() throws {
        let url = try makeTempDatabaseURL()
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("test_fail_after_ddl") { db in
            try db.execute(sql: "CREATE TABLE test_fail_marker (id INTEGER PRIMARY KEY) STRICT")
            throw TestMigrationFailure.intentional
        }

        XCTAssertThrowsError(try migrator.migrate(pool))

        try pool.read { db in
            let tables = try DatabaseTestSupport.tableNames(db)
            XCTAssertFalse(tables.contains("test_fail_marker"))
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertFalse(applied.contains("test_fail_after_ddl"))
        }
    }

    func testSchemaDumpEvidence() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        let dump = try database.pool.read { db in
            try DatabaseTestSupport.schemaDump(db)
        }

        XCTAssertTrue(dump.contains("applied_migrations=v001_create_catalog_core, v002_add_stage_1_catalog_query_support"))
        XCTAssertTrue(dump.contains("journal_mode=wal"))
        XCTAssertTrue(dump.contains("foreign_keys=1"))
        XCTAssertTrue(dump.contains("quick_check=ok"))
        XCTAssertTrue(dump.contains("table:source"))
        XCTAssertTrue(dump.contains("CREATE TABLE source"))
        XCTAssertTrue(dump.contains("index:asset_current_file_locator_uq"))
        XCTAssertTrue(dump.contains("<null>"))
    }
}

private enum TestMigrationFailure: Error {
    case intentional
}
