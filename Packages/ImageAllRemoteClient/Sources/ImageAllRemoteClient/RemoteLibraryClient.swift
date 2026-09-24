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

    public init(publicHTTPSBaseURL: String, accessToken: String) throws {
        guard let normalized = RemotePublicEndpoint.normalizedHTTPSBaseURL(
            publicHTTPSBaseURL
        ),
            let url = URL(string: normalized)
        else {
            throw RemoteAPIError(code: .badRequest, message: "invalid public host URL")
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

    public func submitLocalLibrarySnapshot(
        _ request: RemoteLocalLibrarySnapshotRequest
    ) async throws -> RemoteLocalLibrarySnapshotReceipt {
        try await postJSON(
            path: RemoteHTTPPaths.localLibrarySnapshot,
            body: encoder.encode(request)
        )
    }

    public func submitLocalLibraryTagDecision(
        _ request: RemoteLocalLibraryTagDecisionRequest
    ) async throws -> RemoteLocalLibraryTagDecisionReceipt {
        try await postJSON(
            path: RemoteHTTPPaths.localLibraryTagDecision,
            body: encoder.encode(request)
        )
    }

    public func fetchLocalLibraryTagChanges(
        sourceEpoch: UUID, scopeRevision: Int64, afterCursor: Int64
    ) async throws -> RemoteLocalLibraryTagChangesPage {
        try await getJSON(
            path: RemoteHTTPPaths.localLibraryTagChanges,
            queryItems: [
                URLQueryItem(name: "sourceEpoch", value: sourceEpoch.uuidString),
                URLQueryItem(name: "scopeRevision", value: String(scopeRevision)),
                URLQueryItem(name: "afterCursor", value: String(afterCursor))
            ]
        )
    }

    public func fetchSources() async throws -> [RemoteSourceSummary] {
        try await getJSON(path: RemoteHTTPPaths.sources)
    }

    public func fetchTags() async throws -> [RemoteTagSummary] {
        try await getJSON(path: RemoteHTTPPaths.tags)
    }

    public func fetchTagGroups() async throws -> [RemoteTagGroupSummary] {
        try await getJSON(path: RemoteHTTPPaths.tagGroups)
    }

    public func installPresetTags(
        _ request: RemoteInstallPresetTagsRequest
    ) async throws -> RemoteInstallPresetTagsResponse {
        try await postJSON(
            path: RemoteHTTPPaths.tagsInstallPresets,
            body: encoder.encode(request)
        )
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
        let acceptedTagIDs = request.tagDecisionFilters
            .filter { $0.decision == .accepted }
            .map(\.tagID.uuidString)
        if !acceptedTagIDs.isEmpty {
            items.append(URLQueryItem(name: "acceptedTagIDs", value: acceptedTagIDs.joined(separator: ",")))
        }
        let rejectedTagIDs = request.tagDecisionFilters
            .filter { $0.decision == .rejected }
            .map(\.tagID.uuidString)
        if !rejectedTagIDs.isEmpty {
            items.append(URLQueryItem(name: "rejectedTagIDs", value: rejectedTagIDs.joined(separator: ",")))
        }
        if !request.excludedTagIDs.isEmpty {
            items.append(URLQueryItem(
                name: "excludedTagIDs",
                value: request.excludedTagIDs.map(\.uuidString).joined(separator: ",")
            ))
        }
        if !request.tagDecisionFilters.isEmpty
            || !request.excludedTagIDs.isEmpty
            || request.tagMatchMode != .all
        {
            items.append(URLQueryItem(name: "tagMatchMode", value: request.tagMatchMode.rawValue))
        }
        if !request.availabilities.isEmpty {
            items.append(URLQueryItem(
                name: "availabilities",
                value: request.availabilities.map(\.rawValue).joined(separator: ",")
            ))
        }
        if !request.mediaKinds.isEmpty {
            items.append(URLQueryItem(
                name: "mediaKinds",
                value: request.mediaKinds.map(\.rawValue).joined(separator: ",")
            ))
        }
        if !request.mediaTypes.isEmpty {
            items.append(URLQueryItem(name: "mediaTypes", value: request.mediaTypes.joined(separator: ",")))
        }
        if request.tagPresence != .any {
            items.append(URLQueryItem(name: "tagPresence", value: request.tagPresence.rawValue))
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

    /// Downloads the same bounded standard preview exposed by the Mac inspector.
    /// Callers must only invoke this from an explicit user action.
    public func downloadCloudPreview(assetID: UUID) async throws -> Data {
        try await loadBinary(
            path: RemoteHTTPPaths.cloudPreview(assetID: assetID),
            method: "POST"
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

    public func createTagAndApply(
        _ request: RemoteCreateTagAndApplyRequest
    ) async throws -> RemoteCreateTagAndApplyResponse {
        try await postJSON(path: RemoteHTTPPaths.tagsCreateAndApply, body: encoder.encode(request))
    }

    public func undoTagDecision(
        _ request: RemoteUndoTagDecisionRequest
    ) async throws -> RemoteUndoTagDecisionResponse {
        try await postJSON(path: RemoteHTTPPaths.tagDecisionsUndo, body: encoder.encode(request))
    }

    public func renameTag(
        tagID: UUID, request: RemoteRenameTagRequest
    ) async throws -> RemoteTagMutationResponse {
        try await postJSON(path: RemoteHTTPPaths.tagRename(tagID: tagID), body: encoder.encode(request))
    }

    public func archiveTag(
        tagID: UUID, request: RemoteArchiveTagRequest
    ) async throws -> RemoteTagMutationResponse {
        try await postJSON(path: RemoteHTTPPaths.tagArchive(tagID: tagID), body: encoder.encode(request))
    }

    public func moveTag(
        tagID: UUID, request: RemoteMoveTagRequest
    ) async throws -> RemoteTagMutationResponse {
        try await postJSON(path: RemoteHTTPPaths.tagMove(tagID: tagID), body: encoder.encode(request))
    }

    public func createTagGroup(
        _ request: RemoteCreateTagGroupRequest
    ) async throws -> RemoteTagGroupMutationResponse {
        try await postJSON(path: RemoteHTTPPaths.tagGroups, body: encoder.encode(request))
    }

    public func renameTagGroup(
        groupID: UUID, request: RemoteRenameTagGroupRequest
    ) async throws -> RemoteTagGroupMutationResponse {
        try await postJSON(
            path: RemoteHTTPPaths.tagGroupRename(groupID: groupID), body: encoder.encode(request)
        )
    }

    public func deleteTagGroup(
        groupID: UUID, request: RemoteDeleteTagGroupRequest
    ) async throws -> RemoteTagGroupMutationResponse {
        try await postJSON(
            path: RemoteHTTPPaths.tagGroupDelete(groupID: groupID), body: encoder.encode(request)
        )
    }

    public func fetchReviewOverview(
        mediaKind: RemoteAssetMediaKind, sourceIDs: [UUID] = []
    ) async throws -> RemoteReviewOverview {
        var items = [URLQueryItem(name: "mediaKind", value: mediaKind.rawValue)]
        if !sourceIDs.isEmpty {
            items.append(URLQueryItem(
                name: "sourceIDs", value: sourceIDs.map(\.uuidString).joined(separator: ",")
            ))
        }
        return try await getJSON(path: RemoteHTTPPaths.reviewOverview, queryItems: items)
    }

    public func fetchReviewQueue(
        _ request: RemoteReviewQueueRequest
    ) async throws -> RemoteReviewQueuePage {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "tagID", value: request.tagID.uuidString),
            URLQueryItem(name: "mediaKind", value: request.mediaKind.rawValue),
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

    private func loadBinary(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = []
    ) async throws -> Data {
        let request = try makeRequest(path: path, method: method, queryItems: queryItems)
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
