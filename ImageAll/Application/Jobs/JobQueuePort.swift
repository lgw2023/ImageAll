import Foundation

protocol JobQueue: Sendable {
    func enqueue(_ command: EnqueueJobCommand) throws -> JobRecordSnapshot
    func fetchJob(id: UUID) throws -> JobRecordSnapshot
    func claimNext(_ input: ClaimNextInput) throws -> JobLeaseToken?
    func applyStateCommand(_ command: JobStateCommand) throws -> JobRecordSnapshot
    func submitSafeBatch(_ input: SafeBatchCommitInput) throws -> JobRecordSnapshot
    func settleRetryableJobs() throws
    func recoverInterruptedRunningJobs() throws
}

protocol JobBusinessBatchQueue: Sendable {
    func commitSimulatedBusinessBatch(_ input: SimulatedBusinessWriteInput) throws -> JobRecordSnapshot
}

struct JobExecutionCoordinator: Sendable {
    let queue: JobQueue
    let registry: JobHandlerRegistry
    let retryPolicy: RetryPolicy
    let clock: JobClock

    init(
        queue: JobQueue,
        registry: JobHandlerRegistry,
        retryPolicy: RetryPolicy,
        clock: JobClock
    ) {
        self.queue = queue
        self.registry = registry
        self.retryPolicy = retryPolicy
        self.clock = clock
    }

    func claimAndExecuteOnce(_ input: ClaimNextInput) throws -> JobExecutionResult? {
        guard let lease = try queue.claimNext(input) else {
            return nil
        }

        if let validationError = JobRegistryValidation.validate(
            kind: lease.kind,
            payloadVersion: lease.payloadVersion,
            checkpoint: lease.checkpoint,
            registry: registry
        ) {
            let errorCode: JobSafeErrorCode
            switch validationError {
            case .unknownJobKind:
                errorCode = .unknownJobKind
            case let .unsupportedPayloadVersion:
                errorCode = .unsupportedPayloadVersion
            case let .unsupportedCheckpointVersion:
                errorCode = .unsupportedCheckpointVersion
            default:
                throw validationError
            }

            let snapshot = try queue.submitSafeBatch(
                SafeBatchCommitInput(
                    lease: lease,
                    outcome: .nonRetryableFailure(code: errorCode),
                    checkpoint: lease.checkpoint,
                    progress: JobProgress(completed: 0, total: nil)
                )
            )
            return JobExecutionResult(lease: lease, snapshot: snapshot, handlerInvoked: false)
        }

        guard let handler = registry.handler(forKind: lease.kind) else {
            throw JobQueueError.unknownJobKind(lease.kind)
        }

        let execution = try handler.execute(
            payloadVersion: lease.payloadVersion,
            payload: lease.payload,
            checkpoint: lease.checkpoint
        )

        let snapshot = try queue.submitSafeBatch(
            SafeBatchCommitInput(
                lease: lease,
                outcome: execution.outcome,
                checkpoint: execution.checkpoint,
                progress: execution.progress
            )
        )
        return JobExecutionResult(lease: lease, snapshot: snapshot, handlerInvoked: true)
    }
}

struct JobExecutionResult: Sendable, Equatable {
    let lease: JobLeaseToken
    let snapshot: JobRecordSnapshot
    let handlerInvoked: Bool
}
