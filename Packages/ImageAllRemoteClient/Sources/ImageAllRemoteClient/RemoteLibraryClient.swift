import Foundation
import ImageAllRemoteProtocol

public struct RemoteHostEndpoint: Sendable, Equatable {
    public var baseURL: URL
    public var accessToken: String

    public init(baseURL: URL, accessToken: String) {
        self.baseURL = baseURL
        self.accessToken = accessToken
    }

    public init(host: String, port: Int, accessToken: String) throws {
        guard var components = URLComponents(string: "http://\(host)") else {
            throw RemoteAPIError(code: .badRequest, message: "invalid host")
        }
        components.port = port
        guard let url = components.url else {
            throw RemoteAPIError(code: .badRequest, message: "invalid host URL")
        }
        self.baseURL = url
        self.accessToken = accessToken
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

    public init(
        endpoint: RemoteHostEndpoint,
        transport: any RemoteHTTPTransporting = URLSessionRemoteHTTPTransport()
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
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

    public func loadThumbnail(assetID: UUID, targetPixelWidth: Int = 320) async throws -> Data {
        let path = RemoteHTTPPaths.thumbnail(assetID: assetID)
        let request = try makeRequest(
            path: path,
            method: "GET",
            queryItems: [URLQueryItem(name: "w", value: String(targetPixelWidth))]
        )
        let (data, response) = try await transport.data(for: request)
        try Self.validate(response: response, data: data)
        return data
    }

    public func applyTagDecision(
        _ request: RemoteBatchTagDecisionRequest
    ) async throws -> RemoteBatchTagDecisionResponse {
        let body = try encoder.encode(request)
        return try await postJSON(path: RemoteHTTPPaths.tagDecisionsBatch, body: body)
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
        request.setValue(
            RemoteHTTPHeaders.bearerPrefix + endpoint.accessToken,
            forHTTPHeaderField: RemoteHTTPHeaders.authorization
        )
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
