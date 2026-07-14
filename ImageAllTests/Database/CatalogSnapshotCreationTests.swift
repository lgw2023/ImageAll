import GRDB
import XCTest
@testable import ImageAll

final class CatalogSnapshotCreationTests: XCTestCase {
    func testManualSnapshotCreatesFinalDirectoryWithQuickCheckAndManifestFromBackupTarget() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        _ = try SnapshotTestSupport.seedRepresentativeFacts(in: database)

        let snapshotID = UUID()
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let creator = CatalogSnapshotCreator(sourceDatabase: database)
        let descriptor = try creator.createManualSnapshot(
            snapshotID: snapshotID,
            createdAtMs: SnapshotTestSupport.createdAtMs,
            appVersion: SnapshotTestSupport.appVersion,
            backupsDirectoryURL: backups
        )

        let tempURL = backups.appendingPathComponent("\(snapshotID.uuidString.lowercased()).tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))

        let databaseURL = descriptor.directoryURL.appendingPathComponent(CatalogSnapshotConstants.databaseFilename)
        let validated = try CatalogSnapshotCatalog.validatePublishedSnapshotDirectory(descriptor.directoryURL)
        XCTAssertEqual(validated.manifest, descriptor.manifest)
        XCTAssertEqual(descriptor.manifest.appliedMigrations, CatalogMigrationID.knownOrdered)
        XCTAssertEqual(descriptor.manifest.databaseBytes, try CatalogSnapshotHashing.fileSize(of: databaseURL))
        XCTAssertEqual(descriptor.manifest.databaseSHA256, try CatalogSnapshotHashing.sha256Hex(of: databaseURL))
        XCTAssertFalse(CatalogDatabaseSidecarHelpers.hasSidecars(at: databaseURL))
        XCTAssertEqual(try SnapshotTestSupport.readJournalMode(at: databaseURL).lowercased(), "delete")
    }

    func testPreMigrationSnapshotReusesSameCreationPrimitive() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let creator = CatalogSnapshotCreator(sourceDatabase: database)

        let descriptor = try creator.createPreMigrationSnapshot(
            snapshotID: UUID(),
            createdAtMs: SnapshotTestSupport.createdAtMs,
            appVersion: SnapshotTestSupport.appVersion,
            backupsDirectoryURL: backups
        )

        XCTAssertEqual(descriptor.manifest.appliedMigrations, CatalogMigrationID.knownOrdered)
    }

    func testSnapshotCollisionDoesNotOverwriteExistingDirectory() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let snapshotID = UUID()
        let creator = CatalogSnapshotCreator(sourceDatabase: database)

        _ = try creator.createManualSnapshot(
            snapshotID: snapshotID,
            createdAtMs: SnapshotTestSupport.createdAtMs,
            appVersion: SnapshotTestSupport.appVersion,
            backupsDirectoryURL: backups
        )

        XCTAssertThrowsError(
            try creator.createManualSnapshot(
                snapshotID: snapshotID,
                createdAtMs: SnapshotTestSupport.createdAtMs,
                appVersion: SnapshotTestSupport.appVersion,
                backupsDirectoryURL: backups
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .snapshotCollision)
        }
    }

    func testBackupAbortDuringIncompleteStepDoesNotPublishFinalOrChangeLiveFacts() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        try SnapshotTestSupport.populateManyPages(in: database)
        let facts = try SnapshotTestSupport.seedRepresentativeFacts(in: database)
        let beforeCounts = try SnapshotTestSupport.factCounts(in: database)
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let snapshotID = UUID()
        let progressCounter = ProgressCounter()

        XCTAssertThrowsError(
            try CatalogSnapshotCreator(sourceDatabase: database).createManualSnapshot(
                snapshotID: snapshotID,
                createdAtMs: SnapshotTestSupport.createdAtMs,
                appVersion: SnapshotTestSupport.appVersion,
                backupsDirectoryURL: backups,
                dependencies: .init(
                    pagesPerStep: 1,
                    backupProgressHook: { progress in
                        guard !progress.isCompleted else { return }
                        progressCounter.increment()
                        throw CatalogSnapshotError.backupAborted
                    }
                )
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .backupAborted)
        }

        XCTAssertGreaterThan(progressCounter.value, 0)

        let finalURL = backups.appendingPathComponent(snapshotID.uuidString.lowercased(), isDirectory: true)
        let tempURL = backups.appendingPathComponent("\(snapshotID.uuidString.lowercased()).tmp", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        XCTAssertEqual(try SnapshotTestSupport.factCounts(in: database), beforeCounts)
        _ = facts
    }

    func testQuickCheckFailureDuringCreationDoesNotPublishFinal() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        _ = try SnapshotTestSupport.seedRepresentativeFacts(in: database)
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let snapshotID = UUID()

        XCTAssertThrowsError(
            try CatalogSnapshotCreator(sourceDatabase: database).createManualSnapshot(
                snapshotID: snapshotID,
                createdAtMs: SnapshotTestSupport.createdAtMs,
                appVersion: SnapshotTestSupport.appVersion,
                backupsDirectoryURL: backups,
                dependencies: .init(
                    destinationPreCloseHook: { _, databaseURL in
                        try SnapshotTestSupport.corruptDestinationQuickCheck(at: databaseURL)
                    }
                )
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .integrityCheckFailed)
        }

        let finalURL = backups.appendingPathComponent(snapshotID.uuidString.lowercased(), isDirectory: true)
        let tempURL = backups.appendingPathComponent("\(snapshotID.uuidString.lowercased()).tmp", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testCloseFailureDuringCreationDoesNotPublishFinal() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let snapshotID = UUID()

        XCTAssertThrowsError(
            try CatalogSnapshotCreator(sourceDatabase: database).createManualSnapshot(
                snapshotID: snapshotID,
                createdAtMs: SnapshotTestSupport.createdAtMs,
                appVersion: SnapshotTestSupport.appVersion,
                backupsDirectoryURL: backups,
                dependencies: .init(
                    destinationCloseFailureHook: {
                        throw CatalogSnapshotError.closeFailed
                    }
                )
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .closeFailed)
        }

        let finalURL = backups.appendingPathComponent(snapshotID.uuidString.lowercased(), isDirectory: true)
        let tempURL = backups.appendingPathComponent("\(snapshotID.uuidString.lowercased()).tmp", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testManifestWriteFailureCleansTempOnly() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let snapshotID = UUID()

        XCTAssertThrowsError(
            try CatalogSnapshotCreator(sourceDatabase: database).createManualSnapshot(
                snapshotID: snapshotID,
                createdAtMs: SnapshotTestSupport.createdAtMs,
                appVersion: SnapshotTestSupport.appVersion,
                backupsDirectoryURL: backups,
                dependencies: .init(
                    manifestDataWriter: { _, _ in
                        throw CatalogSnapshotError.manifestWriteFailed
                    }
                )
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .manifestWriteFailed)
        }

        let tempURL = backups.appendingPathComponent("\(snapshotID.uuidString.lowercased()).tmp", isDirectory: true)
        let finalURL = backups.appendingPathComponent(snapshotID.uuidString.lowercased(), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
    }

    func testPublicationRenameFailureDoesNotLeaveFinalDirectory() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let snapshotID = UUID()
        let snapshotIDString = snapshotID.uuidString.lowercased()

        XCTAssertThrowsError(
            try CatalogSnapshotCreator(sourceDatabase: database).createManualSnapshot(
                snapshotID: snapshotID,
                createdAtMs: SnapshotTestSupport.createdAtMs,
                appVersion: SnapshotTestSupport.appVersion,
                backupsDirectoryURL: backups,
                dependencies: .init(
                    publicationFailureHook: {
                        throw CatalogSnapshotError.publicationFailed
                    }
                )
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .publicationFailed)
        }

        let finalURL = backups.appendingPathComponent(snapshotIDString, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertTrue(try CatalogSnapshotCatalog.discoverPublishedSnapshots(in: backups).isEmpty)
    }

    func testHashFailureDuringCreationCleansTempAndLeavesLiveFactsUnchanged() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        _ = try SnapshotTestSupport.seedRepresentativeFacts(in: database)
        let beforeCounts = try SnapshotTestSupport.factCounts(in: database)
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let snapshotID = UUID()

        XCTAssertThrowsError(
            try CatalogSnapshotCreator(sourceDatabase: database).createManualSnapshot(
                snapshotID: snapshotID,
                createdAtMs: SnapshotTestSupport.createdAtMs,
                appVersion: SnapshotTestSupport.appVersion,
                backupsDirectoryURL: backups,
                dependencies: .init(
                    hashFailureHook: {
                        throw CatalogSnapshotError.invalidDatabaseChecksum
                    }
                )
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .invalidDatabaseChecksum)
        }

        let finalURL = backups.appendingPathComponent(snapshotID.uuidString.lowercased(), isDirectory: true)
        let tempURL = backups.appendingPathComponent("\(snapshotID.uuidString.lowercased()).tmp", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        XCTAssertEqual(try SnapshotTestSupport.factCounts(in: database), beforeCounts)
    }

    func testDestinationQueueOpenFailureCleansTempDirectory() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let snapshotID = UUID()
        let snapshotIDString = snapshotID.uuidString.lowercased()

        XCTAssertThrowsError(
            try CatalogSnapshotCreator(sourceDatabase: database).createManualSnapshot(
                snapshotID: snapshotID,
                createdAtMs: SnapshotTestSupport.createdAtMs,
                appVersion: SnapshotTestSupport.appVersion,
                backupsDirectoryURL: backups,
                dependencies: .init(
                    destinationQueueOpenFailureHook: {
                        throw CatalogSnapshotError.backupFailed
                    }
                )
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .backupFailed)
        }

        let tempURL = backups.appendingPathComponent("\(snapshotIDString).tmp", isDirectory: true)
        let finalURL = backups.appendingPathComponent(snapshotIDString, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
    }

    func testConcurrentWriteDuringBackupStepsProducesConsistentSnapshot() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        try SnapshotTestSupport.populateManyPages(in: database)
        _ = try SnapshotTestSupport.seedRepresentativeFacts(in: database)

        final class BackupGate: @unchecked Sendable {
            private let lock = NSLock()
            private var backupHasStarted = false
            private var allowContinue = false

            func markStarted() {
                lock.lock()
                backupHasStarted = true
                lock.unlock()
            }

            func hasStarted() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return backupHasStarted
            }

            func waitForAllowContinue() {
                while true {
                    lock.lock()
                    let allowed = allowContinue
                    lock.unlock()
                    if allowed { return }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }

            func allowBackupToContinue() {
                lock.lock()
                allowContinue = true
                lock.unlock()
            }
        }

        let gate = BackupGate()
        let concurrentSourceID = UUID()
        let concurrentAssetID = UUID()
        let concurrentTagID = UUID()
        let backups = SnapshotTestSupport.backupsDirectoryURL(in: root)
        let snapshotID = UUID()
        let creator = CatalogSnapshotCreator(sourceDatabase: database)
        let snapshotErrorBox = ErrorBox()

        let work = DispatchWorkItem {
            do {
                _ = try creator.createManualSnapshot(
                    snapshotID: snapshotID,
                    createdAtMs: SnapshotTestSupport.createdAtMs,
                    appVersion: SnapshotTestSupport.appVersion,
                    backupsDirectoryURL: backups,
                    dependencies: .init(
                        pagesPerStep: 1,
                        backupProgressHook: { progress in
                            guard !progress.isCompleted else { return }
                            gate.markStarted()
                            gate.waitForAllowContinue()
                        }
                    )
                )
            } catch {
                snapshotErrorBox.store(error)
            }
        }
        DispatchQueue.global().async(execute: work)

        let start = Date()
        while true {
            if gate.hasStarted() { break }
            if Date().timeIntervalSince(start) > 5 {
                XCTFail("Backup did not start")
                return
            }
            Thread.sleep(forTimeInterval: 0.001)
        }

        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'folder', 'Concurrent', ?, 0, 0, 'active', ?, ?)
                """,
                arguments: [
                    concurrentSourceID.uuidString.lowercased(),
                    DatabaseTestSupport.folderBookmark(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    media_type, record_created_at_ms, record_updated_at_ms
                ) VALUES (?, ?, 'file', 'concurrent/a.jpg', NULL, 'public.jpeg', ?, ?)
                """,
                arguments: [
                    concurrentAssetID.uuidString.lowercased(),
                    concurrentSourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES (?, 'Concurrent', 'concurrent', 'active', ?, ?)
                """,
                arguments: [
                    concurrentTagID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'accepted', ?)
                """,
                arguments: [
                    concurrentAssetID.uuidString.lowercased(),
                    concurrentTagID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                ]
            )
        }

        gate.allowBackupToContinue()

        work.wait()
        if let snapshotError = snapshotErrorBox.storedError {
            XCTFail("Snapshot failed: \(snapshotError)")
            return
        }

        let snapshotDB = backups
            .appendingPathComponent(snapshotID.uuidString.lowercased())
            .appendingPathComponent(CatalogSnapshotConstants.databaseFilename)
        _ = try CatalogSnapshotCatalog.validatePublishedSnapshotDirectory(
            backups.appendingPathComponent(snapshotID.uuidString.lowercased(), isDirectory: true)
        )

        let includedConcurrent = try SnapshotTestSupport.factCountsReadOnly(at: snapshotDB)
        if includedConcurrent.sources == 2 {
            XCTAssertEqual(includedConcurrent.assets, 2)
            XCTAssertEqual(includedConcurrent.tags, 2)
            XCTAssertEqual(includedConcurrent.decisions, 2)
        } else {
            XCTAssertEqual(includedConcurrent.sources, 1)
            XCTAssertEqual(includedConcurrent.assets, 1)
            XCTAssertEqual(includedConcurrent.tags, 1)
            XCTAssertEqual(includedConcurrent.decisions, 1)
        }
    }
}

private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

final class CatalogSnapshotCheckpointTests: XCTestCase {
    func testTruncateCheckpointRequiresCompleteFramesBeforeSidecarRemoval() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let databaseURL = root.appendingPathComponent("checkpoint/ImageAll.sqlite")
        let database = try SnapshotTestSupport.openLiveDatabase(at: databaseURL)
        _ = try SnapshotTestSupport.seedRepresentativeFacts(in: database)

        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)
        let readFinished = DispatchSemaphore(value: 0)
        let readErrorBox = ErrorBox()

        DispatchQueue.global().async {
            do {
                try database.pool.read { db in
                    readStarted.signal()
                    releaseRead.wait()
                    _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source")
                }
            } catch {
                readErrorBox.store(error)
            }
            readFinished.signal()
        }

        readStarted.wait()

        var config = Configuration()
        let challenger = try DatabaseQueue(path: databaseURL.path, configuration: config)
        XCTAssertThrowsError(
            try challenger.writeWithoutTransaction { db in
                try CatalogDatabase.performTruncateCheckpoint(db)
            }
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .checkpointFailed)
        }
        try CatalogDatabase.closeQueue(challenger)

        releaseRead.signal()
        readFinished.wait()
        if let capturedReadError = readErrorBox.storedError {
            throw capturedReadError
        }

        try database.checkpointAndCloseForReplacement()
        XCTAssertFalse(CatalogDatabaseSidecarHelpers.hasSidecars(at: databaseURL))
        XCTAssertEqual(try SnapshotTestSupport.readJournalMode(at: databaseURL).lowercased(), "delete")
        try SnapshotTestSupport.validatePublishedSnapshotReadOnly(at: databaseURL)
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var storedError: (any Error)?

    func store(_ error: any Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}
