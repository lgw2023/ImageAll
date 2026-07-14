import Foundation
import GRDB
import XCTest
@testable import ImageAll

enum StartupTestSupport {
    static let appVersion = "0.6.0-test"
    static let createdAtMs: Int64 = 1_750_100_000_000

    static func makeTempRoot(testCase: XCTestCase) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAllStartupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    static func makePathsResolver(root: URL) -> TemporaryAppPathsResolver {
        TemporaryAppPathsResolver(rootURL: root)
    }

    static func makeDependencies(
        root: URL,
        callLog: CatalogBootstrapCallLog? = nil,
        processLock: CatalogProcessLocking? = nil,
        capacityProvider: CatalogCapacityProviding? = nil,
        fileReplacer: (any CatalogDatabaseFileReplacing)? = nil,
        postReplaceValidator: (any CatalogPostReplaceValidator)? = nil,
        recoveryFailureHook: (@Sendable () throws -> Void)? = nil,
        snapshotFailureHook: (@Sendable () throws -> Void)? = nil,
        checkpointAndCloseFormalDatabase: (@Sendable (URL) throws -> Void)? = nil,
        closeDatabasePool: (@Sendable (DatabasePool) throws -> Void)? = nil,
        onLockReleased: (@Sendable () -> Void)? = nil,
        blockingWorkProbe: (@Sendable (CatalogBlockingWorkEntry) -> Void)? = nil,
        openCurrentSchema: (@Sendable (URL) throws -> CatalogDatabase)? = nil,
        createCandidateDatabase: (@Sendable (URL) throws -> Void)? = nil,
        operationID: UUID = UUID()
    ) -> CatalogBootstrapDependencies {
        var capacityChecker = CatalogCapacityChecker()
        if let capacityProvider {
            capacityChecker = CatalogCapacityChecker(provider: capacityProvider)
        }

        return CatalogBootstrapDependencies(
            pathsResolver: makePathsResolver(root: root),
            processLock: processLock ?? DarwinCatalogProcessLock(),
            fileReplacer: fileReplacer ?? FoundationCatalogDatabaseFileReplacer(),
            postReplaceValidator: postReplaceValidator ?? DefaultCatalogPostReplaceValidator(),
            capacityChecker: capacityChecker,
            operationIDProvider: { operationID },
            snapshotIDProvider: { UUID() },
            createdAtMsProvider: { createdAtMs },
            appVersionProvider: { appVersion },
            clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs),
            retryPolicy: FixedDelayRetryPolicy(delayMs: JobTestSupport.retryDelayMs),
            callLog: callLog,
            recoveryFailureHook: recoveryFailureHook,
            blockingWorkProbe: blockingWorkProbe,
            openCurrentSchema: openCurrentSchema ?? { try CatalogDatabase.openCurrentSchema(at: $0) },
            createCandidateDatabase: createCandidateDatabase ?? { try CatalogDatabase.createCandidateDatabase(at: $0) },
            snapshotFailureHook: snapshotFailureHook,
            checkpointAndCloseFormalDatabase: checkpointAndCloseFormalDatabase ?? { url in
                let database = try CatalogDatabase.openWithoutMigration(at: url)
                try database.checkpointAndCloseForReplacement()
            },
            closeDatabasePool: closeDatabasePool ?? { try $0.close() },
            onLockReleased: onLockReleased
        )
    }

    static func resolvedPaths(root: URL) throws -> AppPaths {
        try makePathsResolver(root: root).resolve()
    }

    static func seedCurrentSchemaDatabase(at url: URL) throws -> CatalogDatabase {
        try SnapshotTestSupport.openLiveDatabase(at: url)
    }

    static func seedEmptySQLite(at url: URL) throws {
        try SnapshotTestSupport.createEmptySQLite(at: url)
    }

    static func seedLegacyDatabaseWithSentinel(at url: URL) throws {
        try LegacyStartupTestSupport.seedLegacyDatabaseWithSentinel(at: url)
    }

    static func seedLegacyDatabaseWithMigrationConflict(at url: URL) throws {
        try LegacyStartupTestSupport.seedLegacyDatabaseWithMigrationConflict(at: url)
    }

    static func readLegacySentinelPayload(at url: URL) throws -> String? {
        try LegacyStartupTestSupport.readSentinelPayload(at: url)
    }

    static func seedFutureSchemaDatabase(at url: URL) throws {
        try seedEmptySQLite(at: url)
        var config = Configuration()
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try queue.write { db in
            try db.execute(
                sql: """
                CREATE TABLE grdb_migrations (
                    identifier TEXT PRIMARY KEY NOT NULL
                ) STRICT
                """
            )
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: ["v999_future_migration"]
            )
        }
        try queue.close()
    }

    static func seedCorruptDatabase(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-a-database".utf8).write(to: url)
    }

    static func insertInterruptedRunningJob(
        at databaseURL: URL,
        jobID: UUID = UUID(),
        controlRequest: JobControlRequest = .none
    ) throws {
        let database = try CatalogDatabase.openCurrentSchema(at: databaseURL)
        defer {
            try? database.pool.close()
        }

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO job (
                    id, kind, payload_version, payload, state, control_request, priority,
                    attempts, max_attempts, not_before_ms, lease_owner, lease_expires_at_ms,
                    progress_completed, created_at_ms, updated_at_ms
                ) VALUES (?, 'test.fake', 1, ?, 'running', ?, 0, 1, 3, ?, 'owner', ?, 0, ?, ?)
                """,
                arguments: [
                    jobID.uuidString.lowercased(),
                    Data("payload".utf8),
                    controlRequest.rawValue,
                    JobTestSupport.baseTimeMs,
                    JobTestSupport.baseTimeMs + 60_000,
                    JobTestSupport.baseTimeMs,
                    JobTestSupport.baseTimeMs,
                ]
            )
        }
    }
}

struct FixedCapacityProvider: CatalogCapacityProviding {
    let bytes: UInt64?

    func availableBytes(for url: URL) throws -> UInt64? {
        bytes
    }
}

final class FormalDatabaseOpenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

struct CountingCatalogPostReplaceValidator: CatalogPostReplaceValidator {
    let underlying: any CatalogPostReplaceValidator
    let counter: FormalDatabaseOpenCounter

    func validateDatabase(at url: URL) throws {
        counter.increment()
        try underlying.validateDatabase(at: url)
    }
}

struct BlockingProcessLock: CatalogProcessLocking {
    let underlying: CatalogProcessLocking
    let holdLockURL: URL

    func tryAcquire(at lockFileURL: URL) throws -> CatalogProcessLockAcquireResult {
        if lockFileURL == holdLockURL {
            return .alreadyRunning
        }
        return try underlying.tryAcquire(at: lockFileURL)
    }
}

struct FailingProcessLock: CatalogProcessLocking {
    func tryAcquire(at lockFileURL: URL) throws -> CatalogProcessLockAcquireResult {
        throw CatalogProcessLockError.ioFailure
    }
}

final class MainThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sawMainThread = false

    func markIfMainThread() {
        lock.lock()
        defer { lock.unlock() }
        if Thread.isMainThread {
            sawMainThread = true
        }
    }
}

enum LegacyStartupTestSupport {
    static let sentinelTable = "_startup_legacy_sentinel"
    static let sentinelFactID = "sentinel-1"
    static let sentinelPayload = "legacy-fact-v1"

    static func seedLegacyDatabaseWithSentinel(at url: URL) throws {
        try SnapshotTestSupport.createEmptySQLite(at: url)
        let queue = try DatabaseQueue(path: url.path)
        defer {
            try? queue.close()
        }
        try queue.write { db in
            try db.execute(
                sql: """
                CREATE TABLE _startup_legacy_sentinel (
                    fact_id TEXT NOT NULL PRIMARY KEY,
                    payload TEXT NOT NULL
                ) STRICT
                """
            )
            try db.execute(
                sql: """
                INSERT INTO _startup_legacy_sentinel (fact_id, payload)
                VALUES (?, ?)
                """,
                arguments: [sentinelFactID, sentinelPayload]
            )
        }
    }

    static func seedLegacyDatabaseWithMigrationConflict(at url: URL) throws {
        try seedLegacyDatabaseWithSentinel(at: url)
        let queue = try DatabaseQueue(path: url.path)
        defer {
            try? queue.close()
        }
        try queue.write { db in
            try db.execute(
                sql: """
                CREATE TABLE source (
                    id INTEGER NOT NULL PRIMARY KEY
                ) STRICT
                """
            )
        }
    }

    static func readSentinelPayload(at url: URL) throws -> String? {
        try CatalogDatabase.withReadonlyQueue(at: url) { db in
            guard try db.tableExists(sentinelTable) else {
                return nil
            }
            return try String.fetchOne(
                db,
                sql: "SELECT payload FROM _startup_legacy_sentinel WHERE fact_id = ?",
                arguments: [sentinelFactID]
            )
        }
    }
}

final class RecoveryCleanupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [String] = []

    func record(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

final class FormalCheckpointCloseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var callCount = 0

    func recordCall() {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
    }
}

final class SidecarStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var postCheckpointHasSidecars: Bool?

    func recordPostCheckpoint(hasSidecars: Bool) {
        lock.lock()
        defer { lock.unlock() }
        postCheckpointHasSidecars = hasSidecars
    }
}

final class LockReleaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var releaseCount = 0

    func recordRelease() {
        lock.lock()
        defer { lock.unlock() }
        releaseCount += 1
    }
}
