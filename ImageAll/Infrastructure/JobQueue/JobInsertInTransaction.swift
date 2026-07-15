import Foundation
import GRDB

enum JobInsertInTransaction {
    static func insertPendingJob(
        _ db: Database,
        command: EnqueueJobCommand,
        nowMs: Int64
    ) throws {
        guard command.maxAttempts > 0 else {
            throw JobQueueError.invalidClaimInput(reason: "maxAttempts must be > 0")
        }
        guard command.payloadVersion >= 1 else {
            throw JobQueueError.invalidClaimInput(reason: "payloadVersion must be >= 1")
        }
        guard !command.kind.isEmpty else {
            throw JobQueueError.invalidClaimInput(reason: "kind must be non-empty")
        }

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

        let jobID = command.id.uuidString.lowercased()
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
    }
}
