import Foundation
import ImageAllRemoteProtocol

/// Thin mapping/facade over a narrow catalog surface. Does not touch UI state machines.
actor RemoteCatalogFacade {
    private struct AppliedOperation: Sendable {
        let tagID: UUID
        let assetIDs: [UUID]
        let action: RemoteTagDecisionAction
        let response: RemoteBatchTagDecisionResponse

        func matches(_ request: RemoteBatchTagDecisionRequest) -> Bool {
            tagID == request.tagID
                && action == request.action
                && assetIDs == Self.canonicalAssetIDs(request.assetIDs)
        }

        private static func canonicalAssetIDs(_ ids: [UUID]) -> [UUID] {
            Array(Set(ids)).sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }
        }
    }

    private let catalog: any RemoteCatalogServing
    private let hostAppVersion: String
    private let listenPort: Int
    private var appliedOperations: [UUID: AppliedOperation] = [:]

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

    func fetchTags() throws -> [RemoteTagSummary] {
        try catalog.listTags().map(Self.mapTag)
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
            cursor: cursor,
            limit: limit
        )
        return RemoteAssetPage(
            items: page.items.map(Self.mapAsset),
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
            guard replayed.matches(request) else {
                throw RemoteAPIError(
                    code: .conflict,
                    message: "operationID was already used for a different mutation"
                )
            }
            return RemoteBatchTagDecisionResponse(
                operationID: replayed.response.operationID,
                appliedAssetCount: replayed.response.appliedAssetCount,
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
        appliedOperations[request.operationID] = AppliedOperation(
            tagID: request.tagID,
            assetIDs: Array(Set(request.assetIDs)).sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            },
            action: request.action,
            response: response
        )
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

    private static func mapTag(_ tag: TagListItem) -> RemoteTagSummary {
        RemoteTagSummary(
            id: tag.id,
            displayName: tag.displayName,
            state: tag.state == .archived ? .archived : .active,
            groupID: tag.groupID
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
                case .recycled: .missing
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
