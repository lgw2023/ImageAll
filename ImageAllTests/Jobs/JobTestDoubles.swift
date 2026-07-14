import Foundation
@testable import ImageAll

struct FixedJobClock: JobClock {
    let nowMs: Int64
}

struct FixedDelayRetryPolicy: RetryPolicy {
    let delayMs: Int64

    func nextNotBeforeMs(
        nowMs: Int64,
        attempts: Int,
        maxAttempts: Int,
        errorCode: JobSafeErrorCode
    ) -> Int64 {
        nowMs + delayMs
    }
}

struct InMemoryJobHandlerRegistry: JobHandlerRegistry {
    private let handlers: [String: any JobHandler]

    init(handlers: [any JobHandler]) {
        var map: [String: any JobHandler] = [:]
        for handler in handlers {
            map[handler.kind] = handler
        }
        self.handlers = map
    }

    func handler(forKind kind: String) -> (any JobHandler)? {
        handlers[kind]
    }
}

struct FakeJobHandler: JobHandler {
    let kind: String
    let supportedPayloadVersions: Set<Int>
    let supportedCheckpointVersions: Set<Int>
    private let resultProvider: @Sendable (Int, Data, JobCheckpoint?) -> JobHandlerExecutionResult

    init(
        kind: String,
        supportedPayloadVersions: Set<Int> = [1],
        supportedCheckpointVersions: Set<Int> = [1],
        resultProvider: @escaping @Sendable (Int, Data, JobCheckpoint?) -> JobHandlerExecutionResult
    ) {
        self.kind = kind
        self.supportedPayloadVersions = supportedPayloadVersions
        self.supportedCheckpointVersions = supportedCheckpointVersions
        self.resultProvider = resultProvider
    }

    func execute(
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?
    ) -> JobHandlerExecutionResult {
        resultProvider(payloadVersion, payload, checkpoint)
    }
}
