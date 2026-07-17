import Foundation
import GRDB

struct CatalogDatabase: Sendable {
    let pool: DatabasePool

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        V001CreateCatalogCoreMigration.register(on: &migrator)
        V002AddStage1CatalogQuerySupportMigration.register(on: &migrator)
        V003AddDerivedImageCacheMigration.register(on: &migrator)
        V004AddPersonalizationMigration.register(on: &migrator)
        V005AddCatalogScaleIndexesMigration.register(on: &migrator)
        V006AddAssetTextSearchMigration.register(on: &migrator)
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
        try closePool(pool)
        try convergeClosedDatabaseFileToDelete(at: databaseURL)
    }

    static func convergeClosedDatabaseFileToDelete(at url: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: config)
        } catch {
            throw CatalogSnapshotError.sidecarConvergenceFailed
        }
        var closed = false
        do {
            try queue.writeWithoutTransaction { db in
                try requireDeleteJournalMode(db, setDelete: true)
            }
            try queue.read { db in
                try performQuickCheck(on: db)
            }
        } catch let error as CatalogSnapshotError {
            try closeQueueOnce(queue, closed: &closed)
            throw error
        } catch {
            try closeQueueOnce(queue, closed: &closed)
            throw CatalogSnapshotError.sidecarConvergenceFailed
        }
        try closeQueueOnce(queue, closed: &closed)
        try CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(at: url)
        try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: url)
    }

    static func performTruncateCheckpoint(_ db: Database) throws {
        do {
            let result = try db.checkpoint(.truncate)
            if result.walFrameCount < 0 {
                return
            }
            guard result.walFrameCount == result.checkpointedFrameCount else {
                throw CatalogSnapshotError.checkpointFailed
            }
            guard result.walFrameCount == 0 else {
                throw CatalogSnapshotError.checkpointFailed
            }
        } catch let error as CatalogSnapshotError {
            throw error
        } catch let error as DatabaseError
            where error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED {
            throw CatalogSnapshotError.checkpointFailed
        } catch is DatabaseError {
            throw CatalogSnapshotError.checkpointFailed
        }
    }

    static func closePool(_ pool: DatabasePool) throws {
        do {
            try pool.close()
        } catch {
            throw CatalogSnapshotError.closeFailed
        }
    }

    static func closeQueue(_ queue: DatabaseQueue) throws {
        do {
            try queue.close()
        } catch {
            throw CatalogSnapshotError.closeFailed
        }
    }

    private static func closeQueueOnce(_ queue: DatabaseQueue, closed: inout Bool) throws {
        guard !closed else { return }
        try closeQueue(queue)
        closed = true
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

    static func requireDeleteJournalMode(_ db: Database, setDelete: Bool) throws {
        let mode: String
        do {
            if setDelete {
                mode = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE") ?? ""
            } else {
                mode = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? ""
            }
        } catch is DatabaseError {
            throw CatalogSnapshotError.sidecarConvergenceFailed
        }
        guard mode.lowercased() == "delete" else {
            throw CatalogSnapshotError.sidecarConvergenceFailed
        }
    }

    static func convergeToDeleteJournalOnQueue(_ queue: DatabaseQueue, recheckQuickCheck: Bool) throws {
        try queue.writeWithoutTransaction { db in
            try performTruncateCheckpoint(db)
            try requireDeleteJournalMode(db, setDelete: true)
        }
        if recheckQuickCheck {
            try queue.read { db in
                try performQuickCheck(on: db)
            }
        }
    }

    static func withReadonlyQueue<T>(at url: URL, _ body: (Database) throws -> T) throws -> T {
        var config = Configuration()
        config.readonly = true
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: config)
        } catch {
            throw CatalogSnapshotError.integrityCheckFailed
        }
        var closed = false
        let value: T
        do {
            value = try queue.read { db in
                try body(db)
            }
        } catch let error as CatalogDatabaseError {
            try closeQueueOnce(queue, closed: &closed)
            if case let .futureSchema(applied, unknown) = error {
                throw CatalogSnapshotError.futureMigrationHistory(applied: applied, unknown: unknown)
            }
            throw CatalogSnapshotError.integrityCheckFailed
        } catch let error as CatalogSnapshotError {
            try closeQueueOnce(queue, closed: &closed)
            throw error
        } catch {
            try closeQueueOnce(queue, closed: &closed)
            throw CatalogSnapshotError.integrityCheckFailed
        }
        try closeQueueOnce(queue, closed: &closed)
        return value
    }

    static func prepareWorkCopyForReplacement(
        at url: URL,
        expectedManifestMigrations: [String],
        runMigration: Bool
    ) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: config)
        } catch {
            throw CatalogSnapshotError.candidatePreparationFailed
        }
        var closed = false
        do {
            let initialMigrations = try queue.read { db -> [String] in
                try performQuickCheck(on: db)
                try validateAppliedMigrations(db)
                return try readAppliedMigrationIDs(from: db)
            }

            try CatalogSnapshotManifestValidator.validateMigrationHistoryMatchesDatabase(
                manifestMigrations: expectedManifestMigrations,
                databaseMigrations: initialMigrations
            )

            if runMigration {
                let migrator = makeMigrator()
                try migrator.migrate(queue)
            }

            try queue.read { db in
                try performQuickCheck(on: db)
                try validateAppliedMigrations(db)
                let applied = try readAppliedMigrationIDs(from: db)
                guard applied == CatalogMigrationID.knownOrdered else {
                    throw CatalogSnapshotError.invalidMigrationHistory
                }
                guard try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1 else {
                    throw CatalogSnapshotError.integrityCheckFailed
                }
            }

            try convergeToDeleteJournalOnQueue(queue, recheckQuickCheck: true)
        } catch let error as CatalogDatabaseError {
            try closeQueueOnce(queue, closed: &closed)
            if case let .futureSchema(applied, unknown) = error {
                throw CatalogSnapshotError.futureMigrationHistory(applied: applied, unknown: unknown)
            }
            throw CatalogSnapshotError.candidatePreparationFailed
        } catch let error as CatalogSnapshotError {
            try closeQueueOnce(queue, closed: &closed)
            throw error
        } catch {
            try closeQueueOnce(queue, closed: &closed)
            throw CatalogSnapshotError.candidatePreparationFailed
        }
        try closeQueueOnce(queue, closed: &closed)
        try CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(at: url)
        try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: url)
    }

    static func validateAndCloseReplacedDatabase(at url: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: config)
        } catch {
            throw CatalogSnapshotError.postReplaceValidationFailed
        }
        var closed = false
        do {
            try queue.read { db in
                guard try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1 else {
                    throw CatalogSnapshotError.postReplaceValidationFailed
                }
                try performQuickCheck(on: db)
                try validateAppliedMigrations(db)
                let applied = try readAppliedMigrationIDs(from: db)
                guard applied == CatalogMigrationID.knownOrdered else {
                    throw CatalogSnapshotError.postReplaceValidationFailed
                }
            }
            try convergeToDeleteJournalOnQueue(queue, recheckQuickCheck: true)
        } catch let error as CatalogDatabaseError {
            try closeQueueOnce(queue, closed: &closed)
            throw CatalogSnapshotError.postReplaceValidationFailed
        } catch is CatalogSnapshotError {
            try closeQueueOnce(queue, closed: &closed)
            throw CatalogSnapshotError.postReplaceValidationFailed
        } catch {
            try closeQueueOnce(queue, closed: &closed)
            throw CatalogSnapshotError.postReplaceValidationFailed
        }
        try closeQueueOnce(queue, closed: &closed)
        try CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(at: url)
        try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: url)
    }
}

enum V005AddCatalogScaleIndexesMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v005AddCatalogScaleIndexes) { db in
            for statement in indexStatements {
                try db.execute(sql: statement)
            }
        }
    }

    private static let timeEmptyMarkerExpression =
        V002AddStage1CatalogQuerySupportMigration.timeEmptyMarkerExpression
    private static let coalescedMediaTimeExpression =
        V002AddStage1CatalogQuerySupportMigration.coalescedMediaTimeExpression

    private static let indexStatements = [
        """
        CREATE INDEX asset_current_time_desc_idx ON asset (
            \(timeEmptyMarkerExpression),
            \(coalescedMediaTimeExpression) DESC,
            id DESC
        ) WHERE locator_state = 'current'
        """,
        """
        CREATE INDEX asset_current_source_media_time_desc_idx ON asset (
            source_id,
            media_type,
            \(timeEmptyMarkerExpression),
            \(coalescedMediaTimeExpression) DESC,
            id DESC
        ) WHERE locator_state = 'current'
        """,
        """
        CREATE INDEX asset_current_file_name_all_idx ON asset (
            (CASE WHEN file_name IS NOT NULL THEN 0 ELSE 1 END),
            file_name COLLATE NOCASE,
            id
        ) WHERE locator_state = 'current'
        """,
    ]
}

enum V006AddAssetTextSearchMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(CatalogMigrationID.v006AddAssetTextSearch) { db in
            try db.execute(
                sql: """
                CREATE VIRTUAL TABLE asset_search USING fts5(
                    file_name,
                    relative_path,
                    content = 'asset',
                    content_rowid = 'rowid',
                    tokenize = 'trigram'
                )
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER asset_search_after_insert
                AFTER INSERT ON asset
                BEGIN
                    INSERT INTO asset_search(rowid, file_name, relative_path)
                    VALUES (new.rowid, new.file_name, new.relative_path);
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER asset_search_after_delete
                AFTER DELETE ON asset
                BEGIN
                    INSERT INTO asset_search(asset_search, rowid, file_name, relative_path)
                    VALUES ('delete', old.rowid, old.file_name, old.relative_path);
                END
                """
            )
            try db.execute(
                sql: """
                CREATE TRIGGER asset_search_after_update
                AFTER UPDATE OF file_name, relative_path ON asset
                BEGIN
                    INSERT INTO asset_search(asset_search, rowid, file_name, relative_path)
                    VALUES ('delete', old.rowid, old.file_name, old.relative_path);
                    INSERT INTO asset_search(rowid, file_name, relative_path)
                    VALUES (new.rowid, new.file_name, new.relative_path);
                END
                """
            )
            try db.execute(sql: "INSERT INTO asset_search(asset_search) VALUES ('rebuild')")
        }
    }
}
