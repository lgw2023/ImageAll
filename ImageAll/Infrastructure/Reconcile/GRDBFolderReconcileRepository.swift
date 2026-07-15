import Foundation
import GRDB

struct GRDBFolderReconcileRepository: FolderReconcileBatchPort, Sendable {
    let queue: GRDBJobQueue

    func fetchJobContext(jobID: UUID) throws -> FolderReconcileJobContext {
        let snapshot = try queue.fetchJob(id: jobID)
        return FolderReconcileJobContext(
            jobID: snapshot.id,
            kind: snapshot.kind,
            payloadVersion: snapshot.payloadVersion,
            sourceID: snapshot.sourceID,
            scanGeneration: snapshot.scanGeneration,
            startedDirtyEpoch: snapshot.startedDirtyEpoch,
            progressCompleted: snapshot.progress.completed
        )
    }

    func lookupMoveCandidates(
        sourceID: UUID,
        resourceID: Data,
        excludingGeneration: Int
    ) throws -> [FolderMoveCandidate] {
        try queue.database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT a.id, a.relative_path, f.size_bytes, f.modified_at_ns, f.resource_id
                FROM asset a
                JOIN file_fingerprint f ON f.asset_id = a.id
                WHERE a.source_id = ?
                    AND a.locator_kind = 'file'
                    AND a.locator_state = 'current'
                    AND f.resource_id = ?
                    AND (a.last_seen_generation IS NULL OR a.last_seen_generation < ?)
                """,
                arguments: [
                    sourceID.uuidString.lowercased(),
                    resourceID,
                    excludingGeneration,
                ]
            )
            return rows.map { row in
                FolderMoveCandidate(
                    assetID: UUID(uuidString: row["id"])!,
                    relativePath: row["relative_path"],
                    sizeBytes: row["size_bytes"] ?? 0,
                    modifiedAtNs: row["modified_at_ns"] ?? 0,
                    resourceID: row["resource_id"]
                )
            }
        }
    }

    func beginGeneration(_ input: FolderBeginGenerationInput) throws -> FolderBeginGenerationResult {
        try queue.runLeaseProtectedTransaction(lease: input.lease) { db in
            let jobRow = try requireRunningJob(db: db, lease: input.lease)
            try validateJobKindAndVersion(jobRow: jobRow)
            try validateJobSourceConsistency(jobRow: jobRow, sourceID: input.sourceID)
            try validatePayloadInTransaction(
                payloadVersion: input.payloadVersion,
                payload: input.payload,
                jobSourceID: input.sourceID
            )

            let sourceRow = try requireActiveFolderSource(db: db, sourceID: input.sourceID)

            let existingGeneration: Int? = jobRow["scan_generation"]
            let existingEpoch: Int? = jobRow["started_dirty_epoch"]

            let generation: Int
            let startedEpoch: Int

            if let existingGeneration, let existingEpoch {
                let sourceGeneration: Int = sourceRow["scan_generation"]
                guard existingGeneration == sourceGeneration else {
                    throw FolderReconcileRepositoryError.checkpointInvalid
                }
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
        var identityConflictsAdded = 0
        let progress = try monotonicProgress(for: input)
        let snapshot = try queue.commitLeaseProtectedBatch(
            input: SafeBatchCommitInput(
                lease: input.lease,
                outcome: input.outcome,
                checkpoint: try makeJobCheckpoint(input.checkpoint),
                progress: progress,
                leaseDurationMs: input.leaseDurationMs
            )
        ) { db in
            try validateBatchInput(db: db, input: input)
            guard input.observations.count <= FolderEnumerationConfig.productionDefault.assetBatchLimit else {
                throw FolderReconcileRepositoryError.batchLimitExceeded
            }
            for observation in input.observations {
                let added = try upsertAssetObservation(
                    db: db,
                    sourceID: input.sourceID,
                    generation: input.generation,
                    observation: observation,
                    nowMs: queue.clock.nowMs
                )
                identityConflictsAdded += added
            }
        }
        return FolderBatchCommitResult(
            jobSnapshot: snapshot,
            checkpoint: input.checkpoint,
            identityConflictsAdded: identityConflictsAdded
        )
    }

    func completeGeneration(_ input: FolderCompleteGenerationInput) throws -> FolderCompleteGenerationResult {
        var successorJobID: UUID?
        let nowMs = queue.clock.nowMs
        let progress = try monotonicProgress(
            lease: input.lease,
            checkpoint: input.checkpoint
        )
        let jobCheckpoint = try makeJobCheckpoint(input.checkpoint)

        let snapshot = try queue.runLeaseProtectedTransaction(lease: input.lease) { db in
            try validateCompleteInput(db: db, input: input)

            let jobRow = try requireRunningJob(db: db, lease: input.lease)
            let persistedSnapshot = try JobPersistenceMapping.snapshot(from: jobRow)
            let control = persistedSnapshot.controlRequest

            if control == .none {
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
            }

            let terminalState: JobState
            switch control {
            case .pause:
                terminalState = .paused
            case .cancel:
                terminalState = .cancelled
            case .none:
                terminalState = .completed
            }

            try db.execute(
                sql: """
                UPDATE job SET
                    state = ?,
                    not_before_ms = ?,
                    checkpoint_version = ?,
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
                    terminalState.rawValue,
                    persistedSnapshot.notBeforeMs,
                    jobCheckpoint.version,
                    jobCheckpoint.data,
                    progress.completed,
                    nowMs,
                    input.lease.jobID.uuidString.lowercased(),
                    input.lease.leaseOwner,
                    input.lease.attempts,
                ]
            )
            guard db.changesCount == 1 else {
                throw JobQueueError.staleLease(input.lease.jobID)
            }

            if control == .none {
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
        let progress: JobProgress
        if let checkpoint = input.checkpoint {
            progress = try monotonicProgress(lease: input.lease, checkpoint: checkpoint)
        } else {
            let persisted = try queue.fetchJob(id: input.lease.jobID)
            progress = JobProgress(completed: persisted.progress.completed, total: nil)
        }

        let jobCheckpoint: JobCheckpoint?
        if let checkpoint = input.checkpoint {
            jobCheckpoint = try makeJobCheckpoint(checkpoint)
        } else {
            jobCheckpoint = nil
        }

        let snapshot = try queue.commitLeaseProtectedBatch(
            input: SafeBatchCommitInput(
                lease: input.lease,
                outcome: input.outcome,
                checkpoint: jobCheckpoint,
                progress: progress,
                leaseDurationMs: input.leaseDurationMs
            )
        ) { db in
            try validateStopInput(db: db, input: input)
        }
        return FolderBatchCommitResult(
            jobSnapshot: snapshot,
            checkpoint: input.checkpoint,
            identityConflictsAdded: 0
        )
    }

    private func monotonicProgress(for input: FolderAssetBatchInput) throws -> JobProgress {
        try monotonicProgress(lease: input.lease, checkpoint: input.checkpoint)
    }

    private func monotonicProgress(
        lease: JobLeaseToken,
        checkpoint: FolderReconcileCheckpointV1
    ) throws -> JobProgress {
        let persisted = try queue.fetchJob(id: lease.jobID)
        let completed = max(persisted.progress.completed, checkpoint.candidateFiles)
        return JobProgress(completed: completed, total: nil)
    }

    private func validateJobKindAndVersion(jobRow: Row) throws {
        let kind: String = jobRow["kind"]
        let payloadVersion: Int = jobRow["payload_version"]
        guard kind == FolderReconcileJobFactory.kind else {
            throw FolderReconcileRepositoryError.invalidJobKind
        }
        guard payloadVersion == FolderReconcileJobFactory.payloadVersion else {
            throw FolderReconcileRepositoryError.invalidPayloadVersion
        }
    }

    private func validateJobSourceConsistency(jobRow: Row, sourceID: UUID) throws {
        guard let jobSourceIDString: String = jobRow["source_id"],
              let jobSourceID = UUID(uuidString: jobSourceIDString),
              jobSourceID == sourceID
        else {
            throw FolderReconcileRepositoryError.sourceMismatch
        }
    }

    private func validateBatchInput(db: Database, input: FolderAssetBatchInput) throws {
        guard input.outcome == .continue else {
            throw FolderReconcileRepositoryError.invalidBatchOutcome
        }
        let jobRow = try requireRunningJob(db: db, lease: input.lease)
        try validateJobKindAndVersion(jobRow: jobRow)
        try validateJobSourceConsistency(jobRow: jobRow, sourceID: input.sourceID)
        try requireActiveFolderSource(db: db, sourceID: input.sourceID)
        try validateGenerationConsistency(
            jobRow: jobRow,
            generation: input.generation,
            startedDirtyEpoch: input.startedDirtyEpoch,
            attempt: input.lease.attempts,
            checkpoint: input.checkpoint
        )
        try validateCheckpointValueDomain(input.checkpoint)
        for observation in input.observations {
            try validateObservation(observation)
        }
    }

    private func validateCompleteInput(db: Database, input: FolderCompleteGenerationInput) throws {
        let jobRow = try requireRunningJob(db: db, lease: input.lease)
        try validateJobKindAndVersion(jobRow: jobRow)
        try validateJobSourceConsistency(jobRow: jobRow, sourceID: input.sourceID)
        try validateGenerationConsistency(
            jobRow: jobRow,
            generation: input.generation,
            startedDirtyEpoch: input.startedDirtyEpoch,
            attempt: input.lease.attempts,
            checkpoint: input.checkpoint
        )
        try validateCheckpointValueDomain(input.checkpoint)

        let control: String = jobRow["control_request"]
        if control == JobControlRequest.none.rawValue {
            _ = try requireActiveFolderSource(db: db, sourceID: input.sourceID)
        }
    }

    private func validateStopInput(db: Database, input: FolderStopIncompleteInput) throws {
        let jobRow = try requireRunningJob(db: db, lease: input.lease)
        try validateJobKindAndVersion(jobRow: jobRow)
        try validateJobSourceConsistency(jobRow: jobRow, sourceID: input.sourceID)

        guard isAllowedFolderStopCode(input.errorCode) else {
            throw FolderReconcileRepositoryError.invalidStopCode
        }
        guard input.outcome == FolderReconcileSafeErrorSettlement.outcome(for: input.errorCode) else {
            throw FolderReconcileRepositoryError.invalidStopSettlement
        }

        let jobGeneration: Int? = jobRow["scan_generation"]
        let jobEpoch: Int? = jobRow["started_dirty_epoch"]

        if let checkpoint = input.checkpoint {
            guard let jobGeneration, let jobEpoch else {
                throw FolderReconcileRepositoryError.checkpointInvalid
            }
            try validateGenerationConsistency(
                jobRow: jobRow,
                generation: checkpoint.generation,
                startedDirtyEpoch: checkpoint.startedDirtyEpoch,
                attempt: input.lease.attempts,
                checkpoint: checkpoint
            )
            try validateCheckpointValueDomain(checkpoint)
        } else {
            guard jobGeneration == nil, jobEpoch == nil else {
                throw FolderReconcileRepositoryError.checkpointInvalid
            }
        }
    }

    private func validatePayloadInTransaction(
        payloadVersion: Int,
        payload: Data,
        jobSourceID: UUID
    ) throws {
        switch FolderReconcilePayloadValidation.validate(
            payloadVersion: payloadVersion,
            payload: payload,
            jobSourceID: jobSourceID
        ) {
        case .success:
            break
        case let .failure(.invalid(code)):
            throw FolderReconcileRepositoryError.payloadInvalid(code)
        }
    }

    private func validateCheckpointValueDomain(_ checkpoint: FolderReconcileCheckpointV1) throws {
        guard checkpoint.enumeratedEntries >= 0,
              checkpoint.candidateFiles >= 0,
              checkpoint.committedAssets >= 0,
              checkpoint.ignoredEntries >= 0,
              checkpoint.unsupportedAssets >= 0,
              checkpoint.unreadableAssets >= 0,
              checkpoint.identityConflicts >= 0,
              checkpoint.generation > 0,
              checkpoint.startedDirtyEpoch >= 0,
              checkpoint.attempt > 0
        else {
            throw FolderReconcileRepositoryError.checkpointInvalid
        }
    }

    private func isAllowedFolderStopCode(_ code: JobSafeErrorCode) -> Bool {
        switch code {
        case .folderPayloadInvalid, .folderCheckpointInvalid, .folderAuthorizationRequired,
             .folderSourceUnavailable, .folderEnumerationIncomplete, .folderUnsafeRelativePath:
            return true
        default:
            return false
        }
    }

    private func validateGenerationConsistency(
        jobRow: Row,
        generation: Int,
        startedDirtyEpoch: Int,
        attempt: Int,
        checkpoint: FolderReconcileCheckpointV1
    ) throws {
        let jobGeneration: Int? = jobRow["scan_generation"]
        let jobEpoch: Int? = jobRow["started_dirty_epoch"]
        guard jobGeneration == generation,
              jobEpoch == startedDirtyEpoch,
              checkpoint.generation == generation,
              checkpoint.startedDirtyEpoch == startedDirtyEpoch,
              checkpoint.attempt == attempt
        else {
            throw FolderReconcileRepositoryError.checkpointInvalid
        }
    }

    private func validateObservation(_ observation: FolderReconcileAssetObservation) throws {
        switch RelativePathRules.validate(observation.relativePath) {
        case .success:
            break
        case .failure:
            throw FolderReconcileRepositoryError.unsafeRelativePath
        }
        guard let fileName = RelativePathRules.fileName(from: observation.relativePath),
              fileName == observation.fileName
        else {
            throw FolderReconcileRepositoryError.invalidObservation
        }
    }

    @discardableResult
    private func upsertAssetObservation(
        db: Database,
        sourceID: UUID,
        generation: Int,
        observation: FolderReconcileAssetObservation,
        nowMs: Int64
    ) throws -> Int {
        let sourceIDString = sourceID.uuidString.lowercased()

        if let existing = try fetchCurrentAsset(db: db, sourceID: sourceID, relativePath: observation.relativePath) {
            return try applySamePathUpdate(
                db: db,
                existing: existing,
                observation: observation,
                generation: generation,
                nowMs: nowMs
            )
        }

        if observation.availability == .available,
           let relocateAssetID = try resolveMoveReconnectInTransaction(
               db: db,
               sourceID: sourceID,
               generation: generation,
               observation: observation
           )
        {
            try relocateAsset(
                db: db,
                sourceID: sourceID,
                assetID: relocateAssetID,
                observation: observation,
                generation: generation,
                nowMs: nowMs
            )
            return 0
        }

        if observation.availability == .available,
           let probe = observation.movePathProbe,
           probe == .multipleCandidates || probe == .oldPathSameResourceID || probe == .oldPathProbeError
        {
            try insertNewAsset(
                db: db,
                sourceID: sourceIDString,
                observation: observation,
                generation: generation,
                nowMs: nowMs
            )
            return 1
        }

        try insertNewAsset(
            db: db,
            sourceID: sourceIDString,
            observation: observation,
            generation: generation,
            nowMs: nowMs
        )
        return 0
    }

    @discardableResult
    private func applySamePathUpdate(
        db: Database,
        existing: ExistingAssetRecord,
        observation: FolderReconcileAssetObservation,
        generation: Int,
        nowMs: Int64
    ) throws -> Int {
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
            return 0
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
            return 0
        case .conflict:
            try updateConflictAsset(
                db: db,
                assetID: existing.assetID,
                generation: generation,
                nowMs: nowMs
            )
            return 1
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

    private func resolveMoveReconnectInTransaction(
        db: Database,
        sourceID: UUID,
        generation: Int,
        observation: FolderReconcileAssetObservation
    ) throws -> UUID? {
        guard let resourceID = observation.resourceID else {
            return nil
        }
        guard let probe = observation.movePathProbe,
              probe == .oldPathMissing || probe == .oldPathDifferentResourceID
        else {
            return nil
        }

        let candidates = try fetchMoveCandidatesInTransaction(
            db: db,
            sourceID: sourceID,
            resourceID: resourceID,
            excludingGeneration: generation
        )
        guard candidates.count == 1, let candidate = candidates.first else {
            return nil
        }
        guard candidate.sourceID == sourceID.uuidString.lowercased(),
              candidate.lastSeenGeneration == nil || candidate.lastSeenGeneration! < generation
        else {
            return nil
        }
        return candidate.assetID
    }

    private func fetchMoveCandidatesInTransaction(
        db: Database,
        sourceID: UUID,
        resourceID: Data,
        excludingGeneration: Int
    ) throws -> [MoveCandidateRecord] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT a.id, a.source_id, a.relative_path, a.last_seen_generation
            FROM asset a
            JOIN file_fingerprint f ON f.asset_id = a.id
            WHERE a.source_id = ?
                AND a.locator_kind = 'file'
                AND a.locator_state = 'current'
                AND f.resource_id = ?
                AND (a.last_seen_generation IS NULL OR a.last_seen_generation < ?)
            """,
            arguments: [
                sourceID.uuidString.lowercased(),
                resourceID,
                excludingGeneration,
            ]
        )
        return rows.map { row in
            MoveCandidateRecord(
                assetID: UUID(uuidString: row["id"])!,
                sourceID: row["source_id"],
                relativePath: row["relative_path"],
                lastSeenGeneration: row["last_seen_generation"]
            )
        }
    }

    private func relocateAsset(
        db: Database,
        sourceID: UUID,
        assetID: UUID,
        observation: FolderReconcileAssetObservation,
        generation: Int,
        nowMs: Int64
    ) throws {
        guard let existing = try fetchAssetByID(db: db, assetID: assetID) else {
            throw FolderReconcileRepositoryError.assetNotFound
        }
        let sourceIDString = sourceID.uuidString.lowercased()
        guard existing.sourceID == sourceIDString else {
            throw FolderReconcileRepositoryError.assetNotFound
        }
        if let observationResourceID = observation.resourceID,
           let existingResourceID = existing.resourceID,
           observationResourceID != existingResourceID
        {
            throw FolderReconcileRepositoryError.invalidObservation
        }
        if let currentAtNewPath = try fetchCurrentAsset(
            db: db,
            sourceID: sourceID,
            relativePath: observation.relativePath
        ), currentAtNewPath.assetID != assetID {
            throw FolderReconcileRepositoryError.invalidObservation
        }

        let newRevision = fingerprintChanged(existing: existing, observation: observation)
            ? existing.contentRevision + 1
            : existing.contentRevision

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

    private func fetchAssetByID(db: Database, assetID: UUID) throws -> ExistingAssetRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT a.id AS asset_id, a.source_id, a.availability, a.content_revision,
                   f.size_bytes, f.modified_at_ns, f.resource_id
            FROM asset a
            LEFT JOIN file_fingerprint f ON f.asset_id = a.id
            WHERE a.id = ?
            """,
            arguments: [assetID.uuidString.lowercased()]
        ) else {
            return nil
        }
        return ExistingAssetRecord(row: row)
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
    case invalidJobKind
    case invalidPayloadVersion
    case sourceMismatch
    case batchLimitExceeded
    case unsafeRelativePath
    case invalidObservation
    case assetNotFound
    case invalidBatchOutcome
    case invalidStopCode
    case invalidStopSettlement
    case payloadInvalid(JobSafeErrorCode)
}

private struct MoveCandidateRecord {
    let assetID: UUID
    let sourceID: String
    let relativePath: String
    let lastSeenGeneration: Int?
}
