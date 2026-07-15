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

    private static func makeAsset(sourceID: UUID) -> AssetGridItemProjection {
        AssetGridItemProjection(
            assetID: UUID(),
            sourceID: sourceID,
            sourceDisplayName: "Fixture",
            sourceState: .active,
            relativePath: "sample.jpg",
            fileName: "sample.jpg",
            mediaType: "public.jpeg",
            mediaCreatedAtMs: 1,
            mediaModifiedAtMs: 1,
            width: 32,
            height: 32,
            availability: .available,
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
    private let scanFails: Bool

    init(
        connectedSource: LibrarySourceSummary,
        reconciledItems: [AssetGridItemProjection],
        scanFails: Bool = false
    ) {
        self.connectedSource = connectedSource
        self.reconciledItems = reconciledItems
        self.scanFails = scanFails
    }

    var reconcileRunCount: Int {
        lock.withLock { storedReconcileRunCount }
    }

    func fetchSources() throws -> [LibrarySourceSummary] {
        lock.withLock { storedSources }
    }

    func connectFolder() async throws -> ConnectFolderOutcome {
        lock.withLock { storedSources = [connectedSource] }
        return .connected(sourceID: connectedSource.id)
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

    func fetchAssetPage(sourceID: UUID?, cursor: AssetPageCursor?) throws -> AssetPageResult {
        lock.withLock {
            AssetPageResult(items: storedItems, nextCursor: nil)
        }
    }

    func loadThumbnail(assetID: UUID) async throws -> Data {
        Data()
    }
}

private enum FakeWorkspaceError: Error {
    case scanFailed
}
