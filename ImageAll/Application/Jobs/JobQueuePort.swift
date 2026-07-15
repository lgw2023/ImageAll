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

struct JobExecutionCoordinator: Sendable {
    let queue: JobQueue
    let registry: JobHandlerRegistry
    let leaseContextProvider: (any JobLeaseContextProviding)?

    init(
        queue: JobQueue,
        registry: JobHandlerRegistry,
        leaseContextProvider: (any JobLeaseContextProviding)? = nil
    ) {
        self.queue = queue
        self.registry = registry
        self.leaseContextProvider = leaseContextProvider
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
            case .unsupportedPayloadVersion:
                errorCode = .unsupportedPayloadVersion
            case .unsupportedCheckpointVersion:
                errorCode = .unsupportedCheckpointVersion
            default:
                throw validationError
            }

            let persisted = try queue.fetchJob(id: lease.jobID)
            let snapshot = try queue.submitSafeBatch(
                SafeBatchCommitInput(
                    lease: lease,
                    outcome: .nonRetryableFailure(code: errorCode),
                    checkpoint: persisted.checkpoint,
                    progress: persisted.progress
                )
            )
            return JobExecutionResult(lease: lease, snapshot: snapshot, handlerInvoked: false)
        }

        guard let handler = registry.handler(forKind: lease.kind) else {
            throw JobQueueError.unknownJobKind(lease.kind)
        }

        if let leaseHandler = handler as? any LeaseBoundJobHandler {
            guard let leaseContextProvider else {
                throw JobQueueError.invalidClaimInput(reason: "lease context provider required")
            }
            let context = leaseContextProvider.makeLeaseContext(
                leaseDurationMs: input.leaseDurationMs
            )
            let execution = try leaseHandler.execute(
                lease: lease,
                payloadVersion: lease.payloadVersion,
                payload: lease.payload,
                checkpoint: lease.checkpoint,
                context: context
            )
            if execution.settledByHandler {
                let snapshot = try queue.fetchJob(id: lease.jobID)
                return JobExecutionResult(lease: lease, snapshot: snapshot, handlerInvoked: true)
            }
            let snapshot = try queue.submitSafeBatch(
                SafeBatchCommitInput(
                    lease: lease,
                    outcome: execution.outcome,
                    checkpoint: execution.checkpoint,
                    progress: execution.progress,
                    leaseDurationMs: input.leaseDurationMs
                )
            )
            return JobExecutionResult(lease: lease, snapshot: snapshot, handlerInvoked: true)
        }

        let execution = handler.execute(
            payloadVersion: lease.payloadVersion,
            payload: lease.payload,
            checkpoint: lease.checkpoint
        )

        let snapshot = try queue.submitSafeBatch(
            SafeBatchCommitInput(
                lease: lease,
                outcome: execution.outcome,
                checkpoint: execution.checkpoint,
                progress: execution.progress,
                leaseDurationMs: input.leaseDurationMs
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
