import Foundation
import ImageAllRemoteProtocol
import Network
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

/// Minimal HTTP/1.1 listener for the auxiliary iOS companion. Default off.
actor RemoteHTTPServer {
    static let defaultPort: UInt16 = 8787
    static let maximumRequestBytes = 256 * 1_024
    static let maximumHeaderBytes = 32 * 1_024
    static let requestTimeout: Duration = .seconds(15)

    private let facade: RemoteCatalogFacade
    private let accessToken: String
    private let port: UInt16
    private let advertisementName: String
    private let logger = Logger(subsystem: "com.gwlee.ImageAll", category: "RemoteHTTPServer")
    private var listener: NWListener?
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    init(
        facade: RemoteCatalogFacade,
        accessToken: String,
        port: UInt16 = RemoteHTTPServer.defaultPort,
        advertisementName: String = RemoteHTTPServer.defaultAdvertisementName()
    ) {
        self.facade = facade
        self.accessToken = accessToken
        self.port = port
        self.advertisementName = advertisementName
    }

    var listenPort: Int { Int(port) }

    /// Exposed for tests: Bonjour service configured on the active listener.
    var bonjourServiceType: String? {
        listener?.service?.type
    }

    func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = Self.makeBonjourService(name: advertisementName)
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection: connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleListenerState(state) }
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
        logger.info(
            "Remote host listening on port \(self.port, privacy: .public); Bonjour \(RemoteBonjour.serviceType, privacy: .public) as \(self.advertisementName, privacy: .public)"
        )
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    static func defaultAdvertisementName() -> String {
        let host = ProcessInfo.processInfo.hostName
        if host.isEmpty { return "ImageAll" }
        return host.replacingOccurrences(of: ".local", with: "")
    }

    static func makeBonjourService(name: String) -> NWListener.Service {
        var txt = NWTXTRecord()
        for (key, value) in RemoteBonjour.txtRecord() {
            txt[key] = value
        }
        return NWListener.Service(
            name: name,
            type: RemoteBonjour.serviceType,
            txtRecord: txt
        )
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
        Task {
            try? await Task.sleep(for: Self.requestTimeout)
            connection.cancel()
        }
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task {
                guard let self else {
                    connection.cancel()
                    return
                }
                if let error {
                    self.logger.error("Remote receive failed: \(String(describing: error), privacy: .public)")
                    connection.cancel()
                    return
                }
                var next = buffer
                if let data, !data.isEmpty {
                    next.append(data)
                }
                switch Self.parseRequest(buffer: next, isComplete: isComplete) {
                case .incomplete:
                    await self.receiveRequest(on: connection, buffer: next)
                case let .rejected(status, apiError):
                    await self.respond(connection, status: status, error: apiError)
                case let .request(request):
                    await self.route(
                        connection: connection,
                        method: request.method,
                        pathAndQuery: request.pathAndQuery,
                        headers: request.headers,
                        body: request.body
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

    private func route(
        connection: NWConnection,
        method: String,
        pathAndQuery: String,
        headers: [String: String],
        body: Data
    ) async {
        guard authorize(headers: headers) else {
            await respond(connection, status: 401, error: .init(code: .unauthorized, message: "invalid or missing bearer token"))
            return
        }

        let (path, query) = Self.splitPathAndQuery(pathAndQuery)
        do {
            switch (method, path) {
            case ("GET", RemoteHTTPPaths.capabilities):
                let payload = await facade.capabilities()
                await respondJSON(connection, status: 200, value: payload)
            case ("GET", RemoteHTTPPaths.sources):
                let payload = try await facade.fetchSources()
                await respondJSON(connection, status: 200, value: payload)
            case ("GET", RemoteHTTPPaths.tags):
                let payload = try await facade.fetchTags()
                await respondJSON(connection, status: 200, value: payload)
            case ("GET", RemoteHTTPPaths.assets):
                let request = Self.parseAssetPageRequest(query: query)
                let payload = try await facade.fetchAssets(request)
                await respondJSON(connection, status: 200, value: payload)
            case ("POST", RemoteHTTPPaths.tagDecisionsBatch):
                let request = try jsonDecoder.decode(RemoteBatchTagDecisionRequest.self, from: body)
                let payload = try await facade.applyTagDecision(request)
                await respondJSON(connection, status: 200, value: payload)
            default:
                if method == "GET", let assetID = Self.thumbnailAssetID(from: path) {
                    let width = Int(query["w"] ?? query["width"] ?? "320") ?? 320
                    let data = try await facade.loadThumbnail(assetID: assetID, targetPixelWidth: width)
                    await respond(
                        connection,
                        status: 200,
                        contentType: "image/jpeg",
                        body: data
                    )
                } else {
                    await respond(connection, status: 404, error: .init(code: .notFound, message: "unknown route"))
                }
            }
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
            await respond(connection, status: status, error: api)
        } catch {
            logger.error("Remote route failed: \(String(describing: error), privacy: .private)")
            await respond(
                connection,
                status: 500,
                error: .init(code: .internalError, message: "internal server error")
            )
        }
    }

    private func authorize(headers: [String: String]) -> Bool {
        guard let value = headers["authorization"] else { return false }
        let prefix = RemoteHTTPHeaders.bearerPrefix
        guard value.hasPrefix(prefix) else { return false }
        let token = String(value.dropFirst(prefix.count))
        return token == accessToken && !accessToken.isEmpty
    }

    private func respondJSON<T: Encodable>(_ connection: NWConnection, status: Int, value: T) async {
        do {
            let data = try jsonEncoder.encode(value)
            await respond(connection, status: status, contentType: "application/json", body: data)
        } catch {
            await respond(
                connection,
                status: 500,
                error: .init(code: .internalError, message: "encode failed")
            )
        }
    }

    private func respond(
        _ connection: NWConnection,
        status: Int,
        error: RemoteAPIError
    ) async {
        let data = (try? jsonEncoder.encode(error)) ?? Data(#"{"code":"internalError","message":"encode"}"#.utf8)
        await respond(connection, status: status, contentType: "application/json", body: data)
    }

    private func respond(
        _ connection: NWConnection,
        status: Int,
        contentType: String,
        body: Data
    ) async {
        let reason: String = {
            switch status {
            case 200: "OK"
            case 400: "Bad Request"
            case 401: "Unauthorized"
            case 404: "Not Found"
            case 409: "Conflict"
            case 413: "Payload Too Large"
            default: "Error"
            }
        }()
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
                continuation.resume()
            })
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
        let sort = RemoteAssetSort(rawValue: query["sort"] ?? "") ?? .newest
        let limit = Int(query["limit"] ?? "60") ?? 60
        return RemoteAssetPageRequest(
            sourceIDs: sourceIDs,
            searchText: query["q"],
            sort: sort,
            limit: limit,
            cursor: query["cursor"]
        )
    }

    private static func thumbnailAssetID(from path: String) -> UUID? {
        // /v1/assets/{uuid}/thumbnail
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 4,
              parts[0] == "v1",
              parts[1] == "assets",
              parts[3] == "thumbnail",
              let id = UUID(uuidString: parts[2])
        else {
            return nil
        }
        return id
    }
}
