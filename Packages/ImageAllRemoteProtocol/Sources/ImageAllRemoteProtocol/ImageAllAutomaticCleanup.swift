import Foundation

/// Persist alongside the phone task. No receipt is cached here: every attempt
/// gets a new nonce and must obtain fresh proof over the original pinned session.
public struct ImageAllAutomaticCleanup: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case pending, running, deferred, complete }
    public enum Reason: String, Codable, Sendable { case connectionUnavailable, busy, interrupted, failed }
    public private(set) var phase: Phase = .pending
    public private(set) var reason: Reason?
    public private(set) var attemptID: UUID?
    public private(set) var attempts = 0
    public private(set) var nextAttemptAtMs: Int64 = 0
    public init() {}

    public mutating func begin(nowMs: Int64, connected: Bool, ready: Bool) -> UUID? {
        guard phase != .complete, phase != .running else { return nil }
        guard connected else { phase = .deferred; reason = .connectionUnavailable; return nil }
        guard ready, nowMs >= nextAttemptAtMs else { return nil }
        attempts = min(attempts + 1, 16)
        let nonce = UUID()
        attemptID = nonce; phase = .running; reason = nil
        nextAttemptAtMs = nowMs + delayMs
        return nonce
    }
    public mutating func deferAttempt(_ nonce: UUID, reason: Reason, nowMs: Int64) {
        guard phase == .running, attemptID == nonce else { return }
        phase = .deferred; self.reason = reason
        nextAttemptAtMs = nowMs + delayMs
        attemptID = nil
    }
    public mutating func complete(_ nonce: UUID) {
        guard phase == .running, attemptID == nonce else { return }
        phase = .complete; reason = nil; attemptID = nil
    }
    public func restored() -> Self {
        var value = self
        if value.phase == .running {
            value.phase = .deferred; value.reason = .interrupted; value.attemptID = nil
        }
        return value
    }
    private var delayMs: Int64 { min(300_000, 30_000 * (1 << min(4, max(0, attempts - 1)))) }
}
