import Foundation
import GRDB
import XCTest
@testable import ImageAll

enum FolderAuthorizationTestSupport {
    static let baseTimeMs: Int64 = 1_700_000_100_000

    final class TempRootRegistry {
        private static let ownedRootPrefix = "ImageAllAuthTests-"
        private(set) var roots: [URL] = []

        func makeRoot(label: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(Self.ownedRootPrefix)\(label)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            roots.append(url)
            return url
        }

        func makeFile(label: String, extension ext: String = "txt") throws -> URL {
            let root = try makeRoot(label: "file-\(label)")
            let url = root.appendingPathComponent("fixture.\(ext)")
            guard FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)) else {
                throw NSError(domain: "FolderAuthorizationTestSupport", code: 1)
            }
            return url
        }

        func makeSymlink(to target: URL, label: String) throws -> URL {
            let root = try makeRoot(label: "link-\(label)")
            let url = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            return url
        }

        func makePackage(label: String) throws -> URL {
            let root = try makeRoot(label: "pkg-\(label)")
            let package = root.appendingPathComponent("Sample.app", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            return package
        }

        func makeFakePhotosLibrary(label: String) throws -> URL {
            let root = try makeRoot(label: "photos-\(label)")
            let library = root.appendingPathComponent("Library.photoslibrary", isDirectory: true)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            return library
        }

        func cleanup() {
            assertCleanupTargetsAreSafe()
            for root in roots.reversed() {
                try? FileManager.default.removeItem(at: root)
            }
            roots.removeAll()
        }

        func assertCleanupTargetsAreSafe(
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            let systemTemp = FileManager.default.temporaryDirectory.standardizedFileURL
            let systemTempParent = systemTemp.deletingLastPathComponent().standardizedFileURL
            let repoRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .standardizedFileURL

            let forbiddenExactRoots: [URL] = [
                URL(fileURLWithPath: "/"),
                URL(fileURLWithPath: "/tmp"),
                URL(fileURLWithPath: "/var"),
                URL(fileURLWithPath: "/Users"),
                URL(fileURLWithPath: "/Volumes"),
                systemTemp,
                systemTempParent,
                repoRoot,
            ].map(\.standardizedFileURL)

            let ownedRootUUIDPattern = try? NSRegularExpression(
                pattern: "^\(NSRegularExpression.escapedPattern(for: Self.ownedRootPrefix)).+-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
            )

            for url in roots {
                let standardized = url.standardizedFileURL
                let name = standardized.lastPathComponent
                let parent = standardized.deletingLastPathComponent().standardizedFileURL

                XCTAssertFalse(
                    forbiddenExactRoots.contains(standardized),
                    "Cleanup must never delete public or shared roots: \(standardized.path)",
                    file: file,
                    line: line
                )
                XCTAssertEqual(
                    parent,
                    systemTemp,
                    "Cleanup target parent must be the process temporaryDirectory: \(standardized.path)",
                    file: file,
                    line: line
                )
                XCTAssertTrue(
                    name.hasPrefix(Self.ownedRootPrefix),
                    "Cleanup target must use owned prefix: \(standardized.path)",
                    file: file,
                    line: line
                )
                if let ownedRootUUIDPattern {
                    let range = NSRange(name.startIndex ..< name.endIndex, in: name)
                    XCTAssertNotEqual(
                        ownedRootUUIDPattern.firstMatch(in: name, range: range),
                        nil,
                        "Cleanup target must include a unique UUID suffix: \(standardized.path)",
                        file: file,
                        line: line
                    )
                }
            }
        }
    }

    enum AuthorizationDatabaseTestFaults {
        static func installConnectJobInsertAbortTrigger(_ database: CatalogDatabase) throws {
            let kind = FolderReconcileJobFactory.kind.replacingOccurrences(of: "'", with: "''")
            try database.pool.write { db in
                try db.execute(
                    sql: """
                    CREATE TRIGGER auth_test_fail_connect_job_insert
                    BEFORE INSERT ON job
                    WHEN NEW.kind = '\(kind)'
                    BEGIN
                        SELECT RAISE(ABORT, 'CHECK constraint failed: state');
                    END
                    """
                )
            }
        }

        static func installDisableJobConvergenceAbortTrigger(_ database: CatalogDatabase) throws {
            try database.pool.write { db in
                try db.execute(
                    sql: """
                    CREATE TRIGGER auth_test_fail_disable_job_updates
                    AFTER UPDATE OF state ON source
                    WHEN NEW.state = 'disabled' AND OLD.state != 'disabled'
                    BEGIN
                        SELECT RAISE(ABORT, 'CHECK constraint failed: state');
                    END
                    """
                )
            }
        }

        static func installReauthorizeJobConvergenceAbortTrigger(_ database: CatalogDatabase) throws {
            try database.pool.write { db in
                try db.execute(
                    sql: """
                    CREATE TRIGGER auth_test_fail_reauthorize_job_updates
                    AFTER UPDATE OF state ON source
                    WHEN NEW.state = 'active'
                        AND OLD.state IN ('unavailable', 'authorizationRequired')
                    BEGIN
                        SELECT RAISE(ABORT, 'CHECK constraint failed: state');
                    END
                    """
                )
            }
        }

        static func installStaleBookmarkReplaceAbortTrigger(_ database: CatalogDatabase) throws {
            try database.pool.write { db in
                try db.execute(
                    sql: """
                    CREATE TRIGGER auth_test_fail_stale_bookmark_replace
                    BEFORE UPDATE OF bookmark ON source
                    WHEN NEW.bookmark != OLD.bookmark
                    BEGIN
                        SELECT RAISE(ABORT, 'CHECK constraint failed: state');
                    END
                    """
                )
            }
        }

        static func installSourceStateUpdateAbortTrigger(_ database: CatalogDatabase) throws {
            try database.pool.write { db in
                try db.execute(
                    sql: """
                    CREATE TRIGGER auth_test_fail_source_state_update
                    BEFORE UPDATE OF state ON source
                    WHEN NEW.state IN ('unavailable', 'authorizationRequired')
                    BEGIN
                        SELECT RAISE(ABORT, 'CHECK constraint failed: state');
                    END
                    """
                )
            }
        }
    }

    final class FakeDirectoryPicker: FolderDirectoryPickerPort, @unchecked Sendable {
        private let lock = NSLock()
        private var _configuredResponses: [URL?] = []
        private var _callCount = 0

        var configuredResponses: [URL?] {
            get {
                lock.lock()
                defer { lock.unlock() }
                return _configuredResponses
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                _configuredResponses = newValue
            }
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _callCount
        }

        func pickDirectory() -> URL? {
            lock.lock()
            defer { lock.unlock() }
            _callCount += 1
            if _configuredResponses.isEmpty {
                return nil
            }
            return _configuredResponses.removeFirst()
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
        var staleOnResolve = false
        var issueDistinctBookmarksOnCreate = false
        private var createGeneration = 0

        func register(url: URL, token: Data? = nil) -> Data {
            let bookmark = token ?? Data("bookmark-\(url.absoluteString.hashValue)".utf8)
            urlByBookmark[bookmark] = url
            createdBookmarks[url] = bookmark
            return bookmark
        }

        func createReadOnlyBookmark(for url: URL) throws -> Data {
            if createBookmarkFailure {
                throw NSError(domain: "test", code: 1)
            }
            if issueDistinctBookmarksOnCreate {
                createGeneration += 1
                let bookmark = Data("bookmark-gen-\(createGeneration)-\(url.absoluteString.hashValue)".utf8)
                urlByBookmark[bookmark] = url
                return bookmark
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
            return BookmarkResolveResult(url: url, isStale: staleOnResolve)
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
        private var underlyingStartedURL: URL?

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
                underlyingStartedURL = url
            }
            return started
        }

        func stopAccessing(_ url: URL) {
            stopCount += 1
            guard let underlyingStartedURL else {
                return
            }
            if underlyingStartedURL.standardizedFileURL == url.standardizedFileURL {
                underlying.stopAccessing(url)
                self.underlyingStartedURL = nil
            }
        }

        func resetCounters() {
            startCount = 0
            stopCount = 0
            underlyingStartedURL = nil
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

    final class IndeterminateParentRelationshipChecker: FolderRootRelationshipChecking, @unchecked Sendable {
        private let underlying: FoundationFolderRootRelationshipChecker

        init(underlying: FoundationFolderRootRelationshipChecker = FoundationFolderRootRelationshipChecker()) {
            self.underlying = underlying
        }

        var indeterminatePairs: Set<String> = []

        func relationship(between newRoot: URL, and existingRoot: URL) -> FolderRootRelationship {
            let key = "\(newRoot.path)|\(existingRoot.path)"
            if indeterminatePairs.contains(key) {
                return .indeterminate
            }
            return underlying.relationship(between: newRoot, and: existingRoot)
        }
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

    static func makeDatabase() throws -> CatalogDatabase {
        let url = try DatabaseTestSupport.makeTempDatabaseURL()
        return try CatalogDatabase.open(at: url)
    }

    static func makeCoordinator(
        database: CatalogDatabase,
        picker: FakeDirectoryPicker,
        bookmarkPort: any SecurityScopedBookmarkPort = ScopeTrackingBookmarkPort(),
        resourceReader: FixedResourceReader = FixedResourceReader(),
        relationshipChecker: any FolderRootRelationshipChecking = FoundationFolderRootRelationshipChecker(),
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

    static func insertPhotosSource(
        database: CatalogDatabase,
        sourceID: UUID,
        nowMs: Int64 = baseTimeMs
    ) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'photos', 'Library', NULL, 0, 0, 'active', ?, ?)
                """,
                arguments: [
                    sourceID.uuidString.lowercased(),
                    nowMs,
                    nowMs,
                ]
            )
        }
    }

    static func insertFolderAssetGraph(
        database: CatalogDatabase,
        sourceID: UUID,
        assetID: UUID,
        tagID: UUID,
        nowMs: Int64 = DatabaseTestSupport.timestampMs
    ) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, content_revision, availability,
                    record_created_at_ms, record_updated_at_ms
                ) VALUES (?, ?, 'file', 'photo.jpg', NULL, 'current', 'public.jpeg', 1, 'available', ?, ?)
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    sourceID.uuidString.lowercased(),
                    nowMs,
                    nowMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO file_fingerprint (asset_id, size_bytes, modified_at_ns)
                VALUES (?, 100, 200)
                """,
                arguments: [assetID.uuidString.lowercased()]
            )
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES (?, 'Trip', 'trip', 'active', ?, ?)
                """,
                arguments: [
                    tagID.uuidString.lowercased(),
                    nowMs,
                    nowMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'accepted', ?)
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    tagID.uuidString.lowercased(),
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

    static func assetGraphCounts(
        _ database: CatalogDatabase,
        sourceID: UUID
    ) throws -> (assets: Int, fingerprints: Int, tags: Int, decisions: Int) {
        try database.pool.read { db in
            let assets = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM asset WHERE source_id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            ) ?? 0
            let fingerprints = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM file_fingerprint
                WHERE asset_id IN (SELECT id FROM asset WHERE source_id = ?)
                """,
                arguments: [sourceID.uuidString.lowercased()]
            ) ?? 0
            let tags = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag") ?? 0
            let decisions = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM asset_tag_decision
                WHERE asset_id IN (SELECT id FROM asset WHERE source_id = ?)
                """,
                arguments: [sourceID.uuidString.lowercased()]
            ) ?? 0
            return (assets, fingerprints, tags, decisions)
        }
    }

    static func assertErrorDescriptionIsSanitized(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        let description = String(describing: error)
        XCTAssertFalse(description.contains("/Volumes/"), file: file, line: line)
        XCTAssertFalse(description.contains("/Users/"), file: file, line: line)
        XCTAssertFalse(description.localizedCaseInsensitiveContains("sqlite"), file: file, line: line)
        XCTAssertFalse(description.localizedCaseInsensitiveContains("bookmark"), file: file, line: line)
        XCTAssertFalse(description.localizedCaseInsensitiveContains("display name"), file: file, line: line)
    }
}
