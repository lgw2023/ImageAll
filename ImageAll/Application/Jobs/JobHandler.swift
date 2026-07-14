import Foundation

protocol JobHandler: Sendable {
    var kind: String { get }
    var supportedPayloadVersions: Set<Int> { get }
    var supportedCheckpointVersions: Set<Int> { get }

    func execute(
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?
    ) throws -> JobHandlerExecutionResult
}

struct JobHandlerExecutionResult: Sendable, Equatable {
    let outcome: JobHandlerOutcome
    let checkpoint: JobCheckpoint?
    let progress: JobProgress
}

protocol JobHandlerRegistry: Sendable {
    func handler(forKind kind: String) -> (any JobHandler)?
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
    private let resultProvider: @Sendable (Int, Data, JobCheckpoint?) throws -> JobHandlerExecutionResult

    init(
        kind: String,
        supportedPayloadVersions: Set<Int> = [1],
        supportedCheckpointVersions: Set<Int> = [1],
        resultProvider: @escaping @Sendable (Int, Data, JobCheckpoint?) throws -> JobHandlerExecutionResult
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
    ) throws -> JobHandlerExecutionResult {
        try resultProvider(payloadVersion, payload, checkpoint)
    }
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
