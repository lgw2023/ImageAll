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
    private var latestUndo: LatestUndo?

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

    func fetchTagGroups() throws -> [RemoteTagGroupSummary] {
        try catalog.listTagGroups().map(Self.mapTagGroup)
    }

    func fetchAssets(_ request: RemoteAssetPageRequest) throws -> RemoteAssetPage {
        let limit = max(1, min(request.limit, 200))
        let cursor = try Self.decodeCursor(request.cursor)
        let page = try catalog.fetchAssetPage(
            filter: AssetPageFilter(
                sourceIDs: request.sourceIDs,
                tagDecisionFilters: request.tagDecisionFilters.map {
                    TagDecisionFilter(
                        tagID: $0.tagID,
                        decision: $0.decision == .accepted ? .accepted : .rejected
                    )
                },
                excludedTagIDs: request.excludedTagIDs,
                tagMatchMode: request.tagMatchMode == .all ? .all : .any,
                availabilities: request.availabilities.map {
                    switch $0 {
                    case .available: .available
                    case .missing: .missing
                    case .unreadable: .unreadable
                    case .unsupported: .unsupported
                    }
                },
                mediaKinds: request.mediaKinds.map {
                    $0 == .image ? .image : .video
                },
                mediaTypes: request.mediaTypes,
                tagPresence: {
                    switch request.tagPresence {
                    case .any: .any
                    case .tagged: .tagged
                    case .untagged: .untagged
                    }
                }(),
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
            mediaKind: Self.mapMediaKind(request.mediaKind),
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

    func fetchReviewOverview(
        mediaKind: RemoteAssetMediaKind,
        sourceIDs: [UUID]
    ) throws -> RemoteReviewOverview {
        let resolvedSourceIDs: [UUID]? = sourceIDs.isEmpty ? nil : sourceIDs
        let mappedMediaKind = Self.mapMediaKind(mediaKind)
        return RemoteReviewOverview(
            totalPendingSuggestionCount: try review.totalPendingSuggestionCount(
                mediaKind: mappedMediaKind,
                sourceIDs: resolvedSourceIDs
            ),
            tags: try review.tagOverviews(
                mediaKind: mappedMediaKind,
                sourceIDs: resolvedSourceIDs
            ).map(Self.mapSuggestionOverview)
        )
    }

    func applyTagDecision(
        _ request: RemoteBatchTagDecisionRequest
    ) async throws -> RemoteBatchTagDecisionResponse {
        let catalog = self.catalog
        let (appliedAssetCount, replayed, undoID) = try await applyDecision(
            operationID: request.operationID,
            kind: "tagDecision",
            tagID: request.tagID,
            assetIDs: request.assetIDs,
            actionRawValue: request.action.rawValue
        ) {
            try catalog.mutateTag(
                tagID: request.tagID,
                assetIDs: request.assetIDs,
                action: Self.mapTagAction(request.action)
            )
        }
        return RemoteBatchTagDecisionResponse(
            operationID: request.operationID,
            appliedAssetCount: appliedAssetCount,
            replayed: replayed,
            undoID: undoID
        )
    }

    func createTagAndApply(
        _ request: RemoteCreateTagAndApplyRequest
    ) async throws -> RemoteCreateTagAndApplyResponse {
        guard !request.assetIDs.isEmpty else {
            throw RemoteAPIError(code: .badRequest, message: "请先选择至少一张照片")
        }
        let catalog = self.catalog
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "createTagAndApply",
            subject: request.name,
            assetIDs: request.assetIDs,
            action: RemoteTagDecisionAction.accept.rawValue
        )
        let snapshotBox = SnapshotBox()
        do {
            let (result, replayed): (CreateTagResult, Bool) = try await idempotency.perform(
                operationID: request.operationID,
                key: key
            ) {
                let created: TagCreateAndApplyResult
                do {
                    created = try catalog.createTagAndAccept(
                        rawName: request.name,
                        assetIDs: request.assetIDs
                    )
                } catch let error as CatalogQueryError {
                    throw Self.mapCreateTagError(error)
                }
                snapshotBox.store(created.restoreSnapshot())
                return CreateTagResult(
                    tagID: created.tagID,
                    displayName: created.displayName,
                    appliedAssetCount: created.priorStates.count
                )
            }
            if !replayed, let snapshot = snapshotBox.value {
                latestUndo = LatestUndo(
                    id: UUID(),
                    operationID: request.operationID,
                    snapshot: snapshot
                )
            }
            return RemoteCreateTagAndApplyResponse(
                operationID: request.operationID,
                tagID: result.tagID,
                displayName: result.displayName,
                appliedAssetCount: result.appliedAssetCount,
                replayed: replayed,
                undoID: latestUndo?.operationID == request.operationID ? latestUndo?.id : nil
            )
        } catch is RemoteIdempotencyStore.IdempotencyError {
            throw RemoteAPIError(
                code: .conflict,
                message: "operationID was already used for a different mutation"
            )
        }
    }

    func applyReviewDecision(
        _ request: RemoteBatchReviewDecisionRequest
    ) async throws -> RemoteBatchReviewDecisionResponse {
        let catalog = self.catalog
        let (appliedAssetCount, replayed, undoID) = try await applyDecision(
            operationID: request.operationID,
            kind: "reviewDecision",
            tagID: request.tagID,
            assetIDs: request.assetIDs,
            actionRawValue: request.action.rawValue
        ) {
            try catalog.mutateTag(
                tagID: request.tagID,
                assetIDs: request.assetIDs,
                action: Self.mapReviewAction(request.action)
            )
        }
        return RemoteBatchReviewDecisionResponse(
            operationID: request.operationID,
            appliedAssetCount: appliedAssetCount,
            replayed: replayed,
            undoID: undoID
        )
    }

    func undoTagDecision(
        _ request: RemoteUndoTagDecisionRequest
    ) async throws -> RemoteUndoTagDecisionResponse {
        let candidate = latestUndo?.id == request.undoID ? latestUndo : nil
        let catalog = self.catalog
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "undoTagDecision",
            subject: request.undoID.uuidString.lowercased(),
            assetIDs: [],
            action: "restore"
        )
        do {
            let (restoredAssetCount, replayed): (Int, Bool) = try await idempotency.perform(
                operationID: request.operationID,
                key: key
            ) {
                guard let candidate else {
                    throw RemoteAPIError(code: .notFound, message: "这次撤销已过期")
                }
                try catalog.restoreTagMutation(candidate.snapshot)
                return candidate.snapshot.priorStates.count
            }
            if !replayed, latestUndo?.id == request.undoID {
                latestUndo = nil
            }
            return RemoteUndoTagDecisionResponse(
                operationID: request.operationID,
                restoredAssetCount: restoredAssetCount,
                replayed: replayed
            )
        } catch is RemoteIdempotencyStore.IdempotencyError {
            throw RemoteAPIError(code: .conflict, message: "operationID was already used for a different mutation")
        }
    }

    func renameTag(tagID: UUID, request: RemoteRenameTagRequest) async throws -> RemoteTagMutationResponse {
        let catalog = self.catalog
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "renameTag",
            tagID: tagID,
            assetIDs: [],
            action: request.name
        )
        do {
            let (tag, replayed): (RemoteTagSummary, Bool) = try await idempotency.perform(
                operationID: request.operationID,
                key: key
            ) {
                do {
                    return Self.mapTag(try catalog.renameTag(tagID: tagID, rawName: request.name))
                } catch let error as CatalogQueryError {
                    throw Self.mapTagCatalogError(error)
                }
            }
            return RemoteTagMutationResponse(operationID: request.operationID, tag: tag, replayed: replayed)
        } catch is RemoteIdempotencyStore.IdempotencyError {
            throw RemoteAPIError(code: .conflict, message: "operationID was already used for a different mutation")
        }
    }

    func archiveTag(tagID: UUID, request: RemoteArchiveTagRequest) async throws -> RemoteTagMutationResponse {
        let catalog = self.catalog
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "archiveTag",
            tagID: tagID,
            assetIDs: [],
            action: "archive"
        )
        do {
            let (_, replayed): (Bool, Bool) = try await idempotency.perform(
                operationID: request.operationID,
                key: key
            ) {
                do {
                    try catalog.archiveTag(tagID: tagID)
                    return true
                } catch let error as CatalogQueryError {
                    throw Self.mapTagCatalogError(error)
                }
            }
            return RemoteTagMutationResponse(operationID: request.operationID, tag: nil, replayed: replayed)
        } catch is RemoteIdempotencyStore.IdempotencyError {
            throw RemoteAPIError(code: .conflict, message: "operationID was already used for a different mutation")
        }
    }

    func moveTag(tagID: UUID, request: RemoteMoveTagRequest) async throws -> RemoteTagMutationResponse {
        let catalog = self.catalog
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "moveTag",
            tagID: tagID,
            assetIDs: [],
            action: request.groupID.uuidString.lowercased()
        )
        do {
            let (tag, replayed): (RemoteTagSummary, Bool) = try await idempotency.perform(
                operationID: request.operationID,
                key: key
            ) {
                do {
                    return Self.mapTag(try catalog.moveTag(tagID: tagID, toGroupID: request.groupID))
                } catch let error as CatalogQueryError {
                    throw Self.mapTagCatalogError(error)
                }
            }
            return RemoteTagMutationResponse(operationID: request.operationID, tag: tag, replayed: replayed)
        } catch is RemoteIdempotencyStore.IdempotencyError {
            throw RemoteAPIError(code: .conflict, message: "operationID was already used for a different mutation")
        }
    }

    func createTagGroup(
        _ request: RemoteCreateTagGroupRequest
    ) async throws -> RemoteTagGroupMutationResponse {
        let catalog = self.catalog
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "createTagGroup",
            subject: request.name,
            assetIDs: [],
            action: "create"
        )
        do {
            let (group, replayed): (RemoteTagGroupSummary, Bool) = try await idempotency.perform(
                operationID: request.operationID,
                key: key
            ) {
                do {
                    return Self.mapTagGroup(try catalog.createTagGroup(rawName: request.name))
                } catch let error as CatalogQueryError {
                    throw Self.mapTagCatalogError(error)
                }
            }
            return RemoteTagGroupMutationResponse(operationID: request.operationID, group: group, replayed: replayed)
        } catch is RemoteIdempotencyStore.IdempotencyError {
            throw RemoteAPIError(code: .conflict, message: "operationID was already used for a different mutation")
        }
    }

    func renameTagGroup(
        groupID: UUID,
        request: RemoteRenameTagGroupRequest
    ) async throws -> RemoteTagGroupMutationResponse {
        let catalog = self.catalog
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "renameTagGroup",
            subject: "\(groupID.uuidString.lowercased()):\(request.name)",
            assetIDs: [],
            action: "rename"
        )
        do {
            let (group, replayed): (RemoteTagGroupSummary, Bool) = try await idempotency.perform(
                operationID: request.operationID,
                key: key
            ) {
                do {
                    return Self.mapTagGroup(try catalog.renameTagGroup(groupID: groupID, rawName: request.name))
                } catch let error as CatalogQueryError {
                    throw Self.mapTagCatalogError(error)
                }
            }
            return RemoteTagGroupMutationResponse(operationID: request.operationID, group: group, replayed: replayed)
        } catch is RemoteIdempotencyStore.IdempotencyError {
            throw RemoteAPIError(code: .conflict, message: "operationID was already used for a different mutation")
        }
    }

    func deleteTagGroup(
        groupID: UUID,
        request: RemoteDeleteTagGroupRequest
    ) async throws -> RemoteTagGroupMutationResponse {
        let catalog = self.catalog
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "deleteTagGroup",
            subject: groupID.uuidString.lowercased(),
            assetIDs: [],
            action: "delete"
        )
        do {
            let (_, replayed): (Bool, Bool) = try await idempotency.perform(
                operationID: request.operationID,
                key: key
            ) {
                do {
                    try catalog.deleteTagGroup(groupID: groupID)
                    return true
                } catch let error as CatalogQueryError {
                    throw Self.mapTagCatalogError(error)
                }
            }
            return RemoteTagGroupMutationResponse(operationID: request.operationID, group: nil, replayed: replayed)
        } catch is RemoteIdempotencyStore.IdempotencyError {
            throw RemoteAPIError(code: .conflict, message: "operationID was already used for a different mutation")
        }
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
        mutate: @escaping @Sendable () throws -> TagMutationPriorStateSnapshot
    ) async throws -> (appliedAssetCount: Int, replayed: Bool, undoID: UUID?) {
        guard !assetIDs.isEmpty else {
            throw RemoteAPIError(code: .badRequest, message: "assetIDs must not be empty")
        }
        let key = RemoteIdempotencyStore.MutationKey(
            kind: kind,
            tagID: tagID,
            assetIDs: assetIDs,
            action: actionRawValue
        )
        let snapshotBox = SnapshotBox()
        do {
            let (appliedAssetCount, replayed): (Int, Bool) = try await idempotency.perform(
                operationID: operationID,
                key: key,
                mutate: {
                    let snapshot = try mutate()
                    snapshotBox.store(snapshot)
                    return snapshot.priorStates.count
                }
            )
            if !replayed, let snapshot = snapshotBox.value {
                latestUndo = LatestUndo(
                    id: UUID(),
                    operationID: operationID,
                    snapshot: snapshot
                )
            }
            return (
                appliedAssetCount,
                replayed,
                latestUndo?.operationID == operationID ? latestUndo?.id : nil
            )
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

    private static func mapTagGroup(_ group: TagGroupListItem) -> RemoteTagGroupSummary {
        RemoteTagGroupSummary(
            id: group.id,
            displayName: group.displayName,
            sortOrder: group.sortOrder,
            isSystem: group.isSystem
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
                case .librarySlimmingPurge: .background
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

    private static func mapSuggestionOverview(
        _ overview: SuggestionTagOverview
    ) -> RemoteSuggestionTagOverview {
        RemoteSuggestionTagOverview(
            id: overview.id,
            displayName: overview.displayName,
            acceptedSampleCount: overview.acceptedSampleCount,
            rejectedSampleCount: overview.rejectedSampleCount,
            pendingSuggestionCount: overview.pendingSuggestionCount,
            pendingSuggestionCounts: RemoteSuggestionOriginCounts(
                featurePrint: overview.pendingSuggestionCounts.featurePrint,
                standardModel: overview.pendingSuggestionCounts.standardModel,
                personalModel: overview.pendingSuggestionCounts.personalModel,
                personalAdamW: overview.pendingSuggestionCounts.personalAdamW
            ),
            taskStatus: mapSuggestionTaskStatus(overview.taskStatus),
            checkedCount: overview.checkedCount,
            totalCount: overview.totalCount,
            skippedCount: overview.skippedCount,
            missingPositiveCount: overview.missingPositiveCount,
            missingNegativeCount: overview.missingNegativeCount,
            canReview: overview.canReview
        )
    }

    private static func mapSuggestionTaskStatus(
        _ status: SuggestionTaskPresentation
    ) -> RemoteSuggestionTaskStatus {
        switch status {
        case .notReady: .notReady
        case .ready: .ready
        case .waiting: .waiting
        case .running: .running
        case .paused: .paused
        case .retryableFailure: .retryableFailure
        case .completed: .completed
        case .terminalFailure: .terminalFailure
        case .cancelled: .cancelled
        }
    }

    private static func mapMediaKind(_ kind: RemoteAssetMediaKind) -> MediaKind {
        kind == .video ? .video : .image
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

    private static func mapCreateTagError(_ error: CatalogQueryError) -> RemoteAPIError {
        switch error {
        case .invalidTagName:
            RemoteAPIError(code: .badRequest, message: "标签名称无效")
        case .duplicateTag:
            RemoteAPIError(code: .conflict, message: "已有同名标签")
        case .emptySelection:
            RemoteAPIError(code: .badRequest, message: "请先选择至少一张照片")
        case .selectionTooLarge:
            RemoteAPIError(code: .badRequest, message: "一次选择的照片过多")
        case .notFound:
            RemoteAPIError(code: .notFound, message: "所选照片已不存在")
        default:
            RemoteAPIError(code: .internalError, message: "无法创建标签")
        }
    }

    private static func mapTagCatalogError(_ error: CatalogQueryError) -> RemoteAPIError {
        switch error {
        case .invalidTagName:
            RemoteAPIError(code: .badRequest, message: "名称无效")
        case .duplicateTag:
            RemoteAPIError(code: .conflict, message: "已有同名标签或分组")
        case .archivedTag:
            RemoteAPIError(code: .conflict, message: "归档标签不能执行此操作")
        case .systemGroupProtected:
            RemoteAPIError(code: .conflict, message: "系统标签分组不能修改或删除")
        case .notFound:
            RemoteAPIError(code: .notFound, message: "标签或分组已不存在")
        default:
            RemoteAPIError(code: .internalError, message: "标签操作失败")
        }
    }

    private struct CreateTagResult: Codable, Sendable {
        let tagID: UUID
        let displayName: String
        let appliedAssetCount: Int
    }

    private struct LatestUndo: Sendable {
        let id: UUID
        let operationID: UUID
        let snapshot: TagMutationPriorStateSnapshot
    }

    private final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: TagMutationPriorStateSnapshot?

        var value: TagMutationPriorStateSnapshot? {
            lock.withLock { storedValue }
        }

        func store(_ value: TagMutationPriorStateSnapshot) {
            lock.withLock { storedValue = value }
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
