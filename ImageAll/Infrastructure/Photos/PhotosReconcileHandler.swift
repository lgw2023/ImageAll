import Foundation
import GRDB

private struct PhotosReconcilePayload: Sendable {
    let sourceID: UUID

    init(data: Data) throws {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["contract_version"] as? Int == 1,
            let sourceIDString = object["source_id"] as? String,
            let sourceID = UUID(uuidString: sourceIDString)
        else {
            throw PhotosReconcileError.invalidPayload
        }
        self.sourceID = sourceID
    }
}

private struct PhotosReconcileCheckpoint: Codable, Sendable {
    let generation: Int
    let processedCount: Int
    let frozenChangeToken: Data?
    let replayChangeToken: Data?
    let startedDirtyEpoch: Int?

    enum CodingKeys: String, CodingKey {
        case generation
        case processedCount = "processed_count"
        case frozenChangeToken = "frozen_change_token"
        case replayChangeToken = "replay_change_token"
        case startedDirtyEpoch = "started_dirty_epoch"
    }

    var jobCheckpoint: JobCheckpoint {
        get throws {
            JobCheckpoint(version: 1, data: try JSONEncoder().encode(self))
        }
    }
}

private enum PhotosReconcileError: Error {
    case invalidPayload
    case invalidCheckpoint
    case sourceUnavailable
}

private struct PhotosReconcileSafeBoundaryReached: Error {
    let snapshot: JobRecordSnapshot
}

struct PhotosReconcileHandler: LeaseBoundJobHandler, Sendable {
    let database: CatalogDatabase
    let queue: GRDBJobQueue
    let access: any PhotosLibraryAccessPort
    let changeHistory: (any PhotosChangeHistoryPort)?
    let clock: any JobClock
    let batchSize: Int
    let idGenerator: @Sendable () -> UUID

    var kind: String { PhotosReconcileJobFactory.kind }
    var supportedPayloadVersions: Set<Int> { [PhotosReconcileJobFactory.payloadVersion] }
    var supportedCheckpointVersions: Set<Int> { [1] }

    init(
        database: CatalogDatabase,
        queue: GRDBJobQueue,
        access: any PhotosLibraryAccessPort,
        changeHistory: (any PhotosChangeHistoryPort)? = nil,
        clock: any JobClock = SystemJobClock(),
        batchSize: Int = 25,
        idGenerator: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.database = database
        self.queue = queue
        self.access = access
        self.changeHistory = changeHistory
        self.clock = clock
        self.batchSize = batchSize
        self.idGenerator = idGenerator
    }

    func execute(
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?
    ) -> JobHandlerExecutionResult {
        failure(.photosPersistenceFailure, checkpoint: checkpoint)
    }

    func execute(
        lease: JobLeaseToken,
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?,
        context: JobLeaseExecutionContext
    ) throws -> JobHandlerExecutionResult {
        var currentState: PhotosReconcileCheckpoint?
        var sourceID: UUID?
        let persistedProgress = (try? queue.fetchJob(id: lease.jobID).progress)
            ?? JobProgress(completed: 0, total: nil)
        let persistedCompleted = persistedProgress.completed
        do {
            guard payloadVersion == PhotosReconcileJobFactory.payloadVersion else {
                throw PhotosReconcileError.invalidPayload
            }
            let decodedPayload = try PhotosReconcilePayload(data: payload)
            sourceID = decodedPayload.sourceID
            if checkpoint == nil {
                let sourceState = try persistedSourceSyncState(sourceID: decodedPayload.sourceID)
                if let changeHistory,
                   let changeToken = sourceState.changeToken,
                   try hasCompletedFullPhotosEnumeration(sourceID: decodedPayload.sourceID)
                {
                    do {
                        return try executeIncrementalChanges(
                            lease: lease,
                            sourceID: decodedPayload.sourceID,
                            changeToken: changeToken,
                            startedDirtyEpoch: sourceState.dirtyEpoch,
                            changeHistory: changeHistory,
                            leaseDurationMs: context.leaseDurationMs
                        )
                    } catch PhotosLibraryError.changeTokenInvalid {
                        // The source cursor can no longer prove a continuous history.
                        // A new full generation must complete before missing facts change.
                    }
                }
            }
            let frozenChangeToken = checkpoint == nil ? try changeHistory?.currentChangeToken() : nil
            var state = try beginOrResume(
                lease: lease,
                sourceID: decodedPayload.sourceID,
                checkpoint: checkpoint,
                frozenChangeToken: frozenChangeToken,
                leaseDurationMs: context.leaseDurationMs
            )
            currentState = state
            var enumerationTotal = persistedProgress.total ?? state.processedCount
            let heartbeatIntervalMs = max(1, context.leaseDurationMs / 2)
            var lastLeaseRenewedAtMs = clock.nowMs

            // Legacy checkpoints counted supported assets, which is a safe lower-bound
            // for the raw PhotoKit offset: upgrades may repeat work but never skip it.
            try access.enumerateStaticImages(
                startingAt: state.processedCount,
                batchSize: batchSize,
                onAssetEnumerated: {
                    let nowMs = clock.nowMs
                    guard nowMs - lastLeaseRenewedAtMs >= heartbeatIntervalMs else { return }
                    let snapshot = try queue.commitLeaseProtectedBatch(
                        input: SafeBatchCommitInput(
                            lease: lease,
                            outcome: .continue,
                            checkpoint: try state.jobCheckpoint,
                            progress: JobProgress(
                                completed: state.processedCount,
                                total: enumerationTotal
                            ),
                            leaseDurationMs: context.leaseDurationMs
                        )
                    ) { _ in }
                    lastLeaseRenewedAtMs = nowMs
                    guard snapshot.state == .running else {
                        throw PhotosReconcileSafeBoundaryReached(snapshot: snapshot)
                    }
                },
                onBatch: { batch in
                    guard batch.completedCount >= state.processedCount,
                          batch.totalCount >= batch.completedCount
                    else {
                        throw PhotosReconcileError.invalidCheckpoint
                    }
                    let nextState = PhotosReconcileCheckpoint(
                        generation: state.generation,
                        processedCount: batch.completedCount,
                        frozenChangeToken: state.frozenChangeToken,
                        replayChangeToken: state.replayChangeToken,
                        startedDirtyEpoch: state.startedDirtyEpoch
                    )
                    let nextCheckpoint = try nextState.jobCheckpoint
                    _ = try queue.commitLeaseProtectedBatch(
                        input: SafeBatchCommitInput(
                            lease: lease,
                            outcome: .continue,
                            checkpoint: nextCheckpoint,
                            progress: JobProgress(
                                completed: batch.completedCount,
                                total: batch.totalCount
                            ),
                            leaseDurationMs: context.leaseDurationMs
                        )
                    ) { db in
                        _ = try requireActiveGeneration(sourceID: decodedPayload.sourceID, db: db)
                        for metadata in batch.assets {
                            try upsert(
                                metadata,
                                sourceID: decodedPayload.sourceID,
                                generation: state.generation,
                                db: db
                            )
                        }
                    }
                    state = nextState
                    currentState = nextState
                    enumerationTotal = batch.totalCount
                    lastLeaseRenewedAtMs = clock.nowMs
                }
            )

            if let changeHistory,
               let replayStartToken = state.replayChangeToken ?? state.frozenChangeToken
            {
                try changeHistory.enumeratePersistentChanges(since: replayStartToken) { batch in
                    let nextState = PhotosReconcileCheckpoint(
                        generation: state.generation,
                        processedCount: state.processedCount,
                        frozenChangeToken: state.frozenChangeToken,
                        replayChangeToken: batch.changeToken,
                        startedDirtyEpoch: state.startedDirtyEpoch
                    )
                    _ = try queue.commitLeaseProtectedBatch(
                        input: SafeBatchCommitInput(
                            lease: lease,
                            outcome: .continue,
                            checkpoint: try nextState.jobCheckpoint,
                            progress: JobProgress(completed: state.processedCount, total: enumerationTotal),
                            leaseDurationMs: context.leaseDurationMs
                        )
                    ) { db in
                        _ = try requireActiveGeneration(sourceID: decodedPayload.sourceID, db: db)
                        try applyPersistentChange(
                            batch,
                            sourceID: decodedPayload.sourceID,
                            generation: state.generation,
                            db: db
                        )
                    }
                    state = nextState
                    currentState = nextState
                }
            }

            let finalCheckpoint = try state.jobCheckpoint
            var needsFollowUp = false
            _ = try queue.commitLeaseProtectedBatch(
                input: SafeBatchCommitInput(
                    lease: lease,
                    outcome: .completed,
                    checkpoint: finalCheckpoint,
                    progress: JobProgress(completed: state.processedCount, total: enumerationTotal),
                    leaseDurationMs: context.leaseDurationMs
                )
            ) { db in
                _ = try requireActiveGeneration(sourceID: decodedPayload.sourceID, db: db)
                try db.execute(
                    sql: """
                    UPDATE asset SET
                        availability = 'missing',
                        content_revision = content_revision + 1,
                        record_updated_at_ms = ?
                    WHERE source_id = ?
                        AND locator_kind = 'photos'
                        AND locator_state = 'current'
                        AND (last_seen_generation IS NULL OR last_seen_generation < ?)
                        AND availability != 'missing'
                    """,
                    arguments: [clock.nowMs, decodedPayload.sourceID.uuidString.lowercased(), state.generation]
                )
                if let finalChangeToken = state.replayChangeToken ?? state.frozenChangeToken {
                    try db.execute(
                        sql: "UPDATE source SET sync_cursor = ?, updated_at_ms = ? WHERE id = ?",
                        arguments: [
                            finalChangeToken,
                            clock.nowMs,
                            decodedPayload.sourceID.uuidString.lowercased(),
                        ]
                    )
                } else {
                    try db.execute(
                        sql: "UPDATE source SET updated_at_ms = ? WHERE id = ?",
                        arguments: [clock.nowMs, decodedPayload.sourceID.uuidString.lowercased()]
                    )
                }
                if let startedDirtyEpoch = state.startedDirtyEpoch {
                    let currentDirtyEpoch = try Int.fetchOne(
                        db,
                        sql: "SELECT dirty_epoch FROM source WHERE id = ?",
                        arguments: [decodedPayload.sourceID.uuidString.lowercased()]
                    ) ?? startedDirtyEpoch
                    needsFollowUp = currentDirtyEpoch > startedDirtyEpoch
                }
            }
            if needsFollowUp {
                enqueueFollowUpIfNeeded(sourceID: decodedPayload.sourceID)
            }
            return JobHandlerExecutionResult(
                outcome: .completed,
                checkpoint: finalCheckpoint,
                progress: JobProgress(completed: state.processedCount, total: enumerationTotal),
                settledByHandler: true
            )
        } catch let boundary as PhotosReconcileSafeBoundaryReached {
            return JobHandlerExecutionResult(
                outcome: boundary.snapshot.state == .cancelled ? .completed : .continue,
                checkpoint: boundary.snapshot.checkpoint,
                progress: boundary.snapshot.progress,
                settledByHandler: true
            )
        } catch PhotosReconcileError.invalidPayload {
            return failure(.photosPayloadInvalid, checkpoint: checkpoint, completed: persistedCompleted)
        } catch PhotosReconcileError.invalidCheckpoint {
            return failure(.photosCheckpointInvalid, checkpoint: checkpoint, completed: persistedCompleted)
        } catch PhotosReconcileError.sourceUnavailable {
            return failure(.photosSourceUnavailable, checkpoint: checkpoint, completed: persistedCompleted)
        } catch PhotosLibraryError.authorizationDenied, PhotosLibraryError.authorizationRestricted {
            do {
                if let sourceID {
                    try database.pool.write { db in
                        try db.execute(
                            sql: """
                            UPDATE source SET state = 'authorizationRequired', updated_at_ms = ?
                            WHERE id = ? AND kind = 'photos'
                            """,
                            arguments: [clock.nowMs, sourceID.uuidString.lowercased()]
                        )
                    }
                }
            } catch {
                return retryableFailure(
                    .photosPersistenceFailure,
                    checkpoint: checkpoint,
                    completed: persistedCompleted
                )
            }
            return failure(.photosAuthorizationRequired, checkpoint: checkpoint, completed: persistedCompleted)
        } catch {
            let recoveryCheckpoint = (try? currentState?.jobCheckpoint) ?? checkpoint
            return retryableFailure(
                .photosPersistenceFailure,
                checkpoint: recoveryCheckpoint,
                completed: currentState?.processedCount ?? 0
            )
        }
    }

    private func persistedSourceSyncState(sourceID: UUID) throws -> (changeToken: Data?, dirtyEpoch: Int) {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT kind, state, sync_cursor, dirty_epoch FROM source WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            ) else {
                throw PhotosReconcileError.sourceUnavailable
            }
            let kind: String = row["kind"]
            let state: String = row["state"]
            guard kind == SourceKind.photos.rawValue, state == SourceState.active.rawValue else {
                throw PhotosReconcileError.sourceUnavailable
            }
            return (row["sync_cursor"], row["dirty_epoch"])
        }
    }

    private func hasCompletedFullPhotosEnumeration(sourceID: UUID) throws -> Bool {
        try database.pool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1 FROM job
                    WHERE source_id = ?
                        AND kind = ?
                        AND state = 'completed'
                        AND checkpoint IS NOT NULL
                )
                """,
                arguments: [
                    sourceID.uuidString.lowercased(),
                    PhotosReconcileJobFactory.kind,
                ]
            ) ?? false
        }
    }

    private func executeIncrementalChanges(
        lease: JobLeaseToken,
        sourceID: UUID,
        changeToken: Data,
        startedDirtyEpoch: Int,
        changeHistory: any PhotosChangeHistoryPort,
        leaseDurationMs: Int64
    ) throws -> JobHandlerExecutionResult {
        var processedCount = 0
        try changeHistory.enumeratePersistentChanges(since: changeToken) { batch in
            processedCount += batch.upsertedAssets.count + batch.deletedLocalIdentifiers.count
            _ = try queue.commitLeaseProtectedBatch(
                input: SafeBatchCommitInput(
                    lease: lease,
                    outcome: .continue,
                    checkpoint: nil,
                    progress: JobProgress(completed: processedCount, total: nil),
                    leaseDurationMs: leaseDurationMs
                )
            ) { db in
                let generation = try requireActiveGeneration(sourceID: sourceID, db: db)
                try applyPersistentChange(batch, sourceID: sourceID, generation: generation, db: db)
                try db.execute(
                    sql: "UPDATE source SET sync_cursor = ?, updated_at_ms = ? WHERE id = ?",
                    arguments: [batch.changeToken, clock.nowMs, sourceID.uuidString.lowercased()]
                )
            }
        }

        var needsFollowUp = false
        _ = try queue.commitLeaseProtectedBatch(
            input: SafeBatchCommitInput(
                lease: lease,
                outcome: .completed,
                checkpoint: nil,
                progress: JobProgress(completed: processedCount, total: processedCount),
                leaseDurationMs: leaseDurationMs
            )
        ) { db in
            _ = try requireActiveGeneration(sourceID: sourceID, db: db)
            let currentDirtyEpoch = try Int.fetchOne(
                db,
                sql: "SELECT dirty_epoch FROM source WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            ) ?? startedDirtyEpoch
            needsFollowUp = currentDirtyEpoch > startedDirtyEpoch
        }
        if needsFollowUp {
            enqueueFollowUpIfNeeded(sourceID: sourceID)
        }
        return JobHandlerExecutionResult(
            outcome: .completed,
            checkpoint: nil,
            progress: JobProgress(completed: processedCount, total: processedCount),
            settledByHandler: true
        )
    }

    private func requireActiveGeneration(sourceID: UUID, db: Database) throws -> Int {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT state, scan_generation FROM source WHERE id = ? AND kind = 'photos'",
            arguments: [sourceID.uuidString.lowercased()]
        ) else {
            throw PhotosReconcileError.sourceUnavailable
        }
        let sourceState: String = row["state"]
        guard sourceState == SourceState.active.rawValue else {
            throw PhotosReconcileError.sourceUnavailable
        }
        return row["scan_generation"]
    }

    private func applyPersistentChange(
        _ batch: PhotosPersistentChangeBatch,
        sourceID: UUID,
        generation: Int,
        db: Database
    ) throws {
        for metadata in batch.upsertedAssets {
            try upsert(metadata, sourceID: sourceID, generation: generation, db: db)
        }
        guard !batch.deletedLocalIdentifiers.isEmpty else { return }

        var arguments = StatementArguments()
        arguments += [clock.nowMs, sourceID.uuidString.lowercased()]
        for identifier in batch.deletedLocalIdentifiers {
            arguments += [identifier]
        }
        try db.execute(
            sql: """
            UPDATE asset SET
                availability = 'missing',
                content_revision = content_revision + 1,
                record_updated_at_ms = ?
            WHERE source_id = ? AND locator_kind = 'photos'
                AND locator_state = 'current'
                AND photos_local_identifier IN (\(databaseQuestionMarks(batch.deletedLocalIdentifiers.count)))
                AND availability != 'missing'
            """,
            arguments: arguments
        )
    }

    private func databaseQuestionMarks(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private func enqueueFollowUpIfNeeded(sourceID: UUID) {
        try? database.pool.write { db in
            try PhotosReconcileJobEnqueuer(clock: clock, idGenerator: idGenerator)
                .enqueueIfNeeded(sourceID: sourceID, db: db)
        }
    }

    private func beginOrResume(
        lease: JobLeaseToken,
        sourceID: UUID,
        checkpoint: JobCheckpoint?,
        frozenChangeToken: Data?,
        leaseDurationMs: Int64
    ) throws -> PhotosReconcileCheckpoint {
        if let checkpoint {
            guard checkpoint.version == 1,
                  let decoded = try? JSONDecoder().decode(PhotosReconcileCheckpoint.self, from: checkpoint.data),
                  decoded.generation > 0,
                  decoded.processedCount >= 0
            else {
                throw PhotosReconcileError.invalidCheckpoint
            }
            let isValid = try database.pool.read { db in
                try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM source
                        WHERE id = ? AND kind = 'photos' AND state = 'active'
                            AND scan_generation = ?
                    )
                    """,
                    arguments: [sourceID.uuidString.lowercased(), decoded.generation]
                ) ?? false
            }
            guard isValid else { throw PhotosReconcileError.invalidCheckpoint }
            return decoded
        }

        var initialState: PhotosReconcileCheckpoint?
        _ = try queue.commitLeaseProtectedBatch(
            input: SafeBatchCommitInput(
                lease: lease,
                outcome: .continue,
                checkpoint: nil,
                progress: JobProgress(completed: 0, total: nil),
                leaseDurationMs: leaseDurationMs
            )
        ) { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT kind, state, scan_generation, dirty_epoch FROM source WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            ) else {
                throw PhotosReconcileError.sourceUnavailable
            }
            let kind: String = row["kind"]
            let sourceState: String = row["state"]
            let currentGeneration: Int = row["scan_generation"]
            let startedDirtyEpoch: Int = row["dirty_epoch"]
            guard kind == SourceKind.photos.rawValue, sourceState == SourceState.active.rawValue else {
                throw PhotosReconcileError.sourceUnavailable
            }
            let generation = currentGeneration + 1
            initialState = PhotosReconcileCheckpoint(
                generation: generation,
                processedCount: 0,
                frozenChangeToken: frozenChangeToken,
                replayChangeToken: nil,
                startedDirtyEpoch: startedDirtyEpoch
            )
            try db.execute(
                sql: "UPDATE source SET scan_generation = ?, updated_at_ms = ? WHERE id = ?",
                arguments: [generation, clock.nowMs, sourceID.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE job SET scan_generation = ? WHERE id = ?",
                arguments: [generation, lease.jobID.uuidString.lowercased()]
            )
        }
        guard let initialState else { throw PhotosReconcileError.sourceUnavailable }
        let persistedCheckpoint = try initialState.jobCheckpoint
        _ = try queue.commitLeaseProtectedBatch(
            input: SafeBatchCommitInput(
                lease: lease,
                outcome: .continue,
                checkpoint: persistedCheckpoint,
                progress: JobProgress(completed: 0, total: nil),
                leaseDurationMs: leaseDurationMs
            )
        ) { _ in }
        return initialState
    }

    private func upsert(
        _ metadata: PhotosAssetMetadata,
        sourceID: UUID,
        generation: Int,
        db: Database
    ) throws {
        let sourceIDString = sourceID.uuidString.lowercased()
        if let row = try Row.fetchOne(
            db,
            sql: """
            SELECT id, file_name, media_type, width, height,
                   media_created_at_ms, media_modified_at_ms, availability,
                   media_kind, duration_ms
            FROM asset
            WHERE source_id = ? AND locator_kind = 'photos'
                AND locator_state = 'current' AND photos_local_identifier = ?
            """,
            arguments: [sourceIDString, metadata.localIdentifier]
        ) {
            let storedFileName: String? = row["file_name"]
            let storedMediaType: String = row["media_type"]
            let storedWidth: Int? = row["width"]
            let storedHeight: Int? = row["height"]
            let storedCreatedAtMs: Int64? = row["media_created_at_ms"]
            let storedModifiedAtMs: Int64? = row["media_modified_at_ms"]
            let storedMediaKind: String = row["media_kind"]
            let storedDurationMs: Int64? = row["duration_ms"]
            let storedAvailability: String = row["availability"]
            let fileIdentityChanged = storedFileName != metadata.fileName
                || storedMediaType != metadata.mediaType
            let dimensionsChanged = storedWidth != metadata.width
                || storedHeight != metadata.height
            let timestampsChanged = storedCreatedAtMs != metadata.createdAtMs
                || storedModifiedAtMs != metadata.modifiedAtMs
            let videoMetadataChanged = storedMediaKind != metadata.mediaKind.rawValue
                || storedDurationMs != metadata.durationMs
            let availabilityChanged = storedAvailability != AssetAvailability.available.rawValue
            let changed = fileIdentityChanged
                || dimensionsChanged
                || timestampsChanged
                || videoMetadataChanged
                || availabilityChanged
            try db.execute(
                sql: """
                UPDATE asset SET
                    file_name = ?, media_type = ?, width = ?, height = ?,
                    media_created_at_ms = ?, media_modified_at_ms = ?,
                    media_kind = ?, duration_ms = ?,
                    last_seen_generation = ?, availability = 'available',
                    content_revision = content_revision + ?, record_updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [
                    metadata.fileName, metadata.mediaType, metadata.width, metadata.height,
                    metadata.createdAtMs, metadata.modifiedAtMs,
                    metadata.mediaKind.rawValue, metadata.durationMs,
                    generation, changed ? 1 : 0,
                    clock.nowMs, row["id"] as String,
                ]
            )
            try upsertLocation(
                metadata.location,
                assetID: row["id"] as String,
                db: db
            )
        } else {
            let assetID = idGenerator().uuidString.lowercased()
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, width, height,
                    media_created_at_ms, media_modified_at_ms, content_revision,
                    last_seen_generation, availability, record_created_at_ms,
                    record_updated_at_ms, file_name, media_kind, duration_ms
                ) VALUES (?, ?, 'photos', NULL, ?, 'current', ?, ?, ?, ?, ?, 1, ?, 'available', ?, ?, ?, ?, ?)
                """,
                arguments: [
                    assetID, sourceIDString, metadata.localIdentifier,
                    metadata.mediaType, metadata.width, metadata.height, metadata.createdAtMs,
                    metadata.modifiedAtMs, generation, clock.nowMs, clock.nowMs, metadata.fileName,
                    metadata.mediaKind.rawValue, metadata.durationMs,
                ]
            )
            try upsertLocation(metadata.location, assetID: assetID, db: db)
        }
    }

    private func upsertLocation(
        _ candidate: AssetLocationCoordinate?,
        assetID: String,
        db: Database
    ) throws {
        let location = candidate?.isValid == true ? candidate : nil
        try db.execute(
            sql: """
            INSERT INTO asset_location (
                asset_id, latitude, longitude, altitude_m, source_kind, updated_at_ms
            ) VALUES (?, ?, ?, NULL, ?, ?)
            ON CONFLICT(asset_id) DO UPDATE SET
                latitude = excluded.latitude,
                longitude = excluded.longitude,
                altitude_m = NULL,
                source_kind = excluded.source_kind,
                place_id = NULL,
                updated_at_ms = excluded.updated_at_ms
            """,
            arguments: [
                assetID,
                location?.latitude,
                location?.longitude,
                location == nil ? "none" : "photosGPS",
                clock.nowMs,
            ]
        )
    }

    private func failure(
        _ code: JobSafeErrorCode,
        checkpoint: JobCheckpoint?,
        completed: Int = 0
    ) -> JobHandlerExecutionResult {
        JobHandlerExecutionResult(
            outcome: .nonRetryableFailure(code: code),
            checkpoint: checkpoint,
            progress: JobProgress(completed: completed, total: nil)
        )
    }

    private func retryableFailure(
        _ code: JobSafeErrorCode,
        checkpoint: JobCheckpoint?,
        completed: Int
    ) -> JobHandlerExecutionResult {
        JobHandlerExecutionResult(
            outcome: .retryableFailure(code: code),
            checkpoint: checkpoint,
            progress: JobProgress(completed: completed, total: nil)
        )
    }
}
