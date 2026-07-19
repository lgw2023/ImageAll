import Foundation

protocol JobQueue: Sendable {
    func enqueue(_ command: EnqueueJobCommand) throws -> JobRecordSnapshot
    func fetchJob(id: UUID) throws -> JobRecordSnapshot
    func fetchActivityItems() throws -> [JobActivityItem]
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
        guard let claim = try claimAndValidate(input) else { return nil }
        switch claim {
        case let .settled(result):
            return result
        case let .ready(lease, handler):
            return try executeSync(lease: lease, handler: handler, input: input)
        }
    }

    func claimAndExecuteOnceAsync(_ input: ClaimNextInput) async throws -> JobExecutionResult? {
        guard let claim = try claimAndValidate(input) else { return nil }
        switch claim {
        case let .settled(result):
            return result
        case let .ready(lease, handler):
            guard let asyncHandler = handler as? any AsyncLeaseBoundJobHandler else {
                return try executeSync(lease: lease, handler: handler, input: input)
            }
            let execution = try await asyncHandler.executeAsync(
                lease: lease,
                payloadVersion: lease.payloadVersion,
                payload: lease.payload,
                checkpoint: lease.checkpoint,
                context: try leaseContext(for: input)
            )
            return try settle(execution, lease: lease, leaseDurationMs: input.leaseDurationMs)
        }
    }

    private func claimAndValidate(_ input: ClaimNextInput) throws -> ValidatedJobClaim? {
        guard let lease = try queue.claimNext(input) else { return nil }
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
            return .settled(
                JobExecutionResult(lease: lease, snapshot: snapshot, handlerInvoked: false)
            )
        }
        guard let handler = registry.handler(forKind: lease.kind) else {
            throw JobQueueError.unknownJobKind(lease.kind)
        }
        return .ready(lease, handler)
    }

    private func executeSync(
        lease: JobLeaseToken,
        handler: any JobHandler,
        input: ClaimNextInput
    ) throws -> JobExecutionResult {
        let execution: JobHandlerExecutionResult
        if let leaseHandler = handler as? any LeaseBoundJobHandler {
            execution = try leaseHandler.execute(
                lease: lease,
                payloadVersion: lease.payloadVersion,
                payload: lease.payload,
                checkpoint: lease.checkpoint,
                context: try leaseContext(for: input)
            )
        } else {
            execution = handler.execute(
                payloadVersion: lease.payloadVersion,
                payload: lease.payload,
                checkpoint: lease.checkpoint
            )
        }
        return try settle(execution, lease: lease, leaseDurationMs: input.leaseDurationMs)
    }

    private func leaseContext(for input: ClaimNextInput) throws -> JobLeaseExecutionContext {
        guard let leaseContextProvider else {
            throw JobQueueError.invalidClaimInput(reason: "lease context provider required")
        }
        return leaseContextProvider.makeLeaseContext(leaseDurationMs: input.leaseDurationMs)
    }

    private func settle(
        _ execution: JobHandlerExecutionResult,
        lease: JobLeaseToken,
        leaseDurationMs: Int64
    ) throws -> JobExecutionResult {
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
                leaseDurationMs: leaseDurationMs
            )
        )
        return JobExecutionResult(lease: lease, snapshot: snapshot, handlerInvoked: true)
    }
}

private enum ValidatedJobClaim {
    case settled(JobExecutionResult)
    case ready(JobLeaseToken, any JobHandler)
}

struct JobExecutionResult: Sendable, Equatable {
    let lease: JobLeaseToken
    let snapshot: JobRecordSnapshot
    let handlerInvoked: Bool
}
