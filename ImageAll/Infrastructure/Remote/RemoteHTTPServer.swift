import Foundation
import ImageAllRemoteProtocol
import Network
import os

/// Minimal HTTP/1.1 listener for the auxiliary iOS companion. Default off.
actor RemoteHTTPServer {
    static let defaultPort: UInt16 = 8787

    private let facade: RemoteCatalogFacade
    private let accessToken: String
    private let port: UInt16
    private let logger = Logger(subsystem: "com.gwlee.ImageAll", category: "RemoteHTTPServer")
    private var listener: NWListener?
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    init(
        facade: RemoteCatalogFacade,
        accessToken: String,
        port: UInt16 = RemoteHTTPServer.defaultPort
    ) {
        self.facade = facade
        self.accessToken = accessToken
        self.port = port
    }

    var listenPort: Int { Int(port) }

    func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection: connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleListenerState(state) }
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
        logger.info("Remote host listening on port \(self.port, privacy: .public)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
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
                if let headerEnd = next.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = next.subdata(in: next.startIndex..<headerEnd.lowerBound)
                    let bodyStart = headerEnd.upperBound
                    guard let headerText = String(data: headerData, encoding: .utf8) else {
                        await self.respond(connection, status: 400, error: .init(code: .badRequest, message: "invalid headers"))
                        return
                    }
                    let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
                    guard let requestLine = lines.first else {
                        await self.respond(connection, status: 400, error: .init(code: .badRequest, message: "missing request line"))
                        return
                    }
                    let parts = requestLine.split(separator: " ")
                    guard parts.count >= 2 else {
                        await self.respond(connection, status: 400, error: .init(code: .badRequest, message: "malformed request line"))
                        return
                    }
                    let method = String(parts[0])
                    let pathAndQuery = String(parts[1])
                    var headers: [String: String] = [:]
                    for line in lines.dropFirst() {
                        guard let sep = line.firstIndex(of: ":") else { continue }
                        let key = line[..<sep].trimmingCharacters(in: .whitespaces).lowercased()
                        let value = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
                        headers[key] = value
                    }
                    let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                    let body = next.subdata(in: bodyStart..<min(bodyStart + contentLength, next.endIndex))
                    if body.count < contentLength, !isComplete {
                        await self.receiveRequest(on: connection, buffer: next)
                        return
                    }
                    await self.route(
                        connection: connection,
                        method: method,
                        pathAndQuery: pathAndQuery,
                        headers: headers,
                        body: body
                    )
                    return
                }
                if isComplete {
                    connection.cancel()
                    return
                }
                if next.count > 256 * 1024 {
                    await self.respond(connection, status: 413, error: .init(code: .badRequest, message: "request too large"))
                    return
                }
                await self.receiveRequest(on: connection, buffer: next)
            }
        }
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
            await respond(
                connection,
                status: 500,
                error: .init(code: .internalError, message: String(describing: error))
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
