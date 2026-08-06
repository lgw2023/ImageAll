import Foundation
import XCTest
@testable import ImageAll

final class RemoteSourceManagementCommandServiceTests: XCTestCase {
    func testSquarePrewarmReportsProgressCompletesAndReplaysOnce() async throws {
        let workspace = RemoteSourcePrewarmWorkspaceStub(assetCount: 3)
        workspace.failingAssetIDs = [workspace.assetIDs[1]]
        let service = RemoteSourceManagementCommandService(
            workspace: workspace,
            approvalPresenter: RemoteSourceApprovalStub(),
            clock: FixedJobClock(nowMs: 123)
        )
        let command = SourceManagementCommandRequest(
            operationID: UUID(),
            action: .prewarmThumbnails,
            sourceID: workspace.source.id
        )

        let accepted = try await service.submit(command)
        XCTAssertEqual(accepted.phase, .running)
        let terminal = try await waitForTerminalRequest(service, id: accepted.id)

        XCTAssertEqual(terminal.phase, .completed)
        XCTAssertEqual(terminal.completedCount, 3)
        XCTAssertEqual(terminal.totalCount, 3)
        XCTAssertEqual(terminal.warmedCount, 2)
        XCTAssertEqual(terminal.failedCount, 1)
        XCTAssertEqual(workspace.squarePrewarmAssetIDs.count, 3)

        let replay = try await service.submit(command)
        XCTAssertEqual(replay, terminal)
        XCTAssertEqual(workspace.squarePrewarmAssetIDs.count, 3)
    }

    func testOriginalAspectPrewarmSkipsCachedAssetAndCanBeCancelled() async throws {
        let workspace = RemoteSourcePrewarmWorkspaceStub(assetCount: 3)
        workspace.cachedOriginalAssetIDs = [workspace.assetIDs[0]]
        workspace.originalDelayNanoseconds = 2_000_000_000
        let service = RemoteSourceManagementCommandService(
            workspace: workspace,
            approvalPresenter: RemoteSourceApprovalStub(),
            clock: FixedJobClock(nowMs: 456)
        )
        let start = SourceManagementCommandRequest(
            operationID: UUID(),
            action: .prewarmOriginalAspect,
            sourceID: workspace.source.id
        )

        let accepted = try await service.submit(start)
        try await waitForProgress(service, id: accepted.id, total: 2)
        let cancel = SourceManagementCommandRequest(
            operationID: UUID(),
            action: .cancelPrewarm,
            sourceID: workspace.source.id
        )
        let cancelled = try await service.submit(cancel)

        XCTAssertEqual(cancelled.id, accepted.id)
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertEqual(cancelled.totalCount, 2)
        XCTAssertFalse(workspace.originalPrewarmAssetIDs.contains(workspace.assetIDs[0]))

        let replay = try await service.submit(cancel)
        XCTAssertEqual(replay.phase, .cancelled)
        XCTAssertEqual(replay.id, accepted.id)
    }

    func testPhotosWriteAuthorizationCompletesOnlyAfterMacAuthorization() async throws {
        let workspace = RemoteSourcePrewarmWorkspaceStub(assetCount: 0, kind: .photos)
        let service = RemoteSourceManagementCommandService(
            workspace: workspace,
            photosMutation: RemotePhotosMutationAuthorizationStub(state: .authorized),
            approvalPresenter: RemoteSourceApprovalStub(),
            clock: FixedJobClock(nowMs: 789)
        )
        let accepted = try await service.submit(SourceManagementCommandRequest(
            operationID: UUID(),
            action: .requestPhotosWriteAuthorization,
            sourceID: workspace.source.id
        ))

        XCTAssertEqual(accepted.phase, .awaitingMac)
        let terminal = try await waitForTerminalRequest(service, id: accepted.id)
        XCTAssertEqual(terminal.phase, .completed)
        XCTAssertTrue(terminal.message.contains("写入权限"))
    }

    func testFolderRecycleAuthorizationCancellationIsReportedWithoutMutation() async throws {
        let workspace = RemoteSourcePrewarmWorkspaceStub(assetCount: 0, kind: .folder)
        let service = RemoteSourceManagementCommandService(
            workspace: workspace,
            mutationAuthorization: RemoteFolderMutationAuthorizationStub(outcome: .cancelled),
            approvalPresenter: RemoteSourceApprovalStub(),
            clock: FixedJobClock(nowMs: 987)
        )
        let accepted = try await service.submit(SourceManagementCommandRequest(
            operationID: UUID(),
            action: .refreshFolderMutationAuthorization,
            sourceID: workspace.source.id
        ))

        XCTAssertEqual(accepted.phase, .awaitingMac)
        let terminal = try await waitForTerminalRequest(service, id: accepted.id)
        XCTAssertEqual(terminal.phase, .cancelled)
        XCTAssertTrue(terminal.message.contains("取消更新回收权限"))
    }

    private func waitForProgress(
        _ service: RemoteSourceManagementCommandService,
        id: UUID,
        total: Int
    ) async throws {
        for _ in 0..<200 {
            let request = try await service.snapshot().requests.first(where: { $0.id == id })
            if request?.totalCount == total { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for source prewarm progress")
    }

    private func waitForTerminalRequest(
        _ service: RemoteSourceManagementCommandService,
        id: UUID
    ) async throws -> SourceManagementCommandRequestSnapshot {
        for _ in 0..<200 {
            let snapshot = try await service.snapshot()
            if let request = snapshot.requests.first(where: { $0.id == id }),
               ![.awaitingMac, .running].contains(request.phase) {
                return request
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let snapshot = try await service.snapshot()
        return try XCTUnwrap(snapshot.requests.first(where: { $0.id == id }))
    }
}

private final class RemoteSourcePrewarmWorkspaceStub:
    RemoteSourceManagementWorkspacePort,
    @unchecked Sendable
{
    private let lock = NSLock()
    let source: LibrarySourceSummary
    let assetIDs: [UUID]
    var failingAssetIDs = Set<UUID>()
    var cachedOriginalAssetIDs = Set<UUID>()
    var originalDelayNanoseconds: UInt64 = 0
    private var storedSquarePrewarmAssetIDs: [UUID] = []
    private var storedOriginalPrewarmAssetIDs: [UUID] = []

    init(assetCount: Int, kind: SourceKind = .folder) {
        source = LibrarySourceSummary(
            id: UUID(),
            kind: kind,
            displayName: kind == .photos ? "Synthetic Photos" : "Synthetic Archive",
            state: .active
        )
        assetIDs = (0..<assetCount).map { _ in UUID() }
    }

    var squarePrewarmAssetIDs: [UUID] {
        lock.withLock { storedSquarePrewarmAssetIDs }
    }

    var originalPrewarmAssetIDs: [UUID] {
        lock.withLock { storedOriginalPrewarmAssetIDs }
    }

    func fetchSources() throws -> [LibrarySourceSummary] {
        [source]
    }

    func fetchAssetPage(
        filter: AssetPageFilter,
        sort _: AssetPageSort,
        cursor _: AssetPageCursor?
    ) throws -> AssetPageResult {
        XCTAssertEqual(filter.sourceIDs, [source.id])
        return AssetPageResult(
            items: assetIDs.enumerated().map { index, assetID in
                AssetGridItemProjection(
                    assetID: assetID,
                    sourceID: source.id,
                    sourceDisplayName: source.displayName,
                    sourceState: source.state,
                    relativePath: "synthetic-\(index).jpg",
                    fileName: "synthetic-\(index).jpg",
                    mediaType: "public.jpeg",
                    mediaCreatedAtMs: nil,
                    mediaModifiedAtMs: nil,
                    width: 1200,
                    height: 900,
                    availability: .available,
                    contentRevision: 1,
                    acceptedTagCount: 0,
                    rejectedTagCount: 0
                )
            },
            nextCursor: nil
        )
    }

    func loadThumbnail(assetID: UUID) async throws -> Data {
        lock.withLock { storedSquarePrewarmAssetIDs.append(assetID) }
        if failingAssetIDs.contains(assetID) {
            throw SourceManagementCommandError.unavailable
        }
        return Data([0xFF, 0xD8, 0xFF])
    }

    func cachedOriginalAspectThumbnailAssetIDs(sourceID: UUID) async throws -> Set<UUID> {
        XCTAssertEqual(sourceID, source.id)
        return cachedOriginalAssetIDs
    }

    func prewarmOriginalAspectThumbnail(assetID: UUID) async throws -> Data {
        lock.withLock { storedOriginalPrewarmAssetIDs.append(assetID) }
        if originalDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: originalDelayNanoseconds)
        }
        return Data([0xFF, 0xD8, 0xFF])
    }
}

private struct RemoteSourceApprovalStub: RemoteSourceNativeApprovalPresenting {
    @MainActor
    func confirm(_: RemoteSourceNativeApproval) -> Bool { true }
}

private struct RemoteFolderMutationAuthorizationStub: FolderMutationAuthorizationPort {
    let outcome: FolderMutationAuthorizationOutcome

    @MainActor
    func authorizeMutation(sourceID _: UUID) async throws -> FolderMutationAuthorizationOutcome {
        outcome
    }
}

private struct RemotePhotosMutationAuthorizationStub: PhotosLibraryMutationPort {
    let state: PhotosAuthorizationState

    func authorizationState() -> PhotosAuthorizationState { state }
    func requestAuthorization() async -> PhotosAuthorizationState { state }

    func moveToRecentlyDeleted(localIdentifiers _: [String]) throws -> [String] { [] }
    func presence(localIdentifier _: String) throws -> PhotosAssetPresence { .missing }
    func presences(localIdentifiers: [String]) throws -> [String: PhotosAssetPresence] {
        Dictionary(uniqueKeysWithValues: localIdentifiers.map { ($0, .missing) })
    }
}
