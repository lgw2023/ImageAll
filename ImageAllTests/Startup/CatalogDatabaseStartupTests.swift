import GRDB
import XCTest
@testable import ImageAll

final class CatalogDatabaseStartupTests: XCTestCase {
    func testOpenCurrentSchemaClosesPoolWhenValidationFails() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        try StartupTestSupport.seedFutureSchemaDatabase(at: paths.catalogDatabaseURL)

        XCTAssertThrowsError(try CatalogDatabase.openCurrentSchema(at: paths.catalogDatabaseURL)) { error in
            guard case CatalogDatabaseError.futureSchema = error else {
                return XCTFail("Expected futureSchema, got \(error)")
            }
        }

        let inspection = try CatalogDatabase.inspectFormalDatabase(at: paths.catalogDatabaseURL)
        if case .unsupportedSchema = inspection {
            // Pool from failed openCurrentSchema was closed; formal file remains inspectable.
        } else {
            XCTFail("Expected unsupportedSchema inspection after failed open")
        }
    }

    func testOpenCurrentSchemaLeavesPoolUsableOnSuccess() throws {
        let root = try StartupTestSupport.makeTempRoot(testCase: self)
        let paths = try StartupTestSupport.resolvedPaths(root: root)
        _ = try StartupTestSupport.seedCurrentSchemaDatabase(at: paths.catalogDatabaseURL)

        let database = try CatalogDatabase.openCurrentSchema(at: paths.catalogDatabaseURL)
        defer {
            try? database.pool.close()
        }

        let migrations = try database.appliedMigrationIDs()
        XCTAssertEqual(migrations, CatalogMigrationID.knownOrdered)
    }
}
