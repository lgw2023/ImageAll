import Foundation
import ImageAllRemoteProtocol
import XCTest

final class RemoteProtocolRoundTripTests: XCTestCase {
    func testGeneralSettingsRoundTripPreservesSharedMacPreferences() throws {
        let snapshot = RemoteGeneralSettingsSnapshot(
            localModel: RemoteLocalModelSettings(
                isEnabled: true,
                state: .ready,
                modelName: "DINOv2 Small",
                runtimeName: "App 内 Core ML（本机）",
                detail: "模型已就绪"
            ),
            idleThumbnailPrewarmEnabled: true,
            idleThresholdSeconds: 180,
            toolbarDisplayMode: .iconAndTitle
        )
        let request = RemoteGeneralSettingsUpdateRequest(
            operationID: UUID(),
            modelEnabled: false,
            toolbarDisplayMode: .iconOnly
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteGeneralSettingsSnapshot.self,
                from: JSONEncoder().encode(snapshot)
            ),
            snapshot
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteGeneralSettingsUpdateRequest.self,
                from: JSONEncoder().encode(request)
            ),
            request
        )
        XCTAssertEqual(RemoteHTTPPaths.generalSettings, "/v1/settings/general")
    }

    func testSuggestionThresholdSettingsRoundTripPreservesOverridesAndReference() throws {
        let tagID = UUID()
        let snapshot = RemoteSuggestionThresholdSnapshot(
            defaults: [
                .init(method: .featureKnn, minScore: 0.15),
                .init(method: .personalCentroid, minScore: 0.25),
                .init(method: .personalAdamW, minScore: 0.35),
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
                                acceptedSampleCount: 8,
                                rejectedSampleCount: 7
                            )
                        ),
                    ]
                ),
            ]
        )
        let request = RemoteGeneralSettingsUpdateRequest(
            operationID: UUID(),
            suggestionThresholdMutation: .init(
                action: .setOverride,
                method: .featureKnn,
                tagID: tagID,
                minScore: 0.55
            )
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteSuggestionThresholdSnapshot.self,
                from: JSONEncoder().encode(snapshot)
            ),
            snapshot
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteGeneralSettingsUpdateRequest.self,
                from: JSONEncoder().encode(request)
            ),
            request
        )
    }

    func testAssetPageRequestDefaultsToFileNameSort() {
        XCTAssertEqual(
            RemoteAssetPageRequest().sort,
            .fileNameAscending
        )
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private let decoder = JSONDecoder()

    func testCapabilitiesRoundTrip() throws {
        let original = RemoteCapabilities(
            hostAppVersion: "1.0.0-test",
            capabilities: [.sources, .tags, .assetPages, .thumbnails, .tagDecisions, .pairing, .events],
            listenPort: 8787,
            usesTLS: true,
            hostID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
            certificateFingerprintSHA256: "deadbeef"
        )
        try assertRoundTrip(original)
    }

    func testCreateTagAndApplyRoundTrip() throws {
        let operationID = UUID()
        let tagID = UUID()
        let assetIDs = [UUID(), UUID()]

        try assertRoundTrip(
            RemoteCreateTagAndApplyRequest(
                operationID: operationID,
                name: "旅行",
                assetIDs: assetIDs
            )
        )
        try assertRoundTrip(
            RemoteCreateTagAndApplyResponse(
                operationID: operationID,
                tagID: tagID,
                displayName: "旅行",
                appliedAssetCount: 2,
                replayed: false,
                undoID: UUID()
            )
        )
    }

    func testJobNavigationAndFailureSummaryRoundTrip() throws {
        let jobID = UUID()
        try assertRoundTrip(
            RemoteJobSummary(
                id: jobID,
                kind: .librarySlimmingAnalysis,
                state: .retryableFailed,
                progress: RemoteJobProgress(completedUnitCount: 8, totalUnitCount: 12),
                availableActions: [.resume, .cancel],
                controlRequest: RemoteJobControlRequest.none,
                attempts: 2,
                maxAttempts: 10,
                lastErrorCode: "librarySlimmingAnalysisFailed",
                navigationTarget: RemoteJobNavigationTarget(
                    workspace: .librarySlimming,
                    recordID: jobID,
                    mediaKind: .image
                )
            )
        )
    }

    func testTagManagementAndUndoRoundTrip() throws {
        let operationID = UUID()
        let tagID = UUID()
        let groupID = UUID()
        try assertRoundTrip(
            RemoteTagGroupSummary(
                id: groupID,
                displayName: "旅行",
                sortOrder: 20,
                isSystem: false
            )
        )
        try assertRoundTrip(RemoteRenameTagRequest(operationID: operationID, name: "家人"))
        try assertRoundTrip(RemoteMoveTagRequest(operationID: operationID, groupID: groupID))
        try assertRoundTrip(RemoteArchiveTagRequest(operationID: operationID))
        try assertRoundTrip(
            RemoteTagMutationResponse(
                operationID: operationID,
                tag: RemoteTagSummary(
                    id: tagID,
                    displayName: "家人",
                    state: .active,
                    groupID: groupID
                ),
                replayed: false
            )
        )
        try assertRoundTrip(RemoteInstallPresetTagsRequest(operationID: operationID))
        try assertRoundTrip(
            RemoteInstallPresetTagsResponse(
                operationID: operationID,
                createdTags: [
                    RemoteTagSummary(
                        id: UUID(),
                        displayName: "风景",
                        state: .active,
                        groupID: groupID
                    ),
                ],
                replayed: false
            )
        )
        let undoID = UUID()
        try assertRoundTrip(RemoteUndoTagDecisionRequest(operationID: operationID, undoID: undoID))
        try assertRoundTrip(
            RemoteUndoTagDecisionResponse(
                operationID: operationID,
                restoredAssetCount: 2,
                replayed: false
            )
        )
    }

    func testReviewOverviewRoundTrip() throws {
        let activeJobID = UUID()
        let overview = RemoteReviewOverview(
            totalPendingSuggestionCount: 7,
            tags: [
                RemoteSuggestionTagOverview(
                    id: UUID(),
                    displayName: "猫",
                    acceptedSampleCount: 8,
                    rejectedSampleCount: 5,
                    pendingSuggestionCount: 7,
                    pendingSuggestionCounts: RemoteSuggestionOriginCounts(
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
                    canPause: true,
                    canResume: false,
                    canCancel: true,
                    activeJobID: activeJobID
                ),
            ]
        )
        try assertRoundTrip(overview)
        try assertRoundTrip(
            RemoteReviewQueueRequest(
                tagID: overview.tags[0].id,
                sourceIDs: [UUID()],
                mediaKind: .video,
                limit: 48,
                cursor: "cursor"
            )
        )
        let legacyJSON = try XCTUnwrap(
            """
            {
              "id":"\(overview.tags[0].id.uuidString)",
              "displayName":"猫",
              "acceptedSampleCount":8,
              "rejectedSampleCount":5,
              "pendingSuggestionCount":7,
              "pendingSuggestionCounts":{"featurePrint":2,"standardModel":1,"personalModel":3,"personalAdamW":1},
              "taskStatus":"completed",
              "checkedCount":120,
              "totalCount":120,
              "skippedCount":4,
              "missingPositiveCount":0,
              "missingNegativeCount":0,
              "canReview":true
            }
            """.data(using: .utf8)
        )
        let legacy = try decoder.decode(RemoteSuggestionTagOverview.self, from: legacyJSON)
        XCTAssertFalse(legacy.canGeneratePersonalModel)
        XCTAssertNil(legacy.activeJobID)
    }

    func testReviewDecisionAndUndoRoundTrip() throws {
        let operationID = UUID()
        let tagID = UUID()
        let assetIDs = [UUID(), UUID()]
        let undoID = UUID()
        try assertRoundTrip(
            RemoteBatchReviewDecisionRequest(
                operationID: operationID,
                tagID: tagID,
                assetIDs: assetIDs,
                action: .reject
            )
        )
        try assertRoundTrip(
            RemoteBatchReviewDecisionResponse(
                operationID: operationID,
                appliedAssetCount: assetIDs.count,
                replayed: false,
                undoID: undoID
            )
        )
        try assertRoundTrip(
            RemoteUndoReviewDecisionRequest(operationID: operationID, undoID: undoID)
        )
        try assertRoundTrip(
            RemoteUndoReviewDecisionResponse(
                operationID: operationID,
                restoredAssetCount: assetIDs.count,
                replayed: false
            )
        )
    }

    func testPairingOfferRoundTrip() throws {
        let original = RemotePairingOffer(
            hostID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            hostDisplayName: "Studio",
            listenPort: 8787,
            usesTLS: true,
            certificateFingerprintSHA256: "abc123",
            pairingToken: "pair-token",
            expiresAtMs: 1_700_000_000_000,
            publicBaseURL: "https://imageall.ultrahardcore.net"
        )
        try assertRoundTrip(original)
    }

    func testPublicEndpointNormalizationAcceptsOnlyDedicatedHTTPSRoot() {
        XCTAssertEqual(
            RemotePublicEndpoint.normalizedHTTPSBaseURL(
                " HTTPS://ImageAll.UltraHardcore.Net:443/ "
            ),
            "https://imageall.ultrahardcore.net"
        )
        XCTAssertNil(RemotePublicEndpoint.normalizedHTTPSBaseURL("http://imageall.example.com"))
        XCTAssertNil(RemotePublicEndpoint.normalizedHTTPSBaseURL("https://user@example.com"))
        XCTAssertNil(RemotePublicEndpoint.normalizedHTTPSBaseURL("https://example.com/api"))
        XCTAssertNil(RemotePublicEndpoint.normalizedHTTPSBaseURL("https://127.0.0.1"))
        XCTAssertNil(RemotePublicEndpoint.normalizedHTTPSBaseURL("https://[::1]"))
        XCTAssertNil(RemotePublicEndpoint.normalizedHTTPSBaseURL("https://example.com:8443"))
    }

    func testPairingOfferWithoutPublicEndpointRemainsDecodable() throws {
        let payload = Data(
            """
            {
              "hostID":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
              "hostDisplayName":"Legacy Host",
              "listenPort":8787,
              "usesTLS":true,
              "certificateFingerprintSHA256":"abc123",
              "pairingToken":"pair-token",
              "expiresAtMs":1700000000000,
              "protocolVersion":1
            }
            """.utf8
        )

        let offer = try JSONDecoder().decode(RemotePairingOffer.self, from: payload)

        XCTAssertNil(offer.publicBaseURL)
    }

    func testRemoteEventRoundTrip() throws {
        let original = RemoteEvent(
            kind: .jobsChanged,
            emittedAtMs: 1_700_000_000_000,
            jobID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        )
        try assertRoundTrip(original)
    }

    func testTagSummaryRoundTrip() throws {
        let original = RemoteTagSummary(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            displayName: "风景",
            state: .active,
            groupID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        )
        try assertRoundTrip(original)
    }

    func testTagSummaryWithoutGroupIDUsesLegacyFallbackGroup() throws {
        let payload = Data(
            """
            {
              "id":"55555555-5555-5555-5555-555555555555",
              "displayName":"风景",
              "state":"active"
            }
            """.utf8
        )

        let summary = try decoder.decode(RemoteTagSummary.self, from: payload)

        XCTAssertEqual(
            summary.groupID,
            UUID(uuidString: "a0000000-0000-4000-8000-000000000007")!
        )
    }

    func testReviewQueueRequestWithoutMediaKindDefaultsToImage() throws {
        let payload = Data(
            """
            {
              "tagID":"55555555-5555-5555-5555-555555555555",
              "sourceIDs":[],
              "limit":40
            }
            """.utf8
        )

        let request = try decoder.decode(RemoteReviewQueueRequest.self, from: payload)

        XCTAssertEqual(request.mediaKind, .image)
    }

    func testBonjourTXTRoundTripHelpers() {
        let hostID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let txt = RemoteBonjour.txtRecord(protocolVersion: 1, hostID: hostID)
        XCTAssertEqual(txt[RemoteBonjour.TXTKey.protocolVersion], "1")
        XCTAssertEqual(txt[RemoteBonjour.TXTKey.hostID], hostID.uuidString)
        XCTAssertEqual(RemoteBonjour.protocolVersion(fromTXT: txt), 1)
        XCTAssertEqual(RemoteBonjour.hostID(fromTXT: txt), hostID)
        XCTAssertEqual(RemoteBonjour.serviceType, "_imageall._tcp")
    }

    func testSourceSummaryRoundTrip() throws {
        let original = RemoteSourceSummary(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            kind: .folder,
            displayName: "Archive",
            state: .active
        )
        try assertRoundTrip(original)
    }

    func testAssetPageRoundTrip() throws {
        let item = RemoteAssetSummary(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            sourceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            sourceName: "Archive",
            fileName: "a.jpg",
            mediaType: "image",
            availability: .available,
            contentRevision: 3,
            acceptedTagCount: 1,
            rejectedTagCount: 0,
            mediaCreatedAtMs: 1_700_000_000_000,
            width: 4000,
            height: 3000
        )
        let original = RemoteAssetPage(items: [item], nextCursor: "cursor-1")
        try assertRoundTrip(original)
    }

    func testAdvancedAssetPageRequestRoundTrip() throws {
        let tagID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let original = RemoteAssetPageRequest(
            searchText: "sunset",
            sort: .oldest,
            limit: 48,
            tagDecisionFilters: [
                RemoteAssetTagDecisionFilter(tagID: tagID, decision: .accepted),
            ],
            excludedTagIDs: [UUID(uuidString: "55555555-5555-5555-5555-555555555555")!],
            tagMatchMode: .any,
            availabilities: [.available],
            mediaKinds: [.image],
            mediaTypes: ["public.jpeg"],
            tagPresence: .tagged
        )
        try assertRoundTrip(original)
    }

    func testAssetDetailRoundTripPreservesCompleteInspectorMetadata() throws {
        let suggestionTagID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let detail = RemoteAssetDetail(
            assetID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            sourceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            sourceName: "Archive",
            fileName: "clip.mp4",
            relativePath: "Trips/clip.mp4",
            mediaType: "public.mpeg-4",
            availability: .available,
            contentRevision: 4,
            acceptedTagCount: 2,
            rejectedTagCount: 1,
            mediaCreatedAtMs: 1_700_000_000_000,
            mediaModifiedAtMs: 1_700_000_100_000,
            width: 1920,
            height: 1080,
            durationMs: 12_345,
            fingerprintSizeBytes: 4_500_000,
            tags: [],
            pendingSuggestions: [
                RemoteAssetPendingSuggestion(
                    tagID: suggestionTagID,
                    displayName: "猫",
                    suggestionOrigin: .personalAdamW
                ),
            ]
        )
        try assertRoundTrip(detail)
        XCTAssertEqual(detail.pendingSuggestions?.first?.tagID, suggestionTagID)
        XCTAssertEqual(detail.pendingSuggestions?.first?.suggestionOrigin, .personalAdamW)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(detail)) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "pendingSuggestions")
        let legacy = try decoder.decode(
            RemoteAssetDetail.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        XCTAssertNil(legacy.pendingSuggestions)
    }

    func testTrainingWorkspaceRoundTripPreservesRunLedgerAndSlots() throws {
        let runID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let tagID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let batchID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let snapshot = RemoteTrainingWorkspaceSnapshot(
            mediaKind: .video,
            methodFilter: .personalAdamW,
            runs: [
                RemoteTrainingRun(
                    id: runID,
                    mediaKind: .video,
                    method: .personalAdamW,
                    state: .succeeded,
                    createdAtMs: 1_700_000_000_000,
                    startedAtMs: 1_700_000_001_000,
                    finishedAtMs: 1_700_000_002_000,
                    catalogScopeID: "allSources",
                    tagID: tagID,
                    tagDisplayName: "猫",
                    batchID: batchID,
                    batchTagIndex: 1,
                    batchTagCount: 3,
                    sampleCount: 12,
                    positiveSampleCount: 8,
                    negativeSampleCount: 4,
                    sampleSummaryJSON: "{\"sampleCount\":12}",
                    configJSON: "{\"epochs\":8}",
                    metricsJSON: "{\"evaluationSplit\":\"validation\"}",
                    artifactKind: "personal-head",
                    artifactRef: "objects/head.personal-head",
                    artifactSHA256: String(repeating: "a", count: 64),
                    resultSummaryJSON: "{\"published\":true}",
                    recoveryContext: RemoteTrainingRecoveryContext(
                        tagIDs: [tagID],
                        scope: .unresolved,
                        isExact: false,
                        note: "已恢复方法和标签"
                    ),
                    failureGuidance: RemoteTrainingFailureGuidance(
                        title: "训练未完成",
                        message: "失败记录已保留。",
                        suggestedAction: "重新配置后再试。"
                    )
                ),
            ],
            slots: [
                RemoteTrainingSlot(
                    method: .personalAdamW,
                    isPublished: true,
                    publishedRunID: runID,
                    artifactRef: "objects/head.personal-head"
                ),
            ]
        )

        try assertRoundTrip(snapshot)
    }

    func testTrainingRunDecodesLegacyPayloadWithoutRecoveryProjection() throws {
        let data = Data(#"""
        {
          "id":"66666666-6666-6666-6666-666666666666",
          "mediaKind":"image",
          "method":"featureKnn",
          "state":"failed",
          "createdAtMs":1700000000000,
          "catalogScopeID":"scope-v1"
        }
        """#.utf8)

        let run = try JSONDecoder().decode(RemoteTrainingRun.self, from: data)

        XCTAssertNil(run.recoveryContext)
        XCTAssertNil(run.failureGuidance)
        XCTAssertNil(run.tagDisplayName)
        XCTAssertNil(run.batchID)
        XCTAssertNil(run.batchTagIndex)
        XCTAssertNil(run.batchTagCount)
        XCTAssertNil(run.sampleCount)
        XCTAssertNil(run.positiveSampleCount)
        XCTAssertNil(run.negativeSampleCount)
    }

    func testTrainingSetupLaunchAndActivityRoundTrip() throws {
        let tagID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let sourceID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let operationID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let setup = RemoteTrainingSetupSnapshot(
            mediaKind: .image,
            tags: [
                RemoteTrainingTagOption(
                    id: tagID,
                    displayName: "猫",
                    acceptedSampleCount: 9,
                    rejectedSampleCount: 4,
                    featureMode: .update,
                    personalEligible: true
                ),
            ],
            sources: [RemoteTrainingSourceOption(id: sourceID, displayName: "Apple Photos")],
            methods: [
                RemoteTrainingMethodAvailability(method: .featureKnn, isAvailable: true),
                RemoteTrainingMethodAvailability(method: .personalCentroid, isAvailable: true),
                RemoteTrainingMethodAvailability(method: .personalAdamW, isAvailable: false),
            ]
        )
        try assertRoundTrip(setup)

        let request = RemoteTrainingLaunchRequest(
            operationID: operationID,
            mediaKind: .image,
            method: .featureKnn,
            tagIDs: [tagID],
            sourceIDs: [sourceID]
        )
        try assertRoundTrip(request)
        try assertRoundTrip(RemoteTrainingLaunchResponse(
            operationID: operationID,
            method: .featureKnn,
            acceptedAtMs: 1_700_000_003_000,
            scheduledTagCount: 1,
            jobID: UUID(),
            replayed: false
        ))
        let activity = RemoteTrainingActivity(
            operationID: operationID,
            mediaKind: .image,
            method: .personalCentroid,
            phase: .preparingEmbeddings,
            completedUnitCount: 0,
            totalUnitCount: 1,
            sampleCount: 9,
            availableActions: [.cancel],
            tagActivities: [
                RemoteTrainingTagActivity(
                    tagID: tagID,
                    displayName: "猫",
                    phase: .preparingEmbeddings,
                    sampleCount: 9
                ),
            ],
            acceptedAtMs: 1_700_000_003_000,
            updatedAtMs: 1_700_000_003_500
        )
        try assertRoundTrip(activity)
        try assertRoundTrip(RemoteTrainingActivityActionRequest(action: .cancel))
        try assertRoundTrip(RemoteTrainingActivityActionResponse(activity: activity))

        let legacyJSON = try XCTUnwrap(
            """
            {
              "operationID":"\(operationID.uuidString)",
              "mediaKind":"image",
              "method":"personalCentroid",
              "phase":"completed",
              "completedUnitCount":1,
              "totalUnitCount":1
            }
            """.data(using: .utf8)
        )
        let legacy = try decoder.decode(RemoteTrainingActivity.self, from: legacyJSON)
        XCTAssertEqual(legacy.availableActions, [])
        XCTAssertEqual(legacy.tagActivities, [])
        XCTAssertEqual(legacy.acceptedAtMs, 0)
        XCTAssertEqual(legacy.updatedAtMs, 0)
    }

    func testEmbeddingPreparationRoundTrip() throws {
        let operationID = UUID(uuidString: "91111111-1111-1111-1111-111111111111")!
        let assetIDs = [
            UUID(uuidString: "92222222-2222-2222-2222-222222222222")!,
            UUID(uuidString: "93333333-3333-3333-3333-333333333333")!,
        ]
        try assertRoundTrip(RemoteEmbeddingPreparationRequest(
            operationID: operationID,
            mediaKind: .image,
            assetIDs: assetIDs
        ))
        let activity = RemoteEmbeddingPreparationActivity(
            operationID: operationID,
            mediaKind: .image,
            phase: .running,
            completedUnitCount: 1,
            totalUnitCount: 2,
            preparedCount: 1,
            availableActions: [.cancel]
        )
        try assertRoundTrip(RemoteEmbeddingPreparationSnapshot(
            mediaKind: .image,
            isAvailable: true,
            activities: [activity]
        ))
        try assertRoundTrip(RemoteEmbeddingPreparationResponse(
            activity: activity,
            replayed: false
        ))
        try assertRoundTrip(RemoteEmbeddingPreparationActionRequest(action: .cancel))
        try assertRoundTrip(RemoteEmbeddingPreparationActionResponse(activity: activity))
    }

    func testSampleSuggestionRoundTrip() throws {
        let operationID = UUID(uuidString: "94444444-4444-4444-4444-444444444444")!
        let assetID = UUID(uuidString: "95555555-5555-5555-5555-555555555555")!
        try assertRoundTrip(RemoteSampleSuggestionRequest(
            operationID: operationID,
            mediaKind: .image,
            assetIDs: [assetID]
        ))
        let activity = RemoteSampleSuggestionActivity(
            operationID: operationID,
            mediaKind: .image,
            phase: .running,
            completedUnitCount: 0,
            totalUnitCount: 1,
            availableActions: [.cancel]
        )
        try assertRoundTrip(RemoteSampleSuggestionSnapshot(
            mediaKind: .image,
            isAvailable: true,
            maximumSampleCount: 500,
            activities: [activity]
        ))
        try assertRoundTrip(RemoteSampleSuggestionResponse(activity: activity, replayed: false))
        try assertRoundTrip(RemoteSampleSuggestionActionRequest(action: .cancel))
        try assertRoundTrip(RemoteSampleSuggestionActionResponse(activity: activity))
    }

    func testTagLibrarySuggestionRoundTrip() throws {
        let operationID = UUID(uuidString: "96666666-6666-6666-6666-666666666666")!
        let tagID = UUID(uuidString: "97777777-7777-7777-7777-777777777777")!
        let sourceID = UUID(uuidString: "98888888-8888-8888-8888-888888888888")!
        try assertRoundTrip(RemoteTagLibrarySuggestionRequest(
            operationID: operationID,
            mediaKind: .image,
            method: .personalAdamW,
            tagID: tagID,
            sourceIDs: [sourceID]
        ))
        let activity = RemoteTagLibrarySuggestionActivity(
            operationID: operationID,
            mediaKind: .image,
            method: .personalAdamW,
            tagID: tagID,
            phase: .scoring,
            completedUnitCount: 12,
            totalUnitCount: 40,
            aboveThresholdCount: 7,
            insertedCount: 0,
            skippedCount: 1,
            availableActions: [.cancel]
        )
        try assertRoundTrip(RemoteTagLibrarySuggestionSnapshot(
            mediaKind: .image,
            maximumPendingCount: 500,
            personalCentroidAvailable: true,
            personalAdamWAvailable: true,
            tags: [
                RemoteTagLibrarySuggestionTagOption(
                    tagID: tagID,
                    personalEligible: true,
                    personalCentroidMinScore: 0.35,
                    personalAdamWMinScore: 0.55
                ),
            ],
            activities: [activity]
        ))
        try assertRoundTrip(RemoteTagLibrarySuggestionResponse(
            activity: activity,
            replayed: false
        ))
        try assertRoundTrip(RemoteTagLibrarySuggestionActionRequest(action: .cancel))
        try assertRoundTrip(RemoteTagLibrarySuggestionActionResponse(activity: activity))
    }

    func testBatchTagDecisionRoundTrip() throws {
        let request = RemoteBatchTagDecisionRequest(
            operationID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            tagID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            assetIDs: [UUID(uuidString: "22222222-2222-2222-2222-222222222222")!],
            action: .accept
        )
        try assertRoundTrip(request)

        let response = RemoteBatchTagDecisionResponse(
            operationID: request.operationID,
            appliedAssetCount: 1,
            replayed: false,
            undoID: UUID()
        )
        try assertRoundTrip(response)
    }

    func testLibrarySlimmingWorkspaceRoundTrip() throws {
        let jobID = UUID(uuidString: "11111111-aaaa-bbbb-cccc-111111111111")!
        let clusterID = UUID(uuidString: "22222222-aaaa-bbbb-cccc-222222222222")!
        let assetID = UUID(uuidString: "33333333-aaaa-bbbb-cccc-333333333333")!
        let sourceID = UUID(uuidString: "44444444-aaaa-bbbb-cccc-444444444444")!
        let snapshot = RemoteLibrarySlimmingWorkspaceSnapshot(
            mediaKind: .image,
            jobs: [
                RemoteLibrarySlimmingJob(
                    id: jobID,
                    mode: .catalog,
                    mediaKind: .image,
                    state: .completed,
                    progress: RemoteJobProgress(completedUnitCount: 25, totalUnitCount: 25),
                    attempts: 1,
                    maxAttempts: 10,
                    memberCount: 12,
                    seedCount: 0,
                    clusterCount: 1,
                    hasResult: true,
                    createdAtMs: 1_700_000_000_000,
                    updatedAtMs: 1_700_000_001_000,
                    sourceNames: ["Apple Photos"],
                    availableActions: [],
                    controlRequest: .pause,
                    scanProgress: RemoteLibrarySlimmingScanProgress(
                        phase: .loadingFeaturePrints,
                        completedUnitCount: 6,
                        totalUnitCount: 12
                    ),
                    lastErrorCode: "interrupted"
                ),
            ],
            selectedJobID: jobID,
            clusters: [
                RemoteLibrarySlimmingCluster(
                    id: clusterID,
                    kind: .nearDuplicateScene,
                    memberCount: 1,
                    representativeAssetID: assetID,
                    score: 0.91,
                    technicalSummary: "DINOv2 余弦 0.910 · policy:librarySlimming.v1"
                ),
            ],
            selectedClusterID: clusterID,
            members: [
                RemoteLibrarySlimmingMember(
                    id: assetID,
                    sourceID: sourceID,
                    sourceName: "Apple Photos",
                    fileName: "IMG_0001.HEIC",
                    mediaType: "public.heic",
                    availability: .available,
                    contentRevision: 2,
                    width: 3024,
                    height: 4032
                ),
            ],
            pendingAnalysisCount: 0,
            analyzedAssetCount: 12,
            policyVersion: "librarySlimming.v1"
        )
        try assertRoundTrip(snapshot)
    }

    func testLibrarySlimmingSetupLaunchActionsAndThresholdsRoundTrip() throws {
        let sourceID = UUID(uuidString: "55555555-aaaa-bbbb-cccc-555555555555")!
        let operationID = UUID(uuidString: "66666666-aaaa-bbbb-cccc-666666666666")!
        let jobID = UUID(uuidString: "77777777-aaaa-bbbb-cccc-777777777777")!
        let thresholds = RemoteLibrarySlimmingThresholds(
            featurePrintRecallTopK: 32,
            featurePrintMaxL2Distance: 0.38,
            dinoCosineMinSimilarity: 0.86,
            sceneBucketActivationAssetCount: 800,
            featurePrintRecallMode: .topK,
            featurePrintL2Mode: .radius,
            dinoCosineMode: .minimum,
            sceneBucketingMode: .automatic
        )
        try assertRoundTrip(RemoteLibrarySlimmingSetupSnapshot(
            mediaKind: .image,
            sources: [
                RemoteLibrarySlimmingSourceOption(
                    id: sourceID,
                    displayName: "Apple Photos",
                    kind: .photos
                ),
            ],
            thresholds: thresholds,
            factoryThresholds: thresholds
        ))
        let filter = RemoteAssetPageRequest(
            sourceIDs: [sourceID],
            searchText: "猫",
            sort: .newest,
            limit: 200,
            mediaKinds: [.image]
        )
        try assertRoundTrip(RemoteLibrarySlimmingLaunchRequest(
            operationID: operationID,
            mediaKind: .image,
            mode: .currentFilter,
            sourceIDs: nil,
            filter: filter
        ))
        try assertRoundTrip(RemoteLibrarySlimmingLaunchResponse(
            operationID: operationID,
            jobID: jobID,
            acceptedAtMs: 1_700_000_004_000,
            memberCount: 18,
            replayed: false
        ))
        try assertRoundTrip(RemoteLibrarySlimmingJobActionRequest(
            operationID: UUID(),
            action: .pause
        ))
        try assertRoundTrip(RemoteLibrarySlimmingJobActionResponse(
            job: nil,
            deleted: true,
            replayed: false
        ))
        try assertRoundTrip(RemoteLibrarySlimmingThresholdUpdateRequest(
            operationID: UUID(),
            thresholds: thresholds
        ))
        try assertRoundTrip(RemoteLibrarySlimmingThresholdUpdateResponse(
            thresholds: thresholds,
            replayed: false
        ))
    }

    func testLibrarySlimmingRecycleSnapshotAndRequestRoundTrip() throws {
        let entryID = UUID(uuidString: "88888888-bbbb-cccc-dddd-888888888888")!
        let assetID = UUID(uuidString: "99999999-bbbb-cccc-dddd-999999999999")!
        let sourceID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-aaaaaaaaaaaa")!
        let operationID = UUID(uuidString: "bbbbbbbb-bbbb-cccc-dddd-bbbbbbbbbbbb")!
        let request = RemoteLibrarySlimmingRecycleRequestSnapshot(
            id: UUID(),
            operationID: operationID,
            entryID: entryID,
            action: .restore,
            fileName: "IMG_0001.HEIC",
            phase: .awaitingMac,
            message: "请回到 Mac 完成原生确认",
            updatedAtMs: 1_700_000_005_000
        )
        try assertRoundTrip(RemoteLibrarySlimmingRecycleSnapshot(
            mediaKind: .image,
            entries: [
                RemoteLibrarySlimmingRecycleEntry(
                    id: entryID,
                    assetID: assetID,
                    sourceID: sourceID,
                    sourceDisplayName: "Archive",
                    sourceKind: .file,
                    mediaKind: .image,
                    fileName: "IMG_0001.HEIC",
                    trashedAtMs: 1_700_000_000_000,
                    purgeAfterMs: 1_702_592_000_000,
                    state: .recycled,
                    errorCode: nil,
                    resolution: .restoreOrPurge,
                    availableActions: [.restore, .purge]
                ),
            ],
            totalCount: 1,
            requests: [request]
        ))
        try assertRoundTrip(RemoteLibrarySlimmingRecycleSubmitRequest(
            operationID: operationID,
            entryID: entryID,
            action: .restore
        ))
    }

    func testLibrarySlimmingBatchRemovalSnapshotAndRequestRoundTrip() throws {
        let operationID = UUID()
        let jobID = UUID()
        let clusterID = UUID()
        let assetIDs = [UUID(), UUID()]
        let audit = RemoteLibrarySlimmingRemovalAudit(
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
            photosMutationFailureCategories: [],
            photosMutationFailureCodes: [],
            sourceChangedAssetIDs: [assetIDs[1]]
        )
        let request = RemoteLibrarySlimmingRemovalRequestSnapshot(
            id: UUID(),
            operationID: operationID,
            jobID: jobID,
            clusterID: clusterID,
            mediaKind: .image,
            assetIDs: assetIDs,
            mode: .recoverableRecycle,
            phase: .completed,
            progress: RemoteLibrarySlimmingRemovalProgress(
                phase: .completedAsset,
                completedAssetCount: 2,
                totalAssetCount: 2,
                copiedBytes: 1_024,
                totalFileBytes: 1_024
            ),
            audit: audit,
            message: "已移入可恢复回收站 1 项 · 失败 1 项",
            updatedAtMs: 1_700_000_006_000
        )
        try assertRoundTrip(RemoteLibrarySlimmingRemovalSnapshot(
            mediaKind: .image,
            requests: [request]
        ))
        try assertRoundTrip(RemoteLibrarySlimmingRemovalSubmitRequest(
            operationID: operationID,
            jobID: jobID,
            clusterID: clusterID,
            mediaKind: .image,
            assetIDs: assetIDs,
            mode: .recoverableRecycle
        ))
    }

    func testLibrarySlimmingIdenticalCleanupPlanExecutionAndVerificationRoundTrip() throws {
        let planID = UUID()
        let jobID = UUID()
        let operationID = UUID()
        try assertRoundTrip(RemoteLibrarySlimmingIdenticalCleanupPlanRequest(
            jobID: jobID,
            mediaKind: .image
        ))
        try assertRoundTrip(RemoteLibrarySlimmingIdenticalCleanupPlanSnapshot(
            id: planID,
            jobID: jobID,
            mediaKind: .image,
            groupCount: 3,
            verifiedAssetCount: 8,
            retainedAssetCount: 3,
            removalAssetCount: 5,
            skippedGroupCount: 1,
            photosAssetCount: 2,
            fileAssetCount: 3,
            groupSizeHistogram: [2: 2, 4: 1],
            preparedAtMs: 1_700_000_007_000
        ))
        try assertRoundTrip(RemoteLibrarySlimmingIdenticalCleanupSubmitRequest(
            operationID: operationID,
            planID: planID,
            mode: .releaseSourceSpace
        ))
        let request = RemoteLibrarySlimmingIdenticalCleanupRequestSnapshot(
            id: UUID(),
            operationID: operationID,
            planID: planID,
            jobID: jobID,
            mediaKind: .image,
            mode: .releaseSourceSpace,
            phase: .completed,
            progress: RemoteLibrarySlimmingRemovalProgress(
                phase: .completedAsset,
                completedAssetCount: 5,
                totalAssetCount: 5,
                copiedBytes: 0,
                totalFileBytes: 0
            ),
            audit: nil,
            verification: RemoteLibrarySlimmingIdenticalCleanupVerification(
                verifiedGroupCount: 3,
                targetGroupCount: 3,
                targetRetainedAssetCount: 3,
                observedAssetCount: 8,
                currentAvailableAssetCount: 3,
                retainedNonredundantAssetCount: 3,
                recycledRedundantAssetCount: 5,
                remainingRedundantAssetCount: 0,
                unresolvedAssetCount: 0,
                unresolvedGroupCount: 0,
                isComplete: true
            ),
            message: "已完成去重 3/3 组",
            updatedAtMs: 1_700_000_008_000
        )
        try assertRoundTrip(RemoteLibrarySlimmingIdenticalCleanupSnapshot(
            mediaKind: .image,
            requests: [request]
        ))
    }

    func testAPIErrorRoundTrip() throws {
        let original = RemoteAPIError(code: .unauthorized, message: "missing token")
        try assertRoundTrip(original)
        XCTAssertEqual(original.localizedDescription, "missing token")
    }

    func testSourceManagementSnapshotAndSubmitRoundTrip() throws {
        let sourceID = UUID(uuidString: "88888888-aaaa-bbbb-cccc-888888888888")!
        let requestID = UUID(uuidString: "99999999-aaaa-bbbb-cccc-999999999999")!
        let operationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-aaaaaaaaaaaa")!
        let activity = RemoteSourceManagementRequestSnapshot(
            id: requestID,
            operationID: operationID,
            action: .prewarmOriginalAspect,
            sourceID: sourceID,
            sourceDisplayName: "Archive",
            phase: .running,
            message: "正在预热 Archive 的原比例缓存 8 / 20",
            completedCount: 8,
            totalCount: 20,
            warmedCount: 7,
            failedCount: 1,
            updatedAtMs: 1_700_000_005_000
        )
        try assertRoundTrip(RemoteSourceManagementSnapshot(
            sources: [
                RemoteSourceSummary(
                    id: sourceID,
                    kind: .folder,
                    displayName: "Archive",
                    state: .authorizationRequired
                ),
            ],
            canConnectPhotos: true,
            requests: [activity]
        ))
        try assertRoundTrip(RemoteSourceManagementSubmitRequest(
            operationID: operationID,
            action: .prewarmOriginalAspect,
            sourceID: sourceID
        ))
        try assertRoundTrip(RemoteSourceManagementSubmitRequest(
            operationID: UUID(),
            action: .cancelPrewarm,
            sourceID: sourceID
        ))
        try assertRoundTrip(RemoteSourceManagementSubmitRequest(
            operationID: UUID(),
            action: .requestPhotosWriteAuthorization,
            sourceID: sourceID
        ))
        try assertRoundTrip(RemoteSourceManagementSubmitRequest(
            operationID: UUID(),
            action: .refreshFolderMutationAuthorization,
            sourceID: sourceID
        ))
        try assertRoundTrip(activity)
    }

    func testWorldMapSnapshotSelectionAndAssetsRoundTrip() throws {
        let assetID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-bbbbbbbbbbbb")!
        let bounds = RemoteWorldMapBounds(west: 118, south: 30, east: 123, north: 33)
        let query = RemoteWorldMapSelectionQuery(
            cellDegrees: 0.25,
            longitudeBucket: 1_200,
            latitudeBucket: 480,
            bounds: bounds,
            maximumAssets: 36
        )
        let cluster = RemoteWorldMapCluster(
            id: "cluster-shanghai",
            longitude: 121.47,
            latitude: 31.23,
            photoCount: 42,
            gpsCount: 30,
            tagCount: 12,
            displayName: "上海",
            selectionQuery: query
        )
        try assertRoundTrip(RemoteWorldMapSnapshot(
            clusters: [cluster],
            eligiblePhotoCount: 100,
            locatedPhotoCount: 70,
            unlocatedPhotoCount: 30
        ))
        try assertRoundTrip(RemoteWorldMapSelectionRequest(query: query))
        try assertRoundTrip(RemoteWorldMapSelection(
            assets: [
                RemoteWorldMapAsset(
                    id: assetID,
                    fileName: "IMG_0001.HEIC",
                    availability: .available,
                    contentRevision: 2
                ),
            ],
            totalPhotoCount: 42
        ))
        let sourceID = UUID(uuidString: "aaaaaaaa-2222-3333-4444-aaaaaaaaaaaa")!
        let backfill = RemoteWorldMapLocationBackfillSnapshot(
            sourceID: sourceID,
            sourceKind: .photos,
            sourceDisplayName: "Apple Photos",
            sourceState: .active,
            phase: .running,
            totalPhotoCount: 100,
            inspectedPhotoCount: 40,
            locatedPhotoCount: 28,
            activeJobID: UUID(),
            scanProgress: RemoteJobProgress(completedUnitCount: 41, totalUnitCount: 100),
            canStart: false,
            canCancel: true
        )
        try assertRoundTrip(backfill)
        let command = RemoteWorldMapLocationBackfillCommandRequest(
            operationID: UUID(),
            sourceID: sourceID,
            action: .cancel
        )
        try assertRoundTrip(command)
        try assertRoundTrip(RemoteWorldMapLocationBackfillCommandResponse(
            operationID: command.operationID,
            snapshot: backfill,
            replayed: false
        ))
        let tagID = UUID(uuidString: "cccccccc-1111-2222-3333-cccccccccccc")!
        let candidate = RemoteWorldMapPlaceCandidate(
            placeID: "place-shanghai",
            displayName: "上海市",
            subtitle: "中国上海市",
            latitude: 31.23,
            longitude: 121.47,
            kind: .city
        )
        let resolution = RemoteWorldMapPlaceTagResolution(
            tagID: tagID,
            tagName: "上海",
            groupName: "地点与场景",
            acceptedPhotoCount: 18,
            status: .ambiguous,
            candidates: [candidate]
        )
        try assertRoundTrip(RemoteWorldMapPlaceTagSnapshot(
            items: [resolution],
            maximumQueryLength: 160
        ))
        let search = RemoteWorldMapPlaceTagCommandRequest(
            operationID: UUID(),
            tagID: tagID,
            action: .search,
            query: "上海 中国"
        )
        try assertRoundTrip(search)
        try assertRoundTrip(RemoteWorldMapPlaceTagCommandRequest(
            operationID: UUID(),
            tagID: tagID,
            action: .confirm,
            placeID: candidate.placeID
        ))
        try assertRoundTrip(RemoteWorldMapPlaceTagCommandResponse(
            operationID: search.operationID,
            resolution: resolution,
            replayed: false
        ))
    }

    func testGalleryOverviewRoundTrip() throws {
        let sourceID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-aaaaaaaaaaaa")!
        let tagID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-bbbbbbbbbbbb")!
        try assertRoundTrip(RemoteGalleryOverviewSnapshot(
            media: [
                RemoteGalleryOverviewMediaSummary(
                    mediaKind: .image,
                    totalCount: 120,
                    exactUniqueCount: 110,
                    exactRedundantCount: 10,
                    exactFingerprintCount: 118
                ),
            ],
            sources: [
                RemoteGalleryOverviewSourceSummary(
                    id: sourceID,
                    displayName: "Apple Photos",
                    kind: .photos,
                    state: .active,
                    imageCount: 100,
                    videoCount: 20
                ),
            ],
            positiveTags: [
                RemoteGalleryOverviewTagSummary(
                    id: tagID,
                    displayName: "猫",
                    imageCount: 18,
                    videoCount: 2
                ),
            ],
            years: [RemoteGalleryOverviewYearSummary(year: 2026, imageCount: 90, videoCount: 12)],
            availability: [
                RemoteGalleryOverviewAvailabilitySummary(
                    availability: .available,
                    imageCount: 118,
                    videoCount: 20
                ),
            ],
            undatedCount: 18,
            positiveLabeledAssetCount: 20,
            acceptedDecisionCount: 24
        ))
    }

    func testStorageMaintenanceSnapshotAndSubmitRoundTrip() throws {
        let operationID = UUID(uuidString: "aaaaaaaa-2222-3333-4444-aaaaaaaaaaaa")!
        let request = RemoteStorageMaintenanceRequestSnapshot(
            id: UUID(uuidString: "bbbbbbbb-2222-3333-4444-bbbbbbbbbbbb")!,
            operationID: operationID,
            action: .exportPortableData,
            phase: .completed,
            message: "已导出 42 条记录",
            updatedAtMs: 1_700_000_000_000,
            result: RemoteStorageMaintenanceRequestResult(
                bundleName: "ImageAll-Export-20260806",
                totalRecordCount: 42
            )
        )
        try assertRoundTrip(RemoteStorageMaintenanceSnapshot(
            previewCache: RemoteStorageUsageSummary(
                entryCount: 12,
                registeredBytes: 1_500_000
            ),
            photosOriginals: RemoteStorageUsageSummary(
                entryCount: 3,
                registeredBytes: 9_000_000
            ),
            appStorage: RemoteAppStorageSummary(
                kind: .internalStorage,
                requiresRestart: true,
                pendingExternalRootName: "ImageAll-External"
            ),
            requests: [request]
        ))
        try assertRoundTrip(RemoteStorageMaintenanceSubmitRequest(
            operationID: operationID,
            action: .exportPortableData
        ))
    }

    private func assertRoundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(T.self, from: data)
        XCTAssertEqual(decoded, value)
    }
}
