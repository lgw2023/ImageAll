import GRDB
import XCTest
@testable import ImageAll

final class CatalogSchemaTests: XCTestCase {
    func testBusinessTablesAreStrict() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        try database.pool.read { db in
            let tables = try DatabaseTestSupport.tableNames(db)
            XCTAssertEqual(tables.sorted(), CatalogSchemaExpectations.businessTables)

            for table in CatalogSchemaExpectations.businessTables {
                XCTAssertTrue(
                    try DatabaseTestSupport.isStrictTable(db, table: table),
                    "\(table) must be STRICT"
                )
            }
        }
    }

    func testNoExtraneousBusinessSchemaObjects() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        try database.pool.read { db in
            let tables = try DatabaseTestSupport.tableNames(db)
            XCTAssertEqual(Set(tables), Set(CatalogSchemaExpectations.businessTables))

            let allIndexes = try DatabaseTestSupport.fetchStrings(
                db,
                sql: "SELECT name FROM sqlite_schema WHERE type = 'index' ORDER BY name"
            )
            let businessIndexes = Set(CatalogSchemaExpectations.businessIndexes)
            let autoIndexes = allIndexes.filter { $0.hasPrefix("sqlite_autoindex_") }
            let namedIndexes = allIndexes.filter { !$0.hasPrefix("sqlite_autoindex_") }
            XCTAssertEqual(
                Set(namedIndexes),
                businessIndexes,
                "Unexpected named indexes: \(namedIndexes)"
            )
            XCTAssertFalse(autoIndexes.isEmpty, "SQLite auto indexes must be present for PRIMARY KEY constraints")
        }
    }

    func testBusinessTableColumnsDefaultsAndPrimaryKeysMatchSpec() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        try database.pool.read { db in
            for (table, expectedColumns) in CatalogSchemaExpectations.columnsByTable {
                let actualColumns = try DatabaseTestSupport.tableInfo(db, table: table)
                XCTAssertEqual(actualColumns.count, expectedColumns.count, "Column count mismatch for \(table)")

                for expected in expectedColumns {
                    guard let actual = actualColumns.first(where: { $0.name == expected.name }) else {
                        return XCTFail("Missing column \(expected.name) on \(table)")
                    }
                    XCTAssertEqual(actual.type, expected.type, "\(table).\(expected.name) type")
                    XCTAssertEqual(actual.notNull, expected.notNull, "\(table).\(expected.name) NOT NULL")
                    XCTAssertEqual(actual.defaultValue, expected.defaultValue, "\(table).\(expected.name) default")
                    XCTAssertEqual(actual.pk, expected.primaryKeyOrder, "\(table).\(expected.name) PK order")
                }
            }
        }
    }

    func testBusinessTableForeignKeysMatchSpec() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        try database.pool.read { db in
            for (table, expectedForeignKeys) in CatalogSchemaExpectations.foreignKeysByTable {
                let actualForeignKeys = try DatabaseTestSupport.foreignKeyList(db, table: table)
                XCTAssertEqual(actualForeignKeys.count, expectedForeignKeys.count, "FK count for \(table)")

                for expected in expectedForeignKeys {
                    XCTAssertTrue(
                        actualForeignKeys.contains {
                            $0.from == expected.from
                                && $0.toTable == expected.toTable
                                && $0.to == expected.to
                                && $0.onDelete == expected.onDelete
                        },
                        "Missing FK \(table).\(expected.from) -> \(expected.toTable).\(expected.to)"
                    )
                }
            }
        }
    }

    func testBusinessIndexesMatchSpec() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        try database.pool.read { db in
            let indexNames = try DatabaseTestSupport.indexNames(db)
            for expected in CatalogSchemaExpectations.indexes {
                XCTAssertTrue(indexNames.contains(expected.name), "Missing index \(expected.name)")

                let columns = try DatabaseTestSupport.indexXInfo(db, index: expected.name)
                let keyColumns = columns.filter(\.key).compactMap(\.name)
                XCTAssertEqual(keyColumns, expected.columns, "Index columns for \(expected.name)")

                for (column, collation) in expected.collationByColumn {
                    let entry = columns.first { $0.name == column }
                    XCTAssertEqual(entry?.coll, collation, "Collation for \(expected.name).\(column)")
                }

                for column in expected.descendingColumns {
                    let entry = columns.first { $0.name == column }
                    XCTAssertEqual(entry?.desc, true, "\(expected.name).\(column) must be DESC")
                }

                let ddl = try String.fetchOne(
                    db,
                    sql: "SELECT sql FROM sqlite_schema WHERE type = 'index' AND name = ?",
                    arguments: [expected.name]
                )
                XCTAssertNotNil(ddl, "Index DDL must exist for \(expected.name)")
                for fragment in expected.partialPredicateFragments {
                    XCTAssertTrue(ddl?.contains(fragment) == true, "\(expected.name) must contain \(fragment)")
                }
            }
        }
    }

    func testSchemaDumpListsTypeNameAndRawSQLIncludingAutoObjects() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        let dump = try database.pool.read { db in
            try DatabaseTestSupport.schemaDump(db)
        }

        XCTAssertTrue(dump.contains("applied_migrations=v001_create_catalog_core"))
        XCTAssertTrue(dump.contains("journal_mode=wal"))
        XCTAssertTrue(dump.contains("foreign_keys=1"))
        XCTAssertTrue(dump.contains("quick_check=ok"))

        for table in CatalogSchemaExpectations.businessTables {
            XCTAssertTrue(dump.contains("table:\(table)"))
            XCTAssertTrue(dump.contains("CREATE TABLE \(table)"))
        }

        XCTAssertTrue(dump.contains("table:grdb_migrations"))

        for index in CatalogSchemaExpectations.businessIndexes {
            XCTAssertTrue(dump.contains("index:\(index)"))
            XCTAssertTrue(dump.contains("CREATE"))
        }

        XCTAssertTrue(dump.contains("<null>"), "Dump must include sql=NULL auto objects")
        XCTAssertTrue(dump.contains("index:sqlite_autoindex_"))
    }
}
