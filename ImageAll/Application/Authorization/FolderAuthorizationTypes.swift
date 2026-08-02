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

struct DeleteLibrarySourceOutcome: Sendable, Equatable {
    let sourceID: UUID
    let deletedAssetCount: Int
}

enum DeleteLibrarySourceError: Error, Sendable, Equatable {
    case sourceNotFound
    case unresolvedRecycleEntries(count: Int)
    case cacheCleanupFailed
    case persistenceFailure
}
