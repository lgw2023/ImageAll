import Foundation

enum SourceManagementCommandError: Error, Equatable, Sendable {
    case unavailable
    case invalidAction
    case sourceNotFound
    case operationConflict
}

enum SourceManagementCommandAction: String, Equatable, Sendable {
    case connectFolder
    case connectPhotos
    case rebindPhotos
    case reauthorize
    case rescan
    case syncPhotos
    case fullRepair
    case requestPhotosWriteAuthorization
    case refreshFolderMutationAuthorization
    case prewarmThumbnails
    case prewarmOriginalAspect
    case cancelPrewarm
    case delete
}

enum SourceManagementCommandPhase: String, Equatable, Sendable {
    case awaitingMac
    case running
    case completed
    case cancelled
    case failed
}

struct SourceManagementCommandRequest: Equatable, Sendable {
    let operationID: UUID
    let action: SourceManagementCommandAction
    let sourceID: UUID?
}

struct SourceManagementCommandRequestSnapshot: Equatable, Sendable {
    let id: UUID
    let operationID: UUID
    let action: SourceManagementCommandAction
    let sourceID: UUID?
    let sourceDisplayName: String?
    let phase: SourceManagementCommandPhase
    let message: String
    let completedCount: Int?
    let totalCount: Int?
    let warmedCount: Int?
    let failedCount: Int?
    let updatedAtMs: Int64

    init(
        id: UUID,
        operationID: UUID,
        action: SourceManagementCommandAction,
        sourceID: UUID?,
        sourceDisplayName: String?,
        phase: SourceManagementCommandPhase,
        message: String,
        completedCount: Int? = nil,
        totalCount: Int? = nil,
        warmedCount: Int? = nil,
        failedCount: Int? = nil,
        updatedAtMs: Int64
    ) {
        self.id = id
        self.operationID = operationID
        self.action = action
        self.sourceID = sourceID
        self.sourceDisplayName = sourceDisplayName
        self.phase = phase
        self.message = message
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.warmedCount = warmedCount
        self.failedCount = failedCount
        self.updatedAtMs = updatedAtMs
    }
}

struct SourceManagementCommandSnapshot: Equatable, Sendable {
    let sources: [LibrarySourceSummary]
    let requests: [SourceManagementCommandRequestSnapshot]
}

protocol RemoteSourceManagementCommandPort: Sendable {
    func snapshot() async throws -> SourceManagementCommandSnapshot
    func submit(
        _ command: SourceManagementCommandRequest
    ) async throws -> SourceManagementCommandRequestSnapshot
}

/// The Remote source workflow deliberately depends on the same catalog and
/// derived-image seams as the Mac workspace, without reaching into SwiftUI
/// state. Explicit prewarming remains read-only with respect to source media.
protocol RemoteSourceManagementWorkspacePort: Sendable {
    func fetchSources() throws -> [LibrarySourceSummary]
    func connectFolder() async throws -> ConnectFolderOutcome
    func connectPhotos() async throws -> ConnectPhotosOutcome
    func rebindPhotos(unavailableSourceID: UUID) async throws -> RebindPhotosOutcome
    func reactivatePhotosLibrary(sourceID: UUID) async throws
    func reauthorizeFolder(sourceID: UUID) async throws -> ReauthorizeFolderOutcome
    func enqueueReconcile(sourceIDs: [UUID]) throws
    func syncPhotosLibrary(sourceID: UUID) async throws
    func requestPhotosFullRepair(sourceID: UUID) async throws
    func deleteLibrarySource(sourceID: UUID) async throws -> DeleteLibrarySourceOutcome
    func runPendingReconcileJobs(sourceIDs: Set<UUID>?) throws
    func runPendingPhotosReconcileJobs(sourceIDs: Set<UUID>?) throws
    func fetchAssetPage(
        filter: AssetPageFilter,
        sort: AssetPageSort,
        cursor: AssetPageCursor?
    ) throws -> AssetPageResult
    func loadThumbnail(assetID: UUID) async throws -> Data
    func cachedOriginalAspectThumbnailAssetIDs(sourceID: UUID) async throws -> Set<UUID>
    func loadOriginalAspectThumbnailIfCached(assetID: UUID) async throws -> Data?
    func prewarmOriginalAspectThumbnail(assetID: UUID) async throws -> Data
}

extension RemoteSourceManagementWorkspacePort {
    func connectFolder() async throws -> ConnectFolderOutcome {
        throw SourceManagementCommandError.unavailable
    }

    func connectPhotos() async throws -> ConnectPhotosOutcome {
        throw SourceManagementCommandError.unavailable
    }

    func rebindPhotos(unavailableSourceID _: UUID) async throws -> RebindPhotosOutcome {
        throw SourceManagementCommandError.unavailable
    }

    func reactivatePhotosLibrary(sourceID _: UUID) async throws {
        throw SourceManagementCommandError.unavailable
    }

    func reauthorizeFolder(sourceID _: UUID) async throws -> ReauthorizeFolderOutcome {
        throw SourceManagementCommandError.unavailable
    }

    func enqueueReconcile(sourceIDs _: [UUID]) throws {
        throw SourceManagementCommandError.unavailable
    }

    func syncPhotosLibrary(sourceID _: UUID) async throws {
        throw SourceManagementCommandError.unavailable
    }

    func requestPhotosFullRepair(sourceID _: UUID) async throws {
        throw SourceManagementCommandError.unavailable
    }

    func deleteLibrarySource(sourceID _: UUID) async throws -> DeleteLibrarySourceOutcome {
        throw SourceManagementCommandError.unavailable
    }

    func runPendingReconcileJobs(sourceIDs _: Set<UUID>?) throws {}
    func runPendingPhotosReconcileJobs(sourceIDs _: Set<UUID>?) throws {}

    func fetchAssetPage(
        filter _: AssetPageFilter,
        sort _: AssetPageSort,
        cursor _: AssetPageCursor?
    ) throws -> AssetPageResult {
        throw SourceManagementCommandError.unavailable
    }

    func loadThumbnail(assetID _: UUID) async throws -> Data {
        throw SourceManagementCommandError.unavailable
    }

    func cachedOriginalAspectThumbnailAssetIDs(sourceID _: UUID) async throws -> Set<UUID> {
        []
    }

    func loadOriginalAspectThumbnailIfCached(assetID _: UUID) async throws -> Data? {
        nil
    }

    func prewarmOriginalAspectThumbnail(assetID _: UUID) async throws -> Data {
        throw SourceManagementCommandError.unavailable
    }
}

enum RemoteSourceNativeApproval: Equatable, Sendable {
    case connectPhotos
    case rebindPhotos(sourceName: String)
    case fullRepair(sourceName: String)
    case requestPhotosWriteAuthorization(sourceName: String)
    case delete(sourceName: String)
}

protocol RemoteSourceNativeApprovalPresenting: Sendable {
    @MainActor
    func confirm(_ approval: RemoteSourceNativeApproval) -> Bool
}
