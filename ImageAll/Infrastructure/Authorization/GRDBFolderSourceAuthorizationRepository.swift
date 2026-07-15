import Foundation
import GRDB

enum FolderSourceLookupResult: Equatable, Sendable {
    case notFound
    case wrongKind
    case folder(StoredFolderSourceRecord)
}

struct StoredFolderSourceRecord: Equatable, Sendable {
    let id: UUID
    let displayName: String
    let bookmark: Data
    let state: SourceState
    let scanGeneration: Int
    let dirtyEpoch: Int
    let createdAtMs: Int64
    let updatedAtMs: Int64
}

struct GRDBFolderSourceAuthorizationRepository: Sendable {
    let database: CatalogDatabase

    func lookupSource(id: UUID) throws -> FolderSourceLookupResult {
        try mapPersistence {
            try database.pool.read { db in
                try lookupSource(db, id: id)
            }
        }
    }

    func fetchAllFolderSources() throws -> [StoredFolderSourceRecord] {
        try mapPersistence {
            try database.pool.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM source
                    WHERE kind = 'folder'
                    ORDER BY id ASC
                    """
                ).map { row in
                    try storedFolderSource(from: row)
                }
            }
        }
    }

    func connectFolder(
        sourceID: UUID,
        displayName: String,
        bookmark: Data,
        jobID: UUID,
        nowMs: Int64
    ) throws {
        try mapPersistence {
            try database.pool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO source (
                        id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                        state, created_at_ms, updated_at_ms
                    ) VALUES (?, 'folder', ?, ?, 0, 0, 'active', ?, ?)
                    """,
                    arguments: [
                        sourceID.uuidString.lowercased(),
                        displayName,
                        bookmark,
                        nowMs,
                        nowMs,
                    ]
                )

                let command = try FolderReconcileJobFactory.makeEnqueueCommand(
                    jobID: jobID,
                    sourceID: sourceID,
                    notBeforeMs: nowMs
                )
                try JobInsertInTransaction.insertPendingJob(db, command: command, nowMs: nowMs)
            }
        }
    }

    func disableFolderSource(sourceID: UUID, nowMs: Int64) throws {
        try mapPersistence {
            try database.pool.write { db in
                switch try lookupSource(db, id: sourceID) {
                case .notFound:
                    throw FolderAuthorizationError.sourceNotFound
                case .wrongKind:
                    throw FolderAuthorizationError.sourceKindMismatch
                case .folder:
                    break
                }

                try db.execute(
                    sql: """
                    UPDATE source SET state = 'disabled', updated_at_ms = ?
                    WHERE id = ? AND kind = 'folder'
                    """,
                    arguments: [nowMs, sourceID.uuidString.lowercased()]
                )
                guard db.changesCount == 1 else {
                    throw FolderAuthorizationError.persistenceFailure
                }

                try db.execute(
                    sql: """
                    UPDATE job SET
                        state = 'cancelled',
                        control_request = 'none',
                        lease_owner = NULL,
                        lease_expires_at_ms = NULL,
                        last_error_code = NULL,
                        last_error_message = NULL,
                        updated_at_ms = ?
                    WHERE source_id = ?
                        AND kind = ?
                        AND state IN ('pending', 'paused', 'retryableFailed')
                    """,
                    arguments: [
                        nowMs,
                        sourceID.uuidString.lowercased(),
                        FolderReconcileJobFactory.kind,
                    ]
                )

                try db.execute(
                    sql: """
                    UPDATE job SET
                        control_request = 'cancel',
                        updated_at_ms = ?
                    WHERE source_id = ?
                        AND kind = ?
                        AND state = 'running'
                        AND control_request IN ('none', 'pause')
                    """,
                    arguments: [
                        nowMs,
                        sourceID.uuidString.lowercased(),
                        FolderReconcileJobFactory.kind,
                    ]
                )
            }
        }
    }

    func reauthorizeFolder(
        sourceID: UUID,
        displayName: String,
        bookmark: Data,
        jobID: UUID,
        nowMs: Int64
    ) throws {
        try mapPersistence {
            try database.pool.write { db in
                switch try lookupSource(db, id: sourceID) {
                case .notFound:
                    throw FolderAuthorizationError.sourceNotFound
                case .wrongKind:
                    throw FolderAuthorizationError.sourceKindMismatch
                case let .folder(record):
                    guard record.state == .unavailable || record.state == .authorizationRequired else {
                        throw FolderAuthorizationError.invalidSourceState
                    }
                }

                try db.execute(
                    sql: """
                    UPDATE source SET
                        display_name = ?,
                        bookmark = ?,
                        state = 'active',
                        updated_at_ms = ?
                    WHERE id = ?
                        AND kind = 'folder'
                        AND state IN ('unavailable', 'authorizationRequired')
                    """,
                    arguments: [
                        displayName,
                        bookmark,
                        nowMs,
                        sourceID.uuidString.lowercased(),
                    ]
                )
                guard db.changesCount == 1 else {
                    throw FolderAuthorizationError.invalidSourceState
                }

                let coalescingKey = FolderReconcileJobFactory.coalescingKey(sourceID: sourceID)
                let activeExists = try Int.fetchOne(
                    db,
                    sql: """
                    SELECT 1 FROM job
                    WHERE coalescing_key = ?
                        AND state IN ('pending', 'running', 'paused', 'retryableFailed')
                    LIMIT 1
                    """,
                    arguments: [coalescingKey]
                )

                if activeExists != 1 {
                    let command = try FolderReconcileJobFactory.makeEnqueueCommand(
                        jobID: jobID,
                        sourceID: sourceID,
                        notBeforeMs: nowMs
                    )
                    try JobInsertInTransaction.insertPendingJob(db, command: command, nowMs: nowMs)
                }
            }
        }
    }

    func replaceStaleBookmark(
        sourceID: UUID,
        bookmark: Data,
        nowMs: Int64
    ) throws {
        try mapPersistence {
            try database.pool.write { db in
                try db.execute(
                    sql: """
                    UPDATE source SET bookmark = ?, updated_at_ms = ?
                    WHERE id = ? AND kind = 'folder'
                    """,
                    arguments: [
                        bookmark,
                        nowMs,
                        sourceID.uuidString.lowercased(),
                    ]
                )
                guard db.changesCount == 1 else {
                    throw FolderAuthorizationError.persistenceFailure
                }
            }
        }
    }

    func updateSourceState(sourceID: UUID, state: SourceState, nowMs: Int64) throws {
        try mapPersistence {
            try database.pool.write { db in
                try db.execute(
                    sql: """
                    UPDATE source SET state = ?, updated_at_ms = ?
                    WHERE id = ? AND kind = 'folder'
                    """,
                    arguments: [
                        state.rawValue,
                        nowMs,
                        sourceID.uuidString.lowercased(),
                    ]
                )
                guard db.changesCount == 1 else {
                    throw FolderAuthorizationError.persistenceFailure
                }
            }
        }
    }

    private func lookupSource(_ db: Database, id: UUID) throws -> FolderSourceLookupResult {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM source WHERE id = ?",
            arguments: [id.uuidString.lowercased()]
        ) else {
            return .notFound
        }
        let kind: String = row["kind"]
        guard kind == SourceKind.folder.rawValue else {
            return .wrongKind
        }
        return .folder(try storedFolderSource(from: row))
    }

    private func storedFolderSource(from row: Row) throws -> StoredFolderSourceRecord {
        let idString: String = row["id"]
        guard let id = UUID(uuidString: idString) else {
            throw FolderAuthorizationError.persistenceFailure
        }
        let stateRaw: String = row["state"]
        guard let state = SourceState(rawValue: stateRaw) else {
            throw FolderAuthorizationError.persistenceFailure
        }
        guard let bookmark: Data = row["bookmark"] else {
            throw FolderAuthorizationError.persistenceFailure
        }
        return StoredFolderSourceRecord(
            id: id,
            displayName: row["display_name"],
            bookmark: bookmark,
            state: state,
            scanGeneration: row["scan_generation"],
            dirtyEpoch: row["dirty_epoch"],
            createdAtMs: row["created_at_ms"],
            updatedAtMs: row["updated_at_ms"]
        )
    }

    private func mapPersistence<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as FolderAuthorizationError {
            throw error
        } catch is DatabaseError {
            throw FolderAuthorizationError.persistenceFailure
        } catch {
            throw FolderAuthorizationError.persistenceFailure
        }
    }
}
