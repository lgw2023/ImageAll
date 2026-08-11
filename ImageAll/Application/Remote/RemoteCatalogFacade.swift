import CryptoKit
import Foundation
import ImageAllRemoteProtocol

/// Thin mapping/facade over a narrow catalog surface. Does not touch UI state machines.
/// Tag- and review-decision idempotency is delegated to `RemoteIdempotencyStore`, which
/// persists applied operations to disk so replays survive a Mac Host restart.
actor RemoteCatalogFacade {
    private let catalog: any RemoteCatalogServing
    private let review: any PersonalizationReviewPort
    private let trainingWorkspace: (any TrainingWorkspacePort)?
    private let trainingCommands: (any RemoteTrainingCommandPort)?
    private let librarySlimmingAnalysis: (any LibrarySlimmingAnalysisJobPort)?
    private let librarySlimmingCommands: (any RemoteLibrarySlimmingCommandPort)?
    private let sourceManagementCommands: (any RemoteSourceManagementCommandPort)?
    private let storageMaintenanceCommands: (any RemoteStorageMaintenanceCommandPort)?
    private let generalSettingsCommands: (any RemoteGeneralSettingsCommandPort)?
    private let workspaceNotices: (any RemoteWorkspaceNoticePort)?
    private let idempotency: RemoteIdempotencyStore
    private let hostAppVersion: String
    private let listenPort: Int
    private let hostID: UUID?
    private let usesTLS: Bool
    private let certificateFingerprintSHA256: String?
    private var latestTagUndo: LatestUndo?
    private var latestReviewUndo: LatestUndo?

    init(
        catalog: any RemoteCatalogServing,
        review: any PersonalizationReviewPort,
        trainingWorkspace: (any TrainingWorkspacePort)? = nil,
        trainingCommands: (any RemoteTrainingCommandPort)? = nil,
        librarySlimmingAnalysis: (any LibrarySlimmingAnalysisJobPort)? = nil,
        librarySlimmingCommands: (any RemoteLibrarySlimmingCommandPort)? = nil,
        sourceManagementCommands: (any RemoteSourceManagementCommandPort)? = nil,
        storageMaintenanceCommands: (any RemoteStorageMaintenanceCommandPort)? = nil,
        generalSettingsCommands: (any RemoteGeneralSettingsCommandPort)? = nil,
        workspaceNotices: (any RemoteWorkspaceNoticePort)? = nil,
        idempotency: RemoteIdempotencyStore,
        hostAppVersion: String,
        listenPort: Int,
        hostID: UUID? = nil,
        usesTLS: Bool = false,
        certificateFingerprintSHA256: String? = nil
    ) {
        self.catalog = catalog
        self.review = review
        self.trainingWorkspace = trainingWorkspace
        self.trainingCommands = trainingCommands
        self.librarySlimmingAnalysis = librarySlimmingAnalysis
        self.librarySlimmingCommands = librarySlimmingCommands
        self.sourceManagementCommands = sourceManagementCommands
        self.storageMaintenanceCommands = storageMaintenanceCommands
        self.generalSettingsCommands = generalSettingsCommands
        self.workspaceNotices = workspaceNotices
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

    func fetchWorkspaceNotice() async -> RemoteWorkspaceNoticeSnapshot {
        let notice = await workspaceNotices?.currentWorkspaceNotice()
        return RemoteWorkspaceNoticeSnapshot(notice: notice.map(Self.mapWorkspaceNotice))
    }

    func dismissWorkspaceNotice(
        _ request: RemoteWorkspaceNoticeDismissRequest
    ) async -> RemoteWorkspaceNoticeDismissResponse {
        let dismissed = await workspaceNotices?.dismissWorkspaceNotice(
            noticeID: request.noticeID
        ) ?? false
        let notice = await workspaceNotices?.currentWorkspaceNotice()
        return RemoteWorkspaceNoticeDismissResponse(
            dismissed: dismissed,
            notice: notice.map(Self.mapWorkspaceNotice)
        )
    }

    func performWorkspaceNoticeAction(
        _ request: RemoteWorkspaceNoticeActionRequest
    ) async -> RemoteWorkspaceNoticeActionResponse {
        let performed = await workspaceNotices?.performWorkspaceNoticeAction(
            noticeID: request.noticeID,
            actionID: request.actionID
        ) ?? false
        let notice = await workspaceNotices?.currentWorkspaceNotice()
        return RemoteWorkspaceNoticeActionResponse(
            performed: performed,
            notice: notice.map(Self.mapWorkspaceNotice)
        )
    }

    private static func mapWorkspaceNotice(
        _ notice: WorkspaceNoticeProjection
    ) -> RemoteWorkspaceNotice {
        RemoteWorkspaceNotice(
            id: notice.id,
            severity: RemoteWorkspaceNoticeSeverity(rawValue: notice.severity.rawValue) ?? .warning,
            message: notice.message,
            actions: notice.actions.map { action in
                let kind: RemoteWorkspaceNoticeActionKind
                switch action.kind {
                case .undoTagMutation: kind = .undoTagMutation
                case .openRecycleBin: kind = .openRecycleBin
                }
                return RemoteWorkspaceNoticeAction(
                    id: action.id,
                    kind: kind,
                    title: action.title,
                    sourceID: action.sourceID
                )
            }
        )
    }

    func fetchGeneralSettings() async throws -> RemoteGeneralSettingsSnapshot {
        guard let generalSettingsCommands else {
            throw RemoteAPIError(code: .notFound, message: "通用设置当前不可用")
        }
        return Self.mapGeneralSettings(try await generalSettingsCommands.snapshot())
    }

    func updateGeneralSettings(
        _ request: RemoteGeneralSettingsUpdateRequest
    ) async throws -> RemoteGeneralSettingsUpdateResponse {
        guard let generalSettingsCommands else {
            throw RemoteAPIError(code: .notFound, message: "通用设置当前不可用")
        }
        var subjectParts: [String] = []
        subjectParts.append(request.modelEnabled.map { String($0) } ?? "-")
        subjectParts.append(request.idleThumbnailPrewarmEnabled.map { String($0) } ?? "-")
        subjectParts.append(request.toolbarDisplayMode?.rawValue ?? "-")
        subjectParts.append(request.maxPendingSuggestionsPerTag.map(String.init) ?? "-")
        let thresholdMutation = request.suggestionThresholdMutation
        subjectParts.append(thresholdMutation?.action.rawValue ?? "-")
        subjectParts.append(thresholdMutation?.method.rawValue ?? "-")
        subjectParts.append(thresholdMutation?.tagID?.uuidString.lowercased() ?? "-")
        subjectParts.append(thresholdMutation.map { mutation in
            mutation.minScore.map { String($0) } ?? "-"
        } ?? "-")
        let subject = subjectParts.joined(separator: "|")
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "generalSettings",
            subject: subject,
            assetIDs: [],
            action: "update"
        )
        do {
            if let prior: RemoteGeneralSettingsUpdateResponse = try await idempotency.replay(
                operationID: request.operationID,
                key: key
            ) {
                return RemoteGeneralSettingsUpdateResponse(
                    settings: prior.settings,
                    replayed: true
                )
            }
            let updated = try await generalSettingsCommands.update(
                GeneralSettingsUpdate(
                    modelEnabled: request.modelEnabled,
                    idleThumbnailPrewarmEnabled: request.idleThumbnailPrewarmEnabled,
                    toolbarDisplayMode: request.toolbarDisplayMode.map(Self.mapToolbarDisplayMode),
                    suggestionThresholdMutation: request.suggestionThresholdMutation.map {
                        GeneralSettingsSuggestionMutation(
                            action: Self.mapSuggestionMutationAction($0.action),
                            method: Self.mapSuggestionMethod($0.method),
                            tagID: $0.tagID,
                            minScore: $0.minScore
                        )
                    },
                    maxPendingSuggestionsPerTag: request.maxPendingSuggestionsPerTag
                )
            )
            let response = RemoteGeneralSettingsUpdateResponse(
                settings: Self.mapGeneralSettings(updated),
                replayed: false
            )
            try await idempotency.record(
                operationID: request.operationID,
                key: key,
                response: response
            )
            return response
        } catch GeneralSettingsCommandError.emptyUpdate {
            throw RemoteAPIError(code: .badRequest, message: "至少需要修改一项设置")
        } catch GeneralSettingsCommandError.invalidSuggestionMutation {
            throw RemoteAPIError(code: .badRequest, message: "建议阈值操作缺少必要参数")
        } catch GeneralSettingsCommandError.unavailable {
            throw RemoteAPIError(code: .notFound, message: "建议阈值当前不可用")
        } catch RemoteIdempotencyStore.IdempotencyError.conflict {
            throw RemoteAPIError(code: .conflict, message: "operationID 已用于不同设置操作")
        } catch let error as RemoteAPIError {
            throw error
        } catch {
            throw RemoteAPIError(code: .internalError, message: "通用设置更新失败")
        }
    }

    func fetchSources() throws -> [RemoteSourceSummary] {
        try catalog.fetchSources().map(Self.mapSource)
    }

    func fetchSourceManagement() async throws -> RemoteSourceManagementSnapshot {
        guard let sourceManagementCommands else {
            throw RemoteAPIError(code: .notFound, message: "来源管理当前不可用")
        }
        let snapshot = try await sourceManagementCommands.snapshot()
        return RemoteSourceManagementSnapshot(
            sources: snapshot.sources.map(Self.mapSource),
            canConnectPhotos: !snapshot.sources.contains(where: { $0.kind == .photos }),
            requests: snapshot.requests.map(Self.mapSourceManagementRequest)
        )
    }

    func submitSourceManagement(
        _ request: RemoteSourceManagementSubmitRequest
    ) async throws -> RemoteSourceManagementRequestSnapshot {
        guard let sourceManagementCommands else {
            throw RemoteAPIError(code: .notFound, message: "来源管理当前不可用")
        }
        do {
            return Self.mapSourceManagementRequest(
                try await sourceManagementCommands.submit(
                    SourceManagementCommandRequest(
                        operationID: request.operationID,
                        action: Self.mapSourceManagementAction(request.action),
                        sourceID: request.sourceID
                    )
                )
            )
        } catch SourceManagementCommandError.sourceNotFound {
            throw RemoteAPIError(code: .notFound, message: "来源不存在")
        } catch SourceManagementCommandError.invalidAction {
            throw RemoteAPIError(code: .badRequest, message: "当前来源状态不允许该操作")
        } catch SourceManagementCommandError.operationConflict {
            throw RemoteAPIError(code: .conflict, message: "operationID 已用于不同来源操作")
        } catch {
            throw RemoteAPIError(code: .internalError, message: "来源管理请求失败")
        }
    }

    func fetchStorageMaintenance() async throws -> RemoteStorageMaintenanceSnapshot {
        guard let storageMaintenanceCommands else {
            throw RemoteAPIError(code: .notFound, message: "存储维护当前不可用")
        }
        return Self.mapStorageMaintenanceSnapshot(
            try await storageMaintenanceCommands.snapshot()
        )
    }

    func submitStorageMaintenance(
        _ request: RemoteStorageMaintenanceSubmitRequest
    ) async throws -> RemoteStorageMaintenanceRequestSnapshot {
        guard let storageMaintenanceCommands else {
            throw RemoteAPIError(code: .notFound, message: "存储维护当前不可用")
        }
        do {
            return Self.mapStorageMaintenanceRequest(
                try await storageMaintenanceCommands.submit(
                    StorageMaintenanceCommandRequest(
                        operationID: request.operationID,
                        action: Self.mapStorageMaintenanceAction(request.action)
                    )
                )
            )
        } catch StorageMaintenanceCommandError.invalidAction {
            throw RemoteAPIError(code: .conflict, message: "另一项存储操作正在等待或执行")
        } catch StorageMaintenanceCommandError.operationConflict {
            throw RemoteAPIError(code: .conflict, message: "operationID 已用于不同存储操作")
        } catch {
            throw RemoteAPIError(code: .internalError, message: "存储维护请求失败")
        }
    }

    func fetchTags() throws -> [RemoteTagSummary] {
        try catalog.listTags().map(Self.mapTag)
    }

    func fetchTagGroups() throws -> [RemoteTagGroupSummary] {
        try catalog.listTagGroups().map(Self.mapTagGroup)
    }

    func installPresetTags(
        _ request: RemoteInstallPresetTagsRequest
    ) async throws -> RemoteInstallPresetTagsResponse {
        let catalog = self.catalog
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "installPresetTags",
            subject: "starter-v1",
            assetIDs: [],
            action: "install"
        )
        do {
            let (createdTags, replayed): ([RemoteTagSummary], Bool) = try await idempotency.perform(
                operationID: request.operationID,
                key: key
            ) {
                try catalog.installPresetTags().createdTags.map(Self.mapTag)
            }
            return RemoteInstallPresetTagsResponse(
                operationID: request.operationID,
                createdTags: createdTags,
                replayed: replayed
            )
        } catch is RemoteIdempotencyStore.IdempotencyError {
            throw RemoteAPIError(
                code: .conflict,
                message: "operationID was already used for a different mutation"
            )
        } catch {
            throw RemoteAPIError(code: .internalError, message: "无法添加常用标签")
        }
    }

    func fetchGalleryOverview() throws -> RemoteGalleryOverviewSnapshot {
        let snapshot = try catalog.fetchGalleryOverview()
        return RemoteGalleryOverviewSnapshot(
            media: snapshot.media.map {
                RemoteGalleryOverviewMediaSummary(
                    mediaKind: $0.mediaKind == .video ? .video : .image,
                    totalCount: $0.totalCount,
                    exactUniqueCount: $0.exactUniqueCount,
                    exactRedundantCount: $0.exactRedundantCount,
                    exactFingerprintCount: $0.exactFingerprintCount
                )
            },
            sources: snapshot.sources.map {
                RemoteGalleryOverviewSourceSummary(
                    id: $0.sourceID,
                    displayName: $0.displayName,
                    kind: $0.kind == .photos ? .photos : .folder,
                    state: Self.mapSourceState($0.state),
                    imageCount: $0.imageCount,
                    videoCount: $0.videoCount
                )
            },
            positiveTags: snapshot.positiveTags.map {
                RemoteGalleryOverviewTagSummary(
                    id: $0.tagID,
                    displayName: $0.displayName,
                    imageCount: $0.imageCount,
                    videoCount: $0.videoCount
                )
            },
            years: snapshot.years.map {
                RemoteGalleryOverviewYearSummary(
                    year: $0.year,
                    imageCount: $0.imageCount,
                    videoCount: $0.videoCount
                )
            },
            availability: snapshot.availability.map {
                RemoteGalleryOverviewAvailabilitySummary(
                    availability: Self.mapAvailability($0.availability),
                    imageCount: $0.imageCount,
                    videoCount: $0.videoCount
                )
            },
            undatedCount: snapshot.undatedCount,
            positiveLabeledAssetCount: snapshot.positiveLabeledAssetCount,
            acceptedDecisionCount: snapshot.acceptedDecisionCount,
            favorites: snapshot.favorites.map {
                RemoteGalleryOverviewFavoriteSummary(
                    mediaKind: $0.mediaKind == .video ? .video : .image,
                    count: $0.count
                )
            }
        )
    }

    func fetchAssets(_ request: RemoteAssetPageRequest) throws -> RemoteAssetPage {
        let limit = max(1, min(request.limit, 200))
        let cursor = try Self.decodeCursor(request.cursor)
        let page: AssetPageResult
        do {
            page = try catalog.fetchAssetPage(
                filter: Self.mapAssetFilter(request),
                sort: Self.mapSort(request.sort),
                cursor: cursor,
                limit: limit
            )
        } catch CatalogQueryError.invalidSpatialFilter {
            throw RemoteAPIError(code: .badRequest, message: "地点图库范围无效")
        }
        let favoriteStates = try catalog.fetchFavoriteStates(
            assetIDs: page.items.map(\.assetID)
        )
        return RemoteAssetPage(
            items: page.items.map {
                Self.mapAsset(
                    $0,
                    favorite: favoriteStates[$0.assetID]
                        ?? .none(assetID: $0.assetID)
                )
            },
            nextCursor: try Self.encodeCursor(page.nextCursor)
        )
    }

    func loadThumbnail(
        assetID: UUID,
        targetPixelWidth: Int,
        originalAspect: Bool = false
    ) async throws -> Data {
        _ = targetPixelWidth // R0: advisory only; existing port has no size parameter.
        if originalAspect,
           let cached = try? await catalog.loadOriginalAspectThumbnailIfCached(assetID: assetID)
        {
            return cached
        }
        return try await catalog.loadThumbnail(assetID: assetID)
    }

    func loadPreview(assetID: UUID) async throws -> Data {
        do {
            return try await catalog.loadPreview(assetID: assetID)
        } catch PhotosLibraryError.cloudOnly {
            throw RemoteAPIError(
                code: .conflict,
                message: "cloud preview required"
            )
        } catch let error as RemoteAPIError {
            throw error
        } catch {
            throw RemoteAPIError(code: .notFound, message: "preview unavailable")
        }
    }

    func downloadCloudPreview(assetID: UUID) async throws -> Data {
        try await downloadCloudPreview(assetID: assetID, onProgress: { _ in })
    }

    func downloadCloudPreview(
        assetID: UUID,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        do {
            return try await catalog.downloadCloudPreview(
                assetID: assetID,
                onProgress: onProgress
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch PhotosLibraryError.authorizationDenied,
                PhotosLibraryError.authorizationRestricted {
            throw RemoteAPIError(code: .unauthorized, message: "Photos access is unavailable")
        } catch PhotosLibraryError.libraryUnavailable {
            throw RemoteAPIError(code: .notFound, message: "cloud preview unavailable")
        } catch PhotosLibraryError.cloudOnly,
                PhotosLibraryError.changeTokenInvalid,
                PhotosLibraryError.persistenceFailure {
            throw RemoteAPIError(code: .internalError, message: "cloud preview download failed")
        } catch let error as RemoteAPIError {
            throw error
        } catch {
            throw RemoteAPIError(code: .internalError, message: "cloud preview download failed")
        }
    }

    func fetchInspectorDetail(assetID: UUID) throws -> RemoteAssetDetail {
        let detail = try catalog.fetchInspectorDetail(assetID: assetID)
        let pendingSuggestions = try review.pendingSuggestionsForAsset(assetID: assetID)
        let favorite = try catalog.fetchFavoriteStates(assetIDs: [assetID])[assetID]
            ?? .none(assetID: assetID)
        return Self.mapDetail(
            detail,
            pendingSuggestions: pendingSuggestions,
            favorite: favorite
        )
    }

    func analyzeAssetLocalSuggestions(
        assetID: UUID,
        request: RemoteAssetLocalSuggestionRequest
    ) async throws -> RemoteAssetLocalSuggestionResponse {
        guard let trainingCommands else {
            throw RemoteAPIError(code: .notFound, message: "当前 Mac 未提供单张本地模型预览")
        }
        do {
            let snapshot = try await trainingCommands.assetLocalSuggestions(
                AssetLocalSuggestionCommand(
                    operationID: request.operationID,
                    assetID: assetID,
                    track: request.track == .standard ? .standard : .personal
                )
            )
            return RemoteAssetLocalSuggestionResponse(
                operationID: snapshot.operationID,
                assetID: snapshot.assetID,
                track: snapshot.track == .standard ? .standard : .personal,
                state: {
                    switch snapshot.state {
                    case .results: .results
                    case .previewUnavailable: .previewUnavailable
                    case .personalUnavailable: .personalUnavailable
                    case .serviceUnavailable: .serviceUnavailable
                    case .failed: .failed
                    }
                }(),
                suggestions: snapshot.suggestions.map { suggestion in
                    RemoteAssetLocalSuggestion(
                        id: suggestion.id,
                        track: suggestion.track == .standard ? .standard : .personal,
                        tagID: suggestion.tagID,
                        displayName: suggestion.displayName,
                        recommendation: suggestion.recommendation == .autoAssigned
                            ? .autoAssigned
                            : .suggested
                    )
                },
                replayed: snapshot.replayed
            )
        } catch {
            throw Self.mapAssetLocalSuggestionError(error)
        }
    }

    func setFavorite(
        _ request: RemoteFavoriteMutationRequest
    ) async throws -> RemoteFavoriteMutationResponse {
        guard !request.assetIDs.isEmpty else {
            throw RemoteAPIError(code: .badRequest, message: "assetIDs must not be empty")
        }
        guard Set(request.assetIDs).count == request.assetIDs.count else {
            throw RemoteAPIError(code: .badRequest, message: "assetIDs must not contain duplicates")
        }
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "favoriteMutation",
            subject: "favorites",
            assetIDs: request.assetIDs,
            action: request.isFavorite ? "favorite" : "unfavorite"
        )
        let catalog = self.catalog
        do {
            let (stored, replayed): (RemoteFavoriteMutationResponse, Bool) =
                try await idempotency.perform(
                    operationID: request.operationID,
                    key: key
                ) {
                    let summary = try catalog.setFavorite(
                        assetIDs: request.assetIDs,
                        isFavorite: request.isFavorite
                    )
                    let states = try catalog.fetchFavoriteStates(assetIDs: request.assetIDs)
                    return RemoteFavoriteMutationResponse(
                        operationID: request.operationID,
                        changedCount: summary.changedCount,
                        localOnlyCount: summary.localOnlyCount,
                        syncedCount: summary.syncedCount,
                        pendingCount: summary.pendingCount,
                        failedCount: summary.failedCount,
                        states: request.assetIDs.map {
                            Self.mapFavorite(
                                states[$0] ?? .none(assetID: $0)
                            )
                        },
                        replayed: false
                    )
                }
            return RemoteFavoriteMutationResponse(
                operationID: stored.operationID,
                changedCount: stored.changedCount,
                localOnlyCount: stored.localOnlyCount,
                syncedCount: stored.syncedCount,
                pendingCount: stored.pendingCount,
                failedCount: stored.failedCount,
                states: stored.states,
                replayed: replayed
            )
        } catch is RemoteIdempotencyStore.IdempotencyError {
            throw RemoteAPIError(
                code: .conflict,
                message: "operationID was already used for a different mutation"
            )
        }
    }

    func retryFavoriteSync(
        _ request: RemoteFavoriteSyncRetryRequest
    ) async throws -> RemoteFavoriteSyncRetryResponse {
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "favoriteSyncRetry",
            subject: "favorites",
            assetIDs: [],
            action: "retry"
        )
        let catalog = self.catalog
        do {
            let (stored, replayed): (RemoteFavoriteSyncRetryResponse, Bool) =
                try await idempotency.perform(operationID: request.operationID, key: key) {
                    let summary = try catalog.retryPendingFavoriteSync(sourceIDs: nil)
                    return RemoteFavoriteSyncRetryResponse(
                        operationID: request.operationID,
                        localOnlyCount: summary.localOnlyCount,
                        syncedCount: summary.syncedCount,
                        pendingCount: summary.pendingCount,
                        failedCount: summary.failedCount,
                        replayed: false
                    )
                }
            return RemoteFavoriteSyncRetryResponse(
                operationID: stored.operationID,
                localOnlyCount: stored.localOnlyCount,
                syncedCount: stored.syncedCount,
                pendingCount: stored.pendingCount,
                failedCount: stored.failedCount,
                replayed: replayed
            )
        } catch is RemoteIdempotencyStore.IdempotencyError {
            throw RemoteAPIError(
                code: .conflict,
                message: "operationID was already used for a different mutation"
            )
        }
    }

    func selectionAggregate(_ request: RemoteTagSelectionRequest) throws -> [RemoteTagSelectionAggregate] {
        try catalog
            .selectionAggregate(tagIDs: request.tagIDs, assetIDs: request.assetIDs)
            .map(Self.mapAggregate)
    }

    func fetchJobActivity() throws -> [RemoteJobSummary] {
        let slimmingSummaries = (try? librarySlimmingAnalysis?.listJobs()) ?? []
        let slimmingByID = Dictionary(
            uniqueKeysWithValues: slimmingSummaries.map { ($0.jobID, $0) }
        )
        let sourcesByID = Dictionary(
            uniqueKeysWithValues: ((try? catalog.fetchSources()) ?? []).map { ($0.id, $0) }
        )
        return try catalog.fetchJobActivity().map {
            Self.mapJob(
                $0,
                source: $0.sourceID.flatMap { sourcesByID[$0] },
                librarySlimmingSummary: slimmingByID[$0.id]
            )
        }
    }

    func fetchWorldMapSnapshot(
        bounds: RemoteWorldMapBounds?,
        maximumClusters: Int = 2_000
    ) throws -> RemoteWorldMapSnapshot {
        let query = WorldMapCatalogQuery(
            bounds: bounds.map(Self.mapWorldMapBounds),
            maximumClusters: max(1, min(maximumClusters, WorldMapCatalogQuery.maximumClusterLimit))
        )
        do {
            let snapshot = try catalog.fetchWorldMapSnapshot(query: query)
            return RemoteWorldMapSnapshot(
                clusters: snapshot.clusters.map(Self.mapWorldMapCluster),
                eligiblePhotoCount: snapshot.eligiblePhotoCount,
                locatedPhotoCount: snapshot.locatedPhotoCount,
                unlocatedPhotoCount: snapshot.unlocatedPhotoCount
            )
        } catch WorldMapCatalogError.invalidQuery {
            throw RemoteAPIError(code: .badRequest, message: "地图视口参数无效")
        } catch {
            throw RemoteAPIError(code: .internalError, message: "世界地图目录查询失败")
        }
    }

    func fetchWorldMapSelection(
        _ request: RemoteWorldMapSelectionRequest
    ) throws -> RemoteWorldMapSelection {
        do {
            let selection = try catalog.fetchWorldMapSelection(
                query: Self.mapWorldMapSelectionQuery(request.query)
            )
            let favoriteStates = try catalog.fetchFavoriteStates(
                assetIDs: selection.assets.map(\.assetID)
            )
            let assets = selection.assets.map { asset -> RemoteWorldMapAsset in
                do {
                    let detail = try catalog.fetchInspectorDetail(assetID: asset.assetID)
                    return RemoteWorldMapAsset(
                        id: asset.assetID,
                        fileName: asset.fileName,
                        availability: Self.mapAvailability(detail.availability),
                        contentRevision: detail.contentRevision,
                        favorite: favoriteStates[asset.assetID].map(Self.mapFavorite)
                    )
                } catch {
                    return RemoteWorldMapAsset(
                        id: asset.assetID,
                        fileName: asset.fileName,
                        availability: .missing,
                        contentRevision: 0,
                        favorite: favoriteStates[asset.assetID].map(Self.mapFavorite)
                    )
                }
            }
            return RemoteWorldMapSelection(
                assets: assets,
                totalPhotoCount: selection.totalPhotoCount
            )
        } catch WorldMapCatalogError.invalidQuery {
            throw RemoteAPIError(code: .badRequest, message: "地点范围参数无效")
        } catch {
            throw RemoteAPIError(code: .internalError, message: "地点照片查询失败")
        }
    }

    func fetchWorldMapLocationBackfillSnapshots() throws
        -> [RemoteWorldMapLocationBackfillSnapshot]
    {
        do {
            return try catalog.fetchWorldMapLocationBackfillSnapshots().map(
                Self.mapWorldMapLocationBackfillSnapshot
            )
        } catch {
            throw RemoteAPIError(code: .internalError, message: "位置目录状态读取失败")
        }
    }

    func submitWorldMapLocationBackfillCommand(
        _ request: RemoteWorldMapLocationBackfillCommandRequest
    ) async throws -> RemoteWorldMapLocationBackfillCommandResponse {
        let catalog = self.catalog
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "worldMapLocationBackfill",
            subject: request.sourceID.uuidString.lowercased(),
            assetIDs: [],
            action: request.action.rawValue
        )
        do {
            let (snapshot, replayed): (RemoteWorldMapLocationBackfillSnapshot, Bool) =
                try await idempotency.perform(operationID: request.operationID, key: key) {
                    switch request.action {
                    case .start:
                        try catalog.startWorldMapLocationBackfill(sourceID: request.sourceID)
                    case .cancel:
                        try catalog.cancelWorldMapLocationBackfill(sourceID: request.sourceID)
                    }
                    guard let snapshot = try catalog
                        .fetchWorldMapLocationBackfillSnapshots()
                        .first(where: { $0.sourceID == request.sourceID })
                    else {
                        throw ProductionLibraryWorkspaceError
                            .worldMapLocationBackfillSourceUnavailable
                    }
                    if request.action == .start {
                        Task.detached(priority: .utility) {
                            try? catalog.runPendingWorldMapLocationBackfill(
                                sourceID: request.sourceID,
                                sourceKind: snapshot.sourceKind
                            )
                        }
                    }
                    return Self.mapWorldMapLocationBackfillSnapshot(snapshot)
                }
            return RemoteWorldMapLocationBackfillCommandResponse(
                operationID: request.operationID,
                snapshot: snapshot,
                replayed: replayed
            )
        } catch ProductionLibraryWorkspaceError.worldMapLocationBackfillSourceUnavailable,
                CatalogQueryError.notFound {
            throw RemoteAPIError(code: .notFound, message: "照片来源当前不可用")
        } catch RemoteIdempotencyStore.IdempotencyError.conflict {
            throw RemoteAPIError(code: .conflict, message: "operationID 已用于不同的位置目录操作")
        } catch let error as RemoteAPIError {
            throw error
        } catch {
            throw RemoteAPIError(code: .internalError, message: "位置目录操作提交失败")
        }
    }

    func fetchWorldMapPlaceTagSnapshot() throws -> RemoteWorldMapPlaceTagSnapshot {
        do {
            return RemoteWorldMapPlaceTagSnapshot(
                items: try catalog.fetchWorldMapPlaceTagResolutions().map(
                    Self.mapWorldMapPlaceTagResolution
                ),
                maximumQueryLength: WorldMapPlaceSearchPolicy.maximumQueryLength
            )
        } catch {
            throw RemoteAPIError(code: .internalError, message: "地点标签缓存读取失败")
        }
    }

    func submitWorldMapPlaceTagCommand(
        _ request: RemoteWorldMapPlaceTagCommandRequest
    ) async throws -> RemoteWorldMapPlaceTagCommandResponse {
        let normalizedSubject: String
        switch request.action {
        case .search:
            guard request.placeID == nil, let query = request.query else {
                throw RemoteAPIError(code: .badRequest, message: "地点搜索缺少描述")
            }
            let normalizedQuery = query
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            guard !normalizedQuery.isEmpty,
                  normalizedQuery.count <= WorldMapPlaceSearchPolicy.maximumQueryLength
            else {
                throw RemoteAPIError(code: .badRequest, message: "地点描述长度无效")
            }
            normalizedSubject = normalizedQuery
        case .confirm:
            guard request.query == nil,
                  let placeID = request.placeID?.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ),
                  !placeID.isEmpty
            else {
                throw RemoteAPIError(code: .badRequest, message: "地点确认缺少候选")
            }
            normalizedSubject = placeID
        }

        let key = RemoteIdempotencyStore.MutationKey(
            kind: "worldMapPlaceTag",
            subject: "\(request.tagID.uuidString.lowercased())|\(Self.sha256Hex(normalizedSubject))",
            assetIDs: [],
            action: request.action.rawValue
        )
        do {
            if let prior: RemoteWorldMapPlaceTagCommandResponse = try await idempotency.replay(
                operationID: request.operationID,
                key: key
            ) {
                return RemoteWorldMapPlaceTagCommandResponse(
                    operationID: prior.operationID,
                    resolution: prior.resolution,
                    replayed: true
                )
            }

            let resolution: WorldMapPlaceTagResolution
            switch request.action {
            case .search:
                resolution = try await catalog.searchWorldMapPlaceTag(
                    tagID: request.tagID,
                    query: normalizedSubject
                )
            case .confirm:
                resolution = try catalog.confirmWorldMapPlaceCandidate(
                    tagID: request.tagID,
                    placeID: normalizedSubject
                )
            }
            let response = RemoteWorldMapPlaceTagCommandResponse(
                operationID: request.operationID,
                resolution: Self.mapWorldMapPlaceTagResolution(resolution),
                replayed: false
            )
            try await idempotency.record(
                operationID: request.operationID,
                key: key,
                response: response
            )
            return response
        } catch WorldMapPlaceResolutionError.tagUnavailable,
                CatalogQueryError.notFound {
            throw RemoteAPIError(code: .notFound, message: "地点标签当前不可用")
        } catch WorldMapPlaceResolutionError.invalidQuery {
            throw RemoteAPIError(code: .badRequest, message: "地点描述长度无效")
        } catch WorldMapPlaceResolutionError.candidateUnavailable,
                WorldMapPlaceResolutionError.invalidCandidate {
            throw RemoteAPIError(code: .conflict, message: "地点候选已变化，请重新搜索")
        } catch WorldMapPlaceResolutionError.resolverFailed {
            throw RemoteAPIError(code: .internalError, message: "地点搜索服务暂时不可用")
        } catch RemoteIdempotencyStore.IdempotencyError.conflict {
            throw RemoteAPIError(code: .conflict, message: "operationID 已用于不同的地点标签操作")
        } catch let error as RemoteAPIError {
            throw error
        } catch {
            throw RemoteAPIError(code: .internalError, message: "地点标签操作失败")
        }
    }

    func fetchTrainingWorkspace(
        mediaKind: RemoteAssetMediaKind,
        method: RemoteTrainingRunMethod?
    ) async throws -> RemoteTrainingWorkspaceSnapshot {
        guard let trainingWorkspace else {
            throw RemoteAPIError(code: .notFound, message: "训练工程当前不可用")
        }
        let snapshot = try trainingWorkspace.snapshot(
            mediaKind: Self.mapMediaKind(mediaKind),
            method: method.map(Self.mapTrainingMethod),
            limit: 200
        )
        let activities = await trainingCommands?.activities(
            mediaKind: Self.mapMediaKind(mediaKind)
        ) ?? []
        let tagNamesByID = ((try? catalog.listTagsIncludingArchived()) ?? [])
            .reduce(into: [UUID: String]()) { names, tag in
                names[tag.id] = tag.displayName
            }
        return RemoteTrainingWorkspaceSnapshot(
            mediaKind: mediaKind,
            methodFilter: method,
            runs: snapshot.runs.map { run in
                Self.mapTrainingRun(
                    run,
                    tagDisplayName: run.tagID.flatMap { tagNamesByID[$0] }
                )
            },
            slots: snapshot.slots.map(Self.mapTrainingSlot),
            activities: activities.map(Self.mapTrainingActivity)
        )
    }

    func fetchTrainingSetup(
        mediaKind: RemoteAssetMediaKind
    ) async throws -> RemoteTrainingSetupSnapshot {
        guard let trainingCommands else {
            throw RemoteAPIError(code: .notFound, message: "训练任务当前不可用")
        }
        do {
            let setup = try await trainingCommands.setup(
                mediaKind: Self.mapMediaKind(mediaKind)
            )
            return RemoteTrainingSetupSnapshot(
                mediaKind: mediaKind,
                tags: setup.tags.map {
                    RemoteTrainingTagOption(
                        id: $0.id,
                        displayName: $0.displayName,
                        acceptedSampleCount: $0.acceptedSampleCount,
                        rejectedSampleCount: $0.rejectedSampleCount,
                        featureMode: $0.featureMode.map {
                            $0 == .update ? .update : .generate
                        },
                        personalEligible: $0.personalEligible
                    )
                },
                sources: setup.sources.map {
                    RemoteTrainingSourceOption(id: $0.id, displayName: $0.displayName)
                },
                methods: [
                    RemoteTrainingMethodAvailability(method: .featureKnn, isAvailable: true),
                    RemoteTrainingMethodAvailability(
                        method: .personalCentroid,
                        isAvailable: setup.supportsPersonalCentroid
                    ),
                    RemoteTrainingMethodAvailability(
                        method: .personalAdamW,
                        isAvailable: setup.supportsPersonalAdamW
                    ),
                ]
            )
        } catch {
            throw Self.mapTrainingCommandError(error)
        }
    }

    func fetchLibrarySlimmingWorkspace(
        mediaKind: RemoteAssetMediaKind,
        jobID: UUID?,
        clusterID: UUID?,
        clusterScope: RemoteLibrarySlimmingClusterScope = .pending,
        jobLimit: Int = 100,
        clusterLimit: Int = 80,
        memberLimit: Int = 200
    ) async throws -> RemoteLibrarySlimmingWorkspaceSnapshot {
        guard let librarySlimmingAnalysis else {
            throw RemoteAPIError(code: .notFound, message: "图库瘦身当前不可用")
        }
        let mappedMediaKind = Self.mapMediaKind(mediaKind)
        let summaries = try librarySlimmingAnalysis.listJobs(mediaKind: mappedMediaKind)
        let selectedSummary = jobID.flatMap { requested in
            summaries.first(where: { $0.jobID == requested })
        } ?? summaries.first
        let safeJobLimit = max(1, min(jobLimit, 10_000))
        // A task/activity deep link may target a record beyond the currently loaded
        // prefix. Grow the prefix through that record so ordering and next/previous
        // navigation remain truthful instead of appending an out-of-order singleton.
        let selectedJobPosition = selectedSummary.flatMap { selected in
            summaries.firstIndex(where: { $0.jobID == selected.jobID })
        }
        let effectiveJobLimit = max(safeJobLimit, selectedJobPosition.map { $0 + 1 } ?? 0)
        let jobs = summaries.prefix(effectiveJobLimit).map(Self.mapLibrarySlimmingJob)
        guard let selectedSummary else {
            return RemoteLibrarySlimmingWorkspaceSnapshot(
                mediaKind: mediaKind,
                jobs: jobs,
                selectedJobID: nil,
                clusters: [],
                selectedClusterID: nil,
                members: [],
                pendingAnalysisCount: 0,
                analyzedAssetCount: 0,
                policyVersion: nil,
                clusterScopeCounts: RemoteLibrarySlimmingClusterScopeCounts(
                    pending: 0,
                    confirmed: 0,
                    ignored: 0
                ),
                totalJobCount: summaries.count
            )
        }

        let snapshot = try librarySlimmingAnalysis.snapshot(jobID: selectedSummary.jobID)
        let reviewDispositions = try librarySlimmingAnalysis.clusterReviewDispositions(
            jobID: selectedSummary.jobID
        )
        let resultClusters = snapshot.result?.clusters ?? []
        let seedOnlyCluster: SlimmingCluster? = if resultClusters.isEmpty,
                                                   !snapshot.seedAssetIDs.isEmpty
        {
            SlimmingCluster(
                id: NearDuplicateSceneClusterService.stableClusterID(
                    kind: .nearDuplicateScene,
                    members: snapshot.seedAssetIDs
                ),
                kind: .nearDuplicateScene,
                memberAssetIDs: snapshot.seedAssetIDs,
                representativeAssetID: snapshot.seedAssetIDs[0],
                score: 1,
                modelIdentity: .featurePrintOnly
            )
        } else {
            nil
        }
        let rawClusters = resultClusters + (seedOnlyCluster.map { [$0] } ?? [])
        let hiddenAssetIDs: Set<UUID>
        if let librarySlimmingCommands {
            hiddenAssetIDs = (try? await librarySlimmingCommands.slimmingHiddenAssetIDs(
                from: rawClusters.flatMap(\.memberAssetIDs)
            )) ?? []
        } else {
            hiddenAssetIDs = []
        }
        let resolvedClusters: [(
            cluster: SlimmingCluster,
            originalMemberCount: Int,
            isHistoricalProcessedRecord: Bool
        )] = rawClusters.compactMap { cluster in
            let originalMemberCount = cluster.memberAssetIDs.count
            let remaining = cluster.memberAssetIDs.filter { !hiddenAssetIDs.contains($0) }
            let isSeedOnlyResult = cluster.id == seedOnlyCluster?.id
            let minimumMemberCount = isSeedOnlyResult ? 1 : 2
            let disposition = reviewDispositions[cluster.id]
            guard remaining.count >= minimumMemberCount || disposition != nil else {
                return nil
            }
            let projected = SlimmingCluster(
                id: cluster.id,
                kind: cluster.kind,
                memberAssetIDs: remaining,
                representativeAssetID: remaining.contains(cluster.representativeAssetID)
                    ? cluster.representativeAssetID
                    : (remaining.first ?? cluster.representativeAssetID),
                score: cluster.score,
                modelIdentity: cluster.modelIdentity
            )
            return (
                projected,
                originalMemberCount,
                disposition != nil && remaining.count < originalMemberCount
            )
        }
        let clusterScopeCounts = RemoteLibrarySlimmingClusterScopeCounts(
            pending: resolvedClusters.lazy.filter {
                reviewDispositions[$0.cluster.id] == nil
            }.count,
            confirmed: resolvedClusters.lazy.filter {
                reviewDispositions[$0.cluster.id] == .confirmed
            }.count,
            ignored: resolvedClusters.lazy.filter {
                reviewDispositions[$0.cluster.id] == .ignored
            }.count
        )
        let scopedClusters = resolvedClusters.filter { projection in
            switch clusterScope {
            case .pending: reviewDispositions[projection.cluster.id] == nil
            case .confirmed: reviewDispositions[projection.cluster.id] == .confirmed
            case .ignored: reviewDispositions[projection.cluster.id] == .ignored
            }
        }
        let selectedCluster = clusterID.flatMap { requested in
            scopedClusters.first(where: { $0.cluster.id == requested })
        } ?? scopedClusters.first
        // Keep the initial web payload bounded while still allowing the user to
        // progressively reveal every cluster/member in an authoritative result.
        // The client grows these limits in small steps; these caps only protect
        // the Host from an accidentally unbounded query.
        let safeClusterLimit = max(1, min(clusterLimit, 10_000))
        let safeMemberLimit = max(1, min(memberLimit, 5_000))
        var visibleClusters = Array(scopedClusters.prefix(safeClusterLimit))
        if let selectedCluster,
           !visibleClusters.contains(where: {
               $0.cluster.id == selectedCluster.cluster.id
           })
        {
            visibleClusters.append(selectedCluster)
        }
        let clusters = visibleClusters.map { projection in
            Self.mapLibrarySlimmingCluster(
                projection.cluster,
                isSeedOnlyResult: projection.cluster.id == seedOnlyCluster?.id,
                reviewDisposition: reviewDispositions[projection.cluster.id],
                originalMemberCount: projection.originalMemberCount,
                isHistoricalProcessedRecord: projection.isHistoricalProcessedRecord
            )
        }
        let memberAssetIDs = selectedCluster.map {
            Array($0.cluster.memberAssetIDs.prefix(safeMemberLimit))
        } ?? []
        let favoriteStates = try catalog.fetchFavoriteStates(assetIDs: memberAssetIDs)
        let members: [RemoteLibrarySlimmingMember] = memberAssetIDs.map { assetID in
            do {
                let detail = try catalog.fetchInspectorDetail(assetID: assetID)
                return RemoteLibrarySlimmingMember(
                    id: assetID,
                    sourceID: detail.sourceID,
                    sourceName: detail.sourceDisplayName,
                    fileName: detail.fileName,
                    mediaType: detail.mediaType,
                    availability: Self.mapAvailability(detail.availability),
                    contentRevision: detail.contentRevision,
                    width: detail.width,
                    height: detail.height,
                    durationMs: detail.durationMs,
                    favorite: favoriteStates[assetID].map(Self.mapFavorite)
                )
            } catch {
                return RemoteLibrarySlimmingMember(
                    id: assetID,
                    availability: .missing,
                    favorite: favoriteStates[assetID].map(Self.mapFavorite)
                )
            }
        }
        return RemoteLibrarySlimmingWorkspaceSnapshot(
            mediaKind: mediaKind,
            jobs: jobs,
            selectedJobID: selectedSummary.jobID,
            clusters: clusters,
            selectedClusterID: selectedCluster?.cluster.id,
            members: members,
            pendingAnalysisCount: snapshot.result?.pendingAnalysisAssetIDs.count ?? 0,
            analyzedAssetCount: snapshot.result?.analyzedAssetCount ?? 0,
            policyVersion: snapshot.result?.policyVersion,
            clusterScopeCounts: clusterScopeCounts,
            totalJobCount: summaries.count
        )
    }

    func fetchLibrarySlimmingSetup(
        mediaKind: RemoteAssetMediaKind
    ) async throws -> RemoteLibrarySlimmingSetupSnapshot {
        guard let librarySlimmingCommands else {
            throw RemoteAPIError(code: .notFound, message: "图库瘦身分析当前不可用")
        }
        do {
            let setup = try await librarySlimmingCommands.setup(
                mediaKind: Self.mapMediaKind(mediaKind)
            )
            return Self.mapLibrarySlimmingSetup(setup, mediaKind: mediaKind)
        } catch {
            throw Self.mapLibrarySlimmingCommandError(error)
        }
    }

    func maintainLibrarySlimmingSources(
        _ request: RemoteLibrarySlimmingSourceMaintenanceRequest
    ) async throws -> RemoteLibrarySlimmingSourceMaintenanceResponse {
        guard let librarySlimmingCommands else {
            throw RemoteAPIError(code: .notFound, message: "图库瘦身来源维护当前不可用")
        }
        let sourceIDs = Array(Set(request.sourceIDs)).sorted(by: Self.uuidLessThan)
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "librarySlimmingSourceMaintenance",
            subject: [request.mediaKind.rawValue, sourceIDs.map(\.uuidString).joined(separator: ",")]
                .joined(separator: "|"),
            assetIDs: [],
            action: request.action.rawValue
        )
        do {
            if let prior: RemoteLibrarySlimmingSourceMaintenanceResponse = try await idempotency.replay(
                operationID: request.operationID,
                key: key
            ) {
                return RemoteLibrarySlimmingSourceMaintenanceResponse(
                    operationID: prior.operationID,
                    action: prior.action,
                    mediaKind: prior.mediaKind,
                    sourceIDs: prior.sourceIDs,
                    setup: prior.setup,
                    replayed: true
                )
            }
            let setup = try await librarySlimmingCommands.maintainSources(
                LibrarySlimmingSourceMaintenanceCommand(
                    action: request.action == .refreshCatalog
                        ? .refreshCatalog : .initializeSimilarityIndex,
                    mediaKind: Self.mapMediaKind(request.mediaKind),
                    sourceIDs: sourceIDs
                )
            )
            let response = RemoteLibrarySlimmingSourceMaintenanceResponse(
                operationID: request.operationID,
                action: request.action,
                mediaKind: request.mediaKind,
                sourceIDs: sourceIDs,
                setup: Self.mapLibrarySlimmingSetup(setup, mediaKind: request.mediaKind),
                replayed: false
            )
            try await idempotency.record(
                operationID: request.operationID,
                key: key,
                response: response
            )
            return response
        } catch {
            throw Self.mapLibrarySlimmingCommandError(error)
        }
    }

    func launchLibrarySlimming(
        _ request: RemoteLibrarySlimmingLaunchRequest
    ) async throws -> RemoteLibrarySlimmingLaunchResponse {
        guard let librarySlimmingCommands else {
            throw RemoteAPIError(code: .notFound, message: "图库瘦身分析当前不可用")
        }
        let canonicalSourceIDs = request.sourceIDs.map {
            Array(Set($0)).sorted(by: Self.uuidLessThan)
        }
        let canonicalSeedIDs = Array(Set(request.seedAssetIDs)).sorted(by: Self.uuidLessThan)
        let filterSubject = try request.filter.map { try Self.canonicalJSON($0) } ?? "none"
        let subject = [
            request.mediaKind.rawValue,
            request.mode.rawValue,
            canonicalSourceIDs?.map(\.uuidString).joined(separator: ",") ?? "all",
            filterSubject,
        ].joined(separator: "|")
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "librarySlimmingLaunch",
            subject: subject,
            assetIDs: canonicalSeedIDs,
            action: request.mode.rawValue
        )
        do {
            if let prior: RemoteLibrarySlimmingLaunchResponse = try await idempotency.replay(
                operationID: request.operationID,
                key: key
            ) {
                return RemoteLibrarySlimmingLaunchResponse(
                    operationID: prior.operationID,
                    jobID: prior.jobID,
                    acceptedAtMs: prior.acceptedAtMs,
                    memberCount: prior.memberCount,
                    replayed: true
                )
            }
            let filter = request.filter.map(Self.mapAssetFilter)
            let receipt = try await librarySlimmingCommands.launch(
                LibrarySlimmingLaunchCommand(
                    operationID: request.operationID,
                    mediaKind: Self.mapMediaKind(request.mediaKind),
                    mode: Self.mapLibrarySlimmingMode(request.mode),
                    sourceIDs: canonicalSourceIDs.map { Set($0) },
                    seedAssetIDs: Set(canonicalSeedIDs),
                    filter: filter,
                    sort: request.filter.map { Self.mapSort($0.sort) } ?? .newest
                )
            )
            let response = RemoteLibrarySlimmingLaunchResponse(
                operationID: receipt.operationID,
                jobID: receipt.jobID,
                acceptedAtMs: receipt.acceptedAtMs,
                memberCount: receipt.memberCount,
                replayed: false
            )
            try await idempotency.record(
                operationID: request.operationID,
                key: key,
                response: response
            )
            return response
        } catch {
            throw Self.mapLibrarySlimmingCommandError(error)
        }
    }

    func applyLibrarySlimmingJobAction(
        jobID: UUID,
        request: RemoteLibrarySlimmingJobActionRequest
    ) async throws -> RemoteLibrarySlimmingJobActionResponse {
        guard let librarySlimmingCommands else {
            throw RemoteAPIError(code: .notFound, message: "图库瘦身任务当前不可用")
        }
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "librarySlimmingJobAction",
            subject: jobID.uuidString.lowercased(),
            assetIDs: [],
            action: request.action.rawValue
        )
        do {
            if let prior: RemoteLibrarySlimmingJobActionResponse = try await idempotency.replay(
                operationID: request.operationID,
                key: key
            ) {
                return RemoteLibrarySlimmingJobActionResponse(
                    job: prior.job,
                    deleted: prior.deleted,
                    replayed: true
                )
            }
            let result = try await librarySlimmingCommands.apply(
                jobID: jobID,
                action: {
                    switch request.action {
                    case .pause: .pause
                    case .resume: .resume
                    case .deleteRecord: .deleteRecord
                    }
                }()
            )
            let mappedJob: RemoteLibrarySlimmingJob?
            if let snapshot = result.snapshot,
               let summary = try librarySlimmingAnalysis?
                   .listJobs()
                   .first(where: { $0.jobID == snapshot.jobID })
            {
                mappedJob = Self.mapLibrarySlimmingJob(summary)
            } else {
                mappedJob = nil
            }
            let response = RemoteLibrarySlimmingJobActionResponse(
                job: mappedJob,
                deleted: result.deleted,
                replayed: false
            )
            try await idempotency.record(
                operationID: request.operationID,
                key: key,
                response: response
            )
            return response
        } catch {
            throw Self.mapLibrarySlimmingCommandError(error)
        }
    }

    func updateLibrarySlimmingClusterReview(
        _ request: RemoteLibrarySlimmingClusterReviewRequest
    ) async throws -> RemoteLibrarySlimmingClusterReviewResponse {
        guard let librarySlimmingCommands else {
            throw RemoteAPIError(code: .notFound, message: "图库瘦身审阅当前不可用")
        }
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "librarySlimmingClusterReview",
            subject: "\(request.jobID.uuidString.lowercased()):\(request.clusterID.uuidString.lowercased())",
            assetIDs: [],
            action: request.disposition?.rawValue ?? "pending"
        )
        do {
            if let prior: RemoteLibrarySlimmingClusterReviewResponse = try await idempotency.replay(
                operationID: request.operationID,
                key: key
            ) {
                return RemoteLibrarySlimmingClusterReviewResponse(
                    operationID: prior.operationID,
                    jobID: prior.jobID,
                    clusterID: prior.clusterID,
                    disposition: prior.disposition,
                    replayed: true
                )
            }
            let disposition = try await librarySlimmingCommands.setClusterReviewDisposition(
                jobID: request.jobID,
                clusterID: request.clusterID,
                disposition: {
                    switch request.disposition {
                    case .confirmed: .confirmed
                    case .ignored: .ignored
                    case nil: nil
                    }
                }()
            )
            let response = RemoteLibrarySlimmingClusterReviewResponse(
                operationID: request.operationID,
                jobID: request.jobID,
                clusterID: request.clusterID,
                disposition: {
                    switch disposition {
                    case .confirmed: .confirmed
                    case .ignored: .ignored
                    case nil: nil
                    }
                }(),
                replayed: false
            )
            try await idempotency.record(
                operationID: request.operationID,
                key: key,
                response: response
            )
            return response
        } catch {
            throw Self.mapLibrarySlimmingCommandError(error)
        }
    }

    func updateLibrarySlimmingThresholds(
        _ request: RemoteLibrarySlimmingThresholdUpdateRequest
    ) async throws -> RemoteLibrarySlimmingThresholdUpdateResponse {
        guard let librarySlimmingCommands else {
            throw RemoteAPIError(code: .notFound, message: "图库瘦身设置当前不可用")
        }
        let subject = try Self.canonicalJSON(request.thresholds)
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "librarySlimmingThresholds",
            subject: subject,
            assetIDs: [],
            action: "update"
        )
        do {
            if let prior: RemoteLibrarySlimmingThresholdUpdateResponse = try await idempotency.replay(
                operationID: request.operationID,
                key: key
            ) {
                return RemoteLibrarySlimmingThresholdUpdateResponse(
                    thresholds: prior.thresholds,
                    replayed: true
                )
            }
            let updated = try await librarySlimmingCommands.updateThresholds(
                Self.mapLibrarySlimmingThresholds(request.thresholds)
            )
            let response = RemoteLibrarySlimmingThresholdUpdateResponse(
                thresholds: Self.mapLibrarySlimmingThresholds(updated),
                replayed: false
            )
            try await idempotency.record(
                operationID: request.operationID,
                key: key,
                response: response
            )
            return response
        } catch {
            throw Self.mapLibrarySlimmingCommandError(error)
        }
    }

    func fetchLibrarySlimmingRecycle(
        mediaKind: RemoteAssetMediaKind,
        sourceID: UUID?,
        searchText: String?,
        scope: RemoteLibrarySlimmingRecycleScope,
        limit: Int
    ) async throws -> RemoteLibrarySlimmingRecycleSnapshot {
        guard let librarySlimmingCommands else {
            throw RemoteAPIError(code: .notFound, message: "图库瘦身回收站当前不可用")
        }
        do {
            let snapshot = try await librarySlimmingCommands.recycleSnapshot(
                mediaKind: Self.mapMediaKind(mediaKind),
                sourceID: sourceID,
                searchText: searchText,
                scope: {
                    switch scope {
                    case .all: .all
                    case .photos: .photos
                    case .files: .files
                    case .attention: .attention
                    }
                }(),
                limit: limit
            )
            let favoriteStates = try catalog.fetchFavoriteStates(
                assetIDs: snapshot.entries.map(\.assetID)
            )
            return RemoteLibrarySlimmingRecycleSnapshot(
                mediaKind: mediaKind,
                entries: snapshot.entries.map { entry in
                    Self.mapLibrarySlimmingRecycleEntry(
                        entry,
                        sourceDisplayName: snapshot.sourceNames[entry.sourceID] ?? "已移除来源",
                        favorite: favoriteStates[entry.assetID]
                    )
                },
                totalCount: snapshot.totalCount,
                requests: snapshot.requests.map(Self.mapLibrarySlimmingRecycleRequest),
                scopeCounts: RemoteLibrarySlimmingRecycleScopeCounts(
                    all: snapshot.scopeCounts.all,
                    photos: snapshot.scopeCounts.photos,
                    files: snapshot.scopeCounts.files,
                    attention: snapshot.scopeCounts.attention
                )
            )
        } catch {
            throw Self.mapLibrarySlimmingCommandError(error)
        }
    }

    func submitLibrarySlimmingRecycle(
        _ request: RemoteLibrarySlimmingRecycleSubmitRequest
    ) async throws -> RemoteLibrarySlimmingRecycleRequestSnapshot {
        guard let librarySlimmingCommands else {
            throw RemoteAPIError(code: .notFound, message: "图库瘦身回收站当前不可用")
        }
        do {
            let snapshot = try await librarySlimmingCommands.submitRecycle(
                LibrarySlimmingRecycleCommandRequest(
                    operationID: request.operationID,
                    entryID: request.entryID,
                    action: {
                        switch request.action {
                        case .restore: .restore
                        case .discardPreflightFailure: .discardPreflightFailure
                        case .retryInterruptedOperation: .retryInterruptedOperation
                        case .purge: .purge
                        }
                    }()
                )
            )
            return Self.mapLibrarySlimmingRecycleRequest(snapshot)
        } catch {
            throw Self.mapLibrarySlimmingCommandError(error)
        }
    }

    func fetchLibrarySlimmingRemovals(
        mediaKind: RemoteAssetMediaKind
    ) async throws -> RemoteLibrarySlimmingRemovalSnapshot {
        guard let librarySlimmingCommands else {
            throw RemoteAPIError(code: .notFound, message: "图库瘦身批量操作当前不可用")
        }
        do {
            let snapshot = try await librarySlimmingCommands.removalSnapshot(
                mediaKind: Self.mapMediaKind(mediaKind)
            )
            return RemoteLibrarySlimmingRemovalSnapshot(
                mediaKind: mediaKind,
                requests: snapshot.requests.map(Self.mapLibrarySlimmingRemovalRequest)
            )
        } catch {
            throw Self.mapLibrarySlimmingCommandError(error)
        }
    }

    func submitLibrarySlimmingRemoval(
        _ request: RemoteLibrarySlimmingRemovalSubmitRequest
    ) async throws -> RemoteLibrarySlimmingRemovalRequestSnapshot {
        guard let librarySlimmingCommands else {
            throw RemoteAPIError(code: .notFound, message: "图库瘦身批量操作当前不可用")
        }
        do {
            let snapshot = try await librarySlimmingCommands.submitRemoval(
                LibrarySlimmingRemovalCommand(
                    operationID: request.operationID,
                    scope: request.scope == .gallerySelection
                        ? .gallerySelection
                        : .analysisCluster,
                    jobID: request.jobID,
                    clusterID: request.clusterID,
                    mediaKind: Self.mapMediaKind(request.mediaKind),
                    assetIDs: request.assetIDs,
                    mode: request.mode == .releaseSourceSpace
                        ? .releaseSourceSpace
                        : .recoverableRecycle
                )
            )
            return Self.mapLibrarySlimmingRemovalRequest(snapshot)
        } catch {
            throw Self.mapLibrarySlimmingCommandError(error)
        }
    }

    func prepareLibrarySlimmingIdenticalCleanup(
        _ request: RemoteLibrarySlimmingIdenticalCleanupPlanRequest
    ) async throws -> RemoteLibrarySlimmingIdenticalCleanupPlanSnapshot {
        guard let librarySlimmingCommands else {
            throw RemoteAPIError(code: .notFound, message: "完全相同项清理当前不可用")
        }
        do {
            let snapshot = try await librarySlimmingCommands.prepareIdenticalCleanup(
                jobID: request.jobID,
                mediaKind: Self.mapMediaKind(request.mediaKind)
            )
            return RemoteLibrarySlimmingIdenticalCleanupPlanSnapshot(
                id: snapshot.id,
                jobID: snapshot.jobID,
                mediaKind: snapshot.mediaKind == .video ? .video : .image,
                groupCount: snapshot.groupCount,
                verifiedAssetCount: snapshot.verifiedAssetCount,
                retainedAssetCount: snapshot.retainedAssetCount,
                favoriteRetainedAssetCount: snapshot.favoriteRetainedAssetCount,
                ordinaryRetainedAssetCount: snapshot.ordinaryRetainedAssetCount,
                protectedSkippedAssetCount: snapshot.protectedSkippedAssetCount,
                removalAssetCount: snapshot.removalAssetCount,
                skippedGroupCount: snapshot.skippedGroupCount,
                photosAssetCount: snapshot.photosAssetCount,
                fileAssetCount: snapshot.fileAssetCount,
                groupSizeHistogram: snapshot.groupSizeHistogram,
                preparedAtMs: snapshot.preparedAtMs
            )
        } catch {
            throw Self.mapLibrarySlimmingCommandError(error)
        }
    }

    func fetchLibrarySlimmingIdenticalCleanupRequests(
        mediaKind: RemoteAssetMediaKind
    ) async throws -> RemoteLibrarySlimmingIdenticalCleanupSnapshot {
        guard let librarySlimmingCommands else {
            throw RemoteAPIError(code: .notFound, message: "完全相同项清理当前不可用")
        }
        do {
            let snapshot = try await librarySlimmingCommands.identicalCleanupSnapshot(
                mediaKind: Self.mapMediaKind(mediaKind)
            )
            return RemoteLibrarySlimmingIdenticalCleanupSnapshot(
                mediaKind: mediaKind,
                requests: snapshot.requests.map(Self.mapLibrarySlimmingIdenticalCleanupRequest)
            )
        } catch {
            throw Self.mapLibrarySlimmingCommandError(error)
        }
    }

    func submitLibrarySlimmingIdenticalCleanup(
        _ request: RemoteLibrarySlimmingIdenticalCleanupSubmitRequest
    ) async throws -> RemoteLibrarySlimmingIdenticalCleanupRequestSnapshot {
        guard let librarySlimmingCommands else {
            throw RemoteAPIError(code: .notFound, message: "完全相同项清理当前不可用")
        }
        do {
            let snapshot = try await librarySlimmingCommands.submitIdenticalCleanup(
                LibrarySlimmingIdenticalCleanupCommand(
                    operationID: request.operationID,
                    planID: request.planID,
                    mode: request.mode == .releaseSourceSpace
                        ? .releaseSourceSpace
                        : .recoverableRecycle
                )
            )
            return Self.mapLibrarySlimmingIdenticalCleanupRequest(snapshot)
        } catch {
            throw Self.mapLibrarySlimmingCommandError(error)
        }
    }

    func launchTraining(
        _ request: RemoteTrainingLaunchRequest
    ) async throws -> RemoteTrainingLaunchResponse {
        guard let trainingCommands else {
            throw RemoteAPIError(code: .notFound, message: "训练任务当前不可用")
        }
        let canonicalTagIDs = Array(Set(request.tagIDs)).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        let canonicalSourceIDs = Array(Set(request.sourceIDs)).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        let canonicalAssetIDs = Array(Set(request.assetIDs)).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        let subject = [
            request.mediaKind.rawValue,
            request.method.rawValue,
            canonicalTagIDs.map(\.uuidString).joined(separator: ","),
            canonicalSourceIDs.map(\.uuidString).joined(separator: ","),
        ].joined(separator: "|")
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "trainingLaunch",
            subject: subject,
            assetIDs: canonicalAssetIDs,
            action: request.method.rawValue
        )
        do {
            if let prior: RemoteTrainingLaunchResponse = try await idempotency.replay(
                operationID: request.operationID,
                key: key
            ) {
                return RemoteTrainingLaunchResponse(
                    operationID: prior.operationID,
                    method: prior.method,
                    acceptedAtMs: prior.acceptedAtMs,
                    scheduledTagCount: prior.scheduledTagCount,
                    jobID: prior.jobID,
                    replayed: true
                )
            }
            let receipt = try await trainingCommands.launch(
                TrainingLaunchCommand(
                    operationID: request.operationID,
                    mediaKind: Self.mapMediaKind(request.mediaKind),
                    method: Self.mapTrainingMethod(request.method),
                    tagIDs: Set(canonicalTagIDs),
                    sourceIDs: Set(canonicalSourceIDs),
                    assetIDs: Set(canonicalAssetIDs)
                )
            )
            let response = RemoteTrainingLaunchResponse(
                operationID: receipt.operationID,
                method: Self.mapTrainingMethod(receipt.method),
                acceptedAtMs: receipt.acceptedAtMs,
                scheduledTagCount: receipt.scheduledTagCount,
                jobID: receipt.jobID,
                replayed: false
            )
            try await idempotency.record(
                operationID: request.operationID,
                key: key,
                response: response
            )
            return response
        } catch {
            throw Self.mapTrainingCommandError(error)
        }
    }

    func fetchEmbeddingPreparation(
        mediaKind: RemoteAssetMediaKind
    ) async throws -> RemoteEmbeddingPreparationSnapshot {
        guard let trainingCommands else {
            throw RemoteAPIError(code: .notFound, message: "照片特征准备当前不可用")
        }
        return RemoteEmbeddingPreparationSnapshot(
            mediaKind: mediaKind,
            isAvailable: await trainingCommands.embeddingPreparationAvailable(),
            activities: await trainingCommands.embeddingPreparationActivities(
                mediaKind: Self.mapMediaKind(mediaKind)
            ).map(Self.mapEmbeddingPreparationActivity)
        )
    }

    func submitEmbeddingPreparation(
        _ request: RemoteEmbeddingPreparationRequest
    ) async throws -> RemoteEmbeddingPreparationResponse {
        guard let trainingCommands else {
            throw RemoteAPIError(code: .notFound, message: "照片特征准备当前不可用")
        }
        let canonicalAssetIDs = Set(request.assetIDs)
        guard canonicalAssetIDs.count == request.assetIDs.count else {
            throw RemoteAPIError(code: .badRequest, message: "所选项目包含重复项")
        }
        do {
            let receipt = try await trainingCommands.prepareEmbeddings(
                EmbeddingPreparationCommand(
                    operationID: request.operationID,
                    mediaKind: Self.mapMediaKind(request.mediaKind),
                    assetIDs: canonicalAssetIDs
                )
            )
            return RemoteEmbeddingPreparationResponse(
                activity: Self.mapEmbeddingPreparationActivity(receipt.activity),
                replayed: receipt.replayed
            )
        } catch {
            throw Self.mapEmbeddingPreparationError(error)
        }
    }

    func applyEmbeddingPreparationAction(
        operationID: UUID,
        request: RemoteEmbeddingPreparationActionRequest
    ) async throws -> RemoteEmbeddingPreparationActionResponse {
        guard let trainingCommands else {
            throw RemoteAPIError(code: .notFound, message: "照片特征准备当前不可用")
        }
        do {
            let activity: EmbeddingPreparationActivitySnapshot
            switch request.action {
            case .cancel:
                activity = try await trainingCommands.cancelEmbeddingPreparation(
                    operationID: operationID
                )
            }
            return RemoteEmbeddingPreparationActionResponse(
                activity: Self.mapEmbeddingPreparationActivity(activity)
            )
        } catch {
            throw Self.mapEmbeddingPreparationError(error)
        }
    }

    func fetchLibrarySuggestions(
        mediaKind: RemoteAssetMediaKind,
        refreshServiceHealth: Bool
    ) async throws -> RemoteLibrarySuggestionSnapshot {
        guard let trainingCommands else {
            throw RemoteAPIError(code: .notFound, message: "全库模型建议当前不可用")
        }
        do {
            return Self.mapLibrarySuggestionSnapshot(
                try await trainingCommands.librarySuggestions(
                    mediaKind: Self.mapMediaKind(mediaKind),
                    refreshServiceHealth: refreshServiceHealth
                )
            )
        } catch {
            throw Self.mapLibrarySuggestionError(error)
        }
    }

    func submitLibrarySuggestions(
        _ request: RemoteLibrarySuggestionRequest
    ) async throws -> RemoteLibrarySuggestionResponse {
        guard let trainingCommands else {
            throw RemoteAPIError(code: .notFound, message: "全库模型建议当前不可用")
        }
        if let sourceIDs = request.sourceIDs,
           sourceIDs.isEmpty || Set(sourceIDs).count != sourceIDs.count
        {
            throw RemoteAPIError(code: .badRequest, message: "请至少选择一个且不重复的审核来源")
        }
        do {
            let receipt = try await trainingCommands.generateLibrarySuggestions(
                LibrarySuggestionCommand(
                    operationID: request.operationID,
                    mediaKind: Self.mapMediaKind(request.mediaKind),
                    track: request.track == .standard ? .standard : .personal,
                    sourceIDs: request.sourceIDs
                )
            )
            return RemoteLibrarySuggestionResponse(
                operationID: receipt.operationID,
                track: receipt.track == .standard ? .standard : .personal,
                jobID: receipt.jobID,
                replayed: receipt.replayed
            )
        } catch {
            throw Self.mapLibrarySuggestionError(error)
        }
    }

    func fetchSampleSuggestions(
        mediaKind: RemoteAssetMediaKind
    ) async throws -> RemoteSampleSuggestionSnapshot {
        guard let trainingCommands else {
            throw RemoteAPIError(code: .notFound, message: "个人建议抽检当前不可用")
        }
        return RemoteSampleSuggestionSnapshot(
            mediaKind: mediaKind,
            isAvailable: await trainingCommands.sampleSuggestionsAvailable(
                mediaKind: Self.mapMediaKind(mediaKind)
            ),
            maximumSampleCount: await trainingCommands.sampleSuggestionMaximumCount(),
            activities: await trainingCommands.sampleSuggestionActivities(
                mediaKind: Self.mapMediaKind(mediaKind)
            ).map(Self.mapSampleSuggestionActivity)
        )
    }

    func submitSampleSuggestions(
        _ request: RemoteSampleSuggestionRequest
    ) async throws -> RemoteSampleSuggestionResponse {
        guard let trainingCommands else {
            throw RemoteAPIError(code: .notFound, message: "个人建议抽检当前不可用")
        }
        guard Set(request.assetIDs).count == request.assetIDs.count else {
            throw RemoteAPIError(code: .badRequest, message: "所选项目包含重复项")
        }
        if let sourceIDs = request.sourceIDs {
            guard Set(sourceIDs).count == sourceIDs.count else {
                throw RemoteAPIError(code: .badRequest, message: "审核来源包含重复项")
            }
            guard request.assetIDs.isEmpty else {
                throw RemoteAPIError(code: .badRequest, message: "所选项目与审核来源不能同时提交")
            }
        }
        do {
            let receipt = try await trainingCommands.generateSampleSuggestions(
                SampleSuggestionCommand(
                    operationID: request.operationID,
                    mediaKind: Self.mapMediaKind(request.mediaKind),
                    assetIDs: request.assetIDs,
                    sourceIDs: request.sourceIDs
                )
            )
            return RemoteSampleSuggestionResponse(
                activity: Self.mapSampleSuggestionActivity(receipt.activity),
                replayed: receipt.replayed
            )
        } catch {
            throw Self.mapSampleSuggestionError(error)
        }
    }

    func applySampleSuggestionAction(
        operationID: UUID,
        request: RemoteSampleSuggestionActionRequest
    ) async throws -> RemoteSampleSuggestionActionResponse {
        guard let trainingCommands else {
            throw RemoteAPIError(code: .notFound, message: "个人建议抽检当前不可用")
        }
        do {
            let activity: SampleSuggestionActivitySnapshot
            switch request.action {
            case .cancel:
                activity = try await trainingCommands.cancelSampleSuggestions(
                    operationID: operationID
                )
            }
            return RemoteSampleSuggestionActionResponse(
                activity: Self.mapSampleSuggestionActivity(activity)
            )
        } catch {
            throw Self.mapSampleSuggestionError(error)
        }
    }

    func fetchTagLibrarySuggestions(
        mediaKind: RemoteAssetMediaKind
    ) async throws -> RemoteTagLibrarySuggestionSnapshot {
        guard let trainingCommands else {
            throw RemoteAPIError(code: .notFound, message: "按标签生成建议当前不可用")
        }
        let mappedMediaKind = Self.mapMediaKind(mediaKind)
        let tagOptions: [TagLibrarySuggestionTagOption]
        do {
            tagOptions = try await trainingCommands.tagLibrarySuggestionTagOptions(
                mediaKind: mappedMediaKind
            )
        } catch {
            throw Self.mapTagLibrarySuggestionError(error)
        }
        return RemoteTagLibrarySuggestionSnapshot(
            mediaKind: mediaKind,
            maximumPendingCount: await trainingCommands.sampleSuggestionMaximumCount(),
            personalCentroidAvailable: await trainingCommands.tagLibrarySuggestionsAvailable(
                mediaKind: mappedMediaKind,
                method: .personalCentroid
            ),
            personalAdamWAvailable: await trainingCommands.tagLibrarySuggestionsAvailable(
                mediaKind: mappedMediaKind,
                method: .personalAdamW
            ),
            tags: tagOptions.map {
                RemoteTagLibrarySuggestionTagOption(
                    tagID: $0.tagID,
                    personalEligible: $0.personalEligible,
                    personalCentroidMinScore: $0.personalCentroidMinScore,
                    personalAdamWMinScore: $0.personalAdamWMinScore
                )
            },
            activities: await trainingCommands.tagLibrarySuggestionActivities(
                mediaKind: mappedMediaKind
            ).map(Self.mapTagLibrarySuggestionActivity)
        )
    }

    func submitTagLibrarySuggestions(
        _ request: RemoteTagLibrarySuggestionRequest
    ) async throws -> RemoteTagLibrarySuggestionResponse {
        guard let trainingCommands else {
            throw RemoteAPIError(code: .notFound, message: "按标签生成建议当前不可用")
        }
        let sourceIDs = Set(request.sourceIDs)
        guard sourceIDs.count == request.sourceIDs.count else {
            throw RemoteAPIError(code: .badRequest, message: "所选来源包含重复项")
        }
        do {
            let receipt = try await trainingCommands.generateTagLibrarySuggestions(
                TagLibrarySuggestionCommand(
                    operationID: request.operationID,
                    mediaKind: Self.mapMediaKind(request.mediaKind),
                    method: Self.mapTagLibrarySuggestionMethod(request.method),
                    tagID: request.tagID,
                    sourceIDs: sourceIDs
                )
            )
            return RemoteTagLibrarySuggestionResponse(
                activity: Self.mapTagLibrarySuggestionActivity(receipt.activity),
                replayed: receipt.replayed
            )
        } catch {
            throw Self.mapTagLibrarySuggestionError(error)
        }
    }

    func applyTagLibrarySuggestionAction(
        operationID: UUID,
        request: RemoteTagLibrarySuggestionActionRequest
    ) async throws -> RemoteTagLibrarySuggestionActionResponse {
        guard let trainingCommands else {
            throw RemoteAPIError(code: .notFound, message: "按标签生成建议当前不可用")
        }
        do {
            let activity: TagLibrarySuggestionActivitySnapshot
            switch request.action {
            case .cancel:
                activity = try await trainingCommands.cancelTagLibrarySuggestions(
                    operationID: operationID
                )
            }
            return RemoteTagLibrarySuggestionActionResponse(
                activity: Self.mapTagLibrarySuggestionActivity(activity)
            )
        } catch {
            throw Self.mapTagLibrarySuggestionError(error)
        }
    }

    func applyTrainingActivityAction(
        operationID: UUID,
        request: RemoteTrainingActivityActionRequest
    ) async throws -> RemoteTrainingActivityActionResponse {
        guard let trainingCommands else {
            throw RemoteAPIError(code: .notFound, message: "训练任务当前不可用")
        }
        do {
            let activity: TrainingCommandActivitySnapshot
            switch request.action {
            case .cancel:
                activity = try await trainingCommands.cancelActivity(
                    operationID: operationID
                )
            }
            return RemoteTrainingActivityActionResponse(
                activity: Self.mapTrainingActivity(activity)
            )
        } catch {
            throw Self.mapTrainingCommandError(error)
        }
    }

    func applyJobActivityAction(
        jobID: UUID,
        request: RemoteJobActionRequest
    ) async throws {
        let item = try catalog.fetchJobActivity().first { $0.id == jobID }
        guard let item else {
            throw RemoteAPIError(code: .notFound, message: "后台任务不存在")
        }
        if item.kind == .personalizationSuggestions {
            switch request.action {
            case .pause:
                try review.pauseSuggestionJob(jobID: jobID)
            case .resume:
                try review.resumeSuggestionJob(jobID: jobID)
                await trainingCommands?.ensureSuggestionRunnerRunning()
            case .cancel:
                try review.cancelSuggestionJob(jobID: jobID)
            }
        } else {
            try catalog.applyJobActivityAction(Self.mapJobAction(request.action), jobID: jobID)
        }
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
        let favoriteStates = try catalog.fetchFavoriteStates(
            assetIDs: page.items.map(\.assetID)
        )
        return RemoteReviewQueuePage(
            items: page.items.map {
                Self.mapReviewItem($0, favorite: favoriteStates[$0.assetID])
            },
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
            undoChannel: .tag,
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
                latestTagUndo = LatestUndo(
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
                undoID: latestTagUndo?.operationID == request.operationID
                    ? latestTagUndo?.id
                    : nil
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
            undoChannel: .review,
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
        let candidate = latestTagUndo?.id == request.undoID ? latestTagUndo : nil
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
            if !replayed, latestTagUndo?.id == request.undoID {
                latestTagUndo = nil
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

    func undoReviewDecision(
        _ request: RemoteUndoReviewDecisionRequest
    ) async throws -> RemoteUndoReviewDecisionResponse {
        let candidate = latestReviewUndo?.id == request.undoID ? latestReviewUndo : nil
        let catalog = self.catalog
        let key = RemoteIdempotencyStore.MutationKey(
            kind: "undoReviewDecision",
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
                    throw RemoteAPIError(code: .notFound, message: "这次审核撤销已过期")
                }
                try catalog.restoreTagMutation(candidate.snapshot)
                return candidate.snapshot.priorStates.count
            }
            if !replayed, latestReviewUndo?.id == request.undoID {
                latestReviewUndo = nil
            }
            return RemoteUndoReviewDecisionResponse(
                operationID: request.operationID,
                restoredAssetCount: restoredAssetCount,
                replayed: replayed
            )
        } catch is RemoteIdempotencyStore.IdempotencyError {
            throw RemoteAPIError(
                code: .conflict,
                message: "operationID was already used for a different mutation"
            )
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
        undoChannel: DecisionUndoChannel,
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
                let undo = LatestUndo(
                    id: UUID(),
                    operationID: operationID,
                    snapshot: snapshot
                )
                switch undoChannel {
                case .tag:
                    latestTagUndo = undo
                case .review:
                    latestReviewUndo = undo
                }
            }
            let latestUndo = switch undoChannel {
            case .tag: latestTagUndo
            case .review: latestReviewUndo
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

    private static func mapSourceState(_ state: SourceState) -> RemoteSourceState {
        switch state {
        case .active: .active
        case .disabled: .disabled
        case .unavailable: .unavailable
        case .authorizationRequired: .authorizationRequired
        }
    }

    private static func mapSourceManagementAction(
        _ action: RemoteSourceManagementAction
    ) -> SourceManagementCommandAction {
        switch action {
        case .connectFolder: .connectFolder
        case .connectPhotos: .connectPhotos
        case .refreshAll: .refreshAll
        case .prewarmAllThumbnails: .prewarmAllThumbnails
        case .prewarmAllOriginalAspect: .prewarmAllOriginalAspect
        case .reauthorizeAll: .reauthorizeAll
        case .refreshAllFolderMutationAuthorizations: .refreshAllFolderMutationAuthorizations
        case .rebindPhotos: .rebindPhotos
        case .reauthorize: .reauthorize
        case .rescan: .rescan
        case .syncPhotos: .syncPhotos
        case .fullRepair: .fullRepair
        case .openPhotosPrivacySettings: .openPhotosPrivacySettings
        case .requestPhotosWriteAuthorization: .requestPhotosWriteAuthorization
        case .refreshFolderMutationAuthorization: .refreshFolderMutationAuthorization
        case .prewarmThumbnails: .prewarmThumbnails
        case .prewarmOriginalAspect: .prewarmOriginalAspect
        case .cancelPrewarm: .cancelPrewarm
        case .delete: .delete
        }
    }

    private static func mapSourceManagementAction(
        _ action: SourceManagementCommandAction
    ) -> RemoteSourceManagementAction {
        switch action {
        case .connectFolder: .connectFolder
        case .connectPhotos: .connectPhotos
        case .refreshAll: .refreshAll
        case .prewarmAllThumbnails: .prewarmAllThumbnails
        case .prewarmAllOriginalAspect: .prewarmAllOriginalAspect
        case .reauthorizeAll: .reauthorizeAll
        case .refreshAllFolderMutationAuthorizations: .refreshAllFolderMutationAuthorizations
        case .rebindPhotos: .rebindPhotos
        case .reauthorize: .reauthorize
        case .rescan: .rescan
        case .syncPhotos: .syncPhotos
        case .fullRepair: .fullRepair
        case .openPhotosPrivacySettings: .openPhotosPrivacySettings
        case .requestPhotosWriteAuthorization: .requestPhotosWriteAuthorization
        case .refreshFolderMutationAuthorization: .refreshFolderMutationAuthorization
        case .prewarmThumbnails: .prewarmThumbnails
        case .prewarmOriginalAspect: .prewarmOriginalAspect
        case .cancelPrewarm: .cancelPrewarm
        case .delete: .delete
        }
    }

    private static func mapSourceManagementRequest(
        _ request: SourceManagementCommandRequestSnapshot
    ) -> RemoteSourceManagementRequestSnapshot {
        RemoteSourceManagementRequestSnapshot(
            id: request.id,
            operationID: request.operationID,
            action: mapSourceManagementAction(request.action),
            sourceID: request.sourceID,
            sourceDisplayName: request.sourceDisplayName,
            phase: {
                switch request.phase {
                case .awaitingMac: .awaitingMac
                case .running: .running
                case .completed: .completed
                case .cancelled: .cancelled
                case .failed: .failed
                }
            }(),
            message: request.message,
            completedCount: request.completedCount,
            totalCount: request.totalCount,
            warmedCount: request.warmedCount,
            failedCount: request.failedCount,
            reusedCount: request.reusedCount,
            ineligibleCount: request.ineligibleCount,
            completedSourceCount: request.completedSourceCount,
            totalSourceCount: request.totalSourceCount,
            updatedAtMs: request.updatedAtMs
        )
    }

    private static func mapStorageMaintenanceAction(
        _ action: RemoteStorageMaintenanceAction
    ) -> StorageMaintenanceCommandAction {
        switch action {
        case .exportPortableData: .exportPortableData
        case .chooseExternalStorage: .chooseExternalStorage
        case .clearPreviewCache: .clearPreviewCache
        case .clearPhotosOriginals: .clearPhotosOriginals
        }
    }

    private static func mapStorageMaintenanceAction(
        _ action: StorageMaintenanceCommandAction
    ) -> RemoteStorageMaintenanceAction {
        switch action {
        case .exportPortableData: .exportPortableData
        case .chooseExternalStorage: .chooseExternalStorage
        case .clearPreviewCache: .clearPreviewCache
        case .clearPhotosOriginals: .clearPhotosOriginals
        }
    }

    private static func mapStorageMaintenanceSnapshot(
        _ snapshot: StorageMaintenanceCommandSnapshot
    ) -> RemoteStorageMaintenanceSnapshot {
        RemoteStorageMaintenanceSnapshot(
            previewCache: RemoteStorageUsageSummary(
                entryCount: snapshot.previewCache.entryCount,
                registeredBytes: snapshot.previewCache.registeredBytes
            ),
            photosOriginals: RemoteStorageUsageSummary(
                entryCount: snapshot.photosOriginals.entryCount,
                registeredBytes: snapshot.photosOriginals.registeredBytes
            ),
            appStorage: RemoteAppStorageSummary(
                kind: snapshot.appStorage.kind == .externalStorage
                    ? .externalStorage : .internalStorage,
                requiresRestart: snapshot.appStorage.requiresRestart,
                pendingExternalRootName: snapshot.appStorage.pendingExternalRootName
            ),
            requests: snapshot.requests.map(Self.mapStorageMaintenanceRequest)
        )
    }

    private static func mapStorageMaintenanceRequest(
        _ request: StorageMaintenanceCommandRequestSnapshot
    ) -> RemoteStorageMaintenanceRequestSnapshot {
        RemoteStorageMaintenanceRequestSnapshot(
            id: request.id,
            operationID: request.operationID,
            action: mapStorageMaintenanceAction(request.action),
            phase: {
                switch request.phase {
                case .awaitingMac: .awaitingMac
                case .running: .running
                case .completed: .completed
                case .cancelled: .cancelled
                case .failed: .failed
                }
            }(),
            message: request.message,
            updatedAtMs: request.updatedAtMs,
            result: request.result.map {
                RemoteStorageMaintenanceRequestResult(
                    affectedEntryCount: $0.affectedEntryCount,
                    affectedBytes: $0.affectedBytes,
                    bundleName: $0.bundleName,
                    totalRecordCount: $0.totalRecordCount,
                    requiresRestart: $0.requiresRestart,
                    partialReclaim: $0.partialReclaim
                )
            }
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

    private static func mapFavorite(_ state: MediaFavoriteState) -> RemoteAssetFavoriteState {
        let syncStatus: RemoteFavoriteSyncStatus
        switch state.syncStatus {
        case .localOnly:
            syncStatus = .localOnly
        case .synced:
            syncStatus = .synced
        case .pending:
            syncStatus = .pending
        case .failed:
            syncStatus = .failed
        }
        return RemoteAssetFavoriteState(
            assetID: state.assetID,
            isFavorite: state.isFavorite,
            photosObservedValue: state.photosObservedValue,
            syncStatus: syncStatus,
            lastErrorCode: state.lastErrorCode
        )
    }

    private static func mapAsset(
        _ item: AssetGridItemProjection,
        favorite: MediaFavoriteState
    ) -> RemoteAssetSummary {
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
            height: item.height,
            favorite: mapFavorite(favorite),
            relativePath: item.relativePath,
            mediaModifiedAtMs: item.mediaModifiedAtMs,
            durationMs: item.durationMs
        )
    }

    private static func mapDetail(
        _ detail: AssetInspectorDetail,
        pendingSuggestions: [AssetPendingSuggestion],
        favorite: MediaFavoriteState
    ) -> RemoteAssetDetail {
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
            durationMs: detail.durationMs,
            fingerprintSizeBytes: detail.fingerprintSizeBytes,
            favorite: mapFavorite(favorite),
            tags: detail.tags.map(mapInspectorTagState),
            pendingSuggestions: pendingSuggestions.map { suggestion in
                RemoteAssetPendingSuggestion(
                    tagID: suggestion.tagID,
                    displayName: suggestion.displayName,
                    suggestionOrigin: mapSuggestionOrigin(suggestion.suggestionOrigin)
                )
            }
        )
    }

    private static func mapSuggestionOrigin(
        _ origin: ReviewQueueSuggestionOrigin
    ) -> RemoteReviewSuggestionOrigin {
        switch origin {
        case .featurePrint: .featurePrint
        case .standardModel: .standardModel
        case .personalModel: .personalModel
        case .personalAdamW: .personalAdamW
        }
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

    private static func mapJob(
        _ item: JobActivityItem,
        source: LibrarySourceSummary? = nil,
        librarySlimmingSummary: LibrarySlimmingAnalysisJobSummary? = nil
    ) -> RemoteJobSummary {
        RemoteJobSummary(
            id: item.id,
            sourceID: item.sourceID,
            sourceDisplayName: source?.displayName,
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
            },
            controlRequest: {
                switch item.controlRequest {
                case .none: RemoteJobControlRequest.none
                case .pause: .pause
                case .cancel: .cancel
                }
            }(),
            attempts: librarySlimmingSummary?.attempts,
            maxAttempts: librarySlimmingSummary?.maxAttempts,
            lastErrorCode: librarySlimmingSummary?.lastErrorCode?.rawValue,
            navigationTarget: librarySlimmingSummary.map {
                RemoteJobNavigationTarget(
                    workspace: .librarySlimming,
                    recordID: $0.jobID,
                    mediaKind: $0.mediaKind == .video ? .video : .image
                )
            }
        )
    }

    private static func mapAssetFilter(
        _ request: RemoteAssetPageRequest
    ) -> AssetPageFilter {
        AssetPageFilter(
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
            mediaKinds: request.mediaKinds.map(Self.mapMediaKind),
            mediaTypes: request.mediaTypes,
            tagPresence: {
                switch request.tagPresence {
                case .any: .any
                case .tagged: .tagged
                case .untagged: .untagged
                }
            }(),
            favorite: request.favorite == .favorited ? .favorited : .any,
            searchText: request.searchText,
            worldMapSelection: request.worldMapSelection.map(mapWorldMapSelectionQuery)
        )
    }

    private static func mapWorldMapBounds(_ bounds: RemoteWorldMapBounds) -> WorldMapCatalogBounds {
        WorldMapCatalogBounds(
            west: bounds.west,
            south: bounds.south,
            east: bounds.east,
            north: bounds.north
        )
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func mapWorldMapSelectionQuery(
        _ query: RemoteWorldMapSelectionQuery
    ) -> WorldMapCatalogSelectionQuery {
        WorldMapCatalogSelectionQuery(
            cellDegrees: query.cellDegrees,
            longitudeBucket: query.longitudeBucket,
            latitudeBucket: query.latitudeBucket,
            bounds: query.bounds.map(mapWorldMapBounds),
            maximumAssets: max(
                1,
                min(query.maximumAssets, WorldMapCatalogSelectionQuery.maximumAssetLimit)
            )
        )
    }

    private static func mapWorldMapSelectionQuery(
        _ query: WorldMapCatalogSelectionQuery
    ) -> RemoteWorldMapSelectionQuery {
        RemoteWorldMapSelectionQuery(
            cellDegrees: query.cellDegrees,
            longitudeBucket: query.longitudeBucket,
            latitudeBucket: query.latitudeBucket,
            bounds: query.bounds.map {
                RemoteWorldMapBounds(
                    west: $0.west,
                    south: $0.south,
                    east: $0.east,
                    north: $0.north
                )
            },
            maximumAssets: query.maximumAssets
        )
    }

    private static func mapWorldMapCluster(
        _ cluster: WorldMapCatalogCluster
    ) -> RemoteWorldMapCluster {
        RemoteWorldMapCluster(
            id: cluster.id,
            longitude: cluster.longitude,
            latitude: cluster.latitude,
            photoCount: cluster.photoCount,
            gpsCount: cluster.gpsCount,
            tagCount: cluster.tagCount,
            displayName: cluster.displayName,
            selectionQuery: mapWorldMapSelectionQuery(cluster.selectionQuery)
        )
    }

    private static func mapWorldMapLocationBackfillSnapshot(
        _ snapshot: WorldMapLocationBackfillSnapshot
    ) -> RemoteWorldMapLocationBackfillSnapshot {
        RemoteWorldMapLocationBackfillSnapshot(
            sourceID: snapshot.sourceID,
            sourceKind: snapshot.sourceKind == .photos ? .photos : .folder,
            sourceDisplayName: snapshot.sourceDisplayName,
            sourceState: mapSourceState(snapshot.sourceState),
            phase: {
                switch snapshot.phase {
                case .ready: .ready
                case .queued: .queued
                case .running: .running
                case .cancelling: .cancelling
                case .retryableFailed: .retryableFailed
                case .completed: .completed
                case .cancelled: .cancelled
                case .terminalFailed: .terminalFailed
                case .unavailable: .unavailable
                }
            }(),
            totalPhotoCount: snapshot.totalPhotoCount,
            inspectedPhotoCount: snapshot.inspectedPhotoCount,
            locatedPhotoCount: snapshot.locatedPhotoCount,
            activeJobID: snapshot.activeJobID,
            scanProgress: snapshot.scanProgress.map {
                RemoteJobProgress(
                    completedUnitCount: Int64($0.completed),
                    totalUnitCount: $0.total.map(Int64.init)
                )
            },
            canStart: snapshot.canStart,
            canCancel: snapshot.canCancel
        )
    }

    private static func mapWorldMapPlaceTagResolution(
        _ resolution: WorldMapPlaceTagResolution
    ) -> RemoteWorldMapPlaceTagResolution {
        RemoteWorldMapPlaceTagResolution(
            tagID: resolution.tagID,
            tagName: resolution.tagName,
            groupName: resolution.groupName,
            acceptedPhotoCount: resolution.acceptedPhotoCount,
            status: {
                switch resolution.status {
                case .unresolved: .unresolved
                case .resolved: .resolved
                case .ambiguous: .ambiguous
                case .ignored: .ignored
                case .failed: .failed
                }
            }(),
            confirmedPlaceID: resolution.confirmedPlaceID,
            candidates: resolution.candidates.map { candidate in
                RemoteWorldMapPlaceCandidate(
                    placeID: candidate.placeID,
                    displayName: candidate.displayName,
                    subtitle: candidate.subtitle,
                    latitude: candidate.latitude,
                    longitude: candidate.longitude,
                    kind: {
                        switch candidate.kind {
                        case .poi: .poi
                        case .city: .city
                        case .region: .region
                        case .country: .country
                        }
                    }()
                )
            }
        )
    }

    private static func mapLibrarySlimmingMode(
        _ mode: RemoteLibrarySlimmingAnalyzeMode
    ) -> LibrarySlimmingAnalyzeMode {
        switch mode {
        case .catalog: .catalog
        case .currentFilter: .currentFilter
        case .seeds: .seeds
        }
    }

    private static func mapLibrarySlimmingSetup(
        _ setup: LibrarySlimmingCommandSetupSnapshot,
        mediaKind: RemoteAssetMediaKind
    ) -> RemoteLibrarySlimmingSetupSnapshot {
        RemoteLibrarySlimmingSetupSnapshot(
            mediaKind: mediaKind,
            sources: setup.sources.map { source in
                RemoteLibrarySlimmingSourceOption(
                    id: source.id,
                    displayName: source.displayName,
                    kind: source.kind == .photos ? .photos : .folder,
                    similarityIndex: setup.sourceSimilarityIndexStatuses[source.id].map { status in
                        RemoteLibrarySlimmingSourceIndexStatus(
                            state: {
                                switch status.state {
                                case .building: .building
                                case .ready: .ready
                                case .stale: .stale
                                case .failed: .failed
                                }
                            }(),
                            assetCount: status.assetCount,
                            indexedCount: status.indexedCount,
                            clusterCount: status.clusterCount,
                            pendingCount: status.pendingCount,
                            updatedAtMs: status.updatedAtMs
                        )
                    }
                )
            },
            thresholds: mapLibrarySlimmingThresholds(setup.thresholds),
            factoryThresholds: mapLibrarySlimmingThresholds(setup.factoryThresholds),
            sourceSimilarityIndexAvailable: setup.sourceSimilarityIndexAvailable
        )
    }

    private static func mapLibrarySlimmingThresholds(
        _ thresholds: NearDuplicateSceneThresholds
    ) -> RemoteLibrarySlimmingThresholds {
        RemoteLibrarySlimmingThresholds(
            featurePrintRecallTopK: thresholds.featurePrintRecallTopK,
            featurePrintMaxL2Distance: thresholds.featurePrintMaxL2Distance,
            dinoCosineMinSimilarity: thresholds.dinoCosineMinSimilarity,
            sceneBucketActivationAssetCount: thresholds.sceneBucketActivationAssetCount,
            featurePrintRecallMode: thresholds.featurePrintRecallMode == .allCandidates
                ? .allCandidates : .topK,
            featurePrintL2Mode: thresholds.featurePrintL2Mode == .unlimited
                ? .unlimited : .radius,
            dinoCosineMode: thresholds.dinoCosineMode == .unlimited
                ? .unlimited : .minimum,
            sceneBucketingMode: {
                switch thresholds.sceneBucketingMode {
                case .always: .always
                case .automatic: .automatic
                case .never: .never
                }
            }()
        )
    }

    private static func mapLibrarySlimmingThresholds(
        _ thresholds: RemoteLibrarySlimmingThresholds
    ) -> NearDuplicateSceneThresholds {
        NearDuplicateSceneThresholds(
            featurePrintRecallTopK: thresholds.featurePrintRecallTopK,
            featurePrintMaxL2Distance: thresholds.featurePrintMaxL2Distance,
            dinoCosineMinSimilarity: thresholds.dinoCosineMinSimilarity,
            sceneBucketActivationAssetCount: thresholds.sceneBucketActivationAssetCount,
            featurePrintRecallMode: thresholds.featurePrintRecallMode == .allCandidates
                ? .allCandidates : .topK,
            featurePrintL2Mode: thresholds.featurePrintL2Mode == .unlimited
                ? .unlimited : .radius,
            dinoCosineMode: thresholds.dinoCosineMode == .unlimited
                ? .unlimited : .minimum,
            sceneBucketingMode: {
                switch thresholds.sceneBucketingMode {
                case .always: .always
                case .automatic: .automatic
                case .never: .never
                }
            }()
        ).clamped()
    }

    private static func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let result = String(data: data, encoding: .utf8) else {
            throw RemoteAPIError(code: .internalError, message: "无法规范化请求")
        }
        return result
    }

    private static func uuidLessThan(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }

    private static func mapLibrarySlimmingCommandError(_ error: Error) -> RemoteAPIError {
        if let remote = error as? RemoteAPIError { return remote }
        if let idempotencyError = error as? RemoteIdempotencyStore.IdempotencyError,
           idempotencyError == .conflict
        {
            return RemoteAPIError(code: .conflict, message: "操作 ID 已用于其他图库瘦身请求")
        }
        guard let commandError = error as? LibrarySlimmingCommandError else {
            return RemoteAPIError(code: .internalError, message: "图库瘦身命令执行失败")
        }
        switch commandError {
        case .unavailable:
            return RemoteAPIError(code: .notFound, message: "图库瘦身当前不可用")
        case .invalidSelection:
            return RemoteAPIError(code: .badRequest, message: "图库瘦身分析范围无效")
        case .activeConflict:
            return RemoteAPIError(code: .conflict, message: "该操作与现有图库瘦身任务冲突")
        case .jobNotFound:
            return RemoteAPIError(code: .notFound, message: "图库瘦身分析记录不存在")
        case .invalidAction:
            return RemoteAPIError(code: .conflict, message: "当前任务状态不允许此操作")
        case .recycleEntryNotFound:
            return RemoteAPIError(code: .notFound, message: "回收站项目不存在")
        case .operationConflict:
            return RemoteAPIError(code: .conflict, message: "操作 ID 已用于其他回收站请求")
        case .cleanupPlanNotFound:
            return RemoteAPIError(code: .notFound, message: "一键清理方案已过期，请重新预览")
        case .cleanupPlanChanged:
            return RemoteAPIError(code: .conflict, message: "分析结果或来源状态已变化，请重新预览")
        }
    }

    private static func mapLibrarySlimmingRecycleEntry(
        _ entry: RecycleEntryRecord,
        sourceDisplayName: String,
        favorite: MediaFavoriteState?
    ) -> RemoteLibrarySlimmingRecycleEntry {
        let resolution: RemoteLibrarySlimmingRecycleResolution = if entry.sourceKind == .photos,
                                                                    entry.state == .recycled
        {
            .photosManagedBySystem
        } else {
            switch entry.resolution {
            case .restoreOrPurge: .restoreOrPurge
            case .discardPreflightFailure: .discardPreflightFailure
            case .retryInterruptedOperation: .retryInterruptedOperation
            case .reinspectFileLocations: .reinspectFileLocations
            case .updateFolderAuthorization: .updateFolderAuthorization
            case .refreshSourceBeforeRetry: .refreshSourceBeforeRetry
            case .requestPhotosAuthorization: .requestPhotosAuthorization
            case .retryFromAnalysis: .retryFromAnalysis
            }
        }
        let actions: [RemoteLibrarySlimmingRecycleAction] = switch entry.resolution {
        case .restoreOrPurge:
            entry.sourceKind == .photos ? [] : [.restore, .purge]
        case .discardPreflightFailure: [.discardPreflightFailure]
        case .retryInterruptedOperation, .reinspectFileLocations:
            [.retryInterruptedOperation]
        case .updateFolderAuthorization,
             .refreshSourceBeforeRetry,
             .requestPhotosAuthorization,
             .retryFromAnalysis:
            []
        }
        return RemoteLibrarySlimmingRecycleEntry(
            id: entry.id,
            assetID: entry.assetID,
            sourceID: entry.sourceID,
            sourceDisplayName: sourceDisplayName,
            sourceKind: entry.sourceKind == .photos ? .photos : .file,
            mediaKind: entry.mediaKind == .video ? .video : .image,
            fileName: entry.fileName,
            trashedAtMs: entry.trashedAtMs,
            purgeAfterMs: entry.purgeAfterMs,
            state: {
                switch entry.state {
                case .pending: .pending
                case .recycled: .recycled
                case .restoring: .restoring
                case .purging: .purging
                case .restored: .restored
                case .purged: .purged
                case .failed: .failed
                }
            }(),
            errorCode: entry.errorCode,
            problem: mapLibrarySlimmingRecycleProblem(entry.problem),
            resolution: resolution,
            availableActions: actions,
            stateMessage: librarySlimmingRecycleStateMessage(entry),
            policyMessage: librarySlimmingRecyclePolicyMessage(entry),
            explanationMessage: librarySlimmingRecycleExplanationMessage(entry),
            favorite: favorite.map(Self.mapFavorite)
        )
    }

    private static func mapLibrarySlimmingRecycleProblem(
        _ problem: RecycleEntryProblem?
    ) -> RemoteLibrarySlimmingRecycleProblem? {
        switch problem {
        case .sourceAuthorizationRequired: .sourceAuthorizationRequired
        case .sourceAuthorizationInvalid: .sourceAuthorizationInvalid
        case .sourceChanged: .sourceChanged
        case .photosAuthorizationRequired: .photosAuthorizationRequired
        case .photosAssetNotFound: .photosAssetNotFound
        case .photosUserCancelled: .photosUserCancelled
        case .photosMutationFailed: .photosMutationFailed
        case .fileIO: .fileIO
        case .locationConflict: .locationConflict
        case .locationMissing: .locationMissing
        case .unknown: .unknown
        case nil: nil
        }
    }

    private static func librarySlimmingRecycleStateMessage(
        _ entry: RecycleEntryRecord
    ) -> String {
        if entry.isDiscardablePreflightFailure {
            return "尚未开始：需要更新文件夹回收权限"
        }
        return switch entry.state {
        case .pending: "处理尚未完成，正在等待安全协调"
        case .restoring: "恢复尚未完成，可继续协调"
        case .purging: "永久清理尚未完成，可安全继续"
        case .failed: librarySlimmingRecycleProblemMessage(entry.problem)
        case .recycled: "可恢复"
        case .restored: "已恢复"
        case .purged: "已永久清理"
        }
    }

    private static func librarySlimmingRecycleProblemMessage(
        _ problem: RecycleEntryProblem?
    ) -> String {
        switch problem {
        case .sourceAuthorizationRequired: "需要文件夹回收权限"
        case .sourceAuthorizationInvalid: "原有文件夹回收权限已失效"
        case .sourceChanged: "来源文件已变化，已停止处理以避免误删"
        case .photosAuthorizationRequired: "需要 Apple Photos 完整读写权限"
        case .photosAssetNotFound: "Photos 中已找不到同一媒体，未提交删除"
        case .photosUserCancelled: "已取消系统删除确认，媒体未被删除"
        case .photosMutationFailed: "Apple Photos 未确认完成删除"
        case .fileIO: "文件操作没有形成可确认的完整结果"
        case .locationConflict: "原位置与隔离区同时存在内容，需要核对"
        case .locationMissing: "无法确认媒体当前的唯一位置"
        case .unknown, nil: "本次处理未完成，需要重新核对"
        }
    }

    private static func librarySlimmingRecyclePolicyMessage(
        _ entry: RecycleEntryRecord
    ) -> String {
        switch entry.state {
        case .recycled:
            return entry.sourceKind == .photos
                ? "恢复与永久删除由“照片”App 管理"
                : "可恢复到原位置"
        case .pending:
            return "ImageAll 会先确认实际位置，不会重复删除"
        case .restoring:
            return "正在协调原位置与 ImageAll 隔离区"
        case .purging:
            return "永久清理已经开始，完成后不可恢复"
        case .failed:
            return switch entry.problem {
            case .sourceAuthorizationRequired, .sourceAuthorizationInvalid:
                "原文件未因本次失败而被修改"
            case .sourceChanged:
                "原文件未删除；刷新来源并重新分析后再试"
            case .photosAuthorizationRequired,
                 .photosAssetNotFound,
                 .photosUserCancelled,
                 .photosMutationFailed:
                "未确认移入“最近删除”；可修正原因后重试"
            case .locationConflict:
                "两处内容均会保留，ImageAll 不会覆盖或删除"
            case .locationMissing:
                "位置未确认前，ImageAll 不会继续删除"
            case .fileIO, .unknown, nil:
                "未确认删除完成；现有内容会继续受到保护"
            }
        case .restored:
            return "媒体已经恢复"
        case .purged:
            return "媒体已经永久清理"
        }
    }

    private static func librarySlimmingRecycleExplanationMessage(
        _ entry: RecycleEntryRecord
    ) -> String? {
        if entry.sourceKind == .photos, entry.state == .recycled {
            return "请在系统“照片”App 的“最近删除”中恢复；恢复后 ImageAll 会自动对账。永久删除也由系统管理。"
        }
        guard entry.state == .failed else { return nil }
        return switch entry.problem {
        case .sourceAuthorizationRequired:
            "文件操作尚未开始，原文件没有修改。请更新来源回收权限后回到分析结果重试；也可以移除这条失败记录。"
        case .sourceAuthorizationInvalid:
            "已保存的来源回收权限失效。请重新选择原来源更新权限，再回到分析结果重试。"
        case .sourceChanged:
            "目录中的文件与分析时记录不一致，ImageAll 已停止删除以避免误删。请刷新来源、等待完成、重新分析后再试。"
        case .photosAuthorizationRequired:
            "尚未取得 Apple Photos 完整读写权限，因此没有提交移入“最近删除”。授权后可回到分析结果重试。"
        case .photosAssetNotFound:
            "执行前已无法用同一 Photos 标识找到该媒体，因此没有提交删除。请刷新 Photos 来源并重新分析。"
        case .photosUserCancelled:
            "系统的删除确认已取消，媒体没有被 ImageAll 视为已移入“最近删除”。可回到分析结果重新发起。"
        case .photosMutationFailed:
            "Apple Photos 没有确认完成本次删除，ImageAll 因此保留当前媒体状态。可回到分析结果重试。"
        case .fileIO:
            "文件操作没有得到可证明的完整结果。若原位置和隔离区都已登记，可重新检查两处位置；否则请回到分析结果重试。"
        case .locationConflict:
            "原位置与 ImageAll 隔离区同时存在内容。为避免覆盖或误删，ImageAll 会保留两份并等待人工处理。"
        case .locationMissing:
            "ImageAll 无法在原位置或隔离区确认唯一内容，因此不会继续删除。请先核对来源磁盘和文件位置。"
        case .unknown, nil:
            "本次操作没有形成可证明的完成状态。ImageAll 不会继续删除；请回到分析结果重新检查后再试。"
        }
    }

    private static func mapLibrarySlimmingRecycleRequest(
        _ request: LibrarySlimmingRecycleCommandRequestSnapshot
    ) -> RemoteLibrarySlimmingRecycleRequestSnapshot {
        RemoteLibrarySlimmingRecycleRequestSnapshot(
            id: request.id,
            operationID: request.operationID,
            entryID: request.entryID,
            action: {
                switch request.action {
                case .restore: .restore
                case .discardPreflightFailure: .discardPreflightFailure
                case .retryInterruptedOperation: .retryInterruptedOperation
                case .purge: .purge
                }
            }(),
            fileName: request.fileName,
            phase: {
                switch request.phase {
                case .awaitingMac: .awaitingMac
                case .running: .running
                case .completed: .completed
                case .cancelled: .cancelled
                case .failed: .failed
                }
            }(),
            message: request.message,
            updatedAtMs: request.updatedAtMs
        )
    }

    private static func mapLibrarySlimmingRemovalRequest(
        _ request: LibrarySlimmingRemovalCommandRequestSnapshot
    ) -> RemoteLibrarySlimmingRemovalRequestSnapshot {
        RemoteLibrarySlimmingRemovalRequestSnapshot(
            id: request.id,
            operationID: request.operationID,
            jobID: request.jobID,
            clusterID: request.clusterID,
            scope: request.scope == .gallerySelection
                ? .gallerySelection
                : .analysisCluster,
            mediaKind: request.mediaKind == .video ? .video : .image,
            assetIDs: request.assetIDs,
            mode: request.mode == .releaseSourceSpace
                ? .releaseSourceSpace
                : .recoverableRecycle,
            phase: {
                switch request.phase {
                case .awaitingMac: .awaitingMac
                case .running: .running
                case .completed: .completed
                case .cancelled: .cancelled
                case .failed: .failed
                }
            }(),
            progress: request.progress.map { progress in
                RemoteLibrarySlimmingRemovalProgress(
                    phase: RemoteLibrarySlimmingRemovalProgressPhase(
                        rawValue: progress.phase.rawValue
                    ) ?? .preparing,
                    completedAssetCount: progress.completedAssetCount,
                    totalAssetCount: progress.totalAssetCount,
                    copiedBytes: progress.copiedBytes,
                    totalFileBytes: progress.totalFileBytes
                )
            },
            audit: request.audit.map { audit in
                RemoteLibrarySlimmingRemovalAudit(
                    hiddenAssetIDs: audit.hiddenAssetIDs,
                    recycledEntryIDs: audit.recycledEntryIDs,
                    permanentlyDeletedAssetIDs: audit.permanentlyDeletedAssetIDs,
                    durabilityPendingAssetIDs: audit.durabilityPendingAssetIDs,
                    failedAssetIDs: audit.failedAssetIDs,
                    authorizationRequiredSourceIDs: audit.authorizationRequiredSourceIDs,
                    authorizationRequiredAssetIDs: audit.authorizationRequiredAssetIDs,
                    authorizationDeniedPhotosAssetIDs: audit.authorizationDeniedPhotosAssetIDs,
                    mutationAuthorizationInvalidAssetIDs:
                        audit.mutationAuthorizationInvalidAssetIDs,
                    photosMutationFailedAssetIDs: audit.photosMutationFailedAssetIDs,
                    photosMutationFailureCategories:
                        audit.photosMutationFailureCategories.map(\.rawValue),
                    photosMutationFailureCodes: audit.photosMutationFailureCodes,
                    sourceChangedAssetIDs: audit.sourceChangedAssetIDs
                )
            },
            message: request.message,
            updatedAtMs: request.updatedAtMs
        )
    }

    private static func mapLibrarySlimmingIdenticalCleanupRequest(
        _ request: LibrarySlimmingIdenticalCleanupRequestSnapshot
    ) -> RemoteLibrarySlimmingIdenticalCleanupRequestSnapshot {
        let removal = LibrarySlimmingRemovalCommandRequestSnapshot(
            id: request.id,
            operationID: request.operationID,
            scope: .analysisCluster,
            jobID: request.jobID,
            clusterID: request.planID,
            mediaKind: request.mediaKind,
            assetIDs: [],
            mode: request.mode,
            phase: request.phase,
            progress: request.progress,
            audit: request.audit,
            message: request.message,
            updatedAtMs: request.updatedAtMs
        )
        let mapped = mapLibrarySlimmingRemovalRequest(removal)
        return RemoteLibrarySlimmingIdenticalCleanupRequestSnapshot(
            id: request.id,
            operationID: request.operationID,
            planID: request.planID,
            jobID: request.jobID,
            mediaKind: request.mediaKind == .video ? .video : .image,
            mode: request.mode == .releaseSourceSpace
                ? .releaseSourceSpace
                : .recoverableRecycle,
            phase: mapped.phase,
            executionStage: request.executionStage.flatMap {
                RemoteLibrarySlimmingIdenticalCleanupExecutionStage(rawValue: $0.rawValue)
            },
            progress: mapped.progress,
            audit: mapped.audit,
            verification: request.verification.map {
                RemoteLibrarySlimmingIdenticalCleanupVerification(
                    verifiedGroupCount: $0.verifiedGroupCount,
                    targetGroupCount: $0.targetGroupCount,
                    targetRetainedAssetCount: $0.targetRetainedAssetCount,
                    observedAssetCount: $0.observedAssetCount,
                    currentAvailableAssetCount: $0.currentAvailableAssetCount,
                    retainedNonredundantAssetCount: $0.retainedNonredundantAssetCount,
                    recycledRedundantAssetCount: $0.recycledRedundantAssetCount,
                    remainingRedundantAssetCount: $0.remainingRedundantAssetCount,
                    unresolvedAssetCount: $0.unresolvedAssetCount,
                    unresolvedGroupCount: $0.unresolvedGroupCount,
                    isComplete: $0.isComplete
                )
            },
            message: request.message,
            updatedAtMs: request.updatedAtMs
        )
    }

    private static func mapLibrarySlimmingJob(
        _ summary: LibrarySlimmingAnalysisJobSummary
    ) -> RemoteLibrarySlimmingJob {
        RemoteLibrarySlimmingJob(
            id: summary.jobID,
            mode: {
                switch summary.mode {
                case .catalog: .catalog
                case .currentFilter: .currentFilter
                case .seeds: .seeds
                }
            }(),
            mediaKind: summary.mediaKind == .video ? .video : .image,
            state: mapJobState(summary.state),
            progress: RemoteJobProgress(
                completedUnitCount: Int64(summary.progress.completed),
                totalUnitCount: summary.progress.total.map(Int64.init)
            ),
            attempts: summary.attempts,
            maxAttempts: summary.maxAttempts,
            memberCount: summary.memberCount,
            seedCount: summary.seedCount,
            clusterCount: summary.clusterCount,
            hasResult: summary.hasResult,
            createdAtMs: summary.createdAtMs,
            updatedAtMs: summary.updatedAtMs,
            sourceNames: summary.sourceNames,
            availableActions: {
                switch summary.state {
                case .pending, .running:
                    summary.controlRequest == .none ? [.pause] : []
                case .paused, .retryableFailed:
                    [.resume]
                case .completed, .terminalFailed, .cancelled:
                    []
                }
            }(),
            controlRequest: {
                switch summary.controlRequest {
                case .none: .none
                case .pause: .pause
                case .cancel: .cancel
                }
            }(),
            scanProgress: {
                guard let total = summary.progress.total,
                      let progress = LibrarySlimmingJobProgressPresentation.scanProgress(
                        completed: summary.progress.completed,
                        progressTotal: total,
                        memberCount: summary.memberCount
                      )
                else { return nil }
                let phase: RemoteLibrarySlimmingScanPhase = switch progress.phase {
                case .preparingFingerprints: .preparingFingerprints
                case .loadingFeaturePrints: .loadingFeaturePrints
                case .loadingEmbeddings: .loadingEmbeddings
                case .clustering: .clustering
                }
                return RemoteLibrarySlimmingScanProgress(
                    phase: phase,
                    completedUnitCount: Int64(progress.completed),
                    totalUnitCount: Int64(progress.total)
                )
            }(),
            lastErrorCode: summary.lastErrorCode?.rawValue
        )
    }

    private static func mapLibrarySlimmingCluster(
        _ cluster: SlimmingCluster,
        isSeedOnlyResult: Bool,
        reviewDisposition: LibrarySlimmingClusterReviewDisposition?,
        originalMemberCount: Int,
        isHistoricalProcessedRecord: Bool
    ) -> RemoteLibrarySlimmingCluster {
        RemoteLibrarySlimmingCluster(
            id: cluster.id,
            kind: {
                switch cluster.kind {
                case .byteIdentical: .byteIdentical
                case .perceptualDuplicate: .perceptualDuplicate
                case .nearDuplicateScene: .nearDuplicateScene
                }
            }(),
            memberCount: cluster.memberAssetIDs.count,
            representativeAssetID: cluster.representativeAssetID,
            score: cluster.score,
            isSeedOnlyResult: isSeedOnlyResult,
            technicalSummary: {
                if isSeedOnlyResult {
                    return "种子检索未形成相似分组"
                }
                switch cluster.kind {
                case .byteIdentical:
                    return "SHA-256 一致 · \(cluster.modelIdentity.revisionCaption)"
                case .perceptualDuplicate:
                    return String(
                        format: "感知匹配 %.0f%% · %@",
                        cluster.score * 100,
                        cluster.modelIdentity.revisionCaption
                    )
                case .nearDuplicateScene:
                    return String(
                        format: "DINOv2 余弦 %.3f · %@",
                        cluster.score,
                        cluster.modelIdentity.revisionCaption
                    )
                }
            }(),
            reviewDisposition: {
                switch reviewDisposition {
                case .confirmed: .confirmed
                case .ignored: .ignored
                case nil: nil
                }
            }(),
            originalMemberCount: originalMemberCount,
            isHistoricalProcessedRecord: isHistoricalProcessedRecord
        )
    }

    private static func mapJobState(_ state: JobState) -> RemoteJobState {
        switch state {
        case .pending: .pending
        case .running: .running
        case .paused: .paused
        case .retryableFailed: .retryableFailed
        case .completed: .completed
        case .terminalFailed: .terminalFailed
        case .cancelled: .cancelled
        }
    }

    private static func mapJobAction(_ action: RemoteJobAction) -> JobActivityAction {
        switch action {
        case .pause: .pause
        case .resume: .resume
        case .cancel: .cancel
        }
    }

    private static func mapTrainingRun(
        _ run: TrainingRunRecord,
        tagDisplayName: String?
    ) -> RemoteTrainingRun {
        let summary = trainingJSONObject(run.sampleSummaryJSON)
        let perTag = (summary["perTag"] as? [[String: Any]])?.first { item in
            guard let tagID = run.tagID else { return true }
            return (item["tagID"] as? String).flatMap(UUID.init(uuidString:)) == tagID
        }
        return RemoteTrainingRun(
            id: run.id,
            mediaKind: run.mediaKind == .video ? .video : .image,
            method: mapTrainingMethod(run.method),
            state: {
                switch run.state {
                case .queued: .queued
                case .running: .running
                case .succeeded: .succeeded
                case .failed: .failed
                case .cancelled: .cancelled
                }
            }(),
            createdAtMs: run.createdAtMs,
            startedAtMs: run.startedAtMs,
            finishedAtMs: run.finishedAtMs,
            catalogScopeID: run.catalogScopeID,
            jobID: run.jobID,
            tagID: run.tagID,
            tagDisplayName: tagDisplayName,
            batchID: (summary["batchID"] as? String).flatMap(UUID.init(uuidString:)),
            batchTagIndex: trainingNonnegativeInteger(summary["batchTagIndex"]),
            batchTagCount: trainingNonnegativeInteger(summary["batchTagCount"]),
            sampleCount: trainingNonnegativeInteger(summary["sampleCount"]),
            positiveSampleCount: trainingNonnegativeInteger(perTag?["positiveCount"]),
            negativeSampleCount: trainingNonnegativeInteger(perTag?["negativeCount"]),
            sampleSummaryJSON: sanitizeTrainingJSON(run.sampleSummaryJSON),
            sampleManifestSHA256: run.sampleManifestSHA256,
            configJSON: sanitizeTrainingJSON(run.configJSON),
            metricsJSON: sanitizeTrainingJSON(run.metricsJSON),
            artifactKind: run.artifactKind,
            artifactRef: safeTrainingArtifactReference(run.artifactRef),
            artifactSHA256: run.artifactSHA256,
            resultSummaryJSON: sanitizeTrainingJSON(run.resultSummaryJSON),
            errorCode: run.errorCode,
            recoveryContext: trainingRecoveryContext(run),
            failureGuidance: run.errorCode.map(trainingFailureGuidance)
        )
    }

    private static func trainingRecoveryContext(
        _ run: TrainingRunRecord
    ) -> RemoteTrainingRecoveryContext {
        let summary = trainingJSONObject(run.sampleSummaryJSON)
        let config = trainingJSONObject(run.configJSON)
        var tagIDs = trainingUUIDs(summary["batchTagIDs"])
        if tagIDs.isEmpty {
            tagIDs = run.tagID.map { [$0] } ?? []
        }
        if tagIDs.isEmpty {
            tagIDs = trainingUUIDs(summary["tagIDs"])
        }
        if tagIDs.isEmpty, let perTag = summary["perTag"] as? [[String: Any]] {
            tagIDs = perTag.compactMap { item in
                (item["tagID"] as? String).flatMap(UUID.init(uuidString:))
            }
        }
        tagIDs = Array(Set(tagIDs)).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }

        let scopeKind = summary["scopeKind"] as? String
        let sourceIDs = run.method == .featureKnn
            ? trainingUUIDs(config["sourceIDs"])
            : []
        let scope: RemoteTrainingRecoveryScope
        let isExact: Bool
        let note: String?
        switch (run.method, scopeKind) {
        case (.featureKnn, "allActiveSources"):
            scope = .allSources
            isExact = true
            note = "将按原来的“全部可用来源”范围重新配置。"
        case (.featureKnn, "selectedSources") where !sourceIDs.isEmpty:
            scope = .selectedSources
            isExact = true
            note = "已恢复原来选定的来源；已停用的来源会在确认时明确提示。"
        case (.featureKnn, "selectedSources"):
            scope = .unresolved
            isExact = false
            note = "这条旧记录没有保存来源明细，请重新选择来源后再启动。"
        case (.featureKnn, _):
            scope = .unresolved
            isExact = false
            note = "无法确认这条旧记录的来源范围，请重新选择来源后再启动。"
        default:
            scope = .unresolved
            isExact = false
            note = "已恢复方法和标签；历史记录未保存图库选择范围，默认使用全部已确认样本。"
        }
        return RemoteTrainingRecoveryContext(
            tagIDs: tagIDs,
            sourceIDs: sourceIDs,
            scope: scope,
            isExact: isExact,
            note: note
        )
    }

    private static func trainingFailureGuidance(
        _ errorCode: String
    ) -> RemoteTrainingFailureGuidance {
        switch errorCode {
        case "insufficientSamples", "personalizationInsufficientSamples",
             "invalidSnapshot", "personalRebuildInvalidSnapshot":
            return RemoteTrainingFailureGuidance(
                title: "可用样本不足",
                message: "标签的确认样本不足，或部分样本已不再可用。",
                suggestedAction: "先在标签审核中补齐样本，再用“重新配置”启动。"
            )
        case "modelUnavailable", "personalRebuildServiceUnavailable",
             "personalLibraryServiceUnavailable":
            return RemoteTrainingFailureGuidance(
                title: "模型服务暂不可用",
                message: "这台 Mac 当前没有准备好本次训练需要的模型能力。",
                suggestedAction: "确认 Mac 端模型状态后，再重新配置并启动。"
            )
        case "embeddingUnavailable", "personalRebuildCacheMiss":
            return RemoteTrainingFailureGuidance(
                title: "照片特征尚未准备好",
                message: "训练所需的本地照片特征缺失或生成失败。",
                suggestedAction: "保持 Mac App 运行，准备特征后再重新配置。"
            )
        case "staleSnapshot", "personalRebuildBundleMismatch",
             "personalLibraryBundleMismatch", "identityMismatch":
            return RemoteTrainingFailureGuidance(
                title: "训练数据已经变化",
                message: "标签决定或模型身份在训练期间发生了变化，旧快照不能继续使用。",
                suggestedAction: "使用最新标签和范围重新配置。"
            )
        case "activeConflict", "alreadyRunning":
            return RemoteTrainingFailureGuidance(
                title: "已有同类任务正在运行",
                message: "为避免覆盖结果，这次启动没有继续。",
                suggestedAction: "等待现有任务完成，或在任务面板取消后重试。"
            )
        case "personalizationTagArchived":
            return RemoteTrainingFailureGuidance(
                title: "标签已归档",
                message: "这条训练记录关联的标签已不再可用。",
                suggestedAction: "选择一个当前可用的标签重新配置。"
            )
        case "cancelled":
            return RemoteTrainingFailureGuidance(
                title: "训练已取消",
                message: "任务在完成前被取消，没有覆盖已有模型。",
                suggestedAction: "需要时可恢复原有配置并重新启动。"
            )
        case "hostRestartInterrupted":
            return RemoteTrainingFailureGuidance(
                title: "训练被 App 重启中断",
                message: "个人模型训练依赖当前 Mac App 进程，重启后不会继续占用资源或覆盖已有模型。",
                suggestedAction: "使用“重新配置”恢复原批次标签，并从尚未完成的部分重新启动。"
            )
        default:
            return RemoteTrainingFailureGuidance(
                title: "训练未完成",
                message: "这台 Mac 已安全保留失败记录和已有模型。",
                suggestedAction: "检查关联任务；若问题已排除，可重新配置后再试。"
            )
        }
    }

    private static func trainingJSONObject(_ json: String) -> [String: Any] {
        guard json.utf8.count <= 256_000,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let dictionary = object as? [String: Any]
        else {
            return [:]
        }
        return dictionary
    }

    private static func trainingUUIDs(_ value: Any?) -> [UUID] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { value in
            (value as? String).flatMap(UUID.init(uuidString:))
        }
    }

    private static func trainingNonnegativeInteger(_ value: Any?) -> Int? {
        let integer: Int?
        if let value = value as? Int {
            integer = value
        } else if let value = value as? NSNumber {
            integer = value.intValue
        } else {
            integer = nil
        }
        guard let integer, integer >= 0 else { return nil }
        return integer
    }

    private static func mapTrainingSlot(_ slot: TrainingWorkspaceSlot) -> RemoteTrainingSlot {
        RemoteTrainingSlot(
            method: mapTrainingMethod(slot.method),
            isPublished: slot.isPublished,
            publishedRunID: slot.publishedRunID,
            artifactRef: safeTrainingArtifactReference(slot.artifactRef)
        )
    }

    private static func mapTrainingActivity(
        _ activity: TrainingCommandActivitySnapshot
    ) -> RemoteTrainingActivity {
        RemoteTrainingActivity(
            operationID: activity.operationID,
            mediaKind: activity.mediaKind == .video ? .video : .image,
            method: mapTrainingMethod(activity.method),
            phase: {
                switch activity.phase {
                case .preparingSamples: .preparingSamples
                case .preparingEmbeddings: .preparingEmbeddings
                case .trainingAndPublishing: .trainingAndPublishing
                case .completed: .completed
                case .failed: .failed
                case .cancelled: .cancelled
                }
            }(),
            completedUnitCount: activity.completedUnitCount,
            totalUnitCount: activity.totalUnitCount,
            sampleCount: activity.sampleCount,
            errorCode: activity.errorCode,
            availableActions: activity.availableActions.map {
                switch $0 {
                case .cancel: .cancel
                }
            },
            tagActivities: activity.tagActivities.map { tag in
                RemoteTrainingTagActivity(
                    tagID: tag.tagID,
                    displayName: tag.displayName,
                    phase: {
                        switch tag.phase {
                        case .pending: .pending
                        case .preparingSamples: .preparingSamples
                        case .preparingEmbeddings: .preparingEmbeddings
                        case .trainingAndPublishing: .trainingAndPublishing
                        case .succeeded: .succeeded
                        case .skipped: .skipped
                        case .failed: .failed
                        case .cancelled: .cancelled
                        }
                    }(),
                    sampleCount: tag.sampleCount,
                    errorCode: tag.errorCode
                )
            },
            acceptedAtMs: activity.acceptedAtMs,
            updatedAtMs: activity.updatedAtMs
        )
    }

    private static func mapEmbeddingPreparationActivity(
        _ activity: EmbeddingPreparationActivitySnapshot
    ) -> RemoteEmbeddingPreparationActivity {
        RemoteEmbeddingPreparationActivity(
            operationID: activity.operationID,
            mediaKind: activity.mediaKind == .video ? .video : .image,
            phase: {
                switch activity.phase {
                case .running: .running
                case .completed: .completed
                case .failed: .failed
                case .cancelled: .cancelled
                }
            }(),
            completedUnitCount: activity.completedUnitCount,
            totalUnitCount: activity.totalUnitCount,
            preparedCount: activity.preparedCount,
            cachedCount: activity.cachedCount,
            cloudOnlyCount: activity.cloudOnlyCount,
            failedCount: activity.failedCount,
            errorCode: activity.errorCode,
            availableActions: activity.availableActions.map { _ in .cancel }
        )
    }

    private static func mapLibrarySuggestionSnapshot(
        _ snapshot: LibrarySuggestionWorkspaceSnapshot
    ) -> RemoteLibrarySuggestionSnapshot {
        RemoteLibrarySuggestionSnapshot(
            mediaKind: snapshot.mediaKind == .video ? .video : .image,
            service: RemoteLibrarySuggestionService(
                state: {
                    switch snapshot.service.state {
                    case .unchecked: .unchecked
                    case .ready: .ready
                    case .degraded: .degraded
                    case .unavailable: .unavailable
                    }
                }(),
                serviceVersion: snapshot.service.serviceVersion,
                provider: snapshot.service.provider,
                modelID: snapshot.service.modelID
            ),
            standardAvailable: snapshot.standardAvailable,
            personalMode: {
                switch snapshot.personalMode {
                case .unavailable: .unavailable
                case .sample: .sample
                case .fullLibrary: .fullLibrary
                }
            }(),
            standardJob: snapshot.standardJob.map(Self.mapLibrarySuggestionJob),
            personalJob: snapshot.personalJob.map(Self.mapLibrarySuggestionJob)
        )
    }

    private static func mapLibrarySuggestionJob(
        _ job: LibrarySuggestionJobSnapshot
    ) -> RemoteLibrarySuggestionJob {
        RemoteLibrarySuggestionJob(
            jobID: job.jobID,
            state: {
                switch job.state {
                case .pending: .pending
                case .running: .running
                case .paused: .paused
                case .retryableFailed: .retryableFailed
                case .completed: .completed
                case .terminalFailed: .terminalFailed
                case .cancelled: .cancelled
                }
            }(),
            checkedCount: job.checkedCount,
            totalCount: job.totalCount,
            suggestedCount: job.suggestedCount,
            skippedCount: job.skippedCount,
            lastErrorCode: job.lastErrorCode?.rawValue,
            availableActions: job.availableActions.map {
                switch $0 {
                case .pause: .pause
                case .resume: .resume
                case .cancel: .cancel
                }
            }
        )
    }

    private static func mapSampleSuggestionActivity(
        _ activity: SampleSuggestionActivitySnapshot
    ) -> RemoteSampleSuggestionActivity {
        RemoteSampleSuggestionActivity(
            operationID: activity.operationID,
            mediaKind: activity.mediaKind == .video ? .video : .image,
            phase: {
                switch activity.phase {
                case .running: .running
                case .completed: .completed
                case .failed: .failed
                case .cancelled: .cancelled
                }
            }(),
            completedUnitCount: activity.completedUnitCount,
            totalUnitCount: activity.totalUnitCount,
            suggestedCount: activity.suggestedCount,
            skippedCount: activity.skippedCount,
            errorCode: activity.errorCode,
            availableActions: activity.availableActions.map { _ in .cancel }
        )
    }

    private static func mapTagLibrarySuggestionActivity(
        _ activity: TagLibrarySuggestionActivitySnapshot
    ) -> RemoteTagLibrarySuggestionActivity {
        RemoteTagLibrarySuggestionActivity(
            operationID: activity.operationID,
            mediaKind: activity.mediaKind == .video ? .video : .image,
            method: activity.method == .personalAdamW ? .personalAdamW : .personalCentroid,
            tagID: activity.tagID,
            phase: {
                switch activity.phase {
                case .preparingCandidates: .preparingCandidates
                case .scoring: .scoring
                case .publishing: .publishing
                case .completed: .completed
                case .failed: .failed
                case .cancelled: .cancelled
                }
            }(),
            completedUnitCount: activity.completedUnitCount,
            totalUnitCount: activity.totalUnitCount,
            aboveThresholdCount: activity.aboveThresholdCount,
            insertedCount: activity.insertedCount,
            skippedCount: activity.skippedCount,
            errorCode: activity.errorCode,
            availableActions: activity.availableActions.map { _ in .cancel }
        )
    }

    private static func mapTagLibrarySuggestionMethod(
        _ method: RemoteTagLibrarySuggestionMethod
    ) -> TagLibrarySuggestionMethod {
        method == .personalAdamW ? .personalAdamW : .personalCentroid
    }

    private static func mapTrainingMethod(_ method: TrainingRunMethod) -> RemoteTrainingRunMethod {
        switch method {
        case .featureKnn: .featureKnn
        case .personalCentroid: .personalCentroid
        case .personalAdamW: .personalAdamW
        }
    }

    private static func mapTrainingMethod(_ method: RemoteTrainingRunMethod) -> TrainingRunMethod {
        switch method {
        case .featureKnn: .featureKnn
        case .personalCentroid: .personalCentroid
        case .personalAdamW: .personalAdamW
        }
    }

    private static func mapTrainingCommandError(_ error: Error) -> Error {
        if let apiError = error as? RemoteAPIError {
            return apiError
        }
        if error is RemoteIdempotencyStore.IdempotencyError {
            return RemoteAPIError(code: .conflict, message: "操作编号已用于另一项训练")
        }
        guard let commandError = error as? TrainingCommandError else {
            return RemoteAPIError(code: .internalError, message: "训练任务处理失败")
        }
        switch commandError {
        case .unavailable:
            return RemoteAPIError(code: .notFound, message: "当前设备尚未提供此训练能力")
        case .invalidSelection:
            return RemoteAPIError(code: .badRequest, message: "训练标签、来源或媒体范围无效")
        case .insufficientSamples:
            return RemoteAPIError(code: .badRequest, message: "当前范围内的训练样本不足")
        case .activeConflict:
            return RemoteAPIError(code: .conflict, message: "同类训练任务正在运行")
        case .activityNotFound:
            return RemoteAPIError(code: .notFound, message: "训练活动不存在或已结束")
        }
    }

    private static func mapAssetLocalSuggestionError(_ error: Error) -> Error {
        if let apiError = error as? RemoteAPIError { return apiError }
        guard let commandError = error as? TrainingCommandError else {
            return RemoteAPIError(code: .internalError, message: "本地模型预览处理失败")
        }
        switch commandError {
        case .unavailable:
            return RemoteAPIError(code: .notFound, message: "当前 Mac 未提供单张本地模型预览")
        case .invalidSelection, .insufficientSamples:
            return RemoteAPIError(code: .badRequest, message: "当前媒体无法进行本地模型预览")
        case .activeConflict:
            return RemoteAPIError(code: .conflict, message: "同一模型预览请求仍在运行")
        case .activityNotFound:
            return RemoteAPIError(code: .notFound, message: "本地模型预览请求不存在")
        }
    }

    private static func mapEmbeddingPreparationError(_ error: Error) -> Error {
        if let apiError = error as? RemoteAPIError { return apiError }
        guard let commandError = error as? TrainingCommandError else {
            return RemoteAPIError(code: .internalError, message: "照片特征准备失败")
        }
        switch commandError {
        case .unavailable:
            return RemoteAPIError(code: .notFound, message: "当前设备尚未提供照片特征能力")
        case .invalidSelection, .insufficientSamples:
            return RemoteAPIError(code: .badRequest, message: "所选项目无法准备照片特征")
        case .activeConflict:
            return RemoteAPIError(code: .conflict, message: "另一项照片特征任务正在运行")
        case .activityNotFound:
            return RemoteAPIError(code: .notFound, message: "照片特征任务不存在或已结束")
        }
    }

    private static func mapLibrarySuggestionError(_ error: Error) -> Error {
        if let apiError = error as? RemoteAPIError { return apiError }
        guard let commandError = error as? TrainingCommandError else {
            return RemoteAPIError(code: .internalError, message: "全库模型建议处理失败")
        }
        switch commandError {
        case .unavailable:
            return RemoteAPIError(code: .notFound, message: "本地模型服务或当前建议能力不可用")
        case .invalidSelection, .insufficientSamples:
            return RemoteAPIError(code: .badRequest, message: "模型身份、媒体类型或来源范围无效")
        case .activeConflict:
            return RemoteAPIError(code: .conflict, message: "已有标准或个人模型建议任务正在运行")
        case .activityNotFound:
            return RemoteAPIError(code: .notFound, message: "模型建议任务不存在或已结束")
        }
    }

    private static func mapSampleSuggestionError(_ error: Error) -> Error {
        if let apiError = error as? RemoteAPIError { return apiError }
        guard let commandError = error as? TrainingCommandError else {
            return RemoteAPIError(code: .internalError, message: "个人建议生成失败")
        }
        switch commandError {
        case .unavailable:
            return RemoteAPIError(code: .notFound, message: "当前设备尚未提供个人建议能力")
        case .invalidSelection, .insufficientSamples:
            return RemoteAPIError(code: .badRequest, message: "当前范围没有可抽检的照片")
        case .activeConflict:
            return RemoteAPIError(code: .conflict, message: "另一项个人建议抽检正在运行")
        case .activityNotFound:
            return RemoteAPIError(code: .notFound, message: "个人建议抽检不存在或已结束")
        }
    }

    private static func mapTagLibrarySuggestionError(_ error: Error) -> Error {
        if let apiError = error as? RemoteAPIError { return apiError }
        guard let commandError = error as? TrainingCommandError else {
            return RemoteAPIError(code: .internalError, message: "按标签生成建议失败")
        }
        switch commandError {
        case .unavailable:
            return RemoteAPIError(code: .notFound, message: "当前设备尚未提供该个人模型能力")
        case .invalidSelection, .insufficientSamples:
            return RemoteAPIError(code: .badRequest, message: "标签、来源或候选范围无效")
        case .activeConflict:
            return RemoteAPIError(code: .conflict, message: "另一项个人模型任务正在运行")
        case .activityNotFound:
            return RemoteAPIError(code: .notFound, message: "按标签建议任务不存在或已结束")
        }
    }

    /// Training records may contain machine-local paths in historical JSON. The web
    /// projection mirrors the Mac inspector's privacy boundary and removes those fields.
    private static func sanitizeTrainingJSON(_ value: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)),
              let sanitized = sanitizeTrainingJSONValue(object, key: nil),
              JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(
                withJSONObject: sanitized,
                options: [.sortedKeys]
              )
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func sanitizeTrainingJSONValue(_ value: Any, key: String?) -> Any? {
        if let key {
            let normalized = key.lowercased()
            let sensitiveFragments = ["path", "bookmark", "locator", "filename", "original"]
            if sensitiveFragments.contains(where: normalized.contains) {
                return nil
            }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                if let sanitized = sanitizeTrainingJSONValue(entry.value, key: entry.key) {
                    result[entry.key] = sanitized
                }
            }
        }
        if let array = value as? [Any] {
            return array.compactMap { sanitizeTrainingJSONValue($0, key: nil) }
        }
        return value
    }

    private static func safeTrainingArtifactReference(_ value: String?) -> String? {
        guard let value,
              !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains("://"),
              !value.split(separator: "/").contains("..")
        else {
            return nil
        }
        return value
    }

    private static func mapReviewItem(
        _ item: ReviewQueueItemProjection,
        favorite: MediaFavoriteState?
    ) -> RemoteReviewQueueItem {
        RemoteReviewQueueItem(
            assetID: item.assetID,
            fileName: item.fileName,
            availability: mapAvailability(item.availability),
            acceptedTagCount: item.acceptedTagCount,
            rejectedTagCount: item.rejectedTagCount,
            suggestionOrigin: mapSuggestionOrigin(item.suggestionOrigin),
            score: item.score,
            width: item.width,
            height: item.height,
            favorite: favorite.map(mapFavorite)
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
            canGenerate: overview.canGenerate,
            canUpdate: overview.canUpdate,
            canGeneratePersonalModel: overview.canGeneratePersonalModel,
            canReview: overview.canReview,
            canPause: overview.canPause,
            canResume: overview.canResume,
            canCancel: overview.canCancel,
            activeJobID: overview.activeJobID
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

    private static func mapGeneralSettings(
        _ snapshot: GeneralSettingsSnapshot
    ) -> RemoteGeneralSettingsSnapshot {
        RemoteGeneralSettingsSnapshot(
            localModel: RemoteLocalModelSettings(
                isEnabled: snapshot.localModel.isEnabled,
                state: {
                    switch snapshot.localModel.state {
                    case .disabled: .disabled
                    case .validating: .validating
                    case .ready: .ready
                    case .unavailable: .unavailable
                    }
                }(),
                modelName: snapshot.localModel.modelName,
                runtimeName: snapshot.localModel.runtimeName,
                detail: snapshot.localModel.detail
            ),
            idleThumbnailPrewarmEnabled: snapshot.idleThumbnailPrewarmEnabled,
            idleThresholdSeconds: snapshot.idleThresholdSeconds,
            toolbarDisplayMode: {
                switch snapshot.toolbarDisplayMode {
                case .iconOnly: .iconOnly
                case .iconAndTitle: .iconAndTitle
                }
            }(),
            suggestionThresholds: snapshot.suggestionThresholds.map { thresholds in
                RemoteSuggestionThresholdSnapshot(
                    defaults: thresholds.defaults.map {
                        RemoteSuggestionThresholdDefault(
                            method: Self.mapSuggestionMethod($0.method),
                            minScore: $0.minScore
                        )
                    },
                    tags: thresholds.tags.map { tag in
                        RemoteSuggestionThresholdTagRow(
                            tagID: tag.tagID,
                            displayName: tag.displayName,
                            methods: tag.methods.map { method in
                                RemoteSuggestionThresholdMethodRow(
                                    method: Self.mapSuggestionMethod(method.method),
                                    effectiveMinScore: method.effectiveMinScore,
                                    overrideMinScore: method.overrideMinScore,
                                    reference: method.reference.map {
                                        RemoteSuggestionThresholdReference(
                                            minScore: $0.minScore,
                                            acceptedSampleCount: $0.acceptedSampleCount,
                                            rejectedSampleCount: $0.rejectedSampleCount
                                        )
                                    }
                                )
                            }
                        )
                    }
                )
            },
            maxPendingSuggestionsPerTag: snapshot.maxPendingSuggestionsPerTag
        )
    }

    private static func mapSuggestionMethod(
        _ method: GeneralSettingsSuggestionMethod
    ) -> RemoteSuggestionThresholdMethod {
        switch method {
        case .featureKnn: .featureKnn
        case .personalCentroid: .personalCentroid
        case .personalAdamW: .personalAdamW
        }
    }

    private static func mapSuggestionMethod(
        _ method: RemoteSuggestionThresholdMethod
    ) -> GeneralSettingsSuggestionMethod {
        switch method {
        case .featureKnn: .featureKnn
        case .personalCentroid: .personalCentroid
        case .personalAdamW: .personalAdamW
        }
    }

    private static func mapSuggestionMutationAction(
        _ action: RemoteSuggestionThresholdMutationAction
    ) -> GeneralSettingsSuggestionMutationAction {
        switch action {
        case .setDefault: .setDefault
        case .setOverride: .setOverride
        case .clearOverride: .clearOverride
        case .prune: .prune
        }
    }

    private static func mapToolbarDisplayMode(
        _ mode: RemoteToolbarDisplayMode
    ) -> GeneralSettingsToolbarDisplayMode {
        switch mode {
        case .iconOnly: .iconOnly
        case .iconAndTitle: .iconAndTitle
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

    private enum DecisionUndoChannel: Sendable {
        case tag
        case review
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
