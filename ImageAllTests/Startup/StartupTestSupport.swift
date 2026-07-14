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
        restoreBeforeWorkCopyHook: (@Sendable () throws -> Void)? = nil,
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
            restoreBeforeWorkCopyHook: restoreBeforeWorkCopyHook
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
