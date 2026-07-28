import Foundation
import ImageAllRemoteProtocol

public final class RemoteEventSocket: @unchecked Sendable {
    public typealias EventHandler = @Sendable (RemoteEvent) -> Void

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var handler: EventHandler?
    private var isRunning = false

    public init() {}

    public func connect(
        endpoint: RemoteHostEndpoint,
        certificateFingerprintSHA256: String?,
        onEvent: @escaping EventHandler
    ) throws {
        stop()
        let session: URLSession
        if let fingerprint = certificateFingerprintSHA256, endpoint.usesTLS {
            session = RemotePinnedURLSessionFactory.makeSession(
                certificateFingerprintSHA256: fingerprint
            )
        } else {
            session = .shared
        }
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
        let task = session.webSocketTask(with: request)
        lock.lock()
        self.session = session
        self.task = task
        self.handler = onEvent
        self.isRunning = true
        lock.unlock()
        task.resume()
        receiveLoop()
    }

    public func stop() {
        lock.lock()
        isRunning = false
        let active = task
        task = nil
        session = nil
        handler = nil
        lock.unlock()
        active?.cancel(with: .goingAway, reason: nil)
    }

    private func receiveLoop() {
        lock.lock()
        let active = task
        let running = isRunning
        lock.unlock()
        guard running, let active else { return }
        active.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                if case let .string(text) = message,
                   let data = text.data(using: .utf8),
                   let event = try? JSONDecoder().decode(RemoteEvent.self, from: data) {
                    self.lock.lock()
                    let handler = self.handler
                    self.lock.unlock()
                    handler?(event)
                }
                self.receiveLoop()
            case .failure:
                self.stop()
            }
        }
    }
}
