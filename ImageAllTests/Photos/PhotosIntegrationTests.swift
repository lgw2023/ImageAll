import Foundation
import GRDB
import Photos
import XCTest
@testable import ImageAll

final class PhotosIntegrationTests: XCTestCase {
    func testPhotoKitPolicyIncludesLivePhotoStillImageButExcludesVideoAndNetwork() {
        let supportedTypes = [
            "public.jpeg", "public.png", "public.heic", "public.heif",
            "public.tiff", "org.webmproject.webp",
        ]
        for type in supportedTypes {
            XCTAssertTrue(
                PhotoKitPhotosLibraryAdapter.isSupportedStaticImage(
                    mediaType: .image,
                    mediaSubtypes: [],
                    uniformTypeIdentifier: type
                )
            )
        }
        XCTAssertFalse(
            PhotoKitPhotosLibraryAdapter.isSupportedStaticImage(
                mediaType: .video,
                mediaSubtypes: [],
                uniformTypeIdentifier: "public.jpeg"
            )
        )
        XCTAssertTrue(
            PhotoKitPhotosLibraryAdapter.isSupportedStaticImage(
                mediaType: .image,
                mediaSubtypes: .photoLive,
                uniformTypeIdentifier: "public.heic"
            )
        )
        XCTAssertFalse(PhotoKitPhotosLibraryAdapter.makeLocalOnlyImageRequestOptions().isNetworkAccessAllowed)
        let featureOptions = PhotoKitPhotosLibraryAdapter.makeLocalOnlyFeaturePrintRequestOptions()
        XCTAssertTrue(featureOptions.isSynchronous)
        XCTAssertFalse(featureOptions.isNetworkAccessAllowed)
    }

    func testPhotoKitCloudPreviewPolicyOnlyEnablesNetworkForExplicit2048Request() {
        let options = PhotoKitPhotosLibraryAdapter.makeCloudPreviewRequestOptions { _ in }

        XCTAssertTrue(options.isNetworkAccessAllowed)
        XCTAssertFalse(options.isSynchronous)
        XCTAssertEqual(PhotoKitPhotosLibraryAdapter.cloudPreviewTargetSize, NSSize(width: 2_048, height: 2_048))
        XCTAssertFalse(PhotoKitPhotosLibraryAdapter.makeLocalOnlyImageRequestOptions().isNetworkAccessAllowed)
        XCTAssertFalse(PhotoKitPhotosLibraryAdapter.makeLocalOnlyFeaturePrintRequestOptions().isNetworkAccessAllowed)
    }

    func testPhotoKitOriginalOpenPolicyEnablesNetworkOnlyForExplicitUserAction() {
        let options = PhotoKitPhotosLibraryAdapter.makeOriginalContentEditingInputRequestOptions()

        XCTAssertTrue(options.isNetworkAccessAllowed)
        XCTAssertFalse(PhotoKitPhotosLibraryAdapter.makeLocalOnlyImageRequestOptions().isNetworkAccessAllowed)
        XCTAssertFalse(PhotoKitPhotosLibraryAdapter.makeLocalOnlyFeaturePrintRequestOptions().isNetworkAccessAllowed)
    }

    func testIndexableStaticImageCountMatchesSupportedUTIPolicy() {
        // Startup full-repair heuristics compare this count to catalog rows.
        // Video must not inflate the library side of that ratio; RAW/GIF are now approved (ADR-041).
        let count = PhotoKitPhotosLibraryAdapter.indexableStaticImageCount(
            assets: [
                (.image, "public.heic"),
                (.image, "public.jpeg"),
                (.image, "public.png"),
                (.image, "com.adobe.raw-image"),
                (.image, "com.compuserve.gif"),
                (.image, "public.mpeg-4"),
                (.video, "public.mpeg-4"),
            ]
        )

        XCTAssertEqual(count, 5)
    }

    func testPersistentChangeBatchKeepsOnlyExplicitDeletes() {
        let resolved = metadata("photos-a", name: "A.HEIC", type: "public.heic")
        let batch = PhotoKitPhotosLibraryAdapter.makePersistentChangeBatch(
            upsertedAssets: [resolved],
            deletedLocalIdentifiers: ["photos-deleted", "photos-also-deleted"],
            changeToken: Data("photos-token".utf8)
        )

        XCTAssertEqual(batch.upsertedAssets.map(\.localIdentifier), ["photos-a"])
        XCTAssertEqual(batch.deletedLocalIdentifiers, ["photos-also-deleted", "photos-deleted"])
        XCTAssertFalse(batch.deletedLocalIdentifiers.contains("photos-unresolved-update"))
    }

    func testReconnectPreservesSyncCursorForIncrementalSync() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let access = FakePhotosLibraryAccess(state: .authorized)
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let firstJobID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let secondJobID = UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!
        let clock = FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let service = PhotosLibraryConnectionService(
            database: database,
            access: access,
            clock: clock,
            idGenerator: IDSequence([sourceID, firstJobID, secondJobID]).next
        )
        let token = Data("photos-token".utf8)

        _ = try await service.connect()
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET sync_cursor = ? WHERE id = ?",
                arguments: [token, sourceID.uuidString.lowercased()]
            )
        }

        let reconnect = try await service.connect()
        XCTAssertEqual(reconnect, .alreadyConnected(sourceID: sourceID))

        let cursor = try await database.pool.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT sync_cursor FROM source WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(cursor, token)
    }

    func testSyncNowPreservesCursorAndFullRepairClearsCursor() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let access = FakePhotosLibraryAccess(state: .authorized)
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let firstJobID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let secondJobID = UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!
        let clock = FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let service = PhotosLibraryConnectionService(
            database: database,
            access: access,
            clock: clock,
            idGenerator: IDSequence([sourceID, firstJobID, secondJobID]).next
        )
        let token = Data("photos-token".utf8)

        _ = try await service.connect()
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET sync_cursor = ? WHERE id = ?",
                arguments: [token, sourceID.uuidString.lowercased()]
            )
        }

        try service.syncNow(sourceID: sourceID)
        let cursorAfterSync = try await database.pool.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT sync_cursor FROM source WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(cursorAfterSync, token)

        try service.requestFullRepair(sourceID: sourceID)
        let cursorAfterRepair = try await database.pool.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT sync_cursor FROM source WHERE id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            )
        }
        XCTAssertNil(cursorAfterRepair)
    }

    func testSyncCursorWithoutCompletedFullScanRunsFullEnumeration() async throws {
        let first = metadata("photos-a", name: "A.HEIC", type: "public.heic")
        let second = metadata("photos-b", name: "B.PNG", type: "public.png")
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let access = FakePhotosLibraryAccess(
            state: .authorized,
            batches: [[first, second]]
        )
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let jobID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let clock = FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let connection = PhotosLibraryConnectionService(
            database: database,
            access: access,
            clock: clock,
            idGenerator: IDSequence([sourceID, jobID]).next
        )
        _ = try await connection.connect()
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET sync_cursor = ? WHERE id = ?",
                arguments: [Data("photos-token-1".utf8), sourceID.uuidString.lowercased()]
            )
        }

        let queue = GRDBJobQueue(database: database, clock: clock, retryPolicy: FixedDelayRetryPolicy(delayMs: 1_000))
        let handler = PhotosReconcileHandler(
            database: database,
            queue: queue,
            access: access,
            changeHistory: access,
            clock: clock
        )
        let coordinator = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [handler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )
        let claim = ClaimNextInput(
            owner: "photos-full-scan-without-history-test",
            leaseDurationMs: 60_000,
            allowedKinds: [PhotosReconcileJobFactory.kind]
        )
        XCTAssertEqual(try coordinator.claimAndExecuteOnce(claim)?.snapshot.state, .completed)

        let assetCount = try await database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM asset WHERE source_id = ?",
                arguments: [sourceID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(assetCount, 2)
    }

    func testIncrementalUpdateWithoutUpsertDoesNotMarkExistingAssetMissing() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let first = metadata("photos-a", name: "A.HEIC", type: "public.heic")
        let retainedWithoutUpsert = metadata("photos-b", name: "B.PNG", type: "public.png")
        let updated = metadata("photos-a", name: "A-UPDATED.HEIC", type: "public.heic")
        let oldToken = Data("photos-token-1".utf8)
        let newToken = Data("photos-token-2".utf8)
        let access = FakePhotosLibraryAccess(
            state: .authorized,
            batches: [[first, retainedWithoutUpsert]],
            persistentChanges: [
                PhotosPersistentChangeBatch(
                    upsertedAssets: [updated],
                    deletedLocalIdentifiers: [],
                    changeToken: newToken
                ),
            ]
        )
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let firstJobID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let secondJobID = UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!
        let clock = FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let connection = PhotosLibraryConnectionService(
            database: database,
            access: access,
            clock: clock,
            idGenerator: IDSequence([sourceID, firstJobID]).next
        )
        _ = try await connection.connect()

        let queue = GRDBJobQueue(database: database, clock: clock, retryPolicy: FixedDelayRetryPolicy(delayMs: 1_000))
        let fullScanHandler = PhotosReconcileHandler(database: database, queue: queue, access: access, clock: clock)
        let fullScanCoordinator = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [fullScanHandler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )
        let claim = ClaimNextInput(
            owner: "photos-unresolved-update-test",
            leaseDurationMs: 60_000,
            allowedKinds: [PhotosReconcileJobFactory.kind]
        )
        XCTAssertEqual(try fullScanCoordinator.claimAndExecuteOnce(claim)?.snapshot.state, .completed)
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET sync_cursor = ? WHERE id = ?",
                arguments: [oldToken, sourceID.uuidString.lowercased()]
            )
        }

        _ = try queue.enqueue(
            PhotosReconcileJobFactory.makeEnqueueCommand(
                jobID: secondJobID,
                sourceID: sourceID,
                notBeforeMs: clock.nowMs
            )
        )
        let incrementalHandler = PhotosReconcileHandler(
            database: database,
            queue: queue,
            access: access,
            changeHistory: access,
            clock: clock
        )
        let incrementalCoordinator = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [incrementalHandler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )
        XCTAssertEqual(try incrementalCoordinator.claimAndExecuteOnce(claim)?.snapshot.state, .completed)

        let assets = try await database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT photos_local_identifier, file_name, availability
                FROM asset WHERE source_id = ? ORDER BY photos_local_identifier
                """,
                arguments: [sourceID.uuidString.lowercased()]
            )
        }
        let byID = Dictionary(
            uniqueKeysWithValues: assets.compactMap { row -> (String, Row)? in
                guard let identifier: String = row["photos_local_identifier"] else { return nil }
                return (identifier, row)
            }
        )
        XCTAssertEqual(byID["photos-a"]?["file_name"] as String?, "A-UPDATED.HEIC")
        XCTAssertEqual(byID["photos-a"]?["availability"] as String?, AssetAvailability.available.rawValue)
        XCTAssertEqual(byID["photos-b"]?["file_name"] as String?, "B.PNG")
        XCTAssertEqual(byID["photos-b"]?["availability"] as String?, AssetAvailability.available.rawValue)
    }

    func testAuthorizedConnectionCreatesOnePhotosSourceAndOneActiveJob() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let access = FakePhotosLibraryAccess(state: .authorized)
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let jobID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let service = PhotosLibraryConnectionService(
            database: database,
            access: access,
            clock: FixedJobClock(nowMs: DatabaseTestSupport.timestampMs),
            idGenerator: IDSequence([sourceID, jobID]).next
        )

        let firstConnection = try await service.connect()
        XCTAssertEqual(firstConnection, .connected(sourceID: sourceID))

        let secondConnection = try await service.connect()
        XCTAssertEqual(secondConnection, .alreadyConnected(sourceID: sourceID))

        let evidence = try await database.pool.read { db in
            (
                sources: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source WHERE kind = 'photos'"),
                activeJobs: try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM job
                    WHERE kind = ? AND state IN ('pending', 'running', 'paused', 'retryableFailed')
                    """,
                    arguments: [PhotosReconcileJobFactory.kind]
                )
            )
        }
        XCTAssertEqual(evidence.sources, 1)
        XCTAssertEqual(evidence.activeJobs, 1)
    }

    func testDeniedConnectionCreatesNoSourceOrJob() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let service = PhotosLibraryConnectionService(
            database: database,
            access: FakePhotosLibraryAccess(state: .denied),
            clock: FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        )

        do {
            _ = try await service.connect()
            XCTFail("Expected authorization denial")
        } catch {
            XCTAssertEqual(error as? PhotosLibraryError, .authorizationDenied)
        }

        let counts = try await database.pool.read { db in
            (
                sources: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source") ?? -1,
                jobs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job") ?? -1
            )
        }
        XCTAssertEqual(counts.sources, 0)
        XCTAssertEqual(counts.jobs, 0)
    }

    func testAuthorizationFailureDuringReconcileMarksPhotosSourceForReauthorization() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let jobID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let clock = FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let connection = PhotosLibraryConnectionService(
            database: database,
            access: FakePhotosLibraryAccess(state: .authorized),
            clock: clock,
            idGenerator: IDSequence([sourceID, jobID]).next
        )
        _ = try await connection.connect()

        let queue = GRDBJobQueue(
            database: database,
            clock: clock,
            retryPolicy: FixedDelayRetryPolicy(delayMs: 1_000)
        )
        let handler = PhotosReconcileHandler(
            database: database,
            queue: queue,
            access: FakePhotosLibraryAccess(state: .denied),
            clock: clock
        )
        let coordinator = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [handler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )

        _ = try coordinator.claimAndExecuteOnce(
            ClaimNextInput(
                owner: "photos-authorization-test",
                leaseDurationMs: 60_000,
                allowedKinds: [PhotosReconcileJobFactory.kind]
            )
        )

        XCTAssertEqual(try connection.fetchSources().first?.state, .authorizationRequired)
    }

    func testReconcilePublishesTwoMetadataBatchesAndSourceFilteringFindsThem() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let access = FakePhotosLibraryAccess(
            state: .authorized,
            batches: [
                [metadata("photos-a", name: "A.HEIC", type: "public.heic")],
                [
                    metadata("photos-b", name: "B.PNG", type: "public.png"),
                    metadata("photos-c", name: "C.WEBP", type: "org.webmproject.webp"),
                ],
            ]
        )
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let jobID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let clock = FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let connection = PhotosLibraryConnectionService(
            database: database,
            access: access,
            clock: clock,
            idGenerator: IDSequence([sourceID, jobID]).next
        )
        _ = try await connection.connect()

        let queue = GRDBJobQueue(database: database, clock: clock, retryPolicy: FixedDelayRetryPolicy(delayMs: 1_000))
        let handler = PhotosReconcileHandler(database: database, queue: queue, access: access, clock: clock)
        let coordinator = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [handler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )
        let result = try coordinator.claimAndExecuteOnce(
            ClaimNextInput(owner: "photos-test", leaseDurationMs: 60_000, allowedKinds: [PhotosReconcileJobFactory.kind])
        )
        XCTAssertEqual(result?.snapshot.state, .completed)

        let query = GRDBAssetCatalogQueryRepository(database: database)
        let all = try query.fetchAssetPage(
            AssetPageRequest(filter: AssetPageFilter(), sort: .newest, cursor: nil, limit: 100)
        )
        let photosOnly = try query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(sourceIDs: [sourceID]),
                sort: .newest,
                cursor: nil,
                limit: 100
            )
        )
        XCTAssertEqual(all.items.map(\.fileName).sorted { ($0 ?? "") < ($1 ?? "") }, ["A.HEIC", "B.PNG", "C.WEBP"])
        XCTAssertEqual(photosOnly.items.count, 3)
        XCTAssertEqual(Set(photosOnly.items.map(\.sourceID)), [sourceID])
    }

    func testReconcileUsesPersistedChangeCursorForIncrementalAssetChanges() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let first = metadata("photos-a", name: "A.HEIC", type: "public.heic")
        let removed = metadata("photos-b", name: "B.PNG", type: "public.png")
        let inserted = metadata("photos-c", name: "C.WEBP", type: "org.webmproject.webp")
        let updated = metadata("photos-a", name: "A-UPDATED.HEIC", type: "public.heic")
        let oldToken = Data("photos-token-1".utf8)
        let newToken = Data("photos-token-2".utf8)
        let access = FakePhotosLibraryAccess(
            state: .authorized,
            batches: [[first, removed]],
            persistentChanges: [
                PhotosPersistentChangeBatch(
                    upsertedAssets: [updated, inserted],
                    deletedLocalIdentifiers: [removed.localIdentifier],
                    changeToken: newToken
                ),
            ]
        )
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let firstJobID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let secondJobID = UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!
        let clock = FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let connection = PhotosLibraryConnectionService(
            database: database,
            access: access,
            clock: clock,
            idGenerator: IDSequence([sourceID, firstJobID]).next
        )
        _ = try await connection.connect()

        let queue = GRDBJobQueue(database: database, clock: clock, retryPolicy: FixedDelayRetryPolicy(delayMs: 1_000))
        let fullScanHandler = PhotosReconcileHandler(database: database, queue: queue, access: access, clock: clock)
        let fullScanCoordinator = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [fullScanHandler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )
        let claim = ClaimNextInput(
            owner: "photos-change-history-test",
            leaseDurationMs: 60_000,
            allowedKinds: [PhotosReconcileJobFactory.kind]
        )
        XCTAssertEqual(try fullScanCoordinator.claimAndExecuteOnce(claim)?.snapshot.state, .completed)
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET sync_cursor = ? WHERE id = ?",
                arguments: [oldToken, sourceID.uuidString.lowercased()]
            )
        }

        _ = try queue.enqueue(
            PhotosReconcileJobFactory.makeEnqueueCommand(
                jobID: secondJobID,
                sourceID: sourceID,
                notBeforeMs: clock.nowMs
            )
        )
        let incrementalHandler = PhotosReconcileHandler(
            database: database,
            queue: queue,
            access: access,
            changeHistory: access,
            clock: clock
        )
        let incrementalCoordinator = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [incrementalHandler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )
        XCTAssertEqual(try incrementalCoordinator.claimAndExecuteOnce(claim)?.snapshot.state, .completed)

        let evidence = try await database.pool.read { db in
            (
                assets: try Row.fetchAll(
                    db,
                    sql: """
                    SELECT photos_local_identifier, file_name, availability, content_revision
                    FROM asset WHERE source_id = ? ORDER BY photos_local_identifier
                    """,
                    arguments: [sourceID.uuidString.lowercased()]
                ),
                cursor: try Data.fetchOne(
                    db,
                    sql: "SELECT sync_cursor FROM source WHERE id = ?",
                    arguments: [sourceID.uuidString.lowercased()]
                )
            )
        }
        XCTAssertEqual(evidence.assets.count, 3)
        let assetsByIdentifier = Dictionary(
            uniqueKeysWithValues: evidence.assets.compactMap { row -> (String, Row)? in
                guard let identifier: String = row["photos_local_identifier"] else { return nil }
                return (identifier, row)
            }
        )
        XCTAssertEqual(assetsByIdentifier["photos-a"]?["file_name"] as String?, "A-UPDATED.HEIC")
        XCTAssertEqual(
            assetsByIdentifier["photos-a"]?["availability"] as String?,
            AssetAvailability.available.rawValue
        )
        XCTAssertEqual(assetsByIdentifier["photos-a"]?["content_revision"] as Int?, 2)
        XCTAssertEqual(
            assetsByIdentifier["photos-b"]?["availability"] as String?,
            AssetAvailability.missing.rawValue
        )
        XCTAssertEqual(assetsByIdentifier["photos-c"]?["file_name"] as String?, "C.WEBP")
        XCTAssertEqual(
            assetsByIdentifier["photos-c"]?["availability"] as String?,
            AssetAvailability.available.rawValue
        )
        XCTAssertEqual(evidence.cursor, newToken)
        XCTAssertEqual(access.enumerationStartOffsets, [0])
        XCTAssertEqual(access.requestedChangeTokens, [oldToken])
    }

    func testInvalidChangeCursorFallsBackToFullGenerationBeforeMarkingMissing() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let retained = metadata("photos-a", name: "A.HEIC", type: "public.heic")
        let removed = metadata("photos-b", name: "B.PNG", type: "public.png")
        let changedDuringScan = metadata("photos-c", name: "C.WEBP", type: "org.webmproject.webp")
        let invalidToken = Data("photos-expired-token".utf8)
        let replacementToken = Data("photos-replacement-token".utf8)
        let replayedToken = Data("photos-replayed-token".utf8)
        let access = FakePhotosLibraryAccess(
            state: .authorized,
            batches: [[retained, removed]],
            persistentChanges: [
                PhotosPersistentChangeBatch(
                    upsertedAssets: [changedDuringScan],
                    deletedLocalIdentifiers: [],
                    changeToken: replayedToken
                ),
            ],
            currentChangeToken: replacementToken,
            invalidChangeTokens: [invalidToken]
        )
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let firstJobID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let secondJobID = UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!
        let clock = FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let connection = PhotosLibraryConnectionService(
            database: database,
            access: access,
            clock: clock,
            idGenerator: IDSequence([sourceID, firstJobID]).next
        )
        _ = try await connection.connect()
        let queue = GRDBJobQueue(database: database, clock: clock, retryPolicy: FixedDelayRetryPolicy(delayMs: 1_000))
        let fullScanHandler = PhotosReconcileHandler(database: database, queue: queue, access: access, clock: clock)
        let fullScanCoordinator = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [fullScanHandler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )
        let claim = ClaimNextInput(
            owner: "photos-invalid-token-test",
            leaseDurationMs: 60_000,
            allowedKinds: [PhotosReconcileJobFactory.kind]
        )
        XCTAssertEqual(try fullScanCoordinator.claimAndExecuteOnce(claim)?.snapshot.state, .completed)
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET sync_cursor = ? WHERE id = ?",
                arguments: [invalidToken, sourceID.uuidString.lowercased()]
            )
        }
        access.configure(batches: [[retained]], failAfterBatches: false)
        _ = try queue.enqueue(
            PhotosReconcileJobFactory.makeEnqueueCommand(
                jobID: secondJobID,
                sourceID: sourceID,
                notBeforeMs: clock.nowMs
            )
        )

        let recoveryHandler = PhotosReconcileHandler(
            database: database,
            queue: queue,
            access: access,
            changeHistory: access,
            clock: clock
        )
        let recoveryCoordinator = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [recoveryHandler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )
        XCTAssertEqual(try recoveryCoordinator.claimAndExecuteOnce(claim)?.snapshot.state, .completed)

        let evidence = try await database.pool.read { db in
            (
                availability: try String.fetchOne(
                    db,
                    sql: "SELECT availability FROM asset WHERE photos_local_identifier = 'photos-b'"
                ),
                cursor: try Data.fetchOne(
                    db,
                    sql: "SELECT sync_cursor FROM source WHERE id = ?",
                    arguments: [sourceID.uuidString.lowercased()]
                ),
                replayedAssetCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM asset WHERE photos_local_identifier = 'photos-c'"
                )
            )
        }
        XCTAssertEqual(evidence.availability, AssetAvailability.missing.rawValue)
        XCTAssertEqual(evidence.cursor, replayedToken)
        XCTAssertEqual(evidence.replayedAssetCount, 1)
        XCTAssertEqual(access.enumerationStartOffsets, [0, 0])
        XCTAssertEqual(access.requestedChangeTokens, [invalidToken, replacementToken])
    }

    func testPhotoLibraryObserverOnlyCoalescesOneReconcileJob() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let access = FakePhotosLibraryAccess(state: .authorized)
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let firstJobID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let observedJobID = UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!
        let clock = FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let connection = PhotosLibraryConnectionService(
            database: database,
            access: access,
            clock: clock,
            idGenerator: IDSequence([sourceID, firstJobID]).next
        )
        _ = try await connection.connect()
        let queue = GRDBJobQueue(database: database, clock: clock, retryPolicy: FixedDelayRetryPolicy(delayMs: 1_000))
        let handler = PhotosReconcileHandler(database: database, queue: queue, access: access, clock: clock)
        let coordinator = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [handler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )
        let claim = ClaimNextInput(
            owner: "photos-observer-test",
            leaseDurationMs: 60_000,
            allowedKinds: [PhotosReconcileJobFactory.kind]
        )
        XCTAssertEqual(try coordinator.claimAndExecuteOnce(claim)?.snapshot.state, .completed)

        let observer = FakePhotosChangeObserver()
        let notifications = PhotosObserverNotificationRecorder()
        let changeCoordinator = PhotosLibraryChangeObserverCoordinator(
            observer: observer,
            database: database,
            clock: clock,
            idGenerator: IDSequence([observedJobID]).next
        )
        changeCoordinator.start {
            notifications.record()
        }
        observer.emitChange()
        observer.emitChange()
        changeCoordinator.stop()
        observer.emitChange()

        let evidence = try await database.pool.read { db in
            (
                activeJobs: try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM job
                    WHERE kind = ? AND state IN ('pending', 'running', 'paused', 'retryableFailed')
                    """,
                    arguments: [PhotosReconcileJobFactory.kind]
                ),
                assets: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset")
            )
        }
        XCTAssertEqual(evidence.activeJobs, 1)
        XCTAssertEqual(evidence.assets, 0)
        XCTAssertEqual(notifications.count, 3)
    }

    func testPhotoLibraryObserverStartupQueuesCatchUpWithoutFabricatingAChangeEvent() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let access = FakePhotosLibraryAccess(state: .authorized)
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let firstJobID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let startupJobID = UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!
        let clock = FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let connection = PhotosLibraryConnectionService(
            database: database,
            access: access,
            clock: clock,
            idGenerator: IDSequence([sourceID, firstJobID]).next
        )
        _ = try await connection.connect()

        let queue = GRDBJobQueue(database: database, clock: clock, retryPolicy: FixedDelayRetryPolicy(delayMs: 1_000))
        let handler = PhotosReconcileHandler(database: database, queue: queue, access: access, clock: clock)
        let execution = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [handler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )
        let claim = ClaimNextInput(
            owner: "photos-startup-catch-up-test",
            leaseDurationMs: 60_000,
            allowedKinds: [PhotosReconcileJobFactory.kind]
        )
        XCTAssertEqual(try execution.claimAndExecuteOnce(claim)?.snapshot.state, .completed)

        PhotosLibraryChangeObserverCoordinator(
            observer: FakePhotosChangeObserver(),
            database: database,
            clock: clock,
            idGenerator: IDSequence([startupJobID]).next
        ).start()

        let evidence = try await database.pool.read { db in
            (
                activeJobs: try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM job
                    WHERE kind = ? AND state IN ('pending', 'running', 'paused', 'retryableFailed')
                    """,
                    arguments: [PhotosReconcileJobFactory.kind]
                ),
                dirtyEpoch: try Int.fetchOne(
                    db,
                    sql: "SELECT dirty_epoch FROM source WHERE id = ?",
                    arguments: [sourceID.uuidString.lowercased()]
                )
            )
        }
        XCTAssertEqual(evidence.activeJobs, 1)
        XCTAssertEqual(evidence.dirtyEpoch, 0)
    }

    func testPhotoLibraryObserverDoesNotNotifyWithoutActivePhotosSource() throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let observer = FakePhotosChangeObserver()
        let notifications = PhotosObserverNotificationRecorder()
        PhotosLibraryChangeObserverCoordinator(
            observer: observer,
            database: database
        ).start {
            notifications.record()
        }

        observer.emitChange()

        XCTAssertEqual(notifications.count, 0)
        let jobCount = try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM job WHERE kind = ?",
                arguments: [PhotosReconcileJobFactory.kind]
            )
        }
        XCTAssertEqual(jobCount, 0)
    }

    func testPhotoLibraryUnavailabilitySuspendsSourceWithoutChangingAssetFacts() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let assetID = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
        let clock = FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let connection = PhotosLibraryConnectionService(
            database: database,
            access: FakePhotosLibraryAccess(state: .authorized),
            clock: clock,
            idGenerator: IDSequence([
                sourceID,
                UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            ]).next
        )
        _ = try await connection.connect()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    media_type, availability, record_created_at_ms, record_updated_at_ms, file_name
                ) VALUES (?, ?, 'photos', NULL, 'photos-existing', 'public.jpeg', 'available', ?, ?, 'Existing.jpg')
                """,
                arguments: [
                    assetID.uuidString.lowercased(), sourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs,
                ]
            )
        }

        let changes = FakePhotosChangeObserver()
        let availability = FakePhotosAvailabilityObserver()
        let notifications = PhotosObserverNotificationRecorder()
        let coordinator = PhotosLibraryChangeObserverCoordinator(
            observer: changes,
            availabilityObserver: availability,
            database: database,
            clock: clock
        )
        coordinator.start { notifications.record() }
        let notificationsBeforeLoss = notifications.count

        availability.emit(.systemLibrarySwitch)

        let evidence = try await database.pool.read { db in
            (
                sourceState: try String.fetchOne(
                    db,
                    sql: "SELECT state FROM source WHERE id = ?",
                    arguments: [sourceID.uuidString.lowercased()]
                ),
                assetAvailability: try String.fetchOne(
                    db,
                    sql: "SELECT availability FROM asset WHERE id = ?",
                    arguments: [assetID.uuidString.lowercased()]
                ),
                activeJobs: try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM job
                    WHERE source_id = ? AND kind = ?
                        AND state IN ('pending', 'running', 'paused', 'retryableFailed')
                    """,
                    arguments: [sourceID.uuidString.lowercased(), PhotosReconcileJobFactory.kind]
                )
            )
        }
        XCTAssertEqual(evidence.sourceState, SourceState.unavailable.rawValue)
        XCTAssertEqual(evidence.assetAvailability, AssetAvailability.available.rawValue)
        XCTAssertEqual(evidence.activeJobs, 0)
        XCTAssertEqual(notifications.count, notificationsBeforeLoss + 1)
    }

    func testUnavailablePhotosSourceCannotBeSilentlyReactivatedByConnect() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let clock = FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let connection = PhotosLibraryConnectionService(
            database: database,
            access: FakePhotosLibraryAccess(state: .authorized),
            clock: clock,
            idGenerator: IDSequence([
                sourceID,
                UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            ]).next
        )
        _ = try await connection.connect()
        let availability = FakePhotosAvailabilityObserver()
        PhotosLibraryChangeObserverCoordinator(
            observer: FakePhotosChangeObserver(),
            availabilityObserver: availability,
            database: database,
            clock: clock
        ).start()
        availability.emit(.systemLibrarySwitch)

        do {
            _ = try await connection.connect()
            XCTFail("Expected unavailable source to require an explicit future rebind flow")
        } catch {
            XCTAssertEqual(error as? PhotosLibraryError, .libraryUnavailable)
        }

        let deniedConnection = PhotosLibraryConnectionService(
            database: database,
            access: FakePhotosLibraryAccess(state: .denied),
            clock: clock
        )
        do {
            _ = try await deniedConnection.connect()
            XCTFail("Expected unavailable source state to take precedence over authorization changes")
        } catch {
            XCTAssertEqual(error as? PhotosLibraryError, .libraryUnavailable)
        }

        let evidence = try await database.pool.read { db in
            (
                sourceState: try String.fetchOne(
                    db,
                    sql: "SELECT state FROM source WHERE id = ?",
                    arguments: [sourceID.uuidString.lowercased()]
                ),
                activeJobs: try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM job
                    WHERE source_id = ? AND kind = ?
                        AND state IN ('pending', 'running', 'paused', 'retryableFailed')
                    """,
                    arguments: [sourceID.uuidString.lowercased(), PhotosReconcileJobFactory.kind]
                )
            )
        }
        XCTAssertEqual(evidence.sourceState, SourceState.unavailable.rawValue)
        XCTAssertEqual(evidence.activeJobs, 0)
    }

    func testConnectRechecksUnavailableSourceAfterAuthorizationWait() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let unavailableSourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let access = SuspendedPhotosAuthorizationAccess()
        let service = PhotosLibraryConnectionService(
            database: database,
            access: access,
            clock: FixedJobClock(nowMs: DatabaseTestSupport.timestampMs),
            idGenerator: IDSequence([
                UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
                UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            ]).next
        )

        let connection = Task { try await service.connect() }
        for _ in 0 ..< 10_000 where !access.hasPendingRequest {
            await Task.yield()
        }
        XCTAssertTrue(access.hasPendingRequest)
        try await database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, state, created_at_ms, updated_at_ms
                ) VALUES (?, 'photos', 'Apple Photos', NULL, 'unavailable', ?, ?)
                """,
                arguments: [
                    unavailableSourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        }
        access.resumeAuthorization(with: .authorized)

        do {
            _ = try await connection.value
            XCTFail("Expected the transaction recheck to require explicit rebind")
        } catch {
            XCTAssertEqual(error as? PhotosLibraryError, .libraryUnavailable)
        }

        let evidence = try await database.pool.read { db in
            (
                photosSourceCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM source WHERE kind = 'photos'"
                ),
                activeSourceCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM source WHERE kind = 'photos' AND state = 'active'"
                ),
                jobCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job")
            )
        }
        XCTAssertEqual(evidence.photosSourceCount, 1)
        XCTAssertEqual(evidence.activeSourceCount, 0)
        XCTAssertEqual(evidence.jobCount, 0)
    }

    func testExplicitRebindCreatesDistinctActiveSourceAndPreservesHistoricalFacts() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let historicalSourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let historicalJobID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let historicalAssetID = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
        let tagID = UUID(uuidString: "44444444-5555-6666-7777-888888888888")!
        let activeSourceID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let activeJobID = UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!
        let activeAssetID = UUID(uuidString: "55555555-6666-7777-8888-999999999999")!
        let clock = FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let connection = PhotosLibraryConnectionService(
            database: database,
            access: FakePhotosLibraryAccess(state: .authorized),
            clock: clock,
            idGenerator: IDSequence([
                historicalSourceID,
                historicalJobID,
                activeSourceID,
                activeJobID,
            ]).next
        )
        _ = try await connection.connect()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    media_type, availability, record_created_at_ms, record_updated_at_ms, file_name
                ) VALUES (?, ?, 'photos', NULL, 'shared-local-identifier', 'public.jpeg',
                          'available', ?, ?, 'Historical.jpg')
                """,
                arguments: [
                    historicalAssetID.uuidString.lowercased(),
                    historicalSourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES (?, 'Keep', 'keep', 'active', ?, ?)
                """,
                arguments: [
                    tagID.uuidString.lowercased(),
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
                    historicalAssetID.uuidString.lowercased(),
                    tagID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                ]
            )
            try db.execute(
                sql: "UPDATE source SET state = 'unavailable' WHERE id = ?",
                arguments: [historicalSourceID.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE job SET state = 'cancelled' WHERE id = ?",
                arguments: [historicalJobID.uuidString.lowercased()]
            )
        }

        let outcome = try await connection.rebind(unavailableSourceID: historicalSourceID)
        XCTAssertEqual(
            outcome,
            .rebound(previousSourceID: historicalSourceID, sourceID: activeSourceID)
        )
        do {
            _ = try await connection.rebind(unavailableSourceID: historicalSourceID)
            XCTFail("Expected the existing active Photos source to block a second rebind")
        } catch {
            XCTAssertEqual(error as? PhotosLibraryError, .libraryUnavailable)
        }

        try await database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    media_type, availability, record_created_at_ms, record_updated_at_ms, file_name
                ) VALUES (?, ?, 'photos', NULL, 'shared-local-identifier', 'public.jpeg',
                          'available', ?, ?, 'Current.jpg')
                """,
                arguments: [
                    activeAssetID.uuidString.lowercased(),
                    activeSourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        }

        let evidence = try await database.pool.read { db in
            (
                photosSourceCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM source WHERE kind = 'photos'"
                ),
                activeSourceCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM source WHERE kind = 'photos' AND state = 'active'"
                ),
                historicalState: try String.fetchOne(
                    db,
                    sql: "SELECT state FROM source WHERE id = ?",
                    arguments: [historicalSourceID.uuidString.lowercased()]
                ),
                historicalAssetCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM asset WHERE id = ? AND source_id = ?",
                    arguments: [
                        historicalAssetID.uuidString.lowercased(),
                        historicalSourceID.uuidString.lowercased(),
                    ]
                ),
                historicalDecisionCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM asset_tag_decision WHERE asset_id = ? AND tag_id = ?",
                    arguments: [
                        historicalAssetID.uuidString.lowercased(),
                        tagID.uuidString.lowercased(),
                    ]
                ),
                sharedIdentifierCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM asset WHERE photos_local_identifier = 'shared-local-identifier'"
                ),
                newActiveJobCount: try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM job
                    WHERE id = ? AND source_id = ? AND state = 'pending'
                    """,
                    arguments: [
                        activeJobID.uuidString.lowercased(),
                        activeSourceID.uuidString.lowercased(),
                    ]
                )
            )
        }
        XCTAssertEqual(evidence.photosSourceCount, 2)
        XCTAssertEqual(evidence.activeSourceCount, 1)
        XCTAssertEqual(evidence.historicalState, SourceState.unavailable.rawValue)
        XCTAssertEqual(evidence.historicalAssetCount, 1)
        XCTAssertEqual(evidence.historicalDecisionCount, 1)
        XCTAssertEqual(evidence.sharedIdentifierCount, 2)
        XCTAssertEqual(evidence.newActiveJobCount, 1)
    }

    func testConnectReusesCurrentActiveSourceWhenHistoricalUnavailableSourceExists() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let historicalSourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let activeSourceID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        try await database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, state, created_at_ms, updated_at_ms
                ) VALUES (?, 'photos', 'Apple Photos', NULL, 'unavailable', ?, ?),
                         (?, 'photos', 'Apple Photos', NULL, 'active', ?, ?)
                """,
                arguments: [
                    historicalSourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                    activeSourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs + 1,
                    DatabaseTestSupport.timestampMs + 1,
                ]
            )
        }
        let service = PhotosLibraryConnectionService(
            database: database,
            access: FakePhotosLibraryAccess(state: .authorized),
            clock: FixedJobClock(nowMs: DatabaseTestSupport.timestampMs + 2),
            idGenerator: IDSequence([
                UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!,
            ]).next
        )

        let outcome = try await service.connect()

        XCTAssertEqual(outcome, .alreadyConnected(sourceID: activeSourceID))
        let states = try await database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, state FROM source WHERE kind = 'photos' ORDER BY created_at_ms"
            )
        }
        XCTAssertEqual(states.map { $0["id"] as String }, [
            historicalSourceID.uuidString.lowercased(),
            activeSourceID.uuidString.lowercased(),
        ])
        XCTAssertEqual(states.map { $0["state"] as String }, [
            SourceState.unavailable.rawValue,
            SourceState.active.rawValue,
        ])
    }

    func testAuthorizationFailureDoesNotRewriteHistoricalUnavailableSource() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let historicalSourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let activeSourceID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        try await database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, state, created_at_ms, updated_at_ms
                ) VALUES (?, 'photos', 'Apple Photos', NULL, 'unavailable', ?, ?),
                         (?, 'photos', 'Apple Photos', NULL, 'active', ?, ?)
                """,
                arguments: [
                    historicalSourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                    activeSourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs + 1,
                    DatabaseTestSupport.timestampMs + 1,
                ]
            )
        }
        let service = PhotosLibraryConnectionService(
            database: database,
            access: FakePhotosLibraryAccess(state: .denied),
            clock: FixedJobClock(nowMs: DatabaseTestSupport.timestampMs + 2)
        )

        do {
            _ = try await service.connect()
            XCTFail("Expected authorization denial")
        } catch {
            XCTAssertEqual(error as? PhotosLibraryError, .authorizationDenied)
        }

        let states = try await database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, state FROM source WHERE kind = 'photos' ORDER BY created_at_ms"
            )
        }
        XCTAssertEqual(states.map { $0["id"] as String }, [
            historicalSourceID.uuidString.lowercased(),
            activeSourceID.uuidString.lowercased(),
        ])
        XCTAssertEqual(states.map { $0["state"] as String }, [
            SourceState.unavailable.rawValue,
            SourceState.authorizationRequired.rawValue,
        ])
    }

    func testLibrarySwitchDuringFullReconcileCancelsWithoutPublishingAssetFacts() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let newAsset = metadata("photos-new", name: "New.HEIC", type: "public.heic")
        let access = FakePhotosLibraryAccess(state: .authorized, batches: [[newAsset]])
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let existingAssetID = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
        let clock = FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let connection = PhotosLibraryConnectionService(
            database: database,
            access: access,
            clock: clock,
            idGenerator: IDSequence([
                sourceID,
                UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            ]).next
        )
        _ = try await connection.connect()
        try await database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    media_type, availability, record_created_at_ms, record_updated_at_ms, file_name
                ) VALUES (?, ?, 'photos', NULL, 'photos-existing', 'public.jpeg', 'available', ?, ?, 'Existing.jpg')
                """,
                arguments: [
                    existingAssetID.uuidString.lowercased(), sourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs,
                ]
            )
        }

        let availability = FakePhotosAvailabilityObserver()
        PhotosLibraryChangeObserverCoordinator(
            observer: FakePhotosChangeObserver(),
            availabilityObserver: availability,
            database: database,
            clock: clock
        ).start()
        access.configureOnEnumerationStart { availability.emit(.systemLibrarySwitch) }

        let queue = GRDBJobQueue(
            database: database,
            clock: clock,
            retryPolicy: FixedDelayRetryPolicy(delayMs: 1_000)
        )
        let handler = PhotosReconcileHandler(database: database, queue: queue, access: access, clock: clock)
        let execution = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [handler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )
        let result = try execution.claimAndExecuteOnce(
            ClaimNextInput(
                owner: "photos-library-switch-test",
                leaseDurationMs: 60_000,
                allowedKinds: [PhotosReconcileJobFactory.kind]
            )
        )

        let evidence = try await database.pool.read { db in
            (
                sourceState: try String.fetchOne(
                    db,
                    sql: "SELECT state FROM source WHERE id = ?",
                    arguments: [sourceID.uuidString.lowercased()]
                ),
                existingAvailability: try String.fetchOne(
                    db,
                    sql: "SELECT availability FROM asset WHERE id = ?",
                    arguments: [existingAssetID.uuidString.lowercased()]
                ),
                newAssetCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM asset WHERE photos_local_identifier = 'photos-new'"
                )
            )
        }
        XCTAssertEqual(result?.snapshot.state, .cancelled)
        XCTAssertEqual(evidence.sourceState, SourceState.unavailable.rawValue)
        XCTAssertEqual(evidence.existingAvailability, AssetAvailability.available.rawValue)
        XCTAssertEqual(evidence.newAssetCount, 0)
    }

    func testPhotoLibraryChangeDuringReconcileQueuesOneFollowUpJob() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let access = FakePhotosLibraryAccess(
            state: .authorized,
            batches: [[metadata("photos-a", name: "A.HEIC", type: "public.heic")]]
        )
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let firstJobID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let clock = FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let connection = PhotosLibraryConnectionService(
            database: database,
            access: access,
            clock: clock,
            idGenerator: IDSequence([sourceID, firstJobID]).next
        )
        _ = try await connection.connect()

        let observer = FakePhotosChangeObserver()
        PhotosLibraryChangeObserverCoordinator(
            observer: observer,
            database: database,
            clock: clock
        ).start()
        access.configureOnEnumerationStart { observer.emitChange() }

        let queue = GRDBJobQueue(database: database, clock: clock, retryPolicy: FixedDelayRetryPolicy(delayMs: 1_000))
        let handler = PhotosReconcileHandler(database: database, queue: queue, access: access, clock: clock)
        let coordinator = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [handler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )
        let claim = ClaimNextInput(
            owner: "photos-observer-race-test",
            leaseDurationMs: 60_000,
            allowedKinds: [PhotosReconcileJobFactory.kind]
        )
        XCTAssertEqual(try coordinator.claimAndExecuteOnce(claim)?.snapshot.state, .completed)

        let evidence = try await database.pool.read { db in
            (
                activeJobs: try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM job
                    WHERE kind = ? AND state IN ('pending', 'running', 'paused', 'retryableFailed')
                    """,
                    arguments: [PhotosReconcileJobFactory.kind]
                ),
                totalJobs: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM job WHERE kind = ?",
                    arguments: [PhotosReconcileJobFactory.kind]
                )
            )
        }
        XCTAssertEqual(evidence.activeJobs, 1)
        XCTAssertEqual(evidence.totalJobs, 2)
    }

    func testInterruptedReconcileDoesNotMarkUnseenAssetsMissingUntilSuccessfulResume() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let first = metadata("photos-a", name: "A.HEIC", type: "public.heic")
        let second = metadata("photos-b", name: "B.PNG", type: "public.png")
        let access = FakePhotosLibraryAccess(state: .authorized, batches: [[first, second]])
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let clock = MutableJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let connection = PhotosLibraryConnectionService(
            database: database,
            access: access,
            clock: clock,
            idGenerator: IDSequence([
                sourceID,
                UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            ]).next
        )
        _ = try await connection.connect()

        let queue = GRDBJobQueue(database: database, clock: clock, retryPolicy: FixedDelayRetryPolicy(delayMs: 1_000))
        let handler = PhotosReconcileHandler(database: database, queue: queue, access: access, clock: clock)
        let coordinator = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [handler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )
        let claim = ClaimNextInput(
            owner: "photos-interruption-test",
            leaseDurationMs: 60_000,
            allowedKinds: [PhotosReconcileJobFactory.kind]
        )
        XCTAssertEqual(try coordinator.claimAndExecuteOnce(claim)?.snapshot.state, .completed)

        _ = try queue.enqueue(
            PhotosReconcileJobFactory.makeEnqueueCommand(
                jobID: UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!,
                sourceID: sourceID,
                notBeforeMs: clock.nowMs
            )
        )
        access.configure(batches: [[first]], failAfterBatches: true)
        XCTAssertEqual(try coordinator.claimAndExecuteOnce(claim)?.snapshot.state, .retryableFailed)

        let afterFailure = try await availabilityByName(database)
        XCTAssertEqual(afterFailure["A.HEIC"], .available)
        XCTAssertEqual(afterFailure["B.PNG"], .available)

        access.configure(batches: [[first]], failAfterBatches: false)
        clock.setNowMs(clock.nowMs + 1_000)
        try queue.settleRetryableJobs()
        XCTAssertEqual(try coordinator.claimAndExecuteOnce(claim)?.snapshot.state, .completed)

        let afterCompletion = try await availabilityByName(database)
        XCTAssertEqual(afterCompletion["A.HEIC"], .available)
        XCTAssertEqual(afterCompletion["B.PNG"], .missing)
    }

    func testInterruptedReconcileResumesAtPersistedPhotoKitOffsetAndReportsTotal() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let first = metadata("photos-a", name: "A.HEIC", type: "public.heic")
        let second = metadata("photos-b", name: "B.PNG", type: "public.png")
        let third = metadata("photos-c", name: "C.WEBP", type: "org.webmproject.webp")
        let access = FakePhotosLibraryAccess(state: .authorized, batches: [[first]])
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let clock = MutableJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let connection = PhotosLibraryConnectionService(
            database: database,
            access: access,
            clock: clock,
            idGenerator: IDSequence([
                sourceID,
                UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            ]).next
        )
        _ = try await connection.connect()

        let queue = GRDBJobQueue(database: database, clock: clock, retryPolicy: FixedDelayRetryPolicy(delayMs: 1_000))
        let handler = PhotosReconcileHandler(database: database, queue: queue, access: access, clock: clock, batchSize: 1)
        let coordinator = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [handler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )
        let claim = ClaimNextInput(
            owner: "photos-resume-test",
            leaseDurationMs: 60_000,
            allowedKinds: [PhotosReconcileJobFactory.kind]
        )

        access.configure(batches: [[first]], failAfterBatches: true)
        XCTAssertEqual(try coordinator.claimAndExecuteOnce(claim)?.snapshot.state, .retryableFailed)

        access.configure(batches: [[first], [second], [third]], failAfterBatches: false)
        clock.setNowMs(clock.nowMs + 1_000)
        try queue.settleRetryableJobs()
        let resumed = try coordinator.claimAndExecuteOnce(claim)?.snapshot

        XCTAssertEqual(access.enumerationStartOffsets, [0, 1])
        XCTAssertEqual(resumed?.state, .completed)
        XCTAssertEqual(resumed?.progress, JobProgress(completed: 3, total: 3))
    }

    func testDefaultPhotosReconcileRenewsLeaseDuringSlowMetadataEnumeration() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let jobID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let clock = MutableJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let access = LeaseAdvancingPhotosLibraryAccess(
            assetCount: 5,
            elapsedMsPerAsset: 13_000,
            clock: clock
        )
        let connection = PhotosLibraryConnectionService(
            database: database,
            access: access,
            clock: clock,
            idGenerator: IDSequence([sourceID, jobID]).next
        )
        _ = try await connection.connect()

        let queue = GRDBJobQueue(
            database: database,
            clock: clock,
            retryPolicy: FixedDelayRetryPolicy(delayMs: 1_000)
        )
        let handler = PhotosReconcileHandler(
            database: database,
            queue: queue,
            access: access,
            clock: clock
        )
        let coordinator = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [handler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )

        let result = try coordinator.claimAndExecuteOnce(
            ClaimNextInput(
                owner: "slow-photos-metadata-test",
                leaseDurationMs: 60_000,
                allowedKinds: [PhotosReconcileJobFactory.kind]
            )
        )

        XCTAssertEqual(result?.snapshot.state, .completed)
        XCTAssertEqual(result?.snapshot.progress, JobProgress(completed: 5, total: 5))
        let assetCount = try await database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset")
        }
        XCTAssertEqual(assetCount, 5)
    }

    func testPhotosReconcileHeartbeatStopsEnumerationAtPauseBoundary() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let jobID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let clock = MutableJobClock(nowMs: DatabaseTestSupport.timestampMs)
        let queue = GRDBJobQueue(
            database: database,
            clock: clock,
            retryPolicy: FixedDelayRetryPolicy(delayMs: 1_000)
        )
        let access = LeaseAdvancingPhotosLibraryAccess(
            assetCount: 5,
            elapsedMsPerAsset: 13_000,
            clock: clock,
            afterAsset: { enumeratedCount in
                guard enumeratedCount == 2 else { return }
                _ = try? queue.applyStateCommand(
                    JobStateCommand(jobID: jobID, operation: .pause)
                )
            }
        )
        let connection = PhotosLibraryConnectionService(
            database: database,
            access: access,
            clock: clock,
            idGenerator: IDSequence([sourceID, jobID]).next
        )
        _ = try await connection.connect()

        let handler = PhotosReconcileHandler(
            database: database,
            queue: queue,
            access: access,
            clock: clock
        )
        let coordinator = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [handler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )

        let result = try coordinator.claimAndExecuteOnce(
            ClaimNextInput(
                owner: "slow-photos-pause-test",
                leaseDurationMs: 60_000,
                allowedKinds: [PhotosReconcileJobFactory.kind]
            )
        )

        XCTAssertEqual(result?.snapshot.state, .paused)
        XCTAssertEqual(access.enumeratedCount, 3)
        let assetCount = try await database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset")
        }
        XCTAssertEqual(assetCount, 0)
    }

    func testImageLoaderRoutesPhotosToLocalProviderAndFilesToDerivedCache() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let photosSourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let folderSourceID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let photosAssetID = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
        let fileAssetID = UUID(uuidString: "44444444-5555-6666-7777-888888888888")!
        try await database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (id, kind, display_name, bookmark, state, created_at_ms, updated_at_ms)
                VALUES (?, 'photos', 'Apple Photos', NULL, 'active', ?, ?),
                       (?, 'folder', 'Fixture', ?, 'active', ?, ?)
                """,
                arguments: [
                    photosSourceID.uuidString.lowercased(), DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs, folderSourceID.uuidString.lowercased(), Data([1]),
                    DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    media_type, availability, record_created_at_ms, record_updated_at_ms, file_name
                ) VALUES (?, ?, 'photos', NULL, 'photos-local', 'public.jpeg', 'available', ?, ?, 'Photo.jpg'),
                         (?, ?, 'file', 'File.jpg', NULL, 'public.jpeg', 'available', ?, ?, 'File.jpg')
                """,
                arguments: [
                    photosAssetID.uuidString.lowercased(), photosSourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs,
                    fileAssetID.uuidString.lowercased(), folderSourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs,
                ]
            )
        }
        let photos = FakePhotosLibraryAccess(state: .authorized, localImageData: Data("photos".utf8))
        let files = FakeDerivedImageCache(data: Data("file".utf8))
        let loader = LibraryAssetImageLoader(database: database, fileImages: files, photosImages: photos)

        let photosData = try await loader.load(assetID: photosAssetID, variant: .grid)
        let fileData = try await loader.load(assetID: fileAssetID, variant: .preview)
        XCTAssertEqual(photosData, Data("photos".utf8))
        XCTAssertEqual(fileData, Data("file".utf8))
        XCTAssertEqual(photos.requestedVariants, [.grid])
        XCTAssertEqual(files.requestedVariants, [.preview])
    }

    func testImageLoaderDoesNotResolveHistoricalIdentifierAgainstCurrentPhotosLibrary() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let historicalSourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let activeSourceID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let historicalAssetID = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
        let activeAssetID = UUID(uuidString: "44444444-5555-6666-7777-888888888888")!
        try await database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (id, kind, display_name, bookmark, state, created_at_ms, updated_at_ms)
                VALUES (?, 'photos', 'Apple Photos', NULL, 'unavailable', ?, ?),
                       (?, 'photos', 'Apple Photos', NULL, 'active', ?, ?)
                """,
                arguments: [
                    historicalSourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                    activeSourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs + 1,
                    DatabaseTestSupport.timestampMs + 1,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    media_type, availability, record_created_at_ms, record_updated_at_ms, file_name
                ) VALUES (?, ?, 'photos', NULL, 'shared-local-identifier', 'public.jpeg',
                          'available', ?, ?, 'Historical.jpg'),
                         (?, ?, 'photos', NULL, 'shared-local-identifier', 'public.jpeg',
                          'available', ?, ?, 'Current.jpg')
                """,
                arguments: [
                    historicalAssetID.uuidString.lowercased(),
                    historicalSourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                    activeAssetID.uuidString.lowercased(),
                    activeSourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs + 1,
                    DatabaseTestSupport.timestampMs + 1,
                ]
            )
        }
        let photos = FakePhotosLibraryAccess(
            state: .authorized,
            localImageData: Data("current-library-photo".utf8)
        )
        let loader = LibraryAssetImageLoader(
            database: database,
            fileImages: FakeDerivedImageCache(data: Data()),
            photosImages: photos
        )

        do {
            _ = try await loader.load(assetID: historicalAssetID, variant: .preview)
            XCTFail("Expected historical source to avoid resolving against the current library")
        } catch {
            XCTAssertEqual(error as? PhotosLibraryError, .libraryUnavailable)
        }
        XCTAssertEqual(photos.requestedVariants, [])

        let activeData = try await loader.load(assetID: activeAssetID, variant: .preview)
        XCTAssertEqual(activeData, Data("current-library-photo".utf8))
        XCTAssertEqual(photos.requestedVariants, [.preview])
    }

    func testImageLoaderPersistsLocalPhotosThumbnailAndReusesItAfterRecreation() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let assetID = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
        try await database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (id, kind, display_name, bookmark, state, created_at_ms, updated_at_ms)
                VALUES (?, 'photos', 'Apple Photos', NULL, 'active', ?, ?)
                """,
                arguments: [
                    sourceID.uuidString.lowercased(), DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    media_type, availability, record_created_at_ms, record_updated_at_ms, file_name
                ) VALUES (?, ?, 'photos', NULL, 'photos-local', 'public.jpeg', 'available', ?, ?, 'Photo.jpg')
                """,
                arguments: [
                    assetID.uuidString.lowercased(), sourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs,
                ]
            )
        }

        let localBytes = Data("local-photo".utf8)
        let persistedBytes = Data("persisted-thumbnail".utf8)
        let photos = FakePhotosLibraryAccess(state: .authorized, localImageData: localBytes)
        let thumbnails = FakePhotoThumbnailCache(storedResult: persistedBytes)
        let firstLoader = LibraryAssetImageLoader(
            database: database,
            fileImages: FakeDerivedImageCache(data: Data()),
            photosImages: photos,
            photoThumbnails: thumbnails
        )

        let firstResult = try await firstLoader.load(assetID: assetID, variant: .grid)
        XCTAssertEqual(firstResult, persistedBytes)
        XCTAssertEqual(photos.requestedVariants, [.grid])
        XCTAssertEqual(thumbnails.storedSourceBytes, [localBytes])

        let unavailablePhotos = FakePhotosLibraryAccess(
            state: .authorized,
            localImageError: .libraryUnavailable
        )
        let reopenedLoader = LibraryAssetImageLoader(
            database: database,
            fileImages: FakeDerivedImageCache(data: Data()),
            photosImages: unavailablePhotos,
            photoThumbnails: thumbnails
        )
        let reopenedResult = try await reopenedLoader.load(assetID: assetID, variant: .grid)
        XCTAssertEqual(reopenedResult, persistedBytes)
        XCTAssertEqual(unavailablePhotos.requestedVariants, [])
    }

    func testExplicitCloudPreviewDownloadRequiresUserActionAndReusesDownloadedCacheForPreviewAndGrid() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let assetID = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
        try await database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (id, kind, display_name, bookmark, state, created_at_ms, updated_at_ms)
                VALUES (?, 'photos', 'Apple Photos', NULL, 'active', ?, ?)
                """,
                arguments: [
                    sourceID.uuidString.lowercased(), DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    media_type, availability, record_created_at_ms, record_updated_at_ms, file_name
                ) VALUES (?, ?, 'photos', NULL, 'photos-cloud-only', 'public.jpeg', 'available', ?, ?, 'Cloud.jpg')
                """,
                arguments: [
                    assetID.uuidString.lowercased(), sourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs,
                ]
            )
        }

        let local = FakePhotosLibraryAccess(
            state: .authorized,
            localImageError: .cloudOnly
        )
        let cloud = FakePhotosCloudPreview(data: Data("cloud-source".utf8))
        let cache = FakeDownloadedPreviewCache(cachedData: Data("cached-preview".utf8))
        let loader = LibraryAssetImageLoader(
            database: database,
            fileImages: FakeDerivedImageCache(data: Data()),
            photosImages: local,
            cloudPreviews: cloud,
            downloadedPreviews: cache
        )

        do {
            _ = try await loader.load(assetID: assetID, variant: .preview)
            XCTFail("Expected local-only request to report cloud-only")
        } catch {
            XCTAssertEqual(error as? PhotosLibraryError, .cloudOnly)
        }
        XCTAssertEqual(cloud.requestedLocalIdentifiers, [])

        let progress = CloudPreviewProgressProbe()
        let downloaded = try await loader.downloadCloudPreview(assetID: assetID) { value in
            progress.append(value)
        }
        XCTAssertEqual(downloaded, Data("cached-preview".utf8))
        XCTAssertEqual(progress.values, [0.25, 1.0])
        XCTAssertEqual(cloud.requestedLocalIdentifiers, ["photos-cloud-only"])
        XCTAssertEqual(cache.storedSourceBytes, [Data("cloud-source".utf8)])

        let cachedPreview = try await loader.load(assetID: assetID, variant: .preview)
        let cachedGrid = try await loader.load(assetID: assetID, variant: .grid)
        XCTAssertEqual(cachedPreview, downloaded)
        XCTAssertEqual(cachedGrid, downloaded)
        XCTAssertEqual(local.requestedVariants, [.preview])
        XCTAssertEqual(cloud.requestedLocalIdentifiers.count, 1)
    }

    func testConcurrentFileImageLoadsAreBounded() async throws {
        let database = try FolderAuthorizationTestSupport.makeDatabase()
        let sourceID = UUID()
        let assetIDs = (0 ..< 20).map { _ in UUID() }
        try await database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (id, kind, display_name, bookmark, state, created_at_ms, updated_at_ms)
                VALUES (?, 'folder', 'Fixture', ?, 'active', ?, ?)
                """,
                arguments: [
                    sourceID.uuidString.lowercased(), Data([1]),
                    DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs,
                ]
            )
            for (index, assetID) in assetIDs.enumerated() {
                try db.execute(
                    sql: """
                    INSERT INTO asset (
                        id, source_id, locator_kind, relative_path, photos_local_identifier,
                        media_type, availability, record_created_at_ms, record_updated_at_ms, file_name
                    ) VALUES (?, ?, 'file', ?, NULL, 'public.jpeg', 'available', ?, ?, ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(), sourceID.uuidString.lowercased(),
                        "image-\(index).jpg", DatabaseTestSupport.timestampMs,
                        DatabaseTestSupport.timestampMs, "image-\(index).jpg",
                    ]
                )
            }
        }
        let probe = ConcurrentLoadProbe()
        let files = ConcurrencyProbingFakeDerivedImageCache(probe: probe)
        let loader = LibraryAssetImageLoader(
            database: database,
            fileImages: files,
            photosImages: FakePhotosLibraryAccess(state: .authorized)
        )

        let loaded = try await withThrowingTaskGroup(of: Data.self) { group in
            for assetID in assetIDs {
                group.addTask {
                    try await loader.load(assetID: assetID, variant: .grid)
                }
            }
            var results: [Data] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertEqual(loaded.count, assetIDs.count)
        let peakConcurrentLoads = await probe.peakConcurrentLoads
        XCTAssertLessThanOrEqual(peakConcurrentLoads, 4)
    }

    private func availabilityByName(_ database: CatalogDatabase) async throws -> [String: AssetAvailability] {
        try await database.pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT file_name, availability FROM asset")
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let name: String = row["file_name"],
                      let availability = AssetAvailability(rawValue: row["availability"])
                else { return nil }
                return (name, availability)
            })
        }
    }

    private func metadata(_ identifier: String, name: String, type: String) -> PhotosAssetMetadata {
        PhotosAssetMetadata(
            localIdentifier: identifier,
            fileName: name,
            mediaType: type,
            width: 1200,
            height: 800,
            createdAtMs: DatabaseTestSupport.timestampMs,
            modifiedAtMs: DatabaseTestSupport.timestampMs
        )
    }
}

private final class SuspendedPhotosAuthorizationAccess: PhotosLibraryAccessPort, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PhotosAuthorizationState, Never>?

    var hasPendingRequest: Bool {
        lock.withLock { continuation != nil }
    }

    func authorizationState() -> PhotosAuthorizationState { .notDetermined }

    func requestAuthorization() async -> PhotosAuthorizationState {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func resumeAuthorization(with state: PhotosAuthorizationState) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: state)
    }

    func supportedStaticImageCount() throws -> Int { 0 }

    func enumerateStaticImages(
        startingAt _: Int,
        batchSize _: Int,
        onAssetEnumerated _: () throws -> Void,
        onBatch _: (PhotosAssetEnumerationBatch) throws -> Void
    ) throws {
        throw PhotosLibraryError.libraryUnavailable
    }

    func requestLocalImage(
        localIdentifier _: String,
        variant _: PhotosImageVariant
    ) async throws -> Data {
        throw PhotosLibraryError.libraryUnavailable
    }
}

private final class FakePhotosLibraryAccess: PhotosLibraryAccessPort, PhotosChangeHistoryPort, @unchecked Sendable {
    let state: PhotosAuthorizationState
    private let lock = NSLock()
    private var storedBatches: [[PhotosAssetMetadata]]
    private var failAfterBatches = false
    private let localImageData: Data
    private let localImageError: PhotosLibraryError?
    private var storedRequestedVariants: [PhotosImageVariant] = []
    private var storedEnumerationStartOffsets: [Int] = []
    private var storedPersistentChanges: [PhotosPersistentChangeBatch]
    private var storedRequestedChangeTokens: [Data] = []
    private let storedCurrentChangeToken: Data
    private let invalidChangeTokens: Set<Data>
    private var onEnumerationStart: (@Sendable () -> Void)?

    init(
        state: PhotosAuthorizationState,
        batches: [[PhotosAssetMetadata]] = [],
        localImageData: Data = Data(),
        localImageError: PhotosLibraryError? = nil,
        persistentChanges: [PhotosPersistentChangeBatch] = [],
        currentChangeToken: Data = Data("photos-current-token".utf8),
        invalidChangeTokens: Set<Data> = []
    ) {
        self.state = state
        storedBatches = batches
        self.localImageData = localImageData
        self.localImageError = localImageError
        storedPersistentChanges = persistentChanges
        storedCurrentChangeToken = currentChangeToken
        self.invalidChangeTokens = invalidChangeTokens
    }

    func authorizationState() -> PhotosAuthorizationState { state }
    func requestAuthorization() async -> PhotosAuthorizationState { state }

    func supportedStaticImageCount() throws -> Int {
        lock.withLock { storedBatches.reduce(0) { $0 + $1.count } }
    }

    func enumerateStaticImages(
        startingAt startOffset: Int,
        batchSize: Int,
        onAssetEnumerated: () throws -> Void,
        onBatch: (PhotosAssetEnumerationBatch) throws -> Void
    ) throws {
        switch state {
        case .authorized:
            break
        case .restricted:
            throw PhotosLibraryError.authorizationRestricted
        case .notDetermined, .denied:
            throw PhotosLibraryError.authorizationDenied
        }
        let configuration = lock.withLock {
            storedEnumerationStartOffsets.append(startOffset)
            let callback = onEnumerationStart
            onEnumerationStart = nil
            return (storedBatches, failAfterBatches, callback)
        }
        configuration.2?()
        let total = configuration.0.reduce(0) { $0 + $1.count }
        var completed = 0
        for batch in configuration.0 {
            let batchStart = completed
            completed += batch.count
            guard completed > startOffset else { continue }
            let unseenStart = max(0, startOffset - batchStart)
            for _ in batch.dropFirst(unseenStart) {
                try onAssetEnumerated()
            }
            try onBatch(
                PhotosAssetEnumerationBatch(
                    assets: Array(batch.dropFirst(unseenStart)),
                    completedCount: completed,
                    totalCount: total
                )
            )
        }
        if total <= startOffset {
            try onBatch(
                PhotosAssetEnumerationBatch(
                    assets: [],
                    completedCount: total,
                    totalCount: total
                )
            )
        }
        if configuration.1 {
            throw PhotosLibraryError.libraryUnavailable
        }
    }

    func configure(batches: [[PhotosAssetMetadata]], failAfterBatches: Bool) {
        lock.withLock {
            storedBatches = batches
            self.failAfterBatches = failAfterBatches
        }
    }

    func configureOnEnumerationStart(_ callback: @escaping @Sendable () -> Void) {
        lock.withLock { onEnumerationStart = callback }
    }
    func requestLocalImage(
        localIdentifier: String,
        variant: PhotosImageVariant
    ) async throws -> Data {
        lock.withLock { storedRequestedVariants.append(variant) }
        if let localImageError { throw localImageError }
        return localImageData
    }

    func currentChangeToken() throws -> Data {
        storedCurrentChangeToken
    }

    func enumeratePersistentChanges(
        since changeToken: Data,
        onBatch: (PhotosPersistentChangeBatch) throws -> Void
    ) throws {
        let changes = lock.withLock {
            storedRequestedChangeTokens.append(changeToken)
            return storedPersistentChanges
        }
        if invalidChangeTokens.contains(changeToken) {
            throw PhotosLibraryError.changeTokenInvalid
        }
        for change in changes {
            try onBatch(change)
        }
    }

    var requestedVariants: [PhotosImageVariant] {
        lock.withLock { storedRequestedVariants }
    }

    var enumerationStartOffsets: [Int] {
        lock.withLock { storedEnumerationStartOffsets }
    }

    var requestedChangeTokens: [Data] {
        lock.withLock { storedRequestedChangeTokens }
    }
}

private final class LeaseAdvancingPhotosLibraryAccess: PhotosLibraryAccessPort, @unchecked Sendable {
    private let assetCount: Int
    private let elapsedMsPerAsset: Int64
    private let clock: MutableJobClock
    private let afterAsset: (@Sendable (Int) -> Void)?
    private let lock = NSLock()
    private var storedEnumeratedCount = 0

    init(
        assetCount: Int,
        elapsedMsPerAsset: Int64,
        clock: MutableJobClock,
        afterAsset: (@Sendable (Int) -> Void)? = nil
    ) {
        self.assetCount = assetCount
        self.elapsedMsPerAsset = elapsedMsPerAsset
        self.clock = clock
        self.afterAsset = afterAsset
    }

    var enumeratedCount: Int { lock.withLock { storedEnumeratedCount } }

    func authorizationState() -> PhotosAuthorizationState { .authorized }
    func requestAuthorization() async -> PhotosAuthorizationState { .authorized }

    func supportedStaticImageCount() throws -> Int { assetCount }

    func enumerateStaticImages(
        startingAt startOffset: Int,
        batchSize: Int,
        onAssetEnumerated: () throws -> Void,
        onBatch: (PhotosAssetEnumerationBatch) throws -> Void
    ) throws {
        guard batchSize > 0 else { throw PhotosLibraryError.libraryUnavailable }
        let start = min(max(0, startOffset), assetCount)
        guard start < assetCount else {
            try onBatch(
                PhotosAssetEnumerationBatch(
                    assets: [],
                    completedCount: assetCount,
                    totalCount: assetCount
                )
            )
            return
        }

        for batchStart in stride(from: start, to: assetCount, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, assetCount)
            var assets: [PhotosAssetMetadata] = []
            assets.reserveCapacity(batchEnd - batchStart)
            for index in batchStart ..< batchEnd {
                clock.setNowMs(clock.nowMs + elapsedMsPerAsset)
                assets.append(
                    PhotosAssetMetadata(
                        localIdentifier: "slow-photos-\(index)",
                        fileName: "Slow-\(index).jpg",
                        mediaType: "public.jpeg",
                        width: 1_200,
                        height: 800,
                        createdAtMs: DatabaseTestSupport.timestampMs,
                        modifiedAtMs: DatabaseTestSupport.timestampMs
                    )
                )
                let currentCount = lock.withLock {
                    storedEnumeratedCount += 1
                    return storedEnumeratedCount
                }
                afterAsset?(currentCount)
                try onAssetEnumerated()
            }
            try onBatch(
                PhotosAssetEnumerationBatch(
                    assets: assets,
                    completedCount: batchEnd,
                    totalCount: assetCount
                )
            )
        }
    }

    func requestLocalImage(
        localIdentifier _: String,
        variant _: PhotosImageVariant
    ) async throws -> Data {
        throw PhotosLibraryError.libraryUnavailable
    }
}

private final class FakePhotosCloudPreview: PhotosCloudPreviewPort, @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private var identifiers: [String] = []

    init(data: Data) {
        self.data = data
    }

    func requestCloudPreview(
        localIdentifier: String,
        grant _: PhotosCloudDownloadGrant,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        lock.withLock { identifiers.append(localIdentifier) }
        onProgress(0.25)
        onProgress(1.0)
        return data
    }

    var requestedLocalIdentifiers: [String] {
        lock.withLock { identifiers }
    }
}

private final class FakeDownloadedPreviewCache: DownloadedPreviewCachePort, @unchecked Sendable {
    private let lock = NSLock()
    private let cachedData: Data
    private var storedData: Data?
    private var sourceBytes: [Data] = []

    init(cachedData: Data) {
        self.cachedData = cachedData
    }

    func loadDownloadedPreview(assetID _: UUID) throws -> Data? {
        lock.withLock { storedData }
    }

    func storeDownloadedPreview(assetID _: UUID, sourceBytes: Data) async throws -> Data {
        lock.withLock {
            self.sourceBytes.append(sourceBytes)
            storedData = cachedData
        }
        return cachedData
    }

    var storedSourceBytes: [Data] {
        lock.withLock { sourceBytes }
    }
}

private final class FakePhotoThumbnailCache: PhotoThumbnailCachePort, @unchecked Sendable {
    private let lock = NSLock()
    private let storedResult: Data
    private var cachedData: Data?
    private var storedSourceBytesValue: [Data] = []

    init(storedResult: Data) {
        self.storedResult = storedResult
    }

    func loadPhotoThumbnail(assetID _: UUID) throws -> Data? {
        lock.withLock { cachedData }
    }

    func storePhotoThumbnail(assetID _: UUID, sourceBytes: Data) async throws -> Data {
        lock.withLock {
            storedSourceBytesValue.append(sourceBytes)
            cachedData = storedResult
        }
        return storedResult
    }

    var storedSourceBytes: [Data] {
        lock.withLock { storedSourceBytesValue }
    }
}

private final class CloudPreviewProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Double] = []

    func append(_ value: Double) {
        lock.withLock { storedValues.append(value) }
    }

    var values: [Double] {
        lock.withLock { storedValues }
    }
}

private final class FakePhotosChangeObserver: PhotosChangeObserverPort, @unchecked Sendable {
    private let lock = NSLock()
    private var onChange: (@Sendable () -> Void)?

    func startObservingChanges(_ onChange: @escaping @Sendable () -> Void) {
        lock.withLock { self.onChange = onChange }
    }

    func stopObservingChanges() {
        lock.withLock { onChange = nil }
    }

    func emitChange() {
        let callback = lock.withLock { onChange }
        callback?()
    }
}

private final class FakePhotosAvailabilityObserver: PhotosLibraryAvailabilityObserverPort,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var onUnavailable: (@Sendable (PhotosLibraryUnavailabilityReason) -> Void)?

    func startObservingAvailability(
        _ onUnavailable: @escaping @Sendable (PhotosLibraryUnavailabilityReason) -> Void
    ) {
        lock.withLock { self.onUnavailable = onUnavailable }
    }

    func stopObservingAvailability() {
        lock.withLock { onUnavailable = nil }
    }

    func emit(_ reason: PhotosLibraryUnavailabilityReason) {
        let callback = lock.withLock { onUnavailable }
        callback?(reason)
    }
}

private final class PhotosObserverNotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        lock.withLock { storedCount }
    }

    func record() {
        lock.withLock { storedCount += 1 }
    }
}

private final class FakeDerivedImageCache: DerivedImageCachePort, @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private var variants: [DerivedImageVariant] = []

    init(data: Data) {
        self.data = data
    }

    func loadOrGenerate(_ request: DerivedImageRequest) async throws -> DerivedImagePayload {
        lock.withLock { variants.append(request.variant) }
        return DerivedImagePayload(
            entryID: UUID(),
            assetID: request.assetID,
            contentRevision: 1,
            representationVersion: DerivedImageRepresentationVersion.production,
            variant: request.variant,
            storageFormat: .jpeg,
            pixelWidth: 1,
            pixelHeight: 1,
            encodedBytes: data,
            origin: .cacheHit
        )
    }

    func performMaintenance() async throws -> DerivedImageMaintenanceResult {
        DerivedImageMaintenanceResult(
            removedEntries: 0,
            removedObjects: 0,
            removedBytes: 0,
            unsafeObjects: 0
        )
    }

    func cacheUsage() throws -> DerivedImageCacheUsage { .zero }

    func clearCache() async throws -> DerivedImageCacheClearResult {
        DerivedImageCacheClearResult(
            removedEntries: 0,
            registeredBytesInvalidated: 0,
            removedObjects: 0,
            removedBytes: 0,
            partialReclaim: false
        )
    }

    var requestedVariants: [DerivedImageVariant] {
        lock.withLock { variants }
    }
}

private struct ConcurrencyProbingFakeDerivedImageCache: DerivedImageCachePort, Sendable {
    let probe: ConcurrentLoadProbe

    func loadOrGenerate(_ request: DerivedImageRequest) async throws -> DerivedImagePayload {
        await probe.begin()
        do {
            try await Task.sleep(nanoseconds: 30_000_000)
            await probe.end()
            return DerivedImagePayload(
                entryID: UUID(),
                assetID: request.assetID,
                contentRevision: 1,
                representationVersion: DerivedImageRepresentationVersion.production,
                variant: request.variant,
                storageFormat: .jpeg,
                pixelWidth: 1,
                pixelHeight: 1,
                encodedBytes: Data([1]),
                origin: .cacheHit
            )
        } catch {
            await probe.end()
            throw error
        }
    }

    func performMaintenance() async throws -> DerivedImageMaintenanceResult {
        DerivedImageMaintenanceResult(
            removedEntries: 0,
            removedObjects: 0,
            removedBytes: 0,
            unsafeObjects: 0
        )
    }

    func cacheUsage() throws -> DerivedImageCacheUsage { .zero }

    func clearCache() async throws -> DerivedImageCacheClearResult {
        DerivedImageCacheClearResult(
            removedEntries: 0,
            registeredBytesInvalidated: 0,
            removedObjects: 0,
            removedBytes: 0,
            partialReclaim: false
        )
    }
}

private actor ConcurrentLoadProbe {
    private var activeLoads = 0
    private(set) var peakConcurrentLoads = 0

    func begin() {
        activeLoads += 1
        peakConcurrentLoads = max(peakConcurrentLoads, activeLoads)
    }

    func end() {
        activeLoads -= 1
    }
}

private final class IDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID]

    init(_ ids: [UUID]) {
        self.ids = ids
    }

    func next() -> UUID {
        lock.withLock { ids.removeFirst() }
    }
}
