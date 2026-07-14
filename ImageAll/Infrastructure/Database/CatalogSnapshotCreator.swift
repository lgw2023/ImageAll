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

        var destinationQueue: DatabaseQueue?
        var destinationClosed = false
        do {
            try fileManager.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
            let destinationDatabaseURL = tempDirectoryURL.appendingPathComponent(CatalogSnapshotConstants.databaseFilename)

            var destinationConfig = Configuration()
            destinationConfig.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }
            let queue = try DatabaseQueue(path: destinationDatabaseURL.path, configuration: destinationConfig)
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

            if let destinationCloseHandler = dependencies.destinationCloseHandler {
                try destinationCloseHandler(queue)
            } else {
                try CatalogDatabase.closeQueue(queue)
                try CatalogDatabaseSidecarHelpers.removeSidecarsIfPresent(at: destinationDatabaseURL)
                try CatalogDatabaseSidecarHelpers.requireNoSidecars(at: destinationDatabaseURL)
            }
            destinationClosed = true
            destinationQueue = nil

            let databaseBytes: Int64
            do {
                databaseBytes = try CatalogSnapshotHashing.fileSize(of: destinationDatabaseURL)
            } catch {
                throw CatalogSnapshotError.invalidDatabaseBytes
            }
            guard databaseBytes > 0 else {
                throw CatalogSnapshotError.invalidDatabaseBytes
            }

            let databaseSHA256: String
            do {
                databaseSHA256 = try CatalogSnapshotHashing.sha256Hex(of: destinationDatabaseURL)
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

            let manifestData = try CatalogSnapshotManifestCodec.encode(manifest)
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

            let decodedManifest = try CatalogSnapshotManifestCodec.decode(from: Data(contentsOf: manifestURL))
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
            if let destinationQueue, !destinationClosed {
                try CatalogDatabase.closeQueue(destinationQueue)
                destinationClosed = true
            }
            if destinationClosed, fileManager.fileExists(atPath: tempDirectoryURL.path) {
                try? fileManager.removeItem(at: tempDirectoryURL)
            }
            throw error
        }
    }
}
