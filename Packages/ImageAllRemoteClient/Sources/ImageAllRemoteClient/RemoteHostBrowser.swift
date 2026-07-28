import Foundation
import ImageAllRemoteProtocol
import Network

public struct RemoteDiscoveredHost: Identifiable, Sendable, Equatable, Hashable {
    public var id: String { "\(name).\(domain)#\(host):\(port)" }
    public let name: String
    public let domain: String
    public let host: String
    public let port: Int
    public let protocolVersion: Int?

    public init(
        name: String,
        domain: String,
        host: String,
        port: Int,
        protocolVersion: Int?
    ) {
        self.name = name
        self.domain = domain
        self.host = host
        self.port = port
        self.protocolVersion = protocolVersion
    }
}

/// Browses for ImageAll Mac Host Bonjour services and resolves them to host:port.
public final class RemoteHostBrowser: @unchecked Sendable {
    public typealias UpdateHandler = @Sendable ([RemoteDiscoveredHost]) -> Void

    private let queue = DispatchQueue(label: "com.gwlee.ImageAll.RemoteHostBrowser")
    private let lock = NSLock()
    private var browser: NWBrowser?
    private var hostsByServiceID: [String: RemoteDiscoveredHost] = [:]
    private var pendingResolvers: [String: NWConnection] = [:]
    private var updateHandler: UpdateHandler?

    public init() {}

    public func start(onUpdate: @escaping UpdateHandler) {
        stop()
        lock.lock()
        updateHandler = onUpdate
        lock.unlock()

        let descriptor = NWBrowser.Descriptor.bonjour(type: RemoteBonjour.serviceType, domain: nil)
        let next = NWBrowser(for: descriptor, using: .tcp)
        next.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                self.queue.async {
                    self.publish([])
                }
            }
        }
        next.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.queue.async {
                self.handleBrowseResults(results)
            }
        }
        next.start(queue: queue)
        lock.lock()
        browser = next
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let activeBrowser = browser
        let resolvers = pendingResolvers
        browser = nil
        pendingResolvers = [:]
        hostsByServiceID = [:]
        updateHandler = nil
        lock.unlock()
        activeBrowser?.cancel()
        for (_, connection) in resolvers {
            connection.cancel()
        }
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var seenServiceIDs = Set<String>()
        for result in results {
            guard case let .service(name: name, type: _, domain: domain, interface: _) = result.endpoint else {
                continue
            }
            let serviceID = "\(name).\(domain)"
            seenServiceIDs.insert(serviceID)
            let protocolVersion = RemoteBonjour.protocolVersion(fromTXT: txtDictionary(from: result.metadata))
            resolveIfNeeded(
                serviceID: serviceID,
                name: name,
                domain: domain,
                endpoint: result.endpoint,
                protocolVersion: protocolVersion
            )
        }

        lock.lock()
        let stale = hostsByServiceID.keys.filter { !seenServiceIDs.contains($0) }
        for key in stale {
            hostsByServiceID.removeValue(forKey: key)
            pendingResolvers.removeValue(forKey: key)?.cancel()
        }
        let snapshot = Array(hostsByServiceID.values).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let handler = updateHandler
        lock.unlock()
        handler?(snapshot)
    }

    private func resolveIfNeeded(
        serviceID: String,
        name: String,
        domain: String,
        endpoint: NWEndpoint,
        protocolVersion: Int?
    ) {
        lock.lock()
        if hostsByServiceID[serviceID] != nil || pendingResolvers[serviceID] != nil {
            lock.unlock()
            return
        }
        let connection = NWConnection(to: endpoint, using: .tcp)
        pendingResolvers[serviceID] = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.queue.async {
                    self.finishResolve(
                        serviceID: serviceID,
                        name: name,
                        domain: domain,
                        connection: connection,
                        protocolVersion: protocolVersion
                    )
                }
            case .failed, .cancelled:
                self.queue.async {
                    self.lock.lock()
                    self.pendingResolvers.removeValue(forKey: serviceID)
                    self.lock.unlock()
                    connection.cancel()
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func finishResolve(
        serviceID: String,
        name: String,
        domain: String,
        connection: NWConnection,
        protocolVersion: Int?
    ) {
        defer { connection.cancel() }
        guard let remote = connection.currentPath?.remoteEndpoint,
              case let .hostPort(host, port) = remote
        else {
            lock.lock()
            pendingResolvers.removeValue(forKey: serviceID)
            lock.unlock()
            return
        }
        let hostString: String = {
            switch host {
            case let .ipv4(address):
                return "\(address)"
            case let .ipv6(address):
                return "\(address)"
            case let .name(hostname, _):
                return hostname
            @unknown default:
                return name
            }
        }()
        let discovered = RemoteDiscoveredHost(
            name: name,
            domain: domain,
            host: hostString,
            port: Int(port.rawValue),
            protocolVersion: protocolVersion
        )
        lock.lock()
        pendingResolvers.removeValue(forKey: serviceID)
        hostsByServiceID[serviceID] = discovered
        let snapshot = Array(hostsByServiceID.values).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let handler = updateHandler
        lock.unlock()
        handler?(snapshot)
    }

    private func publish(_ hosts: [RemoteDiscoveredHost]) {
        lock.lock()
        let handler = updateHandler
        lock.unlock()
        handler?(hosts)
    }

    private func txtDictionary(from metadata: NWBrowser.Result.Metadata) -> [String: String] {
        guard case let .bonjour(txt) = metadata else { return [:] }
        return txt.dictionary
    }
}
