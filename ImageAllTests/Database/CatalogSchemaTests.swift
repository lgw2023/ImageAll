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
}
