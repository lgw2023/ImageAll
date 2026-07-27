import Foundation
import GRDB

protocol FolderMutationAccessing: Sendable {
    func withWritableSourceRoot<T>(
        sourceID: UUID,
        perform: (URL) throws -> T
    ) throws -> T
}

/// Resolves `source.mutation_bookmark` when present; otherwise falls back to the
/// durable read-only bookmark (sufficient for unit-test temp trees the process owns).
/// Production recycle of user folders still requires a write-capable mutation bookmark;
/// missing write capability surfaces as POSIX failures mapped by the recycle service.
struct FolderMutationAccessService: FolderMutationAccessing {
    let database: CatalogDatabase
    let bookmarkPort: any SecurityScopedBookmarkPort
    let preferMutationBookmark: Bool

    init(
        database: CatalogDatabase,
        bookmarkPort: any SecurityScopedBookmarkPort,
        preferMutationBookmark: Bool = true
    ) {
        self.database = database
        self.bookmarkPort = bookmarkPort
        self.preferMutationBookmark = preferMutationBookmark
    }

    func withWritableSourceRoot<T>(
        sourceID: UUID,
        perform: (URL) throws -> T
    ) throws -> T {
        let bookmarks = try database.pool.read { db -> (mutation: Data?, readonly: Data?) in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT mutation_bookmark, bookmark
                FROM source
                WHERE id = ? AND kind = 'folder'
                """,
                arguments: [sourceID.uuidString.lowercased()]
            )
            guard let row else {
                throw LibrarySlimmingRecycleError.notFound
            }
            return (row["mutation_bookmark"], row["bookmark"])
        }

        let chosen: Data
        if preferMutationBookmark, let mutation = bookmarks.mutation, !mutation.isEmpty {
            chosen = mutation
        } else if let readonly = bookmarks.readonly, !readonly.isEmpty {
            chosen = readonly
        } else {
            throw LibrarySlimmingRecycleError.mutationAuthorizationRequired
        }

        let resolved = try bookmarkPort.resolveBookmark(chosen)
        guard bookmarkPort.startAccessing(resolved.url) else {
            throw LibrarySlimmingRecycleError.mutationAuthorizationRequired
        }
        defer { bookmarkPort.stopAccessing(resolved.url) }
        return try perform(resolved.url)
    }
}

/// Test double that maps source IDs directly to writable temp roots.
struct DirectFolderMutationAccess: FolderMutationAccessing {
    let rootsBySourceID: [UUID: URL]

    func withWritableSourceRoot<T>(
        sourceID: UUID,
        perform: (URL) throws -> T
    ) throws -> T {
        guard let url = rootsBySourceID[sourceID] else {
            throw LibrarySlimmingRecycleError.mutationAuthorizationRequired
        }
        return try perform(url)
    }
}
