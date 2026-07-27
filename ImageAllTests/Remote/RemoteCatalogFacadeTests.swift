import Foundation
import ImageAllRemoteProtocol
import XCTest
@testable import ImageAll

final class RemoteCatalogFacadeTests: XCTestCase {
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
        let facade = RemoteCatalogFacade(
            catalog: catalog,
            hostAppVersion: "9.9.9",
            listenPort: 8787
        )

        let capabilities = await facade.capabilities()
        XCTAssertEqual(capabilities.protocolVersion, RemoteProtocolVersion.current)
        XCTAssertEqual(capabilities.hostAppVersion, "9.9.9")
        XCTAssertEqual(capabilities.listenPort, 8787)

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
        let facade = RemoteCatalogFacade(
            catalog: catalog,
            hostAppVersion: "1.0.0",
            listenPort: 8787
        )
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
        let facade = RemoteCatalogFacade(
            catalog: catalog,
            hostAppVersion: "1.0.0",
            listenPort: 8787
        )

        _ = try await facade.fetchAssets(RemoteAssetPageRequest(limit: 60))

        XCTAssertEqual(catalog.lastRequestedLimit, 60)
    }

    func testReusingOperationIDForDifferentMutationIsConflict() async throws {
        let catalog = RemoteCatalogServingStub()
        let facade = RemoteCatalogFacade(
            catalog: catalog,
            hostAppVersion: "1.0.0",
            listenPort: 8787
        )
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
        let facade = RemoteCatalogFacade(
            catalog: RemoteCatalogServingStub(),
            hostAppVersion: "1.0.0",
            listenPort: 8787
        )
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
}

private final class RemoteCatalogServingStub: RemoteCatalogServing, @unchecked Sendable {
    private let lock = NSLock()
    private let sources: [LibrarySourceSummary]
    private let tags: [TagListItem]
    private let items: [AssetGridItemProjection]
    private let mutateResult: TagMutationPriorStateSnapshot
    private var storedMutateCallCount = 0
    private var storedLastRequestedLimit: Int?

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

    init(
        sources: [LibrarySourceSummary] = [],
        tags: [TagListItem] = [],
        items: [AssetGridItemProjection] = [],
        mutateResult: TagMutationPriorStateSnapshot = TagMutationPriorStateSnapshot(
            tagID: UUID(),
            priorStates: []
        )
    ) {
        self.sources = sources
        self.tags = tags
        self.items = items
        self.mutateResult = mutateResult
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
}
