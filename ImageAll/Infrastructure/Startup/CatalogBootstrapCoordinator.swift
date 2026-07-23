import Foundation
import GRDB

enum CatalogBlockingWorkEntry: String, Sendable {
    case pathsEnsure
    case inspect
    case prepare
    case finalOpen
    case recovery
}

enum CatalogBootstrapStageMarker: Equatable, Sendable {
    case paths
    case lock
    case inspect
    case prepare
    case finalOpen
    case recover
    case ready
}

/// NSLock serializes append/read; safe to share across bootstrap threads.
final class CatalogBootstrapCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [CatalogBootstrapStageMarker] = []

    func record(_ stage: CatalogBootstrapStageMarker) {
        lock.lock()
        defer { lock.unlock() }
        stages.append(stage)
    }

    func snapshot() -> [CatalogBootstrapStageMarker] {
        lock.lock()
        defer { lock.unlock() }
        return stages
    }
}

struct CatalogRuntime: Sendable {
    let paths: AppPaths
    let database: CatalogDatabase
    let lockToken: CatalogProcessLockToken
    let jobQueue: GRDBJobQueue

    func close() throws {
        try database.pool.close()
        lockToken.release()
    }
}

enum CatalogBootstrapResult: Sendable {
    case ready(CatalogRuntimeToken)
    case anotherInstanceRunning
    case unavailable(CatalogUnavailableReason)
}

final class CatalogRuntimeToken: Sendable {
    let runtime: CatalogRuntime

    init(runtime: CatalogRuntime) {
        self.runtime = runtime
    }

    func close() throws {
        try runtime.close()
    }
}

struct CatalogBootstrapDependencies: Sendable {
    var pathsResolver: AppPathsResolving
    var processLock: CatalogProcessLocking
    var fileReplacer: any CatalogDatabaseFileReplacing
    var postReplaceValidator: any CatalogPostReplaceValidator
    var capacityChecker: CatalogCapacityChecker
    var operationIDProvider: @Sendable () -> UUID
    var snapshotIDProvider: @Sendable () -> UUID
    var createdAtMsProvider: @Sendable () -> Int64
    var appVersionProvider: @Sendable () -> String
    var clock: JobClock
    var retryPolicy: RetryPolicy
    var callLog: CatalogBootstrapCallLog?
    var recoveryFailureHook: (@Sendable () throws -> Void)?
    var onStage: (@Sendable (CatalogStartupStage) -> Void)?
    var blockingWorkProbe: (@Sendable (CatalogBlockingWorkEntry) -> Void)?
    var openCurrentSchema: @Sendable (URL) throws -> CatalogDatabase
    var createCandidateDatabase: @Sendable (URL) throws -> Void
    var snapshotFailureHook: (@Sendable () throws -> Void)?
    var checkpointAndCloseFormalDatabase: @Sendable (URL) throws -> Void
    var closeDatabasePool: @Sendable (DatabasePool) throws -> Void
    var onLockReleased: (@Sendable () -> Void)?

    init(
        pathsResolver: AppPathsResolving,
        processLock: CatalogProcessLocking = DarwinCatalogProcessLock(),
        fileReplacer: any CatalogDatabaseFileReplacing = FoundationCatalogDatabaseFileReplacer(),
        postReplaceValidator: any CatalogPostReplaceValidator = DefaultCatalogPostReplaceValidator(),
        capacityChecker: CatalogCapacityChecker = CatalogCapacityChecker(),
        operationIDProvider: @escaping @Sendable () -> UUID = { UUID() },
        snapshotIDProvider: @escaping @Sendable () -> UUID = { UUID() },
        createdAtMsProvider: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        appVersionProvider: @escaping @Sendable () -> String = { "0.0.0-test" },
        clock: JobClock = SystemJobClock(),
        retryPolicy: RetryPolicy = ExponentialBackoffRetryPolicy(),
        callLog: CatalogBootstrapCallLog? = nil,
        recoveryFailureHook: (@Sendable () throws -> Void)? = nil,
        onStage: (@Sendable (CatalogStartupStage) -> Void)? = nil,
        blockingWorkProbe: (@Sendable (CatalogBlockingWorkEntry) -> Void)? = nil,
        openCurrentSchema: @escaping @Sendable (URL) throws -> CatalogDatabase = {
            try CatalogDatabase.openCurrentSchema(at: $0)
        },
        createCandidateDatabase: @escaping @Sendable (URL) throws -> Void = {
            try CatalogDatabase.createCandidateDatabase(at: $0)
        },
        snapshotFailureHook: (@Sendable () throws -> Void)? = nil,
        checkpointAndCloseFormalDatabase: @escaping @Sendable (URL) throws -> Void = { url in
            let database = try CatalogDatabase.openWithoutMigration(at: url)
            try database.checkpointAndCloseForReplacement()
        },
        closeDatabasePool: @escaping @Sendable (DatabasePool) throws -> Void = { pool in
            try pool.close()
        },
        onLockReleased: (@Sendable () -> Void)? = nil
    ) {
        self.pathsResolver = pathsResolver
        self.processLock = processLock
        self.fileReplacer = fileReplacer
        self.postReplaceValidator = postReplaceValidator
        self.capacityChecker = capacityChecker
        self.operationIDProvider = operationIDProvider
        self.snapshotIDProvider = snapshotIDProvider
        self.createdAtMsProvider = createdAtMsProvider
        self.appVersionProvider = appVersionProvider
        self.clock = clock
        self.retryPolicy = retryPolicy
        self.callLog = callLog
        self.recoveryFailureHook = recoveryFailureHook
        self.onStage = onStage
        self.blockingWorkProbe = blockingWorkProbe
        self.openCurrentSchema = openCurrentSchema
        self.createCandidateDatabase = createCandidateDatabase
        self.snapshotFailureHook = snapshotFailureHook
        self.checkpointAndCloseFormalDatabase = checkpointAndCloseFormalDatabase
        self.closeDatabasePool = closeDatabasePool
        self.onLockReleased = onLockReleased
    }
}

struct CatalogBootstrapCoordinator: Sendable {
    let dependencies: CatalogBootstrapDependencies

    func bootstrap() -> CatalogBootstrapResult {
        var lockToken: CatalogProcessLockToken?
        var openedDatabase: CatalogDatabase?
        var suppressDeferLockRelease = false

        defer {
            if openedDatabase == nil, let lockToken, !suppressDeferLockRelease {
                lockToken.release()
                dependencies.onLockReleased?()
            }
        }

        let paths: AppPaths
        do {
            paths = try dependencies.pathsResolver.resolve()
            dependencies.blockingWorkProbe?(.pathsEnsure)
            try dependencies.pathsResolver.ensureRequiredDirectories(for: paths)
            dependencies.callLog?.record(.paths)
            dependencies.onStage?(.paths)
        } catch {
            return .unavailable(.pathsFailed)
        }

        let lockResult: CatalogProcessLockAcquireResult
        do {
            lockResult = try dependencies.processLock.tryAcquire(at: paths.catalogLockFileURL)
            dependencies.callLog?.record(.lock)
            dependencies.onStage?(.lock)
        } catch {
            return .unavailable(.lockIOFailed)
        }

        switch lockResult {
        case .alreadyRunning:
            return .anotherInstanceRunning
        case let .acquired(token):
            lockToken = token
        }

        let inspection: FormalDatabaseInspection
        do {
            dependencies.blockingWorkProbe?(.inspect)
            inspection = try CatalogDatabase.inspectFormalDatabaseForStartup(
                at: paths.catalogDatabaseURL
            )
            dependencies.callLog?.record(.inspect)
            dependencies.onStage?(.catalog)
        } catch {
            return .unavailable(.finalOpenFailed)
        }

        do {
            dependencies.blockingWorkProbe?(.prepare)
            switch inspection {
            case .missing:
                try createAndPublishNewDatabase(at: paths)
            case .currentSchema:
                break
            case .knownOldPrefix:
                try migrateOldSchemaDatabase(at: paths)
            case .unsupportedSchema:
                return .unavailable(.schemaUnsupported)
            case .integrityFailed:
                return .unavailable(.integrityFailed)
            }
            dependencies.callLog?.record(.prepare)
        } catch let error as CatalogCapacityError {
            switch error {
            case let .insufficientSpace(requiredBytes):
                return .unavailable(.insufficientSpace(requiredBytes: requiredBytes))
            default:
                return mapMigrationFailure(error)
            }
        } catch let error as CatalogSnapshotError {
            return mapMigrationFailure(error)
        } catch {
            return .unavailable(.migrationFailed)
        }

        let database: CatalogDatabase
        do {
            dependencies.blockingWorkProbe?(.finalOpen)
            database = try dependencies.openCurrentSchema(paths.catalogDatabaseURL)
            openedDatabase = database
            dependencies.callLog?.record(.finalOpen)
        } catch let error as CatalogDatabaseError {
            if case .futureSchema = error {
                return .unavailable(.schemaUnsupported)
            }
            return .unavailable(.finalOpenFailed)
        } catch {
            return .unavailable(.finalOpenFailed)
        }

        let jobQueue = GRDBJobQueue(
            database: database,
            clock: dependencies.clock,
            retryPolicy: dependencies.retryPolicy
        )

        do {
            dependencies.blockingWorkProbe?(.recovery)
            dependencies.onStage?(.recovery)
            if let recoveryFailureHook = dependencies.recoveryFailureHook {
                try recoveryFailureHook()
            }
            try jobQueue.recoverInterruptedRunningJobs()
            dependencies.callLog?.record(.recover)
        } catch {
            do {
                try dependencies.closeDatabasePool(database.pool)
            } catch {
                suppressDeferLockRelease = true
                lockToken?.abandonKeepingLockHeld()
                lockToken = nil
                openedDatabase = nil
                return .unavailable(.recoveryFailed)
            }
            openedDatabase = nil
            lockToken?.release()
            dependencies.onLockReleased?()
            lockToken = nil
            return .unavailable(.recoveryFailed)
        }

        guard let lockToken else {
            return .unavailable(.lockIOFailed)
        }

        dependencies.callLog?.record(.ready)
        let runtime = CatalogRuntime(
            paths: paths,
            database: database,
            lockToken: lockToken,
            jobQueue: jobQueue
        )
        openedDatabase = database
        return .ready(CatalogRuntimeToken(runtime: runtime))
    }

    private func createAndPublishNewDatabase(at paths: AppPaths) throws {
        let fileManager = FileManager.default
        let operationID = dependencies.operationIDProvider().uuidString.lowercased()
        let candidateURL = paths.catalogDirectory.appendingPathComponent(
            "ImageAll.candidate-\(operationID).sqlite"
        )

        do {
            try dependencies.createCandidateDatabase(candidateURL)
            try CatalogDatabase.publishCandidateDatabase(
                candidateURL: candidateURL,
                formalURL: paths.catalogDatabaseURL,
                fileManager: fileManager
            )
        } catch {
            if fileManager.fileExists(atPath: candidateURL.path) {
                try? fileManager.removeItem(at: candidateURL)
            }
            throw error
        }
    }

    private func migrateOldSchemaDatabase(at paths: AppPaths) throws {
        try dependencies.capacityChecker.assertSufficientSpace(
            for: paths.catalogDatabaseURL,
            at: paths.catalogDirectory
        )

        let readonlyDatabase = try CatalogDatabase.openWithoutMigration(
            at: paths.catalogDatabaseURL,
            readonly: true
        )
        let snapshotCreator = CatalogSnapshotCreator(sourceDatabase: readonlyDatabase)
        let snapshotID = dependencies.snapshotIDProvider()
        var snapshotDependencies = CatalogSnapshotCreationDependencies()
        if let snapshotFailureHook = dependencies.snapshotFailureHook {
            snapshotDependencies.quickCheckFailureHook = { _ in try snapshotFailureHook() }
        }
        let descriptor: CatalogSnapshotDescriptor
        do {
            descriptor = try snapshotCreator.createPreMigrationSnapshot(
                snapshotID: snapshotID,
                createdAtMs: dependencies.createdAtMsProvider(),
                appVersion: dependencies.appVersionProvider(),
                backupsDirectoryURL: paths.backupsDirectory,
                dependencies: snapshotDependencies
            )
        } catch {
            try? readonlyDatabase.pool.close()
            throw error
        }
        try readonlyDatabase.pool.close()

        do {
            try dependencies.checkpointAndCloseFormalDatabase(paths.catalogDatabaseURL)
        } catch let error as CatalogSnapshotError {
            switch error {
            case .checkpointFailed, .closeFailed, .sidecarConvergenceFailed:
                throw CatalogSnapshotError.replacementPreconditionNotMet
            default:
                throw error
            }
        }

        let operationID = dependencies.operationIDProvider()
        let restoreDependencies = CatalogDatabaseRestoreDependencies(
            fileReplacer: dependencies.fileReplacer,
            postReplaceValidator: dependencies.postReplaceValidator
        )

        _ = try CatalogDatabaseRestoreCoordinator().restoreSnapshot(
            snapshotDirectoryURL: descriptor.directoryURL,
            liveDatabaseURL: paths.catalogDatabaseURL,
            operationID: operationID,
            dependencies: restoreDependencies
        )
    }

    private func mapMigrationFailure(_ error: Error) -> CatalogBootstrapResult {
        if let snapshotError = error as? CatalogSnapshotError {
            switch snapshotError {
            case .backupFailed, .integrityCheckFailed, .publicationFailed, .closeFailed:
                return .unavailable(.snapshotFailed)
            case .initialReplacementFailed, .postReplaceValidationFailed,
                 .candidatePreparationFailed, .manualInterventionRequired,
                 .postReplaceValidationFailedWithSuccessfulRollback,
                 .checkpointFailed, .sidecarConvergenceFailed, .replacementPreconditionNotMet:
                return .unavailable(.publicationFailed)
            default:
                return .unavailable(.migrationFailed)
            }
        }
        if let capacityError = error as? CatalogCapacityError {
            if case let .insufficientSpace(requiredBytes) = capacityError {
                return .unavailable(.insufficientSpace(requiredBytes: requiredBytes))
            }
        }
        return .unavailable(.migrationFailed)
    }
}

struct SystemJobClock: JobClock {
    var nowMs: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

struct ExponentialBackoffRetryPolicy: RetryPolicy {
    func nextNotBeforeMs(
        nowMs: Int64,
        attempts: Int,
        maxAttempts: Int,
        errorCode: JobSafeErrorCode
    ) -> Int64 {
        let delayMs = min(Int64(pow(2.0, Double(max(attempts - 1, 0)))) * 1000, 60_000)
        return nowMs + delayMs
    }
}

struct BundleAppVersionProvider {
    func currentVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        if let short, !short.isEmpty, let build, !build.isEmpty {
            return "\(short) (\(build))"
        }
        if let short, !short.isEmpty {
            return short
        }
        return "0.0.0"
    }
}
