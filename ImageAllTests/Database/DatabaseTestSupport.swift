import Foundation
import GRDB
import XCTest
@testable import ImageAll

extension XCTestCase {
    func makeTempDatabaseURL(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        try DatabaseTestSupport.makeTempDatabaseURL(addTeardown: { [weak self] block in
            self?.addTeardownBlock(block)
        })
    }
}

enum DatabaseTestSupport {
    static func makeV001OnlyMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        V001CreateCatalogCoreMigration.register(on: &migrator)
        return migrator
    }

    static func makeV002OnlyMigrator() -> DatabaseMigrator {
        var migrator = makeV001OnlyMigrator()
        V002AddStage1CatalogQuerySupportMigration.register(on: &migrator)
        return migrator
    }

    static func makeV005OnlyMigrator() -> DatabaseMigrator {
        var migrator = makeV002OnlyMigrator()
        V003AddDerivedImageCacheMigration.register(on: &migrator)
        V004AddPersonalizationMigration.register(on: &migrator)
        V005AddCatalogScaleIndexesMigration.register(on: &migrator)
        return migrator
    }

    static func makeTempDatabaseURL(addTeardown: ((@escaping () -> Void) -> Void)? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAllTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardown? {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("catalog.sqlite")
    }
    static let timestampMs: Int64 = 1_700_000_000_000

    static func folderBookmark() -> Data {
        Data([0x01, 0x02, 0x03])
    }

    static func lowercaseUUIDString(_ id: UUID = UUID()) -> String {
        id.uuidString.lowercased()
    }

    static func fetchStrings(_ db: Database, sql: String) throws -> [String] {
        try String.fetchAll(db, sql: sql)
    }

    static func tableNames(_ db: Database) throws -> [String] {
        let tables = try fetchStrings(
            db,
            sql: """
            SELECT name FROM sqlite_schema
            WHERE type = 'table'
                AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """
        )
        let infrastructure = Set(CatalogSchemaExpectations.infrastructureTables)
        return tables.filter { !infrastructure.contains($0) }
    }

    static func normalizeSQL(_ sql: String) -> String {
        sql
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedPartialPredicate(from ddl: String?) -> String? {
        guard let ddl else { return nil }
        guard let range = ddl.range(of: "where", options: [.caseInsensitive]) else {
            return nil
        }
        return normalizeSQL(String(ddl[range.upperBound...]))
    }

    static func normalizedIndexKeyList(from ddl: String?) -> String? {
        guard let ddl else { return nil }
        guard let onRange = ddl.range(of: " ON ", options: [.caseInsensitive]) else {
            return nil
        }
        let afterOn = ddl[onRange.upperBound...]
        guard let openParen = afterOn.firstIndex(of: "(") else {
            return nil
        }
        var depth = 0
        var closeParen: String.Index?
        var index = openParen
        while index < afterOn.endIndex {
            let character = afterOn[index]
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    closeParen = index
                    break
                }
            }
            index = afterOn.index(after: index)
        }
        guard let closeParen else {
            return nil
        }
        let keyList = afterOn[afterOn.index(after: openParen) ..< closeParen]
        return normalizeSQL(String(keyList))
    }

    static func indexNames(_ db: Database) throws -> [String] {
        try fetchStrings(
            db,
            sql: """
            SELECT name FROM sqlite_schema
            WHERE type = 'index' AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """
        )
    }

    static func isStrictTable(_ db: Database, table: String) throws -> Bool {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_list(\(table.quoteDatabaseIdentifier()))")
        guard let row = rows.first else {
            return false
        }
        if let strict = row["strict"] as? Int {
            return strict == 1
        }
        let sql = try String.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?",
            arguments: [table]
        )
        return sql?.localizedCaseInsensitiveContains("STRICT") == true
    }

    static func tableInfo(_ db: Database, table: String) throws -> [(name: String, type: String, notNull: Bool, defaultValue: String?, pk: Int)] {
        try Row.fetchAll(db, sql: "PRAGMA table_info(\(table.quoteDatabaseIdentifier()))").map { row in
            (
                name: row["name"] as String,
                type: row["type"] as String,
                notNull: (row["notnull"] as Int) == 1,
                defaultValue: row["dflt_value"] as String?,
                pk: row["pk"] as Int
            )
        }
    }

    static func foreignKeyList(_ db: Database, table: String) throws -> [(from: String, toTable: String, to: String, onDelete: String)] {
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table.quoteDatabaseIdentifier()))").map { row in
            (
                from: row["from"] as String,
                toTable: row["table"] as String,
                to: row["to"] as String,
                onDelete: row["on_delete"] as String
            )
        }
    }

    static func indexList(_ db: Database, table: String) throws -> [(seq: Int, name: String, unique: Bool, partial: Bool)] {
        try Row.fetchAll(db, sql: "PRAGMA index_list(\(table.quoteDatabaseIdentifier()))").map { row in
            (
                seq: row["seq"] as Int,
                name: row["name"] as String,
                unique: (row["unique"] as Int) == 1,
                partial: (row["partial"] as Int) == 1
            )
        }
    }

    static func indexXInfo(_ db: Database, index: String) throws -> [(seqno: Int, cid: Int, name: String?, desc: Bool, coll: String?, key: Bool)] {
        try Row.fetchAll(db, sql: "PRAGMA index_xinfo(\(index.quoteDatabaseIdentifier()))").map { row in
            (
                seqno: row["seqno"] as Int,
                cid: row["cid"] as Int,
                name: row["name"] as String?,
                desc: (row["desc"] as Int) == 1,
                coll: row["coll"] as String?,
                key: (row["key"] as Int) == 1
            )
        }
    }

    static func schemaIndexOwners(_ db: Database) throws -> [String: String] {
        var owners: [String: String] = [:]
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT name, tbl_name FROM sqlite_schema
            WHERE type = 'index' AND name NOT LIKE 'sqlite_stat%'
            ORDER BY name
            """
        )
        for row in rows {
            owners[row["name"] as String] = row["tbl_name"] as String
        }
        return owners
    }

    static func indexKeyEntries(_ db: Database, index: String) throws -> [(seqno: Int, name: String, desc: Bool, coll: String)] {
        let rows = try indexXInfo(db, index: index).filter(\.key)
        return try rows.map { row in
            guard let name = row.name else {
                throw IndexKeyValidationError.unnamedKeyEntry(index: index, seqno: row.seqno)
            }
            guard let coll = row.coll else {
                throw IndexKeyValidationError.missingCollation(index: index, column: name)
            }
            return (seqno: row.seqno, name: name, desc: row.desc, coll: coll)
        }
    }

    enum IndexKeyValidationError: Error, CustomStringConvertible {
        case unnamedKeyEntry(index: String, seqno: Int)
        case missingCollation(index: String, column: String)

        var description: String {
            switch self {
            case let .unnamedKeyEntry(index, seqno):
                return "Index \(index) key entry at seqno \(seqno) has no column name"
            case let .missingCollation(index, column):
                return "Index \(index).\(column) has no collation in index_xinfo"
            }
        }
    }

    struct SchemaObject: Equatable {
        let type: String
        let name: String
        let sql: String?
    }

    static func schemaObjects(_ db: Database) throws -> [SchemaObject] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT type, name, sql FROM sqlite_schema
            WHERE name NOT LIKE 'sqlite_stat%'
            ORDER BY type, name
            """
        ).map { row in
            SchemaObject(
                type: row["type"] as String,
                name: row["name"] as String,
                sql: row["sql"] as String?
            )
        }
    }

    static func schemaDump(_ db: Database) throws -> String {
        let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
        let foreignKeys = try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0
        let quickCheck = try fetchStrings(db, sql: "PRAGMA quick_check").joined(separator: ", ")
        let migrations = try String.fetchAll(
            db,
            sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"
        ).joined(separator: ", ")

        var lines = [
            "applied_migrations=\(migrations)",
            "journal_mode=\(journalMode)",
            "foreign_keys=\(foreignKeys)",
            "quick_check=\(quickCheck)",
            "",
        ]

        for object in try schemaObjects(db) {
            lines.append("\(object.type):\(object.name)")
            lines.append(object.sql ?? "<null>")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    static func makeFolderSourceWithFileAsset(
        repository: CatalogRepository,
        sourceID: UUID = UUID(),
        assetID: UUID = UUID()
    ) throws {
        try repository.createSourceWithAsset(
            NewSourceWithAssetInput(
                sourceID: sourceID,
                sourceKind: .folder,
                displayName: "Photos",
                bookmark: folderBookmark(),
                assetID: assetID,
                locatorKind: .file,
                relativePath: "album/photo.jpg",
                photosLocalIdentifier: nil,
                mediaType: "public.jpeg",
                timestampMs: timestampMs
            )
        )
    }

    static func makePhotosSourceWithPhotosAsset(
        repository: CatalogRepository,
        sourceID: UUID = UUID(),
        assetID: UUID = UUID()
    ) throws {
        try repository.createSourceWithAsset(
            NewSourceWithAssetInput(
                sourceID: sourceID,
                sourceKind: .photos,
                displayName: "Library",
                bookmark: nil,
                assetID: assetID,
                locatorKind: .photos,
                relativePath: nil,
                photosLocalIdentifier: "ABC-DEF-123",
                mediaType: "public.heic",
                timestampMs: timestampMs
            )
        )
    }
}

private extension String {
    func quoteDatabaseIdentifier() -> String {
        "\"\(replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
