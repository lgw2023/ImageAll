import Foundation
import GRDB
import XCTest
@testable import ImageAll

enum JobTestSupport {
    static let baseTimeMs: Int64 = 1_700_000_000_000
    static let leaseDurationMs: Int64 = 60_000
    static let retryDelayMs: Int64 = 5_000
    static let testKind = "test.fake"
    static let testPayload = Data("payload".utf8)
    static let testCheckpoint = JobCheckpoint(version: 1, data: Data("checkpoint".utf8))

    final class HandlerCallTracker: @unchecked Sendable {
        private(set) var called = false

        func markCalled() {
            called = true
        }
    }

    final class BusinessWorkTracker: @unchecked Sendable {
        private(set) var executed = false

        func markExecuted() {
            executed = true
        }
    }

    static func makeQueue(
        database: CatalogDatabase,
        nowMs: Int64 = baseTimeMs,
        retryDelayMs: Int64 = retryDelayMs
    ) -> GRDBJobQueue {
        GRDBJobQueue(
            database: database,
            clock: FixedJobClock(nowMs: nowMs),
            retryPolicy: FixedDelayRetryPolicy(delayMs: retryDelayMs)
        )
    }

    static func makeCoordinator(
        queue: GRDBJobQueue,
        handlers: [any JobHandler] = []
    ) -> JobExecutionCoordinator {
        JobExecutionCoordinator(
            queue: queue,
            registry: InMemoryJobHandlerRegistry(handlers: handlers)
        )
    }

    static func enqueueDefault(
        queue: GRDBJobQueue,
        id: UUID = UUID(),
        kind: String = testKind,
        payloadVersion: Int = 1,
        payload: Data = testPayload,
        sourceID: UUID? = nil,
        coalescingKey: String? = nil,
        priority: Int = 0,
        maxAttempts: Int = 3,
        notBeforeMs: Int64 = baseTimeMs
    ) throws -> JobRecordSnapshot {
        try queue.enqueue(
            EnqueueJobCommand(
                id: id,
                kind: kind,
                payloadVersion: payloadVersion,
                payload: payload,
                sourceID: sourceID,
                coalescingKey: coalescingKey,
                priority: priority,
                maxAttempts: maxAttempts,
                notBeforeMs: notBeforeMs
            )
        )
    }

    static func claimDefault(
        queue: GRDBJobQueue,
        owner: String = "worker-1"
    ) throws -> JobLeaseToken? {
        try queue.claimNext(
            ClaimNextInput(owner: owner, leaseDurationMs: leaseDurationMs)
        )
    }

    static func fetchRowSnapshot(
        _ db: Database,
        jobID: UUID
    ) throws -> JobRowSnapshot? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM job WHERE id = ?",
            arguments: [jobID.uuidString.lowercased()]
        ) else {
            return nil
        }
        return JobRowSnapshot(row: row)
    }

    static func fetchSourceRowSnapshot(
        _ db: Database,
        sourceID: UUID
    ) throws -> JobRowSnapshot? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM source WHERE id = ?",
            arguments: [sourceID.uuidString.lowercased()]
        ) else {
            return nil
        }
        return JobRowSnapshot(row: row)
    }

    static func insertRunningJobForRecovery(
        database: CatalogDatabase,
        id: UUID = UUID(),
        control: JobControlRequest = .none,
        attempts: Int = 1,
        maxAttempts: Int = 3,
        checkpoint: JobCheckpoint? = nil,
        progress: JobProgress = JobProgress(completed: 0, total: nil)
    ) throws {
        let nowMs = baseTimeMs
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, state, control_request,
                    priority, attempts, max_attempts, not_before_ms,
                    lease_owner, lease_expires_at_ms,
                    checkpoint_version, checkpoint,
                    progress_completed, progress_total,
                    created_at_ms, updated_at_ms
                ) VALUES (?, ?, 1, ?, 'running', ?, 0, ?, ?, ?, 'stale-worker', ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    id.uuidString.lowercased(),
                    testKind,
                    testPayload,
                    control.rawValue,
                    attempts,
                    maxAttempts,
                    nowMs,
                    nowMs + leaseDurationMs,
                    checkpoint?.version,
                    checkpoint?.data,
                    progress.completed,
                    progress.total,
                    nowMs,
                    nowMs,
                ]
            )
        }
    }

    static func incrementSourceDirtyEpoch(
        _ db: Database,
        sourceID: UUID,
        delta: Int,
        nowMs: Int64 = baseTimeMs
    ) throws {
        try db.execute(
            sql: """
            UPDATE source SET dirty_epoch = dirty_epoch + ?, updated_at_ms = ?
            WHERE id = ?
            """,
            arguments: [delta, nowMs, sourceID.uuidString.lowercased()]
        )
    }

    static func prepareJobInState(
        queue: GRDBJobQueue,
        database: CatalogDatabase,
        state: JobState,
        jobID: UUID = UUID(),
        maxAttempts: Int = 3
    ) throws -> UUID {
        switch state {
        case .pending:
            _ = try enqueueDefault(queue: queue, id: jobID, maxAttempts: maxAttempts)
        case .running:
            _ = try enqueueDefault(queue: queue, id: jobID, maxAttempts: maxAttempts)
            _ = try XCTUnwrap(try claimDefault(queue: queue))
        case .paused:
            _ = try enqueueDefault(queue: queue, id: jobID, maxAttempts: maxAttempts)
            _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .pause))
        case .retryableFailed:
            _ = try enqueueDefault(queue: queue, id: jobID, maxAttempts: maxAttempts)
            let lease = try XCTUnwrap(try claimDefault(queue: queue))
            _ = try queue.submitSafeBatch(
                SafeBatchCommitInput(
                    lease: lease,
                    outcome: .retryableFailure(code: .interrupted),
                    checkpoint: nil,
                    progress: JobProgress(completed: 0, total: nil)
                )
            )
        case .completed, .terminalFailed, .cancelled:
            _ = try enqueueDefault(queue: queue, id: jobID, maxAttempts: maxAttempts)
            let lease = try XCTUnwrap(try claimDefault(queue: queue))
            let outcome: JobHandlerOutcome
            switch state {
            case .completed:
                outcome = .completed
            case .terminalFailed:
                outcome = .nonRetryableFailure(code: .interrupted)
            case .cancelled:
                _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .cancel))
                _ = try queue.submitSafeBatch(
                    SafeBatchCommitInput(
                        lease: lease,
                        outcome: .continue,
                        checkpoint: nil,
                        progress: JobProgress(completed: 0, total: nil)
                    )
                )
                return jobID
            default:
                outcome = .completed
            }
            _ = try queue.submitSafeBatch(
                SafeBatchCommitInput(
                    lease: lease,
                    outcome: outcome,
                    checkpoint: nil,
                    progress: JobProgress(completed: 1, total: 1)
                )
            )
        }
        return jobID
    }
}

extension XCTestCase {
    func assertRowUnchanged(
        database: CatalogDatabase,
        jobID: UUID,
        baseline: JobRowSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let current = try database.pool.read { db in
            try JobTestSupport.fetchRowSnapshot(db, jobID: jobID)
        }
        XCTAssertEqual(current, baseline, file: file, line: line)
    }

    func assertSourceRowUnchanged(
        database: CatalogDatabase,
        sourceID: UUID,
        baseline: JobRowSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let current = try database.pool.read { db in
            try JobTestSupport.fetchSourceRowSnapshot(db, sourceID: sourceID)
        }
        XCTAssertEqual(current, baseline, file: file, line: line)
    }
}
