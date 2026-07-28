import Foundation
import ImageAllRemoteProtocol

public struct RemoteHostEndpoint: Sendable, Equatable {
    public var baseURL: URL
    public var accessToken: String

    public init(baseURL: URL, accessToken: String) {
        self.baseURL = baseURL
        self.accessToken = accessToken
    }

    public init(
        host: String,
        port: Int,
        accessToken: String,
        usesTLS: Bool = false
    ) throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost: String = {
            if trimmed.contains(":"), !trimmed.hasPrefix("[") {
                return "[\(trimmed)]"
            }
            return trimmed
        }()
        let scheme = usesTLS ? "https" : "http"
        guard var components = URLComponents(string: "\(scheme)://\(normalizedHost)") else {
            throw RemoteAPIError(code: .badRequest, message: "invalid host")
        }
        components.port = port
        guard let url = components.url else {
            throw RemoteAPIError(code: .badRequest, message: "invalid host URL")
        }
        self.baseURL = url
        self.accessToken = accessToken
    }

    public var usesTLS: Bool {
        baseURL.scheme?.lowercased() == "https"
    }
}

public protocol RemoteHTTPTransporting: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionRemoteHTTPTransport: RemoteHTTPTransporting {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

public struct RemoteLibraryClient: Sendable {
    private let endpoint: RemoteHostEndpoint
    private let transport: any RemoteHTTPTransporting
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let sendAuthorization: Bool

    public init(
        endpoint: RemoteHostEndpoint,
        transport: any RemoteHTTPTransporting = URLSessionRemoteHTTPTransport(),
        sendAuthorization: Bool = true
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        self.sendAuthorization = sendAuthorization
    }

    public static func pinned(
        host: String,
        port: Int,
        accessToken: String,
        certificateFingerprintSHA256: String
    ) throws -> RemoteLibraryClient {
        let endpoint = try RemoteHostEndpoint(
            host: host,
            port: port,
            accessToken: accessToken,
            usesTLS: true
        )
        let session = RemotePinnedURLSessionFactory.makeSession(
            certificateFingerprintSHA256: certificateFingerprintSHA256
        )
        return RemoteLibraryClient(
            endpoint: endpoint,
            transport: URLSessionRemoteHTTPTransport(session: session)
        )
    }

    public func fetchCapabilities() async throws -> RemoteCapabilities {
        try await getJSON(path: RemoteHTTPPaths.capabilities)
    }

    public func fetchSources() async throws -> [RemoteSourceSummary] {
        try await getJSON(path: RemoteHTTPPaths.sources)
    }

    public func fetchTags() async throws -> [RemoteTagSummary] {
        try await getJSON(path: RemoteHTTPPaths.tags)
    }

    public func fetchAssets(_ request: RemoteAssetPageRequest) async throws -> RemoteAssetPage {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "sort", value: request.sort.rawValue),
            URLQueryItem(name: "limit", value: String(request.limit)),
        ]
        if !request.sourceIDs.isEmpty {
            items.append(
                URLQueryItem(
                    name: "sourceIDs",
                    value: request.sourceIDs.map(\.uuidString).joined(separator: ",")
                )
            )
        }
        if let searchText = request.searchText, !searchText.isEmpty {
            items.append(URLQueryItem(name: "q", value: searchText))
        }
        if let cursor = request.cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await getJSON(path: RemoteHTTPPaths.assets, queryItems: items)
    }

    public func fetchAssetDetail(assetID: UUID) async throws -> RemoteAssetDetail {
        try await getJSON(path: RemoteHTTPPaths.assetDetail(assetID: assetID))
    }

    public func loadThumbnail(assetID: UUID, targetPixelWidth: Int = 320) async throws -> Data {
        try await loadBinary(
            path: RemoteHTTPPaths.thumbnail(assetID: assetID),
            queryItems: [URLQueryItem(name: "w", value: String(targetPixelWidth))]
        )
    }

    public func loadPreview(assetID: UUID, targetPixelWidth: Int = 1280) async throws -> Data {
        try await loadBinary(
            path: RemoteHTTPPaths.preview(assetID: assetID),
            queryItems: [URLQueryItem(name: "w", value: String(targetPixelWidth))]
        )
    }

    public func fetchTagSelection(
        _ request: RemoteTagSelectionRequest
    ) async throws -> [RemoteTagSelectionAggregate] {
        let body = try encoder.encode(request)
        return try await postJSON(path: RemoteHTTPPaths.tagSelection, body: body)
    }

    public func applyTagDecision(
        _ request: RemoteBatchTagDecisionRequest
    ) async throws -> RemoteBatchTagDecisionResponse {
        let body = try encoder.encode(request)
        return try await postJSON(path: RemoteHTTPPaths.tagDecisionsBatch, body: body)
    }

    public func fetchReviewQueue(
        _ request: RemoteReviewQueueRequest
    ) async throws -> RemoteReviewQueuePage {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "tagID", value: request.tagID.uuidString),
            URLQueryItem(name: "limit", value: String(request.limit)),
        ]
        if !request.sourceIDs.isEmpty {
            items.append(
                URLQueryItem(
                    name: "sourceIDs",
                    value: request.sourceIDs.map(\.uuidString).joined(separator: ",")
                )
            )
        }
        if let cursor = request.cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await getJSON(path: RemoteHTTPPaths.reviewQueue, queryItems: items)
    }

    public func applyReviewDecision(
        _ request: RemoteBatchReviewDecisionRequest
    ) async throws -> RemoteBatchReviewDecisionResponse {
        let body = try encoder.encode(request)
        return try await postJSON(path: RemoteHTTPPaths.reviewDecisionsBatch, body: body)
    }

    public func fetchJobs() async throws -> [RemoteJobSummary] {
        try await getJSON(path: RemoteHTTPPaths.jobs)
    }

    public func applyJobAction(jobID: UUID, action: RemoteJobAction) async throws {
        let body = try encoder.encode(RemoteJobActionRequest(action: action))
        var request = try makeRequest(path: RemoteHTTPPaths.jobAction(jobID: jobID), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await transport.data(for: request)
        try Self.validate(response: response, data: data)
    }

    public func completePairing(
        _ request: RemotePairingCompleteRequest
    ) async throws -> RemoteSessionTokens {
        let body = try encoder.encode(request)
        return try await RemoteLibraryClient(
            endpoint: RemoteHostEndpoint(baseURL: endpoint.baseURL, accessToken: ""),
            transport: transport,
            sendAuthorization: false
        ).postJSON(path: RemoteHTTPPaths.pairingComplete, body: body)
    }

    public func refreshSession(
        _ request: RemoteTokenRefreshRequest
    ) async throws -> RemoteSessionTokens {
        let body = try encoder.encode(request)
        return try await RemoteLibraryClient(
            endpoint: RemoteHostEndpoint(baseURL: endpoint.baseURL, accessToken: ""),
            transport: transport,
            sendAuthorization: false
        ).postJSON(path: RemoteHTTPPaths.pairingRefresh, body: body)
    }

    private func loadBinary(path: String, queryItems: [URLQueryItem]) async throws -> Data {
        let request = try makeRequest(path: path, method: "GET", queryItems: queryItems)
        let (data, response) = try await transport.data(for: request)
        try Self.validate(response: response, data: data)
        return data
    }

    private func getJSON<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> T {
        let request = try makeRequest(path: path, method: "GET", queryItems: queryItems)
        let (data, response) = try await transport.data(for: request)
        try Self.validate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func postJSON<T: Decodable>(path: String, body: Data) async throws -> T {
        var request = try makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await transport.data(for: request)
        try Self.validate(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func makeRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false) else {
            throw RemoteAPIError(code: .badRequest, message: "invalid base URL")
        }
        let trimmed = path.hasPrefix("/") ? path : "/" + path
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = basePath + trimmed
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw RemoteAPIError(code: .badRequest, message: "invalid request URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        if sendAuthorization, !endpoint.accessToken.isEmpty {
            request.setValue(
                RemoteHTTPHeaders.bearerPrefix + endpoint.accessToken,
                forHTTPHeaderField: RemoteHTTPHeaders.authorization
            )
        }
        return request
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RemoteAPIError(code: .internalError, message: "invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder().decode(RemoteAPIError.self, from: data) {
                throw apiError
            }
            throw RemoteAPIError(
                code: .internalError,
                message: "HTTP \(http.statusCode)"
            )
        }
    }
}
