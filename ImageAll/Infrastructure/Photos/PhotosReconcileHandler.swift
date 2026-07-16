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

    enum CodingKeys: String, CodingKey {
        case generation
        case processedCount = "processed_count"
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

struct PhotosReconcileHandler: LeaseBoundJobHandler, Sendable {
    let database: CatalogDatabase
    let queue: GRDBJobQueue
    let access: any PhotosLibraryAccessPort
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
        clock: any JobClock = SystemJobClock(),
        batchSize: Int = 200,
        idGenerator: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.database = database
        self.queue = queue
        self.access = access
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
        let persistedCompleted = (try? queue.fetchJob(id: lease.jobID).progress.completed) ?? 0
        do {
            guard payloadVersion == PhotosReconcileJobFactory.payloadVersion else {
                throw PhotosReconcileError.invalidPayload
            }
            let decodedPayload = try PhotosReconcilePayload(data: payload)
            sourceID = decodedPayload.sourceID
            var state = try beginOrResume(
                lease: lease,
                sourceID: decodedPayload.sourceID,
                checkpoint: checkpoint,
                leaseDurationMs: context.leaseDurationMs
            )
            currentState = state
            var enumerationTotal = state.processedCount

            // Legacy checkpoints counted supported assets, which is a safe lower-bound
            // for the raw PhotoKit offset: upgrades may repeat work but never skip it.
            try access.enumerateStaticImages(
                startingAt: state.processedCount,
                batchSize: batchSize
            ) { batch in
                guard batch.completedCount >= state.processedCount,
                      batch.totalCount >= batch.completedCount
                else {
                    throw PhotosReconcileError.invalidCheckpoint
                }
                let nextState = PhotosReconcileCheckpoint(
                    generation: state.generation,
                    processedCount: batch.completedCount
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
            }

            let finalCheckpoint = try state.jobCheckpoint
            _ = try queue.commitLeaseProtectedBatch(
                input: SafeBatchCommitInput(
                    lease: lease,
                    outcome: .completed,
                    checkpoint: finalCheckpoint,
                    progress: JobProgress(completed: state.processedCount, total: enumerationTotal),
                    leaseDurationMs: context.leaseDurationMs
                )
            ) { db in
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
                try db.execute(
                    sql: "UPDATE source SET updated_at_ms = ? WHERE id = ?",
                    arguments: [clock.nowMs, decodedPayload.sourceID.uuidString.lowercased()]
                )
            }
            return JobHandlerExecutionResult(
                outcome: .completed,
                checkpoint: finalCheckpoint,
                progress: JobProgress(completed: state.processedCount, total: enumerationTotal),
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

    private func beginOrResume(
        lease: JobLeaseToken,
        sourceID: UUID,
        checkpoint: JobCheckpoint?,
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
                sql: "SELECT kind, state, scan_generation FROM source WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            ) else {
                throw PhotosReconcileError.sourceUnavailable
            }
            let kind: String = row["kind"]
            let sourceState: String = row["state"]
            let currentGeneration: Int = row["scan_generation"]
            guard kind == SourceKind.photos.rawValue, sourceState == SourceState.active.rawValue else {
                throw PhotosReconcileError.sourceUnavailable
            }
            let generation = currentGeneration + 1
            initialState = PhotosReconcileCheckpoint(generation: generation, processedCount: 0)
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
                   media_created_at_ms, media_modified_at_ms, availability
            FROM asset
            WHERE source_id = ? AND locator_kind = 'photos'
                AND locator_state = 'current' AND photos_local_identifier = ?
            """,
            arguments: [sourceIDString, metadata.localIdentifier]
        ) {
            let changed = (row["file_name"] as String?) != metadata.fileName
                || (row["media_type"] as String) != metadata.mediaType
                || (row["width"] as Int?) != metadata.width
                || (row["height"] as Int?) != metadata.height
                || (row["media_created_at_ms"] as Int64?) != metadata.createdAtMs
                || (row["media_modified_at_ms"] as Int64?) != metadata.modifiedAtMs
                || (row["availability"] as String) != AssetAvailability.available.rawValue
            try db.execute(
                sql: """
                UPDATE asset SET
                    file_name = ?, media_type = ?, width = ?, height = ?,
                    media_created_at_ms = ?, media_modified_at_ms = ?,
                    last_seen_generation = ?, availability = 'available',
                    content_revision = content_revision + ?, record_updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [
                    metadata.fileName, metadata.mediaType, metadata.width, metadata.height,
                    metadata.createdAtMs, metadata.modifiedAtMs, generation, changed ? 1 : 0,
                    clock.nowMs, row["id"] as String,
                ]
            )
        } else {
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, width, height,
                    media_created_at_ms, media_modified_at_ms, content_revision,
                    last_seen_generation, availability, record_created_at_ms,
                    record_updated_at_ms, file_name
                ) VALUES (?, ?, 'photos', NULL, ?, 'current', ?, ?, ?, ?, ?, 1, ?, 'available', ?, ?, ?)
                """,
                arguments: [
                    idGenerator().uuidString.lowercased(), sourceIDString, metadata.localIdentifier,
                    metadata.mediaType, metadata.width, metadata.height, metadata.createdAtMs,
                    metadata.modifiedAtMs, generation, clock.nowMs, clock.nowMs, metadata.fileName,
                ]
            )
        }
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
