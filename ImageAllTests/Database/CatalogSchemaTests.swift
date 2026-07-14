import GRDB
import XCTest
@testable import ImageAll

final class CatalogSchemaTests: XCTestCase {
    private let businessTables = [
        "asset",
        "asset_tag_decision",
        "file_fingerprint",
        "job",
        "source",
        "tag",
    ]

    private let businessIndexes = [
        "asset_current_file_locator_uq",
        "asset_current_photos_locator_uq",
        "asset_source_availability_idx",
        "decision_tag_idx",
        "job_active_coalescing_uq",
        "job_queue_idx",
        "tag_normalized_name_uq",
    ]

    func testBusinessTablesAreStrict() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        try database.pool.read { db in
            let tables = try DatabaseTestSupport.tableNames(db)
            XCTAssertEqual(tables.sorted(), businessTables)

            for table in businessTables {
                XCTAssertTrue(try DatabaseTestSupport.isStrictTable(db, table: table), "\(table) must be STRICT")
            }
        }
    }

    func testBusinessIndexesExistWithExpectedNames() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        try database.pool.read { db in
            let indexes = try DatabaseTestSupport.indexNames(db)
            for index in businessIndexes {
                XCTAssertTrue(indexes.contains(index), "Missing index \(index)")
            }
        }
    }

    func testPartialUniquePredicatesArePresent() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        try database.pool.read { db in
            let fileDDL = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_schema WHERE name = 'asset_current_file_locator_uq'"
            )
            XCTAssertTrue(fileDDL?.contains("locator_kind = 'file'") == true)
            XCTAssertTrue(fileDDL?.contains("locator_state = 'current'") == true)

            let coalescingDDL = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_schema WHERE name = 'job_active_coalescing_uq'"
            )
            XCTAssertTrue(coalescingDDL?.contains("coalescing_key IS NOT NULL") == true)
            XCTAssertTrue(coalescingDDL?.contains("'pending'") == true)
            XCTAssertTrue(coalescingDDL?.contains("'retryableFailed'") == true)
        }
    }

    func testSchemaIntrospectionUsesSQLiteMetadata() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        try database.pool.read { db in
            for table in businessTables {
                let info = try DatabaseTestSupport.tableInfo(db, table: table)
                XCTAssertFalse(info.isEmpty, "PRAGMA table_info must return columns for \(table)")
                XCTAssertTrue(try DatabaseTestSupport.isStrictTable(db, table: table))
            }

            let assetFKs = try DatabaseTestSupport.foreignKeyList(db, table: "asset")
            XCTAssertTrue(assetFKs.contains { $0.from == "source_id" && $0.toTable == "source" && $0.onDelete == "RESTRICT" })

            let fingerprintFKs = try DatabaseTestSupport.foreignKeyList(db, table: "file_fingerprint")
            XCTAssertTrue(fingerprintFKs.contains { $0.from == "asset_id" && $0.toTable == "asset" && $0.onDelete == "CASCADE" })

            let jobFKs = try DatabaseTestSupport.foreignKeyList(db, table: "job")
            XCTAssertTrue(jobFKs.contains { $0.from == "source_id" && $0.toTable == "source" && $0.onDelete == "SET NULL" })

            let tagIndexColumns = try DatabaseTestSupport.indexXInfo(db, index: "tag_normalized_name_uq")
            XCTAssertTrue(tagIndexColumns.contains { $0.name == "normalized_name" && $0.coll == "BINARY" })

            let queueIndexColumns = try DatabaseTestSupport.indexXInfo(db, index: "job_queue_idx")
            let queueColumnNames = queueIndexColumns.filter(\.key).compactMap(\.name)
            XCTAssertEqual(queueColumnNames, ["state", "priority", "not_before_ms", "id"])

            let sqliteObjects = try DatabaseTestSupport.fetchStrings(
                db,
                sql: """
                SELECT type || ':' || name FROM sqlite_schema
                WHERE name NOT LIKE 'sqlite_%'
                ORDER BY type, name
                """
            )
            XCTAssertTrue(sqliteObjects.contains("table:source"))
            XCTAssertTrue(sqliteObjects.contains("table:grdb_migrations"))
            for index in businessIndexes {
                XCTAssertTrue(sqliteObjects.contains("index:\(index)"), "Missing index object \(index)")
            }
        }
    }

    func testSchemaDumpIncludesRawSQLiteSchema() throws {
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
        XCTAssertTrue(dump.contains("CREATE TABLE asset"))
        XCTAssertTrue(dump.contains("CREATE TABLE file_fingerprint"))
        XCTAssertTrue(dump.contains("CREATE TABLE tag"))
        XCTAssertTrue(dump.contains("CREATE TABLE asset_tag_decision"))
        XCTAssertTrue(dump.contains("CREATE TABLE job"))
        XCTAssertTrue(dump.contains("CREATE UNIQUE INDEX asset_current_file_locator_uq"))
        XCTAssertTrue(dump.contains("CREATE UNIQUE INDEX asset_current_photos_locator_uq"))
        XCTAssertTrue(dump.contains("CREATE INDEX asset_source_availability_idx"))
        XCTAssertTrue(dump.contains("CREATE UNIQUE INDEX tag_normalized_name_uq"))
        XCTAssertTrue(dump.contains("CREATE INDEX decision_tag_idx"))
        XCTAssertTrue(dump.contains("CREATE INDEX job_queue_idx"))
        XCTAssertTrue(dump.contains("CREATE UNIQUE INDEX job_active_coalescing_uq"))
    }
}
