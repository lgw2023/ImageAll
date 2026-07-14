import GRDB
import XCTest
@testable import ImageAll

final class CatalogMigrationTests: XCTestCase {
    func testFreshDatabaseAppliesV001Once() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        XCTAssertEqual(
            try database.appliedMigrationIDs(),
            [CatalogMigrationID.v001CreateCatalogCore]
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
            [CatalogMigrationID.v001CreateCatalogCore]
        )

        let count = try second.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset") ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    func testUnknownFutureMigrationIsRejected() throws {
        let url = try makeTempDatabaseURL()
        _ = try CatalogDatabase.open(at: url)

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: ["v999_future_migration"]
            )
        }

        XCTAssertThrowsError(try CatalogDatabase.open(at: url)) { error in
            guard case let CatalogDatabaseError.futureSchema(applied, unknown) = error else {
                return XCTFail("Expected futureSchema, got \(error)")
            }
            XCTAssertTrue(applied.contains("v999_future_migration"))
            XCTAssertEqual(unknown, ["v999_future_migration"])
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

        XCTAssertTrue(dump.contains("applied_migrations=v001_create_catalog_core"))
        XCTAssertTrue(dump.contains("journal_mode=wal"))
        XCTAssertTrue(dump.contains("foreign_keys=1"))
        XCTAssertTrue(dump.contains("quick_check=ok"))
        XCTAssertTrue(dump.contains("CREATE TABLE source"))
        XCTAssertTrue(dump.contains("CREATE UNIQUE INDEX asset_current_file_locator_uq"))
    }
}

private enum TestMigrationFailure: Error {
    case intentional
}
