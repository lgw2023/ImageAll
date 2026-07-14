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
        try fileManager.createDirectory(at: backupsDirectoryURL, withIntermediateDirectories: true)

        let tempDirectoryURL = backupsDirectoryURL.appendingPathComponent("\(snapshotIDString).tmp", isDirectory: true)
        let finalDirectoryURL = backupsDirectoryURL.appendingPathComponent(snapshotIDString, isDirectory: true)

        if fileManager.fileExists(atPath: tempDirectoryURL.path)
            || fileManager.fileExists(atPath: finalDirectoryURL.path) {
            throw CatalogSnapshotError.snapshotCollision
        }

        var destinationQueue: DatabaseQueue?
        do {
            try fileManager.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
            let destinationDatabaseURL = tempDirectoryURL.appendingPathComponent(CatalogSnapshotConstants.databaseFilename)

            var destinationConfig = Configuration()
            destinationConfig.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
                try db.execute(sql: "PRAGMA journal_mode = DELETE")
            }
            let queue = try DatabaseQueue(path: destinationDatabaseURL.path, configuration: destinationConfig)
            destinationQueue = queue

            if dependencies.abortOnlineBackupImmediately {
                throw CatalogSnapshotError.backupAborted
            }

            var completedSteps = 0
            try sourceDatabase.pool.backup(to: queue, pagesPerStep: dependencies.pagesPerStep) { progress in
                try dependencies.backupProgressHook?(progress)
                if let abortAfterSteps = dependencies.backupAbortAfterSteps,
                   !progress.isCompleted {
                    completedSteps += 1
                    if completedSteps >= abortAfterSteps {
                        throw CatalogSnapshotError.backupAborted
                    }
                }
            }

            let appliedMigrations = try queue.read { db -> [String] in
                try CatalogDatabase.performQuickCheck(on: db)
                let migrations = try CatalogDatabase.readAppliedMigrationIDs(from: db)
                try CatalogSnapshotManifestValidator.validateMigrationPrefix(migrations)
                return migrations
            }

            try queue.writeWithoutTransaction { db in
                try CatalogDatabase.performTruncateCheckpoint(db)
            }
            try queue.close()
            destinationQueue = nil

            try CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(
                at: destinationDatabaseURL,
                fileManager: fileManager
            )
            try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: destinationDatabaseURL, fileManager: fileManager)

            let databaseBytes = try CatalogSnapshotHashing.fileSize(of: destinationDatabaseURL)
            guard databaseBytes > 0 else {
                throw CatalogSnapshotError.invalidDatabaseBytes
            }

            let databaseSHA256 = try CatalogSnapshotHashing.sha256Hex(of: destinationDatabaseURL)

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

            if dependencies.failManifestWrite {
                throw CatalogSnapshotError.manifestWriteFailed
            }

            let manifestData = try CatalogSnapshotManifestCodec.encode(manifest)
            let manifestURL = tempDirectoryURL.appendingPathComponent(CatalogSnapshotConstants.manifestFilename)
            try manifestData.write(to: manifestURL, options: .atomic)

            let decodedManifest = try CatalogSnapshotManifestCodec.decode(from: Data(contentsOf: manifestURL))
            try CatalogSnapshotManifestValidator.validate(decodedManifest, expectedSnapshotID: snapshotIDString)
            guard decodedManifest.databaseBytes == databaseBytes,
                  decodedManifest.databaseSHA256 == databaseSHA256 else {
                throw CatalogSnapshotError.manifestWriteFailed
            }

            if dependencies.failPublicationRename {
                throw CatalogSnapshotError.publicationFailed
            }

            try fileManager.moveItem(at: tempDirectoryURL, to: finalDirectoryURL)

            return try CatalogSnapshotCatalog.validatePublishedSnapshotDirectory(
                finalDirectoryURL,
                fileManager: fileManager
            )
        } catch {
            if let destinationQueue {
                try? destinationQueue.close()
            }
            if fileManager.fileExists(atPath: tempDirectoryURL.path) {
                try? fileManager.removeItem(at: tempDirectoryURL)
            }
            throw error
        }
    }
}
