import Foundation

public enum RemoteEventConnectionHealth: Sendable, Equatable {
    case stopped
    case connected
    case reconnecting(attempt: Int)
    case hostOffline(attempt: Int)
}

public struct RemoteEventRetryPlan: Sendable, Equatable {
    public let generation: UInt64
    public let attempt: Int
    public let delaySeconds: UInt64
    public let health: RemoteEventConnectionHealth

    public init(
        generation: UInt64,
        attempt: Int,
        delaySeconds: UInt64,
        health: RemoteEventConnectionHealth
    ) {
        self.generation = generation
        self.attempt = attempt
        self.delaySeconds = delaySeconds
        self.health = health
    }
}

public struct RemoteEventRecoveryStateMachine: Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var health: RemoteEventConnectionHealth = .stopped
    public private(set) var automaticRecoveryEnabled = false

    private var attempt = 0
    private var refreshAttempted = false

    public init() {}

    @discardableResult
    public mutating func beginConnection() -> UInt64 {
        generation &+= 1
        attempt = 0
        refreshAttempted = false
        automaticRecoveryEnabled = true
        health = .reconnecting(attempt: 0)
        return generation
    }

    @discardableResult
    public mutating func markConnected(generation candidate: UInt64) -> Bool {
        guard isCurrent(candidate), automaticRecoveryEnabled else { return false }
        attempt = 0
        health = .connected
        return true
    }

    public mutating func unexpectedDisconnect(
        generation candidate: UInt64
    ) -> RemoteEventRetryPlan? {
        guard isCurrent(candidate), automaticRecoveryEnabled else { return nil }
        return nextRetryPlan()
    }

    public mutating func retryFailed(
        generation candidate: UInt64
    ) -> RemoteEventRetryPlan? {
        guard isCurrent(candidate), automaticRecoveryEnabled else { return nil }
        return nextRetryPlan()
    }

    public mutating func claimRefreshAttempt(
        generation candidate: UInt64
    ) -> Bool {
        guard isCurrent(candidate),
              automaticRecoveryEnabled,
              !refreshAttempted
        else {
            return false
        }
        refreshAttempted = true
        return true
    }

    @discardableResult
    public mutating func suspend() -> UInt64 {
        generation &+= 1
        attempt = max(attempt, 1)
        health = .hostOffline(attempt: attempt)
        return generation
    }

    public mutating func resumeImmediately() -> RemoteEventRetryPlan? {
        guard automaticRecoveryEnabled else { return nil }
        generation &+= 1
        attempt = 1
        refreshAttempted = false
        health = .reconnecting(attempt: attempt)
        return RemoteEventRetryPlan(
            generation: generation,
            attempt: attempt,
            delaySeconds: 0,
            health: health
        )
    }

    @discardableResult
    public mutating func markCredentialsRejected(
        generation candidate: UInt64
    ) -> Bool {
        guard isCurrent(candidate), automaticRecoveryEnabled else { return false }
        health = .hostOffline(attempt: max(attempt, 1))
        return true
    }

    @discardableResult
    public mutating func stop() -> UInt64 {
        generation &+= 1
        attempt = 0
        refreshAttempted = false
        automaticRecoveryEnabled = false
        health = .stopped
        return generation
    }

    public func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation
    }

    private mutating func nextRetryPlan() -> RemoteEventRetryPlan {
        attempt += 1
        let delay = min(UInt64(1) << UInt64(min(attempt - 1, 5)), 30)
        let nextHealth: RemoteEventConnectionHealth = if attempt < 3 {
            .reconnecting(attempt: attempt)
        } else {
            .hostOffline(attempt: attempt)
        }
        health = nextHealth
        return RemoteEventRetryPlan(
            generation: generation,
            attempt: attempt,
            delaySeconds: delay,
            health: nextHealth
        )
    }
}
