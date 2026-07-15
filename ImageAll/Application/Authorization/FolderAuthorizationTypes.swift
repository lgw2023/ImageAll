import Foundation

enum ConnectFolderOutcome: Sendable, Equatable {
    case cancelled
    case connected(sourceID: UUID)
}

enum ReauthorizeFolderOutcome: Sendable, Equatable {
    case cancelled
    case reauthorized(sourceID: UUID)
}

enum DisableFolderOutcome: Sendable, Equatable {
    case disabled(sourceID: UUID)
}
