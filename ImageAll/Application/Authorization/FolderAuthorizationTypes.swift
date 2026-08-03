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

struct LibrarySourceDeletionBlockers: Sendable, Equatable {
    /// Files or Photos assets whose recoverable copy / Recently Deleted record is real.
    let recycledItemCount: Int
    /// File recycle intents rejected by the write-authorization gate before file I/O began.
    let discardableAuthorizationFailureCount: Int
    /// Pending, restoring, purging, or failed entries whose physical state is not proven safe.
    let inspectionRequiredCount: Int

    var totalCount: Int {
        recycledItemCount
            + discardableAuthorizationFailureCount
            + inspectionRequiredCount
    }
}

enum DeleteLibrarySourceError: Error, Sendable, Equatable {
    case sourceNotFound
    case unresolvedRecycleEntries(blockers: LibrarySourceDeletionBlockers)
    case cacheCleanupFailed
    case persistenceFailure
}
