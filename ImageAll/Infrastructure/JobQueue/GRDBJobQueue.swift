import Foundation
import GRDB

struct GRDBJobQueue: JobQueue, JobBusinessBatchQueue, Sendable {
    let database: CatalogDatabase
    let clock: JobClock
    let retryPolicy: RetryPolicy

    func enqueue(_ command: EnqueueJobCommand) throws -> JobRecordSnapshot {
        guard command.maxAttempts > 0 else {
            throw JobQueueError.invalidClaimInput(reason: "maxAttempts must be > 0")
        }
        guard command.payloadVersion >= 1 else {
            throw JobQueueError.invalidClaimInput(reason: "payloadVersion must be >= 1")
        }
        guard !command.kind.isEmpty else {
            throw JobQueueError.invalidClaimInput(reason: "kind must be non-empty")
        }

        let nowMs = clock.nowMs
        let jobID = command.id.uuidString.lowercased()

        return try database.pool.write { db in
            if let sourceID = command.sourceID {
                let exists = try Int.fetchOne(
                    db,
                    sql: "SELECT 1 FROM source WHERE id = ?",
                    arguments: [sourceID.uuidString.lowercased()]
                )
                guard exists == 1 else {
                    throw JobQueueError.referenceNotFound
                }
            }

            do {
                try db.execute(
                    sql: """
                    INSERT INTO job (
                        id, kind, payload_version, payload, source_id, coalescing_key,
                        checkpoint_version, checkpoint, scan_generation, started_dirty_epoch,
                        state, control_request, priority, attempts, max_attempts, not_before_ms,
                        lease_owner, lease_expires_at_ms, progress_completed, progress_total,
                        last_error_code, last_error_message, created_at_ms, updated_at_ms
                    ) VALUES (
                        ?, ?, ?, ?, ?, ?,
                        NULL, NULL, NULL, NULL,
                        'pending', 'none', ?, 0, ?, ?,
                        NULL, NULL, 0, NULL,
                        NULL, NULL, ?, ?
                    )
                    """,
                    arguments: [
                        jobID,
                        command.kind,
                        command.payloadVersion,
                        command.payload,
                        command.sourceID?.uuidString.lowercased(),
                        command.coalescingKey,
                        command.priority,
                        command.maxAttempts,
                        command.notBeforeMs,
                        nowMs,
                        nowMs,
                    ]
                )
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                if let coalescingKey = command.coalescingKey {
                    if let existingID: String = try String.fetchOne(
                        db,
                        sql: """
                        SELECT id FROM job
                        WHERE coalescing_key = ?
                            AND state IN ('pending', 'running', 'paused', 'retryableFailed')
                        """,
                        arguments: [coalescingKey]
                    ), let existingUUID = UUID(uuidString: existingID) {
                        throw JobQueueError.activeCoalescingConflict(existingJobID: existingUUID)
                    }
                }
                throw error
            }

            guard let snapshot = try JobRowReader.fetchSnapshot(db, jobID: command.id) else {
                throw JobQueueError.jobNotFound(command.id)
            }
            return snapshot
        }
    }

    func fetchJob(id: UUID) throws -> JobRecordSnapshot {
        try database.pool.read { db in
            guard let snapshot = try JobRowReader.fetchSnapshot(db, jobID: id) else {
                throw JobQueueError.jobNotFound(id)
            }
            return snapshot
        }
    }

    func claimNext(_ input: ClaimNextInput) throws -> JobLeaseToken? {
        guard !input.owner.isEmpty else {
            throw JobQueueError.invalidClaimInput(reason: "owner must be non-empty")
        }
        guard input.leaseDurationMs > 0 else {
            throw JobQueueError.invalidClaimInput(reason: "leaseDurationMs must be > 0")
        }

        let nowMs = clock.nowMs
        let leaseExpiresAtMs = nowMs + input.leaseDurationMs

        return try database.pool.write { db in
            guard let candidate = try Row.fetchOne(
                db,
                sql: """
                SELECT id, attempts FROM job
                WHERE state = 'pending'
                    AND not_before_ms <= ?
                    AND attempts < max_attempts
                ORDER BY priority DESC, not_before_ms ASC, id ASC
                LIMIT 1
                """,
                arguments: [nowMs]
            ) else {
                return nil
            }

            let jobID: String = candidate["id"]
            let previousAttempts: Int = candidate["attempts"]
            let nextAttempts = previousAttempts + 1

            try db.execute(
                sql: """
                UPDATE job SET
                    state = 'running',
                    attempts = ?,
                    lease_owner = ?,
                    lease_expires_at_ms = ?,
                    last_error_code = NULL,
                    last_error_message = NULL,
                    updated_at_ms = ?
                WHERE id = ?
                    AND state = 'pending'
                    AND attempts = ?
                    AND attempts < max_attempts
                    AND not_before_ms <= ?
                """,
                arguments: [
                    nextAttempts,
                    input.owner,
                    leaseExpiresAtMs,
                    nowMs,
                    jobID,
                    previousAttempts,
                    nowMs,
                ]
            )

            guard db.changesCount == 1 else {
                return nil
            }

            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM job WHERE id = ?",
                arguments: [jobID]
            ) else {
                return nil
            }

            return try JobPersistenceMapping.leaseToken(from: row)
        }
    }

    func applyStateCommand(_ command: JobStateCommand) throws -> JobRecordSnapshot {
        let nowMs = clock.nowMs

        return try database.pool.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM job WHERE id = ?",
                arguments: [command.jobID.uuidString.lowercased()]
            ) else {
                throw JobQueueError.jobNotFound(command.jobID)
            }

            let snapshot = try JobPersistenceMapping.snapshot(from: row)

            switch command.operation {
            case .pause:
                try applyPause(db: db, snapshot: snapshot, nowMs: nowMs)
            case .cancel:
                try applyCancel(db: db, snapshot: snapshot, nowMs: nowMs)
            case let .resume(notBeforeMs):
                try applyResume(db: db, snapshot: snapshot, notBeforeMs: notBeforeMs, nowMs: nowMs)
            }

            guard let updated = try JobRowReader.fetchSnapshot(db, jobID: command.jobID) else {
                throw JobQueueError.jobNotFound(command.jobID)
            }
            return updated
        }
    }

    func submitSafeBatch(_ input: SafeBatchCommitInput) throws -> JobRecordSnapshot {
        try JobPersistenceMapping.validateProgress(input.progress)

        let nowMs = clock.nowMs

        return try database.pool.write { db in
            try submitSafeBatchInTransaction(db: db, input: input, nowMs: nowMs)
        }
    }

    func settleRetryableJobs() throws {
        let nowMs = clock.nowMs

        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE job SET
                    state = 'terminalFailed',
                    last_error_code = 'attemptsExhausted',
                    last_error_message = NULL,
                    lease_owner = NULL,
                    lease_expires_at_ms = NULL,
                    control_request = 'none',
                    updated_at_ms = ?
                WHERE state = 'retryableFailed'
                    AND attempts >= max_attempts
                """,
                arguments: [nowMs]
            )

            try db.execute(
                sql: """
                UPDATE job SET
                    state = 'pending',
                    updated_at_ms = ?
                WHERE state = 'retryableFailed'
                    AND attempts < max_attempts
                    AND not_before_ms <= ?
                """,
                arguments: [nowMs, nowMs]
            )
        }
    }

    func recoverInterruptedRunningJobs() throws {
        let nowMs = clock.nowMs

        try database.pool.write { db in
            let runningRows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM job
                WHERE state = 'running'
                ORDER BY priority DESC, not_before_ms ASC, id ASC
                """
            )

            for row in runningRows {
                let snapshot = try JobPersistenceMapping.snapshot(from: row)
                switch snapshot.controlRequest {
                case .cancel:
                    try updateJobLeavingRunning(
                        db: db,
                        jobID: snapshot.id,
                        state: .cancelled,
                        notBeforeMs: snapshot.notBeforeMs,
                        errorCode: nil,
                        clearErrors: true,
                        nowMs: nowMs
                    )
                case .pause:
                    try updateJobLeavingRunning(
                        db: db,
                        jobID: snapshot.id,
                        state: .paused,
                        notBeforeMs: snapshot.notBeforeMs,
                        errorCode: nil,
                        clearErrors: true,
                        nowMs: nowMs
                    )
                case .none:
                    if snapshot.attempts >= snapshot.maxAttempts {
                        try updateJobLeavingRunning(
                            db: db,
                            jobID: snapshot.id,
                            state: .terminalFailed,
                            notBeforeMs: snapshot.notBeforeMs,
                            errorCode: .interrupted,
                            clearErrors: false,
                            nowMs: nowMs
                        )
                    } else {
                        let nextNotBefore = retryPolicy.nextNotBeforeMs(
                            nowMs: nowMs,
                            attempts: snapshot.attempts,
                            maxAttempts: snapshot.maxAttempts,
                            errorCode: .interrupted
                        )
                        try updateJobLeavingRunning(
                            db: db,
                            jobID: snapshot.id,
                            state: .retryableFailed,
                            notBeforeMs: nextNotBefore,
                            errorCode: .interrupted,
                            clearErrors: false,
                            nowMs: nowMs
                        )
                    }
                }
            }
        }
    }

    func commitSimulatedBusinessBatch(_ input: SimulatedBusinessWriteInput) throws -> JobRecordSnapshot {
        try JobPersistenceMapping.validateProgress(input.progress)

        let nowMs = clock.nowMs

        return try database.pool.write { db in
            try validateLease(db: db, lease: input.lease)

            let sourceExists = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM source WHERE id = ?",
                arguments: [input.sourceID.uuidString.lowercased()]
            )
            guard sourceExists == 1 else {
                throw JobQueueError.referenceNotFound
            }

            try db.execute(
                sql: """
                UPDATE source SET
                    dirty_epoch = dirty_epoch + ?,
                    updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [input.dirtyEpochDelta, nowMs, input.sourceID.uuidString.lowercased()]
            )

            return try submitSafeBatchInTransaction(
                db: db,
                input: SafeBatchCommitInput(
                    lease: input.lease,
                    outcome: input.outcome,
                    checkpoint: input.checkpoint,
                    progress: input.progress
                ),
                nowMs: nowMs
            )
        }
    }

    func commitSimulatedBusinessBatchWithFaultInjection(
        _ input: SimulatedBusinessWriteInput,
        afterSourceUpdate: () throws -> Void
    ) throws -> JobRecordSnapshot {
        try JobPersistenceMapping.validateProgress(input.progress)

        let nowMs = clock.nowMs

        return try database.pool.write { db in
            try validateLease(db: db, lease: input.lease)

            let sourceExists = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM source WHERE id = ?",
                arguments: [input.sourceID.uuidString.lowercased()]
            )
            guard sourceExists == 1 else {
                throw JobQueueError.referenceNotFound
            }

            try db.execute(
                sql: """
                UPDATE source SET
                    dirty_epoch = dirty_epoch + ?,
                    updated_at_ms = ?
                WHERE id = ?
                """,
                arguments: [input.dirtyEpochDelta, nowMs, input.sourceID.uuidString.lowercased()]
            )

            try afterSourceUpdate()

            return try submitSafeBatchInTransaction(
                db: db,
                input: SafeBatchCommitInput(
                    lease: input.lease,
                    outcome: input.outcome,
                    checkpoint: input.checkpoint,
                    progress: input.progress
                ),
                nowMs: nowMs
            )
        }
    }

    func submitSafeBatchWithForcedInvalidProgress(
        _ input: SafeBatchCommitInput,
        forcedProgressCompleted: Int,
        forcedProgressTotal: Int?
    ) throws -> JobRecordSnapshot {
        let nowMs = clock.nowMs

        return try database.pool.write { db in
            try validateLease(db: db, lease: input.lease)

            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT control_request FROM job
                WHERE id = ? AND state = 'running'
                    AND lease_owner = ? AND attempts = ?
                """,
                arguments: [
                    input.lease.jobID.uuidString.lowercased(),
                    input.lease.leaseOwner,
                    input.lease.attempts,
                ]
            ) else {
                throw JobQueueError.staleLease(input.lease.jobID)
            }

            let controlRaw: String = row["control_request"]
            let control = try JobPersistenceMapping.controlRequest(from: controlRaw)
            let resolved = resolveSafeBoundaryOutcome(
                control: control,
                handlerOutcome: input.outcome,
                attempts: input.lease.attempts,
                maxAttempts: try fetchMaxAttempts(db: db, jobID: input.lease.jobID)
            )

            switch resolved {
            case .continueRunning:
                try db.execute(
                    sql: """
                    UPDATE job SET
                        checkpoint_version = ?,
                        checkpoint = ?,
                        progress_completed = ?,
                        progress_total = ?,
                        last_error_code = NULL,
                        last_error_message = NULL,
                        control_request = 'none',
                        updated_at_ms = ?
                    WHERE id = ? AND state = 'running'
                        AND lease_owner = ? AND attempts = ?
                    """,
                    arguments: [
                        input.checkpoint?.version,
                        input.checkpoint?.data,
                        forcedProgressCompleted,
                        forcedProgressTotal,
                        nowMs,
                        input.lease.jobID.uuidString.lowercased(),
                        input.lease.leaseOwner,
                        input.lease.attempts,
                    ]
                )
            default:
                break
            }

            guard let updated = try JobRowReader.fetchSnapshot(db, jobID: input.lease.jobID) else {
                throw JobQueueError.jobNotFound(input.lease.jobID)
            }
            return updated
        }
    }
}

private enum SafeBoundaryResolution {
    case continueRunning
    case leaveRunning(state: JobState, errorCode: JobSafeErrorCode?, notBeforeMs: Int64?)
}

private extension GRDBJobQueue {
    func applyPause(db: Database, snapshot: JobRecordSnapshot, nowMs: Int64) throws {
        switch snapshot.state {
        case .pending:
            try updateJobDirect(
                db: db,
                jobID: snapshot.id,
                expectedState: .pending,
                newState: .paused,
                notBeforeMs: snapshot.notBeforeMs,
                errorCode: nil,
                clearErrors: true,
                clearLease: true,
                controlRequest: .none,
                nowMs: nowMs
            )
        case .running:
            let upgraded = JobPersistenceMapping.upgradedControl(current: snapshot.controlRequest, requested: .pause)
            if upgraded == snapshot.controlRequest {
                return
            }
            try db.execute(
                sql: """
                UPDATE job SET
                    control_request = ?,
                    updated_at_ms = ?
                WHERE id = ? AND state = 'running'
                    AND control_request = ?
                """,
                arguments: [
                    upgraded.rawValue,
                    nowMs,
                    snapshot.id.uuidString.lowercased(),
                    snapshot.controlRequest.rawValue,
                ]
            )
            guard db.changesCount == 1 else {
                throw JobQueueError.invalidTransition(currentState: snapshot.state, operation: "pause")
            }
        case .paused:
            return
        case .retryableFailed:
            throw JobQueueError.invalidTransition(currentState: snapshot.state, operation: "pause")
        case .completed, .terminalFailed, .cancelled:
            throw JobQueueError.invalidTransition(currentState: snapshot.state, operation: "pause")
        }
    }

    func applyCancel(db: Database, snapshot: JobRecordSnapshot, nowMs: Int64) throws {
        switch snapshot.state {
        case .pending, .paused, .retryableFailed:
            try updateJobDirect(
                db: db,
                jobID: snapshot.id,
                expectedState: snapshot.state,
                newState: .cancelled,
                notBeforeMs: snapshot.notBeforeMs,
                errorCode: nil,
                clearErrors: true,
                clearLease: true,
                controlRequest: .none,
                nowMs: nowMs
            )
        case .running:
            let upgraded = JobPersistenceMapping.upgradedControl(current: snapshot.controlRequest, requested: .cancel)
            if upgraded == snapshot.controlRequest {
                return
            }
            try db.execute(
                sql: """
                UPDATE job SET
                    control_request = ?,
                    updated_at_ms = ?
                WHERE id = ? AND state = 'running'
                    AND control_request = ?
                """,
                arguments: [
                    upgraded.rawValue,
                    nowMs,
                    snapshot.id.uuidString.lowercased(),
                    snapshot.controlRequest.rawValue,
                ]
            )
            guard db.changesCount == 1 else {
                throw JobQueueError.invalidTransition(currentState: snapshot.state, operation: "cancel")
            }
        case .completed, .terminalFailed, .cancelled:
            throw JobQueueError.invalidTransition(currentState: snapshot.state, operation: "cancel")
        }
    }

    func applyResume(db: Database, snapshot: JobRecordSnapshot, notBeforeMs: Int64, nowMs: Int64) throws {
        guard snapshot.state == .paused else {
            throw JobQueueError.invalidTransition(currentState: snapshot.state, operation: "resume")
        }

        try updateJobDirect(
            db: db,
            jobID: snapshot.id,
            expectedState: .paused,
            newState: .pending,
            notBeforeMs: notBeforeMs,
            errorCode: nil,
            clearErrors: true,
            clearLease: true,
            controlRequest: .none,
            nowMs: nowMs
        )
    }

    func submitSafeBatchInTransaction(
        db: Database,
        input: SafeBatchCommitInput,
        nowMs: Int64
    ) throws -> JobRecordSnapshot {
        try validateLease(db: db, lease: input.lease)

        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT * FROM job
            WHERE id = ? AND state = 'running'
                AND lease_owner = ? AND attempts = ?
            """,
            arguments: [
                input.lease.jobID.uuidString.lowercased(),
                input.lease.leaseOwner,
                input.lease.attempts,
            ]
        ) else {
            throw JobQueueError.staleLease(input.lease.jobID)
        }

        let snapshot = try JobPersistenceMapping.snapshot(from: row)
        let maxAttempts = snapshot.maxAttempts
        let resolved = resolveSafeBoundaryOutcome(
            control: snapshot.controlRequest,
            handlerOutcome: input.outcome,
            attempts: input.lease.attempts,
            maxAttempts: maxAttempts
        )

        switch resolved {
        case .continueRunning:
            try db.execute(
                sql: """
                UPDATE job SET
                    checkpoint_version = ?,
                    checkpoint = ?,
                    progress_completed = ?,
                    progress_total = ?,
                    last_error_code = NULL,
                    last_error_message = NULL,
                    control_request = 'none',
                    updated_at_ms = ?
                WHERE id = ? AND state = 'running'
                    AND lease_owner = ? AND attempts = ?
                """,
                arguments: [
                    input.checkpoint?.version,
                    input.checkpoint?.data,
                    input.progress.completed,
                    input.progress.total,
                    nowMs,
                    input.lease.jobID.uuidString.lowercased(),
                    input.lease.leaseOwner,
                    input.lease.attempts,
                ]
            )
        case let .leaveRunning(state, errorCode, notBeforeMs):
            try updateJobLeavingRunning(
                db: db,
                jobID: input.lease.jobID,
                state: state,
                notBeforeMs: notBeforeMs ?? snapshot.notBeforeMs,
                errorCode: errorCode,
                clearErrors: errorCode == nil,
                checkpoint: input.checkpoint,
                progress: input.progress,
                nowMs: nowMs,
                expectedLeaseOwner: input.lease.leaseOwner,
                expectedAttempts: input.lease.attempts
            )
        }

        guard let updated = try JobRowReader.fetchSnapshot(db, jobID: input.lease.jobID) else {
            throw JobQueueError.jobNotFound(input.lease.jobID)
        }
        return updated
    }

    func validateLease(db: Database, lease: JobLeaseToken) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT state, lease_owner, attempts FROM job WHERE id = ?
            """,
            arguments: [lease.jobID.uuidString.lowercased()]
        ) else {
            throw JobQueueError.jobNotFound(lease.jobID)
        }

        let stateRaw: String = row["state"]
        let state = try JobPersistenceMapping.jobState(from: stateRaw)
        guard state == .running else {
            throw JobQueueError.jobNotRunning(lease.jobID)
        }

        let leaseOwner: String? = row["lease_owner"]
        let attempts: Int = row["attempts"]
        guard leaseOwner == lease.leaseOwner, attempts == lease.attempts else {
            throw JobQueueError.staleLease(lease.jobID)
        }
    }

    func fetchMaxAttempts(db: Database, jobID: UUID) throws -> Int {
        guard let maxAttempts: Int = try Int.fetchOne(
            db,
            sql: "SELECT max_attempts FROM job WHERE id = ?",
            arguments: [jobID.uuidString.lowercased()]
        ) else {
            throw JobQueueError.jobNotFound(jobID)
        }
        return maxAttempts
    }

    func resolveSafeBoundaryOutcome(
        control: JobControlRequest,
        handlerOutcome: JobHandlerOutcome,
        attempts: Int,
        maxAttempts: Int
    ) -> SafeBoundaryResolution {
        switch control {
        case .cancel:
            return .leaveRunning(state: .cancelled, errorCode: nil, notBeforeMs: nil)
        case .pause:
            return .leaveRunning(state: .paused, errorCode: nil, notBeforeMs: nil)
        case .none:
            switch handlerOutcome {
            case .continue:
                return .continueRunning
            case .completed:
                return .leaveRunning(state: .completed, errorCode: nil, notBeforeMs: nil)
            case let .retryableFailure(code):
                if attempts < maxAttempts {
                    let notBefore = retryPolicy.nextNotBeforeMs(
                        nowMs: clock.nowMs,
                        attempts: attempts,
                        maxAttempts: maxAttempts,
                        errorCode: code
                    )
                    return .leaveRunning(state: .retryableFailed, errorCode: code, notBeforeMs: notBefore)
                }
                return .leaveRunning(state: .terminalFailed, errorCode: code, notBeforeMs: nil)
            case let .nonRetryableFailure(code):
                return .leaveRunning(state: .terminalFailed, errorCode: code, notBeforeMs: nil)
            }
        }
    }

    func updateJobDirect(
        db: Database,
        jobID: UUID,
        expectedState: JobState,
        newState: JobState,
        notBeforeMs: Int64,
        errorCode: JobSafeErrorCode?,
        clearErrors: Bool,
        clearLease: Bool,
        controlRequest: JobControlRequest,
        nowMs: Int64
    ) throws {
        let errorCodeValue = clearErrors ? nil : errorCode?.rawValue
        let leaseOwner: String? = clearLease ? nil : nil
        let leaseExpires: Int64? = clearLease ? nil : nil

        try db.execute(
            sql: """
            UPDATE job SET
                state = ?,
                not_before_ms = ?,
                last_error_code = ?,
                last_error_message = NULL,
                lease_owner = ?,
                lease_expires_at_ms = ?,
                control_request = ?,
                updated_at_ms = ?
            WHERE id = ? AND state = ?
            """,
            arguments: [
                newState.rawValue,
                notBeforeMs,
                errorCodeValue,
                leaseOwner,
                leaseExpires,
                controlRequest.rawValue,
                nowMs,
                jobID.uuidString.lowercased(),
                expectedState.rawValue,
            ]
        )

        guard db.changesCount == 1 else {
            throw JobQueueError.invalidTransition(currentState: expectedState, operation: "stateUpdate")
        }
    }

    func updateJobLeavingRunning(
        db: Database,
        jobID: UUID,
        state: JobState,
        notBeforeMs: Int64,
        errorCode: JobSafeErrorCode?,
        clearErrors: Bool,
        checkpoint: JobCheckpoint? = nil,
        progress: JobProgress? = nil,
        nowMs: Int64,
        expectedLeaseOwner: String? = nil,
        expectedAttempts: Int? = nil
    ) throws {
        var sql = """
            UPDATE job SET
                state = ?,
                not_before_ms = ?,
                last_error_code = ?,
                last_error_message = NULL,
                lease_owner = NULL,
                lease_expires_at_ms = NULL,
                control_request = 'none',
                updated_at_ms = ?
            """
        var arguments: [DatabaseValueConvertible?] = [
            state.rawValue,
            notBeforeMs,
            clearErrors ? nil : errorCode?.rawValue,
            nowMs,
        ]

        if let checkpoint {
            sql += ", checkpoint_version = ?, checkpoint = ?"
            arguments.append(checkpoint.version)
            arguments.append(checkpoint.data)
        }
        if let progress {
            sql += ", progress_completed = ?, progress_total = ?"
            arguments.append(progress.completed)
            arguments.append(progress.total)
        }

        sql += " WHERE id = ? AND state = 'running'"
        arguments.append(jobID.uuidString.lowercased())

        if let expectedLeaseOwner, let expectedAttempts {
            sql += " AND lease_owner = ? AND attempts = ?"
            arguments.append(expectedLeaseOwner)
            arguments.append(expectedAttempts)
        }

        try db.execute(sql: sql, arguments: StatementArguments(arguments))

        guard db.changesCount == 1 else {
            throw JobQueueError.staleLease(jobID)
        }
    }
}
