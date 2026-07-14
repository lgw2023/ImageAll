import Foundation
import GRDB

struct CatalogDatabase: Sendable {
    let pool: DatabasePool

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        V001CreateCatalogCoreMigration.register(on: &migrator)
        return migrator
    }

    static func open(at url: URL) throws -> CatalogDatabase {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let pool = try DatabasePool(path: url.path, configuration: config)
        let database = CatalogDatabase(pool: pool)
        try database.migrate()
        try database.validateQuickCheck()
        return database
    }

    func migrate() throws {
        try pool.write { db in
            try Self.validateAppliedMigrations(db)
        }

        let migrator = Self.makeMigrator()
        try migrator.migrate(pool)

        try pool.write { db in
            try Self.validateAppliedMigrations(db)
        }
    }

    func validateQuickCheck() throws {
        try pool.read { db in
            let results = try String.fetchAll(db, sql: "PRAGMA quick_check")
            guard results == ["ok"] else {
                throw CatalogDatabaseError.integrityCheckFailed
            }
        }
    }

    static func validateAppliedMigrations(_ db: Database) throws {
        guard try db.tableExists("grdb_migrations") else {
            return
        }

        let applied = try String.fetchAll(
            db,
            sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"
        )
        let known = CatalogMigrationID.knownOrdered
        let knownSet = Set(known)
        let appliedSet = Set(applied)

        let unknown = applied.filter { !knownSet.contains($0) }.sorted()
        if !unknown.isEmpty {
            throw CatalogDatabaseError.futureSchema(applied: applied.sorted(), unknown: unknown)
        }

        let expectedPrefix = Set(known.prefix(applied.count))
        if appliedSet != expectedPrefix {
            throw CatalogDatabaseError.futureSchema(applied: applied.sorted(), unknown: unknown)
        }
    }

    func appliedMigrationIDs() throws -> [String] {
        try pool.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }

    func journalMode() throws -> String {
        try pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
        }
    }

    func foreignKeysEnabled() throws -> Bool {
        try pool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1
        }
    }

    /// Caller must stop scheduling and hold exclusive catalog access before calling.
    func checkpointAndCloseForReplacement() throws {
        try Self.checkpointAndClose(pool: pool, databaseURL: URL(fileURLWithPath: pool.path))
    }

    static func checkpointAndClose(pool: DatabasePool, databaseURL: URL) throws {
        try pool.barrierWriteWithoutTransaction { db in
            try performTruncateCheckpoint(db)
        }
        try pool.close()
        try CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(at: databaseURL)
        try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: databaseURL)
    }

    static func performTruncateCheckpoint(_ db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)") else {
            throw CatalogSnapshotError.checkpointFailed
        }
        _ = row
    }

    static func readAppliedMigrationIDs(from db: Database) throws -> [String] {
        guard try db.tableExists("grdb_migrations") else {
            return []
        }
        return try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
    }

    static func performQuickCheck(on db: Database) throws {
        let results = try String.fetchAll(db, sql: "PRAGMA quick_check")
        guard results == ["ok"] else {
            throw CatalogSnapshotError.integrityCheckFailed
        }
    }

    static func validateClosedDatabase(at url: URL, requireCurrentSchema: Bool) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let pool = try DatabasePool(path: url.path, configuration: config)
        try pool.read { db in
            try performQuickCheck(on: db)
            try validateAppliedMigrations(db)
            if requireCurrentSchema {
                let applied = try readAppliedMigrationIDs(from: db)
                guard applied == CatalogMigrationID.knownOrdered else {
                    throw CatalogSnapshotError.invalidMigrationHistory
                }
            }
            guard try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1 else {
                throw CatalogSnapshotError.integrityCheckFailed
            }
        }
        try pool.close()
        try CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(at: url)
        try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: url)
    }

    static func migrateWorkCopy(at url: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let pool = try DatabasePool(path: url.path, configuration: config)
        defer {
            try? pool.close()
        }

        let migrator = makeMigrator()
        try migrator.migrate(pool)

        try pool.read { db in
            try performQuickCheck(on: db)
            try validateAppliedMigrations(db)
            let applied = try readAppliedMigrationIDs(from: db)
            guard applied == CatalogMigrationID.knownOrdered else {
                throw CatalogSnapshotError.invalidMigrationHistory
            }
        }
    }

    static func checkpointCloseAndRequireNoSidecars(at url: URL) throws {
        var config = Configuration()
        let pool = try DatabasePool(path: url.path, configuration: config)
        try pool.barrierWriteWithoutTransaction { db in
            try performTruncateCheckpoint(db)
        }
        try pool.close()
        try CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(at: url)
        try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: url)
    }
}
