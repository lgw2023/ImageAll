import CryptoKit
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
    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse)
}

public extension RemoteHTTPTransporting {
    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse) {
        let result = try await data(for: request)
        guard result.0.count <= maximumBytes else { throw RemoteVideoError.responseTooLarge }
        return result
    }
}

public struct URLSessionRemoteHTTPTransport: RemoteHTTPTransporting {
    private let session: URLSession

    public init() {
        session = URLSession(
            configuration: .ephemeral,
            delegate: RemoteNoRedirectDelegate(), delegateQueue: nil
        )
    }

    public init(session: URLSession) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    public func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse) {
        let (stream, response) = try await session.bytes(for: request)
        defer { stream.task.cancel() }
        // Error JSON is needed to distinguish recoverable media states. Read it
        // through the same hard byte budget instead of discarding every non-2xx body.
        guard response.expectedContentLength <= maximumBytes else { throw RemoteVideoError.responseTooLarge }
        var data = Data()
        data.reserveCapacity(maximumBytes)
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw RemoteVideoError.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }
}

private final class RemoteNoRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
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

    public func beginMigrationTransfer(
        migrationID: UUID
    ) async throws -> ImageAllMigrationTransferProgress {
        try await postJSON(
            path: RemoteHTTPPaths.migrationTransfer(migrationID), body: Data()
        )
    }

    public func migrationTransferProgress(
        migrationID: UUID
    ) async throws -> ImageAllMigrationTransferProgress {
        try await getJSON(path: RemoteHTTPPaths.migrationTransfer(migrationID))
    }

    public func uploadMigrationChunk(
        migrationID: UUID, relativePath: String, offset: Int64, bytes: Data
    ) async throws -> ImageAllMigrationTransferProgress {
        guard !bytes.isEmpty,
              bytes.count <= ImageAllMigrationTransferStore.defaultMaximumChunkBytes else {
            throw RemoteAPIError(code: .badRequest, message: "invalid migration chunk size")
        }
        var request = try makeRequest(
            path: RemoteHTTPPaths.migrationTransferChunks(migrationID), method: "PUT"
        )
        request.timeoutInterval = 90
        request.setValue(relativePath, forHTTPHeaderField: "X-ImageAll-File")
        request.setValue(String(offset), forHTTPHeaderField: "X-ImageAll-Offset")
        request.setValue(
            Data(SHA256.hash(data: bytes)).map { String(format: "%02x", $0) }.joined(),
            forHTTPHeaderField: "X-ImageAll-SHA256"
        )
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = bytes
        let (data, response) = try await transport.data(for: request)
        try Self.validate(response: response, data: data)
        return try decoder.decode(ImageAllMigrationTransferProgress.self, from: data)
    }

    public func sealMigrationTransfer(
        migrationID: UUID
    ) async throws -> ImageAllMigrationTransferSealReceipt {
        try await postJSON(
            path: RemoteHTTPPaths.migrationTransferSeal(migrationID), body: Data()
        )
    }

    /// Sends a previously exported local package file by file. Resume always
    /// uses the receiver's committed offsets; the final receipt proves only
    /// verified staging on Mac, not catalog import or migration completion.
    public func uploadMigrationArchive(
        at archiveRoot: URL
    ) async throws -> ImageAllMigrationTransferSealReceipt {
        let (header, firstVerification) = try ImageAllMigrationArchive.readVerifiedHeader(
            at: archiveRoot
        )
        guard firstVerification.isComplete else {
            throw RemoteAPIError(code: .badRequest, message: "archive has missing resources")
        }
        let capabilities = try await fetchCapabilities()
        guard capabilities.capabilities.contains(.migrationTransfer) else {
            throw RemoteAPIError(code: .notFound, message: "host cannot receive migration archives")
        }
        var progress = try await beginMigrationTransfer(migrationID: header.migrationID)
        let manager = FileManager.default
        var paths = [ImageAllMigrationArchive.manifestFilename]
        for directoryName in ["resources", ImageAllMigrationFacts.sidecarDirectoryName] {
            let directory = archiveRoot.appendingPathComponent(directoryName, isDirectory: true)
            if manager.fileExists(atPath: directory.path) {
                paths += try manager.contentsOfDirectory(atPath: directory.path)
                    .sorted().map { "\(directoryName)/\($0)" }
            }
        }
        for path in paths {
            let file = archiveRoot.appendingPathComponent(path)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let attributes = try manager.attributesOfItem(atPath: file.path)
            guard let sizeValue = attributes[.size] as? NSNumber else {
                throw RemoteAPIError(code: .badRequest, message: "archive file size unavailable")
            }
            let size = sizeValue.int64Value
            let committed = progress.files.first(where: { $0.relativePath == path })?.committedBytes ?? 0
            guard committed >= 0, committed <= size else {
                throw RemoteAPIError(code: .conflict, message: "receiver offset exceeds source file")
            }
            try handle.seek(toOffset: UInt64(committed))
            var offset = committed
            while offset < size {
                let count = Int(min(Int64(progress.maximumChunkBytes), size - offset))
                guard count > 0, let bytes = try handle.read(upToCount: count), !bytes.isEmpty else {
                    throw RemoteAPIError(code: .conflict, message: "archive changed during transfer")
                }
                progress = try await uploadMigrationChunk(
                    migrationID: header.migrationID, relativePath: path,
                    offset: offset, bytes: bytes
                )
                offset += Int64(bytes.count)
                guard progress.files.first(where: { $0.relativePath == path })?.committedBytes == offset else {
                    throw RemoteAPIError(code: .conflict, message: "receiver did not commit chunk")
                }
            }
        }
        guard try ImageAllMigrationArchive.verify(at: archiveRoot) == firstVerification else {
            throw RemoteAPIError(code: .conflict, message: "archive changed during transfer")
        }
        let receipt = try await sealMigrationTransfer(migrationID: header.migrationID)
        guard receipt.manifestSHA256 == firstVerification.manifestSHA256,
              receipt.itemCount == firstVerification.itemCount,
              receipt.resourceCount == firstVerification.resourceCount,
              receipt.verifiedBytes == firstVerification.verifiedBytes,
              receipt.factsSHA256 == firstVerification.factsSHA256 else {
            throw RemoteAPIError(code: .conflict, message: "receiver archive differs from source")
        }
        return receipt
    }

    public func submitLocalLibrarySnapshot(
        _ request: RemoteLocalLibrarySnapshotRequest
    ) async throws -> RemoteLocalLibrarySnapshotReceipt {
        try await postJSON(
            path: RemoteHTTPPaths.localLibrarySnapshot,
            body: encoder.encode(request)
        )
    }

    public func submitLocalLibrarySnapshotInChunks(
        _ request: RemoteLocalLibrarySnapshotRequest, deviceID: UUID,
        beforeChunk: @Sendable () async throws -> Void = {}
    ) async throws -> RemoteLocalLibrarySnapshotReceipt {
        let canonical = JSONEncoder()
        canonical.outputFormatting = [.sortedKeys]
        let bytes = try canonical.encode(request)
        guard bytes.count <= RemoteLocalLibrarySnapshotChunk.maximumSnapshotBytes else {
            throw RemoteAPIError(code: .badRequest, message: "snapshot exceeds negotiated transfer capacity")
        }
        let lookup = try RemoteLocalLibrarySnapshotReceiptLookup(request: request)
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            try await beforeChunk()
            let end = min(offset + RemoteLocalLibrarySnapshotChunk.maximumChunkBytes, bytes.count)
            let chunk = RemoteLocalLibrarySnapshotChunk(snapshot: lookup, totalBytes: bytes.count,
                                                        offset: offset, bytes: bytes.subdata(in: offset..<end))
            let progress: RemoteLocalLibrarySnapshotChunkReceipt = try await postJSON(
                path: RemoteHTTPPaths.localLibrarySnapshotChunk, body: encoder.encode(chunk)
            )
            guard progress.hostID == request.hostID, progress.deviceID == deviceID,
                  progress.requestSHA256 == lookup.requestSHA256,
                  progress.receivedBytes >= end, progress.receivedBytes <= bytes.count,
                  progress.receivedBytes == bytes.count
                    || progress.receivedBytes % RemoteLocalLibrarySnapshotChunk.maximumChunkBytes == 0 else {
                throw RemoteAPIError(code: .conflict, message: "snapshot chunk receipt mismatch")
            }
            if let receipt = progress.snapshotReceipt {
                guard progress.receivedBytes == bytes.count, receipt.hostID == request.hostID,
                      receipt.deviceID == deviceID, receipt.sourceEpoch == request.sourceEpoch,
                      receipt.snapshotSequence == request.snapshotSequence else {
                    throw RemoteAPIError(code: .conflict, message: "snapshot commit receipt mismatch")
                }
                return receipt
            }
            guard progress.receivedBytes < bytes.count else {
                throw RemoteAPIError(code: .conflict, message: "snapshot complete without commit receipt")
            }
            offset = progress.receivedBytes
        }
        throw RemoteAPIError(code: .internalError, message: "snapshot transfer incomplete")
    }

    public func lookupLocalLibrarySnapshotReceipt(
        _ lookup: RemoteLocalLibrarySnapshotReceiptLookup
    ) async throws -> RemoteLocalLibrarySnapshotReceiptLookupResult {
        try await postJSON(
            path: RemoteHTTPPaths.localLibrarySnapshotReceipt,
            body: encoder.encode(lookup)
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

    public func submitLocalLibraryCollectionMembership(
        _ request: RemoteLocalLibraryCollectionMembershipRequest
    ) async throws -> RemoteLocalLibraryCollectionMembershipReceipt {
        try await postJSON(
            path: RemoteHTTPPaths.localLibraryCollectionMembership,
            body: encoder.encode(request)
        )
    }

    public func submitLocalLibraryFavoriteTarget(
        _ request: RemoteLocalLibraryFavoriteTargetRequest
    ) async throws -> RemoteLocalLibraryFavoriteTargetReceipt {
        try await postJSON(
            path: RemoteHTTPPaths.localLibraryFavoriteTarget,
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

    public func fetchLocalLibraryCollectionChanges(
        sourceEpoch: UUID, scopeRevision: Int64, afterCursor: Int64
    ) async throws -> RemoteLocalLibraryCollectionChangesPage {
        try await getJSON(
            path: RemoteHTTPPaths.localLibraryCollectionChanges,
            queryItems: [
                URLQueryItem(name: "sourceEpoch", value: sourceEpoch.uuidString),
                URLQueryItem(name: "scopeRevision", value: String(scopeRevision)),
                URLQueryItem(name: "afterCursor", value: String(afterCursor))
            ]
        )
    }

    public func fetchLocalLibraryFavoriteChanges(
        sourceEpoch: UUID, scopeRevision: Int64, afterCursor: Int64
    ) async throws -> RemoteLocalLibraryFavoriteChangesPage {
        try await getJSON(
            path: RemoteHTTPPaths.localLibraryFavoriteChanges,
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
        if let selection = request.worldMapSelection {
            items.append(contentsOf: [
                URLQueryItem(name: "worldMapCellDegrees", value: String(selection.cellDegrees)),
                URLQueryItem(name: "worldMapLongitudeBucket", value: String(selection.longitudeBucket)),
                URLQueryItem(name: "worldMapLatitudeBucket", value: String(selection.latitudeBucket)),
                URLQueryItem(name: "worldMapMaximumAssets", value: String(selection.maximumAssets)),
            ])
            if let scope = selection.mediaScope {
                items.append(URLQueryItem(name: "worldMapMediaScope", value: scope.rawValue))
            }
            if let bounds = selection.bounds {
                items.append(contentsOf: [
                    URLQueryItem(name: "worldMapWest", value: String(bounds.west)),
                    URLQueryItem(name: "worldMapSouth", value: String(bounds.south)),
                    URLQueryItem(name: "worldMapEast", value: String(bounds.east)),
                    URLQueryItem(name: "worldMapNorth", value: String(bounds.north)),
                ])
            }
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
        if let duration = request.videoDuration, duration != .any {
            items.append(URLQueryItem(name: "videoDuration", value: duration.rawValue))
        }
        if let orientation = request.videoOrientation, orientation != .any {
            items.append(URLQueryItem(name: "videoOrientation", value: orientation.rawValue))
        }
        if request.tagPresence != .any {
            items.append(URLQueryItem(name: "tagPresence", value: request.tagPresence.rawValue))
        }
        return try await getJSON(path: RemoteHTTPPaths.assets, queryItems: items)
    }

    public func fetchTrainingSetup(mediaKind: RemoteAssetMediaKind) async throws -> RemoteTrainingSetupSnapshot {
        let result: RemoteTrainingSetupSnapshot = try await getJSON(path: RemoteHTTPPaths.trainingSetup,
            queryItems: [URLQueryItem(name: "mediaKind", value: mediaKind.rawValue)])
        guard result.mediaKind == mediaKind else {
            throw RemoteAPIError(code: .conflict, message: "training setup media mismatch")
        }
        return result
    }

    public func fetchTrainingActivities(mediaKind: RemoteAssetMediaKind) async throws -> [RemoteTrainingActivity] {
        let result: [RemoteTrainingActivity] = try await getJSON(path: RemoteHTTPPaths.trainingActivities,
            queryItems: [URLQueryItem(name: "mediaKind", value: mediaKind.rawValue)])
        guard result.allSatisfy({ $0.mediaKind == mediaKind }) else {
            throw RemoteAPIError(code: .conflict, message: "training activity media mismatch")
        }
        return result
    }

    public func launchTraining(_ request: RemoteTrainingLaunchRequest) async throws -> RemoteTrainingLaunchResponse {
        let result: RemoteTrainingLaunchResponse = try await postJSON(path: RemoteHTTPPaths.trainingLaunch,
            body: JSONEncoder().encode(request))
        guard result.operationID == request.operationID, result.method == request.method else {
            throw RemoteAPIError(code: .conflict, message: "training receipt identity mismatch")
        }
        return result
    }

    public func cancelTraining(operationID: UUID, mediaKind: RemoteAssetMediaKind) async throws -> RemoteTrainingActivityActionResponse {
        let result: RemoteTrainingActivityActionResponse = try await postJSON(
            path: RemoteHTTPPaths.trainingActivityAction(operationID: operationID),
            body: JSONEncoder().encode(RemoteTrainingActivityActionRequest(action: .cancel)))
        guard result.activity.operationID == operationID, result.activity.mediaKind == mediaKind else {
            throw RemoteAPIError(code: .conflict, message: "training cancellation identity mismatch")
        }
        return result
    }

    public func fetchSampleSuggestions(mediaKind: RemoteAssetMediaKind) async throws -> RemoteSampleSuggestionSnapshot {
        let result: RemoteSampleSuggestionSnapshot = try await getJSON(path: RemoteHTTPPaths.sampleSuggestions,
            queryItems: [URLQueryItem(name: "mediaKind", value: mediaKind.rawValue)])
        guard result.mediaKind == mediaKind, result.activities.allSatisfy({ $0.mediaKind == mediaKind }) else {
            throw RemoteAPIError(code: .conflict, message: "sample media identity mismatch")
        }
        return result
    }

    public func submitSampleSuggestions(_ request: RemoteSampleSuggestionRequest) async throws -> RemoteSampleSuggestionResponse {
        let result: RemoteSampleSuggestionResponse = try await postJSON(path: RemoteHTTPPaths.sampleSuggestionRequests,
            body: JSONEncoder().encode(request))
        guard result.activity.operationID == request.operationID, result.activity.mediaKind == request.mediaKind else {
            throw RemoteAPIError(code: .conflict, message: "sample response identity mismatch")
        }
        return result
    }

    public func cancelSampleSuggestions(operationID: UUID) async throws -> RemoteSampleSuggestionActionResponse {
        let result: RemoteSampleSuggestionActionResponse = try await postJSON(path: RemoteHTTPPaths.sampleSuggestionAction(operationID: operationID),
            body: JSONEncoder().encode(RemoteSampleSuggestionActionRequest(action: .cancel)))
        guard result.activity.operationID == operationID else {
            throw RemoteAPIError(code: .conflict, message: "sample cancellation identity mismatch")
        }
        return result
    }

    public func fetchLibrarySuggestions(mediaKind: RemoteAssetMediaKind) async throws -> RemoteLibrarySuggestionSnapshot {
        let result: RemoteLibrarySuggestionSnapshot = try await getJSON(
            path: RemoteHTTPPaths.librarySuggestions,
            queryItems: [URLQueryItem(name: "mediaKind", value: mediaKind.rawValue)]
        )
        guard result.mediaKind == mediaKind else {
            throw RemoteAPIError(code: .conflict, message: "suggestion media identity mismatch")
        }
        return result
    }

    public func analyzeAssetLocalSuggestions(
        assetID: UUID, request: RemoteAssetLocalSuggestionRequest
    ) async throws -> RemoteAssetLocalSuggestionResponse {
        let result: RemoteAssetLocalSuggestionResponse = try await postJSON(
            path: RemoteHTTPPaths.assetDetail(assetID: assetID) + "/local-suggestions",
            body: JSONEncoder().encode(request)
        )
        guard result.assetID == assetID, result.operationID == request.operationID,
              result.track == request.track else {
            throw RemoteAPIError(code: .conflict, message: "suggestion response identity mismatch")
        }
        return result
    }

    public func fetchAssetDetail(assetID: UUID) async throws -> RemoteAssetDetail {
        try await getJSON(path: RemoteHTTPPaths.assetDetail(assetID: assetID))
    }

    /// A bounded authenticated read. Credentials never enter the AVPlayer URL.
    public func readVideoRange(
        assetID: UUID, contentRevision: Int, offset: Int64, count: Int
    ) async throws -> RemoteVideoChunk {
        guard contentRevision >= 0, offset >= 0, count > 0,
              count <= RemoteVideoChunk.maximumBytes,
              offset <= Int64.max - Int64(count) else { throw RemoteVideoError.invalidRange }
        try Task.checkCancellation()
        var request = try makeRequest(
            path: "/v1/assets/\(assetID.uuidString.lowercased())/media", method: "GET",
            queryItems: [URLQueryItem(name: "revision", value: String(contentRevision))]
        )
        request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await transport.data(for: request, maximumBytes: max(count, 8 * 1_024))
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw RemoteVideoError.invalidResponse }
        guard http.statusCode == 206 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw RemoteVideoError.authorizationRequired }
            if http.statusCode == 409 { throw RemoteVideoError.contentChanged }
            if http.statusCode == 404 {
                if data.count <= 8 * 1_024,
                   let error = try? JSONDecoder().decode(RemoteAPIError.self, from: data) {
                    switch error.mediaFailureReason {
                    case .cloudVideoOriginalRequired: throw RemoteVideoError.cloudOriginalRequired
                    case .unsupportedVideoRepresentation: throw RemoteVideoError.unsupportedRepresentation
                    case nil: break
                    }
                }
                throw RemoteVideoError.unavailable
            }
            throw RemoteVideoError.invalidResponse
        }
        guard http.value(forHTTPHeaderField: "X-ImageAll-Content-Revision") == String(contentRevision) else {
            throw RemoteVideoError.contentChanged
        }
        return try RemoteVideoChunk(data: data, response: http, requestedOffset: offset, requestedCount: count)
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
