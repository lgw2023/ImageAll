import Foundation
import GRDB
import XCTest
@testable import ImageAll

enum FolderAuthorizationTestSupport {
    static let baseTimeMs: Int64 = 1_700_000_100_000

    final class TempRootRegistry {
        private var roots: [URL] = []

        func makeRoot(label: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ImageAllAuthTests-\(label)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            roots.append(url)
            return url
        }

        func cleanup() {
            for root in roots {
                try? FileManager.default.removeItem(at: root)
            }
            roots.removeAll()
        }
    }

    final class FakeDirectoryPicker: FolderDirectoryPickerPort, @unchecked Sendable {
        var configuredResponses: [URL?] = []
        private(set) var callCount = 0

        func pickDirectory() -> URL? {
            callCount += 1
            if configuredResponses.isEmpty {
                return nil
            }
            return configuredResponses.removeFirst()
        }
    }

    final class MappingBookmarkPort: SecurityScopedBookmarkPort, @unchecked Sendable {
        var urlByBookmark: [Data: URL] = [:]
        var createdBookmarks: [URL: Data] = [:]
        private(set) var startCount = 0
        private(set) var stopCount = 0
        var forceStartResult: Bool = true
        var createBookmarkFailure = false
        var resolveFailure = false

        func register(url: URL) -> Data {
            let token = Data("bookmark-\(url.path)".utf8)
            urlByBookmark[token] = url
            createdBookmarks[url] = token
            return token
        }

        func createReadOnlyBookmark(for url: URL) throws -> Data {
            if createBookmarkFailure {
                throw NSError(domain: "test", code: 1)
            }
            if let existing = createdBookmarks[url] {
                return existing
            }
            return register(url: url)
        }

        func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolveResult {
            if resolveFailure {
                throw NSError(domain: "test", code: 2)
            }
            guard let url = urlByBookmark[bookmark] else {
                throw NSError(domain: "test", code: 3)
            }
            return BookmarkResolveResult(url: url, isStale: false)
        }

        func startAccessing(_ url: URL) -> Bool {
            if forceStartResult {
                startCount += 1
                return true
            }
            return false
        }

        func stopAccessing(_ url: URL) {
            stopCount += 1
        }
    }

    final class ScopeTrackingBookmarkPort: SecurityScopedBookmarkPort, @unchecked Sendable {
        let underlying: FoundationSecurityScopedBookmarkAdapter
        private(set) var startCount = 0
        private(set) var stopCount = 0
        var forceStartResult: Bool?
        var createBookmarkFailure = false
        var resolveFailure = false
        var resolveResults: [BookmarkResolveResult] = []
        var replaceBookmarkFailureOnSourceID: UUID?

        init(underlying: FoundationSecurityScopedBookmarkAdapter = FoundationSecurityScopedBookmarkAdapter()) {
            self.underlying = underlying
        }

        func createReadOnlyBookmark(for url: URL) throws -> Data {
            if createBookmarkFailure {
                throw NSError(domain: "test", code: 1)
            }
            return try underlying.createReadOnlyBookmark(for: url)
        }

        func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolveResult {
            if resolveFailure {
                throw NSError(domain: "test", code: 2)
            }
            if !resolveResults.isEmpty {
                return resolveResults.removeFirst()
            }
            return try underlying.resolveBookmark(bookmark)
        }

        func startAccessing(_ url: URL) -> Bool {
            if let forceStartResult {
                if forceStartResult {
                    startCount += 1
                }
                return forceStartResult
            }
            let started = underlying.startAccessing(url)
            if started {
                startCount += 1
            }
            return started
        }

        func stopAccessing(_ url: URL) {
            stopCount += 1
            underlying.stopAccessing(url)
        }

        func resetCounters() {
            startCount = 0
            stopCount = 0
        }
    }

    final class FixedResourceReader: FolderRootResourceValueReading, @unchecked Sendable {
        var snapshots: [URL: FolderRootResourceSnapshot] = [:]
        var failureURLs: Set<URL> = []

        func resourceValues(for url: URL) throws -> FolderRootResourceSnapshot {
            if failureURLs.contains(url) {
                throw NSError(domain: "test", code: 3)
            }
            if let snapshot = snapshots[url] {
                return snapshot
            }
            return FolderRootResourceSnapshot(
                isDirectory: true,
                isSymbolicLink: false,
                isAliasFile: false,
                isPackage: false,
                isReadable: true,
                localizedName: url.lastPathComponent,
                pathExtension: url.pathExtension
            )
        }
    }

    final class FixedRelationshipChecker: FolderRootRelationshipChecking, @unchecked Sendable {
        var relationships: [String: FolderRootRelationship] = [:]

        func relationship(between newRoot: URL, and existingRoot: URL) -> FolderRootRelationship {
            let key = Self.key(newRoot, existingRoot)
            return relationships[key]
                ?? relationships[Self.key(existingRoot, newRoot)]
                ?? .disjoint
        }

        static func key(_ lhs: URL, _ rhs: URL) -> String {
            "\(lhs.path)|\(rhs.path)"
        }
    }

    static func makeDatabase() throws -> CatalogDatabase {
        let url = try DatabaseTestSupport.makeTempDatabaseURL()
        return try CatalogDatabase.open(at: url)
    }

    final class IDQueue: @unchecked Sendable {
        private var ids: [UUID]

        init(_ ids: [UUID]) {
            self.ids = ids
        }

        func next() -> UUID {
            if ids.isEmpty {
                return UUID()
            }
            return ids.removeFirst()
        }
    }

    static func makeCoordinator(
        database: CatalogDatabase,
        picker: FakeDirectoryPicker,
        bookmarkPort: any SecurityScopedBookmarkPort = ScopeTrackingBookmarkPort(),
        resourceReader: FixedResourceReader = FixedResourceReader(),
        relationshipChecker: any FolderRootRelationshipChecking = FixedRelationshipChecker(),
        nowMs: Int64 = baseTimeMs,
        ids: [UUID] = [UUID(), UUID(), UUID()]
    ) -> (FolderAuthorizationCoordinator, GRDBFolderSourceAuthorizationRepository, FakeDirectoryPicker, any SecurityScopedBookmarkPort) {
        let idQueue = IDQueue(ids)
        let repository = GRDBFolderSourceAuthorizationRepository(database: database)
        let coordinator = FolderAuthorizationCoordinator(
            dependencies: FolderAuthorizationDependencies(
                repository: repository,
                picker: picker,
                bookmarkPort: bookmarkPort,
                rootValidator: FolderRootValidator(resourceReader: resourceReader),
                relationshipChecker: relationshipChecker,
                clock: FixedJobClock(nowMs: nowMs),
                idGenerator: {
                    idQueue.next()
                }
            )
        )
        return (coordinator, repository, picker, bookmarkPort)
    }

    static func insertFolderSource(
        database: CatalogDatabase,
        sourceID: UUID,
        displayName: String = "Existing",
        bookmark: Data,
        state: SourceState = .active,
        nowMs: Int64 = baseTimeMs
    ) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'folder', ?, ?, 0, 0, ?, ?, ?)
                """,
                arguments: [
                    sourceID.uuidString.lowercased(),
                    displayName,
                    bookmark,
                    state.rawValue,
                    nowMs,
                    nowMs,
                ]
            )
        }
    }

    static func sourceCount(_ database: CatalogDatabase) throws -> Int {
        try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") ?? 0
        }
    }

    static func jobCount(_ database: CatalogDatabase) throws -> Int {
        try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job") ?? 0
        }
    }

    static func fetchSourceBookmark(_ database: CatalogDatabase, sourceID: UUID) throws -> Data? {
        try database.pool.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT bookmark FROM source WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            )
        }
    }

    static func fetchSourceState(_ database: CatalogDatabase, sourceID: UUID) throws -> SourceState? {
        try database.pool.read { db in
            guard let raw: String = try String.fetchOne(
                db,
                sql: "SELECT state FROM source WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            ) else {
                return nil
            }
            return SourceState(rawValue: raw)
        }
    }

    static func activeReconcileJobs(
        _ database: CatalogDatabase,
        sourceID: UUID
    ) throws -> Int {
        try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM job
                WHERE source_id = ?
                    AND kind = ?
                    AND state IN ('pending', 'running', 'paused', 'retryableFailed')
                """,
                arguments: [
                    sourceID.uuidString.lowercased(),
                    FolderReconcileJobFactory.kind,
                ]
            ) ?? 0
        }
    }

    private final class AsyncResultBox<T>: @unchecked Sendable {
        var value: T?
        var error: Error?
        var done = false
    }

    static func awaitResult<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = AsyncResultBox<T>()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                do {
                    box.value = try await body()
                } catch {
                    box.error = error
                }
                box.done = true
                group.leave()
            }
        }
        group.wait()
        if let error = box.error {
            throw error
        }
        return box.value!
    }
}
