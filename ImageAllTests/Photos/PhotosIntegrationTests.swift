import Foundation
import GRDB
import Photos
import XCTest
@testable import ImageAll

final class PhotosIntegrationTests: XCTestCase {
    func testPhotoKitPolicyExcludesVideoAndLivePhotoAndNeverEnablesNetwork() {
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
        XCTAssertFalse(
            PhotoKitPhotosLibraryAdapter.isSupportedStaticImage(
                mediaType: .image,
                mediaSubtypes: .photoLive,
                uniformTypeIdentifier: "public.heic"
            )
        )
        XCTAssertFalse(PhotoKitPhotosLibraryAdapter.makeLocalOnlyImageRequestOptions().isNetworkAccessAllowed)
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

private final class FakePhotosLibraryAccess: PhotosLibraryAccessPort, @unchecked Sendable {
    let state: PhotosAuthorizationState
    private let lock = NSLock()
    private var storedBatches: [[PhotosAssetMetadata]]
    private var failAfterBatches = false
    private let localImageData: Data
    private var storedRequestedVariants: [PhotosImageVariant] = []

    init(
        state: PhotosAuthorizationState,
        batches: [[PhotosAssetMetadata]] = [],
        localImageData: Data = Data()
    ) {
        self.state = state
        storedBatches = batches
        self.localImageData = localImageData
    }

    func authorizationState() -> PhotosAuthorizationState { state }
    func requestAuthorization() async -> PhotosAuthorizationState { state }
    func enumerateStaticImages(
        batchSize: Int,
        onBatch: ([PhotosAssetMetadata]) throws -> Void
    ) throws {
        let configuration = lock.withLock { (storedBatches, failAfterBatches) }
        for batch in configuration.0 {
            try onBatch(batch)
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
    func requestLocalImage(
        localIdentifier: String,
        variant: PhotosImageVariant
    ) async throws -> Data {
        lock.withLock { storedRequestedVariants.append(variant) }
        return localImageData
    }

    var requestedVariants: [PhotosImageVariant] {
        lock.withLock { storedRequestedVariants }
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

    var requestedVariants: [DerivedImageVariant] {
        lock.withLock { variants }
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
