import Foundation
import ImageAllRemoteProtocol

/// Thin mapping/facade over a narrow catalog surface. Does not touch UI state machines.
actor RemoteCatalogFacade {
    private let catalog: any RemoteCatalogServing
    private let hostAppVersion: String
    private let listenPort: Int
    private var appliedOperations: [UUID: RemoteBatchTagDecisionResponse] = [:]

    init(
        catalog: any RemoteCatalogServing,
        hostAppVersion: String,
        listenPort: Int
    ) {
        self.catalog = catalog
        self.hostAppVersion = hostAppVersion
        self.listenPort = listenPort
    }

    func capabilities() -> RemoteCapabilities {
        RemoteCapabilities(
            hostAppVersion: hostAppVersion,
            listenPort: listenPort
        )
    }

    func fetchSources() throws -> [RemoteSourceSummary] {
        try catalog.fetchSources().map(Self.mapSource)
    }

    func fetchAssets(_ request: RemoteAssetPageRequest) throws -> RemoteAssetPage {
        let limit = max(1, min(request.limit, 200))
        let cursor = try Self.decodeCursor(request.cursor)
        let page = try catalog.fetchAssetPage(
            filter: AssetPageFilter(
                sourceIDs: request.sourceIDs,
                searchText: request.searchText
            ),
            sort: Self.mapSort(request.sort),
            cursor: cursor
        )
        // Existing port ignores limit; R0 returns the page as-is and truncates for safety.
        let items = Array(page.items.prefix(limit))
        return RemoteAssetPage(
            items: items.map(Self.mapAsset),
            nextCursor: try Self.encodeCursor(page.nextCursor)
        )
    }

    func loadThumbnail(assetID: UUID, targetPixelWidth: Int) async throws -> Data {
        _ = targetPixelWidth // R0: advisory only; existing port has no size parameter.
        return try await catalog.loadThumbnail(assetID: assetID)
    }

    func applyTagDecision(
        _ request: RemoteBatchTagDecisionRequest
    ) throws -> RemoteBatchTagDecisionResponse {
        if let replayed = appliedOperations[request.operationID] {
            return RemoteBatchTagDecisionResponse(
                operationID: replayed.operationID,
                appliedAssetCount: replayed.appliedAssetCount,
                replayed: true
            )
        }
        guard !request.assetIDs.isEmpty else {
            throw RemoteAPIError(code: .badRequest, message: "assetIDs must not be empty")
        }
        let snapshot = try catalog.mutateTag(
            tagID: request.tagID,
            assetIDs: request.assetIDs,
            action: Self.mapTagAction(request.action)
        )
        let response = RemoteBatchTagDecisionResponse(
            operationID: request.operationID,
            appliedAssetCount: snapshot.priorStates.count,
            replayed: false
        )
        appliedOperations[request.operationID] = response
        return response
    }

    private static func mapSource(_ source: LibrarySourceSummary) -> RemoteSourceSummary {
        RemoteSourceSummary(
            id: source.id,
            kind: source.kind == .photos ? .photos : .folder,
            displayName: source.displayName,
            state: {
                switch source.state {
                case .active: .active
                case .disabled: .disabled
                case .unavailable: .unavailable
                case .authorizationRequired: .authorizationRequired
                }
            }()
        )
    }

    private static func mapAsset(_ item: AssetGridItemProjection) -> RemoteAssetSummary {
        RemoteAssetSummary(
            id: item.assetID,
            sourceID: item.sourceID,
            sourceName: item.sourceDisplayName,
            fileName: item.fileName,
            mediaType: item.mediaType,
            availability: {
                switch item.availability {
                case .available: .available
                case .missing: .missing
                case .unreadable: .unreadable
                case .unsupported: .unsupported
                }
            }(),
            contentRevision: item.contentRevision,
            acceptedTagCount: item.acceptedTagCount,
            rejectedTagCount: item.rejectedTagCount,
            mediaCreatedAtMs: item.mediaCreatedAtMs,
            width: item.width,
            height: item.height
        )
    }

    private static func mapSort(_ sort: RemoteAssetSort) -> AssetPageSort {
        switch sort {
        case .newest: .newest
        case .oldest: .oldest
        case .fileNameAscending: .fileNameAscending
        }
    }

    private static func mapTagAction(_ action: RemoteTagDecisionAction) -> LibraryTagDecisionAction {
        switch action {
        case .accept: .accept
        case .reject: .reject
        case .clear: .clear
        }
    }

    private static func encodeCursor(_ cursor: AssetPageCursor?) throws -> String? {
        guard let cursor else { return nil }
        let data = try JSONEncoder().encode(cursor)
        return data.base64EncodedString()
    }

    private static func decodeCursor(_ raw: String?) throws -> AssetPageCursor? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let data = Data(base64Encoded: raw) else {
            throw RemoteAPIError(code: .badRequest, message: "invalid cursor encoding")
        }
        do {
            return try JSONDecoder().decode(AssetPageCursor.self, from: data)
        } catch {
            throw RemoteAPIError(code: .badRequest, message: "invalid cursor payload")
        }
    }
}
