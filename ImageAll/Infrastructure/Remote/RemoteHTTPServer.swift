import CryptoKit
import Foundation
import ImageAllRemoteProtocol
import Network
import Security
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

/// HTTP/1.1 (+ WebSocket upgrade) listener for the auxiliary iOS companion. Default off;
/// serves TLS when a `SecIdentity` is available, cleartext otherwise (Debug emergency path
/// per ADR-044). Pairing completion/refresh are intentionally reachable without a bearer
/// token; every other route requires either a paired device's access token or the legacy
/// Debug static token.
actor RemoteHTTPServer {
    static let defaultPort: UInt16 = 8787
    static let maximumRequestBytes = 256 * 1_024
    static let maximumHeaderBytes = 32 * 1_024
    static let requestTimeout: Duration = .seconds(15)
    private static let webSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private let facade: RemoteCatalogFacade
    private let pairingStore: RemotePairingStore
    private let eventBroker: RemoteEventBroker
    private let webAssetStore: RemoteWebCompanionAssetStore
    private let secIdentity: SecIdentity?
    private let port: UInt16
    private let advertisementName: String
    private let hostID: UUID?
    private let logger = Logger(subsystem: "com.gwlee.ImageAll", category: "RemoteHTTPServer")
    private var listener: NWListener?
    private var webSocketConnections: [ObjectIdentifier: NWConnection] = [:]
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    var usesTLS: Bool { secIdentity != nil }

    init(
        facade: RemoteCatalogFacade,
        pairingStore: RemotePairingStore,
        eventBroker: RemoteEventBroker,
        webAssetStore: RemoteWebCompanionAssetStore = RemoteWebCompanionAssetStore(),
        secIdentity: SecIdentity? = nil,
        port: UInt16 = RemoteHTTPServer.defaultPort,
        advertisementName: String = RemoteHTTPServer.defaultAdvertisementName(),
        hostID: UUID? = nil
    ) {
        self.facade = facade
        self.pairingStore = pairingStore
        self.eventBroker = eventBroker
        self.webAssetStore = webAssetStore
        self.secIdentity = secIdentity
        self.port = port
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
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection: connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleListenerState(state) }
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
        logger.info(
            "Remote host listening on port \(self.port, privacy: .public) (tls=\(self.usesTLS, privacy: .public)); Bonjour \(RemoteBonjour.serviceType, privacy: .public) as \(self.advertisementName, privacy: .public)"
        )
        Task { await eventBroker.startPingLoop() }
    }

    func stop() {
        listener?.cancel()
        listener = nil
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
                additionalHeaders: RemoteWebCompanionSession.browserSecurityHeaders
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
            guard (await pairingStore.authenticate(
                bearer: authenticationToken(headers: headers)
            )).isAuthorized else {
                timeoutTask.cancel()
                await respond(connection, status: 401, error: .init(code: .unauthorized, message: "invalid or missing bearer token"))
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

        var authenticatedDeviceID: UUID?
        if !Self.unauthenticatedPaths.contains(path) {
            let outcome = await pairingStore.authenticate(
                bearer: authenticationToken(headers: headers)
            )
            guard outcome.isAuthorized else {
                timeoutTask.cancel()
                await respond(connection, status: 401, error: .init(code: .unauthorized, message: "invalid or missing bearer token"))
                return
            }
            if case let .device(deviceID) = outcome {
                authenticatedDeviceID = deviceID
            }
            if Self.isMutationMethod(method),
               bearerToken(headers: headers).isEmpty,
               RemoteWebCompanionSession.cookieValue(
                   named: RemoteWebCompanionSession.accessCookieName,
                   headers: headers
               ) != nil,
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
            case ("GET", RemoteWebCompanionSession.statusPath):
                await respondJSON(
                    connection,
                    status: 200,
                    value: RemoteWebCompanionSession.StatusResponse(
                        authenticated: true,
                        deviceID: authenticatedDeviceID
                    ),
                    timeoutTask: timeoutTask
                )
            case ("GET", RemoteHTTPPaths.sources):
                let payload = try await facade.fetchSources()
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.tags):
                let payload = try await facade.fetchTags()
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.assets):
                let request = Self.parseAssetPageRequest(query: query)
                let payload = try await facade.fetchAssets(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.tagDecisionsBatch):
                let request = try jsonDecoder.decode(RemoteBatchTagDecisionRequest.self, from: body)
                let payload = try await facade.applyTagDecision(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.tagSelection):
                let request = try jsonDecoder.decode(RemoteTagSelectionRequest.self, from: body)
                let payload = try await facade.selectionAggregate(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("GET", RemoteHTTPPaths.reviewQueue):
                let request = try Self.parseReviewQueueRequest(query: query)
                let payload = try await facade.fetchReviewQueue(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
            case ("POST", RemoteHTTPPaths.reviewDecisionsBatch):
                let request = try jsonDecoder.decode(RemoteBatchReviewDecisionRequest.self, from: body)
                let payload = try await facade.applyReviewDecision(request)
                await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
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
                if method == "GET", let assetID = Self.thumbnailAssetID(from: path) {
                    let width = Int(query["w"] ?? query["width"] ?? "320") ?? 320
                    let data = try await facade.loadThumbnail(assetID: assetID, targetPixelWidth: width)
                    await respond(connection, status: 200, contentType: "image/jpeg", body: data, timeoutTask: timeoutTask)
                } else if method == "GET", let assetID = Self.previewAssetID(from: path) {
                    let data = try await facade.loadPreview(assetID: assetID)
                    await respond(connection, status: 200, contentType: "image/jpeg", body: data, timeoutTask: timeoutTask)
                } else if method == "GET", let assetID = Self.assetDetailID(from: path) {
                    let payload = try await facade.fetchInspectorDetail(assetID: assetID)
                    await respondJSON(connection, status: 200, value: payload, timeoutTask: timeoutTask)
                } else if method == "POST", let jobID = Self.jobActionID(from: path) {
                    let request = try jsonDecoder.decode(RemoteJobActionRequest.self, from: body)
                    try await facade.applyJobActivityAction(jobID: jobID, request: request)
                    await respondJSON(connection, status: 200, value: RemoteJobActionAcceptedResponse(jobID: jobID), timeoutTask: timeoutTask)
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
            case 204: "No Content"
            case 400: "Bad Request"
            case 401: "Unauthorized"
            case 403: "Forbidden"
            case 404: "Not Found"
            case 409: "Conflict"
            case 413: "Payload Too Large"
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
        let sort = RemoteAssetSort(rawValue: query["sort"] ?? "") ?? .newest
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
            tagPresence: RemoteAssetTagPresence(rawValue: query["tagPresence"] ?? "") ?? .any
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
        return RemoteReviewQueueRequest(tagID: tagID, sourceIDs: sourceIDs, limit: limit, cursor: query["cursor"])
    }

    private static func thumbnailAssetID(from path: String) -> UUID? {
        // /v1/assets/{uuid}/thumbnail
        pathParameter(path, expectedSegments: ["v1", "assets", nil, "thumbnail"])
    }

    private static func previewAssetID(from path: String) -> UUID? {
        // /v1/assets/{uuid}/preview
        pathParameter(path, expectedSegments: ["v1", "assets", nil, "preview"])
    }

    private static func assetDetailID(from path: String) -> UUID? {
        // /v1/assets/{uuid}
        pathParameter(path, expectedSegments: ["v1", "assets", nil])
    }

    private static func jobActionID(from path: String) -> UUID? {
        // /v1/jobs/{uuid}/actions
        pathParameter(path, expectedSegments: ["v1", "jobs", nil, "actions"])
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

/// Minimal ack body for `POST /v1/jobs/{id}/actions`; the client already knows the action
/// it requested, so this only confirms which job it applied to.
private struct RemoteJobActionAcceptedResponse: Codable, Sendable {
    let jobID: UUID
}
