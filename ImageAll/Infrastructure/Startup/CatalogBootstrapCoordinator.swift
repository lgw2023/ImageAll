import Foundation

enum CatalogBootstrapStageMarker: Equatable, Sendable {
    case paths
    case lock
    case inspect
    case prepare
    case finalOpen
    case recover
    case ready
}

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

struct CatalogRuntimeToken: @unchecked Sendable {
    let runtime: CatalogRuntime

    init(runtime: CatalogRuntime) {
        self.runtime = runtime
    }

    func close() throws {
        try runtime.close()
    }
}

struct CatalogBootstrapDependencies: @unchecked Sendable {
    var pathsResolver: AppPathsResolving
    var processLock: CatalogProcessLocking
    var fileManager: FileManager
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

    init(
        pathsResolver: AppPathsResolving,
        processLock: CatalogProcessLocking = DarwinCatalogProcessLock(),
        fileManager: FileManager = .default,
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
        onStage: (@Sendable (CatalogStartupStage) -> Void)? = nil
    ) {
        self.pathsResolver = pathsResolver
        self.processLock = processLock
        self.fileManager = fileManager
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
    }
}

struct CatalogBootstrapCoordinator: Sendable {
    let dependencies: CatalogBootstrapDependencies

    func bootstrap() -> CatalogBootstrapResult {
        var lockToken: CatalogProcessLockToken?
        var openedDatabase: CatalogDatabase?

        defer {
            if openedDatabase == nil, let lockToken {
                lockToken.release()
            }
        }

        let paths: AppPaths
        do {
            paths = try dependencies.pathsResolver.resolve()
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
            inspection = try CatalogDatabase.inspectFormalDatabase(
                at: paths.catalogDatabaseURL,
                fileManager: dependencies.fileManager
            )
            dependencies.callLog?.record(.inspect)
            dependencies.onStage?(.catalog)
        } catch {
            return .unavailable(.finalOpenFailed)
        }

        do {
            switch inspection {
            case .missing:
                try createAndPublishNewDatabase(at: paths)
            case .currentSchema:
                break
            case let .knownOldPrefix:
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
            database = try CatalogDatabase.openCurrentSchema(at: paths.catalogDatabaseURL)
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
            dependencies.onStage?(.recovery)
            if let recoveryFailureHook = dependencies.recoveryFailureHook {
                try recoveryFailureHook()
            }
            try jobQueue.recoverInterruptedRunningJobs()
            dependencies.callLog?.record(.recover)
        } catch {
            do {
                try database.pool.close()
            } catch {
                // Best-effort close before releasing lock.
            }
            openedDatabase = nil
            lockToken?.release()
            lockToken = nil
            return .unavailable(.recoveryFailed)
        }

        guard let lockToken else {
            return .unavailable(.lockIOFailed)
        }

        dependencies.callLog?.record(.ready)
        let runtime = CatalogRuntime(
            database: database,
            lockToken: lockToken,
            jobQueue: jobQueue
        )
        openedDatabase = database
        return .ready(CatalogRuntimeToken(runtime: runtime))
    }

    private func createAndPublishNewDatabase(at paths: AppPaths) throws {
        let operationID = dependencies.operationIDProvider().uuidString.lowercased()
        let candidateURL = paths.catalogDirectory.appendingPathComponent(
            "ImageAll.candidate-\(operationID).sqlite"
        )

        do {
            try CatalogDatabase.createCandidateDatabase(at: candidateURL)
            try CatalogDatabase.publishCandidateDatabase(
                candidateURL: candidateURL,
                formalURL: paths.catalogDatabaseURL,
                fileManager: dependencies.fileManager
            )
        } catch {
            if dependencies.fileManager.fileExists(atPath: candidateURL.path) {
                try? dependencies.fileManager.removeItem(at: candidateURL)
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
        let descriptor: CatalogSnapshotDescriptor
        do {
            descriptor = try snapshotCreator.createPreMigrationSnapshot(
                snapshotID: snapshotID,
                createdAtMs: dependencies.createdAtMsProvider(),
                appVersion: dependencies.appVersionProvider(),
                backupsDirectoryURL: paths.backupsDirectory
            )
        } catch {
            try? readonlyDatabase.pool.close()
            throw CatalogSnapshotError.backupFailed
        }
        try readonlyDatabase.pool.close()

        let operationID = dependencies.operationIDProvider()
        let operationIDString = operationID.uuidString.lowercased()
        let workDirectoryURL = paths.catalogDirectory.appendingPathComponent(
            ".migrate-\(operationIDString).tmp",
            isDirectory: true
        )
        let workDatabaseURL = workDirectoryURL.appendingPathComponent(
            CatalogSnapshotConstants.databaseFilename
        )

        var workDirectoryCreated = false
        var replacementInvoked = false
        defer {
            if !replacementInvoked, workDirectoryCreated,
               dependencies.fileManager.fileExists(atPath: workDirectoryURL.path) {
                try? dependencies.fileManager.removeItem(at: workDirectoryURL)
            }
        }

        if dependencies.fileManager.fileExists(atPath: workDirectoryURL.path) {
            throw CatalogSnapshotError.candidatePreparationFailed
        }

        try dependencies.fileManager.createDirectory(
            at: workDirectoryURL,
            withIntermediateDirectories: true
        )
        workDirectoryCreated = true

        let snapshotDatabaseURL = descriptor.directoryURL.appendingPathComponent(
            CatalogSnapshotConstants.databaseFilename
        )
        try dependencies.fileManager.copyItem(at: snapshotDatabaseURL, to: workDatabaseURL)

        let needsMigration = descriptor.manifest.appliedMigrations != CatalogMigrationID.knownOrdered
        try CatalogDatabase.prepareWorkCopyForReplacement(
            at: workDatabaseURL,
            expectedManifestMigrations: descriptor.manifest.appliedMigrations,
            runMigration: needsMigration
        )

        guard try CatalogDatabaseSidecarHelpers.isSameVolume(workDatabaseURL, paths.catalogDatabaseURL) else {
            throw CatalogSnapshotError.differentVolume
        }

        let liveDatabase = try CatalogDatabase.openWithoutMigration(at: paths.catalogDatabaseURL)
        try liveDatabase.checkpointAndCloseForReplacement()

        let backupName = "ImageAll.sqlite.pre-migration-\(operationIDString)"
        replacementInvoked = true
        let resultingURL: URL
        do {
            resultingURL = try dependencies.fileReplacer.replaceItem(
                at: paths.catalogDatabaseURL,
                withItemAt: workDatabaseURL,
                backupItemName: backupName,
                options: [.withoutDeletingBackupItem]
            )
        } catch {
            throw CatalogSnapshotError.initialReplacementFailed
        }

        do {
            try dependencies.postReplaceValidator.validateDatabase(at: resultingURL)
            try CatalogDatabaseSidecarHelpers.requireNoSidecars(
                at: resultingURL,
                fileManager: dependencies.fileManager
            )
        } catch {
            throw CatalogSnapshotError.postReplaceValidationFailed
        }

        if dependencies.fileManager.fileExists(atPath: workDirectoryURL.path) {
            try? dependencies.fileManager.removeItem(at: workDirectoryURL)
        }
    }

    private func mapMigrationFailure(_ error: Error) -> CatalogBootstrapResult {
        if let snapshotError = error as? CatalogSnapshotError {
            switch snapshotError {
            case .backupFailed, .integrityCheckFailed, .publicationFailed, .closeFailed:
                return .unavailable(.snapshotFailed)
            case .initialReplacementFailed, .postReplaceValidationFailed,
                 .candidatePreparationFailed, .manualInterventionRequired,
                 .postReplaceValidationFailedWithSuccessfulRollback:
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
