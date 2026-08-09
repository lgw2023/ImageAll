import CryptoKit
import Foundation
import ImageIO
import ImageAllRemoteProtocol
import Network
import Security
import UniformTypeIdentifiers
import os

struct RemoteHTTPParsedRequest: Sendable {
    let method: String
    let pathAndQuery: String
    let headers: [String: String]
    let body: Data
}

enum RemoteHTTPRequestParseResult: Sendable {
    case incomplete
    case request(RemoteHTTPParsedRequest)
    case rejected(status: Int, error: RemoteAPIError)
}

struct RemoteHTTPByteRange: Sendable, Equatable {
    let lowerBound: Int64
    let upperBound: Int64

    var count: Int64 {
        guard upperBound >= lowerBound else { return 0 }
        return upperBound - lowerBound + 1
    }
}

enum RemoteHTTPRangeSelection: Sendable, Equatable {
    case full
    case partial(RemoteHTTPByteRange)
    case unsatisfiable
}

/// HTTP/1.1 (+ WebSocket upgrade) listener for the auxiliary iOS companion. Default off;
/// serves TLS when a `SecIdentity` is available, cleartext otherwise (Debug emergency path
/// per ADR-044). Pairing completion/refresh are intentionally reachable without a bearer
/// token; every other route requires either a paired device's access token or the legacy
/// Debug static token.
actor RemoteHTTPServer {
    static let defaultPort: UInt16 = 8787
    static let defaultLocalWebPort: UInt16 = 8788
    static let maximumRequestBytes = 256 * 1_024
    static let maximumHeaderBytes = 32 * 1_024
    static let requestTimeout: Duration = .seconds(15)
    private static let webSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private let facade: RemoteCatalogFacade
    private let pairingStore: RemotePairingStore
    private let accessAccountStore: RemoteAccessAccountStore
    private let eventBroker: RemoteEventBroker
    private let mediaResources: any RemoteMediaResourceProviding
    private let originalAssetOpener: (any LibraryOriginalAssetOpening)?
    private let webAssetStore: RemoteWebCompanionAssetStore
    private let secIdentity: SecIdentity?
    private let port: UInt16
    private let localWebPort: UInt16?
    private let advertisementName: String
    private let hostID: UUID?
    private let logger = Logger(subsystem: "com.gwlee.ImageAll", category: "RemoteHTTPServer")
    private var listener: NWListener?
    private var localWebListener: NWListener?
    private var webSocketConnections: [ObjectIdentifier: NWConnection] = [:]
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    var usesTLS: Bool { secIdentity != nil }

    init(
        facade: RemoteCatalogFacade,
        pairingStore: RemotePairingStore,
        accessAccountStore: RemoteAccessAccountStore,
        eventBroker: RemoteEventBroker,
        mediaResources: any RemoteMediaResourceProviding = UnavailableRemoteMediaResourceProvider(),
        originalAssetOpener: (any LibraryOriginalAssetOpening)? = nil,
        webAssetStore: RemoteWebCompanionAssetStore = RemoteWebCompanionAssetStore(),
        secIdentity: SecIdentity? = nil,
        port: UInt16 = RemoteHTTPServer.defaultPort,
        localWebPort: UInt16? = nil,
        advertisementName: String = RemoteHTTPServer.defaultAdvertisementName(),
        hostID: UUID? = nil
    ) {
        self.facade = facade
        self.pairingStore = pairingStore
        self.accessAccountStore = accessAccountStore
        self.eventBroker = eventBroker
        self.mediaResources = mediaResources
        self.originalAssetOpener = originalAssetOpener
        self.webAssetStore = webAssetStore
        self.secIdentity = secIdentity
        self.port = port
        self.localWebPort = localWebPort
        self.advertisementName = advertisementName
        self.hostID = hostID
    }

    var listenPort: Int { Int(port) }

    /// Exposed for tests: Bonjour service configured on the active listener.
    var bonjourServiceType: String? {
        listener?.service?.type
    }

    func start() throws {
        guard listener == nil else { return }
        let parameters = Self.makeListenerParameters(secIdentity: secIdentity)
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = Self.makeBonjourService(name: advertisementName, hostID: hostID)
        configure(listener)

        let localWebListener: NWListener?
        if let localWebPort {
            let localParameters = Self.makeLoopbackWebListenerParameters(port: localWebPort)
            let createdListener = try NWListener(using: localParameters)
            configure(createdListener)
            localWebListener = createdListener
        } else {
            localWebListener = nil
        }

        listener.start(queue: .global(qos: .utility))
        localWebListener?.start(queue: .global(qos: .utility))
        self.listener = listener
        self.localWebListener = localWebListener
        logger.info(
            "Remote host listening on port \(self.port, privacy: .public) (tls=\(self.usesTLS, privacy: .public)); Bonjour \(RemoteBonjour.serviceType, privacy: .public) as \(self.advertisementName, privacy: .public)"
        )
        if let localWebPort {
            logger.info(
                "Local Web Companion ready at http://127.0.0.1:\(localWebPort, privacy: .public)"
            )
        }
        Task { await eventBroker.startPingLoop() }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        localWebListener?.cancel()
        localWebListener = nil
        for connection in webSocketConnections.values {
            connection.cancel()
        }
        webSocketConnections.removeAll()
        Task { await eventBroker.stopPingLoop() }
    }

    static func defaultAdvertisementName() -> String {
        let host = ProcessInfo.processInfo.hostName
        if host.isEmpty { return "ImageAll" }
        return host.replacingOccurrences(of: ".local", with: "")
    }

    static func makeBonjourService(name: String, hostID: UUID? = nil) -> NWListener.Service {
        var txt = NWTXTRecord()
        for (key, value) in RemoteBonjour.txtRecord(hostID: hostID) {
            txt[key] = value
        }
        return NWListener.Service(
            name: name,
            type: RemoteBonjour.serviceType,
            txtRecord: txt
        )
    }

    private static func makeListenerParameters(secIdentity: SecIdentity?) -> NWParameters {
        guard let secIdentity, let identity = sec_identity_create(secIdentity) else {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            return parameters
        }
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, identity)
        let parameters = NWParameters(tls: tlsOptions, tcp: .init())
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private static func makeLoopbackWebListenerParameters(port: UInt16) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )
        return parameters
    }

    private func configure(_ listener: NWListener) {
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection: connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleListenerState(state) }
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .failed(let error):
            logger.error("Remote host listener failed: \(String(describing: error), privacy: .public)")
        case .cancelled:
            logger.info("Remote host listener cancelled")
        default:
            break
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        let timeoutTask = Task {
            // `try?` alone would swallow `CancellationError` from an *intentional* early
            // `timeoutTask.cancel()` (once the request has already been handled) and fall
            // through to `connection.cancel()` regardless — racing the in-flight response
            // send and intermittently truncating it from the client's perspective. Only the
            // full timeout elapsing (no throw) should cancel the connection here.
            do {
                try await Task.sleep(for: Self.requestTimeout)
            } catch {
                return
            }
            connection.cancel()
        }
        receiveRequest(on: connection, buffer: Data(), timeoutTask: timeoutTask)
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data, timeoutTask: Task<Void, Never>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task {
                guard let self else {
                    connection.cancel()
                    return
                }
                if let error {
                    self.logger.error("Remote receive failed: \(String(describing: error), privacy: .public)")
                    timeoutTask.cancel()
                    connection.cancel()
                    return
                }
                var next = buffer
                if let data, !data.isEmpty {
                    next.append(data)
                }
                switch Self.parseRequest(buffer: next, isComplete: isComplete) {
                case .incomplete:
                    await self.receiveRequest(on: connection, buffer: next, timeoutTask: timeoutTask)
                case let .rejected(status, apiError):
                    timeoutTask.cancel()
                    await self.respond(connection, status: status, error: apiError)
                case let .request(request):
                    await self.route(
                        connection: connection,
                        method: request.method,
                        pathAndQuery: request.pathAndQuery,
                        headers: request.headers,
                        body: request.body,
                        timeoutTask: timeoutTask
                    )
                }
            }
        }
    }

    static func parseRequest(
        buffer: Data,
        isComplete: Bool
    ) -> RemoteHTTPRequestParseResult {
        guard buffer.count <= maximumRequestBytes else {
            return .rejected(
                status: 413,
                error: .init(code: .badRequest, message: "request too large")
            )
        }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > maximumHeaderBytes {
                return .rejected(
                    status: 413,
                    error: .init(code: .badRequest, message: "headers too large")
                )
            }
            return isComplete
                ? .rejected(
                    status: 400,
                    error: .init(code: .badRequest, message: "incomplete headers")
                )
                : .incomplete
        }
        guard headerEnd.upperBound <= maximumHeaderBytes else {
            return .rejected(
                status: 413,
                error: .init(code: .badRequest, message: "headers too large")
            )
        }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .rejected(
                status: 400,
                error: .init(code: .badRequest, message: "invalid headers")
            )
        }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            return .rejected(
                status: 400,
                error: .init(code: .badRequest, message: "missing request line")
            )
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3,
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0"
        else {
            return .rejected(
                status: 400,
                error: .init(code: .badRequest, message: "malformed request line")
            )
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                return .rejected(
                    status: 400,
                    error: .init(code: .badRequest, message: "malformed header")
                )
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, headers[key] == nil else {
                return .rejected(
                    status: 400,
                    error: .init(code: .badRequest, message: "duplicate or empty header")
                )
            }
            headers[key] = value
        }
        guard headers["transfer-encoding"] == nil else {
            return .rejected(
                status: 400,
                error: .init(code: .badRequest, message: "transfer-encoding is unsupported")
            )
        }

        let contentLength: Int
        if let rawLength = headers["content-length"] {
            guard let parsed = Int(rawLength), parsed >= 0 else {
                return .rejected(
                    status: 400,
                    error: .init(code: .badRequest, message: "invalid content-length")
                )
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        let bodyStart = headerEnd.upperBound
        guard contentLength <= maximumRequestBytes - bodyStart else {
            return .rejected(
                status: 413,
                error: .init(code: .badRequest, message: "request too large")
            )
        }
        let availableBodyBytes = buffer.count - bodyStart
        guard availableBodyBytes >= contentLength else {
            return isComplete
                ? .rejected(
                    status: 400,
                    error: .init(code: .badRequest, message: "incomplete body")
                )
                : .incomplete
        }
        guard availableBodyBytes == contentLength else {
            return .rejected(
                status: 400,
                error: .init(code: .badRequest, message: "unexpected trailing bytes")
            )
        }
        let bodyEnd = bodyStart + contentLength
        return .request(
            RemoteHTTPParsedRequest(
                method: String(parts[0]),
                pathAndQuery: String(parts[1]),
                headers: headers,
                body: buffer.subdata(in: bodyStart..<bodyEnd)
            )
        )
    }

    // MARK: - Routing

    private static let unauthenticatedPaths: Set<String> = [
        RemoteHTTPPaths.pairingComplete,
        RemoteHTTPPaths.pairingRefresh,
    ]

    private func route(
        connection: NWConnection,
        method: String,
        pathAndQuery: String,
        headers: [String: String],
        body: Data,
        timeoutTask: Task<Void, Never>
    ) async {
        let (path, query) = Self.splitPathAndQuery(pathAndQuery)

        if method == "GET", RemoteWebCompanionAssetStore.isPublicAssetPath(path) {
            guard let asset = webAssetStore.asset(for: path) else {
                timeoutTask.cancel()
                await respond(
                    connection,
                    status: 404,
                    error: .init(code: .notFound, message: "web companion asset unavailable")
                )
                return
            }
            await respond(
                connection,
                status: 200,
                contentType: asset.contentType,
                body: asset.body,
                timeoutTask: timeoutTask,
                additionalHeaders: asset.allowsSameOriginFraming
                    ? RemoteWebCompanionSession.embeddedWorldMapSecurityHeaders
                    : RemoteWebCompanionSession.browserSecurityHeaders
            )
            return
        }

        if method == "POST", path == RemoteWebCompanionSession.pairingPath {
            guard RemoteWebCompanionSession.isTrustedSameOrigin(headers: headers) else {
                await respond(
                    connection,
                    status: 403,
                    error: .init(code: .unauthorized, message: "untrusted browser origin"),
                    timeoutTask: timeoutTask
                )
                return
            }
            do {
                let request = try jsonDecoder.decode(
                    RemoteWebCompanionSession.PairingRequest.self,
                    from: body
                )
                let deviceName = request.deviceName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !deviceName.isEmpty,
                      deviceName.count <= 80,
                      request.pairingToken.count <= 512,
                      request.clientID.count >= 8,
                      request.clientID.count <= 256
                else {
                    throw RemoteAPIError(
                        code: .badRequest,
                        message: "invalid browser pairing request"
                    )
                }
                let tokens = try await pairingStore.completePairing(
                    RemotePairingCompleteRequest(
                        pairingToken: request.pairingToken,
                        deviceName: deviceName,
                        devicePublicKeySPKI_SHA256: RemoteWebCompanionSession.fingerprint(
                            for: request.clientID
                        )
                    )
                )
                await respondJSON(
                    connection,
                    status: 200,
                    value: RemoteWebCompanionSession.StatusResponse(
                        authenticated: true,
                        deviceID: tokens.deviceID
                    ),
                    timeoutTask: timeoutTask,
                    additionalHeaders: RemoteWebCompanionSession.sessionCookieHeaders(
                        tokens: tokens
                    )
                )
            } catch is DecodingError {
                await respond(
                    connection,
                    status: 400,
                    error: .init(code: .badRequest, message: "malformed request body"),
                    timeoutTask: timeoutTask
                )
            } catch let pairingError as RemotePairingStore.PairingError {
                await respond(
                    connection,
                    status: 400,
                    error: .init(
                        code: .badRequest,
                        message: String(describing: pairingError)
                    ),
                    timeoutTask: timeoutTask
                )
            } catch let api as RemoteAPIError {
                await respond(
                    connection,
                    status: 400,
                    error: api,
                    timeoutTask: timeoutTask
                )
            } catch {
                logger.error(
                    "Web pairing failed: \(String(describing: error), privacy: .private)"
                )
                await respond(
                    connection,
                    status: 500,
                    error: .init(code: .internalError, message: "internal server error"),
                    timeoutTask: timeoutTask
                )
            }
            return
        }

        if method == "POST", path == RemoteWebCompanionSession.accountLoginPath {
            guard RemoteWebCompanionSession.isTrustedSameOrigin(headers: headers) else {
                await respond(
                    connection,
                    status: 403,
                    error: .init(code: .unauthorized, message: "untrusted browser origin"),
                    timeoutTask: timeoutTask
                )
                return
            }
            guard let credentials = RemoteWebCompanionSession.basicCredentials(headers: headers),
                  await accessAccountStore.authenticate(
                      username: credentials.username,
                      password: credentials.password
                  )
            else {
                await respond(
                    connection,
                    status: 401,
                    error: .init(code: .unauthorized, message: "invalid account credentials"),
                    timeoutTask: timeoutTask
                )
                return
            }
            await respondJSON(
                connection,
                status: 200,
                value: RemoteWebCompanionSession.StatusResponse(
                    authenticated: true,
                    deviceID: nil,
                    authMode: "account",
                    username: credentials.username
                ),
                timeoutTask: timeoutTask
            )
            return
        }

        if method == "POST", path == RemoteWebCompanionSession.refreshPath {
            guard RemoteWebCompanionSession.isTrustedSameOrigin(headers: headers) else {
                await respond(
                    connection,
                    status: 403,
                    error: .init(code: .unauthorized, message: "untrusted browser origin"),
                    timeoutTask: timeoutTask
                )
                return
            }
            do {
                guard let deviceValue = RemoteWebCompanionSession.cookieValue(
                    named: RemoteWebCompanionSession.deviceCookieName,
                    headers: headers
                ),
                let deviceID = UUID(uuidString: deviceValue),
                let refreshToken = RemoteWebCompanionSession.cookieValue(
                    named: RemoteWebCompanionSession.refreshCookieName,
                    headers: headers
                )
                else {
                    throw RemotePairingStore.PairingError.invalidRefreshToken
                }
                let tokens = try await pairingStore.refresh(
                    RemoteTokenRefreshRequest(
                        deviceID: deviceID,
                        refreshToken: refreshToken
                    )
                )
                await respondJSON(
                    connection,
                    status: 200,
                    value: RemoteWebCompanionSession.StatusResponse(
                        authenticated: true,
                        deviceID: tokens.deviceID
                    ),
                    timeoutTask: timeoutTask,
                    additionalHeaders: RemoteWebCompanionSession.sessionCookieHeaders(
                        tokens: tokens
                    )
                )
            } catch {
                await respond(
                    connection,
                    status: 401,
                    error: .init(code: .unauthorized, message: "browser session expired"),
                    timeoutTask: timeoutTask,
                    additionalHeaders: RemoteWebCompanionSession.clearingCookieHeaders
                )
            }
            return
        }

        if method == "POST", path == RemoteWebCompanionSession.logoutPath {
            guard RemoteWebCompanionSession.isTrustedSameOrigin(headers: headers) else {
                await respond(
                    connection,
                    status: 403,
                    error: .init(code: .unauthorized, message: "untrusted browser origin"),
                    timeoutTask: timeoutTask
                )
                return
            }
            await respond(
                connection,
                status: 204,
                contentType: "application/json",
                body: Data(),
                timeoutTask: timeoutTask,
                additionalHeaders: RemoteWebCompanionSession.clearingCookieHeaders
            )
            return
        }

        if method == "GET",
           path == RemoteHTTPPaths.eventsWebSocket,
           Self.isWebSocketUpgrade(headers: headers) {
            guard (await authenticateRequest(headers: headers)).isAuthorized else {
                timeoutTask.cancel()
                await respond(connection, status: 401, error: .init(code: .unauthorized, message: "invalid credentials"))
                return
            }
            guard let secWebSocketKey = headers["sec-websocket-key"] else {
                timeoutTask.cancel()
                await respond(connection, status: 400, error: .init(code: .badRequest, message: "missing Sec-WebSocket-Key"))
                return
            }
            // WebSocket connections are long-lived by design: cancel the generic
            // request-parse timeout before completing the handshake.
            timeoutTask.cancel()
            await upgradeToWebSocket(connection: connection, secWebSocketKey: secWebSocketKey)
            return
        }

        var requestAuthentication = RemoteRequestAuthentication.unauthorized
        if !Self.unauthenticatedPaths.contains(path) {
            requestAuthentication = await authenticateRequest(headers: headers)
            guard requestAuthentication.isAuthorized else {
                timeoutTask.cancel()
                await respond(connection, status: 401, error: .init(code: .unauthorized, message: "invalid credentials"))
                return
            }
            if Self.isMutationMethod(method),
               requestAuthentication.requiresSameOriginMutationCheck,
               !RemoteWebCompanionSession.isTrustedSameOrigin(headers: headers)
            {
                await respond(
                    connection,
                    status: 403,
                    error: .init(code: .unauthorized, message: "untrusted browser origin"),
                    timeoutTask: timeoutTask
                )
                return
            }
        }

        do {
            switch (method, path) {
            case ("GET", RemoteHTTPPaths.capabilities):
                let payload = await facade.capabilities()
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.generalSettings):
                let payload = try await facade.fetchGeneralSettings()
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("PUT", RemoteHTTPPaths.generalSettings):
                let request = try jsonDecoder.decode(
                    RemoteGeneralSettingsUpdateRequest.self,
                    from: body
                )
                let payload = try await facade.updateGeneralSettings(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteWebCompanionSession.statusPath):
                await respondJSON(
                    connection,
                    status: 200,
                    value: RemoteWebCompanionSession.StatusResponse(
                        authenticated: true,
                        deviceID: requestAuthentication.deviceID,
                        authMode: requestAuthentication.authMode,
                        username: requestAuthentication.username
                    ),
                    timeoutTask: timeoutTask
                )
            case ("GET", RemoteHTTPPaths.sources):
                let payload = try await facade.fetchSources()
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.sourceManagement):
                let payload = try await facade.fetchSourceManagement()
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.sourceManagementRequests):
                let request = try jsonDecoder.decode(
                    RemoteSourceManagementSubmitRequest.self,
                    from: body
                )
                let payload = try await facade.submitSourceManagement(request)
                await respondJSON(connection, status: 202, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.storageMaintenance):
                let payload = try await facade.fetchStorageMaintenance()
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.storageMaintenanceRequests):
                let request = try jsonDecoder.decode(
                    RemoteStorageMaintenanceSubmitRequest.self,
                    from: body
                )
                let payload = try await facade.submitStorageMaintenance(request)
                await respondJSON(connection, status: 202, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.tags):
                let payload = try await facade.fetchTags()
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.tagsInstallPresets):
                let request = try jsonDecoder.decode(
                    RemoteInstallPresetTagsRequest.self,
                    from: body
                )
                let payload = try await facade.installPresetTags(request)
                await eventBroker.publish(.init(
                    kind: .tagsChanged,
                    emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                ))
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.tagGroups):
                let payload = try await facade.fetchTagGroups()
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.galleryOverview):
                let payload = try await facade.fetchGalleryOverview()
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.worldMapSnapshot):
                let payload = try await facade.fetchWorldMapSnapshot(
                    bounds: try Self.parseWorldMapBounds(query: query),
                    maximumClusters: Int(query["maximumClusters"] ?? "") ?? 2_000
                )
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.worldMapSelection):
                let request = try jsonDecoder.decode(
                    RemoteWorldMapSelectionRequest.self,
                    from: body
                )
                let payload = try await facade.fetchWorldMapSelection(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.worldMapLocationBackfill):
                let payload = try await facade.fetchWorldMapLocationBackfillSnapshots()
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.worldMapLocationBackfillRequests):
                let request = try jsonDecoder.decode(
                    RemoteWorldMapLocationBackfillCommandRequest.self,
                    from: body
                )
                let payload = try await facade.submitWorldMapLocationBackfillCommand(request)
                await respondJSON(connection, status: 202, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.worldMapPlaceTags):
                let payload = try await facade.fetchWorldMapPlaceTagSnapshot()
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.worldMapPlaceTagRequests):
                let request = try jsonDecoder.decode(
                    RemoteWorldMapPlaceTagCommandRequest.self,
                    from: body
                )
                let payload = try await facade.submitWorldMapPlaceTagCommand(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.tagGroups):
                let request = try jsonDecoder.decode(RemoteCreateTagGroupRequest.self, from: body)
                let payload = try await facade.createTagGroup(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.assets):
                let request = Self.parseAssetPageRequest(query: query)
                let payload = try await facade.fetchAssets(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.favorites):
                let request = try jsonDecoder.decode(
                    RemoteFavoriteMutationRequest.self,
                    from: body
                )
                let payload = try await facade.setFavorite(request)
                await eventBroker.publish(.init(
                    kind: .assetsChanged,
                    emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                ))
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.favoriteSyncRetry):
                let request = try jsonDecoder.decode(
                    RemoteFavoriteSyncRetryRequest.self,
                    from: body
                )
                let payload = try await facade.retryFavoriteSync(request)
                await eventBroker.publish(.init(
                    kind: .assetsChanged,
                    emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                ))
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.tagDecisionsBatch):
                let request = try jsonDecoder.decode(RemoteBatchTagDecisionRequest.self, from: body)
                let payload = try await facade.applyTagDecision(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.tagDecisionsUndo):
                let request = try jsonDecoder.decode(RemoteUndoTagDecisionRequest.self, from: body)
                let payload = try await facade.undoTagDecision(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.tagsCreateAndApply):
                let request = try jsonDecoder.decode(RemoteCreateTagAndApplyRequest.self, from: body)
                let payload = try await facade.createTagAndApply(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.tagSelection):
                let request = try jsonDecoder.decode(RemoteTagSelectionRequest.self, from: body)
                let payload = try await facade.selectionAggregate(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.reviewQueue):
                let request = try Self.parseReviewQueueRequest(query: query)
                let payload = try await facade.fetchReviewQueue(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.reviewOverview):
                let mediaKind = RemoteAssetMediaKind(rawValue: query["mediaKind"] ?? "") ?? .image
                let sourceIDs = (query["sourceIDs"] ?? "")
                    .split(separator: ",")
                    .compactMap { UUID(uuidString: String($0)) }
                let payload = try await facade.fetchReviewOverview(
                    mediaKind: mediaKind,
                    sourceIDs: sourceIDs
                )
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.librarySuggestions):
                let mediaKind = RemoteAssetMediaKind(rawValue: query["mediaKind"] ?? "") ?? .image
                let refreshServiceHealth = query["refreshServiceHealth"] == "1"
                let payload = try await facade.fetchLibrarySuggestions(
                    mediaKind: mediaKind,
                    refreshServiceHealth: refreshServiceHealth
                )
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.librarySuggestionRequests):
                let request = try jsonDecoder.decode(
                    RemoteLibrarySuggestionRequest.self,
                    from: body
                )
                let payload = try await facade.submitLibrarySuggestions(request)
                await eventBroker.publish(.init(
                    kind: .jobsChanged,
                    emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                ))
                await respondJSON(connection, status: 202, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.reviewDecisionsBatch):
                let request = try jsonDecoder.decode(RemoteBatchReviewDecisionRequest.self, from: body)
                let payload = try await facade.applyReviewDecision(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.reviewDecisionsUndo):
                let request = try jsonDecoder.decode(RemoteUndoReviewDecisionRequest.self, from: body)
                let payload = try await facade.undoReviewDecision(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.trainingWorkspace):
                let mediaKind = RemoteAssetMediaKind(rawValue: query["mediaKind"] ?? "") ?? .image
                let method = query["method"].flatMap(RemoteTrainingRunMethod.init(rawValue:))
                let payload = try await facade.fetchTrainingWorkspace(
                    mediaKind: mediaKind,
                    method: method
                )
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.trainingSetup):
                let mediaKind = RemoteAssetMediaKind(rawValue: query["mediaKind"] ?? "") ?? .image
                let payload = try await facade.fetchTrainingSetup(mediaKind: mediaKind)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.embeddingPreparation):
                let mediaKind = RemoteAssetMediaKind(rawValue: query["mediaKind"] ?? "") ?? .image
                let payload = try await facade.fetchEmbeddingPreparation(mediaKind: mediaKind)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.embeddingPreparationRequests):
                let request = try jsonDecoder.decode(
                    RemoteEmbeddingPreparationRequest.self,
                    from: body
                )
                let payload = try await facade.submitEmbeddingPreparation(request)
                await eventBroker.publish(.init(
                    kind: .jobsChanged,
                    emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                ))
                await respondJSON(connection, status: 202, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.sampleSuggestions):
                let mediaKind = RemoteAssetMediaKind(rawValue: query["mediaKind"] ?? "") ?? .image
                let payload = try await facade.fetchSampleSuggestions(mediaKind: mediaKind)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.sampleSuggestionRequests):
                let request = try jsonDecoder.decode(
                    RemoteSampleSuggestionRequest.self,
                    from: body
                )
                let payload = try await facade.submitSampleSuggestions(request)
                await eventBroker.publish(.init(
                    kind: .jobsChanged,
                    emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                ))
                await respondJSON(connection, status: 202, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.tagLibrarySuggestions):
                let mediaKind = RemoteAssetMediaKind(rawValue: query["mediaKind"] ?? "") ?? .image
                let payload = try await facade.fetchTagLibrarySuggestions(mediaKind: mediaKind)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.tagLibrarySuggestionRequests):
                let request = try jsonDecoder.decode(
                    RemoteTagLibrarySuggestionRequest.self,
                    from: body
                )
                let payload = try await facade.submitTagLibrarySuggestions(request)
                await eventBroker.publish(.init(
                    kind: .jobsChanged,
                    emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                ))
                await respondJSON(connection, status: 202, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.librarySlimmingWorkspace):
                let mediaKind = RemoteAssetMediaKind(rawValue: query["mediaKind"] ?? "") ?? .image
                let payload = try await facade.fetchLibrarySlimmingWorkspace(
                    mediaKind: mediaKind,
                    jobID: query["jobID"].flatMap(UUID.init(uuidString:)),
                    clusterID: query["clusterID"].flatMap(UUID.init(uuidString:)),
                    clusterScope: RemoteLibrarySlimmingClusterScope(
                        rawValue: query["clusterScope"] ?? ""
                    ) ?? .pending,
                    jobLimit: Int(query["jobLimit"] ?? "") ?? 100,
                    clusterLimit: Int(query["clusterLimit"] ?? "") ?? 80,
                    memberLimit: Int(query["memberLimit"] ?? "") ?? 200
                )
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.librarySlimmingClusterReview):
                let request = try jsonDecoder.decode(
                    RemoteLibrarySlimmingClusterReviewRequest.self,
                    from: body
                )
                let payload = try await facade.updateLibrarySlimmingClusterReview(request)
                await eventBroker.publish(.init(
                    kind: .jobsChanged,
                    emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                ))
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.librarySlimmingSetup):
                let mediaKind = RemoteAssetMediaKind(rawValue: query["mediaKind"] ?? "") ?? .image
                let payload = try await facade.fetchLibrarySlimmingSetup(mediaKind: mediaKind)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.librarySlimmingLaunch):
                let request = try jsonDecoder.decode(
                    RemoteLibrarySlimmingLaunchRequest.self,
                    from: body
                )
                let payload = try await facade.launchLibrarySlimming(request)
                await eventBroker.publish(.init(
                    kind: .jobsChanged,
                    emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                ))
                await respondJSON(connection, status: 202, value: payload, timeoutTask: timeoutTask)
            case ("PUT", RemoteHTTPPaths.librarySlimmingThresholds):
                let request = try jsonDecoder.decode(
                    RemoteLibrarySlimmingThresholdUpdateRequest.self,
                    from: body
                )
                let payload = try await facade.updateLibrarySlimmingThresholds(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.librarySlimmingRecycle):
                let mediaKind = RemoteAssetMediaKind(rawValue: query["mediaKind"] ?? "") ?? .image
                let payload = try await facade.fetchLibrarySlimmingRecycle(
                    mediaKind: mediaKind,
                    sourceID: query["sourceID"].flatMap(UUID.init(uuidString:)),
                    searchText: query["search"],
                    scope: RemoteLibrarySlimmingRecycleScope(
                        rawValue: query["scope"] ?? ""
                    ) ?? .all,
                    limit: Int(query["limit"] ?? "") ?? 60
                )
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.librarySlimmingRecycleRequests):
                let request = try jsonDecoder.decode(
                    RemoteLibrarySlimmingRecycleSubmitRequest.self,
                    from: body
                )
                let payload = try await facade.submitLibrarySlimmingRecycle(request)
                await eventBroker.publish(.init(
                    kind: .assetsChanged,
                    emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                ))
                await respondJSON(connection, status: 202, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.librarySlimmingRemovals):
                let mediaKind = RemoteAssetMediaKind(rawValue: query["mediaKind"] ?? "") ?? .image
                let payload = try await facade.fetchLibrarySlimmingRemovals(mediaKind: mediaKind)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.librarySlimmingRemovals):
                let request = try jsonDecoder.decode(
                    RemoteLibrarySlimmingRemovalSubmitRequest.self,
                    from: body
                )
                let payload = try await facade.submitLibrarySlimmingRemoval(request)
                await eventBroker.publish(.init(
                    kind: .assetsChanged,
                    emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                ))
                await respondJSON(connection, status: 202, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.librarySlimmingIdenticalCleanupPlans):
                let request = try jsonDecoder.decode(
                    RemoteLibrarySlimmingIdenticalCleanupPlanRequest.self,
                    from: body
                )
                let payload = try await facade.prepareLibrarySlimmingIdenticalCleanup(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.librarySlimmingIdenticalCleanupRequests):
                let mediaKind = RemoteAssetMediaKind(rawValue: query["mediaKind"] ?? "") ?? .image
                let payload = try await facade.fetchLibrarySlimmingIdenticalCleanupRequests(
                    mediaKind: mediaKind
                )
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.librarySlimmingIdenticalCleanupRequests):
                let request = try jsonDecoder.decode(
                    RemoteLibrarySlimmingIdenticalCleanupSubmitRequest.self,
                    from: body
                )
                let payload = try await facade.submitLibrarySlimmingIdenticalCleanup(request)
                await eventBroker.publish(.init(
                    kind: .assetsChanged,
                    emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                ))
                await respondJSON(connection, status: 202, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.trainingLaunch):
                let request = try jsonDecoder.decode(RemoteTrainingLaunchRequest.self, from: body)
                let payload = try await facade.launchTraining(request)
                await eventBroker.publish(.init(
                    kind: .jobsChanged,
                    emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                ))
                await respondJSON(connection, status: 202, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.jobs):
                let payload = try await facade.fetchJobActivity()
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.pairingOffer):
                if let offer = await pairingStore.currentOffer() {
                    await respondJSON(connection, status: 200, value: offer, timeoutTask: timeoutTask)
                } else {
                    await respond(connection, status: 404, error: .init(code: .notFound, message: "no active pairing offer"), timeoutTask: timeoutTask)
                }
            case ("POST", RemoteHTTPPaths.pairingComplete):
                let request = try jsonDecoder.decode(RemotePairingCompleteRequest.self, from: body)
                let payload = try await pairingStore.completePairing(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.pairingRefresh):
                let request = try jsonDecoder.decode(RemoteTokenRefreshRequest.self, from: body)
                let payload = try await pairingStore.refresh(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.pairingDevices):
                let payload = await pairingStore.listDevices()
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            default:
                if ["GET", "HEAD"].contains(method), let assetID = Self.mediaAssetID(from: path) {
                    let resource = try await mediaResources.openMediaResource(assetID: assetID)
                    await respondMedia(
                        connection,
                        method: method,
                        resource: resource,
                        rangeHeader: headers["range"],
                        timeoutTask: timeoutTask
                    )
                } else if method == "GET", let assetID = Self.thumbnailAssetID(from: path) {
                    let width = Int(query["w"] ?? query["width"] ?? "320") ?? 320
                    let data = try await facade.loadThumbnail(assetID: assetID, targetPixelWidth: width)
                    let image = try Self.browserImageResponse(data)
                    await respond(connection, status: 200, contentType: image.contentType, body: image.body, timeoutTask: timeoutTask)
                } else if method == "GET", let assetID = Self.previewAssetID(from: path) {
                    let data = try await facade.loadPreview(assetID: assetID)
                    let image = try Self.browserImageResponse(data)
                    await respond(connection, status: 200, contentType: image.contentType, body: image.body, timeoutTask: timeoutTask)
                } else if method == "POST", let assetID = Self.cloudPreviewAssetID(from: path) {
                    let data = try await facade.downloadCloudPreview(assetID: assetID)
                    let image = try Self.browserImageResponse(data)
                    await respond(
                        connection,
                        status: 200,
                        contentType: image.contentType,
                        body: image.body,
                        timeoutTask: timeoutTask
                    )
                } else if method == "GET", let assetID = Self.assetDetailID(from: path) {
                    let payload = try await facade.fetchInspectorDetail(assetID: assetID)
                    await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
                } else if method == "POST", let assetID = Self.assetOpenOriginalID(from: path) {
                    guard let originalAssetOpener else {
                        throw RemoteAPIError(
                            code: .notFound,
                            message: "original asset opener unavailable"
                        )
                    }
                    do {
                        try await originalAssetOpener.openOriginalAsset(assetID: assetID)
                    } catch let openError as LibraryOriginalAssetOpenError {
                        let message = switch openError {
                        case .unavailable: "original asset unavailable"
                        case .unsafeLocator: "original asset location is unsafe"
                        case .previewUnavailable: "original asset viewer unavailable"
                        }
                        throw RemoteAPIError(code: .notFound, message: message)
                    }
                    await respond(
                        connection,
                        status: 204,
                        contentType: "application/json",
                        body: Data(),
                        timeoutTask: timeoutTask
                    )
                } else if method == "POST", let operationID = Self.trainingActivityActionID(from: path) {
                    let request = try jsonDecoder.decode(
                        RemoteTrainingActivityActionRequest.self,
                        from: body
                    )
                    let payload = try await facade.applyTrainingActivityAction(
                        operationID: operationID,
                        request: request
                    )
                    await eventBroker.publish(.init(
                        kind: .jobsChanged,
                        emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                    ))
                    await respondJSON(
                        connection,
                        status: 200,
                        value: payload,
                        timeoutTask: timeoutTask
                    )
                } else if method == "POST",
                          let operationID = Self.embeddingPreparationActionID(from: path)
                {
                    let request = try jsonDecoder.decode(
                        RemoteEmbeddingPreparationActionRequest.self,
                        from: body
                    )
                    let payload = try await facade.applyEmbeddingPreparationAction(
                        operationID: operationID,
                        request: request
                    )
                    await eventBroker.publish(.init(
                        kind: .jobsChanged,
                        emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                    ))
                    await respondJSON(
                        connection,
                        status: 200,
                        value: payload,
                        timeoutTask: timeoutTask
                    )
                } else if method == "POST",
                          let operationID = Self.sampleSuggestionActionID(from: path)
                {
                    let request = try jsonDecoder.decode(
                        RemoteSampleSuggestionActionRequest.self,
                        from: body
                    )
                    let payload = try await facade.applySampleSuggestionAction(
                        operationID: operationID,
                        request: request
                    )
                    await eventBroker.publish(.init(
                        kind: .jobsChanged,
                        emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                    ))
                    await respondJSON(
                        connection,
                        status: 200,
                        value: payload,
                        timeoutTask: timeoutTask
                    )
                } else if method == "POST",
                          let operationID = Self.tagLibrarySuggestionActionID(from: path)
                {
                    let request = try jsonDecoder.decode(
                        RemoteTagLibrarySuggestionActionRequest.self,
                        from: body
                    )
                    let payload = try await facade.applyTagLibrarySuggestionAction(
                        operationID: operationID,
                        request: request
                    )
                    await eventBroker.publish(.init(
                        kind: .jobsChanged,
                        emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                    ))
                    await respondJSON(
                        connection,
                        status: 200,
                        value: payload,
                        timeoutTask: timeoutTask
                    )
                } else if method == "POST", let jobID = Self.librarySlimmingJobActionID(from: path) {
                    let request = try jsonDecoder.decode(
                        RemoteLibrarySlimmingJobActionRequest.self,
                        from: body
                    )
                    let payload = try await facade.applyLibrarySlimmingJobAction(
                        jobID: jobID,
                        request: request
                    )
                    await eventBroker.publish(.init(
                        kind: .jobsChanged,
                        emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                    ))
                    await respondJSON(
                        connection,
                        status: 200,
                        value: payload,
                        timeoutTask: timeoutTask
                    )
                } else if method == "POST", let jobID = Self.jobActionID(from: path) {
                    let request = try jsonDecoder.decode(RemoteJobActionRequest.self, from: body)
                    try await facade.applyJobActivityAction(jobID: jobID, request: request)
                    await eventBroker.publish(.init(
                        kind: .jobsChanged,
                        emittedAtMs: Int64((Date().timeIntervalSince1970 * 1_000).rounded())
                    ))
                    await respondJSON(connection, status: 200, value: RemoteJobActionAcceptedResponse(jobID: jobID), timeoutTask: timeoutTask)
                } else if method == "POST", let (tagID, action) = Self.tagAction(from: path) {
                    switch action {
                    case "rename":
                        let request = try jsonDecoder.decode(RemoteRenameTagRequest.self, from: body)
                        let payload = try await facade.renameTag(tagID: tagID, request: request)
                        await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
                    case "archive":
                        let request = try jsonDecoder.decode(RemoteArchiveTagRequest.self, from: body)
                        let payload = try await facade.archiveTag(tagID: tagID, request: request)
                        await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
                    case "move":
                        let request = try jsonDecoder.decode(RemoteMoveTagRequest.self, from: body)
                        let payload = try await facade.moveTag(tagID: tagID, request: request)
                        await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
                    default:
                        await respond(connection, status: 404, error: .init(code: .notFound, message: "unknown route"), timeoutTask: timeoutTask)
                    }
                } else if method == "POST", let (groupID, action) = Self.tagGroupAction(from: path) {
                    switch action {
                    case "rename":
                        let request = try jsonDecoder.decode(RemoteRenameTagGroupRequest.self, from: body)
                        let payload = try await facade.renameTagGroup(groupID: groupID, request: request)
                        await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
                    case "delete":
                        let request = try jsonDecoder.decode(RemoteDeleteTagGroupRequest.self, from: body)
                        let payload = try await facade.deleteTagGroup(groupID: groupID, request: request)
                        await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
                    default:
                        await respond(connection, status: 404, error: .init(code: .notFound, message: "unknown route"), timeoutTask: timeoutTask)
                    }
                } else if method == "DELETE", let deviceID = Self.pairingDeviceID(from: path) {
                    await pairingStore.revoke(deviceID: deviceID)
                    await respond(connection, status: 204, contentType: "application/json", body: Data(), timeoutTask: timeoutTask)
                } else {
                    await respond(connection, status: 404, error: .init(code: .notFound, message: "unknown route"), timeoutTask: timeoutTask)
                }
            }
        } catch is DecodingError {
            await respond(connection, status: 400, error: .init(code: .badRequest, message: "malformed request body"), timeoutTask: timeoutTask)
        } catch let pairingError as RemotePairingStore.PairingError {
            let (status, code): (Int, RemoteAPIErrorCode) = {
                switch pairingError {
                case .noActiveOffer, .offerExpired, .invalidToken: (400, .badRequest)
                case .unknownDevice, .invalidRefreshToken: (401, .unauthorized)
                }
            }()
            await respond(connection, status: status, error: .init(code: code, message: String(describing: pairingError)), timeoutTask: timeoutTask)
        } catch let api as RemoteAPIError {
            let status: Int = {
                switch api.code {
                case .unauthorized: 401
                case .notFound: 404
                case .badRequest: 400
                case .conflict: 409
                case .internalError: 500
                }
            }()
            await respond(connection, status: status, error: api, timeoutTask: timeoutTask)
        } catch {
            logger.error("Remote route failed: \(String(describing: error), privacy: .private)")
            await respond(
                connection,
                status: 500,
                error: .init(code: .internalError, message: "internal server error"),
                timeoutTask: timeoutTask
            )
        }
    }

    private func bearerToken(headers: [String: String]) -> String {
        guard let value = headers["authorization"] else { return "" }
        let prefix = RemoteHTTPHeaders.bearerPrefix
        guard value.hasPrefix(prefix) else { return "" }
        return String(value.dropFirst(prefix.count))
    }

    private func authenticationToken(headers: [String: String]) -> String {
        let bearer = bearerToken(headers: headers)
        if !bearer.isEmpty {
            return bearer
        }
        return RemoteWebCompanionSession.cookieValue(
            named: RemoteWebCompanionSession.accessCookieName,
            headers: headers
        ) ?? ""
    }

    private func authenticateRequest(
        headers: [String: String]
    ) async -> RemoteRequestAuthentication {
        let pairingOutcome = await pairingStore.authenticate(
            bearer: authenticationToken(headers: headers)
        )
        switch pairingOutcome {
        case let .device(deviceID):
            return .device(deviceID)
        case .legacyDebugToken:
            return .legacyDebugToken
        case .unauthorized:
            break
        }
        guard let credentials = RemoteWebCompanionSession.basicCredentials(headers: headers),
              await accessAccountStore.authenticate(
                  username: credentials.username,
                  password: credentials.password
              )
        else {
            return .unauthorized
        }
        return .account(credentials.username)
    }

    private static func isMutationMethod(_ method: String) -> Bool {
        ["POST", "PUT", "PATCH", "DELETE"].contains(method)
    }

    // MARK: - WebSocket upgrade

    private static func isWebSocketUpgrade(headers: [String: String]) -> Bool {
        (headers["upgrade"]?.lowercased() == "websocket")
            && (headers["connection"]?.lowercased().contains("upgrade") ?? false)
    }

    /// RFC 6455 §1.3 handshake accept value: base64(SHA-1(key + GUID)).
    static func webSocketAcceptValue(secWebSocketKey: String) -> String {
        let concatenated = secWebSocketKey + webSocketGUID
        let digest = Insecure.SHA1.hash(data: Data(concatenated.utf8))
        return Data(digest).base64EncodedString()
    }

    private func upgradeToWebSocket(connection: NWConnection, secWebSocketKey: String) async {
        let accept = Self.webSocketAcceptValue(secWebSocketKey: secWebSocketKey)
        var header = "HTTP/1.1 101 Switching Protocols\r\n"
        header += "Upgrade: websocket\r\n"
        header += "Connection: Upgrade\r\n"
        header += "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        let handshake = Data(header.utf8)
        let sent = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.send(content: handshake, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
        guard sent else {
            connection.cancel()
            return
        }

        let key = ObjectIdentifier(connection)
        webSocketConnections[key] = connection
        let subscriberID = await eventBroker.subscribe { event in
            guard let data = try? JSONEncoder().encode(event) else { return }
            let text = String(data: data, encoding: .utf8) ?? "{}"
            let frame = Self.encodeWebSocketTextFrame(text)
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
        logger.info("Remote WebSocket client connected (subscriberID=\(subscriberID.uuidString, privacy: .private))")
        watchWebSocketConnection(connection, key: key, subscriberID: subscriberID)
    }

    /// Best-effort connection-close detection: the server does not need to interpret
    /// client-sent WebSocket frames (this channel is server-push only), only notice when
    /// the socket goes away so it can unsubscribe from the broker and stop retaining it.
    private func watchWebSocketConnection(_ connection: NWConnection, key: ObjectIdentifier, subscriberID: RemoteEventBroker.SubscriberID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, isComplete, error in
            Task {
                guard let self else { return }
                if isComplete || error != nil {
                    await self.cleanupWebSocketConnection(key: key, subscriberID: subscriberID)
                    connection.cancel()
                } else {
                    await self.watchWebSocketConnection(connection, key: key, subscriberID: subscriberID)
                }
            }
        }
    }

    private func cleanupWebSocketConnection(key: ObjectIdentifier, subscriberID: RemoteEventBroker.SubscriberID) async {
        webSocketConnections.removeValue(forKey: key)
        await eventBroker.unsubscribe(subscriberID)
    }

    static func encodeWebSocketTextFrame(_ text: String) -> Data {
        var frame = Data()
        let payload = Data(text.utf8)
        frame.append(0x81) // FIN=1, opcode=1 (text)
        switch payload.count {
        case 0...125:
            frame.append(UInt8(payload.count))
        case 126...65535:
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        default:
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((payload.count >> shift) & 0xFF))
            }
        }
        // Server-to-client frames are sent unmasked per RFC 6455 §5.1.
        frame.append(payload)
        return frame
    }

    // MARK: - Response helpers

    private func respondJSON<T: Encodable>(
        _ connection: NWConnection,
        status: Int,
        value: T,
        timeoutTask: Task<Void, Never>,
        additionalHeaders: [(String, String)] = []
    ) async {
        do {
            let data = try jsonEncoder.encode(value)
            await respond(
                connection,
                status: status,
                contentType: "application/json",
                body: data,
                timeoutTask: timeoutTask,
                additionalHeaders: additionalHeaders
            )
        } catch {
            await respond(
                connection,
                status: 500,
                error: .init(code: .internalError, message: "encode failed"),
                timeoutTask: timeoutTask
            )
        }
    }

    private func respond(
        _ connection: NWConnection,
        status: Int,
        error: RemoteAPIError,
        timeoutTask: Task<Void, Never>? = nil,
        additionalHeaders: [(String, String)] = []
    ) async {
        let data = (try? jsonEncoder.encode(error)) ?? Data(#"{"code":"internalError","message":"encode"}"#.utf8)
        await respond(
            connection,
            status: status,
            contentType: "application/json",
            body: data,
            timeoutTask: timeoutTask,
            additionalHeaders: additionalHeaders
        )
    }

    private func respond(
        _ connection: NWConnection,
        status: Int,
        contentType: String,
        body: Data,
        timeoutTask: Task<Void, Never>? = nil,
        additionalHeaders: [(String, String)] = []
    ) async {
        timeoutTask?.cancel()
        let reason: String = {
            switch status {
            case 200: "OK"
            case 202: "Accepted"
            case 204: "No Content"
            case 206: "Partial Content"
            case 400: "Bad Request"
            case 401: "Unauthorized"
            case 403: "Forbidden"
            case 404: "Not Found"
            case 409: "Conflict"
            case 413: "Payload Too Large"
            case 416: "Range Not Satisfiable"
            default: "Error"
            }
        }()
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Pragma: no-cache\r\n"
        for (name, value) in additionalHeaders {
            header += "\(name): \(value)\r\n"
        }
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        // `isComplete: true` with `.finalMessage` performs a graceful TCP half-close (FIN)
        // once the response is flushed, rather than an abrupt reset.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(
                content: payload,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in
                    continuation.resume()
                }
            )
        }
        connection.cancel()
    }

    private func respondMedia(
        _ connection: NWConnection,
        method: String,
        resource: RemoteMediaResource,
        rangeHeader: String?,
        timeoutTask: Task<Void, Never>
    ) async {
        timeoutTask.cancel()
        defer { resource.release() }

        let selectedRange: RemoteHTTPByteRange
        let status: Int
        switch Self.parseByteRange(rangeHeader, contentLength: resource.contentLength) {
        case .full:
            selectedRange = RemoteHTTPByteRange(
                lowerBound: 0,
                upperBound: max(resource.contentLength - 1, -1)
            )
            status = 200
        case let .partial(range):
            selectedRange = range
            status = 206
        case .unsatisfiable:
            await respond(
                connection,
                status: 416,
                contentType: resource.contentType,
                body: Data(),
                additionalHeaders: [
                    ("Accept-Ranges", "bytes"),
                    ("Content-Range", "bytes */\(resource.contentLength)"),
                ]
            )
            return
        }

        let responseLength = selectedRange.count
        var header = "HTTP/1.1 \(status) \(status == 206 ? "Partial Content" : "OK")\r\n"
        header += "Content-Type: \(resource.contentType)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Pragma: no-cache\r\n"
        header += "X-Content-Type-Options: nosniff\r\n"
        if status == 206 {
            header += "Content-Range: bytes \(selectedRange.lowerBound)-\(selectedRange.upperBound)/\(resource.contentLength)\r\n"
        }
        header += "Content-Length: \(responseLength)\r\n"
        header += "Connection: close\r\n\r\n"

        guard await send(connection, content: Data(header.utf8), isFinal: method == "HEAD") else {
            connection.cancel()
            return
        }
        if method == "HEAD" {
            connection.cancel()
            return
        }

        var offset = selectedRange.lowerBound
        var remaining = responseLength
        while remaining > 0 {
            let nextCount = Int(min(remaining, Int64(256 * 1_024)))
            let chunk: Data
            do {
                chunk = try resource.read(offset: offset, count: nextCount)
            } catch {
                connection.cancel()
                return
            }
            guard !chunk.isEmpty else {
                connection.cancel()
                return
            }
            remaining -= Int64(chunk.count)
            offset += Int64(chunk.count)
            guard await send(connection, content: chunk, isFinal: remaining == 0) else {
                connection.cancel()
                return
            }
        }
        connection.cancel()
    }

    private func send(
        _ connection: NWConnection,
        content: Data,
        isFinal: Bool
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.send(
                content: content,
                contentContext: isFinal ? .finalMessage : .defaultMessage,
                // A content context must be completed before `.contentProcessed` fires.
                // Completing `.defaultMessage` does not close TCP; only `.finalMessage`
                // performs the graceful half-close after the final body chunk.
                isComplete: true,
                completion: .contentProcessed { error in
                    continuation.resume(returning: error == nil)
                }
            )
        }
    }

    private static func splitPathAndQuery(_ pathAndQuery: String) -> (String, [String: String]) {
        let pieces = pathAndQuery.split(separator: "?", maxSplits: 1).map(String.init)
        let path = pieces.first ?? "/"
        var query: [String: String] = [:]
        if pieces.count > 1 {
            for pair in pieces[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let key = kv.first else { continue }
                let value = kv.count > 1 ? kv[1].removingPercentEncoding ?? kv[1] : ""
                query[key] = value
            }
        }
        return (path, query)
    }

    private static func parseAssetPageRequest(query: [String: String]) -> RemoteAssetPageRequest {
        let sourceIDs = (query["sourceIDs"] ?? "")
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
        let acceptedTagIDs = (query["acceptedTagIDs"] ?? "")
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
        let rejectedTagIDs = (query["rejectedTagIDs"] ?? "")
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
        let excludedTagIDs = (query["excludedTagIDs"] ?? "")
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
        let sort = RemoteAssetSort(rawValue: query["sort"] ?? "") ?? .fileNameAscending
        let limit = Int(query["limit"] ?? "60") ?? 60
        return RemoteAssetPageRequest(
            sourceIDs: sourceIDs,
            searchText: query["q"],
            sort: sort,
            limit: limit,
            cursor: query["cursor"],
            tagDecisionFilters: acceptedTagIDs.map {
                RemoteAssetTagDecisionFilter(tagID: $0, decision: .accepted)
            } + rejectedTagIDs.map {
                RemoteAssetTagDecisionFilter(tagID: $0, decision: .rejected)
            },
            excludedTagIDs: excludedTagIDs,
            tagMatchMode: RemoteAssetTagMatchMode(rawValue: query["tagMatchMode"] ?? "") ?? .all,
            availabilities: (query["availabilities"] ?? "")
                .split(separator: ",")
                .compactMap { RemoteAssetAvailability(rawValue: String($0)) },
            mediaKinds: (query["mediaKinds"] ?? "")
                .split(separator: ",")
                .compactMap { RemoteAssetMediaKind(rawValue: String($0)) },
            mediaTypes: (query["mediaTypes"] ?? "")
                .split(separator: ",")
                .map(String.init),
            tagPresence: RemoteAssetTagPresence(rawValue: query["tagPresence"] ?? "") ?? .any,
            favorite: RemoteAssetFavoriteFilter(rawValue: query["favorite"] ?? "")
        )
    }

    private static func parseWorldMapBounds(
        query: [String: String]
    ) throws -> RemoteWorldMapBounds? {
        let keys = ["west", "south", "east", "north"]
        let values = keys.compactMap { query[$0] }
        guard !values.isEmpty else { return nil }
        guard values.count == keys.count,
              let west = Double(query["west"] ?? ""), west.isFinite,
              let south = Double(query["south"] ?? ""), south.isFinite,
              let east = Double(query["east"] ?? ""), east.isFinite,
              let north = Double(query["north"] ?? ""), north.isFinite
        else {
            throw RemoteAPIError(code: .badRequest, message: "地图视口参数不完整")
        }
        return RemoteWorldMapBounds(
            west: west,
            south: south,
            east: east,
            north: north
        )
    }

    private static func parseReviewQueueRequest(query: [String: String]) throws -> RemoteReviewQueueRequest {
        guard let tagIDString = query["tagID"], let tagID = UUID(uuidString: tagIDString) else {
            throw RemoteAPIError(code: .badRequest, message: "tagID is required")
        }
        let sourceIDs = (query["sourceIDs"] ?? "")
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
        let limit = Int(query["limit"] ?? "40") ?? 40
        return RemoteReviewQueueRequest(
            tagID: tagID,
            sourceIDs: sourceIDs,
            mediaKind: RemoteAssetMediaKind(rawValue: query["mediaKind"] ?? "") ?? .image,
            limit: limit,
            cursor: query["cursor"]
        )
    }

    private static func browserImageResponse(
        _ sourceBytes: Data
    ) throws -> (contentType: String, body: Data) {
        guard let source = CGImageSourceCreateWithData(sourceBytes as CFData, nil),
              let sourceType = CGImageSourceGetType(source) as String?
        else {
            throw RemoteAPIError(
                code: .internalError,
                message: "image response is not decodable"
            )
        }

        if sourceType == UTType.jpeg.identifier {
            return ("image/jpeg", sourceBytes)
        }
        if sourceType == UTType.png.identifier {
            return ("image/png", sourceBytes)
        }

        let artifact = try DerivedImageRenderer().render(
            sourceBytes: sourceBytes,
            variant: .preview,
            expectedMediaType: sourceType
        )
        switch artifact.storageFormat {
        case .jpeg:
            return ("image/jpeg", artifact.bytes)
        case .png:
            return ("image/png", artifact.bytes)
        }
    }

    private static func thumbnailAssetID(from path: String) -> UUID? {
        // /v1/assets/{uuid}/thumbnail
        pathParameter(path, expectedSegments: ["v1", "assets", nil, "thumbnail"])
    }

    private static func previewAssetID(from path: String) -> UUID? {
        // /v1/assets/{uuid}/preview
        pathParameter(path, expectedSegments: ["v1", "assets", nil, "preview"])
    }

    private static func cloudPreviewAssetID(from path: String) -> UUID? {
        // /v1/assets/{uuid}/cloud-preview
        pathParameter(path, expectedSegments: ["v1", "assets", nil, "cloud-preview"])
    }

    private static func mediaAssetID(from path: String) -> UUID? {
        // /v1/assets/{uuid}/media
        pathParameter(path, expectedSegments: ["v1", "assets", nil, "media"])
    }

    private static func assetOpenOriginalID(from path: String) -> UUID? {
        // /v1/assets/{uuid}/open-original
        pathParameter(path, expectedSegments: ["v1", "assets", nil, "open-original"])
    }

    static func parseByteRange(
        _ header: String?,
        contentLength: Int64
    ) -> RemoteHTTPRangeSelection {
        guard let header else { return .full }
        guard contentLength > 0,
              header.hasPrefix("bytes="),
              !header.contains(",")
        else {
            return .unsatisfiable
        }
        let raw = header.dropFirst("bytes=".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bounds = raw.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return .unsatisfiable }

        if bounds[0].isEmpty {
            guard let suffixLength = Int64(bounds[1]), suffixLength > 0 else {
                return .unsatisfiable
            }
            let length = min(suffixLength, contentLength)
            return .partial(
                RemoteHTTPByteRange(
                    lowerBound: contentLength - length,
                    upperBound: contentLength - 1
                )
            )
        }

        guard let lowerBound = Int64(bounds[0]),
              lowerBound >= 0,
              lowerBound < contentLength
        else {
            return .unsatisfiable
        }
        let upperBound: Int64
        if bounds[1].isEmpty {
            upperBound = contentLength - 1
        } else {
            guard let requestedUpper = Int64(bounds[1]), requestedUpper >= lowerBound else {
                return .unsatisfiable
            }
            upperBound = min(requestedUpper, contentLength - 1)
        }
        return .partial(
            RemoteHTTPByteRange(lowerBound: lowerBound, upperBound: upperBound)
        )
    }

    private static func tagAction(from path: String) -> (UUID, String)? {
        let segments = path.split(separator: "/").map(String.init)
        guard segments.count == 4,
              segments[0] == "v1",
              segments[1] == "tags",
              let tagID = UUID(uuidString: segments[2])
        else {
            return nil
        }
        return (tagID, segments[3])
    }

    private static func tagGroupAction(from path: String) -> (UUID, String)? {
        let segments = path.split(separator: "/").map(String.init)
        guard segments.count == 4,
              segments[0] == "v1",
              segments[1] == "tag-groups",
              let groupID = UUID(uuidString: segments[2])
        else {
            return nil
        }
        return (groupID, segments[3])
    }

    private static func assetDetailID(from path: String) -> UUID? {
        // /v1/assets/{uuid}
        pathParameter(path, expectedSegments: ["v1", "assets", nil])
    }

    private static func jobActionID(from path: String) -> UUID? {
        // /v1/jobs/{uuid}/actions
        pathParameter(path, expectedSegments: ["v1", "jobs", nil, "actions"])
    }

    private static func trainingActivityActionID(from path: String) -> UUID? {
        // /v1/training/activities/{uuid}/actions
        pathParameter(
            path,
            expectedSegments: ["v1", "training", "activities", nil, "actions"]
        )
    }

    private static func embeddingPreparationActionID(from path: String) -> UUID? {
        // /v1/embedding-preparation/requests/{uuid}/actions
        pathParameter(
            path,
            expectedSegments: ["v1", "embedding-preparation", "requests", nil, "actions"]
        )
    }

    private static func sampleSuggestionActionID(from path: String) -> UUID? {
        // /v1/sample-suggestions/requests/{uuid}/actions
        pathParameter(
            path,
            expectedSegments: ["v1", "sample-suggestions", "requests", nil, "actions"]
        )
    }

    private static func tagLibrarySuggestionActionID(from path: String) -> UUID? {
        // /v1/tag-library-suggestions/requests/{uuid}/actions
        pathParameter(
            path,
            expectedSegments: ["v1", "tag-library-suggestions", "requests", nil, "actions"]
        )
    }

    private static func librarySlimmingJobActionID(from path: String) -> UUID? {
        // /v1/library-slimming/jobs/{uuid}/actions
        pathParameter(
            path,
            expectedSegments: ["v1", "library-slimming", "jobs", nil, "actions"]
        )
    }

    private static func pairingDeviceID(from path: String) -> UUID? {
        // /v1/pairing/devices/{uuid}
        pathParameter(path, expectedSegments: ["v1", "pairing", "devices", nil])
    }

    /// Matches `path` against `expectedSegments` (nil marks the UUID slot) and returns
    /// that UUID if every other segment matches exactly.
    private static func pathParameter(_ path: String, expectedSegments: [String?]) -> UUID? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == expectedSegments.count else { return nil }
        var found: UUID?
        for (part, expected) in zip(parts, expectedSegments) {
            if let expected {
                guard part == expected else { return nil }
            } else {
                guard let id = UUID(uuidString: part) else { return nil }
                found = id
            }
        }
        return found
    }
}

private enum RemoteRequestAuthentication {
    case device(UUID)
    case legacyDebugToken
    case account(String)
    case unauthorized

    var isAuthorized: Bool {
        switch self {
        case .device, .legacyDebugToken, .account:
            true
        case .unauthorized:
            false
        }
    }

    var deviceID: UUID? {
        guard case let .device(deviceID) = self else { return nil }
        return deviceID
    }

    var username: String? {
        guard case let .account(username) = self else { return nil }
        return username
    }

    var authMode: String {
        switch self {
        case .device:
            "pairedDevice"
        case .legacyDebugToken:
            "debug"
        case .account:
            "account"
        case .unauthorized:
            "none"
        }
    }

    var requiresSameOriginMutationCheck: Bool {
        switch self {
        case .device:
            true
        case .account:
            true
        case .legacyDebugToken, .unauthorized:
            false
        }
    }
}

/// Minimal ack body for `POST /v1/jobs/{id}/actions`; the client already knows the action
/// it requested, so this only confirms which job it applied to.
private struct RemoteJobActionAcceptedResponse: Codable, Sendable {
    let jobID: UUID
}
