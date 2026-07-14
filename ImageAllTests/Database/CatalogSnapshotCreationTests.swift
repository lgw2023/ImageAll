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
        try CatalogDatabase.validateClosedDatabase(at: databaseURL, requireCurrentSchema: true)
        XCTAssertEqual(descriptor.manifest.appliedMigrations, CatalogMigrationID.knownOrdered)
        XCTAssertEqual(descriptor.manifest.databaseBytes, try CatalogSnapshotHashing.fileSize(of: databaseURL))
        XCTAssertEqual(descriptor.manifest.databaseSHA256, try CatalogSnapshotHashing.sha256Hex(of: databaseURL))
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

    func testBackupAbortDoesNotPublishFinalOrChangeLiveFacts() throws {
        let root = try SnapshotTestSupport.makeTempRoot(testCase: self)
        let liveURL = SnapshotTestSupport.liveDatabaseURL(in: root)
        let database = try SnapshotTestSupport.openLiveDatabase(at: liveURL)
        try SnapshotTestSupport.populateManyPages(in: database)
        let facts = try SnapshotTestSupport.seedRepresentativeFacts(in: database)
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
                    pagesPerStep: 1,
                    abortOnlineBackupImmediately: true
                )
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .backupAborted)
        }

        let finalURL = backups.appendingPathComponent(snapshotID.uuidString.lowercased(), isDirectory: true)
        let tempURL = backups.appendingPathComponent("\(snapshotID.uuidString.lowercased()).tmp", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        XCTAssertEqual(try SnapshotTestSupport.factCounts(in: database), beforeCounts)
        _ = facts
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
                dependencies: .init(failManifestWrite: true)
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .manifestWriteFailed)
        }

        let tempURL = backups.appendingPathComponent("\(snapshotID.uuidString.lowercased()).tmp", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testPublicationRenameFailureDoesNotReportFinalSnapshot() throws {
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
                dependencies: .init(failPublicationRename: true)
            )
        ) { error in
            XCTAssertEqual(error as? CatalogSnapshotError, .publicationFailed)
        }

        let finalURL = backups.appendingPathComponent(snapshotID.uuidString.lowercased(), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertTrue(try CatalogSnapshotCatalog.discoverPublishedSnapshots(in: backups).isEmpty)
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
        var snapshotError: Error?

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
                snapshotError = error
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
        if let snapshotError {
            XCTFail("Snapshot failed: \(snapshotError)")
            return
        }

        let snapshotDB = backups
            .appendingPathComponent(snapshotID.uuidString.lowercased())
            .appendingPathComponent(CatalogSnapshotConstants.databaseFilename)
        try CatalogDatabase.validateClosedDatabase(at: snapshotDB, requireCurrentSchema: true)

        let includedConcurrent = try CatalogDatabase.open(at: snapshotDB).pool.read { db -> Bool in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM source WHERE id = ?",
                arguments: [concurrentSourceID.uuidString.lowercased()]
            ) ?? 0
            return count == 1
        }

        let counts = try SnapshotTestSupport.factCounts(at: snapshotDB)
        if includedConcurrent {
            XCTAssertEqual(counts.sources, 2)
            XCTAssertEqual(counts.assets, 2)
            XCTAssertEqual(counts.tags, 2)
            XCTAssertEqual(counts.decisions, 2)
        } else {
            XCTAssertEqual(counts.sources, 1)
            XCTAssertEqual(counts.assets, 1)
            XCTAssertEqual(counts.tags, 1)
            XCTAssertEqual(counts.decisions, 1)
        }
    }
}
