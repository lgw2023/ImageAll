import Foundation

enum JobState: String, Sendable, Equatable, CaseIterable {
    case pending
    case running
    case paused
    case retryableFailed
    case completed
    case terminalFailed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .terminalFailed, .cancelled:
            return true
        case .pending, .running, .paused, .retryableFailed:
            return false
        }
    }

    var isActiveCoalescing: Bool {
        switch self {
        case .pending, .running, .paused, .retryableFailed:
            return true
        case .completed, .terminalFailed, .cancelled:
            return false
        }
    }
}

enum JobControlRequest: String, Sendable, Equatable, CaseIterable {
    case none
    case pause
    case cancel
}

enum JobSafeErrorCode: String, Sendable, Equatable {
    case interrupted
    case attemptsExhausted
    case unknownJobKind
    case unsupportedPayloadVersion
    case unsupportedCheckpointVersion
}

enum JobHandlerOutcome: Sendable, Equatable {
    case `continue`
    case completed
    case retryableFailure(code: JobSafeErrorCode)
    case nonRetryableFailure(code: JobSafeErrorCode)
}

struct JobCheckpoint: Sendable, Equatable {
    let version: Int
    let data: Data
}

struct JobProgress: Sendable, Equatable {
    let completed: Int
    let total: Int?

    init(completed: Int, total: Int?) {
        self.completed = completed
        self.total = total
    }
}

struct JobRecordSnapshot: Sendable, Equatable {
    let id: UUID
    let kind: String
    let payloadVersion: Int
    let payload: Data
    let sourceID: UUID?
    let coalescingKey: String?
    let checkpoint: JobCheckpoint?
    let scanGeneration: Int?
    let startedDirtyEpoch: Int?
    let state: JobState
    let controlRequest: JobControlRequest
    let priority: Int
    let attempts: Int
    let maxAttempts: Int
    let notBeforeMs: Int64
    let leaseOwner: String?
    let leaseExpiresAtMs: Int64?
    let progress: JobProgress
    let lastErrorCode: JobSafeErrorCode?
    let createdAtMs: Int64
    let updatedAtMs: Int64
}

struct JobLeaseToken: Sendable, Equatable {
    let jobID: UUID
    let leaseOwner: String
    let attempts: Int
    let leaseExpiresAtMs: Int64
    let kind: String
    let payloadVersion: Int
    let payload: Data
    let checkpoint: JobCheckpoint?
}

struct EnqueueJobCommand: Sendable, Equatable {
    let id: UUID
    let kind: String
    let payloadVersion: Int
    let payload: Data
    let sourceID: UUID?
    let coalescingKey: String?
    let priority: Int
    let maxAttempts: Int
    let notBeforeMs: Int64
}

struct ClaimNextInput: Sendable, Equatable {
    let owner: String
    let leaseDurationMs: Int64
}

struct JobStateCommand: Sendable, Equatable {
    enum Operation: Sendable, Equatable {
        case pause
        case cancel
        case resume(notBeforeMs: Int64)
    }

    let jobID: UUID
    let operation: Operation
}

struct SafeBatchCommitInput: Sendable, Equatable {
    let lease: JobLeaseToken
    let outcome: JobHandlerOutcome
    let checkpoint: JobCheckpoint?
    let progress: JobProgress
}

struct SimulatedBusinessWriteInput: Sendable, Equatable {
    let lease: JobLeaseToken
    let sourceID: UUID
    let dirtyEpochDelta: Int
    let outcome: JobHandlerOutcome
    let checkpoint: JobCheckpoint?
    let progress: JobProgress
}
