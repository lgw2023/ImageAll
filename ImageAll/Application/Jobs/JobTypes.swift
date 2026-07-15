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

struct JobSafeErrorCode: Sendable, Equatable, Hashable {
    let rawValue: String

    static let interrupted = JobSafeErrorCode(unchecked: "interrupted")
    static let attemptsExhausted = JobSafeErrorCode(unchecked: "attemptsExhausted")
    static let unknownJobKind = JobSafeErrorCode(unchecked: "unknownJobKind")
    static let unsupportedPayloadVersion = JobSafeErrorCode(unchecked: "unsupportedPayloadVersion")
    static let unsupportedCheckpointVersion = JobSafeErrorCode(unchecked: "unsupportedCheckpointVersion")
    static let folderPayloadInvalid = JobSafeErrorCode(unchecked: "folderPayloadInvalid")
    static let folderCheckpointInvalid = JobSafeErrorCode(unchecked: "folderCheckpointInvalid")
    static let folderAuthorizationRequired = JobSafeErrorCode(unchecked: "folderAuthorizationRequired")
    static let folderSourceUnavailable = JobSafeErrorCode(unchecked: "folderSourceUnavailable")
    static let folderEnumerationIncomplete = JobSafeErrorCode(unchecked: "folderEnumerationIncomplete")
    static let folderUnsafeRelativePath = JobSafeErrorCode(unchecked: "folderUnsafeRelativePath")

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) throws {
        guard Self.isSafePersistedCode(rawValue) else {
            throw JobQueueError.invalidSafeErrorCode(rawValue: rawValue)
        }
        self.rawValue = rawValue
    }

    init(persisted rawValue: String) throws {
        guard Self.isSafePersistedCode(rawValue) else {
            throw JobQueueError.unknownPersistedRawValue(field: "last_error_code", value: rawValue)
        }
        self.rawValue = rawValue
    }

    static func isSafePersistedCode(_ rawValue: String) -> Bool {
        guard !rawValue.isEmpty, rawValue.count <= 64 else {
            return false
        }
        guard let first = rawValue.first, first.isLetter else {
            return false
        }
        return rawValue.allSatisfy { character in
            character.isLetter || character.isNumber
        }
    }
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
    let leaseDurationMs: Int64?

    init(
        lease: JobLeaseToken,
        outcome: JobHandlerOutcome,
        checkpoint: JobCheckpoint?,
        progress: JobProgress,
        leaseDurationMs: Int64? = nil
    ) {
        self.lease = lease
        self.outcome = outcome
        self.checkpoint = checkpoint
        self.progress = progress
        self.leaseDurationMs = leaseDurationMs
    }
}
