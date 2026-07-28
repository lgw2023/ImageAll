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
    public let kind: RemoteJobKind
    public let state: RemoteJobState
    public let progress: RemoteJobProgress
    public let availableActions: [RemoteJobAction]

    public init(
        id: UUID,
        kind: RemoteJobKind,
        state: RemoteJobState,
        progress: RemoteJobProgress,
        availableActions: [RemoteJobAction]
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.progress = progress
        self.availableActions = availableActions
    }
}

public struct RemoteJobActionRequest: Codable, Sendable, Equatable {
    public let action: RemoteJobAction

    public init(action: RemoteJobAction) {
        self.action = action
    }
}
