import Foundation

public enum RemoteJobKind: String, Codable, Sendable, Equatable {
    case folderReconcile
    case photosReconcile
    case personalizationSuggestions
    case standardSuggestions
    case librarySlimmingAnalysis
    case librarySlimmingSourceIndex
    case background
    case other
}

public enum RemoteJobState: String, Codable, Sendable, Equatable {
    case pending
    case running
    case paused
    case retryableFailed
    case completed
    case terminalFailed
    case cancelled
}

public enum RemoteJobAction: String, Codable, Sendable, Equatable {
    case pause
    case resume
    case cancel
}

public enum RemoteJobControlRequest: String, Codable, Sendable, Equatable {
    case none
    case pause
    case cancel
}

public enum RemoteJobWorkspace: String, Codable, Sendable, Equatable {
    case librarySlimming
}

public struct RemoteJobNavigationTarget: Codable, Sendable, Equatable {
    public let workspace: RemoteJobWorkspace
    public let recordID: UUID
    public let mediaKind: RemoteAssetMediaKind?

    public init(
        workspace: RemoteJobWorkspace,
        recordID: UUID,
        mediaKind: RemoteAssetMediaKind? = nil
    ) {
        self.workspace = workspace
        self.recordID = recordID
        self.mediaKind = mediaKind
    }
}

public struct RemoteJobProgress: Codable, Sendable, Equatable {
    public let completedUnitCount: Int64
    public let totalUnitCount: Int64?

    public init(completedUnitCount: Int64, totalUnitCount: Int64?) {
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
    }
}

public struct RemoteJobSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceID: UUID?
    public let sourceDisplayName: String?
    public let kind: RemoteJobKind
    public let state: RemoteJobState
    public let progress: RemoteJobProgress
    public let availableActions: [RemoteJobAction]
    public let controlRequest: RemoteJobControlRequest?
    public let attempts: Int?
    public let maxAttempts: Int?
    public let lastErrorCode: String?
    public let navigationTarget: RemoteJobNavigationTarget?

    public init(
        id: UUID,
        sourceID: UUID? = nil,
        sourceDisplayName: String? = nil,
        kind: RemoteJobKind,
        state: RemoteJobState,
        progress: RemoteJobProgress,
        availableActions: [RemoteJobAction],
        controlRequest: RemoteJobControlRequest? = nil,
        attempts: Int? = nil,
        maxAttempts: Int? = nil,
        lastErrorCode: String? = nil,
        navigationTarget: RemoteJobNavigationTarget? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceDisplayName = sourceDisplayName
        self.kind = kind
        self.state = state
        self.progress = progress
        self.availableActions = availableActions
        self.controlRequest = controlRequest
        self.attempts = attempts
        self.maxAttempts = maxAttempts
        self.lastErrorCode = lastErrorCode
        self.navigationTarget = navigationTarget
    }
}

public struct RemoteJobActionRequest: Codable, Sendable, Equatable {
    public let action: RemoteJobAction

    public init(action: RemoteJobAction) {
        self.action = action
    }
}
