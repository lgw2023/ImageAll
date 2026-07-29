import Foundation
import GRDB

struct AppOwnedAssetPixelCachePurger: Sendable {
    let database: CatalogDatabase
    let derivedCachesDirectory: URL
    let photosOriginalCache: PhotosOriginalCacheService

    func purge(assetID: UUID) throws {
        let entries: [(id: UUID, format: DerivedImageStorageFormat)] = try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, storage_format
                FROM derived_image_cache_entry
                WHERE asset_id = ?
                ORDER BY id
                """,
                arguments: [assetID.uuidString.lowercased()]
            ).compactMap { row in
                guard let id = UUID(uuidString: row["id"]),
                      let format = DerivedImageStorageFormat(rawValue: row["storage_format"])
                else { return nil }
                return (id, format)
            }
        }

        if !entries.isEmpty {
            let store = DerivedImageCacheStore(cachesDirectory: derivedCachesDirectory)
            let session = try store.ensureLayout()
            for entry in entries {
                try store.deleteObject(
                    entryID: entry.id,
                    format: entry.format,
                    session: session
                )
                try database.pool.write { db in
                    try db.execute(
                        sql: """
                        DELETE FROM derived_image_cache_entry
                        WHERE id = ? AND asset_id = ?
                        """,
                        arguments: [
                            entry.id.uuidString.lowercased(),
                            assetID.uuidString.lowercased(),
                        ]
                    )
                }
            }
        }

        try photosOriginalCache.removePixelObject(assetID: assetID)
    }
}

struct LibrarySlimmingRecycleService: LibrarySlimmingRecyclePort {
    let database: CatalogDatabase
    let mutationAccess: any FolderMutationAccessing
    let photosMutation: (any PhotosLibraryMutationPort)?
    let quarantineRootURL: URL
    let clock: any JobClock
    let jobQueue: (any JobQueue)?
    let pixelCachePurger: AppOwnedAssetPixelCachePurger?
    var quarantineIO: FolderQuarantineIO
    var idGenerator: @Sendable () -> UUID

    init(
        database: CatalogDatabase,
        mutationAccess: any FolderMutationAccessing,
        quarantineRootURL: URL,
        clock: any JobClock,
        jobQueue: (any JobQueue)? = nil,
        photosMutation: (any PhotosLibraryMutationPort)? = nil,
        pixelCachePurger: AppOwnedAssetPixelCachePurger? = nil,
        quarantineIO: FolderQuarantineIO = FolderQuarantineIO(),
        idGenerator: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.database = database
        self.mutationAccess = mutationAccess
        self.photosMutation = photosMutation
        self.quarantineRootURL = quarantineRootURL
        self.clock = clock
        self.jobQueue = jobQueue
        self.pixelCachePurger = pixelCachePurger
        self.quarantineIO = quarantineIO
        self.idGenerator = idGenerator
    }

    func makeIdenticalCleanupPlan(
        clusters: [SlimmingCluster]
    ) throws -> LibrarySlimmingIdenticalCleanupPlan {
        let assetIDs = Array(
            Set(
                clusters
                    .filter { $0.kind == .byteIdentical }
                    .flatMap(\.memberAssetIDs)
            )
        )
        guard !assetIDs.isEmpty else {
            return LibrarySlimmingIdenticalCleanupPlanner.makePlan(
                clusters: clusters,
                candidates: []
            )
        }

        let candidates = try database.pool.read { db in
            var loaded: [LibrarySlimmingIdenticalCleanupCandidate] = []
            loaded.reserveCapacity(assetIDs.count)
            let idStrings = assetIDs.map { $0.uuidString.lowercased() }
            let chunkSize = 400
            for start in stride(from: 0, to: idStrings.count, by: chunkSize) {
                let end = min(start + chunkSize, idStrings.count)
                let chunk = Array(idStrings[start ..< end])
                let placeholders = Array(repeating: "?", count: chunk.count)
                    .joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT
                        a.id AS asset_id,
                        a.source_id AS source_id,
                        a.locator_kind AS locator_kind,
                        s.display_name AS source_display_name
                    FROM asset a
                    JOIN source s ON s.id = a.source_id
                    WHERE a.id IN (\(placeholders))
                      AND a.locator_state = 'current'
                      AND a.availability = 'available'
                      AND s.state = 'active'
                    """,
                    arguments: StatementArguments(chunk)
                )
                for row in rows {
                    guard let assetID = UUID(uuidString: row["asset_id"]),
                          let sourceID = UUID(uuidString: row["source_id"])
                    else { continue }
                    let sourceKind: RecycleSourceKind
                    switch row["locator_kind"] as String {
                    case AssetLocatorKind.photos.rawValue:
                        sourceKind = .photos
                    case AssetLocatorKind.file.rawValue:
                        sourceKind = .file
                    default:
                        continue
                    }
                    loaded.append(
                        LibrarySlimmingIdenticalCleanupCandidate(
                            assetID: assetID,
                            sourceID: sourceID,
                            sourceKind: sourceKind,
                            sourceDisplayName: row["source_display_name"]
                        )
                    )
                }
            }
            return loaded
        }
        return LibrarySlimmingIdenticalCleanupPlanner.makePlan(
            clusters: clusters,
            candidates: candidates
        )
    }

    func moveAssetsToRecycle(assetIDs: [UUID]) throws -> LibrarySlimmingRecycleMoveOutcome {
        var outcome = LibrarySlimmingRecycleMoveOutcome(
            recycledEntryIDs: [],
            skippedPhotosAssetIDs: [],
            failedAssetIDs: [],
            authorizationRequiredSourceIDs: [],
            authorizationRequiredAssetIDs: [],
            authorizationDeniedPhotosAssetIDs: []
        )
        try quarantineIO.ensureQuarantineRoot(at: quarantineRootURL)

        var photosAssets: [AssetSnapshot] = []
        for assetID in assetIDs {
            do {
                let asset = try loadAsset(assetID: assetID)
                guard asset.availability == AssetAvailability.available.rawValue else {
                    throw asset.availability == AssetAvailability.recycled.rawValue
                        ? LibrarySlimmingRecycleError.alreadyRecycled
                        : LibrarySlimmingRecycleError.invalidState
                }
                switch asset.locatorKind {
                case AssetLocatorKind.file.rawValue:
                    outcome.recycledEntryIDs.append(try recycleFileAsset(asset))
                case AssetLocatorKind.photos.rawValue:
                    guard let localIdentifier = asset.photosLocalIdentifier,
                          !localIdentifier.isEmpty
                    else {
                        throw LibrarySlimmingRecycleError.invalidState
                    }
                    photosAssets.append(asset)
                default:
                    throw LibrarySlimmingRecycleError.invalidState
                }
            } catch LibrarySlimmingRecycleError.mutationAuthorizationRequired {
                if let sourceID = try? loadSourceID(assetID: assetID) {
                    if !outcome.authorizationRequiredSourceIDs.contains(sourceID) {
                        outcome.authorizationRequiredSourceIDs.append(sourceID)
                    }
                }
                outcome.failedAssetIDs.append(assetID)
                outcome.authorizationRequiredAssetIDs.append(assetID)
            } catch LibrarySlimmingRecycleError.photosAuthorizationRequired {
                outcome.failedAssetIDs.append(assetID)
                outcome.authorizationDeniedPhotosAssetIDs.append(assetID)
            } catch {
                outcome.failedAssetIDs.append(assetID)
            }
        }
        if !photosAssets.isEmpty {
            let photosAssetIDs = photosAssets.map(\.assetID)
            do {
                outcome.recycledEntryIDs.append(
                    contentsOf: try recyclePhotosAssets(photosAssets)
                )
            } catch LibrarySlimmingRecycleError.photosAuthorizationRequired {
                outcome.failedAssetIDs.append(contentsOf: photosAssetIDs)
                outcome.authorizationDeniedPhotosAssetIDs.append(contentsOf: photosAssetIDs)
            } catch {
                outcome.failedAssetIDs.append(contentsOf: photosAssetIDs)
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
                    r.photos_local_identifier, r.error_code, a.file_name
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
                    photosLocalIdentifier: row["photos_local_identifier"],
                    errorCode: row["error_code"],
                    fileName: row["file_name"]
                )
            }
        }
    }

    func restore(entryID: UUID) throws {
        let snapshot = try loadActiveEntry(entryID: entryID)
        guard snapshot.state == .recycled else {
            throw LibrarySlimmingRecycleError.invalidState
        }
        switch snapshot.sourceKind {
        case .file:
            try restoreFileEntry(snapshot)
        case .photos:
            try restorePhotosEntry(snapshot)
        }
    }

    func purgeNow(entryID: UUID) throws {
        let snapshot = try loadActiveEntry(entryID: entryID)
        guard snapshot.state == .recycled else {
            throw LibrarySlimmingRecycleError.invalidState
        }
        switch snapshot.sourceKind {
        case .file:
            try purgeFileEntry(snapshot)
        case .photos:
            try purgePhotosEntry(snapshot)
        }
    }

    func purgeExpired(nowMs: Int64) throws -> Int {
        _ = try? reconcilePhotosRecycleEntries()
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
            // Existing singleton already covers the earliest outstanding deadline.
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
        recovered += try reconcilePhotosRecycleEntries()
        return recovered
    }

    @discardableResult
    func reconcilePhotosRecycleEntries() throws -> Int {
        guard let photosMutation else { return 0 }
        let entries = try loadPhotosRecycledEntries()
        var converged = 0
        for entry in entries {
            guard let localIdentifier = entry.photosLocalIdentifier else { continue }
            let presence: PhotosAssetPresence
            do {
                presence = try photosMutation.presence(localIdentifier: localIdentifier)
            } catch PhotosLibraryMutationError.authorizationDenied,
                    PhotosLibraryMutationError.authorizationRestricted,
                    PhotosLibraryMutationError.notDetermined
            {
                continue
            } catch {
                continue
            }
            switch presence {
            case .available:
                if clock.nowMs - entry.trashedAtMs
                    < LibrarySlimmingRecyclePolicy.photosDeleteConvergenceGraceMs
                {
                    continue
                }
                try markPhotosRestored(entry)
                converged += 1
            case .missing:
                if entry.purgeAfterMs <= clock.nowMs {
                    try transitionEntry(
                        entryID: entry.id,
                        from: .recycled,
                        to: .purging,
                        errorCode: nil
                    )
                    try pixelCachePurger?.purge(assetID: entry.assetID)
                    try finalizePurged(entry)
                    converged += 1
                }
            case .recentlyDeleted:
                if entry.purgeAfterMs <= clock.nowMs {
                    try transitionEntry(
                        entryID: entry.id,
                        from: .recycled,
                        to: .purging,
                        errorCode: nil
                    )
                    try pixelCachePurger?.purge(assetID: entry.assetID)
                    try finalizePurged(entry)
                    converged += 1
                }
            }
        }
        return converged
    }

    func slimmingHiddenAssetIDs(from assetIDs: [UUID]) throws -> Set<UUID> {
        guard !assetIDs.isEmpty else { return [] }
        let normalized = assetIDs.map { $0.uuidString.lowercased() }
        let placeholders = Array(repeating: "?", count: normalized.count).joined(separator: ", ")
        return try database.pool.read { db in
            var hidden = Set<UUID>()
            let recycledRows = try Row.fetchAll(
                db,
                sql: """
                SELECT id FROM asset
                WHERE id IN (\(placeholders)) AND availability = 'recycled'
                """,
                arguments: StatementArguments(normalized)
            )
            for row in recycledRows {
                if let id = UUID(uuidString: row["id"]) {
                    hidden.insert(id)
                }
            }
            let pendingRows = try Row.fetchAll(
                db,
                sql: """
                SELECT asset_id FROM recycle_entry
                WHERE asset_id IN (\(placeholders))
                  AND state IN ('recycled', 'pending')
                """,
                arguments: StatementArguments(normalized)
            )
            for row in pendingRows {
                if let id = UUID(uuidString: row["asset_id"]) {
                    hidden.insert(id)
                }
            }
            return hidden
        }
    }

    func restoredAssetReplacements(from assetIDs: [UUID]) throws -> [UUID: UUID] {
        guard !assetIDs.isEmpty else { return [:] }
        var replacements: [UUID: UUID] = [:]
        let normalized = Array(Set(assetIDs)).map { $0.uuidString.lowercased() }
        for start in stride(from: 0, to: normalized.count, by: 400) {
            let chunk = Array(normalized[start ..< min(start + 400, normalized.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let rows = try database.pool.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT historical.id AS historical_id, current.id AS current_id
                    FROM asset AS historical
                    JOIN recycle_entry AS recycle
                      ON recycle.asset_id = historical.id
                     AND recycle.source_kind = 'file'
                     AND recycle.state = 'restored'
                    JOIN asset AS current
                      ON current.source_id = historical.source_id
                     AND current.relative_path = historical.relative_path
                     AND current.locator_kind = 'file'
                     AND current.locator_state = 'current'
                     AND current.availability = 'available'
                     AND current.id != historical.id
                    JOIN file_fingerprint AS historical_file
                      ON historical_file.asset_id = historical.id
                    JOIN file_fingerprint AS current_file
                      ON current_file.asset_id = current.id
                    LEFT JOIN asset_similarity_fingerprint AS historical_similarity
                      ON historical_similarity.asset_id = historical.id
                     AND historical_similarity.content_revision = historical.content_revision
                    LEFT JOIN asset_similarity_fingerprint AS current_similarity
                      ON current_similarity.asset_id = current.id
                     AND current_similarity.content_revision = current.content_revision
                    WHERE historical.id IN (\(placeholders))
                      AND historical.locator_state = 'historical'
                      AND historical.availability = 'missing'
                      AND historical_file.size_bytes = current_file.size_bytes
                      AND historical_file.modified_at_ns = current_file.modified_at_ns
                      AND COALESCE(
                            historical_file.sha256,
                            historical_similarity.content_sha256
                          ) IS NOT NULL
                      AND COALESCE(
                            historical_file.sha256,
                            historical_similarity.content_sha256
                          ) = COALESCE(
                            current_file.sha256,
                            current_similarity.content_sha256
                          )
                    """,
                    arguments: StatementArguments(chunk)
                )
            }
            for row in rows {
                guard let historical = UUID(uuidString: row["historical_id"]),
                      let current = UUID(uuidString: row["current_id"])
                else { continue }
                replacements[historical] = current
            }
        }
        return replacements
    }

    // MARK: - Private

    private struct AssetSnapshot {
        let assetID: UUID
        let sourceID: UUID
        let locatorKind: String
        let relativePath: String?
        let photosLocalIdentifier: String?
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
        let sourceKind: RecycleSourceKind
        let state: RecycleEntryState
        let quarantineRelativePath: String?
        let originalRelativePath: String?
        let photosLocalIdentifier: String?
        let trashedAtMs: Int64
        let purgeAfterMs: Int64
    }

    private func recycleFileAsset(_ asset: AssetSnapshot) throws -> UUID {
        guard let relativePath = asset.relativePath else {
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
                    quarantine_relative_path, original_relative_path, photos_local_identifier,
                    error_code, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'file', ?, ?, 'pending', ?, ?, NULL, NULL, ?, ?)
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
        } catch LibrarySlimmingRecycleError.mutationAuthorizationInvalid {
            try markFailed(entryID: entryID, code: "mutationAuthorizationInvalid")
            throw LibrarySlimmingRecycleError.mutationAuthorizationInvalid
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

    private func recyclePhotosAssets(_ assets: [AssetSnapshot]) throws -> [UUID] {
        guard !assets.isEmpty else { return [] }
        guard let photosMutation else {
            throw LibrarySlimmingRecycleError.photosAuthorizationRequired
        }
        switch photosMutation.authorizationState() {
        case .authorized:
            break
        case .denied, .restricted, .notDetermined:
            throw LibrarySlimmingRecycleError.photosAuthorizationRequired
        }

        let now = clock.nowMs
        let purgeAfter = LibrarySlimmingRecyclePolicy.purgeAfterMs(trashedAtMs: now)
        let pendingEntries: [(asset: AssetSnapshot, entryID: UUID, localIdentifier: String)] =
            try assets.map { asset in
                guard let localIdentifier = asset.photosLocalIdentifier,
                      !localIdentifier.isEmpty
                else {
                    throw LibrarySlimmingRecycleError.invalidState
                }
                return (asset, idGenerator(), localIdentifier)
            }

        try database.pool.write { db in
            for pending in pendingEntries {
                let displayPath = pending.asset.fileName ?? pending.localIdentifier
                try db.execute(
                    sql: """
                    INSERT INTO recycle_entry (
                        id, asset_id, source_kind, trashed_at_ms, purge_after_ms, state,
                        quarantine_relative_path, original_relative_path, photos_local_identifier,
                        error_code, created_at_ms, updated_at_ms
                    ) VALUES (?, ?, 'photos', ?, ?, 'pending', NULL, ?, ?, NULL, ?, ?)
                    """,
                    arguments: [
                        pending.entryID.uuidString.lowercased(),
                        pending.asset.assetID.uuidString.lowercased(),
                        now,
                        purgeAfter,
                        displayPath,
                        pending.localIdentifier,
                        now,
                        now,
                    ]
                )
            }
        }

        do {
            try photosMutation.moveToRecentlyDeleted(
                localIdentifiers: pendingEntries.map(\.localIdentifier)
            )
        } catch PhotosLibraryMutationError.authorizationDenied,
                PhotosLibraryMutationError.authorizationRestricted,
                PhotosLibraryMutationError.notDetermined
        {
            for pending in pendingEntries {
                try markFailed(
                    entryID: pending.entryID,
                    code: "photosAuthorizationRequired"
                )
            }
            throw LibrarySlimmingRecycleError.photosAuthorizationRequired
        } catch {
            for pending in pendingEntries {
                try markFailed(entryID: pending.entryID, code: "photosMutationFailed")
            }
            throw LibrarySlimmingRecycleError.photosMutationFailed
        }

        try database.pool.write { db in
            for pending in pendingEntries {
                try db.execute(
                    sql: """
                    UPDATE recycle_entry
                    SET state = 'recycled', error_code = NULL, updated_at_ms = ?
                    WHERE id = ?
                    """,
                    arguments: [clock.nowMs, pending.entryID.uuidString.lowercased()]
                )
                try db.execute(
                    sql: """
                    UPDATE asset
                    SET availability = 'recycled', record_updated_at_ms = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        clock.nowMs,
                        pending.asset.assetID.uuidString.lowercased(),
                    ]
                )
            }
        }
        return pendingEntries.map(\.entryID)
    }

    private func restoreFileEntry(_ snapshot: EntrySnapshot) throws {
        guard let quarantinePath = snapshot.quarantineRelativePath,
              let originalRelativePath = snapshot.originalRelativePath
        else {
            throw LibrarySlimmingRecycleError.invalidState
        }
        let sourceID = try loadSourceID(assetID: snapshot.assetID)
        try transitionEntry(
            entryID: snapshot.id,
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
                    originalRelativePath: originalRelativePath
                )
            }
        } catch FolderQuarantineIOError.targetExists {
            try? transitionEntry(
                entryID: snapshot.id,
                from: .restoring,
                to: .recycled,
                errorCode: "restoreConflict"
            )
            throw LibrarySlimmingRecycleError.restoreConflict
        } catch LibrarySlimmingRecycleError.mutationAuthorizationRequired {
            try? transitionEntry(
                entryID: snapshot.id,
                from: .restoring,
                to: .recycled,
                errorCode: "mutationAuthorizationRequired"
            )
            throw LibrarySlimmingRecycleError.mutationAuthorizationRequired
        } catch LibrarySlimmingRecycleError.mutationAuthorizationInvalid {
            try? transitionEntry(
                entryID: snapshot.id,
                from: .restoring,
                to: .recycled,
                errorCode: "mutationAuthorizationInvalid"
            )
            throw LibrarySlimmingRecycleError.mutationAuthorizationInvalid
        } catch {
            try? transitionEntry(
                entryID: snapshot.id,
                from: .restoring,
                to: .recycled,
                errorCode: "restoreIOFailure"
            )
            throw LibrarySlimmingRecycleError.ioFailure
        }

        try finalizeRestored(snapshot)
    }

    private func restorePhotosEntry(_ snapshot: EntrySnapshot) throws {
        guard let localIdentifier = snapshot.photosLocalIdentifier,
              let photosMutation
        else {
            throw LibrarySlimmingRecycleError.invalidState
        }
        let presence: PhotosAssetPresence
        do {
            presence = try photosMutation.presence(localIdentifier: localIdentifier)
        } catch PhotosLibraryMutationError.authorizationDenied,
                PhotosLibraryMutationError.authorizationRestricted,
                PhotosLibraryMutationError.notDetermined
        {
            throw LibrarySlimmingRecycleError.photosAuthorizationRequired
        } catch {
            throw LibrarySlimmingRecycleError.photosMutationFailed
        }
        switch presence {
        case .available:
            try transitionEntry(
                entryID: snapshot.id,
                from: .recycled,
                to: .restoring,
                errorCode: nil
            )
            try finalizeRestored(snapshot)
        case .recentlyDeleted, .missing:
            throw LibrarySlimmingRecycleError.photosRestoreRequiresPhotosApp
        }
    }

    private func purgeFileEntry(_ snapshot: EntrySnapshot) throws {
        guard let quarantinePath = snapshot.quarantineRelativePath else {
            throw LibrarySlimmingRecycleError.invalidState
        }
        try transitionEntry(
            entryID: snapshot.id,
            from: .recycled,
            to: .purging,
            errorCode: nil
        )
        do {
            try pixelCachePurger?.purge(assetID: snapshot.assetID)
            try quarantineIO.deleteQuarantineObject(
                quarantineRootURL: quarantineRootURL,
                quarantineRelativePath: quarantinePath
            )
        } catch {
            try? transitionEntry(
                entryID: snapshot.id,
                from: .purging,
                to: .recycled,
                errorCode: "purgeIOFailure"
            )
            throw LibrarySlimmingRecycleError.ioFailure
        }
        try finalizePurged(snapshot)
    }

    private func purgePhotosEntry(_ snapshot: EntrySnapshot) throws {
        throw LibrarySlimmingRecycleError.photosManagedBySystem
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
        if entry.sourceKind == .photos {
            guard let localIdentifier = entry.photosLocalIdentifier,
                  let photosMutation
            else {
                try markFailed(entryID: entry.id, code: "interruptedPhotosPending")
                return
            }
            let presence: PhotosAssetPresence
            do {
                presence = try photosMutation.presence(localIdentifier: localIdentifier)
            } catch PhotosLibraryMutationError.authorizationDenied,
                    PhotosLibraryMutationError.authorizationRestricted,
                    PhotosLibraryMutationError.notDetermined
            {
                throw LibrarySlimmingRecycleError.photosAuthorizationRequired
            } catch {
                throw LibrarySlimmingRecycleError.photosMutationFailed
            }
            switch presence {
            case .available:
                try markFailed(entryID: entry.id, code: "interruptedBeforePhotosMove")
            case .recentlyDeleted, .missing:
                try finalizeRecycled(entry)
            }
            return
        }
        guard let quarantinePath = entry.quarantineRelativePath,
              let originalRelativePath = entry.originalRelativePath
        else {
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
                relativePath: originalRelativePath
            )
        }

        switch (sourceExists, quarantineExists) {
        case (false, true):
            try finalizeRecycled(entry)
        case (true, false):
            try markFailed(entryID: entry.id, code: "interruptedBeforeMove")
        case (true, true):
            // The original path may have been recreated after the move completed.
            // Keep both objects: deleting either side would make an ambiguous crash
            // recovery destructive. The user can resolve the retained conflict.
            try markFailed(entryID: entry.id, code: "interruptedConflict")
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
        if entry.sourceKind == .photos {
            guard let localIdentifier = entry.photosLocalIdentifier,
                  let photosMutation
            else {
                try markFailed(entryID: entry.id, code: "interruptedPhotosRestore")
                return
            }
            let presence = (try? photosMutation.presence(localIdentifier: localIdentifier)) ?? .missing
            switch presence {
            case .available:
                try finalizeRestored(entry)
            case .recentlyDeleted, .missing:
                try transitionEntry(
                    entryID: entry.id,
                    from: .restoring,
                    to: .recycled,
                    errorCode: "photosRestoreRequiresPhotosApp"
                )
            }
            return
        }
        guard let quarantinePath = entry.quarantineRelativePath,
              let originalRelativePath = entry.originalRelativePath
        else {
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
                relativePath: originalRelativePath
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

    private func markPhotosRestored(_ entry: EntrySnapshot) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET state = 'restored', updated_at_ms = ?, error_code = NULL
                WHERE id = ? AND state = 'recycled'
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
        if entry.sourceKind == .photos {
            try transitionEntry(
                entryID: entry.id,
                from: .purging,
                to: .recycled,
                errorCode: "photosManagedBySystem"
            )
            return
        }
        try pixelCachePurger?.purge(assetID: entry.assetID)
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
                    photos_local_identifier = NULL,
                    error_code = NULL,
                    state = 'purged',
                    updated_at_ms = ?
                WHERE id = ? AND asset_id = ? AND state = 'purging'
                """,
                arguments: [
                    clock.nowMs,
                    entry.id.uuidString.lowercased(),
                    assetID,
                ]
            )
            guard db.changesCount == 1 else {
                throw LibrarySlimmingRecycleError.invalidState
            }
            // Keep the recycled catalog row as a non-browseable tombstone. Its
            // tag decisions, fingerprints/features, training samples, and model
            // provenance remain useful knowledge after the original bytes are gone.
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
                SELECT
                    id, asset_id, source_kind, state, quarantine_relative_path,
                    original_relative_path, photos_local_identifier, trashed_at_ms, purge_after_ms
                FROM recycle_entry
                WHERE state IN ('pending', 'restoring', 'purging')
                ORDER BY updated_at_ms ASC, id ASC
                """
            )
            return rows.compactMap(Self.mapEntrySnapshot)
        }
    }

    private func loadPhotosRecycledEntries() throws -> [EntrySnapshot] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    id, asset_id, source_kind, state, quarantine_relative_path,
                    original_relative_path, photos_local_identifier, trashed_at_ms, purge_after_ms
                FROM recycle_entry
                WHERE state = 'recycled' AND source_kind = 'photos'
                ORDER BY updated_at_ms ASC, id ASC
                """
            )
            return rows.compactMap(Self.mapEntrySnapshot)
        }
    }

    private static func mapEntrySnapshot(_ row: Row) -> EntrySnapshot? {
        guard let id = UUID(uuidString: row["id"]),
              let assetID = UUID(uuidString: row["asset_id"]),
              let sourceKind = RecycleSourceKind(rawValue: row["source_kind"]),
              let state = RecycleEntryState(rawValue: row["state"])
        else {
            return nil
        }
        return EntrySnapshot(
            id: id,
            assetID: assetID,
            sourceKind: sourceKind,
            state: state,
            quarantineRelativePath: row["quarantine_relative_path"],
            originalRelativePath: row["original_relative_path"],
            photosLocalIdentifier: row["photos_local_identifier"],
            trashedAtMs: row["trashed_at_ms"],
            purgeAfterMs: row["purge_after_ms"]
        )
    }

    private func loadAsset(assetID: UUID) throws -> AssetSnapshot {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    a.id, a.source_id, a.locator_kind, a.relative_path,
                    a.photos_local_identifier, a.file_name, a.availability,
                    f.size_bytes, f.modified_at_ns, f.resource_id,
                    COALESCE(f.sha256, sf.content_sha256) AS sha256
                FROM asset a
                LEFT JOIN file_fingerprint f ON f.asset_id = a.id
                LEFT JOIN asset_similarity_fingerprint sf
                    ON sf.asset_id = a.id
                   AND sf.content_revision = a.content_revision
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
                photosLocalIdentifier: row["photos_local_identifier"],
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
                SELECT
                    id, asset_id, source_kind, state, quarantine_relative_path,
                    original_relative_path, photos_local_identifier, trashed_at_ms, purge_after_ms
                FROM recycle_entry WHERE id = ?
                """,
                arguments: [entryID.uuidString.lowercased()]
            ),
                let snapshot = Self.mapEntrySnapshot(row)
            else {
                throw LibrarySlimmingRecycleError.notFound
            }
            return snapshot
        }
    }
}

final class UserDefaultsLibrarySlimmingRecycleConfirmationPreferenceStore:
    LibrarySlimmingRecycleConfirmationPreferenceStore,
    @unchecked Sendable
{
    private static let skipsMoveConfirmationKey =
        "library.slimming.recycle.skip-move-confirmation"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var skipsMoveConfirmation: Bool {
        get { defaults.bool(forKey: Self.skipsMoveConfirmationKey) }
        set { defaults.set(newValue, forKey: Self.skipsMoveConfirmationKey) }
    }
}
