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

        do {
            try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: liveDatabaseURL, fileManager: fileManager)
        } catch {
            throw CatalogSnapshotError.replacementPreconditionNotMet
        }

        var workDirectoryCreated = false
        var replacementInvoked = false
        do {
            if fileManager.fileExists(atPath: workDirectoryURL.path) {
                throw CatalogSnapshotError.candidatePreparationFailed
            }

            do {
                try fileManager.createDirectory(at: workDirectoryURL, withIntermediateDirectories: true)
            } catch {
                throw CatalogSnapshotError.candidatePreparationFailed
            }
            workDirectoryCreated = true

            do {
                try fileManager.copyItem(at: snapshotDatabaseURL, to: workDatabaseURL)
            } catch {
                throw CatalogSnapshotError.candidatePreparationFailed
            }

            let needsMigration = descriptor.manifest.appliedMigrations != CatalogMigrationID.knownOrdered
            try CatalogDatabase.prepareWorkCopyForReplacement(
                at: workDatabaseURL,
                expectedManifestMigrations: descriptor.manifest.appliedMigrations,
                runMigration: needsMigration
            )

            do {
                guard try dependencies.sameVolumeChecker(workDatabaseURL, liveDatabaseURL) else {
                    throw CatalogSnapshotError.differentVolume
                }
            } catch let error as CatalogSnapshotError {
                throw error
            } catch {
                throw CatalogSnapshotError.differentVolume
            }

            let preRestoreBackupName = "ImageAll.sqlite.pre-restore-\(operationIDString)"
            let fileReplacer = dependencies.fileReplacer

            replacementInvoked = true
            let resultingURL: URL
            do {
                resultingURL = try fileReplacer.replaceItem(
                    at: liveDatabaseURL,
                    withItemAt: workDatabaseURL,
                    backupItemName: preRestoreBackupName,
                    options: [.withoutDeletingBackupItem]
                )
            } catch let error as CatalogSnapshotError {
                throw error
            } catch {
                throw CatalogSnapshotError.initialReplacementFailed
            }

            let preRestoreBackupItemURL = liveDatabaseDirectoryURL.appendingPathComponent(preRestoreBackupName)
            do {
                try verifyRetainedBackupItem(at: preRestoreBackupItemURL, fileManager: fileManager)
            } catch {
                throw CatalogSnapshotError.manualInterventionRequired
            }

            do {
                try dependencies.postReplaceValidator.validateDatabase(at: resultingURL)
                try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: resultingURL, fileManager: fileManager)
            } catch let error as CatalogSnapshotError where error == .closeFailed {
                throw CatalogSnapshotError.manualInterventionRequired
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
                } catch let rollbackError as CatalogSnapshotError
                    where rollbackError == .manualInterventionRequired {
                    throw rollbackError
                } catch let rollbackError as CatalogSnapshotError
                    where rollbackError == .rollbackReplacementFailed {
                    throw CatalogSnapshotError.manualInterventionRequired
                } catch let rollbackError as CatalogSnapshotError
                    where rollbackError == .postReplaceValidationFailedWithSuccessfulRollback {
                    throw rollbackError
                }
            }

            if fileManager.fileExists(atPath: workDirectoryURL.path) {
                try? fileManager.removeItem(at: workDirectoryURL)
            }

            return CatalogDatabaseRestoreSuccess(
                restoredDatabaseURL: resultingURL,
                preRestoreBackupItemURL: preRestoreBackupItemURL
            )
        } catch {
            if !replacementInvoked, workDirectoryCreated, fileManager.fileExists(atPath: workDirectoryURL.path) {
                try? fileManager.removeItem(at: workDirectoryURL)
            }
            throw error
        }
    }

    private func verifyRetainedBackupItem(at url: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CatalogSnapshotError.manualInterventionRequired
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            throw CatalogSnapshotError.manualInterventionRequired
        }
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw CatalogSnapshotError.manualInterventionRequired
        }
    }

    private func verifyQuarantineBackupItem(at url: URL, fileManager: FileManager) throws {
        try verifyRetainedBackupItem(at: url, fileManager: fileManager)
    }

    private func performRollbackAfterPostReplaceFailure(
        liveDatabaseURL: URL,
        preRestoreBackupItemURL: URL,
        operationIDString: String,
        fileManager: FileManager,
        fileReplacer: any CatalogDatabaseFileReplacing
    ) throws -> CatalogDatabaseRestoreRollbackResult {
        let liveDatabaseDirectoryURL = liveDatabaseURL.deletingLastPathComponent()

        do {
            try CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(at: liveDatabaseURL, fileManager: fileManager)
        } catch {
            throw CatalogSnapshotError.manualInterventionRequired
        }

        let quarantineBackupName = "ImageAll.sqlite.quarantine-\(operationIDString)"

        let restoredURL: URL
        do {
            restoredURL = try fileReplacer.replaceItem(
                at: liveDatabaseURL,
                withItemAt: preRestoreBackupItemURL,
                backupItemName: quarantineBackupName,
                options: [.withoutDeletingBackupItem]
            )
        } catch {
            throw CatalogSnapshotError.rollbackReplacementFailed
        }

        let quarantineBackupItemURL = liveDatabaseDirectoryURL.appendingPathComponent(quarantineBackupName)

        do {
            try verifyQuarantineBackupItem(at: quarantineBackupItemURL, fileManager: fileManager)
            try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: restoredURL, fileManager: fileManager)
            try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: quarantineBackupItemURL, fileManager: fileManager)
        } catch {
            throw CatalogSnapshotError.manualInterventionRequired
        }

        do {
            try CatalogDatabase.withReadonlyQueue(at: restoredURL) { db in
                try CatalogDatabase.performQuickCheck(on: db)
            }
        } catch {
            // Best-effort post-rollback verification; rollback success must not be downgraded.
        }

        return CatalogDatabaseRestoreRollbackResult(
            restoredDatabaseURL: restoredURL,
            quarantineBackupItemURL: quarantineBackupItemURL
        )
    }
}
