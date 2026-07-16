import Foundation
import XCTest
@testable import ImageAll

@MainActor
final class LibraryWorkspaceModelTests: XCTestCase {
    func testConnectFolderRunsReconcileAndLoadsFirstPage() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        XCTAssertEqual(model.phase, .empty)

        await model.connectFolder()

        XCTAssertEqual(model.phase, .content)
        XCTAssertEqual(model.sources.map(\.id), [sourceID])
        XCTAssertEqual(model.items.map(\.assetID), [asset.assetID])
        XCTAssertEqual(service.reconcileRunCount, 1)
    }

    func testReauthorizingSourceRestoresActiveStateAndRunsReconcile() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(
                id: sourceID,
                displayName: "Fixture",
                state: .authorizationRequired
            ),
            reconciledItems: [asset]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        XCTAssertEqual(model.sources.first?.state, .authorizationRequired)

        await model.reauthorizeSource(sourceID)

        XCTAssertEqual(model.sources.first?.state, .active)
        XCTAssertEqual(model.items.map(\.assetID), [asset.assetID])
        XCTAssertEqual(service.reauthorizeCallCount, 1)
        XCTAssertEqual(service.reconcileRunCount, 2)
    }

    func testDisablingSourceKeepsCatalogItemsAndMarksSourceDisabled() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await model.disableSource(sourceID)

        XCTAssertEqual(model.sources.first?.state, .disabled)
        XCTAssertEqual(model.items.map(\.assetID), [asset.assetID])
        XCTAssertEqual(service.disableCallCount, 1)
        XCTAssertEqual(service.reconcileRunCount, 1)
    }

    func testSourceActionFailureKeepsVisibleCatalogAndShowsNotice() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            sourceMutationFails: true
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await model.disableSource(sourceID)

        XCTAssertEqual(model.phase, .content)
        XCTAssertEqual(model.sources.first?.state, .active)
        XCTAssertEqual(model.items.map(\.assetID), [asset.assetID])
        XCTAssertEqual(model.notice, .sourceActionFailed)
    }

    func testScanFailureIsVisibleInsteadOfLookingLikeAnEmptyLibrary() async {
        let sourceID = UUID()
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [],
            scanFails: true
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()

        XCTAssertEqual(model.phase, .failed(.scanFailed))
        XCTAssertEqual(model.sources.map(\.id), [sourceID])
    }

    func testSelectedAssetCanBeAcceptedAndUndoneFromInspector() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            tags: [tag]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await model.selectAsset(asset.assetID)

        XCTAssertEqual(model.inspectorTags.first?.decision, .unknown)

        await model.applyTagDecision(tagID: tag.id, action: .accept)

        XCTAssertEqual(model.inspectorTags.first?.decision, .accepted)
        XCTAssertEqual(model.items.first?.acceptedTagCount, 1)
        XCTAssertTrue(model.canUndoTagMutation)

        await model.undoLastTagMutation()

        XCTAssertEqual(model.inspectorTags.first?.decision, .unknown)
        XCTAssertEqual(model.items.first?.acceptedTagCount, 0)
        XCTAssertFalse(model.canUndoTagMutation)
    }

    func testSearchAndTagFiltersUseExplicitAnyAndClearHiddenSelection() async {
        let sourceID = UUID()
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "beach.jpg")
        let family = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let print = TagListItem(id: UUID(), displayName: "Print", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [first, second],
            tags: [family, print]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await model.selectAsset(first.assetID)

        await model.applySearchText("beach")
        await model.toggleAcceptedTagFilter(family.id)
        await model.toggleAcceptedTagFilter(print.id)
        await model.setTagMatchMode(.any)

        XCTAssertTrue(model.selectedAssetIDs.isEmpty)
        XCTAssertEqual(model.items.map(\.assetID), [second.assetID])
        XCTAssertEqual(service.lastFilter.searchText, "beach")
        XCTAssertEqual(service.lastFilter.tagMatchMode, .any)
        XCTAssertEqual(
            Set(service.lastFilter.tagDecisionFilters.map(\.tagID)),
            Set([family.id, print.id])
        )
        XCTAssertTrue(service.lastFilter.tagDecisionFilters.allSatisfy { $0.decision == .accepted })
    }

    func testMultiSelectionShowsMixedStateAndCreatesAcceptedTag() async {
        let sourceID = UUID()
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "second.jpg")
        let family = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [first, second],
            tags: [family]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await model.selectAsset(first.assetID)
        await model.applyTagDecision(tagID: family.id, action: .accept)
        await model.selectAsset(second.assetID, additive: true)

        XCTAssertEqual(model.inspectorTags.first?.decision, .mixed)

        await model.createAndAcceptTag(named: "Print")

        XCTAssertEqual(model.selectedAssetIDs, Set([first.assetID, second.assetID]))
        XCTAssertEqual(model.tags.map(\.displayName), ["Family", "Print"])
        XCTAssertEqual(
            model.inspectorTags.first(where: { $0.displayName == "Print" })?.decision,
            .accepted
        )
        XCTAssertTrue(model.canUndoTagMutation)
    }

    func testRenameTagRefreshesSidebarAndInspectorPresentation() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            tags: [tag]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await model.selectAsset(asset.assetID)

        let succeeded = await model.renameTag(tag.id, to: "Loved")

        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.tags.map(\.displayName), ["Loved"])
        XCTAssertEqual(model.inspectorTags.map(\.displayName), ["Loved"])
    }

    func testArchiveTagClearsItsFilterAndKeepsCatalogVisible() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            tags: [tag]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await model.selectAsset(asset.assetID)
        await model.showAcceptedTag(tag.id)

        let succeeded = await model.archiveTag(tag.id)

        XCTAssertTrue(succeeded)
        XCTAssertTrue(model.tags.isEmpty)
        XCTAssertTrue(model.selectedTagFilterIDs.isEmpty)
        XCTAssertTrue(service.lastFilter.tagDecisionFilters.isEmpty)
        XCTAssertEqual(model.items.map(\.assetID), [asset.assetID])
        XCTAssertTrue(model.inspectorTags.isEmpty)
    }

    func testRenameTagFailureKeepsExistingPresentationAndShowsNotice() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            tags: [tag],
            tagMutationFails: true
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await model.selectAsset(asset.assetID)

        let succeeded = await model.renameTag(tag.id, to: "Loved")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(model.tags.map(\.displayName), ["Family"])
        XCTAssertEqual(model.inspectorTags.map(\.displayName), ["Family"])
        XCTAssertEqual(model.notice, .tagMutationFailed)
    }

    func testTagMutationFailureIsVisibleAndDoesNotCreateUndoHistory() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset],
            tags: [tag],
            tagMutationFails: true
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await model.selectAsset(asset.assetID)
        await model.applyTagDecision(tagID: tag.id, action: .accept)

        XCTAssertEqual(model.notice, .tagMutationFailed)
        XCTAssertFalse(model.canUndoTagMutation)
        XCTAssertEqual(model.inspectorTags.first?.decision, .unknown)
    }

    func testSinglePhotoModeMovesPrimarySelectionAndReturnsToGrid() async {
        let sourceID = UUID()
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "second.jpg")
        let third = Self.makeAsset(sourceID: sourceID, fileName: "third.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [first, second, third]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await model.selectAsset(second.assetID)

        model.toggleSinglePhotoView()
        XCTAssertTrue(model.isSinglePhotoPresented)
        XCTAssertEqual(model.primarySelectedAssetID, second.assetID)

        await model.movePrimarySelection(by: 1)
        XCTAssertTrue(model.isSinglePhotoPresented)
        XCTAssertEqual(model.selectedAssetIDs, [third.assetID])
        XCTAssertEqual(model.inspectorDetail?.assetID, third.assetID)

        await model.movePrimarySelection(by: -1)
        XCTAssertEqual(model.selectedAssetIDs, [second.assetID])
        XCTAssertEqual(model.inspectorDetail?.assetID, second.assetID)

        model.closeSinglePhotoView()
        XCTAssertFalse(model.isSinglePhotoPresented)
        XCTAssertEqual(model.selectedAssetIDs, [second.assetID])
    }

    func testAvailabilityFormatAndSortControlsReloadCatalogAndClearHiddenSelection() async {
        let sourceID = UUID()
        let availableJPEG = Self.makeAsset(
            sourceID: sourceID,
            fileName: "available.jpg",
            mediaType: "public.jpeg",
            availability: .available
        )
        let missingPNG = Self.makeAsset(
            sourceID: sourceID,
            fileName: "missing.png",
            mediaType: "public.png",
            availability: .missing
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [availableJPEG, missingPNG]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await model.selectAsset(availableJPEG.assetID)

        await model.toggleAvailabilityFilter(.missing)
        await model.toggleMediaTypeFilterGroup(["public.png"])
        await model.setSort(.oldest)

        XCTAssertEqual(model.selectedAvailabilities, [.missing])
        XCTAssertEqual(model.selectedMediaTypes, ["public.png"])
        XCTAssertEqual(model.sort, .oldest)
        XCTAssertEqual(service.lastFilter.availabilities, [.missing])
        XCTAssertEqual(service.lastFilter.mediaTypes, ["public.png"])
        XCTAssertEqual(service.lastSort, .oldest)
        XCTAssertEqual(model.items.map(\.assetID), [missingPNG.assetID])
        XCTAssertTrue(model.selectedAssetIDs.isEmpty)
        XCTAssertEqual(model.notice, .selectionHiddenByFilter)
    }

    func testClearingAssetPropertyFiltersRestoresAllFormatsAndStates() async {
        let sourceID = UUID()
        let availableJPEG = Self.makeAsset(sourceID: sourceID, fileName: "available.jpg")
        let missingPNG = Self.makeAsset(
            sourceID: sourceID,
            fileName: "missing.png",
            mediaType: "public.png",
            availability: .missing
        )
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [availableJPEG, missingPNG]
        )
        let model = LibraryWorkspaceModel(service: service)

        await model.start()
        await model.connectFolder()
        await model.toggleAvailabilityFilter(.missing)
        await model.toggleMediaTypeFilterGroup(["public.png"])
        XCTAssertEqual(model.items.map(\.assetID), [missingPNG.assetID])

        await model.clearAssetPropertyFilters()

        XCTAssertTrue(model.selectedAvailabilities.isEmpty)
        XCTAssertTrue(model.selectedMediaTypes.isEmpty)
        XCTAssertEqual(model.items.map(\.assetID), [availableJPEG.assetID, missingPNG.assetID])
    }

    func testBulkReviewAcceptanceUsesSingleMutationAndUndoRestoresAll() async {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let assets = (0 ..< 3).map { _ in Self.makeAsset(sourceID: sourceID) }
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: assets,
            tags: [tag]
        )
        let review = FakePersonalizationReviewPort(
            queueItems: assets.map {
                ReviewQueueItemProjection(
                    assetID: $0.assetID,
                    fileName: $0.fileName,
                    availability: $0.availability,
                    acceptedTagCount: 0,
                    rejectedTagCount: 0
                )
            }
        )
        let model = LibraryWorkspaceModel(service: service, review: review)

        await model.enterReviewQueue(tagID: tag.id, displayName: tag.displayName)
        await model.selectAsset(assets[0].assetID)
        await model.selectAsset(assets[1].assetID, additive: true)
        await model.selectAsset(assets[2].assetID, additive: true)
        await model.applyReviewDecision(action: .accept)

        XCTAssertEqual(service.mutateTagCallCount, 1)
        XCTAssertTrue(model.canUndoReviewMutation)
        await model.undoLastReviewMutation()
        XCTAssertEqual(
            try service.selectionAggregate(tagIDs: [tag.id], assetIDs: assets.map(\.assetID)).first?.unknownCount,
            3
        )
    }

    func testDeferReviewSelectionDoesNotWriteToDatabase() async {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let first = Self.makeAsset(sourceID: sourceID, fileName: "first.jpg")
        let second = Self.makeAsset(sourceID: sourceID, fileName: "second.jpg")
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [first, second],
            tags: [tag]
        )
        let review = FakePersonalizationReviewPort(
            queueItems: [
                ReviewQueueItemProjection(
                    assetID: first.assetID,
                    fileName: first.fileName,
                    availability: first.availability,
                    acceptedTagCount: 0,
                    rejectedTagCount: 0
                ),
                ReviewQueueItemProjection(
                    assetID: second.assetID,
                    fileName: second.fileName,
                    availability: second.availability,
                    acceptedTagCount: 0,
                    rejectedTagCount: 0
                ),
            ]
        )
        let model = LibraryWorkspaceModel(service: service, review: review)

        await model.enterReviewQueue(tagID: tag.id, displayName: tag.displayName)
        await model.selectAsset(first.assetID)
        model.deferReviewSelection()

        XCTAssertEqual(service.mutateTagCallCount, 0)
        XCTAssertEqual(model.reviewQueueItems.map(\.assetID).last, first.assetID)
        XCTAssertEqual(model.selectedAssetIDs, [second.assetID])
    }

    func testApplyReviewDecisionIgnoredOutsideReviewQueue() async {
        let sourceID = UUID()
        let asset = Self.makeAsset(sourceID: sourceID)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [asset]
        )
        let model = LibraryWorkspaceModel(service: service, review: FakePersonalizationReviewPort())

        await model.start()
        await model.connectFolder()
        await model.selectAsset(asset.assetID)
        await model.applyReviewDecision(action: .accept)

        XCTAssertEqual(service.mutateTagCallCount, 0)
    }

    func testConfirmSuggestionEnqueueReturnsWithoutDrainingJobs() async {
        let sourceID = UUID()
        let tag = TagListItem(id: UUID(), displayName: "Family", state: .active)
        let service = FakeLibraryWorkspaceService(
            connectedSource: LibrarySourceSummary(id: sourceID, displayName: "Fixture", state: .active),
            reconciledItems: [Self.makeAsset(sourceID: sourceID)],
            tags: [tag]
        )
        let review = FakePersonalizationReviewPort(
            overviews: [
                SuggestionTagOverview(
                    id: tag.id,
                    displayName: tag.displayName,
                    acceptedSampleCount: 4,
                    rejectedSampleCount: 4,
                    pendingSuggestionCount: 0,
                    taskStatus: .ready,
                    checkedCount: 0,
                    totalCount: nil,
                    skippedCount: 0,
                    missingPositiveCount: 0,
                    missingNegativeCount: 0,
                    canGenerate: true,
                    canUpdate: false,
                    canReview: false,
                    canPause: false,
                    canResume: false,
                    canCancel: false,
                    activeJobID: nil
                ),
            ],
            blocksRunPendingJobs: true
        )
        let model = LibraryWorkspaceModel(service: service, review: review)

        await model.start()
        await model.connectFolder()
        await model.refreshReviewState()
        _ = await model.enqueueSuggestions(tagID: tag.id, mode: .generate)
        let start = ContinuousClock.now
        let confirmed = await model.confirmPendingSuggestionEnqueue()
        let elapsed = start.duration(to: .now)
        XCTAssertTrue(confirmed)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(review.enqueueCallCount, 1)
    }

    private static func makeAsset(
        sourceID: UUID,
        fileName: String = "sample.jpg",
        mediaType: String = "public.jpeg",
        availability: AssetAvailability = .available
    ) -> AssetGridItemProjection {
        AssetGridItemProjection(
            assetID: UUID(),
            sourceID: sourceID,
            sourceDisplayName: "Fixture",
            sourceState: .active,
            relativePath: fileName,
            fileName: fileName,
            mediaType: mediaType,
            mediaCreatedAtMs: 1,
            mediaModifiedAtMs: 1,
            width: 32,
            height: 32,
            availability: availability,
            contentRevision: 1,
            acceptedTagCount: 0,
            rejectedTagCount: 0
        )
    }
}

private final class FakeLibraryWorkspaceService: LibraryWorkspacePort, @unchecked Sendable {
    private let lock = NSLock()
    private let connectedSource: LibrarySourceSummary
    private let reconciledItems: [AssetGridItemProjection]
    private var storedSources: [LibrarySourceSummary] = []
    private var storedItems: [AssetGridItemProjection] = []
    private var storedReconcileRunCount = 0
    private var storedReauthorizeCallCount = 0
    private var storedDisableCallCount = 0
    private var storedMutateTagCallCount = 0
    private var storedLastFilter = AssetPageFilter()
    private var storedLastSort: AssetPageSort = .newest
    private let scanFails: Bool
    private let tagMutationFails: Bool
    private let sourceMutationFails: Bool
    private var storedTags: [TagListItem]
    private var decisions: [UUID: [UUID: TagDecisionQueryState]] = [:]

    init(
        connectedSource: LibrarySourceSummary,
        reconciledItems: [AssetGridItemProjection],
        scanFails: Bool = false,
        tags: [TagListItem] = [],
        tagMutationFails: Bool = false,
        sourceMutationFails: Bool = false
    ) {
        self.connectedSource = connectedSource
        self.reconciledItems = reconciledItems
        self.scanFails = scanFails
        self.tagMutationFails = tagMutationFails
        self.sourceMutationFails = sourceMutationFails
        storedTags = tags
    }

    var reconcileRunCount: Int {
        lock.withLock { storedReconcileRunCount }
    }

    var lastFilter: AssetPageFilter {
        lock.withLock { storedLastFilter }
    }

    var reauthorizeCallCount: Int {
        lock.withLock { storedReauthorizeCallCount }
    }

    var disableCallCount: Int {
        lock.withLock { storedDisableCallCount }
    }

    var mutateTagCallCount: Int {
        lock.withLock { storedMutateTagCallCount }
    }

    var lastSort: AssetPageSort {
        lock.withLock { storedLastSort }
    }

    func fetchSources() throws -> [LibrarySourceSummary] {
        lock.withLock { storedSources }
    }

    func connectFolder() async throws -> ConnectFolderOutcome {
        lock.withLock { storedSources = [connectedSource] }
        return .connected(sourceID: connectedSource.id)
    }

    func reauthorizeFolder(sourceID: UUID) async throws -> ReauthorizeFolderOutcome {
        if sourceMutationFails {
            throw FakeWorkspaceError.sourceActionFailed
        }
        lock.withLock {
            storedReauthorizeCallCount += 1
            storedSources = storedSources.map {
                guard $0.id == sourceID else { return $0 }
                return LibrarySourceSummary(id: $0.id, displayName: $0.displayName, state: .active)
            }
        }
        return .reauthorized(sourceID: sourceID)
    }

    func disableFolderSource(sourceID: UUID) async throws -> DisableFolderOutcome {
        if sourceMutationFails {
            throw FakeWorkspaceError.sourceActionFailed
        }
        lock.withLock {
            storedDisableCallCount += 1
            storedSources = storedSources.map {
                guard $0.id == sourceID else { return $0 }
                return LibrarySourceSummary(id: $0.id, displayName: $0.displayName, state: .disabled)
            }
        }
        return .disabled(sourceID: sourceID)
    }

    func enqueueReconcile(sourceIDs: [UUID]) throws {}

    func runPendingReconcileJobs() throws {
        if scanFails {
            throw FakeWorkspaceError.scanFailed
        }
        lock.withLock {
            storedReconcileRunCount += 1
            storedItems = reconciledItems
        }
    }

    func runPendingPersonalizationJobs() throws {}

    func fetchAssetPage(
        filter: AssetPageFilter,
        sort: AssetPageSort,
        cursor: AssetPageCursor?
    ) throws -> AssetPageResult {
        lock.withLock {
            storedLastFilter = filter
            storedLastSort = sort
            let search = filter.searchText?.lowercased()
            let filtered = storedItems.filter { item in
                if !filter.availabilities.isEmpty,
                   !filter.availabilities.contains(item.availability)
                {
                    return false
                }
                if !filter.mediaTypes.isEmpty,
                   !filter.mediaTypes.contains(item.mediaType)
                {
                    return false
                }
                guard let search, !search.isEmpty else { return true }
                return item.fileName?.lowercased().contains(search) == true
            }
            return AssetPageResult(items: filtered, nextCursor: nil)
        }
    }

    func loadThumbnail(assetID: UUID) async throws -> Data {
        Data()
    }

    func loadPreview(assetID: UUID) async throws -> Data {
        Data()
    }

    func listTags() throws -> [TagListItem] {
        lock.withLock { storedTags }
    }

    func fetchInspectorDetail(assetID: UUID) throws -> AssetInspectorDetail {
        try lock.withLock {
            guard let item = storedItems.first(where: { $0.assetID == assetID }) else {
                throw FakeWorkspaceError.notFound
            }
            return AssetInspectorDetail(
                assetID: item.assetID,
                sourceID: item.sourceID,
                sourceDisplayName: item.sourceDisplayName,
                sourceState: item.sourceState,
                relativePath: item.relativePath,
                fileName: item.fileName,
                mediaType: item.mediaType,
                mediaCreatedAtMs: item.mediaCreatedAtMs,
                mediaModifiedAtMs: item.mediaModifiedAtMs,
                width: item.width,
                height: item.height,
                availability: item.availability,
                contentRevision: item.contentRevision,
                acceptedTagCount: item.acceptedTagCount,
                rejectedTagCount: item.rejectedTagCount,
                fingerprintSizeBytes: nil,
                fingerprintModifiedAtNs: nil,
                tags: storedTags.map {
                    InspectorTagState(
                        tagID: $0.id,
                        displayName: $0.displayName,
                        tagState: $0.state,
                        decision: decisions[assetID]?[$0.id] ?? .unknown
                    )
                }
            )
        }
    }

    func selectionAggregate(tagIDs: [UUID], assetIDs: [UUID]) throws -> [TagSelectionAggregate] {
        lock.withLock {
            tagIDs.map { tagID in
                let states = assetIDs.map { decisions[$0]?[tagID] ?? .unknown }
                return TagSelectionAggregate(
                    tagID: tagID,
                    acceptedCount: states.filter { $0 == .accepted }.count,
                    rejectedCount: states.filter { $0 == .rejected }.count,
                    unknownCount: states.filter { $0 == .unknown }.count
                )
            }
        }
    }

    func mutateTag(
        tagID: UUID,
        assetIDs: [UUID],
        action: LibraryTagDecisionAction
    ) throws -> TagMutationPriorStateSnapshot {
        if tagMutationFails {
            throw FakeWorkspaceError.tagMutationFailed
        }
        return lock.withLock {
            storedMutateTagCallCount += 1
            let priorStates = assetIDs.map {
                TagMutationPriorState(assetID: $0, priorState: decisions[$0]?[tagID] ?? .unknown)
            }
            for assetID in assetIDs {
                decisions[assetID, default: [:]][tagID] = action.decision
            }
            return TagMutationPriorStateSnapshot(tagID: tagID, priorStates: priorStates)
        }
    }

    func restoreTagMutation(_ snapshot: TagMutationPriorStateSnapshot) throws {
        lock.withLock {
            for prior in snapshot.priorStates {
                decisions[prior.assetID, default: [:]][snapshot.tagID] = prior.priorState
            }
        }
    }


    func createTagAndAccept(
        rawName: String,
        assetIDs: [UUID]
    ) throws -> TagCreateAndApplyResult {
        lock.withLock {
            let tag = TagListItem(id: UUID(), displayName: rawName, state: .active)
            storedTags.append(tag)
            for assetID in assetIDs {
                decisions[assetID, default: [:]][tag.id] = .accepted
            }
            return TagCreateAndApplyResult(
                tagID: tag.id,
                displayName: rawName,
                normalizedName: rawName.lowercased(),
                priorStates: assetIDs.map { TagMutationPriorState(assetID: $0, priorState: .unknown) }
            )
        }
    }

    func renameTag(tagID: UUID, rawName: String) throws -> TagListItem {
        if tagMutationFails {
            throw FakeWorkspaceError.tagMutationFailed
        }
        return try lock.withLock {
            guard let index = storedTags.firstIndex(where: { $0.id == tagID }) else {
                throw FakeWorkspaceError.notFound
            }
            let renamed = TagListItem(id: tagID, displayName: rawName, state: .active)
            storedTags[index] = renamed
            return renamed
        }
    }

    func archiveTag(tagID: UUID) throws {
        if tagMutationFails {
            throw FakeWorkspaceError.tagMutationFailed
        }
        lock.withLock {
            storedTags.removeAll { $0.id == tagID }
        }
    }
}

private enum FakeWorkspaceError: Error {
    case scanFailed
    case notFound
    case tagMutationFailed
    case sourceActionFailed
}

private final class FakePersonalizationReviewPort: PersonalizationReviewPort, @unchecked Sendable {
    private let lock = NSLock()
    private var storedOverviews: [SuggestionTagOverview]
    private var storedQueueItems: [ReviewQueueItemProjection]
    let blocksRunPendingJobs: Bool
    private(set) var enqueueCallCount = 0
    private(set) var runPendingJobsCallCount = 0

    init(
        overviews: [SuggestionTagOverview] = [],
        queueItems: [ReviewQueueItemProjection] = [],
        blocksRunPendingJobs: Bool = false
    ) {
        storedOverviews = overviews
        storedQueueItems = queueItems
        self.blocksRunPendingJobs = blocksRunPendingJobs
    }

    func totalPendingSuggestionCount() throws -> Int {
        lock.withLock { storedQueueItems.count }
    }

    func tagOverviews() throws -> [SuggestionTagOverview] {
        lock.withLock { storedOverviews }
    }

    func fetchReviewQueue(tagID: UUID, cursor: ReviewQueueCursor?, limit: Int) throws -> ReviewQueuePage {
        lock.withLock {
            ReviewQueuePage(items: Array(storedQueueItems.prefix(limit)), nextCursor: nil)
        }
    }

    func pendingSuggestionsForAsset(assetID: UUID) throws -> [AssetPendingSuggestion] { [] }

    func enqueueFullLibrarySuggestions(tagID: UUID, mode: PersonalizationReviewEnqueueMode) throws -> UUID {
        lock.withLock { enqueueCallCount += 1 }
        return UUID()
    }

    func pauseSuggestionJob(jobID: UUID) throws {}
    func resumeSuggestionJob(jobID: UUID) throws {}
    func cancelSuggestionJob(jobID: UUID) throws {}

    func runPendingSuggestionJobs(maxSteps: Int?) throws -> Bool {
        lock.withLock { runPendingJobsCallCount += 1 }
        if blocksRunPendingJobs {
            Thread.sleep(forTimeInterval: 5)
        }
        return false
    }
}
