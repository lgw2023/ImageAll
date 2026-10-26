import Foundation
import ImageAllRemoteProtocol

public enum RemoteEventSocketState: Sendable, Equatable {
    case connected
    case disconnected
}

struct RemoteEventSocketLifecycle: Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var isActive = false

    mutating func activate() -> UInt64 {
        generation &+= 1
        isActive = true
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
        isActive = false
    }

    func allows(_ candidate: UInt64) -> Bool {
        isActive && candidate == generation
    }
}

public final class RemoteEventSocket: @unchecked Sendable {
    public typealias EventHandler = @Sendable (RemoteEvent) -> Void
    public typealias StateHandler = @Sendable (RemoteEventSocketState) -> Void

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var handler: EventHandler?
    private var stateHandler: StateHandler?
    private var isRunning = false
    private var hasReportedDisconnect = false
    private var lifecycle = RemoteEventSocketLifecycle()

    public init() {}

    public func connect(
        endpoint: RemoteHostEndpoint,
        certificateFingerprintSHA256: String?,
        onEvent: @escaping EventHandler,
        onStateChange: @escaping StateHandler
    ) throws {
        stop()
        var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)
        components?.path = RemoteHTTPPaths.eventsWebSocket
        if endpoint.usesTLS {
            components?.scheme = "wss"
        } else {
            components?.scheme = "ws"
        }
        guard let url = components?.url else {
            throw RemoteAPIError(code: .badRequest, message: "invalid websocket URL")
        }
        var request = URLRequest(url: url)
        request.setValue(
            RemoteHTTPHeaders.bearerPrefix + endpoint.accessToken,
            forHTTPHeaderField: RemoteHTTPHeaders.authorization
        )
        let normalizedFingerprint: String?
        if let certificateFingerprintSHA256 {
            guard let normalized = RemoteTLSFingerprint.normalizedSHA256(
                certificateFingerprintSHA256
            ) else {
                throw RemoteAPIError(
                    code: .badRequest,
                    message: "invalid certificate fingerprint"
                )
            }
            normalizedFingerprint = normalized
        } else {
            normalizedFingerprint = nil
        }
        let delegate = RemoteEventSocketSessionDelegate(
            expectedFingerprint: endpoint.usesTLS ? normalizedFingerprint : nil
        )
        delegate.owner = self
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        // An event stream is deliberately long-lived. A one-minute resource
        // deadline churns healthy sockets even while keepalive events arrive.
        // Retain Foundation's default; transport failures still trigger recovery.
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        let task = session.webSocketTask(with: request)
        lock.lock()
        self.session = session
        self.task = task
        self.handler = onEvent
        self.stateHandler = onStateChange
        self.isRunning = true
        self.hasReportedDisconnect = false
        let generation = lifecycle.activate()
        lock.unlock()
        task.resume()
        receiveLoop(task: task, generation: generation)
    }

    public func stop() {
        lock.lock()
        isRunning = false
        let active = task
        let activeSession = session
        task = nil
        session = nil
        handler = nil
        stateHandler = nil
        hasReportedDisconnect = false
        lifecycle.invalidate()
        lock.unlock()
        active?.cancel(with: .goingAway, reason: nil)
        activeSession?.invalidateAndCancel()
    }

    private func receiveLoop(
        task expectedTask: URLSessionWebSocketTask,
        generation: UInt64
    ) {
        lock.lock()
        let active = task
        let running = isRunning
        let generationIsCurrent = lifecycle.allows(generation)
        lock.unlock()
        guard running,
              generationIsCurrent,
              let active,
              active === expectedTask
        else {
            return
        }
        active.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                self.lock.lock()
                let isCurrent = self.isRunning
                    && self.lifecycle.allows(generation)
                    && self.task === expectedTask
                let handler = isCurrent ? self.handler : nil
                self.lock.unlock()
                guard isCurrent else { return }
                if case let .string(text) = message,
                   let data = text.data(using: .utf8),
                   let event = try? JSONDecoder().decode(RemoteEvent.self, from: data) {
                    handler?(event)
                }
                self.receiveLoop(task: expectedTask, generation: generation)
            case .failure:
                self.reportDisconnected(task: expectedTask)
            }
        }
    }

    fileprivate func reportConnected(task expectedTask: URLSessionWebSocketTask) {
        lock.lock()
        let callback = isRunning && task === expectedTask ? stateHandler : nil
        lock.unlock()
        callback?(.connected)
    }

    fileprivate func reportDisconnected(task expectedTask: URLSessionWebSocketTask) {
        lock.lock()
        guard isRunning,
              task === expectedTask,
              !hasReportedDisconnect
        else {
            lock.unlock()
            return
        }
        hasReportedDisconnect = true
        isRunning = false
        let callback = stateHandler
        let activeTask = task
        let activeSession = session
        task = nil
        session = nil
        handler = nil
        stateHandler = nil
        lifecycle.invalidate()
        lock.unlock()
        activeTask?.cancel(with: .goingAway, reason: nil)
        activeSession?.invalidateAndCancel()
        callback?(.disconnected)
    }
}

private final class RemoteEventSocketSessionDelegate: NSObject,
    URLSessionDelegate,
    URLSessionWebSocketDelegate,
    @unchecked Sendable
{
    weak var owner: RemoteEventSocket?
    private let expectedFingerprint: String?

    init(expectedFingerprint: String?) {
        self.expectedFingerprint = expectedFingerprint
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let expectedFingerprint else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        RemoteTLSPinning.handle(
            challenge: challenge,
            expectedFingerprint: expectedFingerprint,
            completionHandler: completionHandler
        )
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        owner?.reportConnected(task: webSocketTask)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        owner?.reportDisconnected(task: webSocketTask)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let webSocketTask = task as? URLSessionWebSocketTask else { return }
        owner?.reportDisconnected(task: webSocketTask)
    }
}
