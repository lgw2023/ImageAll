import Foundation
import GRDB
import XCTest
@testable import ImageAll

extension XCTestCase {
    func makeTempDatabaseURL(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAllTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("catalog.sqlite")
    }
}

enum DatabaseTestSupport {
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
        try fetchStrings(
            db,
            sql: """
            SELECT name FROM sqlite_schema
            WHERE type = 'table'
                AND name NOT LIKE 'sqlite_%'
                AND name != 'grdb_migrations'
            ORDER BY name
            """
        )
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
        let sql = try String.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?",
            arguments: [table]
        )
        return sql?.localizedCaseInsensitiveContains("STRICT") == true
    }

    static func schemaDump(_ db: Database) throws -> String {
        let ddl = try fetchStrings(
            db,
            sql: """
            SELECT sql FROM sqlite_schema
            WHERE sql IS NOT NULL
            ORDER BY type, name
            """
        ).joined(separator: ";\n\n")

        let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
        let foreignKeys = try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0
        let quickCheck = try fetchStrings(db, sql: "PRAGMA quick_check").joined(separator: ", ")
        let migrations = try String.fetchAll(
            db,
            sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"
        ).joined(separator: ", ")

        return """
        applied_migrations=\(migrations)
        journal_mode=\(journalMode)
        foreign_keys=\(foreignKeys)
        quick_check=\(quickCheck)

        \(ddl);
        """
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
