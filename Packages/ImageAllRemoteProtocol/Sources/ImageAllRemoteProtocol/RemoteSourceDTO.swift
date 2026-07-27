import Foundation

public enum RemoteSourceKind: String, Codable, Sendable, Equatable {
    case folder
    case photos
}

public enum RemoteSourceState: String, Codable, Sendable, Equatable {
    case active
    case disabled
    case unavailable
    case authorizationRequired
}

public struct RemoteSourceSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: RemoteSourceKind
    public let displayName: String
    public let state: RemoteSourceState

    public init(
        id: UUID,
        kind: RemoteSourceKind,
        displayName: String,
        state: RemoteSourceState
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.state = state
    }
}
