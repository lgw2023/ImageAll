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
            try fileManager.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
            tempDirectoryCreated = true
            let destinationDatabaseURL = tempDirectoryURL.appendingPathComponent(CatalogSnapshotConstants.databaseFilename)

            if let destinationQueueOpenFailureHook = dependencies.destinationQueueOpenFailureHook {
                try destinationQueueOpenFailureHook()
            }

            var destinationConfig = Configuration()
            destinationConfig.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            let queue = try DatabaseQueue(path: destinationDatabaseURL.path, configuration: destinationConfig)
            destinationQueueCreated = true
            destinationQueue = queue

            do {
                try sourceDatabase.pool.backup(to: queue, pagesPerStep: dependencies.pagesPerStep) { progress in
                    try dependencies.backupProgressHook?(progress)
                }
            } catch let error as CatalogSnapshotError {
                throw error
            } catch {
                throw CatalogSnapshotError.backupFailed
            }

            let appliedMigrations: [String]
            do {
                try dependencies.destinationPreCloseHook?(queue, destinationDatabaseURL)
                try dependencies.quickCheckFailureHook?(queue)
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

            try dependencies.destinationCloseFailureHook?()
            try CatalogDatabase.closeQueue(queue)
            destinationClosed = true
            destinationQueue = nil
            try CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(at: destinationDatabaseURL)
            try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: destinationDatabaseURL)

            let databaseBytes: Int64
            do {
                databaseBytes = try CatalogSnapshotHashing.fileSize(of: destinationDatabaseURL)
            } catch {
                throw CatalogSnapshotError.invalidDatabaseBytes
            }
            guard databaseBytes > 0 else {
                throw CatalogSnapshotError.invalidDatabaseBytes
            }

            try dependencies.hashFailureHook?()
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
                try manifestDataWriter(manifestData, manifestURL)
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

            try dependencies.publicationFailureHook?()
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
        } catch {
            if destinationQueueCreated, !destinationClosed, let destinationQueue {
                try CatalogDatabase.closeQueue(destinationQueue)
                destinationClosed = true
            }
            if tempDirectoryCreated, destinationClosed || !destinationQueueCreated,
               fileManager.fileExists(atPath: tempDirectoryURL.path) {
                try? fileManager.removeItem(at: tempDirectoryURL)
            }
            throw error
        }
    }
}
