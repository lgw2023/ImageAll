import Foundation
import ImageAllRemoteProtocol

/// Fan-out hub for `RemoteEvent`s to any number of live WebSocket connections. Kept
/// independent of `RemoteHTTPServer`'s connection plumbing so the transport layer only
/// needs to subscribe/unsubscribe and forward whatever the broker publishes.
actor RemoteEventBroker {
    typealias SubscriberID = UUID
    typealias Emit = @Sendable (RemoteEvent) -> Void

    private var subscribers: [SubscriberID: Emit] = [:]
    private var pingTask: Task<Void, Never>?

    /// Registers a subscriber and returns a token to later `unsubscribe`. `emit` may be
    /// called concurrently from the broker's actor context for each published event.
    func subscribe(_ emit: @escaping Emit) -> SubscriberID {
        let id = SubscriberID()
        subscribers[id] = emit
        return id
    }

    func unsubscribe(_ id: SubscriberID) {
        subscribers.removeValue(forKey: id)
    }

    var subscriberCount: Int { subscribers.count }

    func publish(_ event: RemoteEvent) {
        for emit in subscribers.values {
            emit(event)
        }
    }

    /// Convenience for callers that only have the pieces of an event, not a full DTO.
    func publish(
        kind: RemoteEventKind,
        sourceID: UUID? = nil,
        tagID: UUID? = nil,
        jobID: UUID? = nil
    ) {
        publish(
            RemoteEvent(
                kind: kind,
                emittedAtMs: Self.nowMs(),
                sourceID: sourceID,
                tagID: tagID,
                jobID: jobID
            )
        )
    }

    /// Starts a repeating `ping` broadcast so idle WebSocket connections (and any
    /// intermediate NAT/proxy) see periodic traffic. Safe to call repeatedly; restarts
    /// the loop with the latest interval.
    func startPingLoop(interval: Duration = .seconds(20)) {
        stopPingLoop()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.publishPing()
            }
        }
    }

    func stopPingLoop() {
        pingTask?.cancel()
        pingTask = nil
    }

    private func publishPing() {
        publish(kind: .ping)
    }

    private static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}
