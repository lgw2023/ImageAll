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
            authorizationRequiredSourceIDs: [],
            authorizationRequiredAssetIDs: []
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
                outcome.authorizationRequiredAssetIDs.append(assetID)
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
                    r.id, r.asset_id, a.source_id, r.source_kind, r.trashed_at_ms, r.purge_after_ms,
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
                      let sourceID = UUID(uuidString: row["source_id"]),
                      let sourceKind = RecycleSourceKind(rawValue: row["source_kind"]),
                      let state = RecycleEntryState(rawValue: row["state"])
                else { return nil }
                return RecycleEntryRecord(
                    id: id,
                    assetID: assetID,
                    sourceID: sourceID,
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
        try transitionEntry(
            entryID: entryID,
            from: .recycled,
            to: .restoring,
            errorCode: nil
        )

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
            try? transitionEntry(
                entryID: entryID,
                from: .restoring,
                to: .recycled,
                errorCode: "restoreConflict"
            )
            throw LibrarySlimmingRecycleError.restoreConflict
        } catch LibrarySlimmingRecycleError.mutationAuthorizationRequired {
            try? transitionEntry(
                entryID: entryID,
                from: .restoring,
                to: .recycled,
                errorCode: "mutationAuthorizationRequired"
            )
            throw LibrarySlimmingRecycleError.mutationAuthorizationRequired
        } catch {
            try? transitionEntry(
                entryID: entryID,
                from: .restoring,
                to: .recycled,
                errorCode: "restoreIOFailure"
            )
            throw LibrarySlimmingRecycleError.ioFailure
        }

        try finalizeRestored(snapshot)
    }

    func purgeNow(entryID: UUID) throws {
        let snapshot = try loadActiveEntry(entryID: entryID)
        guard snapshot.state == .recycled else {
            throw LibrarySlimmingRecycleError.invalidState
        }
        guard let quarantinePath = snapshot.quarantineRelativePath else {
            throw LibrarySlimmingRecycleError.invalidState
        }
        try transitionEntry(
            entryID: entryID,
            from: .recycled,
            to: .purging,
            errorCode: nil
        )
        do {
            try quarantineIO.deleteQuarantineObject(
                quarantineRootURL: quarantineRootURL,
                quarantineRelativePath: quarantinePath
            )
        } catch {
            try? transitionEntry(
                entryID: entryID,
                from: .purging,
                to: .recycled,
                errorCode: "purgeIOFailure"
            )
            throw LibrarySlimmingRecycleError.ioFailure
        }
        try finalizePurged(snapshot)
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
        guard let earliestPurgeAfterMs = try database.pool.read({ db in
            try Int64.fetchOne(
                db,
                sql: "SELECT MIN(purge_after_ms) FROM recycle_entry WHERE state = 'recycled'"
            )
        }) else {
            return
        }
        let command = try LibrarySlimmingPurgeJobFactory.makeEnqueueCommand(
            jobID: idGenerator(),
            notBeforeMs: earliestPurgeAfterMs
        )
        do {
            _ = try jobQueue.enqueue(command)
        } catch JobQueueError.activeCoalescingConflict {
            // The existing singleton job already covers the earliest outstanding
            // deadline. It is harmless if it wakes slightly early after a restore.
        }
    }

    @discardableResult
    func recoverInterruptedOperations() throws -> Int {
        try quarantineIO.ensureQuarantineRoot(at: quarantineRootURL)
        let entries = try loadInterruptedEntries()
        var recovered = 0
        for entry in entries {
            do {
                switch entry.state {
                case .pending:
                    try recoverPending(entry)
                    recovered += 1
                case .restoring:
                    try recoverRestoring(entry)
                    recovered += 1
                case .purging:
                    try recoverPurging(entry)
                    recovered += 1
                case .recycled, .restored, .purged, .failed:
                    continue
                }
            } catch {
                continue
            }
        }
        return recovered
    }

    // MARK: - Private

    private struct AssetSnapshot {
        let assetID: UUID
        let sourceID: UUID
        let locatorKind: String
        let relativePath: String?
        let fileName: String?
        let availability: String
        let sizeBytes: Int64?
        let modifiedAtNs: Int64?
        let resourceID: Data?
        let sha256: Data?
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
        guard let sizeBytes = asset.sizeBytes,
              let modifiedAtNs = asset.modifiedAtNs,
              let sha256 = asset.sha256,
              sha256.count == 32
        else {
            throw LibrarySlimmingRecycleError.sourceChanged
        }
        let expectedIdentity = FolderQuarantineExpectedIdentity(
            sizeBytes: sizeBytes,
            modifiedAtNs: modifiedAtNs,
            resourceID: asset.resourceID,
            sha256: sha256
        )

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO recycle_entry (
                    id, asset_id, source_kind, trashed_at_ms, purge_after_ms, state,
                    quarantine_relative_path, original_relative_path, error_code,
                    created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'file', ?, ?, 'pending', ?, ?, NULL, ?, ?)
                """,
                arguments: [
                    entryID.uuidString.lowercased(),
                    asset.assetID.uuidString.lowercased(),
                    now,
                    purgeAfter,
                    quarantineRelative,
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
                    quarantineRelativePath: quarantineRelative,
                    expectedIdentity: expectedIdentity
                )
            }
        } catch LibrarySlimmingRecycleError.mutationAuthorizationRequired {
            try markFailed(entryID: entryID, code: "mutationAuthorizationRequired")
            throw LibrarySlimmingRecycleError.mutationAuthorizationRequired
        } catch FolderQuarantineIOError.verificationFailed {
            try markFailed(entryID: entryID, code: "sourceChanged")
            throw LibrarySlimmingRecycleError.sourceChanged
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

    private func recoverPending(_ entry: EntrySnapshot) throws {
        guard let quarantinePath = entry.quarantineRelativePath else {
            try markFailed(entryID: entry.id, code: "interruptedBeforeMove")
            return
        }
        let quarantineExists = try quarantineIO.objectExists(
            rootURL: quarantineRootURL,
            relativePath: quarantinePath
        )
        let sourceID = try loadSourceID(assetID: entry.assetID)
        let sourceExists = try mutationAccess.withWritableSourceRoot(sourceID: sourceID) { root in
            try quarantineIO.objectExists(
                rootURL: root,
                relativePath: entry.originalRelativePath
            )
        }

        switch (sourceExists, quarantineExists) {
        case (false, true):
            try finalizeRecycled(entry)
        case (true, false):
            try markFailed(entryID: entry.id, code: "interruptedBeforeMove")
        case (true, true):
            try quarantineIO.deleteQuarantineObject(
                quarantineRootURL: quarantineRootURL,
                quarantineRelativePath: quarantinePath
            )
            try markFailed(entryID: entry.id, code: "interruptedDuplicate")
        case (false, false):
            try markFailed(entryID: entry.id, code: "interruptedMissingBoth")
        }
    }

    private func finalizeRecycled(_ entry: EntrySnapshot) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET state = 'recycled', error_code = NULL, updated_at_ms = ?
                WHERE id = ? AND state = 'pending'
                """,
                arguments: [clock.nowMs, entry.id.uuidString.lowercased()]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.invalidState
            }
            try db.execute(
                sql: """
                UPDATE asset
                SET availability = 'recycled', record_updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [clock.nowMs, entry.assetID.uuidString.lowercased()]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.notFound
            }
        }
    }

    private func recoverRestoring(_ entry: EntrySnapshot) throws {
        guard let quarantinePath = entry.quarantineRelativePath else {
            try markFailed(entryID: entry.id, code: "interruptedRestoreMissingPath")
            return
        }
        let quarantineExists = try quarantineIO.objectExists(
            rootURL: quarantineRootURL,
            relativePath: quarantinePath
        )
        let sourceID = try loadSourceID(assetID: entry.assetID)
        let sourceExists = try mutationAccess.withWritableSourceRoot(sourceID: sourceID) { root in
            try quarantineIO.objectExists(
                rootURL: root,
                relativePath: entry.originalRelativePath
            )
        }

        switch (sourceExists, quarantineExists) {
        case (true, false):
            try finalizeRestored(entry)
        case (false, true):
            try transitionEntry(
                entryID: entry.id,
                from: .restoring,
                to: .recycled,
                errorCode: "interruptedBeforeRestore"
            )
        case (true, true):
            try transitionEntry(
                entryID: entry.id,
                from: .restoring,
                to: .recycled,
                errorCode: "restoreConflict"
            )
        case (false, false):
            try markFailed(entryID: entry.id, code: "interruptedRestoreMissingBoth")
        }
    }

    private func finalizeRestored(_ entry: EntrySnapshot) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET state = 'restored', updated_at_ms = ?, error_code = NULL
                WHERE id = ? AND state = 'restoring'
                """,
                arguments: [clock.nowMs, entry.id.uuidString.lowercased()]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.invalidState
            }
            try db.execute(
                sql: """
                UPDATE asset
                SET availability = 'available', record_updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [clock.nowMs, entry.assetID.uuidString.lowercased()]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.notFound
            }
        }
    }

    private func recoverPurging(_ entry: EntrySnapshot) throws {
        if let quarantinePath = entry.quarantineRelativePath {
            let quarantineExists = try quarantineIO.objectExists(
                rootURL: quarantineRootURL,
                relativePath: quarantinePath
            )
            if quarantineExists {
                do {
                    try quarantineIO.deleteQuarantineObject(
                        quarantineRootURL: quarantineRootURL,
                        quarantineRelativePath: quarantinePath
                    )
                } catch {
                    try? transitionEntry(
                        entryID: entry.id,
                        from: .purging,
                        to: .recycled,
                        errorCode: "purgeIOFailure"
                    )
                    throw LibrarySlimmingRecycleError.ioFailure
                }
            }
        }
        try finalizePurged(entry)
    }

    private func finalizePurged(_ entry: EntrySnapshot) throws {
        try database.pool.write { db in
            let assetID = entry.assetID.uuidString.lowercased()
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET quarantine_relative_path = NULL,
                    original_relative_path = NULL,
                    error_code = NULL,
                    updated_at_ms = ?
                WHERE asset_id = ?
                """,
                arguments: [clock.nowMs, assetID]
            )
            try db.execute(
                sql: "DELETE FROM asset_tag_decision WHERE asset_id = ?",
                arguments: [assetID]
            )
            try db.execute(
                sql: "DELETE FROM asset WHERE id = ?",
                arguments: [assetID]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.notFound
            }
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET state = 'purged', updated_at_ms = ?
                WHERE id = ? AND state = 'purging' AND asset_id IS NULL
                """,
                arguments: [clock.nowMs, entry.id.uuidString.lowercased()]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.invalidState
            }
        }
    }

    private func transitionEntry(
        entryID: UUID,
        from: RecycleEntryState,
        to: RecycleEntryState,
        errorCode: String?
    ) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET state = ?, error_code = ?, updated_at_ms = ?
                WHERE id = ? AND state = ?
                """,
                arguments: [
                    to.rawValue,
                    errorCode,
                    clock.nowMs,
                    entryID.uuidString.lowercased(),
                    from.rawValue,
                ]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.invalidState
            }
        }
    }

    private func loadInterruptedEntries() throws -> [EntrySnapshot] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, asset_id, state, quarantine_relative_path, original_relative_path
                FROM recycle_entry
                WHERE state IN ('pending', 'restoring', 'purging')
                ORDER BY updated_at_ms ASC, id ASC
                """
            )
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["id"]),
                      let assetID = UUID(uuidString: row["asset_id"]),
                      let state = RecycleEntryState(rawValue: row["state"]),
                      let originalRelativePath: String = row["original_relative_path"]
                else {
                    return nil
                }
                return EntrySnapshot(
                    id: id,
                    assetID: assetID,
                    state: state,
                    quarantineRelativePath: row["quarantine_relative_path"],
                    originalRelativePath: originalRelativePath
                )
            }
        }
    }

    private func loadAsset(assetID: UUID) throws -> AssetSnapshot {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    a.id, a.source_id, a.locator_kind, a.relative_path, a.file_name,
                    a.availability, f.size_bytes, f.modified_at_ns, f.resource_id, f.sha256
                FROM asset a
                LEFT JOIN file_fingerprint f ON f.asset_id = a.id
                WHERE a.id = ?
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
                availability: row["availability"],
                sizeBytes: row["size_bytes"],
                modifiedAtNs: row["modified_at_ns"],
                resourceID: row["resource_id"],
                sha256: row["sha256"]
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
