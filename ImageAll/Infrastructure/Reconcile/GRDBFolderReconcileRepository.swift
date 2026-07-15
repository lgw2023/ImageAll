import Foundation
import GRDB

struct GRDBFolderReconcileRepository: FolderReconcileBatchPort, Sendable {
    let queue: GRDBJobQueue

    func beginGeneration(_ input: FolderBeginGenerationInput) throws -> FolderBeginGenerationResult {
        try queue.runLeaseProtectedTransaction(lease: input.lease) { db in
            let jobRow = try requireRunningJob(db: db, lease: input.lease)
            let sourceRow = try requireActiveFolderSource(db: db, sourceID: input.sourceID)

            let existingGeneration: Int? = jobRow["scan_generation"]
            let existingEpoch: Int? = jobRow["started_dirty_epoch"]

            let generation: Int
            let startedEpoch: Int

            if let existingGeneration, let existingEpoch {
                generation = existingGeneration
                startedEpoch = existingEpoch
            } else if existingGeneration != nil || existingEpoch != nil {
                throw FolderReconcileRepositoryError.checkpointInvalid
            } else {
                let currentGeneration: Int = sourceRow["scan_generation"]
                generation = currentGeneration + 1
                startedEpoch = sourceRow["dirty_epoch"]

                try db.execute(
                    sql: "UPDATE source SET scan_generation = ?, updated_at_ms = ? WHERE id = ?",
                    arguments: [generation, queue.clock.nowMs, input.sourceID.uuidString.lowercased()]
                )
            }

            let checkpoint = FolderReconcileCheckpointV1(
                generation: generation,
                startedDirtyEpoch: startedEpoch,
                attempt: input.lease.attempts
            )

            let checkpointData = try FolderReconcileCheckpointCodec.encode(checkpoint)
            try db.execute(
                sql: """
                UPDATE job SET
                    scan_generation = ?,
                    started_dirty_epoch = ?,
                    checkpoint_version = 1,
                    checkpoint = ?,
                    updated_at_ms = ?
                WHERE id = ? AND state = 'running'
                    AND lease_owner = ? AND attempts = ?
                """,
                arguments: [
                    generation,
                    startedEpoch,
                    checkpointData,
                    queue.clock.nowMs,
                    input.lease.jobID.uuidString.lowercased(),
                    input.lease.leaseOwner,
                    input.lease.attempts,
                ]
            )

            return FolderBeginGenerationResult(
                generation: generation,
                startedDirtyEpoch: startedEpoch,
                checkpoint: checkpoint
            )
        }
    }

    func commitAssetBatch(_ input: FolderAssetBatchInput) throws -> FolderBatchCommitResult {
        let snapshot = try queue.commitLeaseProtectedBatch(
            input: SafeBatchCommitInput(
                lease: input.lease,
                outcome: input.outcome,
                checkpoint: try makeJobCheckpoint(input.checkpoint),
                progress: JobProgress(completed: input.checkpoint.candidateFiles, total: nil),
                leaseDurationMs: input.leaseDurationMs
            )
        ) { db in
            for observation in input.observations {
                try upsertAssetObservation(
                    db: db,
                    sourceID: input.sourceID,
                    generation: input.generation,
                    observation: observation,
                    nowMs: queue.clock.nowMs
                )
            }
        }
        return FolderBatchCommitResult(jobSnapshot: snapshot, checkpoint: input.checkpoint)
    }

    func completeGeneration(_ input: FolderCompleteGenerationInput) throws -> FolderCompleteGenerationResult {
        var successorJobID: UUID?
        let nowMs = queue.clock.nowMs
        let snapshot = try queue.runLeaseProtectedTransaction(lease: input.lease) { db in
            let control: String = try String.fetchOne(
                db,
                sql: "SELECT control_request FROM job WHERE id = ?",
                arguments: [input.lease.jobID.uuidString.lowercased()]
            ) ?? JobControlRequest.none.rawValue
            guard control == JobControlRequest.none.rawValue else {
                throw FolderReconcileRepositoryError.controlInterrupted
            }

            let sourceState: String = try String.fetchOne(
                db,
                sql: "SELECT state FROM source WHERE id = ?",
                arguments: [input.sourceID.uuidString.lowercased()]
            ) ?? ""
            guard sourceState == SourceState.active.rawValue else {
                throw FolderReconcileRepositoryError.sourceNotActive
            }

            try db.execute(
                sql: """
                UPDATE asset SET
                    availability = 'missing',
                    record_updated_at_ms = ?
                WHERE source_id = ?
                    AND locator_kind = 'file'
                    AND locator_state = 'current'
                    AND (last_seen_generation IS NULL OR last_seen_generation < ?)
                """,
                arguments: [
                    nowMs,
                    input.sourceID.uuidString.lowercased(),
                    input.generation,
                ]
            )

            let checkpointData = try FolderReconcileCheckpointCodec.encode(input.checkpoint)
            try db.execute(
                sql: """
                UPDATE job SET
                    state = 'completed',
                    checkpoint_version = 1,
                    checkpoint = ?,
                    progress_completed = ?,
                    progress_total = NULL,
                    last_error_code = NULL,
                    last_error_message = NULL,
                    lease_owner = NULL,
                    lease_expires_at_ms = NULL,
                    control_request = 'none',
                    updated_at_ms = ?
                WHERE id = ? AND state = 'running'
                    AND lease_owner = ? AND attempts = ?
                """,
                arguments: [
                    checkpointData,
                    input.checkpoint.candidateFiles,
                    nowMs,
                    input.lease.jobID.uuidString.lowercased(),
                    input.lease.leaseOwner,
                    input.lease.attempts,
                ]
            )
            guard db.changesCount == 1 else {
                throw JobQueueError.staleLease(input.lease.jobID)
            }

            let currentDirtyEpoch: Int = try Int.fetchOne(
                db,
                sql: "SELECT dirty_epoch FROM source WHERE id = ?",
                arguments: [input.sourceID.uuidString.lowercased()]
            ) ?? input.startedDirtyEpoch

            if currentDirtyEpoch != input.startedDirtyEpoch {
                let newJobID = UUID()
                successorJobID = newJobID
                let command = try FolderReconcileJobFactory.makeEnqueueCommand(
                    jobID: newJobID,
                    sourceID: input.sourceID,
                    notBeforeMs: nowMs
                )
                try JobInsertInTransaction.insertPendingJob(db, command: command, nowMs: nowMs)
            }

            guard let updated = try JobRowReader.fetchSnapshot(db, jobID: input.lease.jobID) else {
                throw JobQueueError.jobNotFound(input.lease.jobID)
            }
            return updated
        }

        return FolderCompleteGenerationResult(
            jobSnapshot: snapshot,
            checkpoint: input.checkpoint,
            successorJobID: successorJobID
        )
    }

    func stopIncomplete(_ input: FolderStopIncompleteInput) throws -> FolderBatchCommitResult {
        let snapshot = try queue.commitLeaseProtectedBatch(
            input: SafeBatchCommitInput(
                lease: input.lease,
                outcome: .retryableFailure(code: input.errorCode),
                checkpoint: try makeJobCheckpoint(input.checkpoint),
                progress: JobProgress(completed: input.checkpoint.candidateFiles, total: nil),
                leaseDurationMs: input.leaseDurationMs
            )
        ) { _ in }
        return FolderBatchCommitResult(jobSnapshot: snapshot, checkpoint: input.checkpoint)
    }

    private func upsertAssetObservation(
        db: Database,
        sourceID: UUID,
        generation: Int,
        observation: FolderReconcileAssetObservation,
        nowMs: Int64
    ) throws {
        let sourceIDString = sourceID.uuidString.lowercased()

        if let existing = try fetchCurrentAsset(db: db, sourceID: sourceID, relativePath: observation.relativePath) {
            try applySamePathUpdate(
                db: db,
                existing: existing,
                observation: observation,
                generation: generation,
                nowMs: nowMs
            )
            return
        }

        if let movedAssetID = try findMoveReconnectCandidate(
            db: db,
            sourceID: sourceID,
            generation: generation,
            observation: observation
        ) {
            try relocateAsset(
                db: db,
                assetID: movedAssetID,
                observation: observation,
                generation: generation,
                nowMs: nowMs
            )
            return
        }

        try insertNewAsset(
            db: db,
            sourceID: sourceIDString,
            observation: observation,
            generation: generation,
            nowMs: nowMs
        )
    }

    private func applySamePathUpdate(
        db: Database,
        existing: ExistingAssetRecord,
        observation: FolderReconcileAssetObservation,
        generation: Int,
        nowMs: Int64
    ) throws {
        switch resolveSamePathIdentity(existing: existing, observation: observation) {
        case let .retain(revision):
            try updateRetainedAsset(
                db: db,
                assetID: existing.assetID,
                observation: observation,
                generation: generation,
                contentRevision: revision,
                nowMs: nowMs
            )
        case let .replace(newAssetID):
            try markHistorical(db: db, assetID: existing.assetID, nowMs: nowMs)
            try insertNewAsset(
                db: db,
                sourceID: existing.sourceID,
                assetID: newAssetID,
                observation: observation,
                generation: generation,
                nowMs: nowMs
            )
        case .conflict:
            try updateConflictAsset(
                db: db,
                assetID: existing.assetID,
                generation: generation,
                nowMs: nowMs
            )
        }
    }

    private enum SamePathResolution {
        case retain(contentRevision: Int)
        case replace(newAssetID: UUID)
        case conflict
    }

    private func resolveSamePathIdentity(
        existing: ExistingAssetRecord,
        observation: FolderReconcileAssetObservation
    ) -> SamePathResolution {
        if existing.availability == AssetAvailability.missing.rawValue {
            return .replace(newAssetID: UUID())
        }

        let oldResourceID = existing.resourceID
        let newResourceID = observation.resourceID

        if let oldResourceID, let newResourceID {
            if oldResourceID == newResourceID {
                let revision = fingerprintChanged(existing: existing, observation: observation)
                    ? existing.contentRevision + 1
                    : existing.contentRevision
                return .retain(contentRevision: revision)
            }
            return .replace(newAssetID: UUID())
        }

        if oldResourceID == nil, newResourceID == nil, existing.availability != AssetAvailability.missing.rawValue {
            let revision = fingerprintChanged(existing: existing, observation: observation)
                ? existing.contentRevision + 1
                : existing.contentRevision
            return .retain(contentRevision: revision)
        }

        return .conflict
    }

    private func fingerprintChanged(
        existing: ExistingAssetRecord,
        observation: FolderReconcileAssetObservation
    ) -> Bool {
        existing.sizeBytes != observation.sizeBytes || existing.modifiedAtNs != observation.modifiedAtNs
    }

    private func fetchCurrentAsset(
        db: Database,
        sourceID: UUID,
        relativePath: String
    ) throws -> ExistingAssetRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT a.id AS asset_id, a.source_id, a.availability, a.content_revision,
                   f.size_bytes, f.modified_at_ns, f.resource_id
            FROM asset a
            LEFT JOIN file_fingerprint f ON f.asset_id = a.id
            WHERE a.source_id = ? AND a.relative_path = ?
                AND a.locator_kind = 'file' AND a.locator_state = 'current'
            """,
            arguments: [sourceID.uuidString.lowercased(), relativePath]
        ) else {
            return nil
        }
        return ExistingAssetRecord(row: row)
    }

    private func findMoveReconnectCandidate(
        db: Database,
        sourceID: UUID,
        generation: Int,
        observation: FolderReconcileAssetObservation
    ) throws -> UUID? {
        guard let resourceID = observation.resourceID else {
            return nil
        }

        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT a.id, a.relative_path, f.resource_id
            FROM asset a
            JOIN file_fingerprint f ON f.asset_id = a.id
            WHERE a.source_id = ?
                AND a.locator_kind = 'file'
                AND a.locator_state = 'current'
                AND f.resource_id = ?
            """,
            arguments: [sourceID.uuidString.lowercased(), resourceID]
        )

        guard rows.count == 1, let row = rows.first else {
            return nil
        }

        let assetID = UUID(uuidString: row["id"])!
        let oldPath: String = row["relative_path"]

        let seenThisGeneration = try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*) FROM asset
            WHERE id = ? AND last_seen_generation = ?
            """,
            arguments: [assetID.uuidString.lowercased(), generation]
        ) ?? 0
        if seenThisGeneration > 0 {
            return nil
        }

        _ = oldPath
        return assetID
    }

    private func insertNewAsset(
        db: Database,
        sourceID: String,
        assetID: UUID = UUID(),
        observation: FolderReconcileAssetObservation,
        generation: Int,
        nowMs: Int64
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO asset (
                id, source_id, locator_kind, relative_path, file_name, locator_state,
                media_type, width, height, media_created_at_ms, media_modified_at_ms,
                content_revision, last_seen_generation, availability,
                record_created_at_ms, record_updated_at_ms
            ) VALUES (?, ?, 'file', ?, ?, 'current', ?, ?, ?, ?, NULL, 1, ?, ?, ?, ?)
            """,
            arguments: [
                assetID.uuidString.lowercased(),
                sourceID,
                observation.relativePath,
                observation.fileName,
                observation.mediaType,
                observation.width,
                observation.height,
                observation.mediaCreatedAtMs,
                generation,
                observation.availability.rawValue,
                nowMs,
                nowMs,
            ]
        )
        try upsertFingerprint(db: db, assetID: assetID, observation: observation)
    }

    private func updateRetainedAsset(
        db: Database,
        assetID: UUID,
        observation: FolderReconcileAssetObservation,
        generation: Int,
        contentRevision: Int,
        nowMs: Int64
    ) throws {
        try db.execute(
            sql: """
            UPDATE asset SET
                file_name = ?,
                media_type = ?,
                width = ?,
                height = ?,
                media_created_at_ms = ?,
                content_revision = ?,
                last_seen_generation = ?,
                availability = ?,
                record_updated_at_ms = ?
            WHERE id = ?
            """,
            arguments: [
                observation.fileName,
                observation.mediaType,
                observation.width,
                observation.height,
                observation.mediaCreatedAtMs,
                contentRevision,
                generation,
                observation.availability.rawValue,
                nowMs,
                assetID.uuidString.lowercased(),
            ]
        )
        try upsertFingerprint(db: db, assetID: assetID, observation: observation)
    }

    private func updateConflictAsset(
        db: Database,
        assetID: UUID,
        generation: Int,
        nowMs: Int64
    ) throws {
        try db.execute(
            sql: """
            UPDATE asset SET
                last_seen_generation = ?,
                availability = 'unreadable',
                record_updated_at_ms = ?
            WHERE id = ?
            """,
            arguments: [generation, nowMs, assetID.uuidString.lowercased()]
        )
    }

    private func relocateAsset(
        db: Database,
        assetID: UUID,
        observation: FolderReconcileAssetObservation,
        generation: Int,
        nowMs: Int64
    ) throws {
        let revision = try Int.fetchOne(
            db,
            sql: "SELECT content_revision FROM asset WHERE id = ?",
            arguments: [assetID.uuidString.lowercased()]
        ) ?? 1
        let newRevision = fingerprintChanged(
            existing: ExistingAssetRecord(
                assetID: assetID,
                sourceID: "",
                availability: observation.availability.rawValue,
                contentRevision: revision,
                sizeBytes: 0,
                modifiedAtNs: 0,
                resourceID: nil
            ),
            observation: observation
        ) ? revision + 1 : revision

        try db.execute(
            sql: """
            UPDATE asset SET
                relative_path = ?,
                file_name = ?,
                media_type = ?,
                width = ?,
                height = ?,
                media_created_at_ms = ?,
                content_revision = ?,
                last_seen_generation = ?,
                availability = ?,
                record_updated_at_ms = ?
            WHERE id = ?
            """,
            arguments: [
                observation.relativePath,
                observation.fileName,
                observation.mediaType,
                observation.width,
                observation.height,
                observation.mediaCreatedAtMs,
                newRevision,
                generation,
                observation.availability.rawValue,
                nowMs,
                assetID.uuidString.lowercased(),
            ]
        )
        try upsertFingerprint(db: db, assetID: assetID, observation: observation)
    }

    private func markHistorical(db: Database, assetID: UUID, nowMs: Int64) throws {
        try db.execute(
            sql: """
            UPDATE asset SET locator_state = 'historical', record_updated_at_ms = ?
            WHERE id = ?
            """,
            arguments: [nowMs, assetID.uuidString.lowercased()]
        )
    }

    private func upsertFingerprint(
        db: Database,
        assetID: UUID,
        observation: FolderReconcileAssetObservation
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO file_fingerprint (asset_id, size_bytes, modified_at_ns, resource_id, sha256)
            VALUES (?, ?, ?, ?, NULL)
            ON CONFLICT(asset_id) DO UPDATE SET
                size_bytes = excluded.size_bytes,
                modified_at_ns = excluded.modified_at_ns,
                resource_id = excluded.resource_id,
                sha256 = NULL
            """,
            arguments: [
                assetID.uuidString.lowercased(),
                observation.sizeBytes,
                observation.modifiedAtNs,
                observation.resourceID,
            ]
        )
    }

    private func requireRunningJob(db: Database, lease: JobLeaseToken) throws -> Row {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT * FROM job
            WHERE id = ? AND state = 'running'
                AND lease_owner = ? AND attempts = ?
            """,
            arguments: [
                lease.jobID.uuidString.lowercased(),
                lease.leaseOwner,
                lease.attempts,
            ]
        ) else {
            throw JobQueueError.staleLease(lease.jobID)
        }
        return row
    }

    private func requireActiveFolderSource(db: Database, sourceID: UUID) throws -> Row {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM source WHERE id = ? AND kind = 'folder'",
            arguments: [sourceID.uuidString.lowercased()]
        ) else {
            throw FolderReconcileRepositoryError.sourceNotFound
        }
        let state: String = row["state"]
        guard state == SourceState.active.rawValue else {
            throw FolderReconcileRepositoryError.sourceNotActive
        }
        return row
    }

    private func makeJobCheckpoint(_ checkpoint: FolderReconcileCheckpointV1) throws -> JobCheckpoint {
        JobCheckpoint(version: 1, data: try FolderReconcileCheckpointCodec.encode(checkpoint))
    }
}

private struct ExistingAssetRecord {
    let assetID: UUID
    let sourceID: String
    let availability: String
    let contentRevision: Int
    let sizeBytes: Int64
    let modifiedAtNs: Int64
    let resourceID: Data?

    init(row: Row) {
        assetID = UUID(uuidString: row["asset_id"])!
        sourceID = row["source_id"]
        availability = row["availability"]
        contentRevision = row["content_revision"]
        sizeBytes = row["size_bytes"] ?? 0
        modifiedAtNs = row["modified_at_ns"] ?? 0
        resourceID = row["resource_id"]
    }

    init(
        assetID: UUID,
        sourceID: String,
        availability: String,
        contentRevision: Int,
        sizeBytes: Int64,
        modifiedAtNs: Int64,
        resourceID: Data?
    ) {
        self.assetID = assetID
        self.sourceID = sourceID
        self.availability = availability
        self.contentRevision = contentRevision
        self.sizeBytes = sizeBytes
        self.modifiedAtNs = modifiedAtNs
        self.resourceID = resourceID
    }
}

enum FolderReconcileRepositoryError: Error, Equatable {
    case checkpointInvalid
    case sourceNotFound
    case sourceNotActive
    case controlInterrupted
}
