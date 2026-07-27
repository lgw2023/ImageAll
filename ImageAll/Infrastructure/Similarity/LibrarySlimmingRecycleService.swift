import Foundation
import GRDB

struct LibrarySlimmingRecycleService: LibrarySlimmingRecyclePort {
    let database: CatalogDatabase
    let mutationAccess: any FolderMutationAccessing
    let quarantineRootURL: URL
    let clock: any JobClock
    let jobQueue: (any JobQueue)?
    var quarantineIO: FolderQuarantineIO
    var idGenerator: @Sendable () -> UUID

    init(
        database: CatalogDatabase,
        mutationAccess: any FolderMutationAccessing,
        quarantineRootURL: URL,
        clock: any JobClock,
        jobQueue: (any JobQueue)? = nil,
        quarantineIO: FolderQuarantineIO = FolderQuarantineIO(),
        idGenerator: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.database = database
        self.mutationAccess = mutationAccess
        self.quarantineRootURL = quarantineRootURL
        self.clock = clock
        self.jobQueue = jobQueue
        self.quarantineIO = quarantineIO
        self.idGenerator = idGenerator
    }

    func moveFolderAssetsToRecycle(assetIDs: [UUID]) throws -> LibrarySlimmingRecycleMoveOutcome {
        var outcome = LibrarySlimmingRecycleMoveOutcome(
            recycledEntryIDs: [],
            skippedPhotosAssetIDs: [],
            failedAssetIDs: [],
            authorizationRequiredSourceIDs: []
        )
        try quarantineIO.ensureQuarantineRoot(at: quarantineRootURL)

        for assetID in assetIDs {
            do {
                let entryID = try recycleOne(assetID: assetID)
                outcome.recycledEntryIDs.append(entryID)
            } catch LibrarySlimmingRecycleError.ineligiblePhotos {
                outcome.skippedPhotosAssetIDs.append(assetID)
            } catch LibrarySlimmingRecycleError.mutationAuthorizationRequired {
                if let sourceID = try? loadSourceID(assetID: assetID) {
                    if !outcome.authorizationRequiredSourceIDs.contains(sourceID) {
                        outcome.authorizationRequiredSourceIDs.append(sourceID)
                    }
                }
                outcome.failedAssetIDs.append(assetID)
            } catch {
                outcome.failedAssetIDs.append(assetID)
            }
        }
        return outcome
    }

    func listRecycledEntries() throws -> [RecycleEntryRecord] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    r.id, r.asset_id, r.source_kind, r.trashed_at_ms, r.purge_after_ms,
                    r.state, r.quarantine_relative_path, r.original_relative_path,
                    r.error_code, a.file_name
                FROM recycle_entry r
                JOIN asset a ON a.id = r.asset_id
                WHERE r.state = 'recycled'
                ORDER BY r.trashed_at_ms DESC, r.id ASC
                """
            )
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["id"]),
                      let assetID = UUID(uuidString: row["asset_id"]),
                      let sourceKind = RecycleSourceKind(rawValue: row["source_kind"]),
                      let state = RecycleEntryState(rawValue: row["state"])
                else { return nil }
                return RecycleEntryRecord(
                    id: id,
                    assetID: assetID,
                    sourceKind: sourceKind,
                    trashedAtMs: row["trashed_at_ms"],
                    purgeAfterMs: row["purge_after_ms"],
                    state: state,
                    quarantineRelativePath: row["quarantine_relative_path"],
                    originalRelativePath: row["original_relative_path"],
                    errorCode: row["error_code"],
                    fileName: row["file_name"]
                )
            }
        }
    }

    func restore(entryID: UUID) throws {
        let snapshot = try loadActiveEntry(entryID: entryID)
        guard snapshot.state == .recycled,
              let quarantinePath = snapshot.quarantineRelativePath
        else {
            throw LibrarySlimmingRecycleError.invalidState
        }
        let sourceID = try loadSourceID(assetID: snapshot.assetID)

        do {
            try mutationAccess.withWritableSourceRoot(sourceID: sourceID) { sourceRoot in
                try quarantineIO.moveOutOfQuarantine(
                    quarantineRootURL: quarantineRootURL,
                    quarantineRelativePath: quarantinePath,
                    sourceRootURL: sourceRoot,
                    originalRelativePath: snapshot.originalRelativePath
                )
            }
        } catch FolderQuarantineIOError.targetExists {
            throw LibrarySlimmingRecycleError.restoreConflict
        } catch LibrarySlimmingRecycleError.mutationAuthorizationRequired {
            throw LibrarySlimmingRecycleError.mutationAuthorizationRequired
        } catch {
            throw LibrarySlimmingRecycleError.ioFailure
        }

        let now = clock.nowMs
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET state = 'restored', updated_at_ms = ?, error_code = NULL
                WHERE id = ?
                """,
                arguments: [now, entryID.uuidString.lowercased()]
            )
            try db.execute(
                sql: """
                UPDATE asset
                SET availability = 'available', record_updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [now, snapshot.assetID.uuidString.lowercased()]
            )
        }
    }

    func purgeNow(entryID: UUID) throws {
        let snapshot = try loadActiveEntry(entryID: entryID)
        guard snapshot.state == .recycled else {
            throw LibrarySlimmingRecycleError.invalidState
        }
        if let quarantinePath = snapshot.quarantineRelativePath {
            try? quarantineIO.deleteQuarantineObject(
                quarantineRootURL: quarantineRootURL,
                quarantineRelativePath: quarantinePath
            )
        }
        let now = clock.nowMs
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET state = 'purged', updated_at_ms = ?, quarantine_relative_path = NULL
                WHERE id = ?
                """,
                arguments: [now, entryID.uuidString.lowercased()]
            )
            try db.execute(
                sql: "DELETE FROM asset WHERE id = ?",
                arguments: [snapshot.assetID.uuidString.lowercased()]
            )
        }
    }

    func purgeExpired(nowMs: Int64) throws -> Int {
        let dueIDs: [UUID] = try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id FROM recycle_entry
                WHERE state = 'recycled' AND purge_after_ms <= ?
                ORDER BY purge_after_ms ASC, id ASC
                """,
                arguments: [nowMs]
            )
            return rows.compactMap { UUID(uuidString: $0["id"]) }
        }
        var purged = 0
        for id in dueIDs {
            do {
                try purgeNow(entryID: id)
                purged += 1
            } catch {
                continue
            }
        }
        return purged
    }

    func enqueuePurgeExpired() throws {
        guard let jobQueue else { return }
        let command = try LibrarySlimmingPurgeJobFactory.makeEnqueueCommand(
            jobID: idGenerator(),
            notBeforeMs: clock.nowMs
        )
        _ = try jobQueue.enqueue(command)
    }

    // MARK: - Private

    private struct AssetSnapshot {
        let assetID: UUID
        let sourceID: UUID
        let locatorKind: String
        let relativePath: String?
        let fileName: String?
        let availability: String
    }

    private struct EntrySnapshot {
        let id: UUID
        let assetID: UUID
        let state: RecycleEntryState
        let quarantineRelativePath: String?
        let originalRelativePath: String
    }

    private func recycleOne(assetID: UUID) throws -> UUID {
        let asset = try loadAsset(assetID: assetID)
        guard asset.locatorKind == AssetLocatorKind.file.rawValue,
              let relativePath = asset.relativePath
        else {
            throw LibrarySlimmingRecycleError.ineligiblePhotos
        }
        guard asset.availability == AssetAvailability.available.rawValue else {
            if asset.availability == AssetAvailability.recycled.rawValue {
                throw LibrarySlimmingRecycleError.alreadyRecycled
            }
            throw LibrarySlimmingRecycleError.invalidState
        }

        let fileName = asset.fileName
            ?? RelativePathRules.fileName(from: relativePath)
            ?? "asset"
        let quarantineRelative = QuarantinePathLayout.relativePath(
            sourceID: asset.sourceID,
            assetID: asset.assetID,
            fileName: fileName
        )
        let entryID = idGenerator()
        let now = clock.nowMs
        let purgeAfter = LibrarySlimmingRecyclePolicy.purgeAfterMs(trashedAtMs: now)

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO recycle_entry (
                    id, asset_id, source_kind, trashed_at_ms, purge_after_ms, state,
                    quarantine_relative_path, original_relative_path, error_code,
                    created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'file', ?, ?, 'pending', NULL, ?, NULL, ?, ?)
                """,
                arguments: [
                    entryID.uuidString.lowercased(),
                    asset.assetID.uuidString.lowercased(),
                    now,
                    purgeAfter,
                    relativePath,
                    now,
                    now,
                ]
            )
        }

        do {
            try mutationAccess.withWritableSourceRoot(sourceID: asset.sourceID) { sourceRoot in
                try quarantineIO.moveIntoQuarantine(
                    sourceRootURL: sourceRoot,
                    sourceRelativePath: relativePath,
                    quarantineRootURL: quarantineRootURL,
                    quarantineRelativePath: quarantineRelative
                )
            }
        } catch LibrarySlimmingRecycleError.mutationAuthorizationRequired {
            try markFailed(entryID: entryID, code: "mutationAuthorizationRequired")
            throw LibrarySlimmingRecycleError.mutationAuthorizationRequired
        } catch {
            try markFailed(entryID: entryID, code: "ioFailure")
            throw LibrarySlimmingRecycleError.ioFailure
        }

        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET state = 'recycled',
                    quarantine_relative_path = ?,
                    error_code = NULL,
                    updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [
                    quarantineRelative,
                    clock.nowMs,
                    entryID.uuidString.lowercased(),
                ]
            )
            try db.execute(
                sql: """
                UPDATE asset
                SET availability = 'recycled', record_updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [
                    clock.nowMs,
                    asset.assetID.uuidString.lowercased(),
                ]
            )
        }
        return entryID
    }

    private func markFailed(entryID: UUID, code: String) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET state = 'failed', error_code = ?, updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [code, clock.nowMs, entryID.uuidString.lowercased()]
            )
        }
    }

    private func loadAsset(assetID: UUID) throws -> AssetSnapshot {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, source_id, locator_kind, relative_path, file_name, availability
                FROM asset WHERE id = ?
                """,
                arguments: [assetID.uuidString.lowercased()]
            ),
                let id = UUID(uuidString: row["id"]),
                let sourceID = UUID(uuidString: row["source_id"])
            else {
                throw LibrarySlimmingRecycleError.notFound
            }
            return AssetSnapshot(
                assetID: id,
                sourceID: sourceID,
                locatorKind: row["locator_kind"],
                relativePath: row["relative_path"],
                fileName: row["file_name"],
                availability: row["availability"]
            )
        }
    }

    private func loadSourceID(assetID: UUID) throws -> UUID {
        try loadAsset(assetID: assetID).sourceID
    }

    private func loadActiveEntry(entryID: UUID) throws -> EntrySnapshot {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, asset_id, state, quarantine_relative_path, original_relative_path
                FROM recycle_entry WHERE id = ?
                """,
                arguments: [entryID.uuidString.lowercased()]
            ),
                let id = UUID(uuidString: row["id"]),
                let assetID = UUID(uuidString: row["asset_id"]),
                let state = RecycleEntryState(rawValue: row["state"])
            else {
                throw LibrarySlimmingRecycleError.notFound
            }
            return EntrySnapshot(
                id: id,
                assetID: assetID,
                state: state,
                quarantineRelativePath: row["quarantine_relative_path"],
                originalRelativePath: row["original_relative_path"]
            )
        }
    }
}
