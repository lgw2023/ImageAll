import Foundation
import ImageAllRemoteProtocol
import XCTest
@testable import ImageAll

final class RemoteCatalogFacadeTests: XCTestCase {
    func testLegacyRemoteTagFallbackMatchesCatalogOtherGroup() {
        XCTAssertEqual(RemoteTagSummary.legacyFallbackGroupID, TagGroupSeed.other.id)
    }

    private func makeIdempotencyStore() -> RemoteIdempotencyStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteCatalogFacadeTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("idempotency.json")
        return RemoteIdempotencyStore(storageURL: url)
    }

    private func makeFacade(
        catalog: any RemoteCatalogServing,
        review: any PersonalizationReviewPort = EmptyPersonalizationReviewPort(),
        trainingWorkspace: (any TrainingWorkspacePort)? = nil,
        trainingCommands: (any RemoteTrainingCommandPort)? = nil,
        librarySlimmingAnalysis: (any LibrarySlimmingAnalysisJobPort)? = nil,
        librarySlimmingCommands: (any RemoteLibrarySlimmingCommandPort)? = nil,
        sourceManagementCommands: (any RemoteSourceManagementCommandPort)? = nil,
        storageMaintenanceCommands: (any RemoteStorageMaintenanceCommandPort)? = nil,
        generalSettingsCommands: (any RemoteGeneralSettingsCommandPort)? = nil,
        hostAppVersion: String = "1.0.0",
        listenPort: Int = 8787,
        hostID: UUID? = nil,
        usesTLS: Bool = false,
        certificateFingerprintSHA256: String? = nil
    ) -> RemoteCatalogFacade {
        RemoteCatalogFacade(
            catalog: catalog,
            review: review,
            trainingWorkspace: trainingWorkspace,
            trainingCommands: trainingCommands,
            librarySlimmingAnalysis: librarySlimmingAnalysis,
            librarySlimmingCommands: librarySlimmingCommands,
            sourceManagementCommands: sourceManagementCommands,
            storageMaintenanceCommands: storageMaintenanceCommands,
            generalSettingsCommands: generalSettingsCommands,
            idempotency: makeIdempotencyStore(),
            hostAppVersion: hostAppVersion,
            listenPort: listenPort,
            hostID: hostID,
            usesTLS: usesTLS,
            certificateFingerprintSHA256: certificateFingerprintSHA256
        )
    }

    func testGeneralSettingsUsesSharedProjectionAndIdempotentPartialUpdates() async throws {
        let tagID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let initialThresholds = GeneralSettingsSuggestionThresholds(
            defaults: [
                .init(method: .featureKnn, minScore: 0.1),
                .init(method: .personalCentroid, minScore: 0.2),
                .init(method: .personalAdamW, minScore: 0.3),
            ],
            tags: [
                .init(
                    tagID: tagID,
                    displayName: "猫",
                    methods: [
                        .init(
                            method: .featureKnn,
                            effectiveMinScore: 0.42,
                            overrideMinScore: 0.42,
                            reference: .init(
                                minScore: 0.55,
                                acceptedSampleCount: 6,
                                rejectedSampleCount: 7
                            )
                        ),
                    ]
                ),
            ]
        )
        let initial = GeneralSettingsSnapshot(
            localModel: GeneralSettingsLocalModelSummary(
                isEnabled: false,
                state: .disabled,
                modelName: "DINOv2 Small",
                runtimeName: "App 内 Core ML（本机）",
                detail: "模型不会初始化或运行。"
            ),
            idleThumbnailPrewarmEnabled: true,
            idleThresholdSeconds: 180,
            toolbarDisplayMode: .iconOnly,
            suggestionThresholds: initialThresholds
        )
        let updated = GeneralSettingsSnapshot(
            localModel: initial.localModel,
            idleThumbnailPrewarmEnabled: true,
            idleThresholdSeconds: 180,
            toolbarDisplayMode: .iconAndTitle,
            suggestionThresholds: initialThresholds
        )
        let port = RemoteGeneralSettingsCommandPortStub(
            snapshot: initial,
            updatedSnapshot: updated
        )
        let facade = makeFacade(
            catalog: RemoteCatalogServingStub(),
            generalSettingsCommands: port
        )

        let fetched = try await facade.fetchGeneralSettings()
        XCTAssertEqual(fetched.toolbarDisplayMode, .iconOnly)
        XCTAssertEqual(fetched.localModel.state, .disabled)
        XCTAssertEqual(fetched.idleThresholdSeconds, 180)
        XCTAssertEqual(fetched.suggestionThresholds?.tags.first?.displayName, "猫")
        XCTAssertEqual(
            fetched.suggestionThresholds?.tags.first?.methods.first?.reference?.minScore,
            0.55
        )

        let operationID = UUID()
        let request = RemoteGeneralSettingsUpdateRequest(
            operationID: operationID,
            toolbarDisplayMode: .iconAndTitle,
            suggestionThresholdMutation: .init(
                action: .setOverride,
                method: .featureKnn,
                tagID: tagID,
                minScore: 0.55
            )
        )
        let first = try await facade.updateGeneralSettings(request)
        let replay = try await facade.updateGeneralSettings(request)
        XCTAssertEqual(first.settings.toolbarDisplayMode, .iconAndTitle)
        XCTAssertFalse(first.replayed)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(port.updateCount, 1)
        XCTAssertEqual(port.lastUpdate?.toolbarDisplayMode, .iconAndTitle)
        XCTAssertEqual(port.lastUpdate?.suggestionThresholdMutation?.tagID, tagID)
        XCTAssertEqual(port.lastUpdate?.suggestionThresholdMutation?.minScore, 0.55)
    }

    func testMapsSourcesAndAssets() async throws {
        let sourceID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let assetID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let catalog = RemoteCatalogServingStub(
            sources: [
                LibrarySourceSummary(
                    id: sourceID,
                    kind: .folder,
                    displayName: "Archive",
                    state: .active
                ),
            ],
            tags: [
                TagListItem(
                    id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
                    displayName: "风景",
                    state: .active,
                    groupID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
                ),
            ],
            items: [
                AssetGridItemProjection(
                    assetID: assetID,
                    sourceID: sourceID,
                    sourceDisplayName: "Archive",
                    sourceState: .active,
                    relativePath: "a.jpg",
                    fileName: "a.jpg",
                    mediaType: "image",
                    mediaCreatedAtMs: 100,
                    mediaModifiedAtMs: 100,
                    width: 10,
                    height: 20,
                    availability: .available,
                    contentRevision: 2,
                    acceptedTagCount: 1,
                    rejectedTagCount: 0
                ),
            ]
        )
        let facade = makeFacade(
            catalog: catalog,
            hostAppVersion: "9.9.9",
            listenPort: 8787,
            hostID: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"),
            usesTLS: true,
            certificateFingerprintSHA256: "deadbeef"
        )

        let capabilities = await facade.capabilities()
        XCTAssertEqual(capabilities.protocolVersion, RemoteProtocolVersion.current)
        XCTAssertEqual(capabilities.hostAppVersion, "9.9.9")
        XCTAssertEqual(capabilities.listenPort, 8787)
        XCTAssertTrue(capabilities.usesTLS)
        XCTAssertEqual(capabilities.hostID, UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"))
        XCTAssertEqual(capabilities.certificateFingerprintSHA256, "deadbeef")

        let sources = try await facade.fetchSources()
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].displayName, "Archive")
        XCTAssertEqual(sources[0].kind, .folder)

        let tags = try await facade.fetchTags()
        XCTAssertEqual(tags.count, 1)
        XCTAssertEqual(tags[0].displayName, "风景")

        let page = try await facade.fetchAssets(RemoteAssetPageRequest(limit: 10))
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].id, assetID)
        XCTAssertEqual(page.items[0].acceptedTagCount, 1)
    }

    func testSourceManagementMapsPrewarmProgressAndSubmission() async throws {
        let sourceID = UUID()
        let operationID = UUID()
        let requestID = UUID()
        let request = SourceManagementCommandRequestSnapshot(
            id: requestID,
            operationID: operationID,
            action: .prewarmOriginalAspect,
            sourceID: sourceID,
            sourceDisplayName: "Apple Photos",
            phase: .running,
            message: "正在预热原比例缓存 4 / 10",
            completedCount: 4,
            totalCount: 10,
            warmedCount: 3,
            failedCount: 1,
            updatedAtMs: 123
        )
        let commands = RemoteSourceManagementCommandPortStub(
            snapshot: SourceManagementCommandSnapshot(
                sources: [
                    LibrarySourceSummary(
                        id: sourceID,
                        kind: .photos,
                        displayName: "Apple Photos",
                        state: .active
                    ),
                ],
                requests: [request]
            ),
            receipt: request
        )
        let facade = makeFacade(
            catalog: RemoteCatalogServingStub(),
            sourceManagementCommands: commands
        )

        let snapshot = try await facade.fetchSourceManagement()
        XCTAssertFalse(snapshot.canConnectPhotos)
        XCTAssertEqual(snapshot.sources.first?.kind, .photos)
        XCTAssertEqual(snapshot.requests.first?.phase, .running)
        XCTAssertEqual(snapshot.requests.first?.completedCount, 4)
        XCTAssertEqual(snapshot.requests.first?.totalCount, 10)
        XCTAssertEqual(snapshot.requests.first?.warmedCount, 3)
        XCTAssertEqual(snapshot.requests.first?.failedCount, 1)

        let submitted = try await facade.submitSourceManagement(
            RemoteSourceManagementSubmitRequest(
                operationID: operationID,
                action: .prewarmOriginalAspect,
                sourceID: sourceID
            )
        )
        XCTAssertEqual(submitted.id, requestID)
        XCTAssertEqual(commands.lastCommand?.action, .prewarmOriginalAspect)
        XCTAssertEqual(commands.lastCommand?.sourceID, sourceID)

        _ = try await facade.submitSourceManagement(
            RemoteSourceManagementSubmitRequest(
                operationID: UUID(),
                action: .requestPhotosWriteAuthorization,
                sourceID: sourceID
            )
        )
        XCTAssertEqual(commands.lastCommand?.action, .requestPhotosWriteAuthorization)
    }

    func testStorageMaintenanceMapsRedactedUsageAndSubmission() async throws {
        let operationID = UUID()
        let requestID = UUID()
        let request = StorageMaintenanceCommandRequestSnapshot(
            id: requestID,
            operationID: operationID,
            action: .chooseExternalStorage,
            phase: .awaitingMac,
            message: "请回到 Mac 选择外置应用存储位置",
            updatedAtMs: 456,
            result: nil
        )
        let commands = RemoteStorageMaintenanceCommandPortStub(
            snapshot: StorageMaintenanceCommandSnapshot(
                previewCache: StorageMaintenanceUsageSummary(
                    entryCount: 12,
                    registeredBytes: 1_500_000
                ),
                photosOriginals: StorageMaintenanceUsageSummary(
                    entryCount: 3,
                    registeredBytes: 9_000_000
                ),
                appStorage: StorageMaintenanceAppStorageSummary(
                    kind: .internalStorage,
                    requiresRestart: true,
                    pendingExternalRootName: "ImageAll-External"
                ),
                requests: [request]
            ),
            receipt: request
        )
        let facade = makeFacade(
            catalog: RemoteCatalogServingStub(),
            storageMaintenanceCommands: commands
        )

        let snapshot = try await facade.fetchStorageMaintenance()
        XCTAssertEqual(snapshot.previewCache.registeredBytes, 1_500_000)
        XCTAssertEqual(snapshot.photosOriginals.entryCount, 3)
        XCTAssertEqual(snapshot.appStorage.kind, .internalStorage)
        XCTAssertEqual(snapshot.appStorage.pendingExternalRootName, "ImageAll-External")
        XCTAssertEqual(snapshot.requests.first?.phase, .awaitingMac)

        let submitted = try await facade.submitStorageMaintenance(
            RemoteStorageMaintenanceSubmitRequest(
                operationID: operationID,
                action: .chooseExternalStorage
            )
        )
        XCTAssertEqual(submitted.id, requestID)
        XCTAssertEqual(commands.lastCommand?.action, .chooseExternalStorage)
    }

    func testMapsSanitizedTrainingWorkspaceProjection() async throws {
        let runID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let tagID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let batchID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let training = RemoteTrainingWorkspacePortStub(
            snapshot: TrainingWorkspaceSnapshot(
                runs: [
                    TrainingRunRecord(
                        id: runID,
                        mediaKind: .video,
                        method: .personalAdamW,
                        state: .succeeded,
                        createdAtMs: 1_700_000_000_000,
                        startedAtMs: 1_700_000_001_000,
                        finishedAtMs: 1_700_000_002_000,
                        catalogScopeID: "allSources",
                        jobID: UUID(),
                        tagID: tagID,
                        sampleSummaryJSON: #"{"batchID":"99999999-9999-9999-9999-999999999999","batchTagIndex":1,"batchTagCount":3,"sampleCount":12,"perTag":[{"tagID":"77777777-7777-7777-7777-777777777777","positiveCount":8,"negativeCount":4}],"originalPath":"/private/source.mov"}"#,
                        sampleManifestSHA256: String(repeating: "b", count: 64),
                        configJSON: "{\"epochs\":8,\"bookmarkData\":\"secret\"}",
                        metricsJSON: "{\"evaluationSplit\":\"validation\"}",
                        artifactKind: "personal-head",
                        artifactRef: "/private/model.personal-head",
                        artifactSHA256: String(repeating: "a", count: 64),
                        resultSummaryJSON: "{\"published\":true,\"fileName\":\"private.bin\"}",
                        errorCode: nil
                    ),
                ],
                slots: [
                    TrainingWorkspaceSlot(
                        method: .personalAdamW,
                        isPublished: true,
                        publishedRunID: runID,
                        artifactRef: "objects/model.personal-head"
                    ),
                ]
            )
        )
        let facade = makeFacade(
            catalog: RemoteCatalogServingStub(
                tags: [
                    TagListItem(
                        id: tagID,
                        displayName: "历史猫标签",
                        state: .archived
                    ),
                ]
            ),
            trainingWorkspace: training
        )

        let result = try await facade.fetchTrainingWorkspace(
            mediaKind: .video,
            method: .personalAdamW
        )

        XCTAssertEqual(training.lastMediaKind, .video)
        XCTAssertEqual(training.lastMethod, .personalAdamW)
        XCTAssertEqual(result.runs.first?.id, runID)
        XCTAssertEqual(result.runs.first?.tagDisplayName, "历史猫标签")
        XCTAssertEqual(result.runs.first?.batchID, batchID)
        XCTAssertEqual(result.runs.first?.batchTagIndex, 1)
        XCTAssertEqual(result.runs.first?.batchTagCount, 3)
        XCTAssertEqual(result.runs.first?.sampleCount, 12)
        XCTAssertEqual(result.runs.first?.positiveSampleCount, 8)
        XCTAssertEqual(result.runs.first?.negativeSampleCount, 4)
        XCTAssertNil(result.runs.first?.artifactRef)
        XCTAssertFalse(result.runs.first?.sampleSummaryJSON?.contains("originalPath") == true)
        XCTAssertFalse(result.runs.first?.configJSON?.contains("bookmarkData") == true)
        XCTAssertFalse(result.runs.first?.resultSummaryJSON?.contains("fileName") == true)
        XCTAssertEqual(result.slots.first?.artifactRef, "objects/model.personal-head")
    }

    func testMapsSafeTrainingRecoveryAndFailureGuidance() async throws {
        let runID = UUID(uuidString: "66000000-0000-4000-8000-000000000001")!
        let tagID = UUID(uuidString: "77000000-0000-4000-8000-000000000001")!
        let sourceID = UUID(uuidString: "88000000-0000-4000-8000-000000000001")!
        let training = RemoteTrainingWorkspacePortStub(
            snapshot: TrainingWorkspaceSnapshot(
                runs: [
                    TrainingRunRecord(
                        id: runID,
                        method: .featureKnn,
                        state: .failed,
                        createdAtMs: 1_700_000_000_000,
                        startedAtMs: 1_700_000_001_000,
                        finishedAtMs: 1_700_000_002_000,
                        catalogScopeID: "scope-v1",
                        jobID: UUID(),
                        tagID: tagID,
                        sampleSummaryJSON: #"{"scopeKind":"selectedSources","tagIDs":["77000000-0000-4000-8000-000000000001"]}"#,
                        sampleManifestSHA256: nil,
                        configJSON: #"{"sourceIDs":["88000000-0000-4000-8000-000000000001"]}"#,
                        metricsJSON: "{}",
                        artifactKind: nil,
                        artifactRef: nil,
                        artifactSHA256: nil,
                        resultSummaryJSON: "{}",
                        errorCode: "staleSnapshot"
                    ),
                ],
                slots: []
            )
        )
        let facade = makeFacade(
            catalog: RemoteCatalogServingStub(),
            trainingWorkspace: training
        )

        let result = try await facade.fetchTrainingWorkspace(mediaKind: .image, method: nil)
        let run = try XCTUnwrap(result.runs.first)

        XCTAssertEqual(run.recoveryContext?.tagIDs, [tagID])
        XCTAssertEqual(run.recoveryContext?.sourceIDs, [sourceID])
        XCTAssertEqual(run.recoveryContext?.scope, .selectedSources)
        XCTAssertEqual(run.recoveryContext?.isExact, true)
        XCTAssertEqual(run.failureGuidance?.title, "训练数据已经变化")
        XCTAssertFalse(run.failureGuidance?.message.contains("/") == true)
    }

    func testMapsInterruptedPersonalBatchRecoveryWithoutLeakingLocalState() async throws {
        let runID = UUID(uuidString: "66000000-0000-4000-8000-000000000002")!
        let firstTagID = UUID(uuidString: "77000000-0000-4000-8000-000000000001")!
        let secondTagID = UUID(uuidString: "77000000-0000-4000-8000-000000000002")!
        let training = RemoteTrainingWorkspacePortStub(
            snapshot: TrainingWorkspaceSnapshot(
                runs: [
                    TrainingRunRecord(
                        id: runID,
                        method: .personalAdamW,
                        state: .failed,
                        createdAtMs: 1_700_000_000_000,
                        startedAtMs: 1_700_000_001_000,
                        finishedAtMs: 1_700_000_002_000,
                        catalogScopeID: "scope-v1",
                        jobID: nil,
                        tagID: firstTagID,
                        sampleSummaryJSON: #"{"batchTagIDs":["77000000-0000-4000-8000-000000000001","77000000-0000-4000-8000-000000000002"],"originalPath":"/private/photos"}"#,
                        sampleManifestSHA256: nil,
                        configJSON: "{}",
                        metricsJSON: "{}",
                        artifactKind: nil,
                        artifactRef: nil,
                        artifactSHA256: nil,
                        resultSummaryJSON: #"{"interruptedByHostRestart":true,"temporaryPath":"/private/model"}"#,
                        errorCode: "hostRestartInterrupted"
                    ),
                ],
                slots: []
            )
        )
        let facade = makeFacade(
            catalog: RemoteCatalogServingStub(),
            trainingWorkspace: training
        )

        let result = try await facade.fetchTrainingWorkspace(
            mediaKind: .image,
            method: .personalAdamW
        )
        let run = try XCTUnwrap(result.runs.first)

        XCTAssertEqual(run.recoveryContext?.tagIDs, [firstTagID, secondTagID])
        XCTAssertEqual(run.recoveryContext?.scope, .unresolved)
        XCTAssertEqual(run.recoveryContext?.isExact, false)
        XCTAssertEqual(run.failureGuidance?.title, "训练被 App 重启中断")
        XCTAssertTrue(run.failureGuidance?.suggestedAction.contains("原批次标签") == true)
        XCTAssertFalse(run.sampleSummaryJSON?.contains("originalPath") == true)
        XCTAssertFalse(run.resultSummaryJSON?.contains("temporaryPath") == true)
    }

    func testTrainingSetupAndLaunchReuseHostValidationAndIdempotency() async throws {
        let tagID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let sourceID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let operationID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let commands = RemoteTrainingCommandPortStub(
            setup: TrainingCommandSetupSnapshot(
                mediaKind: .video,
                tags: [
                    TrainingCommandTagOption(
                        id: tagID,
                        displayName: "猫",
                        acceptedSampleCount: 5,
                        rejectedSampleCount: 3,
                        featureMode: .update,
                        personalEligible: true
                    ),
                ],
                sources: [TrainingCommandSourceOption(id: sourceID, displayName: "Archive")],
                supportsPersonalCentroid: true,
                supportsPersonalAdamW: false
            ),
            receipt: TrainingLaunchReceipt(
                operationID: operationID,
                method: .featureKnn,
                acceptedAtMs: 1_700_000_000_000,
                scheduledTagCount: 1,
                jobID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
            ),
            cancelledActivity: TrainingCommandActivitySnapshot(
                operationID: operationID,
                mediaKind: .video,
                method: .personalCentroid,
                phase: .cancelled,
                completedUnitCount: 1,
                totalUnitCount: 2,
                sampleCount: nil,
                errorCode: nil,
                tagActivities: [
                    TrainingCommandTagActivitySnapshot(
                        tagID: tagID,
                        displayName: "猫",
                        phase: .cancelled,
                        sampleCount: 9,
                        errorCode: nil
                    ),
                ],
                acceptedAtMs: 1_700_000_010_000,
                updatedAtMs: 1_700_000_011_000
            )
        )
        let facade = makeFacade(
            catalog: RemoteCatalogServingStub(),
            trainingCommands: commands
        )

        let setup = try await facade.fetchTrainingSetup(mediaKind: .video)
        XCTAssertEqual(setup.mediaKind, .video)
        XCTAssertEqual(setup.tags.first?.displayName, "猫")
        XCTAssertEqual(setup.tags.first?.featureMode, .update)
        XCTAssertTrue(setup.methods.first(where: { $0.method == .personalCentroid })?.isAvailable == true)
        XCTAssertTrue(setup.methods.first(where: { $0.method == .personalAdamW })?.isAvailable == false)

        let request = RemoteTrainingLaunchRequest(
            operationID: operationID,
            mediaKind: .video,
            method: .featureKnn,
            tagIDs: [tagID],
            sourceIDs: [sourceID]
        )
        let first = try await facade.launchTraining(request)
        let replay = try await facade.launchTraining(request)
        XCTAssertFalse(first.replayed)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(first.jobID, replay.jobID)
        XCTAssertEqual(commands.launchCount, 1)
        XCTAssertEqual(commands.lastCommand?.mediaKind, .video)
        XCTAssertEqual(commands.lastCommand?.tagIDs, [tagID])
        XCTAssertEqual(commands.lastCommand?.sourceIDs, [sourceID])

        let cancelled = try await facade.applyTrainingActivityAction(
            operationID: operationID,
            request: RemoteTrainingActivityActionRequest(action: .cancel)
        )
        XCTAssertEqual(cancelled.activity.phase, .cancelled)
        XCTAssertEqual(cancelled.activity.availableActions, [])
        XCTAssertEqual(cancelled.activity.tagActivities.first?.displayName, "猫")
        XCTAssertEqual(cancelled.activity.tagActivities.first?.phase, .cancelled)
        XCTAssertEqual(cancelled.activity.acceptedAtMs, 1_700_000_010_000)
        XCTAssertEqual(cancelled.activity.updatedAtMs, 1_700_000_011_000)
        XCTAssertEqual(commands.cancelCount, 1)
    }

    func testEmbeddingPreparationMapsSelectionProgressReplayAndCancel() async throws {
        let operationID = UUID(uuidString: "99111111-1111-1111-1111-111111111111")!
        let assetIDs: Set<UUID> = [
            UUID(uuidString: "99222222-2222-2222-2222-222222222222")!,
            UUID(uuidString: "99333333-3333-3333-3333-333333333333")!,
        ]
        let activity = EmbeddingPreparationActivitySnapshot(
            operationID: operationID,
            mediaKind: .image,
            phase: .running,
            completedUnitCount: 1,
            totalUnitCount: 2,
            preparedCount: 1,
            cachedCount: 0,
            cloudOnlyCount: 0,
            failedCount: 0,
            errorCode: nil
        )
        let commands = RemoteTrainingCommandPortStub(
            setup: TrainingCommandSetupSnapshot(
                mediaKind: .image,
                tags: [],
                sources: [],
                supportsPersonalCentroid: true,
                supportsPersonalAdamW: false
            ),
            receipt: TrainingLaunchReceipt(
                operationID: UUID(),
                method: .personalCentroid,
                acceptedAtMs: 0,
                scheduledTagCount: 0,
                jobID: nil
            ),
            embeddingActivity: activity
        )
        let facade = makeFacade(
            catalog: RemoteCatalogServingStub(),
            trainingCommands: commands
        )

        let snapshot = try await facade.fetchEmbeddingPreparation(mediaKind: .image)
        XCTAssertTrue(snapshot.isAvailable)
        XCTAssertEqual(snapshot.activities.first?.preparedCount, 1)
        XCTAssertEqual(snapshot.activities.first?.availableActions, [.cancel])

        let submitted = try await facade.submitEmbeddingPreparation(
            RemoteEmbeddingPreparationRequest(
                operationID: operationID,
                mediaKind: .image,
                assetIDs: Array(assetIDs)
            )
        )
        XCTAssertFalse(submitted.replayed)
        XCTAssertEqual(commands.embeddingPrepareCount, 1)
        XCTAssertEqual(commands.lastEmbeddingCommand?.assetIDs, assetIDs)

        let cancelled = try await facade.applyEmbeddingPreparationAction(
            operationID: operationID,
            request: RemoteEmbeddingPreparationActionRequest(action: .cancel)
        )
        XCTAssertEqual(cancelled.activity.phase, .cancelled)
        XCTAssertEqual(cancelled.activity.availableActions, [])
        XCTAssertEqual(commands.embeddingCancelCount, 1)
    }

    func testEmbeddingPreparationServiceGeneratesOnceAndReplaysLatestActivity() async throws {
        let operationID = UUID(uuidString: "99444444-4444-4444-4444-444444444444")!
        let assetID = UUID(uuidString: "99555555-5555-5555-5555-555555555555")!
        let cache = RemoteEmbeddingCacheStub()
        let catalog = RemoteCatalogServingStub(
            previewData: Data([1, 2, 3]),
            detail: AssetInspectorDetail(
                assetID: assetID,
                sourceID: UUID(),
                sourceDisplayName: "Fixture",
                sourceState: .active,
                relativePath: "fixture.jpg",
                fileName: "fixture.jpg",
                mediaKind: .image,
                mediaType: "public.jpeg",
                mediaCreatedAtMs: nil,
                mediaModifiedAtMs: nil,
                width: 10,
                height: 10,
                availability: .available,
                contentRevision: 3,
                acceptedTagCount: 0,
                rejectedTagCount: 0,
                fingerprintSizeBytes: nil,
                fingerprintModifiedAtNs: nil,
                tags: []
            )
        )
        let service = RemoteTrainingCommandService(
            catalog: catalog,
            review: EmptyPersonalizationReviewPort(),
            centroidRebuilder: nil,
            adamWRebuilder: nil,
            embeddingCache: cache
        )
        let command = EmbeddingPreparationCommand(
            operationID: operationID,
            mediaKind: .image,
            assetIDs: [assetID]
        )

        let preparationAvailable = await service.embeddingPreparationAvailable()
        XCTAssertTrue(preparationAvailable)
        let first = try await service.prepareEmbeddings(command)
        XCTAssertFalse(first.replayed)
        var activities = await service.embeddingPreparationActivities(mediaKind: .image)
        for _ in 0..<50 where activities.first?.phase == .running {
            try await Task.sleep(for: .milliseconds(10))
            activities = await service.embeddingPreparationActivities(mediaKind: .image)
        }
        XCTAssertEqual(activities.first?.phase, .completed)
        XCTAssertEqual(activities.first?.preparedCount, 1)
        XCTAssertEqual(activities.first?.completedUnitCount, 1)
        let initialCacheCallCount = cache.callCount
        XCTAssertEqual(initialCacheCallCount, 1)

        let replay = try await service.prepareEmbeddings(command)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.activity.phase, .completed)
        let replayCacheCallCount = cache.callCount
        XCTAssertEqual(replayCacheCallCount, 1)
    }

    func testSampleSuggestionServiceUsesSelectedCandidatesAndReplaysCompletedActivity() async throws {
        let operationID = UUID(uuidString: "99666666-6666-6666-6666-666666666666")!
        let assetID = UUID(uuidString: "99777777-7777-7777-7777-777777777777")!
        let cache = RemoteEmbeddingCacheStub()
        let suggester = RemoteSampleSuggesterStub()
        let catalog = RemoteCatalogServingStub(
            previewData: Data([1, 2, 3]),
            detail: AssetInspectorDetail(
                assetID: assetID,
                sourceID: UUID(),
                sourceDisplayName: "Fixture",
                sourceState: .active,
                relativePath: "fixture.jpg",
                fileName: "fixture.jpg",
                mediaKind: .image,
                mediaType: "public.jpeg",
                mediaCreatedAtMs: nil,
                mediaModifiedAtMs: nil,
                width: 10,
                height: 10,
                availability: .available,
                contentRevision: 4,
                acceptedTagCount: 0,
                rejectedTagCount: 0,
                fingerprintSizeBytes: nil,
                fingerprintModifiedAtNs: nil,
                tags: []
            )
        )
        let service = RemoteTrainingCommandService(
            catalog: catalog,
            review: EmptyPersonalizationReviewPort(),
            centroidRebuilder: nil,
            adamWRebuilder: nil,
            embeddingCache: cache,
            sampleSuggester: suggester,
            sampleSuggestionLimit: { 12 }
        )
        let command = SampleSuggestionCommand(
            operationID: operationID,
            mediaKind: .image,
            assetIDs: [assetID]
        )

        let isAvailable = await service.sampleSuggestionsAvailable(mediaKind: .image)
        let maximumCount = await service.sampleSuggestionMaximumCount()
        XCTAssertTrue(isAvailable)
        XCTAssertEqual(maximumCount, 12)
        let first = try await service.generateSampleSuggestions(command)
        XCTAssertFalse(first.replayed)
        var activities = await service.sampleSuggestionActivities(mediaKind: .image)
        for _ in 0..<50 where activities.first?.phase == .running {
            try await Task.sleep(for: .milliseconds(10))
            activities = await service.sampleSuggestionActivities(mediaKind: .image)
        }
        XCTAssertEqual(activities.first?.phase, .completed)
        XCTAssertEqual(activities.first?.totalUnitCount, 1)
        XCTAssertEqual(activities.first?.skippedCount, 1)
        let requestedCandidates = await suggester.candidates()
        XCTAssertEqual(requestedCandidates, [
            PersonalSuggestionCandidate(assetID: assetID, contentRevision: 4),
        ])
        XCTAssertEqual(cache.callCount, 1)

        let replay = try await service.generateSampleSuggestions(command)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.activity.phase, .completed)
        let suggestionCallCount = await suggester.callCount()
        XCTAssertEqual(suggestionCallCount, 1)
        XCTAssertEqual(cache.callCount, 1)
    }

    func testTagLibrarySuggestionServiceScansSelectedSourcesPublishesAndReplays() async throws {
        let operationID = UUID(uuidString: "99911111-1111-1111-1111-111111111111")!
        let tagID = UUID(uuidString: "99922222-2222-2222-2222-222222222222")!
        let sourceID = UUID(uuidString: "99933333-3333-3333-3333-333333333333")!
        let candidateIDs = [
            UUID(uuidString: "99944444-4444-4444-4444-444444444444")!,
            UUID(uuidString: "99955555-5555-5555-5555-555555555555")!,
        ]
        let candidates = [
            PersonalSuggestionCandidate(assetID: candidateIDs[0], contentRevision: 4),
            PersonalSuggestionCandidate(assetID: candidateIDs[1], contentRevision: 7),
        ]
        let overview = SuggestionTagOverview(
            id: tagID,
            displayName: "猫",
            acceptedSampleCount: 8,
            rejectedSampleCount: 5,
            pendingSuggestionCount: 0,
            taskStatus: .ready,
            checkedCount: 0,
            totalCount: nil,
            skippedCount: 0,
            missingPositiveCount: 0,
            missingNegativeCount: 0,
            canGenerate: true,
            canUpdate: false,
            canGeneratePersonalModel: true,
            canReview: false,
            canPause: false,
            canResume: false,
            canCancel: false,
            activeJobID: nil
        )
        let review = RemoteReviewPortStub(
            page: ReviewQueuePage(items: [], nextCursor: nil),
            overviews: [overview],
            personalCandidates: candidates,
            personalTagInsertedCount: 1
        )
        let catalog = RemoteCatalogServingStub(
            sources: [
                LibrarySourceSummary(
                    id: sourceID,
                    kind: .photos,
                    displayName: "Apple Photos",
                    state: .active
                ),
            ],
            previewData: Data([1, 2, 3])
        )
        let cache = RemoteEmbeddingCacheStub()
        let suggester = RemoteTagLibrarySuggesterStub(tagID: tagID)
        let service = RemoteTrainingCommandService(
            catalog: catalog,
            review: review,
            centroidRebuilder: nil,
            adamWRebuilder: nil,
            embeddingCache: cache,
            centroidTagSuggester: suggester,
            sampleSuggestionLimit: { 17 },
            tagSuggestionMinimumScore: { requestedTagID, method in
                guard requestedTagID == tagID else {
                    throw TrainingCommandError.invalidSelection
                }
                return method == .personalCentroid ? 0.42 : 0.61
            }
        )

        let available = await service.tagLibrarySuggestionsAvailable(
            mediaKind: .image,
            method: .personalCentroid
        )
        XCTAssertTrue(available)
        let options = try await service.tagLibrarySuggestionTagOptions(mediaKind: .image)
        XCTAssertEqual(options.first?.personalCentroidMinScore, 0.42)

        let command = TagLibrarySuggestionCommand(
            operationID: operationID,
            mediaKind: .image,
            method: .personalCentroid,
            tagID: tagID,
            sourceIDs: [sourceID]
        )
        let first = try await service.generateTagLibrarySuggestions(command)
        XCTAssertFalse(first.replayed)
        var activities = await service.tagLibrarySuggestionActivities(mediaKind: .image)
        for _ in 0..<80 where activities.first.map({
            [.preparingCandidates, .scoring, .publishing].contains($0.phase)
        }) == true {
            try await Task.sleep(for: .milliseconds(10))
            activities = await service.tagLibrarySuggestionActivities(mediaKind: .image)
        }

        XCTAssertEqual(activities.first?.phase, .completed)
        XCTAssertEqual(activities.first?.completedUnitCount, 2)
        XCTAssertEqual(activities.first?.aboveThresholdCount, 1)
        XCTAssertEqual(activities.first?.insertedCount, 1)
        XCTAssertEqual(activities.first?.skippedCount, 1)
        XCTAssertEqual(review.candidateSourceIDs, [sourceID])
        XCTAssertEqual(review.candidateExcludedTagID, tagID)
        XCTAssertEqual(review.publishedTagID, tagID)
        XCTAssertEqual(review.publishedHits.map(\.candidate), [candidates[0]])
        XCTAssertEqual(cache.callCount, 2)
        let invocation = await suggester.invocation()
        XCTAssertEqual(invocation?.tagID, tagID)
        XCTAssertEqual(invocation?.candidates, candidates)
        XCTAssertEqual(invocation?.maximumPendingCount, 17)
        XCTAssertEqual(invocation?.minimumScore, 0.42)

        let replay = try await service.generateTagLibrarySuggestions(command)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.activity.phase, .completed)
        let suggestionCallCount = await suggester.callCount()
        XCTAssertEqual(suggestionCallCount, 1)
        XCTAssertEqual(cache.callCount, 2)
    }

    func testMapsLibrarySlimmingHistoryClustersAndSelectedMembers() async throws {
        let jobID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let clusterID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let assetID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let sourceID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        let result = LibrarySlimmingScanResult(
            clusters: [
                SlimmingCluster(
                    id: clusterID,
                    kind: .nearDuplicateScene,
                    memberAssetIDs: [assetID],
                    representativeAssetID: assetID,
                    score: 0.92,
                    modelIdentity: .featurePrintOnly
                ),
            ],
            pendingAnalysisAssetIDs: [],
            analyzedAssetCount: 1,
            policyVersion: "librarySlimming.v1"
        )
        let analysis = RemoteLibrarySlimmingAnalysisPortStub(
            summaries: [
                LibrarySlimmingAnalysisJobSummary(
                    jobID: jobID,
                    mode: .catalog,
                    mediaKind: .image,
                    state: .running,
                    controlRequest: .pause,
                    progress: JobProgress(completed: 1, total: 3),
                    attempts: 1,
                    maxAttempts: 10,
                    memberCount: 1,
                    seedCount: 0,
                    clusterCount: 1,
                    hasResult: true,
                    createdAtMs: 100,
                    updatedAtMs: 200,
                    sourceNames: ["Apple Photos"],
                    lastErrorCode: .interrupted
                ),
            ],
            snapshot: LibrarySlimmingAnalysisJobSnapshot(
                jobID: jobID,
                state: .running,
                controlRequest: .pause,
                progress: JobProgress(completed: 1, total: 3),
                result: result
            )
        )
        let catalog = RemoteCatalogServingStub(
            detail: AssetInspectorDetail(
                assetID: assetID,
                sourceID: sourceID,
                sourceDisplayName: "Apple Photos",
                sourceState: .active,
                relativePath: nil,
                fileName: "IMG_0001.HEIC",
                mediaType: "public.heic",
                mediaCreatedAtMs: 100,
                mediaModifiedAtMs: 100,
                width: 3024,
                height: 4032,
                availability: .available,
                contentRevision: 2,
                acceptedTagCount: 0,
                rejectedTagCount: 0,
                fingerprintSizeBytes: nil,
                fingerprintModifiedAtNs: nil,
                tags: []
            ),
            jobs: [
                JobActivityItem(
                    id: jobID,
                    kind: .librarySlimmingAnalysis,
                    state: .running,
                    controlRequest: .pause,
                    progress: JobProgress(completed: 1, total: 3)
                ),
            ]
        )
        let facade = makeFacade(catalog: catalog, librarySlimmingAnalysis: analysis)

        let snapshot = try await facade.fetchLibrarySlimmingWorkspace(
            mediaKind: .image,
            jobID: jobID,
            clusterID: clusterID
        )

        XCTAssertEqual(analysis.lastMediaKind, .image)
        XCTAssertEqual(analysis.lastSnapshotJobID, jobID)
        XCTAssertEqual(snapshot.selectedJobID, jobID)
        XCTAssertEqual(snapshot.selectedClusterID, clusterID)
        XCTAssertEqual(snapshot.clusters.first?.kind, .nearDuplicateScene)
        XCTAssertEqual(snapshot.members.first?.fileName, "IMG_0001.HEIC")
        XCTAssertEqual(snapshot.members.first?.sourceName, "Apple Photos")
        XCTAssertEqual(snapshot.policyVersion, "librarySlimming.v1")
        XCTAssertEqual(snapshot.jobs.first?.controlRequest, .pause)
        XCTAssertEqual(snapshot.jobs.first?.scanProgress?.phase, .loadingFeaturePrints)
        XCTAssertEqual(snapshot.jobs.first?.scanProgress?.completedUnitCount, 0)
        XCTAssertEqual(snapshot.jobs.first?.scanProgress?.totalUnitCount, 1)
        XCTAssertEqual(snapshot.jobs.first?.lastErrorCode, "interrupted")
        XCTAssertTrue(snapshot.clusters.first?.technicalSummary?.contains("DINOv2 余弦") == true)

        let activities = try await facade.fetchJobActivity()
        XCTAssertEqual(activities.first?.controlRequest, .pause)
        XCTAssertEqual(activities.first?.attempts, 1)
        XCTAssertEqual(activities.first?.maxAttempts, 10)
        XCTAssertEqual(activities.first?.lastErrorCode, "interrupted")
        XCTAssertEqual(activities.first?.navigationTarget?.workspace, .librarySlimming)
        XCTAssertEqual(activities.first?.navigationTarget?.recordID, jobID)
        XCTAssertEqual(activities.first?.navigationTarget?.mediaKind, .image)
    }

    func testLibrarySlimmingSetupLaunchActionsAndThresholdsAreMappedIdempotently() async throws {
        let sourceID = UUID(uuidString: "51000000-0000-0000-0000-000000000001")!
        let operationID = UUID(uuidString: "52000000-0000-0000-0000-000000000002")!
        let jobID = UUID(uuidString: "53000000-0000-0000-0000-000000000003")!
        let thresholds = NearDuplicateSceneThresholds(
            featurePrintRecallTopK: 24,
            featurePrintMaxL2Distance: 0.42,
            dinoCosineMinSimilarity: 0.83,
            sceneBucketActivationAssetCount: 500,
            featurePrintRecallMode: .topK,
            featurePrintL2Mode: .radius,
            dinoCosineMode: .minimum,
            sceneBucketingMode: .automatic
        )
        let commands = RemoteLibrarySlimmingCommandPortStub(
            setup: LibrarySlimmingCommandSetupSnapshot(
                mediaKind: .image,
                sources: [
                    LibrarySourceSummary(
                        id: sourceID,
                        kind: .photos,
                        displayName: "Apple Photos",
                        state: .active
                    ),
                ],
                thresholds: thresholds,
                factoryThresholds: .factory
            ),
            receipt: LibrarySlimmingLaunchReceipt(
                operationID: operationID,
                jobID: jobID,
                acceptedAtMs: 123,
                memberCount: 8
            )
        )
        let facade = makeFacade(
            catalog: RemoteCatalogServingStub(),
            librarySlimmingCommands: commands
        )

        let setup = try await facade.fetchLibrarySlimmingSetup(mediaKind: .image)
        XCTAssertEqual(setup.sources.map(\.id), [sourceID])
        XCTAssertEqual(setup.thresholds.featurePrintRecallTopK, 24)

        let request = RemoteLibrarySlimmingLaunchRequest(
            operationID: operationID,
            mediaKind: .image,
            mode: .catalog,
            sourceIDs: nil
        )
        let first = try await facade.launchLibrarySlimming(request)
        let replay = try await facade.launchLibrarySlimming(request)
        XCTAssertEqual(first.jobID, jobID)
        XCTAssertFalse(first.replayed)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(commands.launchCount, 1)
        XCTAssertNil(commands.lastLaunch?.sourceIDs)

        let thresholdRequest = RemoteLibrarySlimmingThresholdUpdateRequest(
            operationID: UUID(),
            thresholds: setup.thresholds
        )
        let updated = try await facade.updateLibrarySlimmingThresholds(thresholdRequest)
        XCTAssertEqual(updated.thresholds, setup.thresholds)
        XCTAssertEqual(commands.thresholdUpdateCount, 1)

        let action = try await facade.applyLibrarySlimmingJobAction(
            jobID: jobID,
            request: RemoteLibrarySlimmingJobActionRequest(
                operationID: UUID(),
                action: .deleteRecord
            )
        )
        XCTAssertTrue(action.deleted)
        XCTAssertEqual(commands.lastAction, .deleteRecord)
    }

    func testLibrarySlimmingRecycleMapsSafeProjectionAndMacApprovalRequest() async throws {
        let entryID = UUID()
        let photosEntryID = UUID()
        let refreshOnlyEntryID = UUID()
        let assetID = UUID()
        let sourceID = UUID()
        let operationID = UUID()
        let requestSnapshot = LibrarySlimmingRecycleCommandRequestSnapshot(
            id: UUID(),
            operationID: operationID,
            entryID: entryID,
            action: .restore,
            fileName: "IMG_0001.HEIC",
            phase: .awaitingMac,
            message: "请回到 Mac 完成原生确认",
            updatedAtMs: 123
        )
        let commands = RemoteLibrarySlimmingCommandPortStub(
            setup: LibrarySlimmingCommandSetupSnapshot(
                mediaKind: .image,
                sources: [],
                thresholds: .factory,
                factoryThresholds: .factory
            ),
            receipt: LibrarySlimmingLaunchReceipt(
                operationID: UUID(),
                jobID: UUID(),
                acceptedAtMs: 0,
                memberCount: 0
            ),
            recycleSnapshot: LibrarySlimmingRecycleCommandSnapshot(
                entries: [
                    RecycleEntryRecord(
                        id: entryID,
                        assetID: assetID,
                        sourceID: sourceID,
                        sourceKind: .file,
                        mediaKind: .image,
                        trashedAtMs: 100,
                        purgeAfterMs: 200,
                        state: .recycled,
                        quarantineRelativePath: "private/quarantine/path",
                        originalRelativePath: "private/original/path",
                        photosLocalIdentifier: nil,
                        errorCode: nil,
                        fileName: "IMG_0001.HEIC"
                    ),
                    RecycleEntryRecord(
                        id: photosEntryID,
                        assetID: UUID(),
                        sourceID: sourceID,
                        sourceKind: .photos,
                        mediaKind: .image,
                        trashedAtMs: 100,
                        purgeAfterMs: 200,
                        state: .recycled,
                        quarantineRelativePath: nil,
                        originalRelativePath: nil,
                        photosLocalIdentifier: "private-photos-identifier",
                        errorCode: nil,
                        fileName: "IMG_0002.HEIC"
                    ),
                    RecycleEntryRecord(
                        id: refreshOnlyEntryID,
                        assetID: UUID(),
                        sourceID: sourceID,
                        sourceKind: .file,
                        mediaKind: .image,
                        trashedAtMs: 100,
                        purgeAfterMs: 200,
                        state: .failed,
                        quarantineRelativePath: nil,
                        originalRelativePath: "private/changed/path",
                        photosLocalIdentifier: nil,
                        errorCode: RecycleFailureCode.sourceChanged,
                        fileName: "IMG_0003.HEIC"
                    ),
                ],
                totalCount: 3,
                sourceNames: [sourceID: "Archive"],
                requests: [requestSnapshot]
            ),
            recycleReceipt: requestSnapshot
        )
        let facade = makeFacade(
            catalog: RemoteCatalogServingStub(),
            librarySlimmingCommands: commands
        )

        let snapshot = try await facade.fetchLibrarySlimmingRecycle(
            mediaKind: .image,
            sourceID: nil,
            searchText: nil,
            limit: 60
        )
        let entriesByID = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0) })
        XCTAssertEqual(entriesByID[entryID]?.sourceDisplayName, "Archive")
        XCTAssertEqual(entriesByID[entryID]?.availableActions, [.restore, .purge])
        XCTAssertEqual(entriesByID[photosEntryID]?.availableActions, [])
        XCTAssertEqual(entriesByID[refreshOnlyEntryID]?.availableActions, [])
        let encoded = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("private/original/path"))
        XCTAssertFalse(json.contains("private/quarantine/path"))
        XCTAssertFalse(json.contains("private/changed/path"))
        XCTAssertFalse(json.contains("private-photos-identifier"))

        let response = try await facade.submitLibrarySlimmingRecycle(
            RemoteLibrarySlimmingRecycleSubmitRequest(
                operationID: operationID,
                entryID: entryID,
                action: .restore
            )
        )
        XCTAssertEqual(response.phase, .awaitingMac)
        XCTAssertEqual(commands.lastRecycleCommand?.action, .restore)
        XCTAssertEqual(commands.lastRecycleCommand?.entryID, entryID)
    }

    func testLibrarySlimmingBatchRemovalMapsFrozenSelectionProgressAndAudit() async throws {
        let operationID = UUID()
        let jobID = UUID()
        let clusterID = UUID()
        let assetIDs = [UUID(), UUID()]
        let receipt = LibrarySlimmingRemovalCommandRequestSnapshot(
            id: UUID(),
            operationID: operationID,
            jobID: jobID,
            clusterID: clusterID,
            mediaKind: .image,
            assetIDs: assetIDs,
            mode: .recoverableRecycle,
            phase: .completed,
            progress: LibrarySlimmingRemovalCommandProgress(
                phase: .completedAsset,
                completedAssetCount: 2,
                totalAssetCount: 2,
                copiedBytes: 64,
                totalFileBytes: 64
            ),
            audit: LibrarySlimmingRemovalCommandAudit(
                hiddenAssetIDs: [assetIDs[0]],
                recycledEntryIDs: [UUID()],
                permanentlyDeletedAssetIDs: [],
                durabilityPendingAssetIDs: [],
                failedAssetIDs: [assetIDs[1]],
                authorizationRequiredSourceIDs: [],
                authorizationRequiredAssetIDs: [],
                authorizationDeniedPhotosAssetIDs: [],
                mutationAuthorizationInvalidAssetIDs: [],
                photosMutationFailedAssetIDs: [],
                photosMutationFailureCategories: [.system],
                photosMutationFailureCodes: ["Photos#7"],
                sourceChangedAssetIDs: [assetIDs[1]]
            ),
            message: "已移入可恢复回收站 1 项 · 失败 1 项",
            updatedAtMs: 456
        )
        let commands = RemoteLibrarySlimmingCommandPortStub(
            setup: LibrarySlimmingCommandSetupSnapshot(
                mediaKind: .image,
                sources: [],
                thresholds: .factory,
                factoryThresholds: .factory
            ),
            receipt: LibrarySlimmingLaunchReceipt(
                operationID: UUID(),
                jobID: jobID,
                acceptedAtMs: 0,
                memberCount: 2
            ),
            removalSnapshot: LibrarySlimmingRemovalCommandSnapshot(requests: [receipt]),
            removalReceipt: receipt
        )
        let facade = makeFacade(
            catalog: RemoteCatalogServingStub(),
            librarySlimmingCommands: commands
        )

        let snapshot = try await facade.fetchLibrarySlimmingRemovals(mediaKind: .image)
        XCTAssertEqual(snapshot.requests.first?.assetIDs, assetIDs)
        XCTAssertEqual(snapshot.requests.first?.progress?.completedAssetCount, 2)
        XCTAssertEqual(snapshot.requests.first?.audit?.photosMutationFailureCategories, ["system"])

        let response = try await facade.submitLibrarySlimmingRemoval(
            RemoteLibrarySlimmingRemovalSubmitRequest(
                operationID: operationID,
                jobID: jobID,
                clusterID: clusterID,
                mediaKind: .image,
                assetIDs: assetIDs,
                mode: .recoverableRecycle
            )
        )
        XCTAssertEqual(response.phase, .completed)
        XCTAssertEqual(commands.lastRemovalCommand?.assetIDs, assetIDs)
        XCTAssertEqual(commands.lastRemovalCommand?.clusterID, clusterID)
    }

    func testLibrarySlimmingProgressiveWindowCanPassFormerFiveHundredClusterBoundary() async throws {
        let jobID = UUID()
        let assetID = UUID()
        let sourceID = UUID()
        let clusters = (0 ..< 501).map { _ in
            SlimmingCluster(
                id: UUID(),
                kind: .nearDuplicateScene,
                memberAssetIDs: [assetID],
                representativeAssetID: assetID,
                score: 0.9,
                modelIdentity: .featurePrintOnly
            )
        }
        let analysis = RemoteLibrarySlimmingAnalysisPortStub(
            summaries: [
                LibrarySlimmingAnalysisJobSummary(
                    jobID: jobID,
                    mode: .catalog,
                    mediaKind: .image,
                    state: .completed,
                    controlRequest: .none,
                    progress: JobProgress(completed: 501, total: 501),
                    attempts: 1,
                    maxAttempts: 10,
                    memberCount: 501,
                    seedCount: 0,
                    clusterCount: 501,
                    hasResult: true,
                    createdAtMs: 100,
                    updatedAtMs: 200,
                    sourceNames: ["Apple Photos"]
                ),
            ],
            snapshot: LibrarySlimmingAnalysisJobSnapshot(
                jobID: jobID,
                state: .completed,
                controlRequest: .none,
                progress: JobProgress(completed: 501, total: 501),
                result: LibrarySlimmingScanResult(
                    clusters: clusters,
                    pendingAnalysisAssetIDs: [],
                    analyzedAssetCount: 501,
                    policyVersion: "librarySlimming.v1"
                )
            )
        )
        let catalog = RemoteCatalogServingStub(
            detail: AssetInspectorDetail(
                assetID: assetID,
                sourceID: sourceID,
                sourceDisplayName: "Apple Photos",
                sourceState: .active,
                relativePath: nil,
                fileName: "IMG_0001.HEIC",
                mediaType: "public.heic",
                mediaCreatedAtMs: 100,
                mediaModifiedAtMs: 100,
                width: 3024,
                height: 4032,
                availability: .available,
                contentRevision: 2,
                acceptedTagCount: 0,
                rejectedTagCount: 0,
                fingerprintSizeBytes: nil,
                fingerprintModifiedAtNs: nil,
                tags: []
            )
        )

        let snapshot = try await makeFacade(
            catalog: catalog,
            librarySlimmingAnalysis: analysis
        ).fetchLibrarySlimmingWorkspace(
            mediaKind: .image,
            jobID: jobID,
            clusterID: nil,
            clusterLimit: 501
        )

        XCTAssertEqual(snapshot.clusters.count, 501)
    }

    func testResumingPersonalSuggestionJobWakesHostRunner() async throws {
        let jobID = UUID()
        let catalog = RemoteCatalogServingStub(
            jobs: [
                JobActivityItem(
                    id: jobID,
                    kind: .personalizationSuggestions,
                    state: .paused,
                    controlRequest: .pause,
                    progress: JobProgress(completed: 4, total: 12)
                ),
            ]
        )
        let review = RemoteReviewPortStub(
            page: ReviewQueuePage(items: [], nextCursor: nil)
        )
        let commands = RemoteTrainingCommandPortStub(
            setup: TrainingCommandSetupSnapshot(
                mediaKind: .image,
                tags: [],
                sources: [],
                supportsPersonalCentroid: true,
                supportsPersonalAdamW: true
            ),
            receipt: TrainingLaunchReceipt(
                operationID: UUID(),
                method: .personalCentroid,
                acceptedAtMs: 0,
                scheduledTagCount: 0,
                jobID: nil
            )
        )
        let facade = makeFacade(
            catalog: catalog,
            review: review,
            trainingCommands: commands
        )

        try await facade.applyJobActivityAction(
            jobID: jobID,
            request: RemoteJobActionRequest(action: .resume)
        )

        XCTAssertEqual(review.lastResumedJobID, jobID)
        XCTAssertEqual(commands.ensureRunnerCount, 1)
        XCTAssertNil(catalog.lastJobAction)
    }

    func testTagDecisionIsIdempotentByOperationID() async throws {
        let tagID = UUID()
        let assetID = UUID()
        let catalog = RemoteCatalogServingStub(
            mutateResult: TagMutationPriorStateSnapshot(
                tagID: tagID,
                priorStates: [
                    TagMutationPriorState(assetID: assetID, priorState: .unknown),
                ]
            )
        )
        let facade = makeFacade(catalog: catalog)
        let operationID = UUID()
        let request = RemoteBatchTagDecisionRequest(
            operationID: operationID,
            tagID: tagID,
            assetIDs: [assetID],
            action: .accept
        )

        let first = try await facade.applyTagDecision(request)
        let second = try await facade.applyTagDecision(request)

        XCTAssertEqual(first.appliedAssetCount, 1)
        XCTAssertNotNil(first.undoID)
        XCTAssertFalse(first.replayed)
        XCTAssertEqual(second.appliedAssetCount, 1)
        XCTAssertTrue(second.replayed)
        XCTAssertEqual(catalog.mutateCallCount, 1)
    }

    func testLatestTagDecisionCanBeUndoneOnceAndUndoReplayIsIdempotent() async throws {
        let tagID = UUID()
        let assetID = UUID()
        let catalog = RemoteCatalogServingStub(
            mutateResult: TagMutationPriorStateSnapshot(
                tagID: tagID,
                priorStates: [TagMutationPriorState(assetID: assetID, priorState: .rejected)]
            )
        )
        let facade = makeFacade(catalog: catalog)
        let mutation = try await facade.applyTagDecision(
            RemoteBatchTagDecisionRequest(
                operationID: UUID(),
                tagID: tagID,
                assetIDs: [assetID],
                action: .accept
            )
        )
        let undoID = try XCTUnwrap(mutation.undoID)
        let request = RemoteUndoTagDecisionRequest(operationID: UUID(), undoID: undoID)

        let first = try await facade.undoTagDecision(request)
        let replay = try await facade.undoTagDecision(request)

        XCTAssertEqual(first.restoredAssetCount, 1)
        XCTAssertFalse(first.replayed)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(catalog.restoreCallCount, 1)
    }

    func testTagAndReviewUndoRemainIndependent() async throws {
        let tagID = UUID()
        let reviewTagID = UUID()
        let assetID = UUID()
        let catalog = RemoteCatalogServingStub(
            mutateResult: TagMutationPriorStateSnapshot(
                tagID: tagID,
                priorStates: [TagMutationPriorState(assetID: assetID, priorState: .unknown)]
            )
        )
        let facade = makeFacade(catalog: catalog)
        let tagMutation = try await facade.applyTagDecision(
            RemoteBatchTagDecisionRequest(
                operationID: UUID(),
                tagID: tagID,
                assetIDs: [assetID],
                action: .accept
            )
        )
        let reviewMutation = try await facade.applyReviewDecision(
            RemoteBatchReviewDecisionRequest(
                operationID: UUID(),
                tagID: reviewTagID,
                assetIDs: [assetID],
                action: .reject
            )
        )

        _ = try await facade.undoTagDecision(
            RemoteUndoTagDecisionRequest(
                operationID: UUID(),
                undoID: try XCTUnwrap(tagMutation.undoID)
            )
        )
        _ = try await facade.undoReviewDecision(
            RemoteUndoReviewDecisionRequest(
                operationID: UUID(),
                undoID: try XCTUnwrap(reviewMutation.undoID)
            )
        )

        XCTAssertEqual(catalog.restoreCallCount, 2)
    }

    func testCreateTagAndApplyIsIdempotentByOperationID() async throws {
        let tagID = UUID()
        let assetIDs = [UUID(), UUID()]
        let catalog = RemoteCatalogServingStub(
            createTagResult: TagCreateAndApplyResult(
                tagID: tagID,
                displayName: "旅行",
                normalizedName: "旅行",
                priorStates: assetIDs.map {
                    TagMutationPriorState(assetID: $0, priorState: .unknown)
                }
            )
        )
        let facade = makeFacade(catalog: catalog)
        let operationID = UUID()
        let request = RemoteCreateTagAndApplyRequest(
            operationID: operationID,
            name: "  旅行  ",
            assetIDs: assetIDs
        )

        let first = try await facade.createTagAndApply(request)
        let second = try await facade.createTagAndApply(request)

        XCTAssertEqual(first.tagID, tagID)
        XCTAssertEqual(first.displayName, "旅行")
        XCTAssertEqual(first.appliedAssetCount, 2)
        XCTAssertFalse(first.replayed)
        XCTAssertTrue(second.replayed)
        XCTAssertEqual(catalog.createTagCallCount, 1)
        XCTAssertEqual(catalog.lastCreateTagName, "  旅行  ")
        XCTAssertEqual(catalog.lastCreateTagAssetIDs, assetIDs)
    }

    func testInstallPresetTagsUsesCatalogAndIsIdempotent() async throws {
        let created = TagListItem(
            id: UUID(),
            displayName: "风景",
            state: .active,
            groupID: TagGroupSeed.placesAndScenes.id
        )
        let catalog = RemoteCatalogServingStub(
            presetInstallResult: TagPresetInstallResult(createdTags: [created])
        )
        let facade = makeFacade(catalog: catalog)
        let request = RemoteInstallPresetTagsRequest(operationID: UUID())

        let first = try await facade.installPresetTags(request)
        let replay = try await facade.installPresetTags(request)

        XCTAssertEqual(first.createdTags.map(\.displayName), ["风景"])
        XCTAssertEqual(first.createdTags.first?.groupID, TagGroupSeed.placesAndScenes.id)
        XCTAssertFalse(first.replayed)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(catalog.presetInstallCallCount, 1)
    }

    func testAssetPagePassesRequestedLimitToCatalogWithoutSkipping() async throws {
        let catalog = RemoteCatalogServingStub()
        let facade = makeFacade(catalog: catalog)

        _ = try await facade.fetchAssets(RemoteAssetPageRequest(limit: 60))

        XCTAssertEqual(catalog.lastRequestedLimit, 60)
    }

    func testAssetPageMapsAdvancedWebFiltersToCatalogQuery() async throws {
        let sourceID = UUID()
        let acceptedTagID = UUID()
        let rejectedTagID = UUID()
        let excludedTagID = UUID()
        let catalog = RemoteCatalogServingStub()
        let facade = makeFacade(catalog: catalog)

        _ = try await facade.fetchAssets(
            RemoteAssetPageRequest(
                sourceIDs: [sourceID],
                searchText: "sunset",
                sort: .oldest,
                limit: 24,
                tagDecisionFilters: [
                    RemoteAssetTagDecisionFilter(tagID: acceptedTagID, decision: .accepted),
                    RemoteAssetTagDecisionFilter(tagID: rejectedTagID, decision: .rejected),
                ],
                excludedTagIDs: [excludedTagID],
                tagMatchMode: .any,
                availabilities: [.available, .missing],
                mediaKinds: [.video],
                mediaTypes: ["public.mpeg-4"],
                tagPresence: .tagged
            )
        )

        let filter = try XCTUnwrap(catalog.lastRequestedFilter)
        XCTAssertEqual(filter.sourceIDs, [sourceID])
        XCTAssertEqual(
            filter.tagDecisionFilters,
            [
                TagDecisionFilter(tagID: acceptedTagID, decision: .accepted),
                TagDecisionFilter(tagID: rejectedTagID, decision: .rejected),
            ]
        )
        XCTAssertEqual(filter.excludedTagIDs, [excludedTagID])
        XCTAssertEqual(filter.tagMatchMode, .any)
        XCTAssertEqual(filter.availabilities, [.available, .missing])
        XCTAssertEqual(filter.mediaKinds, [.video])
        XCTAssertEqual(filter.mediaTypes, ["public.mpeg-4"])
        XCTAssertEqual(filter.tagPresence, .tagged)
        XCTAssertEqual(filter.searchText, "sunset")
    }

    func testReusingOperationIDForDifferentMutationIsConflict() async throws {
        let catalog = RemoteCatalogServingStub()
        let facade = makeFacade(catalog: catalog)
        let operationID = UUID()
        _ = try await facade.applyTagDecision(
            RemoteBatchTagDecisionRequest(
                operationID: operationID,
                tagID: UUID(),
                assetIDs: [UUID()],
                action: .accept
            )
        )

        do {
            _ = try await facade.applyTagDecision(
                RemoteBatchTagDecisionRequest(
                    operationID: operationID,
                    tagID: UUID(),
                    assetIDs: [UUID()],
                    action: .reject
                )
            )
            XCTFail("expected conflict")
        } catch let error as RemoteAPIError {
            XCTAssertEqual(error.code, .conflict)
        }
        XCTAssertEqual(catalog.mutateCallCount, 1)
    }

    func testRejectsEmptyAssetIDs() async throws {
        let facade = makeFacade(catalog: RemoteCatalogServingStub())
        do {
            _ = try await facade.applyTagDecision(
                RemoteBatchTagDecisionRequest(
                    operationID: UUID(),
                    tagID: UUID(),
                    assetIDs: [],
                    action: .accept
                )
            )
            XCTFail("expected badRequest")
        } catch let error as RemoteAPIError {
            XCTAssertEqual(error.code, .badRequest)
        }
    }

    func testTagAndReviewDecisionsWithSameOperationIDDoNotCollide() async throws {
        let tagID = UUID()
        let assetID = UUID()
        let catalog = RemoteCatalogServingStub(
            mutateResult: TagMutationPriorStateSnapshot(
                tagID: tagID,
                priorStates: [TagMutationPriorState(assetID: assetID, priorState: .unknown)]
            )
        )
        let facade = makeFacade(catalog: catalog)
        let operationID = UUID()

        let tagResponse = try await facade.applyTagDecision(
            RemoteBatchTagDecisionRequest(operationID: operationID, tagID: tagID, assetIDs: [assetID], action: .accept)
        )
        let reviewResponse = try await facade.applyReviewDecision(
            RemoteBatchReviewDecisionRequest(operationID: operationID, tagID: tagID, assetIDs: [assetID], action: .accept)
        )

        XCTAssertFalse(tagResponse.replayed)
        XCTAssertFalse(reviewResponse.replayed)
        XCTAssertEqual(catalog.mutateCallCount, 2)
    }

    func testFetchesPreviewInspectorDetailAggregateAndJobs() async throws {
        let assetID = UUID()
        let tagID = UUID()
        let jobID = UUID()
        let suggestionTagID = UUID()
        let catalog = RemoteCatalogServingStub(
            previewData: Data([0xAA, 0xBB]),
            cloudPreviewData: Data([0xCC, 0xDD]),
            detail: AssetInspectorDetail(
                assetID: assetID,
                sourceID: UUID(),
                sourceDisplayName: "Archive",
                sourceState: .active,
                relativePath: "a.jpg",
                fileName: "a.jpg",
                mediaKind: .video,
                mediaType: "public.mpeg-4",
                durationMs: 12_345,
                mediaCreatedAtMs: nil,
                mediaModifiedAtMs: nil,
                width: nil,
                height: nil,
                availability: .available,
                contentRevision: 1,
                acceptedTagCount: 1,
                rejectedTagCount: 0,
                fingerprintSizeBytes: 4_500_000,
                fingerprintModifiedAtNs: nil,
                tags: [InspectorTagState(tagID: tagID, displayName: "风景", tagState: .active, decision: .accepted)]
            ),
            aggregates: [TagSelectionAggregate(tagID: tagID, acceptedCount: 3, rejectedCount: 1, unknownCount: 0)],
            jobs: [
                JobActivityItem(
                    id: jobID,
                    kind: .folderReconcile,
                    state: .running,
                    controlRequest: .none,
                    progress: JobProgress(completed: 2, total: 10)
                ),
            ]
        )
        let review = RemoteReviewPortStub(
            page: ReviewQueuePage(items: [], nextCursor: nil),
            pendingSuggestions: [
                AssetPendingSuggestion(
                    tagID: suggestionTagID,
                    displayName: "猫",
                    suggestionOrigin: .personalAdamW
                ),
            ]
        )
        let facade = makeFacade(catalog: catalog, review: review)

        let preview = try await facade.loadPreview(assetID: assetID)
        XCTAssertEqual(preview, Data([0xAA, 0xBB]))
        let cloudPreview = try await facade.downloadCloudPreview(assetID: assetID)
        XCTAssertEqual(cloudPreview, Data([0xCC, 0xDD]))

        let detail = try await facade.fetchInspectorDetail(assetID: assetID)
        XCTAssertEqual(detail.assetID, assetID)
        XCTAssertEqual(detail.tags.first?.decision, .accepted)
        XCTAssertEqual(detail.durationMs, 12_345)
        XCTAssertEqual(detail.fingerprintSizeBytes, 4_500_000)
        XCTAssertEqual(detail.pendingSuggestions?.first?.tagID, suggestionTagID)
        XCTAssertEqual(detail.pendingSuggestions?.first?.displayName, "猫")
        XCTAssertEqual(detail.pendingSuggestions?.first?.suggestionOrigin, .personalAdamW)

        let aggregates = try await facade.selectionAggregate(RemoteTagSelectionRequest(tagIDs: [tagID], assetIDs: [assetID]))
        XCTAssertEqual(aggregates.first?.acceptedCount, 3)

        let jobs = try await facade.fetchJobActivity()
        XCTAssertEqual(jobs.first?.id, jobID)
        XCTAssertEqual(jobs.first?.state, .running)
        XCTAssertEqual(jobs.first?.controlRequest, RemoteJobControlRequest.none)

        try await facade.applyJobActivityAction(jobID: jobID, request: RemoteJobActionRequest(action: .pause))
        XCTAssertEqual(catalog.lastJobAction, .pause)
        XCTAssertEqual(catalog.lastJobActionID, jobID)
    }

    func testFetchesReviewQueue() async throws {
        let tagID = UUID()
        let assetID = UUID()
        let review = RemoteReviewPortStub(
            page: ReviewQueuePage(
                items: [
                    ReviewQueueItemProjection(
                        assetID: assetID,
                        fileName: "a.jpg",
                        availability: .available,
                        acceptedTagCount: 0,
                        rejectedTagCount: 0,
                        suggestionOrigin: .personalModel,
                        score: 0.8
                    ),
                ],
                nextCursor: nil
            )
        )
        let facade = makeFacade(catalog: RemoteCatalogServingStub(), review: review)

        let page = try await facade.fetchReviewQueue(RemoteReviewQueueRequest(tagID: tagID, limit: 10))
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].assetID, assetID)
        XCTAssertEqual(page.items[0].suggestionOrigin, .personalModel)
        XCTAssertEqual(review.lastRequestedTagID, tagID)
    }

    func testFetchesReviewOverviewFromSameAuthoritativeProjection() async throws {
        let tagID = UUID()
        let overview = SuggestionTagOverview(
            id: tagID,
            displayName: "猫",
            acceptedSampleCount: 8,
            rejectedSampleCount: 5,
            pendingSuggestionCount: 7,
            pendingSuggestionCounts: SuggestionOriginCounts(
                featurePrint: 2,
                standardModel: 1,
                personalModel: 3,
                personalAdamW: 1
            ),
            taskStatus: .completed,
            checkedCount: 120,
            totalCount: 120,
            skippedCount: 4,
            missingPositiveCount: 0,
            missingNegativeCount: 0,
            canGenerate: true,
            canUpdate: true,
            canGeneratePersonalModel: true,
            canReview: true,
            canPause: false,
            canResume: false,
            canCancel: false,
            activeJobID: nil
        )
        let review = RemoteReviewPortStub(
            page: ReviewQueuePage(items: [], nextCursor: nil),
            totalPendingCount: 7,
            overviews: [overview]
        )
        let facade = makeFacade(catalog: RemoteCatalogServingStub(), review: review)

        let result = try await facade.fetchReviewOverview(mediaKind: .image, sourceIDs: [])

        XCTAssertEqual(result.totalPendingSuggestionCount, 7)
        XCTAssertEqual(result.tags.first?.id, tagID)
        XCTAssertEqual(result.tags.first?.pendingSuggestionCounts.personalModel, 3)
        XCTAssertEqual(result.tags.first?.taskStatus, .completed)
        XCTAssertEqual(result.tags.first?.canGenerate, true)
        XCTAssertEqual(result.tags.first?.canUpdate, true)
        XCTAssertEqual(result.tags.first?.canGeneratePersonalModel, true)
    }

    func testWorldMapSnapshotAndSelectionReuseCatalogAndInspectorProjection() async throws {
        let assetID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-bbbbbbbbbbbb")!
        let query = WorldMapCatalogSelectionQuery(
            cellDegrees: 0.25,
            longitudeBucket: 1_205,
            latitudeBucket: 485,
            maximumAssets: 36
        )
        let cluster = WorldMapCatalogCluster(
            id: "shanghai",
            longitude: 121.47,
            latitude: 31.23,
            photoCount: 42,
            gpsCount: 30,
            tagCount: 12,
            displayName: "上海",
            selectionQuery: query
        )
        let detail = AssetInspectorDetail(
            assetID: assetID,
            sourceID: UUID(),
            sourceDisplayName: "Photos",
            sourceState: .active,
            relativePath: nil,
            fileName: "IMG_0001.HEIC",
            mediaType: "public.heic",
            mediaCreatedAtMs: nil,
            mediaModifiedAtMs: nil,
            width: 3024,
            height: 4032,
            availability: .available,
            contentRevision: 7,
            acceptedTagCount: 0,
            rejectedTagCount: 0,
            fingerprintSizeBytes: nil,
            fingerprintModifiedAtNs: nil,
            tags: []
        )
        let catalog = RemoteCatalogServingStub(
            detail: detail,
            worldMapSnapshot: WorldMapCatalogSnapshot(
                clusters: [cluster],
                eligiblePhotoCount: 100,
                locatedPhotoCount: 70,
                unlocatedPhotoCount: 30
            ),
            worldMapSelection: WorldMapCatalogSelection(
                assets: [WorldMapCatalogAsset(assetID: assetID, fileName: "IMG_0001.HEIC")],
                totalPhotoCount: 42
            )
        )
        let facade = makeFacade(catalog: catalog)

        let snapshot = try await facade.fetchWorldMapSnapshot(
            bounds: RemoteWorldMapBounds(west: 118, south: 30, east: 123, north: 33)
        )
        let selection = try await facade.fetchWorldMapSelection(
            RemoteWorldMapSelectionRequest(query: snapshot.clusters[0].selectionQuery)
        )

        XCTAssertEqual(snapshot.clusters.first?.displayName, "上海")
        XCTAssertEqual(snapshot.locatedPhotoCount, 70)
        XCTAssertEqual(selection.totalPhotoCount, 42)
        XCTAssertEqual(selection.assets.first?.availability, .available)
        XCTAssertEqual(selection.assets.first?.contentRevision, 7)
    }

    func testGalleryOverviewMapsCatalogProjectionWithoutPhotoLocators() async throws {
        let sourceID = UUID()
        let tagID = UUID()
        let catalog = RemoteCatalogServingStub(
            galleryOverview: GalleryOverviewSnapshot(
                media: [
                    GalleryOverviewMediaSummary(
                        mediaKind: .image,
                        totalCount: 12,
                        exactUniqueCount: 10,
                        exactRedundantCount: 2,
                        exactFingerprintCount: 11
                    ),
                ],
                sources: [
                    GalleryOverviewSourceSummary(
                        sourceID: sourceID,
                        displayName: "Apple Photos",
                        kind: .photos,
                        state: .authorizationRequired,
                        imageCount: 12,
                        videoCount: 0
                    ),
                ],
                positiveTags: [
                    GalleryOverviewTagSummary(
                        tagID: tagID,
                        displayName: "猫",
                        imageCount: 4,
                        videoCount: 0
                    ),
                ],
                years: [GalleryOverviewYearSummary(year: 2026, imageCount: 12, videoCount: 0)],
                availability: [
                    GalleryOverviewAvailabilitySummary(
                        availability: .available,
                        imageCount: 12,
                        videoCount: 0
                    ),
                ],
                undatedCount: 1,
                positiveLabeledAssetCount: 4,
                acceptedDecisionCount: 5
            )
        )

        let result = try await makeFacade(catalog: catalog).fetchGalleryOverview()

        XCTAssertEqual(result.media.first?.mediaKind, .image)
        XCTAssertEqual(result.sources.first?.id, sourceID)
        XCTAssertEqual(result.sources.first?.kind, .photos)
        XCTAssertEqual(result.sources.first?.state, .authorizationRequired)
        XCTAssertEqual(result.positiveTags.first?.id, tagID)
        XCTAssertEqual(result.acceptedDecisionCount, 5)
    }

    func testWorldMapLocationBackfillMapsProgressAndMakesCommandsIdempotent() async throws {
        let sourceID = UUID()
        let jobID = UUID()
        let snapshot = WorldMapLocationBackfillSnapshot(
            sourceID: sourceID,
            sourceKind: .photos,
            sourceDisplayName: "Apple Photos",
            sourceState: .active,
            phase: .running,
            totalPhotoCount: 120,
            inspectedPhotoCount: 45,
            locatedPhotoCount: 31,
            activeJobID: jobID,
            scanProgress: JobProgress(completed: 46, total: 120)
        )
        let catalog = RemoteCatalogServingStub(worldMapLocationBackfills: [snapshot])
        let facade = makeFacade(catalog: catalog)

        let projections = try await facade.fetchWorldMapLocationBackfillSnapshots()
        XCTAssertEqual(projections.first?.sourceKind, .photos)
        XCTAssertEqual(projections.first?.phase, .running)
        XCTAssertEqual(projections.first?.scanProgress?.completedUnitCount, 46)
        XCTAssertEqual(projections.first?.scanProgress?.totalUnitCount, 120)
        XCTAssertEqual(projections.first?.canCancel, true)

        let start = RemoteWorldMapLocationBackfillCommandRequest(
            operationID: UUID(),
            sourceID: sourceID,
            action: .start
        )
        let first = try await facade.submitWorldMapLocationBackfillCommand(start)
        let replay = try await facade.submitWorldMapLocationBackfillCommand(start)
        XCTAssertFalse(first.replayed)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(catalog.worldMapLocationBackfillStartCount, 1)
        for _ in 0..<50 where catalog.worldMapLocationBackfillRunnerCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(catalog.worldMapLocationBackfillRunnerCount, 1)

        _ = try await facade.submitWorldMapLocationBackfillCommand(
            RemoteWorldMapLocationBackfillCommandRequest(
                operationID: UUID(),
                sourceID: sourceID,
                action: .cancel
            )
        )
        XCTAssertEqual(catalog.worldMapLocationBackfillCancelCount, 1)
    }

    func testWorldMapPlaceTagsMapSearchConfirmAndReplayWithoutPhotoIdentifiers() async throws {
        let tagID = UUID()
        let firstCandidate = WorldMapPlaceCandidate(
            placeID: "place-paris-fr",
            displayName: "Paris",
            subtitle: "Île-de-France, France",
            latitude: 48.8566,
            longitude: 2.3522,
            kind: .city,
            countryCode: "FR"
        )
        let cached = WorldMapPlaceTagResolution(
            tagID: tagID,
            tagName: "巴黎",
            groupName: "地点与场景",
            acceptedPhotoCount: 14,
            status: .unresolved,
            confirmedPlaceID: nil,
            candidates: []
        )
        let searched = WorldMapPlaceTagResolution(
            tagID: tagID,
            tagName: "巴黎",
            groupName: "地点与场景",
            acceptedPhotoCount: 14,
            status: .ambiguous,
            confirmedPlaceID: nil,
            candidates: [firstCandidate]
        )
        let confirmed = WorldMapPlaceTagResolution(
            tagID: tagID,
            tagName: "巴黎",
            groupName: "地点与场景",
            acceptedPhotoCount: 14,
            status: .resolved,
            confirmedPlaceID: firstCandidate.placeID,
            candidates: [firstCandidate]
        )
        let catalog = RemoteCatalogServingStub(
            worldMapPlaceResolutions: [cached],
            worldMapPlaceSearchResult: searched,
            worldMapPlaceConfirmResult: confirmed
        )
        let facade = makeFacade(catalog: catalog)

        let snapshot = try await facade.fetchWorldMapPlaceTagSnapshot()
        XCTAssertEqual(snapshot.maximumQueryLength, 160)
        XCTAssertEqual(snapshot.items.first?.tagName, "巴黎")
        XCTAssertEqual(snapshot.items.first?.groupName, "地点与场景")

        let search = RemoteWorldMapPlaceTagCommandRequest(
            operationID: UUID(),
            tagID: tagID,
            action: .search,
            query: "  Paris   France  "
        )
        let firstSearch = try await facade.submitWorldMapPlaceTagCommand(search)
        let replayedSearch = try await facade.submitWorldMapPlaceTagCommand(search)
        XCTAssertEqual(firstSearch.resolution.candidates.first?.placeID, firstCandidate.placeID)
        XCTAssertFalse(firstSearch.replayed)
        XCTAssertTrue(replayedSearch.replayed)
        XCTAssertEqual(catalog.worldMapPlaceSearchCount, 1)
        XCTAssertEqual(catalog.lastWorldMapPlaceQuery, "Paris France")

        let confirm = try await facade.submitWorldMapPlaceTagCommand(
            RemoteWorldMapPlaceTagCommandRequest(
                operationID: UUID(),
                tagID: tagID,
                action: .confirm,
                placeID: firstCandidate.placeID
            )
        )
        XCTAssertEqual(confirm.resolution.status, .resolved)
        XCTAssertEqual(catalog.worldMapPlaceConfirmCount, 1)
        XCTAssertEqual(catalog.lastWorldMapPlaceID, firstCandidate.placeID)
    }

    func testPersonalTrainingBatchContinuesAfterOneTagFailsAndReportsEveryTag() async throws {
        let tagIDs = [
            UUID(uuidString: "71000000-0000-4000-8000-000000000001")!,
            UUID(uuidString: "72000000-0000-4000-8000-000000000002")!,
            UUID(uuidString: "73000000-0000-4000-8000-000000000003")!,
        ]
        let catalogScopeID = "fixture-scope"
        let snapshots = Dictionary(uniqueKeysWithValues: tagIDs.map { tagID in
            let decisions = (0..<2).map { revision in
                PersonalTrainingDecision(
                    assetID: UUID(),
                    contentRevision: revision + 1,
                    tagID: tagID,
                    state: .manualAccepted
                )
            }
            return (
                tagID,
                PersonalTrainingSnapshot(
                    catalogScopeID: catalogScopeID,
                    personalTagIDs: [tagID],
                    decisions: decisions
                )
            )
        })
        let overviews = tagIDs.enumerated().map { index, tagID in
            SuggestionTagOverview(
                id: tagID,
                displayName: "标签 \(index + 1)",
                acceptedSampleCount: 2,
                rejectedSampleCount: 0,
                pendingSuggestionCount: 0,
                taskStatus: .ready,
                checkedCount: 0,
                totalCount: nil,
                skippedCount: 0,
                missingPositiveCount: 0,
                missingNegativeCount: 0,
                canGenerate: false,
                canUpdate: false,
                canGeneratePersonalModel: true,
                canReview: false,
                canPause: false,
                canResume: false,
                canCancel: false,
                activeJobID: nil
            )
        }
        let review = RemoteReviewPortStub(
            page: ReviewQueuePage(items: [], nextCursor: nil),
            overviews: overviews,
            personalSnapshotsByTagID: snapshots
        )
        let rebuilder = RemoteBatchRebuilderStub(failingTagID: tagIDs[1])
        let cache = RemoteEmbeddingCacheStub()
        let service = RemoteTrainingCommandService(
            catalog: RemoteCatalogServingStub(previewData: Data([1, 2, 3])),
            review: review,
            centroidRebuilder: rebuilder,
            adamWRebuilder: nil,
            embeddingCache: cache
        )
        let operationID = UUID(uuidString: "74000000-0000-4000-8000-000000000004")!

        let receipt = try await service.launch(TrainingLaunchCommand(
            operationID: operationID,
            mediaKind: .image,
            method: .personalCentroid,
            tagIDs: Set(tagIDs),
            sourceIDs: [],
            assetIDs: []
        ))
        XCTAssertEqual(receipt.scheduledTagCount, 3)

        var activities = await service.activities(mediaKind: .image)
        var activity = try XCTUnwrap(activities.first)
        for _ in 0..<100 where ![.completed, .failed, .cancelled].contains(activity.phase) {
            try await Task.sleep(for: .milliseconds(10))
            activities = await service.activities(mediaKind: .image)
            activity = try XCTUnwrap(activities.first)
        }

        XCTAssertEqual(activity.phase, .completed)
        XCTAssertEqual(activity.completedUnitCount, 3)
        XCTAssertEqual(activity.tagActivities.map(\.tagID), tagIDs)
        XCTAssertEqual(
            activity.tagActivities.map(\.phase),
            [.succeeded, .failed, .succeeded]
        )
        XCTAssertEqual(activity.tagActivities[1].errorCode, "staleSnapshot")
        let rebuiltSnapshots = await rebuilder.snapshots()
        XCTAssertEqual(rebuiltSnapshots.count, 3)
        XCTAssertTrue(rebuiltSnapshots.allSatisfy {
            $0.batchContext?.operationID == operationID
                && $0.batchContext?.orderedTagIDs == tagIDs
        })
        XCTAssertEqual(cache.callCount, 6)
    }

    func testTrainingActivityStoreRestoresTerminalHistoryAndReconcilesInterruptedBatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrainingActivityStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storageURL = directory.appendingPathComponent("training-activities.json")
        let completedID = UUID(uuidString: "75000000-0000-4000-8000-000000000005")!
        let runningID = UUID(uuidString: "76000000-0000-4000-8000-000000000006")!
        let completedTagID = UUID(uuidString: "77000000-0000-4000-8000-000000000007")!
        let runningTagID = UUID(uuidString: "78000000-0000-4000-8000-000000000008")!
        let store = RemoteTrainingActivityStore(storageURL: storageURL)
        store.upsert(TrainingCommandActivitySnapshot(
            operationID: completedID,
            mediaKind: .image,
            method: .personalCentroid,
            phase: .completed,
            completedUnitCount: 1,
            totalUnitCount: 1,
            sampleCount: 6,
            errorCode: nil,
            tagActivities: [
                TrainingCommandTagActivitySnapshot(
                    tagID: completedTagID,
                    displayName: "猫",
                    phase: .succeeded,
                    sampleCount: 6,
                    errorCode: nil
                ),
            ],
            acceptedAtMs: 1_000,
            updatedAtMs: 2_000
        ))
        store.upsert(TrainingCommandActivitySnapshot(
            operationID: runningID,
            mediaKind: .image,
            method: .personalAdamW,
            phase: .preparingEmbeddings,
            completedUnitCount: 0,
            totalUnitCount: 1,
            sampleCount: 4,
            errorCode: nil,
            tagActivities: [
                TrainingCommandTagActivitySnapshot(
                    tagID: runningTagID,
                    displayName: "旅行",
                    phase: .preparingEmbeddings,
                    sampleCount: 4,
                    errorCode: nil
                ),
            ],
            acceptedAtMs: 3_000,
            updatedAtMs: 4_000
        ))

        let restored = RemoteTrainingActivityStore(storageURL: storageURL)
            .restoreAndReconcile(nowMs: 5_000)
        let completed = try XCTUnwrap(restored.first { $0.operationID == completedID })
        let interrupted = try XCTUnwrap(restored.first { $0.operationID == runningID })

        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.tagActivities.first?.phase, .succeeded)
        XCTAssertEqual(interrupted.phase, .failed)
        XCTAssertEqual(interrupted.errorCode, "hostRestartInterrupted")
        XCTAssertEqual(interrupted.tagActivities.first?.phase, .failed)
        XCTAssertEqual(interrupted.tagActivities.first?.errorCode, "hostRestartInterrupted")
        XCTAssertEqual(interrupted.acceptedAtMs, 3_000)
        XCTAssertEqual(interrupted.updatedAtMs, 5_000)

        let data = try Data(contentsOf: storageURL)
        let persisted = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(persisted.contains("path"))
        XCTAssertFalse(persisted.contains("asset"))
        let attributes = try FileManager.default.attributesOfItem(atPath: storageURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }
}

private final class RemoteCatalogServingStub: RemoteCatalogServing, @unchecked Sendable {
    private let lock = NSLock()
    private let sources: [LibrarySourceSummary]
    private let tags: [TagListItem]
    private let items: [AssetGridItemProjection]
    private let mutateResult: TagMutationPriorStateSnapshot
    private let createTagResult: TagCreateAndApplyResult
    private let presetInstallResult: TagPresetInstallResult
    private let previewData: Data
    private let cloudPreviewData: Data
    private let detail: AssetInspectorDetail
    private let aggregates: [TagSelectionAggregate]
    private let jobs: [JobActivityItem]
    private let worldMapSnapshot: WorldMapCatalogSnapshot
    private let worldMapSelection: WorldMapCatalogSelection
    private let worldMapLocationBackfills: [WorldMapLocationBackfillSnapshot]
    private let worldMapPlaceResolutions: [WorldMapPlaceTagResolution]
    private let worldMapPlaceSearchResult: WorldMapPlaceTagResolution?
    private let worldMapPlaceConfirmResult: WorldMapPlaceTagResolution?
    private let galleryOverview: GalleryOverviewSnapshot
    private var storedMutateCallCount = 0
    private var storedCreateTagCallCount = 0
    private var storedPresetInstallCallCount = 0
    private var storedRestoreCallCount = 0
    private var storedLastCreateTagName: String?
    private var storedLastCreateTagAssetIDs: [UUID]?
    private var storedLastRequestedLimit: Int?
    private var storedLastRequestedFilter: AssetPageFilter?
    private var storedLastJobAction: JobActivityAction?
    private var storedLastJobActionID: UUID?
    private var storedWorldMapLocationBackfillStartCount = 0
    private var storedWorldMapLocationBackfillCancelCount = 0
    private var storedWorldMapLocationBackfillRunnerCount = 0
    private var storedWorldMapPlaceSearchCount = 0
    private var storedWorldMapPlaceConfirmCount = 0
    private var storedLastWorldMapPlaceQuery: String?
    private var storedLastWorldMapPlaceID: String?

    var worldMapLocationBackfillStartCount: Int {
        lock.withLock { storedWorldMapLocationBackfillStartCount }
    }

    var worldMapLocationBackfillCancelCount: Int {
        lock.withLock { storedWorldMapLocationBackfillCancelCount }
    }

    var worldMapLocationBackfillRunnerCount: Int {
        lock.withLock { storedWorldMapLocationBackfillRunnerCount }
    }

    var worldMapPlaceSearchCount: Int {
        lock.withLock { storedWorldMapPlaceSearchCount }
    }

    var worldMapPlaceConfirmCount: Int {
        lock.withLock { storedWorldMapPlaceConfirmCount }
    }

    var lastWorldMapPlaceQuery: String? {
        lock.withLock { storedLastWorldMapPlaceQuery }
    }

    var lastWorldMapPlaceID: String? {
        lock.withLock { storedLastWorldMapPlaceID }
    }

    var mutateCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedMutateCallCount
    }

    var createTagCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCreateTagCallCount
    }

    var presetInstallCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedPresetInstallCallCount
    }

    var restoreCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRestoreCallCount
    }

    var lastCreateTagName: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastCreateTagName
    }

    var lastCreateTagAssetIDs: [UUID]? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastCreateTagAssetIDs
    }

    var lastRequestedLimit: Int? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastRequestedLimit
    }

    var lastRequestedFilter: AssetPageFilter? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastRequestedFilter
    }

    var lastJobAction: JobActivityAction? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastJobAction
    }

    var lastJobActionID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastJobActionID
    }

    init(
        sources: [LibrarySourceSummary] = [],
        tags: [TagListItem] = [],
        items: [AssetGridItemProjection] = [],
        mutateResult: TagMutationPriorStateSnapshot = TagMutationPriorStateSnapshot(
            tagID: UUID(),
            priorStates: []
        ),
        createTagResult: TagCreateAndApplyResult = TagCreateAndApplyResult(
            tagID: UUID(),
            displayName: "新标签",
            normalizedName: "新标签",
            priorStates: []
        ),
        presetInstallResult: TagPresetInstallResult = TagPresetInstallResult(
            createdTags: []
        ),
        previewData: Data = Data(),
        cloudPreviewData: Data = Data(),
        detail: AssetInspectorDetail = AssetInspectorDetail(
            assetID: UUID(),
            sourceID: UUID(),
            sourceDisplayName: "",
            sourceState: .active,
            relativePath: nil,
            fileName: nil,
            mediaType: "image",
            mediaCreatedAtMs: nil,
            mediaModifiedAtMs: nil,
            width: nil,
            height: nil,
            availability: .available,
            contentRevision: 0,
            acceptedTagCount: 0,
            rejectedTagCount: 0,
            fingerprintSizeBytes: nil,
            fingerprintModifiedAtNs: nil,
            tags: []
        ),
        aggregates: [TagSelectionAggregate] = [],
        jobs: [JobActivityItem] = [],
        galleryOverview: GalleryOverviewSnapshot = .empty,
        worldMapSnapshot: WorldMapCatalogSnapshot = .empty,
        worldMapSelection: WorldMapCatalogSelection = .empty,
        worldMapLocationBackfills: [WorldMapLocationBackfillSnapshot] = [],
        worldMapPlaceResolutions: [WorldMapPlaceTagResolution] = [],
        worldMapPlaceSearchResult: WorldMapPlaceTagResolution? = nil,
        worldMapPlaceConfirmResult: WorldMapPlaceTagResolution? = nil
    ) {
        self.sources = sources
        self.tags = tags
        self.items = items
        self.mutateResult = mutateResult
        self.createTagResult = createTagResult
        self.presetInstallResult = presetInstallResult
        self.previewData = previewData
        self.cloudPreviewData = cloudPreviewData
        self.detail = detail
        self.aggregates = aggregates
        self.jobs = jobs
        self.galleryOverview = galleryOverview
        self.worldMapSnapshot = worldMapSnapshot
        self.worldMapSelection = worldMapSelection
        self.worldMapLocationBackfills = worldMapLocationBackfills
        self.worldMapPlaceResolutions = worldMapPlaceResolutions
        self.worldMapPlaceSearchResult = worldMapPlaceSearchResult
        self.worldMapPlaceConfirmResult = worldMapPlaceConfirmResult
    }

    func fetchSources() throws -> [LibrarySourceSummary] {
        sources
    }

    func listTags() throws -> [TagListItem] {
        tags
    }

    func installPresetTags() throws -> TagPresetInstallResult {
        lock.lock()
        storedPresetInstallCallCount += 1
        lock.unlock()
        return presetInstallResult
    }

    func fetchAssetPage(
        filter: AssetPageFilter,
        sort: AssetPageSort,
        cursor: AssetPageCursor?,
        limit: Int
    ) throws -> AssetPageResult {
        _ = filter
        _ = sort
        _ = cursor
        lock.lock()
        storedLastRequestedLimit = limit
        storedLastRequestedFilter = filter
        lock.unlock()
        return AssetPageResult(items: items, nextCursor: nil)
    }

    func loadThumbnail(assetID: UUID) async throws -> Data {
        _ = assetID
        return Data([0xFF, 0xD8, 0xFF])
    }

    func loadPreview(assetID: UUID) async throws -> Data {
        _ = assetID
        return previewData
    }

    func downloadCloudPreview(
        assetID: UUID,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        _ = assetID
        onProgress(1)
        return cloudPreviewData
    }

    func fetchInspectorDetail(assetID: UUID) throws -> AssetInspectorDetail {
        _ = assetID
        return detail
    }

    func fetchWorldMapSnapshot(query: WorldMapCatalogQuery) throws -> WorldMapCatalogSnapshot {
        _ = query
        return worldMapSnapshot
    }

    func fetchGalleryOverview() throws -> GalleryOverviewSnapshot {
        galleryOverview
    }

    func fetchWorldMapSelection(
        query: WorldMapCatalogSelectionQuery
    ) throws -> WorldMapCatalogSelection {
        _ = query
        return worldMapSelection
    }

    func fetchWorldMapLocationBackfillSnapshots() throws
        -> [WorldMapLocationBackfillSnapshot]
    {
        worldMapLocationBackfills
    }

    func startWorldMapLocationBackfill(sourceID: UUID) throws {
        _ = sourceID
        lock.withLock { storedWorldMapLocationBackfillStartCount += 1 }
    }

    func cancelWorldMapLocationBackfill(sourceID: UUID) throws {
        _ = sourceID
        lock.withLock { storedWorldMapLocationBackfillCancelCount += 1 }
    }

    func runPendingWorldMapLocationBackfill(
        sourceID: UUID,
        sourceKind: SourceKind
    ) throws {
        _ = sourceID
        _ = sourceKind
        lock.withLock { storedWorldMapLocationBackfillRunnerCount += 1 }
    }

    func fetchWorldMapPlaceTagResolutions() throws -> [WorldMapPlaceTagResolution] {
        worldMapPlaceResolutions
    }

    func searchWorldMapPlaceTag(
        tagID: UUID,
        query: String
    ) async throws -> WorldMapPlaceTagResolution {
        _ = tagID
        lock.withLock {
            storedWorldMapPlaceSearchCount += 1
            storedLastWorldMapPlaceQuery = query
        }
        guard let worldMapPlaceSearchResult else { throw CatalogQueryError.notFound }
        return worldMapPlaceSearchResult
    }

    func confirmWorldMapPlaceCandidate(
        tagID: UUID,
        placeID: String
    ) throws -> WorldMapPlaceTagResolution {
        _ = tagID
        lock.withLock {
            storedWorldMapPlaceConfirmCount += 1
            storedLastWorldMapPlaceID = placeID
        }
        guard let worldMapPlaceConfirmResult else { throw CatalogQueryError.notFound }
        return worldMapPlaceConfirmResult
    }

    func selectionAggregate(tagIDs: [UUID], assetIDs: [UUID]) throws -> [TagSelectionAggregate] {
        _ = tagIDs
        _ = assetIDs
        return aggregates
    }

    func mutateTag(
        tagID: UUID,
        assetIDs: [UUID],
        action: LibraryTagDecisionAction
    ) throws -> TagMutationPriorStateSnapshot {
        _ = tagID
        _ = assetIDs
        _ = action
        lock.lock()
        storedMutateCallCount += 1
        lock.unlock()
        return mutateResult
    }

    func createTagAndAccept(
        rawName: String,
        assetIDs: [UUID]
    ) throws -> TagCreateAndApplyResult {
        lock.lock()
        storedCreateTagCallCount += 1
        storedLastCreateTagName = rawName
        storedLastCreateTagAssetIDs = assetIDs
        lock.unlock()
        return createTagResult
    }

    func restoreTagMutation(_ snapshot: TagMutationPriorStateSnapshot) throws {
        _ = snapshot
        lock.lock()
        storedRestoreCallCount += 1
        lock.unlock()
    }

    func fetchJobActivity() throws -> [JobActivityItem] {
        jobs
    }

    func applyJobActivityAction(_ action: JobActivityAction, jobID: UUID) throws {
        lock.lock()
        storedLastJobAction = action
        storedLastJobActionID = jobID
        lock.unlock()
    }
}

private final class RemoteReviewPortStub: PersonalizationReviewPort, @unchecked Sendable {
    private let lock = NSLock()
    private let page: ReviewQueuePage
    private let totalPendingCount: Int
    private let overviews: [SuggestionTagOverview]
    private let personalCandidates: [PersonalSuggestionCandidate]
    private let personalTagInsertedCount: Int
    private let personalSnapshotsByTagID: [UUID: PersonalTrainingSnapshot]
    private let pendingSuggestions: [AssetPendingSuggestion]
    private var storedLastRequestedTagID: UUID?
    private var storedLastResumedJobID: UUID?
    private var storedCandidateSourceIDs: [UUID]?
    private var storedCandidateExcludedTagID: UUID?
    private var storedActivatedCapability: PersonalModelSuggestionCapability?
    private var storedPublishedTagID: UUID?
    private var storedPublishedHits: [AppPersonalTagLibrarySuggestionHit] = []

    var lastRequestedTagID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastRequestedTagID
    }

    var lastResumedJobID: UUID? { lock.withLock { storedLastResumedJobID } }
    var candidateSourceIDs: [UUID]? { lock.withLock { storedCandidateSourceIDs } }
    var candidateExcludedTagID: UUID? { lock.withLock { storedCandidateExcludedTagID } }
    var activatedCapability: PersonalModelSuggestionCapability? {
        lock.withLock { storedActivatedCapability }
    }
    var publishedTagID: UUID? { lock.withLock { storedPublishedTagID } }
    var publishedHits: [AppPersonalTagLibrarySuggestionHit] {
        lock.withLock { storedPublishedHits }
    }

    init(
        page: ReviewQueuePage,
        totalPendingCount: Int = 0,
        overviews: [SuggestionTagOverview] = [],
        personalCandidates: [PersonalSuggestionCandidate] = [],
        personalTagInsertedCount: Int = 0,
        personalSnapshotsByTagID: [UUID: PersonalTrainingSnapshot] = [:],
        pendingSuggestions: [AssetPendingSuggestion] = []
    ) {
        self.page = page
        self.totalPendingCount = totalPendingCount
        self.overviews = overviews
        self.personalCandidates = personalCandidates
        self.personalTagInsertedCount = personalTagInsertedCount
        self.personalSnapshotsByTagID = personalSnapshotsByTagID
        self.pendingSuggestions = pendingSuggestions
    }

    func totalPendingSuggestionCount(sourceIDs: [UUID]?) throws -> Int { totalPendingCount }
    func tagOverviews(sourceIDs: [UUID]?) throws -> [SuggestionTagOverview] { overviews }
    func enqueuePersonalModelRebuildIfReady() throws -> UUID? { nil }

    func personalTrainingSnapshot(
        limitingToTagIDs tagIDs: Set<UUID>,
        limitingToAssetIDs _: Set<UUID>?
    ) throws -> PersonalTrainingSnapshot {
        guard tagIDs.count == 1,
              let tagID = tagIDs.first,
              let snapshot = personalSnapshotsByTagID[tagID]
        else {
            throw PersonalizationReviewError.persistenceFailure
        }
        return snapshot
    }

    func fetchReviewQueue(
        tagID: UUID,
        sourceIDs: [UUID]?,
        cursor: ReviewQueueCursor?,
        limit: Int
    ) throws -> ReviewQueuePage {
        _ = sourceIDs
        _ = cursor
        _ = limit
        lock.lock()
        storedLastRequestedTagID = tagID
        lock.unlock()
        return page
    }

    func pendingSuggestionsForAsset(assetID: UUID) throws -> [AssetPendingSuggestion] {
        _ = assetID
        return pendingSuggestions
    }
    func personalSuggestionCandidates(
        afterAssetID: UUID?,
        limit: Int,
        sourceIDs: [UUID]?,
        excludingDecisionsForTagID: UUID?
    ) throws -> [PersonalSuggestionCandidate] {
        _ = limit
        lock.withLock {
            storedCandidateSourceIDs = sourceIDs
            storedCandidateExcludedTagID = excludingDecisionsForTagID
        }
        return afterAssetID == nil ? personalCandidates : []
    }
    func activatePersonalSuggestionBundle(_ capability: PersonalModelSuggestionCapability) throws {
        lock.withLock { storedActivatedCapability = capability }
    }
    func replacePersonalSuggestions(
        candidate: PersonalSuggestionCandidate,
        predictions: [PersonalSuggestionPrediction],
        expectedCapability: PersonalModelSuggestionCapability
    ) throws -> Int { 0 }
    func replacePersonalTagLibrarySuggestions(
        tagID: UUID,
        hits: [AppPersonalTagLibrarySuggestionHit],
        expectedCapability: PersonalModelSuggestionCapability,
        maximumPendingCount: Int
    ) throws -> Int {
        _ = expectedCapability
        _ = maximumPendingCount
        lock.withLock {
            storedPublishedTagID = tagID
            storedPublishedHits = hits
        }
        return personalTagInsertedCount
    }
    func replaceStandardSuggestions(
        assetID: UUID,
        contentRevision: Int,
        suggestions: [LocalModelSuggestion],
        expectedTarget: StandardModelSuggestionTarget
    ) throws -> Int { 0 }
    func invalidateAllPersonalSuggestionBundles() throws {}
    func enqueueFullLibrarySuggestions(
        tagID: UUID,
        mode: PersonalizationReviewEnqueueMode,
        sourceIDs: [UUID]?
    ) throws -> UUID { UUID() }
    func featureSuggestionJob(jobID: UUID) throws -> FeatureSuggestionJobProjection? { nil }
    func enqueuePersonalLibrarySuggestions(
        capability: PersonalModelSuggestionCapability,
        sourceIDs: [UUID]?
    ) throws -> UUID { UUID() }
    func personalLibrarySuggestionJob() throws -> PersonalLibrarySuggestionJobProjection? { nil }
    func enqueueStandardLibrarySuggestions(
        target: StandardModelSuggestionTarget,
        sourceIDs: [UUID]?
    ) throws -> UUID { UUID() }
    func standardLibrarySuggestionJob() throws -> StandardLibrarySuggestionJobProjection? { nil }
    func pauseSuggestionJob(jobID: UUID) throws {}
    func resumeSuggestionJob(jobID: UUID) throws {
        lock.withLock { storedLastResumedJobID = jobID }
    }
    func cancelSuggestionJob(jobID: UUID) throws {}
    func runPendingSuggestionJobs(maxSteps: Int?) throws -> Bool { false }
    func runPendingSuggestionJobsAsync(maxSteps: Int?) async throws -> Bool { false }
    func nextSuggestionRetryDelayNanoseconds() throws -> UInt64? { nil }
}

private final class RemoteTrainingWorkspacePortStub: TrainingWorkspacePort, @unchecked Sendable {
    private let lock = NSLock()
    private let storedSnapshot: TrainingWorkspaceSnapshot
    private var storedLastMediaKind: MediaKind?
    private var storedLastMethod: TrainingRunMethod?

    var lastMediaKind: MediaKind? {
        lock.withLock { storedLastMediaKind }
    }

    var lastMethod: TrainingRunMethod? {
        lock.withLock { storedLastMethod }
    }

    init(snapshot: TrainingWorkspaceSnapshot) {
        storedSnapshot = snapshot
    }

    func snapshot(
        mediaKind: MediaKind,
        method: TrainingRunMethod?,
        limit: Int
    ) throws -> TrainingWorkspaceSnapshot {
        _ = limit
        lock.withLock {
            storedLastMediaKind = mediaKind
            storedLastMethod = method
        }
        return storedSnapshot
    }
}

private final class RemoteTrainingCommandPortStub: RemoteTrainingCommandPort, @unchecked Sendable {
    private let lock = NSLock()
    private let storedSetup: TrainingCommandSetupSnapshot
    private let storedReceipt: TrainingLaunchReceipt
    private let cancelledActivity: TrainingCommandActivitySnapshot?
    private let embeddingActivity: EmbeddingPreparationActivitySnapshot?
    private var storedLaunchCount = 0
    private var storedCancelCount = 0
    private var storedEnsureRunnerCount = 0
    private var storedLastCommand: TrainingLaunchCommand?
    private var storedEmbeddingPrepareCount = 0
    private var storedEmbeddingCancelCount = 0
    private var storedLastEmbeddingCommand: EmbeddingPreparationCommand?

    var launchCount: Int { lock.withLock { storedLaunchCount } }
    var cancelCount: Int { lock.withLock { storedCancelCount } }
    var ensureRunnerCount: Int { lock.withLock { storedEnsureRunnerCount } }
    var lastCommand: TrainingLaunchCommand? { lock.withLock { storedLastCommand } }
    var embeddingPrepareCount: Int { lock.withLock { storedEmbeddingPrepareCount } }
    var embeddingCancelCount: Int { lock.withLock { storedEmbeddingCancelCount } }
    var lastEmbeddingCommand: EmbeddingPreparationCommand? {
        lock.withLock { storedLastEmbeddingCommand }
    }

    init(
        setup: TrainingCommandSetupSnapshot,
        receipt: TrainingLaunchReceipt,
        cancelledActivity: TrainingCommandActivitySnapshot? = nil,
        embeddingActivity: EmbeddingPreparationActivitySnapshot? = nil
    ) {
        storedSetup = setup
        storedReceipt = receipt
        self.cancelledActivity = cancelledActivity
        self.embeddingActivity = embeddingActivity
    }

    func setup(mediaKind: MediaKind) async throws -> TrainingCommandSetupSnapshot {
        XCTAssertEqual(mediaKind, storedSetup.mediaKind)
        return storedSetup
    }

    func launch(_ command: TrainingLaunchCommand) async throws -> TrainingLaunchReceipt {
        lock.withLock {
            storedLaunchCount += 1
            storedLastCommand = command
        }
        return storedReceipt
    }

    func activities(mediaKind _: MediaKind) async -> [TrainingCommandActivitySnapshot] {
        []
    }

    func cancelActivity(operationID: UUID) async throws -> TrainingCommandActivitySnapshot {
        guard let cancelledActivity, cancelledActivity.operationID == operationID else {
            throw TrainingCommandError.activityNotFound
        }
        lock.withLock { storedCancelCount += 1 }
        return cancelledActivity
    }

    func ensureSuggestionRunnerRunning() async {
        lock.withLock { storedEnsureRunnerCount += 1 }
    }

    func embeddingPreparationAvailable() async -> Bool {
        embeddingActivity != nil
    }

    func prepareEmbeddings(
        _ command: EmbeddingPreparationCommand
    ) async throws -> EmbeddingPreparationReceipt {
        guard let embeddingActivity else { throw TrainingCommandError.unavailable }
        lock.withLock {
            storedEmbeddingPrepareCount += 1
            storedLastEmbeddingCommand = command
        }
        return EmbeddingPreparationReceipt(activity: embeddingActivity, replayed: false)
    }

    func embeddingPreparationActivities(
        mediaKind: MediaKind
    ) async -> [EmbeddingPreparationActivitySnapshot] {
        guard let embeddingActivity, embeddingActivity.mediaKind == mediaKind else { return [] }
        return [embeddingActivity]
    }

    func cancelEmbeddingPreparation(
        operationID: UUID
    ) async throws -> EmbeddingPreparationActivitySnapshot {
        guard let embeddingActivity, embeddingActivity.operationID == operationID else {
            throw TrainingCommandError.activityNotFound
        }
        lock.withLock { storedEmbeddingCancelCount += 1 }
        return EmbeddingPreparationActivitySnapshot(
            operationID: embeddingActivity.operationID,
            mediaKind: embeddingActivity.mediaKind,
            phase: .cancelled,
            completedUnitCount: embeddingActivity.completedUnitCount,
            totalUnitCount: embeddingActivity.totalUnitCount,
            preparedCount: embeddingActivity.preparedCount,
            cachedCount: embeddingActivity.cachedCount,
            cloudOnlyCount: embeddingActivity.cloudOnlyCount,
            failedCount: embeddingActivity.failedCount,
            errorCode: nil
        )
    }
}

private final class RemoteEmbeddingCacheStub: AppSelectedAssetEmbeddingCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCallCount = 0

    var callCount: Int { lock.withLock { storedCallCount } }

    func cacheSelectedAsset(
        assetID _: UUID,
        contentRevision _: Int,
        imageData: @escaping @Sendable () async throws -> Data
    ) async throws -> AppCoreMLCachedEmbedding {
        _ = try await imageData()
        lock.withLock { storedCallCount += 1 }
        return AppCoreMLCachedEmbedding(
            identity: AppCoreMLModelIdentity(
                provider: "fixture",
                modelID: "fixture",
                modelRevision: "1",
                preprocessingRevision: "1",
                embeddingSemantics: "fixture",
                postprocessingRevision: "1",
                elementType: "float32",
                elementCount: 1,
                sourceModelSHA256: String(repeating: "1", count: 64),
                artifactSHA256: String(repeating: "2", count: 64),
                manifestSHA256: String(repeating: "3", count: 64),
                licenseID: "fixture",
                licenseSHA256: String(repeating: "4", count: 64)
            ),
            values: [0.5],
            vectorSHA256: String(repeating: "5", count: 64),
            origin: .generated
        )
    }

}

private actor RemoteBatchRebuilderStub: AppPersonalModelRebuilding {
    private let failingTagID: UUID
    private var storedSnapshots: [PersonalTrainingSnapshot] = []

    init(failingTagID: UUID) {
        self.failingTagID = failingTagID
    }

    func rebuild(
        snapshotSource: any AppPersonalTrainingSnapshotSource
    ) async throws -> AppPersonalLinearHeadIdentity {
        let snapshot = try await snapshotSource.currentSnapshot()
        storedSnapshots.append(snapshot)
        if snapshot.personalTagIDs == [failingTagID] {
            throw AppPersonalModelRebuildError.staleSnapshot
        }
        return AppPersonalLinearHeadIdentity(
            catalogScopeID: snapshot.catalogScopeID,
            decisionSnapshotRevision: String(repeating: "1", count: 64),
            labelVocabularyRevision: String(repeating: "2", count: 64),
            encoderIdentity: AppCoreMLModelIdentity(
                provider: "fixture",
                modelID: "fixture",
                modelRevision: "1",
                preprocessingRevision: "1",
                embeddingSemantics: "fixture",
                postprocessingRevision: "1",
                elementType: "float32",
                elementCount: 1,
                sourceModelSHA256: String(repeating: "3", count: 64),
                artifactSHA256: String(repeating: "4", count: 64),
                manifestSHA256: String(repeating: "5", count: 64),
                licenseID: "fixture",
                licenseSHA256: String(repeating: "6", count: 64)
            ),
            personalTagIDs: snapshot.personalTagIDs,
            weightsSHA256: String(repeating: "7", count: 64)
        )
    }

    func snapshots() -> [PersonalTrainingSnapshot] { storedSnapshots }
}

private actor RemoteSampleSuggesterStub: AppPersonalSampleSuggesting {
    private var storedCandidates: [PersonalSuggestionCandidate] = []
    private var storedCallCount = 0

    func suggest(
        candidates: [PersonalSuggestionCandidate],
        maximumSuggestionsPerAsset _: Int,
        embedding: @escaping @Sendable (PersonalSuggestionCandidate) async throws -> AppCoreMLEmbedding
    ) async throws -> AppPersonalSampleSuggestionBatch {
        storedCallCount += 1
        storedCandidates = candidates
        for candidate in candidates {
            _ = try await embedding(candidate)
        }
        return AppPersonalSampleSuggestionBatch(
            capabilities: [],
            results: [],
            skippedCount: candidates.count
        )
    }

    func candidates() -> [PersonalSuggestionCandidate] { storedCandidates }
    func callCount() -> Int { storedCallCount }
}

private actor RemoteTagLibrarySuggesterStub: AppPersonalTagLibrarySuggesting {
    struct Invocation: Equatable, Sendable {
        let tagID: UUID
        let candidates: [PersonalSuggestionCandidate]
        let maximumPendingCount: Int
        let minimumScore: Double
    }

    private let tagID: UUID
    private var storedInvocation: Invocation?
    private var storedCallCount = 0

    init(tagID: UUID) {
        self.tagID = tagID
    }

    func suggest(
        tagID: UUID,
        candidates: [PersonalSuggestionCandidate],
        maximumPendingCount: Int,
        minimumScore: Double,
        embedding: @escaping @Sendable (PersonalSuggestionCandidate) async throws -> AppCoreMLEmbedding,
        progress: (@Sendable (Int, Int, Int) -> Void)?
    ) async throws -> AppPersonalTagLibrarySuggestionBatch {
        storedCallCount += 1
        storedInvocation = Invocation(
            tagID: tagID,
            candidates: candidates,
            maximumPendingCount: maximumPendingCount,
            minimumScore: minimumScore
        )
        for (index, candidate) in candidates.enumerated() {
            _ = try await embedding(candidate)
            progress?(index + 1, index == 0 ? 1 : 1, 0)
        }
        let target = PersonalModelSuggestionTarget(
            catalogScopeID: "fixture-scope",
            bundleID: "fixture-bundle",
            bundleRevision: "1",
            provider: "fixture",
            modelID: "fixture-model",
            modelRevision: "1",
            preprocessingRevision: "1",
            elementCount: 1,
            labelVocabularyRevision: "1",
            weightsSHA256: String(repeating: "a", count: 64),
            policyRevision: "1"
        )
        return AppPersonalTagLibrarySuggestionBatch(
            tagID: self.tagID,
            capability: PersonalModelSuggestionCapability(target: target, tagIDs: [self.tagID]),
            hits: [
                AppPersonalTagLibrarySuggestionHit(candidate: candidates[0], score: 0.91),
            ],
            checkedCount: candidates.count,
            aboveThresholdCount: 1,
            skippedCount: max(0, candidates.count - 1)
        )
    }

    func invocation() -> Invocation? { storedInvocation }
    func callCount() -> Int { storedCallCount }
}

private final class RemoteLibrarySlimmingAnalysisPortStub:
    LibrarySlimmingAnalysisJobPort,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let summaries: [LibrarySlimmingAnalysisJobSummary]
    private let storedSnapshot: LibrarySlimmingAnalysisJobSnapshot
    private var storedLastMediaKind: MediaKind?
    private var storedLastSnapshotJobID: UUID?

    var lastMediaKind: MediaKind? { lock.withLock { storedLastMediaKind } }
    var lastSnapshotJobID: UUID? { lock.withLock { storedLastSnapshotJobID } }

    init(
        summaries: [LibrarySlimmingAnalysisJobSummary],
        snapshot: LibrarySlimmingAnalysisJobSnapshot
    ) {
        self.summaries = summaries
        storedSnapshot = snapshot
    }

    func enqueue(
        mode _: LibrarySlimmingAnalyzeMode,
        assetIDs _: [UUID],
        seedAssetIDs _: [UUID]
    ) throws -> LibrarySlimmingAnalysisJobSnapshot {
        storedSnapshot
    }

    func runPending() throws {}
    func pause(jobID _: UUID) throws -> LibrarySlimmingAnalysisJobSnapshot { storedSnapshot }
    func resume(jobID _: UUID) throws -> LibrarySlimmingAnalysisJobSnapshot { storedSnapshot }

    func snapshot(jobID: UUID) throws -> LibrarySlimmingAnalysisJobSnapshot {
        lock.withLock { storedLastSnapshotJobID = jobID }
        return storedSnapshot
    }

    func latestActiveOrCompleted() throws -> LibrarySlimmingAnalysisJobSnapshot? {
        storedSnapshot
    }

    func listJobs() throws -> [LibrarySlimmingAnalysisJobSummary] { summaries }

    func listJobs(mediaKind: MediaKind) throws -> [LibrarySlimmingAnalysisJobSummary] {
        lock.withLock { storedLastMediaKind = mediaKind }
        return summaries.filter { $0.mediaKind == mediaKind }
    }

    func delete(jobID _: UUID) throws {}
}

private final class RemoteLibrarySlimmingCommandPortStub:
    RemoteLibrarySlimmingCommandPort,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let storedSetup: LibrarySlimmingCommandSetupSnapshot
    private let storedReceipt: LibrarySlimmingLaunchReceipt
    private let storedRecycleSnapshot: LibrarySlimmingRecycleCommandSnapshot?
    private let storedRecycleReceipt: LibrarySlimmingRecycleCommandRequestSnapshot?
    private let storedRemovalSnapshot: LibrarySlimmingRemovalCommandSnapshot?
    private let storedRemovalReceipt: LibrarySlimmingRemovalCommandRequestSnapshot?
    private let storedHiddenAssetIDs: Set<UUID>
    private var storedLaunchCount = 0
    private var storedThresholdUpdateCount = 0
    private var storedLastLaunch: LibrarySlimmingLaunchCommand?
    private var storedLastAction: LibrarySlimmingJobCommandAction?
    private var storedLastRecycleCommand: LibrarySlimmingRecycleCommandRequest?
    private var storedLastRemovalCommand: LibrarySlimmingRemovalCommand?

    var launchCount: Int { lock.withLock { storedLaunchCount } }
    var thresholdUpdateCount: Int { lock.withLock { storedThresholdUpdateCount } }
    var lastLaunch: LibrarySlimmingLaunchCommand? { lock.withLock { storedLastLaunch } }
    var lastAction: LibrarySlimmingJobCommandAction? { lock.withLock { storedLastAction } }
    var lastRecycleCommand: LibrarySlimmingRecycleCommandRequest? {
        lock.withLock { storedLastRecycleCommand }
    }
    var lastRemovalCommand: LibrarySlimmingRemovalCommand? {
        lock.withLock { storedLastRemovalCommand }
    }

    init(
        setup: LibrarySlimmingCommandSetupSnapshot,
        receipt: LibrarySlimmingLaunchReceipt,
        recycleSnapshot: LibrarySlimmingRecycleCommandSnapshot? = nil,
        recycleReceipt: LibrarySlimmingRecycleCommandRequestSnapshot? = nil,
        removalSnapshot: LibrarySlimmingRemovalCommandSnapshot? = nil,
        removalReceipt: LibrarySlimmingRemovalCommandRequestSnapshot? = nil,
        hiddenAssetIDs: Set<UUID> = []
    ) {
        storedSetup = setup
        storedReceipt = receipt
        storedRecycleSnapshot = recycleSnapshot
        storedRecycleReceipt = recycleReceipt
        storedRemovalSnapshot = removalSnapshot
        storedRemovalReceipt = removalReceipt
        storedHiddenAssetIDs = hiddenAssetIDs
    }

    func setup(mediaKind: MediaKind) async throws -> LibrarySlimmingCommandSetupSnapshot {
        XCTAssertEqual(mediaKind, storedSetup.mediaKind)
        return storedSetup
    }

    func launch(_ command: LibrarySlimmingLaunchCommand) async throws
        -> LibrarySlimmingLaunchReceipt
    {
        lock.withLock {
            storedLaunchCount += 1
            storedLastLaunch = command
        }
        return storedReceipt
    }

    func apply(
        jobID: UUID,
        action: LibrarySlimmingJobCommandAction
    ) async throws -> LibrarySlimmingJobCommandResult {
        XCTAssertEqual(jobID, storedReceipt.jobID)
        lock.withLock { storedLastAction = action }
        return LibrarySlimmingJobCommandResult(snapshot: nil, deleted: action == .deleteRecord)
    }

    func updateThresholds(_ thresholds: NearDuplicateSceneThresholds) async throws
        -> NearDuplicateSceneThresholds
    {
        lock.withLock { storedThresholdUpdateCount += 1 }
        return thresholds
    }

    func recycleSnapshot(
        mediaKind _: MediaKind,
        sourceID _: UUID?,
        searchText _: String?,
        limit _: Int
    ) async throws -> LibrarySlimmingRecycleCommandSnapshot {
        try XCTUnwrap(storedRecycleSnapshot)
    }

    func submitRecycle(
        _ command: LibrarySlimmingRecycleCommandRequest
    ) async throws -> LibrarySlimmingRecycleCommandRequestSnapshot {
        lock.withLock { storedLastRecycleCommand = command }
        return try XCTUnwrap(storedRecycleReceipt)
    }

    func removalSnapshot(
        mediaKind _: MediaKind
    ) async throws -> LibrarySlimmingRemovalCommandSnapshot {
        try XCTUnwrap(storedRemovalSnapshot)
    }

    func submitRemoval(
        _ command: LibrarySlimmingRemovalCommand
    ) async throws -> LibrarySlimmingRemovalCommandRequestSnapshot {
        lock.withLock { storedLastRemovalCommand = command }
        return try XCTUnwrap(storedRemovalReceipt)
    }

    func slimmingHiddenAssetIDs(from assetIDs: [UUID]) async throws -> Set<UUID> {
        storedHiddenAssetIDs.intersection(assetIDs)
    }
}

private final class RemoteSourceManagementCommandPortStub:
    RemoteSourceManagementCommandPort,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let storedSnapshot: SourceManagementCommandSnapshot
    private let receipt: SourceManagementCommandRequestSnapshot
    private var storedLastCommand: SourceManagementCommandRequest?

    var lastCommand: SourceManagementCommandRequest? {
        lock.withLock { storedLastCommand }
    }

    init(
        snapshot: SourceManagementCommandSnapshot,
        receipt: SourceManagementCommandRequestSnapshot
    ) {
        storedSnapshot = snapshot
        self.receipt = receipt
    }

    func snapshot() async throws -> SourceManagementCommandSnapshot {
        storedSnapshot
    }

    func submit(
        _ command: SourceManagementCommandRequest
    ) async throws -> SourceManagementCommandRequestSnapshot {
        lock.withLock { storedLastCommand = command }
        return receipt
    }
}

private final class RemoteStorageMaintenanceCommandPortStub:
    RemoteStorageMaintenanceCommandPort,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let storedSnapshot: StorageMaintenanceCommandSnapshot
    private let receipt: StorageMaintenanceCommandRequestSnapshot
    private var storedLastCommand: StorageMaintenanceCommandRequest?

    var lastCommand: StorageMaintenanceCommandRequest? {
        lock.withLock { storedLastCommand }
    }

    init(
        snapshot: StorageMaintenanceCommandSnapshot,
        receipt: StorageMaintenanceCommandRequestSnapshot
    ) {
        storedSnapshot = snapshot
        self.receipt = receipt
    }

    func snapshot() async throws -> StorageMaintenanceCommandSnapshot {
        storedSnapshot
    }

    func submit(
        _ command: StorageMaintenanceCommandRequest
    ) async throws -> StorageMaintenanceCommandRequestSnapshot {
        lock.withLock { storedLastCommand = command }
        return receipt
    }
}

private final class RemoteGeneralSettingsCommandPortStub:
    RemoteGeneralSettingsCommandPort,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedSnapshot: GeneralSettingsSnapshot
    private let updatedSnapshot: GeneralSettingsSnapshot
    private var storedUpdateCount = 0
    private var storedLastUpdate: GeneralSettingsUpdate?

    var updateCount: Int { lock.withLock { storedUpdateCount } }
    var lastUpdate: GeneralSettingsUpdate? { lock.withLock { storedLastUpdate } }

    init(
        snapshot: GeneralSettingsSnapshot,
        updatedSnapshot: GeneralSettingsSnapshot
    ) {
        storedSnapshot = snapshot
        self.updatedSnapshot = updatedSnapshot
    }

    func snapshot() async throws -> GeneralSettingsSnapshot {
        lock.withLock { storedSnapshot }
    }

    func update(_ update: GeneralSettingsUpdate) async throws -> GeneralSettingsSnapshot {
        lock.withLock {
            storedUpdateCount += 1
            storedLastUpdate = update
            storedSnapshot = updatedSnapshot
            return storedSnapshot
        }
    }
}
