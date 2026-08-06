import Foundation

public enum RemoteStorageMaintenanceAction: String, Codable, Sendable, Equatable {
    case exportPortableData
    case chooseExternalStorage
    case clearPreviewCache
    case clearPhotosOriginals
}

public enum RemoteStorageMaintenanceRequestPhase: String, Codable, Sendable, Equatable {
    case awaitingMac
    case running
    case completed
    case cancelled
    case failed
}

public enum RemoteAppStorageKind: String, Codable, Sendable, Equatable {
    case internalStorage
    case externalStorage
}

public struct RemoteStorageUsageSummary: Codable, Sendable, Equatable {
    public let entryCount: Int
    public let registeredBytes: Int64

    public init(entryCount: Int, registeredBytes: Int64) {
        self.entryCount = entryCount
        self.registeredBytes = registeredBytes
    }
}

/// A deliberately redacted projection of the Mac's storage location.
/// Absolute paths never cross the remote boundary.
public struct RemoteAppStorageSummary: Codable, Sendable, Equatable {
    public let kind: RemoteAppStorageKind
    public let requiresRestart: Bool
    public let pendingExternalRootName: String?

    public init(
        kind: RemoteAppStorageKind,
        requiresRestart: Bool,
        pendingExternalRootName: String? = nil
    ) {
        self.kind = kind
        self.requiresRestart = requiresRestart
        self.pendingExternalRootName = pendingExternalRootName
    }
}

public struct RemoteStorageMaintenanceRequestResult: Codable, Sendable, Equatable {
    public let affectedEntryCount: Int?
    public let affectedBytes: Int64?
    public let bundleName: String?
    public let totalRecordCount: Int?
    public let requiresRestart: Bool?
    public let partialReclaim: Bool?

    public init(
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

public struct RemoteStorageMaintenanceRequestSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let operationID: UUID
    public let action: RemoteStorageMaintenanceAction
    public let phase: RemoteStorageMaintenanceRequestPhase
    public let message: String
    public let updatedAtMs: Int64
    public let result: RemoteStorageMaintenanceRequestResult?

    public init(
        id: UUID,
        operationID: UUID,
        action: RemoteStorageMaintenanceAction,
        phase: RemoteStorageMaintenanceRequestPhase,
        message: String,
        updatedAtMs: Int64,
        result: RemoteStorageMaintenanceRequestResult? = nil
    ) {
        self.id = id
        self.operationID = operationID
        self.action = action
        self.phase = phase
        self.message = message
        self.updatedAtMs = updatedAtMs
        self.result = result
    }
}

public struct RemoteStorageMaintenanceSnapshot: Codable, Sendable, Equatable {
    public let previewCache: RemoteStorageUsageSummary
    public let photosOriginals: RemoteStorageUsageSummary
    public let appStorage: RemoteAppStorageSummary
    public let requests: [RemoteStorageMaintenanceRequestSnapshot]

    public init(
        previewCache: RemoteStorageUsageSummary,
        photosOriginals: RemoteStorageUsageSummary,
        appStorage: RemoteAppStorageSummary,
        requests: [RemoteStorageMaintenanceRequestSnapshot]
    ) {
        self.previewCache = previewCache
        self.photosOriginals = photosOriginals
        self.appStorage = appStorage
        self.requests = requests
    }
}

public struct RemoteStorageMaintenanceSubmitRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let action: RemoteStorageMaintenanceAction

    public init(operationID: UUID, action: RemoteStorageMaintenanceAction) {
        self.operationID = operationID
        self.action = action
    }
}
