import GRDB
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

final class FolderReconcileTransactionTests: XCTestCase {
    func testReusableObservationSkipsMetadataDecodeOnlyForAnUnchangedCurrentAsset() throws {
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let assetID = UUID()
        try FolderReconcileTestSupport.seedActiveFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: Data("bookmark".utf8)
        )
        try CatalogRepository(database: database).insertAsset(
            NewAssetInput(
                assetID: assetID,
                sourceID: sourceID,
                locatorKind: .file,
                relativePath: "unchanged.mov",
                photosLocalIdentifier: nil,
                mediaType: UTType.quickTimeMovie.identifier,
                timestampMs: FolderReconcileTestSupport.baseTimeMs
            )
        )
        try CatalogRepository(database: database).upsertFileFingerprint(
            FileFingerprintInput(
                assetID: assetID,
                sizeBytes: 1_234,
                modifiedAtNs: 5_678,
                resourceID: Data("old-volume-id".utf8),
                sha256: nil
            )
        )
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE asset SET
                    file_name = 'unchanged.mov',
                    media_kind = 'video',
                    duration_ms = 4_321,
                    width = 1_920,
                    height = 1_080,
                    media_created_at_ms = 1_700_000_000_000,
                    availability = 'available'
                WHERE id = ?
                """,
                arguments: [assetID.uuidString.lowercased()]
            )
        }

        let reused = try repository.lookupReusableObservation(
            sourceID: sourceID,
            relativePath: "unchanged.mov",
            fileName: "unchanged.mov",
            sizeBytes: 1_234,
            modifiedAtNs: 5_678,
            resourceID: Data("remounted-volume-id".utf8)
        )

        XCTAssertEqual(
            reused,
            FolderReconcileAssetObservation(
                relativePath: "unchanged.mov",
                fileName: "unchanged.mov",
                mediaKind: .video,
                mediaType: UTType.quickTimeMovie.identifier,
                durationMs: 4_321,
                width: 1_920,
                height: 1_080,
                mediaCreatedAtMs: 1_700_000_000_000,
                availability: .available,
                sizeBytes: 1_234,
                modifiedAtNs: 5_678,
                resourceID: Data("remounted-volume-id".utf8),
                movePathProbe: nil
            )
        )
        XCTAssertNil(
            try repository.lookupReusableObservation(
                sourceID: sourceID,
                relativePath: "unchanged.mov",
                fileName: "unchanged.mov",
                sizeBytes: 1_234,
                modifiedAtNs: 5_679,
                resourceID: Data("remounted-volume-id".utf8)
            )
        )

        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET availability = 'recycled' WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }
        XCTAssertNil(
            try repository.lookupReusableObservation(
                sourceID: sourceID,
                relativePath: "unchanged.mov",
                fileName: "unchanged.mov",
                sizeBytes: 1_234,
                modifiedAtNs: 5_678,
                resourceID: Data("remounted-volume-id".utf8)
            )
        )
    }

    func testCompleteGenerationDoesNotOverwriteRecycledAvailability() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let assetID = UUID()
        try FolderReconcileTestSupport.seedActiveFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: Data("bookmark".utf8)
        )
        try CatalogRepository(database: database).insertAsset(
            NewAssetInput(
                assetID: assetID,
                sourceID: sourceID,
                locatorKind: .file,
                relativePath: "recycled.jpg",
                photosLocalIdentifier: nil,
                mediaType: UTType.jpeg.identifier,
                timestampMs: FolderReconcileTestSupport.baseTimeMs
            )
        )
        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET availability = 'recycled' WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(
            try queue.claimNext(ClaimNextInput(owner: "recycle-guard", leaseDurationMs: 1_000))
        )
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(
                lease: lease,
                sourceID: sourceID,
                leaseDurationMs: 1_000
            )
        )

        _ = try repository.completeGeneration(
            FolderCompleteGenerationInput(
                lease: lease,
                sourceID: sourceID,
                generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch,
                checkpoint: begin.checkpoint,
                leaseDurationMs: 1_000
            )
        )

        let availability = try database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(availability, AssetAvailability.recycled.rawValue)
    }

    func testCompleteGenerationDoesNotMarkPendingRecycleAssetMissing() throws {
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let assetID = UUID()
        try FolderReconcileTestSupport.seedActiveFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: Data("bookmark".utf8)
        )
        try CatalogRepository(database: database).insertAsset(
            NewAssetInput(
                assetID: assetID,
                sourceID: sourceID,
                locatorKind: .file,
                relativePath: "moving.jpg",
                photosLocalIdentifier: nil,
                mediaType: UTType.jpeg.identifier,
                timestampMs: FolderReconcileTestSupport.baseTimeMs
            )
        )
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO recycle_entry (
                    id, asset_id, source_kind, trashed_at_ms, purge_after_ms, state,
                    quarantine_relative_path, original_relative_path, photos_local_identifier,
                    error_code, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'file', ?, ?, 'pending', ?, ?, NULL, NULL, ?, ?)
                """,
                arguments: [
                    UUID().uuidString.lowercased(),
                    assetID.uuidString.lowercased(),
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs
                        + LibrarySlimmingRecyclePolicy.dayMs,
                    "source/asset/moving.jpg",
                    "moving.jpg",
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                ]
            )
        }
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(
            try queue.claimNext(ClaimNextInput(owner: "pending-recycle", leaseDurationMs: 1_000))
        )
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(
                lease: lease,
                sourceID: sourceID,
                leaseDurationMs: 1_000
            )
        )

        _ = try repository.completeGeneration(
            FolderCompleteGenerationInput(
                lease: lease,
                sourceID: sourceID,
                generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch,
                checkpoint: begin.checkpoint,
                leaseDurationMs: 1_000
            )
        )

        let availability = try database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(availability, AssetAvailability.available.rawValue)
    }

    func testObservedFileDoesNotOverwriteRecycledAvailability() throws {
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let assetID = UUID()
        try FolderReconcileTestSupport.seedActiveFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: Data("bookmark".utf8)
        )
        try CatalogRepository(database: database).insertAsset(
            NewAssetInput(
                assetID: assetID,
                sourceID: sourceID,
                locatorKind: .file,
                relativePath: "recycled.jpg",
                photosLocalIdentifier: nil,
                mediaType: UTType.jpeg.identifier,
                timestampMs: FolderReconcileTestSupport.baseTimeMs
            )
        )
        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET availability = 'recycled' WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(
            try queue.claimNext(ClaimNextInput(owner: "recycle-observed", leaseDurationMs: 1_000))
        )
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(
                lease: lease,
                sourceID: sourceID,
                leaseDurationMs: 1_000
            )
        )

        _ = try repository.commitAssetBatch(
            FolderAssetBatchInput(
                lease: lease,
                sourceID: sourceID,
                generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch,
                checkpoint: begin.checkpoint,
                observations: [
                    FolderReconcileAssetObservation(
                        relativePath: "recycled.jpg",
                        fileName: "recycled.jpg",
                        mediaType: UTType.jpeg.identifier,
                        width: 2,
                        height: 1,
                        mediaCreatedAtMs: nil,
                        availability: .available,
                        sizeBytes: 100,
                        modifiedAtNs: 1,
                        resourceID: nil,
                        movePathProbe: nil
                    ),
                ],
                leaseDurationMs: 1_000,
                outcome: .continue
            )
        )

        let availability = try database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(availability, AssetAvailability.recycled.rawValue)
    }

    func testObservedFileDuringRestoreKeepsOriginalAssetIdentity() throws {
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let assetID = UUID()
        try FolderReconcileTestSupport.seedActiveFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: Data("bookmark".utf8)
        )
        try CatalogRepository(database: database).insertAsset(
            NewAssetInput(
                assetID: assetID,
                sourceID: sourceID,
                locatorKind: .file,
                relativePath: "restoring.jpg",
                photosLocalIdentifier: nil,
                mediaType: UTType.jpeg.identifier,
                timestampMs: FolderReconcileTestSupport.baseTimeMs
            )
        )
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE asset
                SET availability = 'missing'
                WHERE id = ?
                """,
                arguments: [assetID.uuidString.lowercased()]
            )
            try db.execute(
                sql: """
                INSERT INTO file_fingerprint (
                    asset_id, size_bytes, modified_at_ns, resource_id, sha256
                ) VALUES (?, 100, 1, NULL, ?)
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    Data(repeating: 7, count: 32),
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO recycle_entry (
                    id, asset_id, source_kind, trashed_at_ms, purge_after_ms, state,
                    quarantine_relative_path, original_relative_path, photos_local_identifier,
                    error_code, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'file', ?, ?, 'restoring', ?, ?, NULL, NULL, ?, ?)
                """,
                arguments: [
                    UUID().uuidString.lowercased(),
                    assetID.uuidString.lowercased(),
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs
                        + LibrarySlimmingRecyclePolicy.dayMs,
                    "source/asset/restoring.jpg",
                    "restoring.jpg",
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                ]
            )
        }
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(
            try queue.claimNext(ClaimNextInput(owner: "restore-observed", leaseDurationMs: 1_000))
        )
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(
                lease: lease,
                sourceID: sourceID,
                leaseDurationMs: 1_000
            )
        )

        _ = try repository.commitAssetBatch(
            FolderAssetBatchInput(
                lease: lease,
                sourceID: sourceID,
                generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch,
                checkpoint: begin.checkpoint,
                observations: [
                    FolderReconcileAssetObservation(
                        relativePath: "restoring.jpg",
                        fileName: "restoring.jpg",
                        mediaType: UTType.jpeg.identifier,
                        width: 2,
                        height: 1,
                        mediaCreatedAtMs: nil,
                        availability: .available,
                        sizeBytes: 100,
                        modifiedAtNs: 1,
                        resourceID: nil,
                        movePathProbe: nil
                    ),
                ],
                leaseDurationMs: 1_000,
                outcome: .continue
            )
        )

        let rows = try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, locator_state, availability
                FROM asset
                WHERE source_id = ? AND relative_path = ?
                """,
                arguments: [sourceID.uuidString.lowercased(), "restoring.jpg"]
            )
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["id"] as String?, assetID.uuidString.lowercased())
        XCTAssertEqual(
            rows.first?["locator_state"] as String?,
            AssetLocatorState.current.rawValue
        )
        XCTAssertEqual(
            rows.first?["availability"] as String?,
            AssetAvailability.missing.rawValue
        )
    }

    func testObservedFileAtPurgedTombstonePathCreatesNewAssetIdentity() throws {
        let database = try CatalogDatabase.open(at: makeTempDatabaseURL())
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let purgedAssetID = UUID()
        try FolderReconcileTestSupport.seedActiveFolderSource(
            database: database,
            sourceID: sourceID,
            bookmark: Data("bookmark".utf8)
        )
        try CatalogRepository(database: database).insertAsset(
            NewAssetInput(
                assetID: purgedAssetID,
                sourceID: sourceID,
                locatorKind: .file,
                relativePath: "reused.jpg",
                photosLocalIdentifier: nil,
                mediaType: UTType.jpeg.identifier,
                timestampMs: FolderReconcileTestSupport.baseTimeMs
            )
        )
        try database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET availability = 'recycled' WHERE id = ?",
                arguments: [purgedAssetID.uuidString.lowercased()]
            )
            try db.execute(
                sql: """
                INSERT INTO recycle_entry (
                    id, asset_id, source_kind, trashed_at_ms, purge_after_ms, state,
                    quarantine_relative_path, original_relative_path, photos_local_identifier,
                    error_code, created_at_ms, updated_at_ms
                ) VALUES (?, ?, 'file', ?, ?, 'purged', NULL, NULL, NULL, NULL, ?, ?)
                """,
                arguments: [
                    UUID().uuidString.lowercased(),
                    purgedAssetID.uuidString.lowercased(),
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                ]
            )
        }
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(
            try queue.claimNext(ClaimNextInput(owner: "purged-path", leaseDurationMs: 1_000))
        )
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(
                lease: lease,
                sourceID: sourceID,
                leaseDurationMs: 1_000
            )
        )

        _ = try repository.commitAssetBatch(
            FolderAssetBatchInput(
                lease: lease,
                sourceID: sourceID,
                generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch,
                checkpoint: begin.checkpoint,
                observations: [
                    FolderReconcileAssetObservation(
                        relativePath: "reused.jpg",
                        fileName: "reused.jpg",
                        mediaType: UTType.jpeg.identifier,
                        width: 2,
                        height: 1,
                        mediaCreatedAtMs: nil,
                        availability: .available,
                        sizeBytes: 100,
                        modifiedAtNs: 1,
                        resourceID: nil,
                        movePathProbe: nil
                    ),
                ],
                leaseDurationMs: 1_000,
                outcome: .continue
            )
        )

        let rows = try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, locator_state, availability
                FROM asset
                WHERE source_id = ? AND relative_path = ?
                ORDER BY locator_state ASC, id ASC
                """,
                arguments: [sourceID.uuidString.lowercased(), "reused.jpg"]
            )
        }
        XCTAssertEqual(rows.count, 2)
        let old = try XCTUnwrap(rows.first(where: {
            ($0["id"] as String) == purgedAssetID.uuidString.lowercased()
        }))
        let current = try XCTUnwrap(rows.first(where: {
            ($0["locator_state"] as String) == AssetLocatorState.current.rawValue
        }))
        XCTAssertEqual(old["locator_state"] as String, AssetLocatorState.historical.rawValue)
        XCTAssertEqual(old["availability"] as String, AssetAvailability.recycled.rawValue)
        XCTAssertNotEqual(current["id"] as String, purgedAssetID.uuidString.lowercased())
        XCTAssertEqual(current["availability"] as String, AssetAvailability.available.rawValue)
    }

    func testBeginFailureRollsBackGenerationIncrement() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        try FolderReconcileTestFaults.install(on: database)
        try FolderReconcileTestFaults.setMode(.failBeginSourceUpdate, database: database)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "begin")
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        XCTAssertThrowsError(
            try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000))
        )
        let generation = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT scan_generation FROM source WHERE id = ?", arguments: [sourceID.uuidString.lowercased()])
        }
        XCTAssertEqual(generation, 0)
    }

    func testEnumerationIncompleteLeavesNoMissingAssets() throws {
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "incomplete")
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try fixture.writeFile(root: root, relativePath: "locked/hidden.png", contents: FolderReconcileTestSupport.minimalPNGData())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let sourceID = UUID()
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let (handler, _) = FolderReconcileTestSupport.makeHandler(database: database, root: root, bookmark: bookmark)
        let coordinator = FolderReconcileTestSupport.makeCoordinator(queue: queue, handler: handler)
        let result = try XCTUnwrap(try coordinator.claimAndExecuteOnce(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        XCTAssertEqual(result.snapshot.state, .retryableFailed)
        XCTAssertEqual(result.snapshot.lastErrorCode, .folderEnumerationIncomplete)
        let missingCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset WHERE availability = 'missing'")
        }
        XCTAssertEqual(missingCount, 0)
    }

    func testExpiredLeaseRejectedBeforeBusinessClosure() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let baseClock = FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        let queue = GRDBJobQueue(
            database: database,
            clock: baseClock,
            retryPolicy: FixedDelayRetryPolicy(delayMs: 1000)
        )
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "lease")
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))

        let expiredQueue = GRDBJobQueue(
            database: database,
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs + 5_000),
            retryPolicy: FixedDelayRetryPolicy(delayMs: 1000)
        )
        let repository = GRDBFolderReconcileRepository(queue: expiredQueue)
        XCTAssertThrowsError(
            try repository.beginGeneration(
                FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
            )
        ) { error in
            XCTAssertEqual(error as? JobQueueError, .expiredLease(lease.jobID))
        }
    }

    func testDirtyEpochCreatesExactlyOneSuccessor() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "succ")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        let jobID = UUID()
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: jobID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        try database.pool.write { db in
            try JobTestSupport.incrementSourceDirtyEpoch(db, sourceID: sourceID, delta: 1)
        }
        let checkpoint = FolderReconcileCheckpointV1(
            generation: begin.generation,
            startedDirtyEpoch: begin.startedDirtyEpoch,
            attempt: lease.attempts,
            candidateFiles: 1
        )
        let complete = try repository.completeGeneration(
            FolderCompleteGenerationInput(
                lease: lease,
                sourceID: sourceID,
                generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch,
                checkpoint: checkpoint,
                leaseDurationMs: 1000
            )
        )
        XCTAssertNotNil(complete.successorJobID)
        XCTAssertEqual(complete.jobSnapshot.state, .completed)
        let pending = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job WHERE source_id = ? AND state = 'pending'", arguments: [sourceID.uuidString.lowercased()])
        }
        XCTAssertEqual(pending, 1, "expected one pending successor, got \(pending ?? -1)")
        let completed = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job WHERE id = ? AND state = 'completed'", arguments: [jobID.uuidString.lowercased()])
        }
        XCTAssertEqual(completed, 1)
    }

    func testCleanEpochCreatesNoSuccessor() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "clean")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        let jobID = UUID()
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID, jobID: jobID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        let checkpoint = FolderReconcileCheckpointV1(
            generation: begin.generation,
            startedDirtyEpoch: begin.startedDirtyEpoch,
            attempt: lease.attempts,
            candidateFiles: 1
        )
        let complete = try repository.completeGeneration(
            FolderCompleteGenerationInput(
                lease: lease,
                sourceID: sourceID,
                generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch,
                checkpoint: checkpoint,
                leaseDurationMs: 1000
            )
        )
        XCTAssertNil(complete.successorJobID)
        let pending = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job WHERE source_id = ? AND state = 'pending'", arguments: [sourceID.uuidString.lowercased()])
        }
        XCTAssertEqual(pending, 0)
    }

    func testBatchAssetInsertFaultRollsBackEntireBatch() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        try FolderReconcileTestFaults.install(on: database)
        try FolderReconcileTestFaults.setMode(.failAssetInsert, database: database)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "batch-fault")
        try fixture.writeFile(root: root, relativePath: "a.png", contents: FolderReconcileTestSupport.minimalPNGData())
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        let observation = FolderReconcileAssetObservation(
            relativePath: "a.png",
            fileName: "a.png",
            mediaType: UTType.png.identifier,
            width: 2,
            height: 1,
            mediaCreatedAtMs: nil,
            availability: .available,
            sizeBytes: 100,
            modifiedAtNs: 1,
            resourceID: nil,
            movePathProbe: nil
        )
        XCTAssertThrowsError(
            try repository.commitAssetBatch(
                FolderAssetBatchInput(
                    lease: lease,
                    sourceID: sourceID,
                    generation: begin.generation,
                    startedDirtyEpoch: begin.startedDirtyEpoch,
                    checkpoint: begin.checkpoint,
                    observations: [observation],
                    leaseDurationMs: 1000,
                    outcome: .continue
                )
            )
        )
        let assetCount = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset")
        }
        XCTAssertEqual(assetCount, 0)
    }

    func testFinalMissingFaultRollsBackCompletion() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        try FolderReconcileTestFaults.install(on: database)
        try FolderReconcileTestFaults.setMode(.failFinalMissing, database: database)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "final-missing")
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, file_name, locator_state,
                    media_type, content_revision, last_seen_generation, availability,
                    record_created_at_ms, record_updated_at_ms
                ) VALUES (?, ?, 'file', 'old.png', 'old.png', 'current', 'public.png', 1, 0, 'available', ?, ?)
                """,
                arguments: [UUID().uuidString.lowercased(), sourceID.uuidString.lowercased(), FolderReconcileTestSupport.baseTimeMs, FolderReconcileTestSupport.baseTimeMs]
            )
        }
        let checkpoint = FolderReconcileCheckpointV1(
            generation: begin.generation,
            startedDirtyEpoch: begin.startedDirtyEpoch,
            attempt: lease.attempts
        )
        XCTAssertThrowsError(
            try repository.completeGeneration(
                FolderCompleteGenerationInput(
                    lease: lease,
                    sourceID: sourceID,
                    generation: begin.generation,
                    startedDirtyEpoch: begin.startedDirtyEpoch,
                    checkpoint: checkpoint,
                    leaseDurationMs: 1000
                )
            )
        )
        let jobState = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM job WHERE id = ?", arguments: [lease.jobID.uuidString.lowercased()])
        }
        XCTAssertEqual(jobState, JobState.running.rawValue)
    }

    func testFinalSuccessorFaultRollsBackCompletion() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        try FolderReconcileTestFaults.install(on: database)
        let queue = FolderReconcileTestSupport.makeQueue(database: database)
        let repository = GRDBFolderReconcileRepository(queue: queue)
        let sourceID = UUID()
        let fixture = FolderReconcileTestSupport.TempFixtureRoot()
        defer { fixture.cleanup() }
        let root = try fixture.makeRoot(label: "final-succ")
        let bookmark = root.path.data(using: .utf8)!
        try FolderReconcileTestSupport.seedActiveFolderSource(database: database, sourceID: sourceID, bookmark: bookmark)
        _ = try FolderReconcileTestSupport.enqueueReconcileJob(queue: queue, sourceID: sourceID)
        let lease = try XCTUnwrap(try queue.claimNext(ClaimNextInput(owner: "w", leaseDurationMs: 1000)))
        let begin = try repository.beginGeneration(
            FolderReconcileTestSupport.beginGenerationInput(lease: lease, sourceID: sourceID, leaseDurationMs: 1000)
        )
        try database.pool.write { db in
            try JobTestSupport.incrementSourceDirtyEpoch(db, sourceID: sourceID, delta: 1)
        }
        try FolderReconcileTestFaults.setMode(.failFinalSuccessor, database: database)
        let checkpoint = FolderReconcileCheckpointV1(
            generation: begin.generation,
            startedDirtyEpoch: begin.startedDirtyEpoch,
            attempt: lease.attempts
        )
        XCTAssertThrowsError(
            try repository.completeGeneration(
                FolderCompleteGenerationInput(
                    lease: lease,
                    sourceID: sourceID,
                    generation: begin.generation,
                    startedDirtyEpoch: begin.startedDirtyEpoch,
                    checkpoint: checkpoint,
                    leaseDurationMs: 1000
                )
            )
        )
        let jobState = try database.pool.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM job WHERE id = ?", arguments: [lease.jobID.uuidString.lowercased()])
        }
        XCTAssertEqual(jobState, JobState.running.rawValue)
        let pending = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job WHERE state = 'pending'")
        }
        XCTAssertEqual(pending, 0)
    }
}
