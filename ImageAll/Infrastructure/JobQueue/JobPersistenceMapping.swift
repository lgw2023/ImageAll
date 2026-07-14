import Foundation
import GRDB

enum JobPersistenceMapping {
    static func jobState(from raw: String) throws -> JobState {
        guard let state = JobState(rawValue: raw) else {
            throw JobQueueError.unknownPersistedRawValue(field: "state", value: raw)
        }
        return state
    }

    static func controlRequest(from raw: String) throws -> JobControlRequest {
        guard let request = JobControlRequest(rawValue: raw) else {
            throw JobQueueError.unknownPersistedRawValue(field: "control_request", value: raw)
        }
        return request
    }

    static func safeErrorCode(from raw: String?) throws -> JobSafeErrorCode? {
        guard let raw else { return nil }
        return try JobSafeErrorCode(persisted: raw)
    }

    static func validateProgressMonotonic(_ proposed: JobProgress, persisted: JobProgress) throws {
        guard proposed.completed >= persisted.completed else {
            throw JobQueueError.invalidProgress(reason: "progress_completed must not regress")
        }
    }

    static func upgradedControl(
        current: JobControlRequest,
        requested: JobControlRequest
    ) -> JobControlRequest {
        switch (current, requested) {
        case (_, .cancel):
            return .cancel
        case (.cancel, _):
            return .cancel
        case (.pause, .pause):
            return .pause
        case (.none, .pause):
            return .pause
        case (.none, .none):
            return .none
        case (.pause, .none):
            return .pause
        }
    }

    static func validateProgress(_ progress: JobProgress) throws {
        guard progress.completed >= 0 else {
            throw JobQueueError.invalidProgress(reason: "completed must be >= 0")
        }
        if let total = progress.total {
            guard total >= progress.completed else {
                throw JobQueueError.invalidProgress(reason: "total must be >= completed")
            }
        }
    }

    static func snapshot(from row: Row) throws -> JobRecordSnapshot {
        let idString: String = row["id"]
        guard let id = UUID(uuidString: idString) else {
            throw JobQueueError.unknownPersistedRawValue(field: "id", value: idString)
        }

        let checkpointVersion: Int? = row["checkpoint_version"]
        let checkpointData: Data? = row["checkpoint"]
        let checkpoint: JobCheckpoint?
        if let checkpointVersion, let checkpointData {
            checkpoint = JobCheckpoint(version: checkpointVersion, data: checkpointData)
        } else if checkpointVersion == nil, checkpointData == nil {
            checkpoint = nil
        } else {
            throw JobQueueError.unknownPersistedRawValue(field: "checkpoint", value: "mismatched nullability")
        }

        let sourceID: UUID?
        if let sourceIDString: String = row["source_id"] {
            guard let parsed = UUID(uuidString: sourceIDString) else {
                throw JobQueueError.unknownPersistedRawValue(field: "source_id", value: sourceIDString)
            }
            sourceID = parsed
        } else {
            sourceID = nil
        }

        let lastErrorRaw: String? = row["last_error_code"]
        let lastErrorCode = try safeErrorCode(from: lastErrorRaw)

        return JobRecordSnapshot(
            id: id,
            kind: row["kind"],
            payloadVersion: row["payload_version"],
            payload: row["payload"],
            sourceID: sourceID,
            coalescingKey: row["coalescing_key"],
            checkpoint: checkpoint,
            scanGeneration: row["scan_generation"],
            startedDirtyEpoch: row["started_dirty_epoch"],
            state: try jobState(from: row["state"]),
            controlRequest: try controlRequest(from: row["control_request"]),
            priority: row["priority"],
            attempts: row["attempts"],
            maxAttempts: row["max_attempts"],
            notBeforeMs: row["not_before_ms"],
            leaseOwner: row["lease_owner"],
            leaseExpiresAtMs: row["lease_expires_at_ms"],
            progress: JobProgress(
                completed: row["progress_completed"],
                total: row["progress_total"]
            ),
            lastErrorCode: lastErrorCode,
            createdAtMs: row["created_at_ms"],
            updatedAtMs: row["updated_at_ms"]
        )
    }

    static func leaseToken(from row: Row) throws -> JobLeaseToken {
        let snapshot = try snapshot(from: row)
        guard snapshot.state == .running,
              let leaseOwner = snapshot.leaseOwner,
              let leaseExpiresAtMs = snapshot.leaseExpiresAtMs else {
            throw JobQueueError.jobNotRunning(snapshot.id)
        }

        return JobLeaseToken(
            jobID: snapshot.id,
            leaseOwner: leaseOwner,
            attempts: snapshot.attempts,
            leaseExpiresAtMs: leaseExpiresAtMs,
            kind: snapshot.kind,
            payloadVersion: snapshot.payloadVersion,
            payload: snapshot.payload,
            checkpoint: snapshot.checkpoint
        )
    }
}

enum JobRowReader {
    static func fetchSnapshot(_ db: Database, jobID: UUID) throws -> JobRecordSnapshot? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM job WHERE id = ?",
            arguments: [jobID.uuidString.lowercased()]
        ) else {
            return nil
        }
        return try JobPersistenceMapping.snapshot(from: row)
    }
}
