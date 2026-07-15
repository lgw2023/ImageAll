import Foundation

protocol JobHandler: Sendable {
    var kind: String { get }
    var supportedPayloadVersions: Set<Int> { get }
    var supportedCheckpointVersions: Set<Int> { get }

    func execute(
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?
    ) -> JobHandlerExecutionResult
}

struct JobHandlerExecutionResult: Sendable, Equatable {
    let outcome: JobHandlerOutcome
    let checkpoint: JobCheckpoint?
    let progress: JobProgress
    let settledByHandler: Bool

    init(
        outcome: JobHandlerOutcome,
        checkpoint: JobCheckpoint?,
        progress: JobProgress,
        settledByHandler: Bool = false
    ) {
        self.outcome = outcome
        self.checkpoint = checkpoint
        self.progress = progress
        self.settledByHandler = settledByHandler
    }
}

struct JobLeaseExecutionContext: Sendable {
    let leaseDurationMs: Int64
    let reconcileBatch: any FolderReconcileBatchPort
}

protocol LeaseBoundJobHandler: JobHandler {
    func execute(
        lease: JobLeaseToken,
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?,
        context: JobLeaseExecutionContext
    ) throws -> JobHandlerExecutionResult
}

protocol JobHandlerRegistry: Sendable {
    func handler(forKind kind: String) -> (any JobHandler)?
}

enum JobRegistryValidation {
    static func validate(
        kind: String,
        payloadVersion: Int,
        checkpoint: JobCheckpoint?,
        registry: JobHandlerRegistry
    ) -> JobQueueError? {
        guard let handler = registry.handler(forKind: kind) else {
            return .unknownJobKind(kind)
        }
        guard handler.supportedPayloadVersions.contains(payloadVersion) else {
            return .unsupportedPayloadVersion(kind: kind, version: payloadVersion)
        }
        if let checkpoint {
            guard handler.supportedCheckpointVersions.contains(checkpoint.version) else {
                return .unsupportedCheckpointVersion(kind: kind, version: checkpoint.version)
            }
        }
        return nil
    }
}
