import Foundation
import GRDB

struct CatalogDatabaseRestoreSuccess: Equatable, Sendable {
    let restoredDatabaseURL: URL
    let preRestoreBackupItemURL: URL
}

struct CatalogDatabaseRestoreRollbackResult: Equatable, Sendable {
    let restoredDatabaseURL: URL
    let quarantineBackupItemURL: URL
}

struct CatalogDatabaseRestoreCoordinator: Sendable {
    func restoreSnapshot(
        snapshotDirectoryURL: URL,
        liveDatabaseURL: URL,
        operationID: UUID,
        dependencies: CatalogDatabaseRestoreDependencies = .init()
    ) throws -> CatalogDatabaseRestoreSuccess {
        let fileManager = dependencies.fileManager
        let operationIDString = operationID.uuidString.lowercased()
        let effectiveDependencies = dependenciesWithFaultInjection(dependencies)

        let descriptor = try CatalogSnapshotCatalog.validatePublishedSnapshotDirectory(
            snapshotDirectoryURL,
            fileManager: fileManager
        )

        let snapshotDatabaseURL = snapshotDirectoryURL.appendingPathComponent(CatalogSnapshotConstants.databaseFilename)
        let liveDatabaseDirectoryURL = liveDatabaseURL.deletingLastPathComponent()
        let workDirectoryURL = liveDatabaseDirectoryURL.appendingPathComponent(
            ".restore-\(operationIDString).tmp",
            isDirectory: true
        )
        let workDatabaseURL = workDirectoryURL.appendingPathComponent(CatalogSnapshotConstants.databaseFilename)

        guard try effectiveDependencies.sameVolumeChecker(snapshotDatabaseURL, liveDatabaseURL) else {
            throw CatalogSnapshotError.differentVolume
        }

        try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: liveDatabaseURL, fileManager: fileManager)

        var workDirectoryCreated = false
        do {
            if fileManager.fileExists(atPath: workDirectoryURL.path) {
                throw CatalogSnapshotError.candidatePreparationFailed
            }

            try fileManager.createDirectory(at: workDirectoryURL, withIntermediateDirectories: true)
            workDirectoryCreated = true
            try fileManager.copyItem(at: snapshotDatabaseURL, to: workDatabaseURL)

            do {
                try CatalogDatabase.validateClosedDatabase(
                    at: workDatabaseURL,
                    requireCurrentSchema: descriptor.manifest.appliedMigrations == CatalogMigrationID.knownOrdered
                )
            } catch let error as CatalogDatabaseError {
                if case let .futureSchema(applied, unknown) = error {
                    throw CatalogSnapshotError.futureMigrationHistory(applied: applied, unknown: unknown)
                }
                throw CatalogSnapshotError.candidatePreparationFailed
            } catch {
                throw CatalogSnapshotError.candidatePreparationFailed
            }

            let workMigrations = try readMigrationHistory(at: workDatabaseURL)
            try CatalogSnapshotManifestValidator.validateMigrationHistoryMatchesDatabase(
                manifestMigrations: descriptor.manifest.appliedMigrations,
                databaseMigrations: workMigrations
            )

            if workMigrations != CatalogMigrationID.knownOrdered {
                try CatalogDatabase.migrateWorkCopy(at: workDatabaseURL)
            }

            try CatalogDatabase.checkpointCloseAndRequireNoSidecars(at: workDatabaseURL)

            let preRestoreBackupName = "ImageAll.sqlite.pre-restore-\(operationIDString)"
            let fileReplacer = makeFileReplacer(dependencies: effectiveDependencies)

            let resultingURL = try fileReplacer.replaceItem(
                at: liveDatabaseURL,
                withItemAt: workDatabaseURL,
                backupItemName: preRestoreBackupName,
                options: [.withoutDeletingBackupItem]
            )

            let preRestoreBackupItemURL = liveDatabaseDirectoryURL.appendingPathComponent(preRestoreBackupName)

            do {
                try effectiveDependencies.postReplaceValidator.validateDatabase(at: resultingURL)
                try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: resultingURL, fileManager: fileManager)
            } catch {
                do {
                    _ = try performRollbackAfterPostReplaceFailure(
                        liveDatabaseURL: resultingURL,
                        preRestoreBackupItemURL: preRestoreBackupItemURL,
                        operationIDString: operationIDString,
                        fileManager: fileManager,
                        fileReplacer: fileReplacer
                    )
                    throw CatalogSnapshotError.postReplaceValidationFailedWithSuccessfulRollback
                } catch let rollbackError as CatalogSnapshotError where rollbackError == .manualInterventionRequired {
                    throw rollbackError
                } catch let rollbackError as CatalogSnapshotError where rollbackError == .rollbackReplacementFailed {
                    throw CatalogSnapshotError.manualInterventionRequired
                }
            }

            try? fileManager.removeItem(at: workDirectoryURL)

            return CatalogDatabaseRestoreSuccess(
                restoredDatabaseURL: resultingURL,
                preRestoreBackupItemURL: preRestoreBackupItemURL
            )
        } catch {
            if workDirectoryCreated, fileManager.fileExists(atPath: workDirectoryURL.path) {
                try? fileManager.removeItem(at: workDirectoryURL)
            }
            throw error
        }
    }

    private func dependenciesWithFaultInjection(
        _ dependencies: CatalogDatabaseRestoreDependencies
    ) -> CatalogDatabaseRestoreDependencies {
        var effective = dependencies
        if dependencies.failPostReplaceValidation {
            effective.postReplaceValidator = FaultInjectingCatalogPostReplaceValidator(shouldFail: true)
        }
        return effective
    }

    private func makeFileReplacer(dependencies: CatalogDatabaseRestoreDependencies) -> any CatalogDatabaseFileReplacing {
        if dependencies.failInitialReplacement || dependencies.failRollbackReplacement {
            return FaultInjectingCatalogDatabaseFileReplacer(
                underlying: dependencies.fileReplacer,
                failInitialReplacement: dependencies.failInitialReplacement,
                failRollbackReplacement: dependencies.failRollbackReplacement
            )
        }
        return dependencies.fileReplacer
    }

    private func readMigrationHistory(at databaseURL: URL) throws -> [String] {
        var config = Configuration()
        let pool = try DatabasePool(path: databaseURL.path, configuration: config)
        defer {
            try? pool.close()
        }
        return try pool.read { db in
            try CatalogDatabase.readAppliedMigrationIDs(from: db)
        }
    }

    private func performRollbackAfterPostReplaceFailure(
        liveDatabaseURL: URL,
        preRestoreBackupItemURL: URL,
        operationIDString: String,
        fileManager: FileManager,
        fileReplacer: any CatalogDatabaseFileReplacing
    ) throws -> CatalogDatabaseRestoreRollbackResult {
        let liveDatabaseDirectoryURL = liveDatabaseURL.deletingLastPathComponent()

        try CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(at: liveDatabaseURL, fileManager: fileManager)

        let quarantineBackupName = "ImageAll.sqlite.quarantine-\(operationIDString)"

        do {
            let restoredURL = try fileReplacer.replaceItem(
                at: liveDatabaseURL,
                withItemAt: preRestoreBackupItemURL,
                backupItemName: quarantineBackupName,
                options: [.withoutDeletingBackupItem]
            )

            try? CatalogDatabase.validateClosedDatabase(at: restoredURL, requireCurrentSchema: false)

            return CatalogDatabaseRestoreRollbackResult(
                restoredDatabaseURL: restoredURL,
                quarantineBackupItemURL: liveDatabaseDirectoryURL.appendingPathComponent(quarantineBackupName)
            )
        } catch let error as CatalogSnapshotError where error == .rollbackReplacementFailed {
            throw CatalogSnapshotError.manualInterventionRequired
        } catch {
            throw CatalogSnapshotError.manualInterventionRequired
        }
    }
}
