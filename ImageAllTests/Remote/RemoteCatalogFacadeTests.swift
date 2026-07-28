import Foundation
import ImageAllRemoteProtocol
import XCTest
@testable import ImageAll

final class RemoteCatalogFacadeTests: XCTestCase {
    private func makeIdempotencyStore() -> RemoteIdempotencyStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteCatalogFacadeTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("idempotency.json")
        return RemoteIdempotencyStore(storageURL: url)
    }

    private func makeFacade(
        catalog: any RemoteCatalogServing,
        review: any PersonalizationReviewPort = EmptyPersonalizationReviewPort(),
        hostAppVersion: String = "1.0.0",
        listenPort: Int = 8787,
        hostID: UUID? = nil,
        usesTLS: Bool = false,
        certificateFingerprintSHA256: String? = nil
    ) -> RemoteCatalogFacade {
        RemoteCatalogFacade(
            catalog: catalog,
            review: review,
            idempotency: makeIdempotencyStore(),
            hostAppVersion: hostAppVersion,
            listenPort: listenPort,
            hostID: hostID,
            usesTLS: usesTLS,
            certificateFingerprintSHA256: certificateFingerprintSHA256
        )
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
        XCTAssertFalse(first.replayed)
        XCTAssertEqual(second.appliedAssetCount, 1)
        XCTAssertTrue(second.replayed)
        XCTAssertEqual(catalog.mutateCallCount, 1)
    }

    func testAssetPagePassesRequestedLimitToCatalogWithoutSkipping() async throws {
        let catalog = RemoteCatalogServingStub()
        let facade = makeFacade(catalog: catalog)

        _ = try await facade.fetchAssets(RemoteAssetPageRequest(limit: 60))

        XCTAssertEqual(catalog.lastRequestedLimit, 60)
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
        let catalog = RemoteCatalogServingStub(
            previewData: Data([0xAA, 0xBB]),
            detail: AssetInspectorDetail(
                assetID: assetID,
                sourceID: UUID(),
                sourceDisplayName: "Archive",
                sourceState: .active,
                relativePath: "a.jpg",
                fileName: "a.jpg",
                mediaType: "image",
                mediaCreatedAtMs: nil,
                mediaModifiedAtMs: nil,
                width: nil,
                height: nil,
                availability: .available,
                contentRevision: 1,
                acceptedTagCount: 1,
                rejectedTagCount: 0,
                fingerprintSizeBytes: nil,
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
        let facade = makeFacade(catalog: catalog)

        let preview = try await facade.loadPreview(assetID: assetID)
        XCTAssertEqual(preview, Data([0xAA, 0xBB]))

        let detail = try await facade.fetchInspectorDetail(assetID: assetID)
        XCTAssertEqual(detail.assetID, assetID)
        XCTAssertEqual(detail.tags.first?.decision, .accepted)

        let aggregates = try await facade.selectionAggregate(RemoteTagSelectionRequest(tagIDs: [tagID], assetIDs: [assetID]))
        XCTAssertEqual(aggregates.first?.acceptedCount, 3)

        let jobs = try await facade.fetchJobActivity()
        XCTAssertEqual(jobs.first?.id, jobID)
        XCTAssertEqual(jobs.first?.state, .running)

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
}

private final class RemoteCatalogServingStub: RemoteCatalogServing, @unchecked Sendable {
    private let lock = NSLock()
    private let sources: [LibrarySourceSummary]
    private let tags: [TagListItem]
    private let items: [AssetGridItemProjection]
    private let mutateResult: TagMutationPriorStateSnapshot
    private let previewData: Data
    private let detail: AssetInspectorDetail
    private let aggregates: [TagSelectionAggregate]
    private let jobs: [JobActivityItem]
    private var storedMutateCallCount = 0
    private var storedLastRequestedLimit: Int?
    private var storedLastJobAction: JobActivityAction?
    private var storedLastJobActionID: UUID?

    var mutateCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedMutateCallCount
    }

    var lastRequestedLimit: Int? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastRequestedLimit
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
        previewData: Data = Data(),
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
        jobs: [JobActivityItem] = []
    ) {
        self.sources = sources
        self.tags = tags
        self.items = items
        self.mutateResult = mutateResult
        self.previewData = previewData
        self.detail = detail
        self.aggregates = aggregates
        self.jobs = jobs
    }

    func fetchSources() throws -> [LibrarySourceSummary] {
        sources
    }

    func listTags() throws -> [TagListItem] {
        tags
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

    func fetchInspectorDetail(assetID: UUID) throws -> AssetInspectorDetail {
        _ = assetID
        return detail
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
    private var storedLastRequestedTagID: UUID?

    var lastRequestedTagID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastRequestedTagID
    }

    init(page: ReviewQueuePage) {
        self.page = page
    }

    func totalPendingSuggestionCount(sourceIDs: [UUID]?) throws -> Int { 0 }
    func tagOverviews(sourceIDs: [UUID]?) throws -> [SuggestionTagOverview] { [] }
    func enqueuePersonalModelRebuildIfReady() throws -> UUID? { nil }

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

    func pendingSuggestionsForAsset(assetID: UUID) throws -> [AssetPendingSuggestion] { [] }
    func personalSuggestionCandidates(
        afterAssetID: UUID?,
        limit: Int,
        sourceIDs: [UUID]?,
        excludingDecisionsForTagID: UUID?
    ) throws -> [PersonalSuggestionCandidate] { [] }
    func activatePersonalSuggestionBundle(_ capability: PersonalModelSuggestionCapability) throws {}
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
    ) throws -> Int { 0 }
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
    func resumeSuggestionJob(jobID: UUID) throws {}
    func cancelSuggestionJob(jobID: UUID) throws {}
    func runPendingSuggestionJobs(maxSteps: Int?) throws -> Bool { false }
    func runPendingSuggestionJobsAsync(maxSteps: Int?) async throws -> Bool { false }
    func nextSuggestionRetryDelayNanoseconds() throws -> UInt64? { nil }
}
