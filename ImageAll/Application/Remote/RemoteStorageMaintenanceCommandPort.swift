import Foundation

enum StorageMaintenanceCommandError: Error, Equatable, Sendable {
    case unavailable
    case invalidAction
    case operationConflict
}

enum StorageMaintenanceCommandAction: String, Equatable, Sendable {
    case exportPortableData
    case chooseExternalStorage
    case clearPreviewCache
    case clearPhotosOriginals
}

enum StorageMaintenanceCommandPhase: String, Equatable, Sendable {
    case awaitingMac
    case running
    case completed
    case cancelled
    case failed
}

struct StorageMaintenanceUsageSummary: Equatable, Sendable {
    let entryCount: Int
    let registeredBytes: Int64
}

enum StorageMaintenanceAppStorageKind: String, Equatable, Sendable {
    case internalStorage
    case externalStorage
}

struct StorageMaintenanceAppStorageSummary: Equatable, Sendable {
    let kind: StorageMaintenanceAppStorageKind
    let requiresRestart: Bool
    let pendingExternalRootName: String?
}

struct StorageMaintenanceCommandResult: Equatable, Sendable {
    let affectedEntryCount: Int?
    let affectedBytes: Int64?
    let bundleName: String?
    let totalRecordCount: Int?
    let requiresRestart: Bool?
    let partialReclaim: Bool?

    init(
        affectedEntryCount: Int? = nil,
        affectedBytes: Int64? = nil,
        bundleName: String? = nil,
        totalRecordCount: Int? = nil,
        requiresRestart: Bool? = nil,
        partialReclaim: Bool? = nil
    ) {
        self.affectedEntryCount = affectedEntryCount
        self.affectedBytes = affectedBytes
        self.bundleName = bundleName
        self.totalRecordCount = totalRecordCount
        self.requiresRestart = requiresRestart
        self.partialReclaim = partialReclaim
    }
}

struct StorageMaintenanceCommandRequest: Equatable, Sendable {
    let operationID: UUID
    let action: StorageMaintenanceCommandAction
}

struct StorageMaintenanceCommandRequestSnapshot: Equatable, Sendable {
    let id: UUID
    let operationID: UUID
    let action: StorageMaintenanceCommandAction
    let phase: StorageMaintenanceCommandPhase
    let message: String
    let updatedAtMs: Int64
    let result: StorageMaintenanceCommandResult?
}

struct StorageMaintenanceCommandSnapshot: Equatable, Sendable {
    let previewCache: StorageMaintenanceUsageSummary
    let photosOriginals: StorageMaintenanceUsageSummary
    let appStorage: StorageMaintenanceAppStorageSummary
    let requests: [StorageMaintenanceCommandRequestSnapshot]
}

protocol RemoteStorageMaintenanceCommandPort: Sendable {
    func snapshot() async throws -> StorageMaintenanceCommandSnapshot
    func submit(
        _ command: StorageMaintenanceCommandRequest
    ) async throws -> StorageMaintenanceCommandRequestSnapshot
}

protocol RemoteStorageMaintenanceWorkspacePort: Sendable {
    @MainActor func choosePortableExportDirectory() -> URL?
    func exportPortableUserData(to parentDirectoryURL: URL) throws -> PortableCatalogExportResult
    func fetchPreviewCacheUsage() throws -> DerivedImageCacheUsage
    func clearPreviewCache() async throws -> DerivedImageCacheClearResult
    func fetchPhotosOriginalStorageUsage() throws -> PhotosOriginalStorageUsage
    func clearPhotosOriginalStorage() throws -> PhotosOriginalStorageClearResult
    func fetchAppStorageLocation() -> AppStorageLocationStatus
    @MainActor
    func chooseExternalAppStorageLocation() async throws -> AppStorageLocationSelectionResult
}

extension ProductionLibraryWorkspaceService: RemoteStorageMaintenanceWorkspacePort {}

enum RemoteStorageNativeApproval: Equatable, Sendable {
    case clearPreviewCache
    case clearPhotosOriginals
}

protocol RemoteStorageNativeApprovalPresenting: Sendable {
    @MainActor
    func confirm(_ approval: RemoteStorageNativeApproval) -> Bool
}
