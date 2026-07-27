import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

final class IdenticalDuplicateDetectionTests: XCTestCase {
    func testByteIdenticalClusterAndSourceUnchanged() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let bytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 11, uti: .jpeg))
        let a = try env.seedAsset(relativePath: "a.jpg", contents: bytes)
        let b = try env.seedAsset(relativePath: "b.jpg", contents: bytes)
        let beforeA = try env.sourceFileSnapshot(for: a.fileURL)
        let beforeB = try env.sourceFileSnapshot(for: b.fileURL)

        let completion = env.makeCompletionService()
        let fa = try completion.completeFolderAsset(assetID: a.assetID)
        let fb = try completion.completeFolderAsset(assetID: b.assetID)
        XCTAssertEqual(fa.sha256, fb.sha256)
        XCTAssertEqual(fa.sha256.count, 32)

        let clusters = try IdenticalDuplicateClusterService(database: env.database)
            .clusterIdenticalDuplicates(assetIDs: [a.assetID, b.assetID])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].kind, .byteIdentical)
        XCTAssertEqual(Set(clusters[0].memberAssetIDs), Set([a.assetID, b.assetID]))

        XCTAssertEqual(try env.sourceFileSnapshot(for: a.fileURL), beforeA)
        XCTAssertEqual(try env.sourceFileSnapshot(for: b.fileURL), beforeB)
    }

    func testPerceptualDuplicateAcrossJPEGAndPNG() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let jpeg = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 42, uti: .jpeg, quality: 0.95))
        let png = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 42, uti: .png))
        XCTAssertNotEqual(jpeg, png)

        let a = try env.seedAsset(relativePath: "same-a.jpg", contents: jpeg, mediaType: "public.jpeg")
        let b = try env.seedAsset(relativePath: "same-b.png", contents: png, mediaType: "public.png")

        let completion = env.makeCompletionService()
        let fa = try completion.completeFolderAsset(assetID: a.assetID)
        let fb = try completion.completeFolderAsset(assetID: b.assetID)
        XCTAssertNotEqual(fa.sha256, fb.sha256)

        let left = try XCTUnwrap(PerceptualImageHash.decodeHash(fa.perceptualHash))
        let right = try XCTUnwrap(PerceptualImageHash.decodeHash(fb.perceptualHash))
        let distance = PerceptualImageHash.hammingDistance(left, right)
        XCTAssertLessThanOrEqual(
            distance,
            IdenticalDuplicatePolicy.perceptualDuplicateMaxHammingDistance
        )

        let clusters = try IdenticalDuplicateClusterService(database: env.database)
            .clusterIdenticalDuplicates(assetIDs: [a.assetID, b.assetID])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].kind, .perceptualDuplicate)
        XCTAssertEqual(Set(clusters[0].memberAssetIDs), Set([a.assetID, b.assetID]))
    }

    func testClearlyDifferentImagesDoNotCluster() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let leftBytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 1, uti: .jpeg))
        let rightBytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 200, uti: .jpeg))
        let a = try env.seedAsset(relativePath: "left.jpg", contents: leftBytes)
        let b = try env.seedAsset(relativePath: "right.jpg", contents: rightBytes)

        let completion = env.makeCompletionService()
        let fa = try completion.completeFolderAsset(assetID: a.assetID)
        let fb = try completion.completeFolderAsset(assetID: b.assetID)
        XCTAssertNotEqual(fa.sha256, fb.sha256)

        let left = try XCTUnwrap(PerceptualImageHash.decodeHash(fa.perceptualHash))
        let right = try XCTUnwrap(PerceptualImageHash.decodeHash(fb.perceptualHash))
        XCTAssertGreaterThan(
            PerceptualImageHash.hammingDistance(left, right),
            IdenticalDuplicatePolicy.perceptualDuplicateMaxHammingDistance
        )

        let clusters = try IdenticalDuplicateClusterService(database: env.database)
            .clusterIdenticalDuplicates(assetIDs: [a.assetID, b.assetID])
        XCTAssertTrue(clusters.isEmpty)
    }

    func testDifferentSolidColorsDoNotBecomeDeletionGradeDuplicates() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let red = try XCTUnwrap(
            SimilarityTestSupport.solidImageData(red: 230, green: 20, blue: 20, uti: .jpeg)
        )
        let blue = try XCTUnwrap(
            SimilarityTestSupport.solidImageData(red: 20, green: 20, blue: 230, uti: .jpeg)
        )
        let a = try env.seedAsset(relativePath: "red.jpg", contents: red)
        let b = try env.seedAsset(relativePath: "blue.jpg", contents: blue)
        let completion = env.makeCompletionService()
        let fa = try completion.completeFolderAsset(assetID: a.assetID)
        let fb = try completion.completeFolderAsset(assetID: b.assetID)
        XCTAssertEqual(fa.perceptualHash, fb.perceptualHash, "fixture must exercise a dHash collision")

        let clusters = try IdenticalDuplicateClusterService(database: env.database)
            .clusterIdenticalDuplicates(assetIDs: [a.assetID, b.assetID])

        XCTAssertTrue(clusters.isEmpty)
    }

    func testPhotosCloudOriginalIsDurablyCachedAndClustersAcrossSources() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let bytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 77, uti: .png))
        let folderAsset = try env.seedAsset(
            relativePath: "same-as-photos.png",
            contents: bytes,
            mediaType: "public.png"
        )
        let photos = SimilarityPhotosOriginalStub(bytes: bytes)
        let completion = env.makeCompletionService(photosOriginals: photos)

        let photoFingerprint = try completion.completeAsset(assetID: photosAssetID)
        let folderFingerprint = try completion.completeAsset(assetID: folderAsset.assetID)

        XCTAssertEqual(photoFingerprint.sha256, folderFingerprint.sha256)
        XCTAssertEqual(photos.requestCount, 1)
        let clusters = try IdenticalDuplicateClusterService(database: env.database)
            .clusterIdenticalDuplicates(assetIDs: [photosAssetID, folderAsset.assetID])
        XCTAssertEqual(clusters.map(\.kind), [.byteIdentical])

        try env.database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM asset_similarity_fingerprint WHERE asset_id = ?",
                arguments: [photosAssetID.uuidString.lowercased()]
            )
        }
        photos.bytes = nil
        _ = try completion.completeAsset(assetID: photosAssetID)
        XCTAssertEqual(photos.requestCount, 1, "second completion must use the durable local original")
    }

    func testDurablePhotosOriginalCacheRejectsPreviewWrites() async throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let cache = PhotosOriginalCacheService(
            database: env.database,
            rootURL: env.root.appendingPathComponent("Photos Originals", isDirectory: true),
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )

        do {
            _ = try await cache.storeDownloadedPreview(
                assetID: photosAssetID,
                sourceBytes: Data("preview-only".utf8)
            )
            XCTFail("preview bytes must never be persisted as a durable original")
        } catch PhotosOriginalCacheError.previewWriteRejected {
            // Expected: the protocol conformance is read-only.
        }
    }

    func testDurablePhotosOriginalCacheRejectsChangedPhotoLocator() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let cache = PhotosOriginalCacheService(
            database: env.database,
            rootURL: env.root.appendingPathComponent("Photos Originals", isDirectory: true),
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )

        XCTAssertThrowsError(
            try cache.store(
                assetID: photosAssetID,
                contentRevision: 1,
                localIdentifier: "stale-photo-identifier",
                mediaType: "public.jpeg",
                sourceBytes: Data("full-original".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? PhotosOriginalCacheError, .assetChanged)
        }
    }

    func testDurablePhotosOriginalStorageReportsRetainedUsage() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let cache = PhotosOriginalCacheService(
            database: env.database,
            rootURL: env.root.appendingPathComponent("Photos Originals", isDirectory: true),
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )
        let original = Data("retained-full-original".utf8)
        let localIdentifier = "LOCAL-\(photosAssetID.uuidString.lowercased())"

        _ = try cache.store(
            assetID: photosAssetID,
            contentRevision: 1,
            localIdentifier: localIdentifier,
            mediaType: "public.jpeg",
            sourceBytes: original
        )

        XCTAssertEqual(
            try cache.storageUsage(),
            PhotosOriginalStorageUsage(
                entryCount: 1,
                registeredBytes: Int64(original.count)
            )
        )
    }

    func testManualDurablePhotosOriginalClearKeepsCatalogAndFingerprintFacts() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let original = try XCTUnwrap(
            SimilarityTestSupport.patternedImageData(seed: 91, uti: .jpeg)
        )
        let photos = SimilarityPhotosOriginalStub(bytes: original)
        let completion = env.makeCompletionService(photosOriginals: photos)
        let localIdentifier = "LOCAL-\(photosAssetID.uuidString.lowercased())"
        let cache = PhotosOriginalCacheService(
            database: env.database,
            rootURL: env.root.appendingPathComponent("Photos Originals", isDirectory: true),
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )

        _ = try completion.completeAsset(assetID: photosAssetID)
        XCTAssertEqual(try cache.storageUsage().entryCount, 1)

        XCTAssertEqual(
            try cache.clearAll(),
            PhotosOriginalStorageClearResult(
                removedEntries: 1,
                removedBytes: Int64(original.count),
                partialReclaim: false
            )
        )
        XCTAssertEqual(try cache.storageUsage(), .zero)
        XCTAssertNil(
            try cache.load(
                assetID: photosAssetID,
                contentRevision: 1,
                localIdentifier: localIdentifier
            )
        )
        let fingerprintCount = try env.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM asset_similarity_fingerprint WHERE asset_id = ?",
                arguments: [photosAssetID.uuidString.lowercased()]
            ) ?? 0
        }
        XCTAssertEqual(fingerprintCount, 1)
        XCTAssertEqual(photos.requestCount, 1)
    }

    func testManualDurablePhotosOriginalClearRejectsSymlinkObject() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let root = env.root.appendingPathComponent("Photos Originals", isDirectory: true)
        let cache = PhotosOriginalCacheService(
            database: env.database,
            rootURL: root,
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )
        _ = try cache.store(
            assetID: photosAssetID,
            contentRevision: 1,
            localIdentifier: "LOCAL-\(photosAssetID.uuidString.lowercased())",
            mediaType: "public.jpeg",
            sourceBytes: Data("registered-original".utf8)
        )
        let objectName = try env.database.pool.read { db in
            try XCTUnwrap(
                String.fetchOne(
                    db,
                    sql: "SELECT object_name FROM photos_original_cache_entry WHERE asset_id = ?",
                    arguments: [photosAssetID.uuidString.lowercased()]
                )
            )
        }
        let objectURL = root.appendingPathComponent(objectName)
        let sentinelURL = env.root.appendingPathComponent("must-survive.txt")
        let sentinel = Data("user-owned-sentinel".utf8)
        try sentinel.write(to: sentinelURL)
        try FileManager.default.removeItem(at: objectURL)
        try FileManager.default.createSymbolicLink(
            at: objectURL,
            withDestinationURL: sentinelURL
        )

        XCTAssertEqual(
            try cache.clearAll(),
            PhotosOriginalStorageClearResult(
                removedEntries: 0,
                removedBytes: 0,
                partialReclaim: true
            )
        )
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        XCTAssertEqual(try cache.storageUsage().entryCount, 1)
    }

    func testPrioritizedPreviewCacheReadsDurableOriginalAndWritesDisposableFallback() async throws {
        let assetID = UUID()
        let original = Data("durable-original".utf8)
        let preview = Data("disposable-preview".utf8)
        let primary = SimilarityDownloadedPreviewCacheStub(loaded: original)
        let fallback = SimilarityDownloadedPreviewCacheStub(loaded: preview)
        let cache = PrioritizedDownloadedPreviewCache(primary: primary, fallback: fallback)

        XCTAssertEqual(try cache.loadDownloadedPreview(assetID: assetID), original)
        XCTAssertEqual(primary.loadCount, 1)
        XCTAssertEqual(fallback.loadCount, 0)

        let storedPreview = try await cache.storeDownloadedPreview(
            assetID: assetID,
            sourceBytes: preview
        )
        XCTAssertEqual(storedPreview, preview)
        XCTAssertEqual(primary.storeCount, 0)
        XCTAssertEqual(fallback.storeCount, 1)
    }

    func testV018MigrationAppliedOnFreshDatabase() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAll-S1-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try CatalogDatabase.open(at: url)
        XCTAssertEqual(try database.appliedMigrationIDs(), CatalogMigrationID.knownOrdered)
        try database.pool.read { db in
            XCTAssertTrue(try db.tableExists("asset_similarity_fingerprint"))
        }
    }

    func testLibraryAnalysisJobPausesResumesAndPersistsAutomaticCompletion() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let bytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 91, uti: .png))
        let left = try env.seedAsset(relativePath: "job-left.png", contents: bytes, mediaType: "public.png")
        let right = try env.seedAsset(relativePath: "job-right.png", contents: bytes, mediaType: "public.png")
        let completion = env.makeCompletionService()
        let featureLoader = DictionarySlimmingFeatureLoader(vectors: [:])
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(vectors: [:])
        let scanner = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader
        )
        let queue = JobTestSupport.makeQueue(database: env.database)
        let analysis = LibrarySlimmingAnalysisService(
            database: env.database,
            queue: queue,
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            scanner: scanner,
            clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs)
        )

        let enqueued = try analysis.enqueue(
            mode: .catalog,
            assetIDs: [left.assetID, right.assetID],
            seedAssetIDs: []
        )
        XCTAssertEqual(enqueued.state, .pending)
        XCTAssertEqual(try analysis.pause(jobID: enqueued.jobID).state, .paused)
        XCTAssertEqual(try analysis.resume(jobID: enqueued.jobID).state, .pending)

        try analysis.runPending()

        let finished = try analysis.snapshot(jobID: enqueued.jobID)
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(finished.result?.clusters.map(\.kind), [.byteIdentical])
        XCTAssertEqual(finished.result?.pendingAnalysisAssetIDs, [])
    }

    func testLibraryAnalysisEnqueueSupersedesPausedJob() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let bytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 92, uti: .png))
        let left = try env.seedAsset(relativePath: "supersede-left.png", contents: bytes, mediaType: "public.png")
        let right = try env.seedAsset(relativePath: "supersede-right.png", contents: bytes, mediaType: "public.png")
        let seed = try env.seedAsset(
            relativePath: "supersede-seed.png",
            contents: try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 93, uti: .png)),
            mediaType: "public.png"
        )
        let completion = env.makeCompletionService()
        let featureLoader = DictionarySlimmingFeatureLoader(vectors: [:])
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(vectors: [:])
        let scanner = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader
        )
        let queue = JobTestSupport.makeQueue(database: env.database)
        let analysis = LibrarySlimmingAnalysisService(
            database: env.database,
            queue: queue,
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            scanner: scanner,
            clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs)
        )

        let first = try analysis.enqueue(
            mode: .catalog,
            assetIDs: [left.assetID, right.assetID],
            seedAssetIDs: []
        )
        XCTAssertEqual(try analysis.pause(jobID: first.jobID).state, .paused)

        let second = try analysis.enqueue(
            mode: .seeds,
            assetIDs: [left.assetID, right.assetID, seed.assetID],
            seedAssetIDs: [seed.assetID]
        )
        XCTAssertNotEqual(second.jobID, first.jobID)
        XCTAssertEqual(second.state, .pending)
        XCTAssertEqual(try analysis.snapshot(jobID: first.jobID).state, .cancelled)

        let memberCount = try env.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM library_slimming_scan_member WHERE job_id = ?",
                arguments: [second.jobID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(memberCount, 3)
        let seedCount = try env.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM library_slimming_scan_member
                WHERE job_id = ? AND is_seed = 1
                """,
                arguments: [second.jobID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(seedCount, 1)
    }
}

private final class SimilarityDownloadedPreviewCacheStub: DownloadedPreviewCachePort,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let loaded: Data?
    private var storedLoadCount = 0
    private var storedStoreCount = 0

    init(loaded: Data?) {
        self.loaded = loaded
    }

    var loadCount: Int {
        lock.withLock { storedLoadCount }
    }

    var storeCount: Int {
        lock.withLock { storedStoreCount }
    }

    func loadDownloadedPreview(assetID: UUID) throws -> Data? {
        _ = assetID
        lock.withLock { storedLoadCount += 1 }
        return loaded
    }

    func storeDownloadedPreview(assetID: UUID, sourceBytes: Data) async throws -> Data {
        _ = assetID
        lock.withLock { storedStoreCount += 1 }
        return sourceBytes
    }
}

enum SimilarityTestSupport {
    struct SeededAsset {
        let assetID: UUID
        let fileURL: URL
    }

    final class Environment {
        let root: URL
        let sourceRoot: URL
        let database: CatalogDatabase
        let bookmark: Data
        let sourceID: UUID
        private var didInsertSource = false

        init(label: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ImageAllSimilarity-\(label)-\(UUID().uuidString)", isDirectory: true)
            sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
            let databaseURL = root.appendingPathComponent("catalog.sqlite")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            database = try CatalogDatabase.open(at: databaseURL)
            sourceID = UUID()
            bookmark = sourceRoot.path.data(using: .utf8) ?? Data()
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        func makeCompletionService(
            photosOriginals: (any PhotosOriginalContentPort)? = nil
        ) -> FingerprintCompletionService {
            let bookmarkPort = FolderReconcileTestSupport.TestBookmarkPort(
                rootByBookmark: [bookmark: sourceRoot]
            )
            let sourceAccess = FolderReconcileSourceAccessService(
                repository: GRDBFolderSourceAuthorizationRepository(database: database),
                bookmarkPort: bookmarkPort,
                rootValidator: FolderRootValidator(),
                clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
            )
            return FingerprintCompletionService(
                database: database,
                sourceAccess: sourceAccess,
                photosOriginals: photosOriginals,
                photosOriginalCache: PhotosOriginalCacheService(
                    database: database,
                    rootURL: root.appendingPathComponent("Photos Originals", isDirectory: true),
                    clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
                ),
                clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
            )
        }

        @discardableResult
        func seedAsset(
            relativePath: String,
            contents: Data,
            mediaType: String = "public.jpeg",
            mediaCreatedAtMs: Int64? = nil
        ) throws -> SeededAsset {
            let assetID = UUID()
            let fileURL = sourceRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: fileURL)
            let reader = FoundationFolderFileResourceReader()
            let sizeBytes = reader.fileSizeBytes(for: fileURL) ?? 0
            let modifiedAtNs = reader.modifiedAtNs(for: fileURL) ?? 0
            let resourceID = reader.resourceIdentifier(for: fileURL)
            let fileName = RelativePathRules.fileName(from: relativePath) ?? fileURL.lastPathComponent

            try database.pool.write { db in
                if !didInsertSource {
                    try db.execute(
                        sql: """
                        INSERT INTO source (
                            id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                            state, created_at_ms, updated_at_ms
                        ) VALUES (?, 'folder', 'Fixture', ?, 0, 0, 'active', ?, ?)
                        """,
                        arguments: [
                            sourceID.uuidString.lowercased(),
                            bookmark,
                            FolderReconcileTestSupport.baseTimeMs,
                            FolderReconcileTestSupport.baseTimeMs,
                        ]
                    )
                    didInsertSource = true
                }
                try db.execute(
                    sql: """
                    INSERT INTO asset (
                        id, source_id, locator_kind, relative_path, photos_local_identifier,
                        locator_state, media_type, media_created_at_ms, content_revision, availability,
                        record_created_at_ms, record_updated_at_ms, file_name
                    ) VALUES (?, ?, 'file', ?, NULL, 'current', ?, ?, 1, 'available', ?, ?, ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        sourceID.uuidString.lowercased(),
                        relativePath,
                        mediaType,
                        mediaCreatedAtMs,
                        FolderReconcileTestSupport.baseTimeMs,
                        FolderReconcileTestSupport.baseTimeMs,
                        fileName,
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO file_fingerprint (asset_id, size_bytes, modified_at_ns, resource_id, sha256)
                    VALUES (?, ?, ?, ?, NULL)
                    """,
                    arguments: [assetID.uuidString.lowercased(), sizeBytes, modifiedAtNs, resourceID]
                )
            }
            return SeededAsset(assetID: assetID, fileURL: fileURL)
        }

        func seedPhotosAsset() throws -> UUID {
            let photosSourceID = UUID()
            let assetID = UUID()
            try database.pool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO source (
                        id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                        state, created_at_ms, updated_at_ms
                    ) VALUES (?, 'photos', 'Photos', NULL, 0, 0, 'active', ?, ?)
                    """,
                    arguments: [
                        photosSourceID.uuidString.lowercased(),
                        FolderReconcileTestSupport.baseTimeMs,
                        FolderReconcileTestSupport.baseTimeMs,
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO asset (
                        id, source_id, locator_kind, relative_path, photos_local_identifier,
                        locator_state, media_type, content_revision, availability,
                        record_created_at_ms, record_updated_at_ms, file_name
                    ) VALUES (?, ?, 'photos', NULL, ?, 'current', 'public.jpeg', 1, 'available', ?, ?, NULL)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        photosSourceID.uuidString.lowercased(),
                        "LOCAL-\(assetID.uuidString.lowercased())",
                        FolderReconcileTestSupport.baseTimeMs,
                        FolderReconcileTestSupport.baseTimeMs,
                    ]
                )
            }
            return assetID
        }

        func sourceFileSnapshot(for fileURL: URL) throws -> Data {
            try Data(contentsOf: fileURL)
        }
    }

    static func patternedImageData(
        seed: UInt8,
        uti: UTType,
        width: Int = 64,
        height: Int = 64,
        quality: Double? = nil
    ) -> Data? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let v = UInt8((Int(seed) &* 17 &+ x &* 3 &+ y &* 5) & 0xFF)
                pixels[idx] = v
                pixels[idx + 1] = UInt8((Int(seed) &* 29 &+ x &* 7) & 0xFF)
                pixels[idx + 2] = UInt8((Int(seed) &* 13 &+ y &* 11) & 0xFF)
                pixels[idx + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, uti.identifier as CFString, 1, nil) else {
            return nil
        }
        var props: [CFString: Any] = [:]
        if let quality {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func solidImageData(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        uti: UTType,
        width: Int = 64,
        height: Int = 64
    ) -> Data? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = red
            pixels[offset + 1] = green
            pixels[offset + 2] = blue
            pixels[offset + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            uti.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

private final class SimilarityPhotosOriginalStub: PhotosOriginalContentPort, @unchecked Sendable {
    private let lock = NSLock()
    var bytes: Data?
    private var storedRequestCount = 0

    init(bytes: Data?) {
        self.bytes = bytes
    }

    var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    func requestOriginalImageData(localIdentifier: String) throws -> Data {
        _ = localIdentifier
        return try lock.withLock {
            storedRequestCount += 1
            guard let bytes else {
                throw PhotosLibraryError.libraryUnavailable
            }
            return bytes
        }
    }
}
