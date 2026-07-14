import Foundation
import GRDB

struct CatalogSnapshotCreator: Sendable {
    let sourceDatabase: CatalogDatabase

    func createManualSnapshot(
        snapshotID: UUID,
        createdAtMs: Int64,
        appVersion: String,
        backupsDirectoryURL: URL,
        dependencies: CatalogSnapshotCreationDependencies = .init()
    ) throws -> CatalogSnapshotDescriptor {
        try createSnapshot(
            snapshotID: snapshotID,
            createdAtMs: createdAtMs,
            appVersion: appVersion,
            backupsDirectoryURL: backupsDirectoryURL,
            dependencies: dependencies
        )
    }

    func createPreMigrationSnapshot(
        snapshotID: UUID,
        createdAtMs: Int64,
        appVersion: String,
        backupsDirectoryURL: URL,
        dependencies: CatalogSnapshotCreationDependencies = .init()
    ) throws -> CatalogSnapshotDescriptor {
        try createSnapshot(
            snapshotID: snapshotID,
            createdAtMs: createdAtMs,
            appVersion: appVersion,
            backupsDirectoryURL: backupsDirectoryURL,
            dependencies: dependencies
        )
    }

    func createSnapshot(
        snapshotID: UUID,
        createdAtMs: Int64,
        appVersion: String,
        backupsDirectoryURL: URL,
        dependencies: CatalogSnapshotCreationDependencies = .init()
    ) throws -> CatalogSnapshotDescriptor {
        let snapshotIDString = snapshotID.uuidString.lowercased()
        guard CatalogSnapshotManifestValidator.isLowercaseCanonicalUUID(snapshotIDString) else {
            throw CatalogSnapshotError.invalidSnapshotID
        }

        guard createdAtMs >= 0 else {
            throw CatalogSnapshotError.invalidCreatedAt
        }

        guard !appVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatalogSnapshotError.invalidAppVersion
        }

        let fileManager = dependencies.fileManager
        do {
            try fileManager.createDirectory(at: backupsDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw CatalogSnapshotError.backupFailed
        }

        let tempDirectoryURL = backupsDirectoryURL.appendingPathComponent("\(snapshotIDString).tmp", isDirectory: true)
        let finalDirectoryURL = backupsDirectoryURL.appendingPathComponent(snapshotIDString, isDirectory: true)

        if fileManager.fileExists(atPath: tempDirectoryURL.path)
            || fileManager.fileExists(atPath: finalDirectoryURL.path) {
            throw CatalogSnapshotError.snapshotCollision
        }

        var tempDirectoryCreated = false
        var destinationQueueCreated = false
        var destinationClosed = false
        var destinationQueue: DatabaseQueue?
        do {
            do {
                try fileManager.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
            } catch {
                throw CatalogSnapshotError.backupFailed
            }
            tempDirectoryCreated = true
            let destinationDatabaseURL = tempDirectoryURL.appendingPathComponent(CatalogSnapshotConstants.databaseFilename)

            do {
                try dependencies.destinationQueueOpenPreparationHook?(destinationDatabaseURL)
            } catch {
                throw Self.mapOpenPreparationError(error)
            }

            var destinationConfig = Configuration()
            destinationConfig.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            let queue: DatabaseQueue
            do {
                queue = try DatabaseQueue(path: destinationDatabaseURL.path, configuration: destinationConfig)
            } catch {
                throw CatalogSnapshotError.backupFailed
            }
            destinationQueueCreated = true
            destinationQueue = queue

            do {
                try sourceDatabase.pool.backup(to: queue, pagesPerStep: dependencies.pagesPerStep) { progress in
                    do {
                        try dependencies.backupProgressHook?(progress)
                    } catch {
                        throw Self.mapBackupProgressError(error)
                    }
                }
            } catch let error as CatalogSnapshotError {
                throw Self.mapBackupOperationError(error)
            } catch {
                throw CatalogSnapshotError.backupFailed
            }

            let appliedMigrations: [String]
            do {
                do {
                    try dependencies.destinationPreCloseHook?(queue, destinationDatabaseURL)
                } catch {
                    throw Self.mapIntegritySeamError(error)
                }
                do {
                    try dependencies.quickCheckFailureHook?(queue)
                } catch {
                    throw Self.mapIntegritySeamError(error)
                }
                appliedMigrations = try queue.read { db -> [String] in
                    try CatalogDatabase.performQuickCheck(on: db)
                    let migrations = try CatalogDatabase.readAppliedMigrationIDs(from: db)
                    try CatalogSnapshotManifestValidator.validateMigrationPrefix(migrations)
                    return migrations
                }
                try CatalogDatabase.convergeToDeleteJournalOnQueue(queue, recheckQuickCheck: true)
            } catch let error as CatalogSnapshotError {
                throw error
            } catch {
                throw CatalogSnapshotError.integrityCheckFailed
            }

            do {
                try dependencies.destinationCloseFailureHook?()
            } catch {
                throw Self.mapCloseFailureHookError(error)
            }
            try CatalogDatabase.closeQueue(queue)
            destinationClosed = true
            destinationQueue = nil
            try CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(at: destinationDatabaseURL)
            try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: destinationDatabaseURL)

            let databaseBytes: Int64
            do {
                databaseBytes = try CatalogSnapshotHashing.fileSize(of: destinationDatabaseURL)
            } catch let error as CatalogSnapshotError {
                throw error
            } catch {
                throw CatalogSnapshotError.invalidDatabaseBytes
            }
            guard databaseBytes > 0 else {
                throw CatalogSnapshotError.invalidDatabaseBytes
            }

            do {
                try dependencies.hashFailureHook?()
            } catch {
                throw Self.mapHashSeamError(error)
            }
            let databaseSHA256: String
            do {
                databaseSHA256 = try CatalogSnapshotHashing.sha256Hex(of: destinationDatabaseURL)
            } catch let error as CatalogSnapshotError {
                throw error
            } catch {
                throw CatalogSnapshotError.invalidDatabaseChecksum
            }

            let manifest = CatalogSnapshotManifest(
                formatVersion: CatalogSnapshotConstants.manifestFormatVersion,
                snapshotID: snapshotIDString,
                createdAtMs: createdAtMs,
                appVersion: appVersion,
                appliedMigrations: appliedMigrations,
                databaseFilename: CatalogSnapshotConstants.databaseFilename,
                databaseBytes: databaseBytes,
                databaseSHA256: databaseSHA256
            )
            try CatalogSnapshotManifestValidator.validate(manifest, expectedSnapshotID: snapshotIDString)

            let manifestData: Data
            do {
                manifestData = try CatalogSnapshotManifestCodec.encode(manifest)
            } catch {
                throw CatalogSnapshotError.manifestWriteFailed
            }
            let manifestURL = tempDirectoryURL.appendingPathComponent(CatalogSnapshotConstants.manifestFilename)

            if let manifestDataWriter = dependencies.manifestDataWriter {
                do {
                    try manifestDataWriter(manifestData, manifestURL)
                } catch {
                    throw Self.mapManifestWriterError(error)
                }
            } else {
                do {
                    try manifestData.write(to: manifestURL, options: .atomic)
                } catch {
                    throw CatalogSnapshotError.manifestWriteFailed
                }
            }

            let decodedManifest: CatalogSnapshotManifest
            do {
                decodedManifest = try CatalogSnapshotManifestCodec.decode(from: Data(contentsOf: manifestURL))
            } catch {
                throw CatalogSnapshotError.manifestWriteFailed
            }
            try CatalogSnapshotManifestValidator.validate(decodedManifest, expectedSnapshotID: snapshotIDString)
            guard decodedManifest.databaseBytes == databaseBytes,
                  decodedManifest.databaseSHA256 == databaseSHA256 else {
                throw CatalogSnapshotError.manifestWriteFailed
            }

            do {
                try dependencies.publicationFailureHook?()
            } catch {
                throw Self.mapPublicationHookError(error)
            }
            do {
                try fileManager.moveItem(at: tempDirectoryURL, to: finalDirectoryURL)
            } catch {
                throw CatalogSnapshotError.publicationFailed
            }

            return CatalogSnapshotDescriptor(
                snapshotID: snapshotIDString,
                directoryURL: finalDirectoryURL,
                manifest: decodedManifest
            )
        } catch let error as CatalogSnapshotError where error == .closeFailed {
            throw error
        } catch let error as CatalogSnapshotError {
            if destinationQueueCreated, !destinationClosed, let destinationQueue {
                do {
                    try CatalogDatabase.closeQueue(destinationQueue)
                    destinationClosed = true
                } catch {
                    throw CatalogSnapshotError.closeFailed
                }
            }
            if tempDirectoryCreated, destinationClosed || !destinationQueueCreated,
               fileManager.fileExists(atPath: tempDirectoryURL.path) {
                try? fileManager.removeItem(at: tempDirectoryURL)
            }
            throw error
        } catch {
            if destinationQueueCreated, !destinationClosed, let destinationQueue {
                do {
                    try CatalogDatabase.closeQueue(destinationQueue)
                    destinationClosed = true
                } catch {
                    throw CatalogSnapshotError.closeFailed
                }
            }
            if tempDirectoryCreated, destinationClosed || !destinationQueueCreated,
               fileManager.fileExists(atPath: tempDirectoryURL.path) {
                try? fileManager.removeItem(at: tempDirectoryURL)
            }
            throw CatalogSnapshotError.backupFailed
        }
    }
}

private extension CatalogSnapshotCreator {
    static func mapOpenPreparationError(_: Error) -> CatalogSnapshotError {
        .backupFailed
    }

    static func mapBackupProgressError(_ error: Error) -> CatalogSnapshotError {
        if let error = error as? CatalogSnapshotError, error == .backupAborted {
            return error
        }
        return .backupFailed
    }

    static func mapBackupOperationError(_ error: CatalogSnapshotError) -> CatalogSnapshotError {
        if error == .backupAborted {
            return error
        }
        return .backupFailed
    }

    static func mapIntegritySeamError(_: Error) -> CatalogSnapshotError {
        .integrityCheckFailed
    }

    static func mapHashSeamError(_: Error) -> CatalogSnapshotError {
        .invalidDatabaseChecksum
    }

    static func mapManifestWriterError(_: Error) -> CatalogSnapshotError {
        .manifestWriteFailed
    }

    static func mapPublicationHookError(_: Error) -> CatalogSnapshotError {
        .publicationFailed
    }

    static func mapCloseFailureHookError(_ error: Error) -> CatalogSnapshotError {
        if let error = error as? CatalogSnapshotError, error == .closeFailed {
            return error
        }
        return .closeFailed
    }
}
