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
            let objects = try DatabaseTestSupport.schemaObjects(db)
            let objectTypes = Set(objects.map(\.type))
            XCTAssertEqual(
                objectTypes,
                Set(CatalogSchemaExpectations.allowedSchemaObjectTypes),
                "Schema must contain only tables and indexes, found: \(objectTypes)"
            )
            XCTAssertFalse(objects.contains { $0.type == "trigger" })
            XCTAssertFalse(objects.contains { $0.type == "view" })

            let tables = objects.filter { $0.type == "table" }.map(\.name).sorted()
            let expectedTables = (
                CatalogSchemaExpectations.businessTables + CatalogSchemaExpectations.infrastructureTables
            ).sorted()
            XCTAssertEqual(tables, expectedTables)

            let businessTableSet = Set(CatalogSchemaExpectations.businessTables)
            XCTAssertEqual(Set(try DatabaseTestSupport.tableNames(db)), businessTableSet)

            let indexOwners = try DatabaseTestSupport.schemaIndexOwners(db)
            let allIndexNames = indexOwners.keys.sorted()
            let namedIndexes = allIndexNames.filter { !$0.hasPrefix("sqlite_autoindex_") }
            let autoIndexes = allIndexNames.filter { $0.hasPrefix("sqlite_autoindex_") }

            XCTAssertEqual(
                Set(namedIndexes),
                Set(CatalogSchemaExpectations.businessIndexes),
                "Unexpected named indexes: \(namedIndexes)"
            )
            XCTAssertFalse(autoIndexes.isEmpty, "SQLite auto indexes must be present for PRIMARY KEY constraints")

            let allowedAutoIndexTables = Set(
                CatalogSchemaExpectations.businessTables + CatalogSchemaExpectations.infrastructureTables
            )
            for autoIndex in autoIndexes {
                guard let owner = indexOwners[autoIndex] else {
                    return XCTFail("Missing owner for \(autoIndex)")
                }
                XCTAssertTrue(
                    allowedAutoIndexTables.contains(owner),
                    "Auto index \(autoIndex) must belong to a known table, got \(owner)"
                )
            }
        }
    }

    func testBusinessTableColumnsDefaultsAndPrimaryKeysMatchSpec() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)

        try database.pool.read { db in
            for (table, expectedColumns) in CatalogSchemaExpectations.columnsByTable {
                let actualColumns = try DatabaseTestSupport.tableInfo(db, table: table)
                XCTAssertEqual(actualColumns.count, expectedColumns.count, "Column count mismatch for \(table)")

                let actualNames = actualColumns.map(\.name)
                let expectedNames = expectedColumns.map(\.name)
                XCTAssertEqual(actualNames, expectedNames, "Column order mismatch for \(table)")

                for (expected, actual) in zip(expectedColumns, actualColumns) {
                    XCTAssertEqual(actual.name, expected.name, "\(table) column name")
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
            var indexListByName: [String: (table: String, unique: Bool, partial: Bool)] = [:]
            for table in CatalogSchemaExpectations.businessTables {
                for entry in try DatabaseTestSupport.indexList(db, table: table) {
                    guard !entry.name.hasPrefix("sqlite_autoindex_") else {
                        continue
                    }
                    indexListByName[entry.name] = (table: table, unique: entry.unique, partial: entry.partial)
                }
            }

            XCTAssertEqual(
                Set(indexListByName.keys),
                Set(CatalogSchemaExpectations.businessIndexes),
                "Named business indexes must match spec exactly"
            )

            for expected in CatalogSchemaExpectations.indexes {
                guard let listEntry = indexListByName[expected.name] else {
                    return XCTFail("Missing index \(expected.name) in PRAGMA index_list")
                }
                XCTAssertEqual(
                    listEntry.table,
                    CatalogSchemaExpectations.indexTableByName[expected.name],
                    "Index \(expected.name) table ownership"
                )
                XCTAssertEqual(listEntry.unique, expected.unique, "Index \(expected.name) unique flag")
                XCTAssertEqual(
                    listEntry.partial,
                    !expected.partialPredicateSQL.isEmpty,
                    "Index \(expected.name) partial flag"
                )

                let ddl = try String.fetchOne(
                    db,
                    sql: "SELECT sql FROM sqlite_schema WHERE type = 'index' AND name = ?",
                    arguments: [expected.name]
                )
                XCTAssertNotNil(ddl, "Index DDL must exist for \(expected.name)")

                if !expected.partialPredicateSQL.isEmpty {
                    let actualPredicate = DatabaseTestSupport.normalizedPartialPredicate(from: ddl)
                    let expectedPredicate = DatabaseTestSupport.normalizeSQL(expected.partialPredicateSQL)
                    XCTAssertEqual(actualPredicate, expectedPredicate, "Partial predicate for \(expected.name)")
                }

                if let orderedKeyEntries = expected.orderedKeyEntries {
                    let xinfo = try DatabaseTestSupport.indexXInfo(db, index: expected.name).filter(\.key)
                    XCTAssertEqual(xinfo.count, orderedKeyEntries.count, "Key entry count for \(expected.name)")
                    let sorted = xinfo.sorted { $0.seqno < $1.seqno }
                    for (actual, expectedEntry) in zip(sorted, orderedKeyEntries) {
                        XCTAssertEqual(actual.name, expectedEntry.name, "\(expected.name) key name at seq \(actual.seqno)")
                        XCTAssertEqual(actual.desc, expectedEntry.descending, "\(expected.name) DESC at seq \(actual.seqno)")
                        XCTAssertEqual(actual.coll, expectedEntry.collation, "\(expected.name) collation at seq \(actual.seqno)")
                    }
                } else {
                    let keyEntries = try DatabaseTestSupport.indexKeyEntries(db, index: expected.name)
                    XCTAssertEqual(
                        keyEntries.count,
                        expected.keyColumns.count,
                        "Named key entry count for \(expected.name)"
                    )
                    let sortedKeyEntries = keyEntries.sorted { $0.seqno < $1.seqno }
                    for (actualKey, expectedKey) in zip(sortedKeyEntries, expected.keyColumns) {
                        XCTAssertEqual(actualKey.name, expectedKey.name, "\(expected.name) key column order")
                        XCTAssertEqual(actualKey.desc, expectedKey.descending, "\(expected.name).\(expectedKey.name) DESC flag")
                        XCTAssertEqual(actualKey.coll, expectedKey.collation, "\(expected.name).\(expectedKey.name) collation")
                    }
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

        XCTAssertTrue(dump.contains("applied_migrations=v001_create_catalog_core, v002_add_stage_1_catalog_query_support"))
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
