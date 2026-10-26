import Foundation
import Network

/// A bounded reverse TCP bridge. USBMux reaches only the loopback device port.
/// It never touches Photos and forwards encrypted TLS bytes without inspecting
/// requests, credentials, or resources.
@MainActor
public final class ImageAllUSBPhoneTunnel {
    public var onOffer: ((ImageAllUSBHello) -> Void)?
    public var onReady: ((UInt16, RemotePairingOffer) -> Void)?
    public var onClosed: ((String) -> Void)?
    private var deviceListener: NWListener?
    private var localListener: NWListener?
    private var control: NWConnection?
    private var pending: ImageAllUSBHello?
    private var approvedKey: String?
    private var heartbeatResponder: ImageAllUSBHeartbeatResponder?
    private var links: [ObjectIdentifier: NWConnection] = [:]
    private var dataWaiting: [NWConnection] = []
    private var localWaiting: [NWConnection] = []
    private var relays: [UUID: ImageAllUSBStreamRelay] = [:]
    private let ioQueue = DispatchQueue(label: "ImageAll.USB.Phone.IO", qos: .userInitiated)
    private var generation = UUID()
    #if DEBUG
    private var diagnosticTask: Task<Void, Never>?
    #endif
    public init() {}

    public func start() throws {
        guard deviceListener == nil else { return }
        let listener = try Self.loopbackListener(port: .init(rawValue: ImageAllUSBHello.devicePort)!)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor in self?.stop(); self?.onClosed?(error.localizedDescription) }
            }
        }
        deviceListener = listener
        listener.start(queue: ioQueue)
    }

    public func approve() throws {
        guard let pending, let offer = pending.offer, let control else { throw ImageAllUSBError.disconnected }
        _ = try pending.validated()
        let epoch = generation
        let listener = try Self.loopbackListener(port: .any)
        localListener = listener
        approvedKey = pending.sessionKey
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.generation == epoch, self.localWaiting.count < 8 else { connection.cancel(); return }
                self.track(connection); self.localWaiting.append(connection); self.match()
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == epoch else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { return }
                    control.send(content: Data([1]), completion: .contentProcessed { _ in })
                    let responder = ImageAllUSBHeartbeatResponder(control, queue: self.ioQueue) { [weak self] in
                        Task { @MainActor in
                            guard let self, self.generation == epoch else { return }
                            self.closeSession(ImageAllUSBError.disconnected.localizedDescription)
                        }
                    }
                    self.heartbeatResponder = responder
                    responder.start()
                    #if DEBUG
                    self.startDiagnostics(epoch: epoch)
                    #endif
                    self.onReady?(port, offer)
                case .failed(let error): self.closeSession(error.localizedDescription)
                default: break
                }
            }
        }
        listener.start(queue: ioQueue)
    }

    public func reject() { closeSession("已拒绝 USB 连接") }
    public func stop() {
        deviceListener?.cancel(); deviceListener = nil
        closeSession("USB 连接已停止")
    }
    private static func loopbackListener(port: NWEndpoint.Port) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        return try NWListener(using: parameters)
    }
    private func track(_ connection: NWConnection) {
        links[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.remove(connection) } }
        }
        connection.start(queue: ioQueue)
    }
    private func accept(_ connection: NWConnection) {
        guard links.count < 32 else { connection.cancel(); return }
        track(connection)
        let epoch = generation
        Task { @MainActor [weak self] in
            do {
                let prefix = try await Self.receiveExactly(connection, count: 4)
                let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
                guard length > 0, length <= ImageAllUSBHello.maximumHeaderBytes else { throw ImageAllUSBError.invalidHeader }
                let hello = try ImageAllUSBHello.decode(try await Self.receiveExactly(connection, count: length))
                guard let self, self.generation == epoch else { connection.cancel(); return }
                switch hello.role {
                case .control:
                    guard self.control == nil else { throw ImageAllUSBError.unavailable("已有 USB 连接，请先断开。") }
                    self.control = connection; self.pending = hello
                    self.onOffer?(hello)
                    // A request cannot keep the listener occupied indefinitely.
                    Task { @MainActor [weak self] in
                        guard let offer = hello.offer else { return }
                        try? await Task.sleep(for: .seconds(ImageAllUSBHello.approvalTimeoutSeconds(for: offer)))
                        guard let self, self.generation == epoch, self.approvedKey == nil else { return }
                        self.closeSession("USB 确认超时，请从 Mac 重新连接")
                    }
                case .data:
                    guard hello.sessionKey == self.approvedKey, self.dataWaiting.count < 8 else { throw ImageAllUSBError.invalidHeader }
                    self.dataWaiting.append(connection); self.match()
                }
            } catch { self?.remove(connection) }
        }
    }
    private func match() {
        while !dataWaiting.isEmpty, !localWaiting.isEmpty {
            let data = dataWaiting.removeFirst(), local = localWaiting.removeFirst()
            data.send(content: Data([1]), completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if error != nil { self.remove(data); self.remove(local); return }
                    let id = UUID()
                    let relay = ImageAllUSBStreamRelay(data, local, queue: self.ioQueue) { [weak self] in
                        Task { @MainActor in
                            guard let self else { return }
                            self.relays.removeValue(forKey: id)
                            self.remove(data); self.remove(local)
                        }
                    }
                    self.relays[id] = relay
                    relay.start()
                }
            })
        }
    }
    private func remove(_ connection: NWConnection) {
        connection.cancel(); links.removeValue(forKey: ObjectIdentifier(connection))
        dataWaiting.removeAll { $0 === connection }; localWaiting.removeAll { $0 === connection }
    }
    private func closeSession(_ reason: String) {
        #if DEBUG
        diagnosticTask?.cancel(); diagnosticTask = nil
        #endif
        let hadSession = control != nil
        generation = UUID()
        heartbeatResponder?.stop(); heartbeatResponder = nil
        localListener?.cancel(); localListener = nil
        links.values.forEach { $0.cancel() }; links = [:]
        control = nil; pending = nil; approvedKey = nil
        relays.values.forEach { $0.cancel() }; relays = [:]
        dataWaiting = []; localWaiting = []
        if hadSession { onClosed?(reason) }
    }
    #if DEBUG
    /// Aggregate transport state only: no URLs, credentials or photo identifiers.
    private func startDiagnostics(epoch: UUID) {
        diagnosticTask?.cancel()
        diagnosticTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == epoch else { return }
                var snapshots: [ImageAllUSBRelaySnapshot] = []
                for relay in Array(self.relays.values) { snapshots.append(await relay.snapshot()) }
                guard self.generation == epoch else { return }
                let report = ImageAllUSBPhoneSnapshot(atMs: Int64(Date().timeIntervalSince1970 * 1000),
                    trackedConnections: self.links.count, waitingData: self.dataWaiting.count,
                    waitingLocal: self.localWaiting.count, relays: snapshots)
                if let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                    let root = directory.appendingPathComponent("USBTunnelDiagnostics")
                    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    if let bytes = try? JSONEncoder().encode(report) {
                        try? bytes.write(to: root.appendingPathComponent("latest.json"), options: .atomic)
                    }
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    #endif
    private static func receiveExactly(_ connection: NWConnection, count: Int) async throws -> Data {
        var data = Data()
        while data.count < count {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - data.count) { bytes, _, ended, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let bytes, !bytes.isEmpty { continuation.resume(returning: bytes) }
                    else { continuation.resume(throwing: ImageAllUSBError.disconnected) }
                }
            }
            data.append(chunk)
        }
        return data
    }
}

/// Control liveness must not depend on the UI actor: synchronous PhotoKit and
/// catalogue preparation may occupy that actor longer than the Mac's deadline.
/// Only terminal failure crosses back to MainActor, guarded by the session epoch.
private final class ImageAllUSBHeartbeatResponder: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onClosed: @Sendable () -> Void
    private var stopped = false // owned by queue
    init(_ connection: NWConnection, queue: DispatchQueue,
         onClosed: @escaping @Sendable () -> Void) {
        self.connection = connection; self.queue = queue; self.onClosed = onClosed
    }
    func start() { queue.async { self.receive() } }
    func stop() { queue.async { self.stopped = true } }
    private func fail() {
        guard !stopped else { return }
        stopped = true; connection.cancel(); onClosed()
    }
    private func receive() {
        guard !stopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] bytes, _, ended, error in
            guard let self, !self.stopped else { return }
            guard !ended, error == nil, bytes == Data([0x50]) else { self.fail(); return }
            self.connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                guard let self, !self.stopped else { return }
                if error != nil { self.fail() } else { self.receive() }
            })
        }
    }
}

/// Both directions execute on one serial I/O queue. Each pump waits for the
/// previous send to drain, holding at most 256 KiB per direction. UI activity
/// does not schedule every encrypted byte through MainActor. Half-closing one
/// direction still permits the response to drain in the other direction.
private final class ImageAllUSBStreamRelay: @unchecked Sendable {
    private let first: NWConnection
    private let second: NWConnection
    private let queue: DispatchQueue
    private let onClosed: @Sendable () -> Void
    // Accessed exclusively on queue, including start/cancel.
    private var stopped = false
    private var readEnded: Set<ObjectIdentifier> = []
    #if DEBUG
    private let created = ProcessInfo.processInfo.systemUptime
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var receivedBytes = [0, 0]
    private var completedSends = [0, 0]
    func snapshot() async -> ImageAllUSBRelaySnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                let now = ProcessInfo.processInfo.systemUptime
                continuation.resume(returning: .init(ageSeconds: now - self.created,
                    idleSeconds: now - self.lastActivity, receivedBytes: self.receivedBytes,
                    completedSends: self.completedSends, endedDirections: self.readEnded.count))
            }
        }
    }
    #endif
    init(_ first: NWConnection, _ second: NWConnection, queue: DispatchQueue,
         onClosed: @escaping @Sendable () -> Void) {
        self.first = first; self.second = second; self.queue = queue; self.onClosed = onClosed
    }
    func start() { queue.async { self.pump(self.first, to: self.second); self.pump(self.second, to: self.first) } }
    func cancel() { queue.async { self.finish() } }
    private func finish() {
        guard !stopped else { return }
        stopped = true
        first.cancel(); second.cancel()
        onClosed()
    }
    private func pump(_ source: NWConnection, to target: NWConnection) {
        guard !stopped else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1_024) { [weak self] bytes, _, ended, error in
            guard let self, !self.stopped else { return }
            guard error == nil, ended || bytes?.isEmpty == false else { self.finish(); return }
            #if DEBUG
            let direction = source === self.first ? 0 : 1
            self.receivedBytes[direction] += bytes?.count ?? 0
            self.lastActivity = ProcessInfo.processInfo.systemUptime
            #endif
            target.send(content: bytes, contentContext: ended ? .finalMessage : .defaultMessage,
                        isComplete: true, completion: .contentProcessed { [weak self] sendError in
                guard let self, !self.stopped else { return }
                #if DEBUG
                self.completedSends[direction] += 1
                #endif
                if sendError != nil { self.finish() }
                else if ended {
                    self.readEnded.insert(ObjectIdentifier(source))
                    if self.readEnded.contains(ObjectIdentifier(target)) { self.finish() }
                } else { self.pump(source, to: target) }
            })
        }
    }
}
#if DEBUG
private struct ImageAllUSBRelaySnapshot: Codable, Sendable {
    let ageSeconds: Double
    let idleSeconds: Double
    let receivedBytes: [Int]
    let completedSends: [Int]
    let endedDirections: Int
}
private struct ImageAllUSBPhoneSnapshot: Codable {
    let atMs: Int64
    let trackedConnections: Int
    let waitingData: Int
    let waitingLocal: Int
    let relays: [ImageAllUSBRelaySnapshot]
}
#endif
