import Foundation

public enum RemoteCloudPreviewPhase: String, Codable, Sendable, Equatable {
    case downloading
    case completed
    case cancelled
    case failed
}

public struct RemoteCloudPreviewStartRequest: Codable, Sendable, Equatable {
    public let operationID: UUID

    public init(operationID: UUID) {
        self.operationID = operationID
    }
}

public struct RemoteCloudPreviewCancelRequest: Codable, Sendable, Equatable {
    public let operationID: UUID

    public init(operationID: UUID) {
        self.operationID = operationID
    }
}

public struct RemoteCloudPreviewSnapshot: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let assetID: UUID
    public let phase: RemoteCloudPreviewPhase
    public let progress: Double
    public let message: String?
    public let updatedAtMs: Int64

    public init(
        operationID: UUID,
        assetID: UUID,
        phase: RemoteCloudPreviewPhase,
        progress: Double,
        message: String? = nil,
        updatedAtMs: Int64
    ) {
        self.operationID = operationID
        self.assetID = assetID
        self.phase = phase
        self.progress = min(max(progress, 0), 1)
        self.message = message
        self.updatedAtMs = updatedAtMs
    }
}
