import Foundation
import XCTest
@testable import ImageAll

final class RemoteStorageMaintenanceCommandServiceTests: XCTestCase {
    func testSnapshotRedactsStoragePathsAndReportsUsage() async throws {
        let workspace = RemoteStorageMaintenanceWorkspaceStub()
        workspace.location = AppStorageLocationStatus(
            applicationSupportDirectoryURL: URL(fileURLWithPath: "/private/secret/Application Support/ImageAll"),
            cachesDirectoryURL: URL(fileURLWithPath: "/private/secret/Caches/ImageAll"),
            preferredExternalRootURL: URL(fileURLWithPath: "/Volumes/Archive/ImageAll-External"),
            usesExternalStorage: false,
            requiresRestart: true
        )
        let service = RemoteStorageMaintenanceCommandService(
            workspace: workspace,
            approvalPresenter: RemoteStorageApprovalStub(approved: true),
            clock: FixedJobClock(nowMs: 123)
        )

        let snapshot = try await service.snapshot()

        XCTAssertEqual(snapshot.previewCache.entryCount, 12)
        XCTAssertEqual(snapshot.previewCache.registeredBytes, 1_500_000)
        XCTAssertEqual(snapshot.photosOriginals.entryCount, 3)
        XCTAssertEqual(snapshot.appStorage.kind, .internalStorage)
        XCTAssertTrue(snapshot.appStorage.requiresRestart)
        XCTAssertEqual(snapshot.appStorage.pendingExternalRootName, "ImageAll-External")
    }

    func testClearPreviewRequiresApprovalCompletesAndReplaysIdempotently() async throws {
        let workspace = RemoteStorageMaintenanceWorkspaceStub()
        let approval = RemoteStorageApprovalStub(approved: true)
        let service = RemoteStorageMaintenanceCommandService(
            workspace: workspace,
            approvalPresenter: approval,
            clock: FixedJobClock(nowMs: 456)
        )
        let command = StorageMaintenanceCommandRequest(
            operationID: UUID(),
            action: .clearPreviewCache
        )

        let accepted = try await service.submit(command)
        XCTAssertEqual(accepted.phase, .awaitingMac)
        let completed = try await waitForTerminalRequest(service, id: accepted.id)
        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.result?.affectedEntryCount, 12)
        XCTAssertEqual(completed.result?.affectedBytes, 1_250_000)
        XCTAssertEqual(approval.lastApproval, .clearPreviewCache)
        XCTAssertEqual(workspace.clearPreviewCallCount, 1)

        let replay = try await service.submit(command)
        XCTAssertEqual(replay, completed)
        XCTAssertEqual(workspace.clearPreviewCallCount, 1)
    }

    func testExternalStoragePickerCancellationIsReportedAsCancelled() async throws {
        let service = RemoteStorageMaintenanceCommandService(
            workspace: RemoteStorageMaintenanceWorkspaceStub(),
            approvalPresenter: RemoteStorageApprovalStub(approved: true),
            clock: FixedJobClock(nowMs: 789)
        )

        let accepted = try await service.submit(StorageMaintenanceCommandRequest(
            operationID: UUID(),
            action: .chooseExternalStorage
        ))
        let terminal = try await waitForTerminalRequest(service, id: accepted.id)

        XCTAssertEqual(terminal.phase, .cancelled)
        XCTAssertEqual(terminal.message, "已在 Mac 上取消选择外置存储")
    }

    private func waitForTerminalRequest(
        _ service: RemoteStorageMaintenanceCommandService,
        id: UUID
    ) async throws -> StorageMaintenanceCommandRequestSnapshot {
        for _ in 0..<100 {
            let snapshot = try await service.snapshot()
            if let request = snapshot.requests.first(where: { $0.id == id }),
               ![.awaitingMac, .running].contains(request.phase) {
                return request
            }
            await Task.yield()
        }
        let finalSnapshot = try await service.snapshot()
        return try XCTUnwrap(finalSnapshot.requests.first(where: { $0.id == id }))
    }
}

private final class RemoteStorageMaintenanceWorkspaceStub:
    RemoteStorageMaintenanceWorkspacePort,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedClearPreviewCallCount = 0
    var location = AppStorageLocationStatus(
        applicationSupportDirectoryURL: URL(fileURLWithPath: "/tmp/ImageAll/Application Support"),
        cachesDirectoryURL: URL(fileURLWithPath: "/tmp/ImageAll/Caches"),
        preferredExternalRootURL: nil,
        usesExternalStorage: false,
        requiresRestart: false
    )

    var clearPreviewCallCount: Int {
        lock.withLock { storedClearPreviewCallCount }
    }

    @MainActor
    func choosePortableExportDirectory() -> URL? {
        nil
    }

    func exportPortableUserData(to parentDirectoryURL: URL) throws -> PortableCatalogExportResult {
        PortableCatalogExportResult(
            bundleURL: parentDirectoryURL.appendingPathComponent("ImageAll-Export-Test"),
            totalRecordCount: 42
        )
    }

    func fetchPreviewCacheUsage() throws -> DerivedImageCacheUsage {
        DerivedImageCacheUsage(entryCount: 12, registeredBytes: 1_500_000)
    }

    func clearPreviewCache() async throws -> DerivedImageCacheClearResult {
        lock.withLock { storedClearPreviewCallCount += 1 }
        return DerivedImageCacheClearResult(
            removedEntries: 12,
            registeredBytesInvalidated: 1_500_000,
            removedObjects: 10,
            removedBytes: 1_250_000,
            partialReclaim: false
        )
    }

    func fetchPhotosOriginalStorageUsage() throws -> PhotosOriginalStorageUsage {
        PhotosOriginalStorageUsage(entryCount: 3, registeredBytes: 9_000_000)
    }

    func clearPhotosOriginalStorage() throws -> PhotosOriginalStorageClearResult {
        PhotosOriginalStorageClearResult(
            removedEntries: 3,
            removedBytes: 9_000_000,
            partialReclaim: false
        )
    }

    func fetchAppStorageLocation() -> AppStorageLocationStatus {
        location
    }

    @MainActor
    func chooseExternalAppStorageLocation() async throws -> AppStorageLocationSelectionResult {
        .cancelled
    }
}

private final class RemoteStorageApprovalStub:
    RemoteStorageNativeApprovalPresenting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let approved: Bool
    private var storedLastApproval: RemoteStorageNativeApproval?

    init(approved: Bool) {
        self.approved = approved
    }

    var lastApproval: RemoteStorageNativeApproval? {
        lock.withLock { storedLastApproval }
    }

    @MainActor
    func confirm(_ approval: RemoteStorageNativeApproval) -> Bool {
        lock.withLock { storedLastApproval = approval }
        return approved
    }
}
