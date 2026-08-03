import Foundation
import GRDB

enum FolderMutationAuthorizationOutcome: Sendable, Equatable {
    case authorized(sourceID: UUID)
    case cancelled
}

@MainActor
protocol FolderMutationAuthorizationPort: Sendable {
    func authorizeMutation(sourceID: UUID) async throws -> FolderMutationAuthorizationOutcome
}

@MainActor
struct FolderMutationAuthorizationCoordinator: FolderMutationAuthorizationPort {
    let database: CatalogDatabase
    let picker: any FolderDirectoryPickerPort
    let bookmarkPort: any SecurityScopedBookmarkPort
    let rootValidator: FolderRootValidator
    let relationshipChecker: any FolderRootRelationshipChecking
    let clock: any JobClock

    func authorizeMutation(sourceID: UUID) async throws -> FolderMutationAuthorizationOutcome {
        let stored: (bookmark: Data, state: String) = try await database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT bookmark, state
                FROM source
                WHERE id = ? AND kind = 'folder'
                """,
                arguments: [sourceID.uuidString.lowercased()]
            ), let bookmark: Data = row["bookmark"]
            else {
                throw FolderAuthorizationError.sourceNotFound
            }
            return (bookmark, row["state"])
        }
        guard stored.state == SourceState.active.rawValue
            || stored.state == SourceState.disabled.rawValue
        else {
            throw FolderAuthorizationError.invalidSourceState
        }

        let resolved: BookmarkResolveResult
        do {
            resolved = try bookmarkPort.resolveBookmark(stored.bookmark)
        } catch {
            throw FolderAuthorizationError.identityIndeterminate
        }
        guard bookmarkPort.startAccessing(resolved.url) else {
            throw FolderAuthorizationError.identityIndeterminate
        }
        defer { bookmarkPort.stopAccessing(resolved.url) }

        guard let selectedURL = await picker.pickDirectory(initialDirectoryURL: resolved.url) else {
            return .cancelled
        }
        defer { bookmarkPort.stopAccessing(selectedURL) }

        guard case .valid = rootValidator.validateRoot(at: selectedURL) else {
            throw FolderAuthorizationError.invalidRoot
        }

        guard relationshipChecker.relationship(
            between: selectedURL,
            and: resolved.url
        ) == .same else {
            throw FolderAuthorizationError.identityMismatch
        }

        let writableBookmark: Data
        do {
            writableBookmark = try bookmarkPort.createWritableBookmark(for: selectedURL)
        } catch {
            throw FolderAuthorizationError.bookmarkCreationFailed
        }
        guard !writableBookmark.isEmpty else {
            throw FolderAuthorizationError.bookmarkCreationFailed
        }

        do {
            try await database.pool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO source_mutation_authorization (
                        source_id, bookmark, updated_at_ms
                    )
                    SELECT id, ?, ?
                    FROM source
                    WHERE id = ?
                      AND kind = 'folder'
                      AND state IN ('active', 'disabled')
                      AND bookmark = ?
                    ON CONFLICT(source_id) DO UPDATE SET
                        bookmark = excluded.bookmark,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                    arguments: [
                        writableBookmark,
                        clock.nowMs,
                        sourceID.uuidString.lowercased(),
                        stored.bookmark,
                    ]
                )
                guard db.changesCount == 1 else {
                    throw FolderAuthorizationError.persistenceFailure
                }
            }
        } catch let error as FolderAuthorizationError {
            throw error
        } catch {
            throw FolderAuthorizationError.persistenceFailure
        }

        return .authorized(sourceID: sourceID)
    }
}

protocol FolderMutationAccessing: Sendable {
    func withWritableSourceRoot<T>(
        sourceID: UUID,
        perform: (URL) throws -> T
    ) throws -> T
}

/// Resolves only the independently granted write-capable bookmark. The durable
/// catalog bookmark is intentionally read-only and must never authorize mutation.
struct FolderMutationAccessService: FolderMutationAccessing {
    let database: CatalogDatabase
    let bookmarkPort: any SecurityScopedBookmarkPort

    init(
        database: CatalogDatabase,
        bookmarkPort: any SecurityScopedBookmarkPort
    ) {
        self.database = database
        self.bookmarkPort = bookmarkPort
    }

    func withWritableSourceRoot<T>(
        sourceID: UUID,
        perform: (URL) throws -> T
    ) throws -> T {
        let stored: (mutationBookmark: Data?, state: String) = try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT authorization.bookmark AS mutation_bookmark, source.state
                FROM source
                LEFT JOIN source_mutation_authorization AS authorization
                    ON authorization.source_id = source.id
                WHERE source.id = ? AND source.kind = 'folder'
                """,
                arguments: [sourceID.uuidString.lowercased()]
            ) else {
                throw LibrarySlimmingRecycleError.notFound
            }
            return (row["mutation_bookmark"], row["state"])
        }

        // Disabled sources cannot start a new recycle operation (the recycle
        // insert independently requires an active source), but an explicit
        // restore must remain possible so its real quarantine blockers can be
        // resolved before the source is deleted from ImageAll.
        guard stored.state == SourceState.active.rawValue
            || stored.state == SourceState.disabled.rawValue
        else {
            throw LibrarySlimmingRecycleError.invalidState
        }
        guard let mutationBookmark = stored.mutationBookmark, !mutationBookmark.isEmpty else {
            throw LibrarySlimmingRecycleError.mutationAuthorizationRequired
        }

        let resolved: BookmarkResolveResult
        do {
            resolved = try bookmarkPort.resolveBookmark(mutationBookmark)
        } catch {
            throw LibrarySlimmingRecycleError.mutationAuthorizationInvalid
        }
        guard bookmarkPort.startAccessing(resolved.url) else {
            throw LibrarySlimmingRecycleError.mutationAuthorizationInvalid
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
