import Foundation
import ImageAllRemoteProtocol

/// Thin mapping/facade over a narrow catalog surface. Does not touch UI state machines.
/// Tag- and review-decision idempotency is delegated to `RemoteIdempotencyStore`, which
/// persists applied operations to disk so replays survive a Mac Host restart.
actor RemoteCatalogFacade {
    private let catalog: any RemoteCatalogServing
    private let review: any PersonalizationReviewPort
    private let idempotency: RemoteIdempotencyStore
    private let hostAppVersion: String
    private let listenPort: Int
    private let hostID: UUID?
    private let usesTLS: Bool
    private let certificateFingerprintSHA256: String?

    init(
        catalog: any RemoteCatalogServing,
        review: any PersonalizationReviewPort,
        idempotency: RemoteIdempotencyStore,
        hostAppVersion: String,
        listenPort: Int,
        hostID: UUID? = nil,
        usesTLS: Bool = false,
        certificateFingerprintSHA256: String? = nil
    ) {
        self.catalog = catalog
        self.review = review
        self.idempotency = idempotency
        self.hostAppVersion = hostAppVersion
        self.listenPort = listenPort
        self.hostID = hostID
        self.usesTLS = usesTLS
        self.certificateFingerprintSHA256 = certificateFingerprintSHA256
    }

    func capabilities() -> RemoteCapabilities {
        RemoteCapabilities(
            hostAppVersion: hostAppVersion,
            listenPort: listenPort,
            usesTLS: usesTLS,
            hostID: hostID,
            certificateFingerprintSHA256: certificateFingerprintSHA256
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

    func loadPreview(assetID: UUID) async throws -> Data {
        try await catalog.loadPreview(assetID: assetID)
    }

    func fetchInspectorDetail(assetID: UUID) throws -> RemoteAssetDetail {
        try Self.mapDetail(catalog.fetchInspectorDetail(assetID: assetID))
    }

    func selectionAggregate(_ request: RemoteTagSelectionRequest) throws -> [RemoteTagSelectionAggregate] {
        try catalog
            .selectionAggregate(tagIDs: request.tagIDs, assetIDs: request.assetIDs)
            .map(Self.mapAggregate)
    }

    func fetchJobActivity() throws -> [RemoteJobSummary] {
        try catalog.fetchJobActivity().map(Self.mapJob)
    }

    func applyJobActivityAction(jobID: UUID, request: RemoteJobActionRequest) throws {
        try catalog.applyJobActivityAction(Self.mapJobAction(request.action), jobID: jobID)
    }

    func fetchReviewQueue(_ request: RemoteReviewQueueRequest) throws -> RemoteReviewQueuePage {
        let cursor = try Self.decodeReviewCursor(request.cursor)
        let page = try review.fetchReviewQueue(
            tagID: request.tagID,
            sourceIDs: request.sourceIDs.isEmpty ? nil : request.sourceIDs,
            cursor: cursor,
            limit: max(1, min(request.limit, 200))
        )
        return RemoteReviewQueuePage(
            items: page.items.map(Self.mapReviewItem),
            nextCursor: Self.encodeReviewCursor(page.nextCursor)
        )
    }

    func applyTagDecision(
        _ request: RemoteBatchTagDecisionRequest
    ) async throws -> RemoteBatchTagDecisionResponse {
        let catalog = self.catalog
        let (appliedAssetCount, replayed) = try await applyDecision(
            operationID: request.operationID,
            kind: "tagDecision",
            tagID: request.tagID,
            assetIDs: request.assetIDs,
            actionRawValue: request.action.rawValue
        ) {
            let snapshot = try catalog.mutateTag(
                tagID: request.tagID,
                assetIDs: request.assetIDs,
                action: Self.mapTagAction(request.action)
            )
            return snapshot.priorStates.count
        }
        return RemoteBatchTagDecisionResponse(
            operationID: request.operationID,
            appliedAssetCount: appliedAssetCount,
            replayed: replayed
        )
    }

    func applyReviewDecision(
        _ request: RemoteBatchReviewDecisionRequest
    ) async throws -> RemoteBatchReviewDecisionResponse {
        let catalog = self.catalog
        let (appliedAssetCount, replayed) = try await applyDecision(
            operationID: request.operationID,
            kind: "reviewDecision",
            tagID: request.tagID,
            assetIDs: request.assetIDs,
            actionRawValue: request.action.rawValue
        ) {
            let snapshot = try catalog.mutateTag(
                tagID: request.tagID,
                assetIDs: request.assetIDs,
                action: Self.mapReviewAction(request.action)
            )
            return snapshot.priorStates.count
        }
        return RemoteBatchReviewDecisionResponse(
            operationID: request.operationID,
            appliedAssetCount: appliedAssetCount,
            replayed: replayed
        )
    }

    /// Shared idempotent-mutation plumbing for both tag and review decisions: both mutate
    /// via `RemoteCatalogServing.mutateTag` and both persist through the same
    /// `RemoteIdempotencyStore`, distinguished only by `kind` so a `tagDecision` and a
    /// `reviewDecision` never collide even if they reused an `operationID`.
    private func applyDecision(
        operationID: UUID,
        kind: String,
        tagID: UUID,
        assetIDs: [UUID],
        actionRawValue: String,
        mutate: @escaping @Sendable () throws -> Int
    ) async throws -> (appliedAssetCount: Int, replayed: Bool) {
        guard !assetIDs.isEmpty else {
            throw RemoteAPIError(code: .badRequest, message: "assetIDs must not be empty")
        }
        let key = RemoteIdempotencyStore.MutationKey(
            kind: kind,
            tagID: tagID,
            assetIDs: assetIDs,
            action: actionRawValue
        )
        do {
            let (appliedAssetCount, replayed) = try await idempotency.perform(
                operationID: operationID,
                key: key,
                mutate: mutate
            )
            return (appliedAssetCount, replayed)
        } catch is RemoteIdempotencyStore.IdempotencyError {
            throw RemoteAPIError(
                code: .conflict,
                message: "operationID was already used for a different mutation"
            )
        }
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

    private static func mapAvailability(_ availability: AssetAvailability) -> RemoteAssetAvailability {
        switch availability {
        case .available: .available
        case .missing: .missing
        case .unreadable: .unreadable
        case .unsupported: .unsupported
        case .recycled: .missing
        }
    }

    private static func mapAsset(_ item: AssetGridItemProjection) -> RemoteAssetSummary {
        RemoteAssetSummary(
            id: item.assetID,
            sourceID: item.sourceID,
            sourceName: item.sourceDisplayName,
            fileName: item.fileName,
            mediaType: item.mediaType,
            availability: mapAvailability(item.availability),
            contentRevision: item.contentRevision,
            acceptedTagCount: item.acceptedTagCount,
            rejectedTagCount: item.rejectedTagCount,
            mediaCreatedAtMs: item.mediaCreatedAtMs,
            width: item.width,
            height: item.height
        )
    }

    private static func mapDetail(_ detail: AssetInspectorDetail) -> RemoteAssetDetail {
        RemoteAssetDetail(
            assetID: detail.assetID,
            sourceID: detail.sourceID,
            sourceName: detail.sourceDisplayName,
            fileName: detail.fileName,
            relativePath: detail.relativePath,
            mediaType: detail.mediaType,
            availability: mapAvailability(detail.availability),
            contentRevision: detail.contentRevision,
            acceptedTagCount: detail.acceptedTagCount,
            rejectedTagCount: detail.rejectedTagCount,
            mediaCreatedAtMs: detail.mediaCreatedAtMs,
            mediaModifiedAtMs: detail.mediaModifiedAtMs,
            width: detail.width,
            height: detail.height,
            tags: detail.tags.map(mapInspectorTagState)
        )
    }

    private static func mapInspectorTagState(_ state: InspectorTagState) -> RemoteInspectorTagState {
        RemoteInspectorTagState(
            tagID: state.tagID,
            displayName: state.displayName,
            decision: {
                switch state.decision {
                case .unknown: .unknown
                case .accepted: .accepted
                case .rejected: .rejected
                }
            }()
        )
    }

    private static func mapAggregate(_ aggregate: TagSelectionAggregate) -> RemoteTagSelectionAggregate {
        RemoteTagSelectionAggregate(
            tagID: aggregate.tagID,
            acceptedCount: aggregate.acceptedCount,
            rejectedCount: aggregate.rejectedCount,
            unknownCount: aggregate.unknownCount
        )
    }

    private static func mapJob(_ item: JobActivityItem) -> RemoteJobSummary {
        RemoteJobSummary(
            id: item.id,
            kind: {
                switch item.kind {
                case .folderReconcile: .folderReconcile
                case .photosReconcile: .photosReconcile
                case .personalizationSuggestions: .personalizationSuggestions
                case .standardSuggestions: .standardSuggestions
                case .librarySlimmingAnalysis: .librarySlimmingAnalysis
                case .librarySlimmingSourceIndex: .librarySlimmingSourceIndex
                case .background: .background
                }
            }(),
            state: {
                switch item.state {
                case .pending: .pending
                case .running: .running
                case .paused: .paused
                case .retryableFailed: .retryableFailed
                case .completed: .completed
                case .terminalFailed: .terminalFailed
                case .cancelled: .cancelled
                }
            }(),
            progress: RemoteJobProgress(
                completedUnitCount: Int64(item.progress.completed),
                totalUnitCount: item.progress.total.map(Int64.init)
            ),
            availableActions: item.availableActions.map {
                switch $0 {
                case .pause: .pause
                case .resume: .resume
                case .cancel: .cancel
                }
            }
        )
    }

    private static func mapJobAction(_ action: RemoteJobAction) -> JobActivityAction {
        switch action {
        case .pause: .pause
        case .resume: .resume
        case .cancel: .cancel
        }
    }

    private static func mapReviewItem(_ item: ReviewQueueItemProjection) -> RemoteReviewQueueItem {
        RemoteReviewQueueItem(
            assetID: item.assetID,
            fileName: item.fileName,
            availability: mapAvailability(item.availability),
            acceptedTagCount: item.acceptedTagCount,
            rejectedTagCount: item.rejectedTagCount,
            suggestionOrigin: {
                switch item.suggestionOrigin {
                case .featurePrint: .featurePrint
                case .standardModel: .standardModel
                case .personalModel: .personalModel
                case .personalAdamW: .personalAdamW
                }
            }(),
            score: item.score
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

    private static func mapReviewAction(_ action: RemoteReviewDecisionAction) -> LibraryTagDecisionAction {
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

    private static func encodeReviewCursor(_ cursor: ReviewQueueCursor?) -> String? {
        guard let cursor else { return nil }
        return cursor.token.base64EncodedString()
    }

    private static func decodeReviewCursor(_ raw: String?) throws -> ReviewQueueCursor? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let data = Data(base64Encoded: raw) else {
            throw RemoteAPIError(code: .badRequest, message: "invalid cursor encoding")
        }
        return ReviewQueueCursor(token: data)
    }
}
