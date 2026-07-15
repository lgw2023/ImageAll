import Foundation

enum JobQueueError: Error, Equatable, Sendable {
    case referenceNotFound
    case activeCoalescingConflict(existingJobID: UUID)
    case invalidTransition(currentState: JobState, operation: String)
    case invalidClaimInput(reason: String)
    case jobNotFound(UUID)
    case jobNotRunning(UUID)
    case jobNotClaimed(UUID)
    case staleLease(UUID)
    case expiredLease(UUID)
    case unknownPersistedRawValue(field: String, value: String)
    case unknownJobKind(String)
    case unsupportedPayloadVersion(kind: String, version: Int)
    case unsupportedCheckpointVersion(kind: String, version: Int)
    case invalidProgress(reason: String)
    case invalidSafeErrorCode(rawValue: String)
}
