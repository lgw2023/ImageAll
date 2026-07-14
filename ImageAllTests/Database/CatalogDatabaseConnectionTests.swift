import GRDB
import XCTest
@testable import ImageAll

final class CatalogDatabaseConnectionTests: XCTestCase {
    func testFileDatabaseUsesWALAndForeignKeysOnWriterAndReader() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        XCTAssertEqual(try database.journalMode().lowercased(), "wal")
        XCTAssertTrue(try database.foreignKeysEnabled())

        try database.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA foreign_keys"), 1)
        }

        try database.validateQuickCheck()
    }

    func testForeignKeyViolationIsRejected() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let missingSourceID = DatabaseTestSupport.lowercaseUUIDString()

        XCTAssertThrowsError(try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    media_type, record_created_at_ms, record_updated_at_ms
                ) VALUES (?, ?, 'file', 'a.jpg', NULL, 'public.jpeg', ?, ?)
                """,
                arguments: [
                    DatabaseTestSupport.lowercaseUUIDString(),
                    missingSourceID,
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        })
    }
}
