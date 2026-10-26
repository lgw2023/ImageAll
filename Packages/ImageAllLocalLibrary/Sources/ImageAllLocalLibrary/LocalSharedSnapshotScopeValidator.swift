import Foundation

/// Incremented directly on PhotoKit's callback queue, before UI refresh is scheduled.
/// This prevents queued MainActor work from keeping an obsolete visibility cache alive.
public final class LocalLibraryVisibilityGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    public init() {}
    public func invalidate() { lock.withLock { revision &+= 1 } }
    public var current: UInt64 { lock.withLock { revision } }
}

/// A transfer-local visibility lease. Identity and selection revision are always
/// checked; only the expensive complete visibility fetch is cached between chunks.
/// Callers check current authorization on every use and force a fetch at resource
/// boundaries. A Photos change during validation fails closed rather than publishing
/// a cache from an obsolete observation. No Photos or organization facts are written.
public actor LocalSharedSnapshotScopeValidator {
    private let snapshot: LocalSharedSnapshot
    private let store: LocalLibraryStore
    private let generation: LocalLibraryVisibilityGeneration
    private let visibleIdentifiers: @Sendable () async throws -> Set<String>
    private var validatedGeneration: UInt64?
    private var validatedPermission: Int?

    public init(snapshot: LocalSharedSnapshot, store: LocalLibraryStore,
                generation: LocalLibraryVisibilityGeneration,
                visibleIdentifiers: @escaping @Sendable () async throws -> Set<String>) {
        self.snapshot = snapshot
        self.store = store
        self.generation = generation
        self.visibleIdentifiers = visibleIdentifiers
    }

    public func validate(permissionVersion: Int, forceRefresh: Bool = false) async throws {
        try Task.checkCancellation()
        let revision = generation.current
        try await store.validateSharedSnapshotIdentity(snapshot)
        if forceRefresh || validatedGeneration != revision || validatedPermission != permissionVersion {
            let visible = try await visibleIdentifiers()
            try await store.validateSharedSnapshotScope(snapshot, visibleIdentifiers: visible)
            guard generation.current == revision else { throw LocalLibraryError.syncIdentityChanged }
            validatedGeneration = revision
            validatedPermission = permissionVersion
        }
        try Task.checkCancellation()
        guard generation.current == revision else { throw LocalLibraryError.syncIdentityChanged }
    }
}
