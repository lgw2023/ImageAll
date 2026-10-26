import Foundation

/// Monotonic timing for acknowledged uploads, separate from PhotoKit preparation,
/// hashing and receiver verification. Historical resumed bytes are not counted.
public struct RemoteMigrationTransferMetrics: Sendable {
    public enum Phase: String, CaseIterable, Sendable {
        case preparation, upload, verification, recovery, finalization
    }
    private var phase: Phase = .preparation
    private var phaseStartedAt: TimeInterval?
    private var accumulatedPhaseSeconds: [Phase: TimeInterval] = [:]
    public private(set) var confirmedBytes: Int64 = 0
    private var startedAt: TimeInterval?
    private var uploadStartedAt: TimeInterval?
    private var uploadSeconds: TimeInterval = 0
    private var finishedAt: TimeInterval?
    public init() {}
    public mutating func begin(at now: TimeInterval) {
        self = Self()
        startedAt = now
        phaseStartedAt = now
    }
    public mutating func enterPhase(_ next: Phase, at now: TimeInterval) {
        guard startedAt != nil, finishedAt == nil else { return }
        if let start = phaseStartedAt {
            accumulatedPhaseSeconds[phase, default: 0] += max(0, now - start)
        }
        phase = next
        phaseStartedAt = now
    }
    public func phaseSeconds(at now: TimeInterval) -> [String: TimeInterval] {
        var result = accumulatedPhaseSeconds
        if let start = phaseStartedAt {
            result[phase, default: 0] += max(0, (finishedAt ?? now) - start)
        }
        return Dictionary(uniqueKeysWithValues: Phase.allCases.map { ($0.rawValue, result[$0, default: 0]) })
    }
    public mutating func beginUpload(at now: TimeInterval) {
        guard uploadStartedAt == nil else { return }
        uploadStartedAt = now
    }
    public mutating func endUpload(at now: TimeInterval) {
        if let start = uploadStartedAt { uploadSeconds += max(0, now - start) }
        uploadStartedAt = nil
    }
    public mutating func recordCommittedBytes(_ count: Int64) {
        guard count > 0, count <= Int64.max - confirmedBytes else { return }
        confirmedBytes += count
    }
    public mutating func finish(at now: TimeInterval) {
        endUpload(at: now)
        finishedAt = now
    }
    public func elapsedSeconds(at now: TimeInterval) -> TimeInterval {
        startedAt.map { max(0, (finishedAt ?? now) - $0) } ?? 0
    }
    public func activeUploadSeconds(at now: TimeInterval) -> TimeInterval {
        uploadSeconds + (uploadStartedAt.map { max(0, now - $0) } ?? 0)
    }
    public func uploadBytesPerSecond(at now: TimeInterval) -> Double? {
        let seconds = activeUploadSeconds(at: now)
        guard confirmedBytes > 0, seconds > 0 else { return nil }
        return Double(confirmedBytes) / seconds
    }
}
