import Foundation

enum LibrarySlimmingPurgeJobFactory {
    static let kind = "librarySlimming.purgeExpired.v1"
    static let payloadVersion = 1
    static let contractVersion = 1
    static let maxAttempts = 3
    static let priority = 0

    static func coalescingKey() -> String { kind }

    static func makePayload() throws -> Data {
        let payload: [String: Any] = ["contract_version": contractVersion]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw LibrarySlimmingRecycleError.ioFailure
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    static func makeEnqueueCommand(jobID: UUID, notBeforeMs: Int64) throws -> EnqueueJobCommand {
        EnqueueJobCommand(
            id: jobID,
            kind: kind,
            payloadVersion: payloadVersion,
            payload: try makePayload(),
            sourceID: nil,
            coalescingKey: coalescingKey(),
            priority: priority,
            maxAttempts: maxAttempts,
            notBeforeMs: notBeforeMs
        )
    }
}

struct LibrarySlimmingPurgeExpiredHandler: JobHandler {
    let recycle: any LibrarySlimmingRecyclePort
    let clock: any JobClock

    var kind: String { LibrarySlimmingPurgeJobFactory.kind }
    var supportedPayloadVersions: Set<Int> { [LibrarySlimmingPurgeJobFactory.payloadVersion] }
    var supportedCheckpointVersions: Set<Int> { [] }

    func execute(
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?
    ) -> JobHandlerExecutionResult {
        _ = payloadVersion
        _ = payload
        _ = checkpoint
        do {
            let purged = try recycle.purgeExpired(nowMs: clock.nowMs)
            return JobHandlerExecutionResult(
                outcome: .completed,
                checkpoint: nil,
                progress: JobProgress(completed: purged, total: purged)
            )
        } catch {
            return JobHandlerExecutionResult(
                outcome: .nonRetryableFailure(code: .librarySlimmingPurgeFailed),
                checkpoint: nil,
                progress: JobProgress(completed: 0, total: nil)
            )
        }
    }
}
