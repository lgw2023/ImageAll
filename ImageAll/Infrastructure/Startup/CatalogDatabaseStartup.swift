import Foundation
import GRDB

enum FormalDatabaseInspection: Equatable, Sendable {
    case missing
    case currentSchema
    case knownOldPrefix(applied: [String])
    case unsupportedSchema
    case integrityFailed
}

extension CatalogDatabase {
    static func openWithoutMigration(at url: URL, readonly: Bool = false) throws -> CatalogDatabase {
        var config = Configuration()
        config.readonly = readonly
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let pool = try DatabasePool(path: url.path, configuration: config)
        return CatalogDatabase(pool: pool)
    }

    static func inspectFormalDatabase(at url: URL, fileManager: FileManager = .default) throws -> FormalDatabaseInspection {
        guard fileManager.fileExists(atPath: url.path) else {
            return .missing
        }

        do {
            return try withReadonlyQueue(at: url) { db in
                do {
                    try performQuickCheck(on: db)
                } catch {
                    return .integrityFailed
                }

                let applied = try readAppliedMigrationIDs(from: db)
                if applied.isEmpty {
                    return .knownOldPrefix(applied: [])
                }

                let known = CatalogMigrationID.knownOrdered
                let knownSet = Set(known)
                let unknown = applied.filter { !knownSet.contains($0) }.sorted()
                if !unknown.isEmpty {
                    return .unsupportedSchema
                }

                let expectedPrefix = Array(known.prefix(applied.count))
                if applied != expectedPrefix {
                    return .unsupportedSchema
                }

                if applied == known {
                    return .currentSchema
                }
                return .knownOldPrefix(applied: applied)
            }
        } catch let error as CatalogSnapshotError {
            if case .futureMigrationHistory = error {
                return .unsupportedSchema
            }
            return .integrityFailed
        } catch {
            return .integrityFailed
        }
    }

    static func openCurrentSchema(at url: URL) throws -> CatalogDatabase {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let pool = try DatabasePool(path: url.path, configuration: config)
        do {
            try pool.read { db in
                guard try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1 else {
                    throw CatalogDatabaseError.integrityCheckFailed
                }
                try performQuickCheck(on: db)
                try validateAppliedMigrations(db)
                let applied = try readAppliedMigrationIDs(from: db)
                guard applied == CatalogMigrationID.knownOrdered else {
                    throw CatalogDatabaseError.integrityCheckFailed
                }
            }
            return CatalogDatabase(pool: pool)
        } catch {
            try? pool.close()
            throw error
        }
    }

    static func createCandidateDatabase(at candidateURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: candidateURL.path) {
            throw CatalogSnapshotError.candidatePreparationFailed
        }

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let queue = try DatabaseQueue(path: candidateURL.path, configuration: config)
        defer {
            try? queue.close()
        }

        let migrator = makeMigrator()
        try migrator.migrate(queue)

        try queue.read { db in
            try performQuickCheck(on: db)
            try validateAppliedMigrations(db)
            let applied = try readAppliedMigrationIDs(from: db)
            guard applied == CatalogMigrationID.knownOrdered else {
                throw CatalogSnapshotError.candidatePreparationFailed
            }
            guard try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1 else {
                throw CatalogSnapshotError.integrityCheckFailed
            }
        }

        try convergeToDeleteJournalOnQueue(queue, recheckQuickCheck: true)
        try CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(at: candidateURL)
        try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: candidateURL)
    }

    static func publishCandidateDatabase(
        candidateURL: URL,
        formalURL: URL,
        fileManager: FileManager = .default
    ) throws {
        if fileManager.fileExists(atPath: formalURL.path) {
            throw CatalogSnapshotError.publicationFailed
        }

        do {
            try fileManager.moveItem(at: candidateURL, to: formalURL)
        } catch {
            throw CatalogSnapshotError.publicationFailed
        }
    }
}
