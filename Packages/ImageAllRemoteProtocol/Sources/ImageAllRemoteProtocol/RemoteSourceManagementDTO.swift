import Foundation

public enum RemoteSourceManagementAction: String, Codable, Sendable, Equatable {
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

public enum RemoteSourceManagementRequestPhase: String, Codable, Sendable, Equatable {
    case awaitingMac
    case running
    case completed
    case cancelled
    case failed
}

public struct RemoteSourceManagementRequestSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let operationID: UUID
    public let action: RemoteSourceManagementAction
    public let sourceID: UUID?
    public let sourceDisplayName: String?
    public let phase: RemoteSourceManagementRequestPhase
    public let message: String
    public let completedCount: Int?
    public let totalCount: Int?
    public let warmedCount: Int?
    public let failedCount: Int?
    public let updatedAtMs: Int64

    public init(
        id: UUID,
        operationID: UUID,
        action: RemoteSourceManagementAction,
        sourceID: UUID? = nil,
        sourceDisplayName: String? = nil,
        phase: RemoteSourceManagementRequestPhase,
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

public struct RemoteSourceManagementSnapshot: Codable, Sendable, Equatable {
    public let sources: [RemoteSourceSummary]
    public let canConnectPhotos: Bool
    public let requests: [RemoteSourceManagementRequestSnapshot]

    public init(
        sources: [RemoteSourceSummary],
        canConnectPhotos: Bool,
        requests: [RemoteSourceManagementRequestSnapshot]
    ) {
        self.sources = sources
        self.canConnectPhotos = canConnectPhotos
        self.requests = requests
    }
}

public struct RemoteSourceManagementSubmitRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let action: RemoteSourceManagementAction
    public let sourceID: UUID?

    public init(
        operationID: UUID,
        action: RemoteSourceManagementAction,
        sourceID: UUID? = nil
    ) {
        self.operationID = operationID
        self.action = action
        self.sourceID = sourceID
    }
}
