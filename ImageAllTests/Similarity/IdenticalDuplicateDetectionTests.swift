import CryptoKit
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

final class IdenticalDuplicateDetectionTests: XCTestCase {
    func testVideoFingerprintUsesOnlyRepresentativePosterAcrossFolderAndPhotoKit() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let videoBytes = Data([1, 7, 7, 7])
        let folder = try env.seedAsset(
            relativePath: "folder-video.mp4",
            contents: videoBytes,
            mediaType: "public.mpeg-4",
            mediaKind: .video,
            durationMs: 4_000
        )
        let photosAssetID = try env.seedPhotosAsset(
            mediaType: "com.apple.quicktime-movie",
            mediaKind: .video,
            durationMs: 4_000
        )
        let posterBytes = try XCTUnwrap(
            SimilarityTestSupport.patternedImageData(seed: 101, uti: .png)
        )
        let featureImages = SimilarityPhotosFeatureImageStub(bytes: posterBytes)
        let completion = env.makeCompletionService(
            photosFeatureImages: featureImages,
            videoPosterGenerator: SimilarityVideoPosterStub()
        )

        let folderFingerprint = try completion.completeAsset(assetID: folder.assetID)
        let photosFingerprint = try completion.completeAsset(assetID: photosAssetID)

        XCTAssertEqual(photosFingerprint.sha256, folderFingerprint.sha256)
        XCTAssertNotEqual(folderFingerprint.sha256, Data(SHA256.hash(data: videoBytes)))
        XCTAssertEqual(
            photosFingerprint.perceptualAlgoVersion,
            IdenticalDuplicatePolicy.videoPosterPerceptualAlgoVersion
        )
        XCTAssertEqual(featureImages.requestCount, 1)
        let storedFileSHA: Data? = try env.database.pool.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT sha256 FROM file_fingerprint WHERE asset_id = ?",
                arguments: [folder.assetID.uuidString.lowercased()]
            )
        }
        XCTAssertNil(storedFileSHA)

        let clusters = try IdenticalDuplicateClusterService(database: env.database)
            .clusterIdenticalDuplicates(
                assetIDs: [folder.assetID, photosAssetID],
                mediaKind: .video
            )
        XCTAssertEqual(clusters.map(\.kind), [.perceptualDuplicate])
        XCTAssertEqual(
            Set(try XCTUnwrap(clusters.first).memberAssetIDs),
            Set([folder.assetID, photosAssetID])
        )
    }

    func testVideoSlimmingUsesOnlyPosterSimilarityWithoutPhotoLeakage() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let exactA = try env.seedAsset(
            relativePath: "exact-a.mp4",
            contents: Data([1, 9, 9, 9]),
            mediaType: "public.mpeg-4",
            mediaKind: .video,
            durationMs: 4_000
        )
        let exactB = try env.seedAsset(
            relativePath: "exact-b.mp4",
            contents: Data([1, 8, 8, 8]),
            mediaType: "public.mpeg-4",
            mediaKind: .video,
            durationMs: 4_000
        )
        let sceneA = try env.seedAsset(
            relativePath: "scene-a.mp4",
            contents: Data([2, 2, 3]),
            mediaType: "public.mpeg-4",
            mediaKind: .video,
            durationMs: 5_000
        )
        let sceneB = try env.seedAsset(
            relativePath: "scene-b.mp4",
            contents: Data([3, 3, 4]),
            mediaType: "public.mpeg-4",
            mediaKind: .video,
            durationMs: 6_000
        )
        let photoBytes = try XCTUnwrap(
            SimilarityTestSupport.patternedImageData(seed: 88, uti: .jpeg)
        )
        let photo = try env.seedAsset(relativePath: "photo.jpg", contents: photoBytes)

        let completion = env.makeCompletionService(
            videoPosterGenerator: SimilarityVideoPosterStub()
        )
        for assetID in [exactA.assetID, exactB.assetID, sceneA.assetID, sceneB.assetID, photo.assetID] {
            _ = try completion.completeAsset(assetID: assetID)
        }

        let exactFingerprint = try completion.completeAsset(assetID: exactA.assetID)
        XCTAssertEqual(
            exactFingerprint.perceptualAlgoVersion,
            IdenticalDuplicatePolicy.videoPosterPerceptualAlgoVersion
        )
        XCTAssertEqual(
            try completion.completeAsset(assetID: photo.assetID).perceptualAlgoVersion,
            IdenticalDuplicatePolicy.perceptualAlgoVersion
        )

        let featureLoader = DictionarySlimmingFeatureLoader(vectors: [
            sceneA.assetID: [1, 0],
            sceneB.assetID: [0.99, 0.01],
            photo.assetID: [0.98, 0.02],
        ])
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(vectors: [
            sceneA.assetID: [1, 0],
            sceneB.assetID: [0.99, 0.01],
            photo.assetID: [0.98, 0.02],
        ])
        let scanner = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: nil,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader
        )

        let result = try scanner.scan(
            assetIDs: [
                exactA.assetID, exactB.assetID,
                sceneA.assetID, sceneB.assetID,
                photo.assetID,
            ],
            mediaKind: .video,
            onProgress: nil
        )

        XCTAssertEqual(result.analyzedAssetCount, 4)
        XCTAssertFalse(result.clusters.contains { $0.kind == .byteIdentical })
        let posterDuplicate = try XCTUnwrap(
            result.clusters.first {
                $0.kind == .perceptualDuplicate
                    && Set($0.memberAssetIDs) == Set([exactA.assetID, exactB.assetID])
            },
            """
            exactA=\(exactA.assetID) exactB=\(exactB.assetID) \
            sceneA=\(sceneA.assetID) sceneB=\(sceneB.assetID) \
            clusters=\(result.clusters.map { ($0.kind, $0.memberAssetIDs) })
            """
        )
        XCTAssertEqual(posterDuplicate.score, 1)
        let similar = try XCTUnwrap(result.clusters.first { $0.kind == .nearDuplicateScene })
        XCTAssertEqual(Set(similar.memberAssetIDs), Set([sceneA.assetID, sceneB.assetID]))
        XCTAssertFalse(result.clusters.flatMap(\.memberAssetIDs).contains(photo.assetID))
        XCTAssertEqual(
            posterDuplicate.modelIdentity.perceptualAlgoVersion,
            IdenticalDuplicatePolicy.videoPosterPerceptualAlgoVersion
        )

        let analysis = LibrarySlimmingAnalysisService(
            database: env.database,
            queue: JobTestSupport.makeQueue(database: env.database),
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            scanner: scanner,
            clock: FixedJobClock(nowMs: JobTestSupport.baseTimeMs)
        )
        let enqueued = try analysis.enqueue(
            mode: .catalog,
            assetIDs: [exactA.assetID, exactB.assetID, sceneA.assetID, sceneB.assetID],
            seedAssetIDs: [],
            mediaKind: .video
        )
        try analysis.runPending()
        let completed = try analysis.snapshot(jobID: enqueued.jobID)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.result?.analyzedAssetCount, 4)
        XCTAssertEqual(try analysis.listJobs(mediaKind: .video).count, 1)
        XCTAssertTrue(try analysis.listJobs(mediaKind: .image).isEmpty)
    }

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

    func testPhotosFingerprintFallsBackToLocalFeatureImageWhenOriginalIsCloudOnly() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let previewBytes = try XCTUnwrap(
            SimilarityTestSupport.patternedImageData(seed: 44, uti: .jpeg)
        )
        let folderAsset = try env.seedAsset(
            relativePath: "same-preview-bytes.jpg",
            contents: previewBytes
        )
        let originals = SimilarityPhotosOriginalStub(error: .cloudOnly)
        let featureImages = SimilarityPhotosFeatureImageStub(bytes: previewBytes)
        let completion = env.makeCompletionService(
            photosOriginals: originals,
            photosFeatureImages: featureImages
        )
        let cache = PhotosOriginalCacheService(
            database: env.database,
            rootURL: env.root.appendingPathComponent("Photos Originals", isDirectory: true),
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )

        let fingerprint = try completion.completeAsset(assetID: photosAssetID)
        _ = try completion.completeAsset(assetID: folderAsset.assetID)
        let clusters = try IdenticalDuplicateClusterService(database: env.database)
            .clusterIdenticalDuplicates(assetIDs: [photosAssetID, folderAsset.assetID])

        XCTAssertEqual(originals.requestCount, 1)
        XCTAssertEqual(featureImages.requestCount, 1)
        XCTAssertEqual(try cache.storageUsage(), .zero, "preview/thumbnail bytes must not be stored as originals")
        XCTAssertEqual(fingerprint.sha256, Data(SHA256.hash(data: previewBytes)))
        XCTAssertFalse(
            clusters.contains { $0.kind == .byteIdentical },
            "feature/preview bytes must never prove deletion-grade byte identity"
        )
    }

    func testPhotosFingerprintSkipsWhenNoLocalBytesAvailable() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let completion = env.makeCompletionService(
            photosOriginals: SimilarityPhotosOriginalStub(error: .cloudOnly),
            photosFeatureImages: SimilarityPhotosFeatureImageStub(error: .cloudOnly)
        )

        XCTAssertThrowsError(try completion.completeAsset(assetID: photosAssetID)) { error in
            XCTAssertEqual(error as? FingerprintCompletionError, .sourceUnavailable)
        }
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

    func testLibraryAnalysisResumeKeepsAlreadyPendingJobClaimable() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let bytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 94, uti: .png))
        let asset = try env.seedAsset(
            relativePath: "already-pending.png",
            contents: bytes,
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
        let enqueued = try analysis.enqueue(
            mode: .catalog,
            assetIDs: [asset.assetID],
            seedAssetIDs: []
        )

        let resumed = try analysis.resume(jobID: enqueued.jobID)

        XCTAssertEqual(resumed.state, .pending)
        XCTAssertEqual(
            try JobTestSupport.claimDefault(queue: queue)?.jobID,
            enqueued.jobID
        )
    }

    func testLibraryAnalysisResumeRecoversExpiredRunningJob() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let bytes = try XCTUnwrap(
            SimilarityTestSupport.patternedImageData(seed: 97, uti: .png)
        )
        let asset = try env.seedAsset(
            relativePath: "expired-running.png",
            contents: bytes,
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
        let clock = MutableJobClock(nowMs: JobTestSupport.baseTimeMs)
        let queue = GRDBJobQueue(
            database: env.database,
            clock: clock,
            retryPolicy: FixedDelayRetryPolicy(delayMs: JobTestSupport.retryDelayMs)
        )
        let analysis = LibrarySlimmingAnalysisService(
            database: env.database,
            queue: queue,
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            scanner: scanner,
            clock: clock
        )
        let enqueued = try analysis.enqueue(
            mode: .catalog,
            assetIDs: [asset.assetID],
            seedAssetIDs: []
        )
        let lease = try XCTUnwrap(try JobTestSupport.claimDefault(queue: queue))
        XCTAssertEqual(lease.jobID, enqueued.jobID)
        clock.setNowMs(lease.leaseExpiresAtMs + 1)

        let resumed = try analysis.resume(jobID: enqueued.jobID)

        XCTAssertEqual(resumed.state, .pending)
        XCTAssertNil(try queue.fetchJob(id: enqueued.jobID).leaseOwner)
    }

    func testLibraryAnalysisListJobsUpgradesActiveRetryBudgetAndExposesAttempts() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let bytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 95, uti: .png))
        let asset = try env.seedAsset(
            relativePath: "retry-budget.png",
            contents: bytes,
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
        let enqueued = try analysis.enqueue(
            mode: .catalog,
            assetIDs: [asset.assetID],
            seedAssetIDs: []
        )
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE job SET attempts = 3, max_attempts = 5 WHERE id = ?",
                arguments: [enqueued.jobID.uuidString.lowercased()]
            )
        }

        let summary = try XCTUnwrap(analysis.listJobs().first)

        XCTAssertEqual(summary.attempts, 3)
        XCTAssertEqual(summary.maxAttempts, 10)
        XCTAssertEqual(summary.sourceNames, ["Fixture"])
        XCTAssertEqual(try queue.fetchJob(id: enqueued.jobID).maxAttempts, 10)
    }

    func testLibraryAnalysisEnqueuePreservesPausedJob() throws {
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
        XCTAssertEqual(try analysis.snapshot(jobID: first.jobID).state, .paused)

        let jobs = try analysis.listJobs()
        XCTAssertEqual(jobs.count, 2)
        XCTAssertEqual(Set(jobs.map(\.jobID)), Set([first.jobID, second.jobID]))
        XCTAssertEqual(jobs.first(where: { $0.jobID == second.jobID })?.seedCount, 1)
        XCTAssertEqual(jobs.first(where: { $0.jobID == first.jobID })?.memberCount, 2)

        try analysis.delete(jobID: first.jobID)
        let remaining = try analysis.listJobs()
        XCTAssertEqual(remaining.map(\.jobID), [second.jobID])
        XCTAssertThrowsError(try analysis.snapshot(jobID: first.jobID))
    }

    func testLibraryAnalysisClusteringHeartbeatCompletesBeyondOriginalLease() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let bytes = try XCTUnwrap(
            SimilarityTestSupport.patternedImageData(seed: 96, uti: .png)
        )
        let asset = try env.seedAsset(
            relativePath: "heartbeat.png",
            contents: bytes,
            mediaType: "public.png"
        )
        let completion = env.makeCompletionService()
        let featureLoader = DictionarySlimmingFeatureLoader(vectors: [
            asset.assetID: [1, 0],
        ])
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(vectors: [
            asset.assetID: [1, 0],
        ])
        let clock = MutableJobClock(nowMs: JobTestSupport.baseTimeMs)
        let scanner = LeaseAdvancingSlimmingScanner(
            clock: clock,
            heartbeatAtMs: JobTestSupport.baseTimeMs
                + LibrarySlimmingAnalysisJobFactory.leaseDurationMs / 2,
            finishAtMs: JobTestSupport.baseTimeMs
                + LibrarySlimmingAnalysisJobFactory.leaseDurationMs
                + LibrarySlimmingAnalysisJobFactory.leaseDurationMs / 5
        )
        let queue = GRDBJobQueue(
            database: env.database,
            clock: clock,
            retryPolicy: FixedDelayRetryPolicy(
                delayMs: JobTestSupport.retryDelayMs
            )
        )
        let analysis = LibrarySlimmingAnalysisService(
            database: env.database,
            queue: queue,
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            scanner: scanner,
            clock: clock
        )
        let enqueued = try analysis.enqueue(
            mode: .catalog,
            assetIDs: [asset.assetID],
            seedAssetIDs: []
        )

        try analysis.runPending()

        let finished = try analysis.snapshot(jobID: enqueued.jobID)
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(finished.progress.completed, finished.progress.total)
    }

    func testLibraryAnalysisClusteringRenewsLeaseWithoutProgressCallbacks() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let bytes = try XCTUnwrap(
            SimilarityTestSupport.patternedImageData(seed: 98, uti: .png)
        )
        let asset = try env.seedAsset(
            relativePath: "callback-free-heartbeat.png",
            contents: bytes,
            mediaType: "public.png"
        )
        let completion = env.makeCompletionService()
        let featureLoader = DictionarySlimmingFeatureLoader(vectors: [
            asset.assetID: [1, 0],
        ])
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(vectors: [
            asset.assetID: [1, 0],
        ])
        let clock = SystemJobClock()
        let queue = GRDBJobQueue(
            database: env.database,
            clock: clock,
            retryPolicy: FixedDelayRetryPolicy(delayMs: JobTestSupport.retryDelayMs)
        )
        let analysis = LibrarySlimmingAnalysisService(
            database: env.database,
            queue: queue,
            fingerprintCompletion: completion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            scanner: CallbackFreeBlockingSlimmingScanner(delay: 0.65),
            clock: clock,
            leaseDurationMs: 300
        )
        let enqueued = try analysis.enqueue(
            mode: .catalog,
            assetIDs: [asset.assetID],
            seedAssetIDs: []
        )

        try analysis.runPending()

        let finished = try analysis.snapshot(jobID: enqueued.jobID)
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(finished.progress.completed, finished.progress.total)
    }
}

private final class LeaseAdvancingSlimmingScanner: LibrarySlimmingScanPort,
    @unchecked Sendable
{
    private let clock: MutableJobClock
    private let heartbeatAtMs: Int64
    private let finishAtMs: Int64

    init(clock: MutableJobClock, heartbeatAtMs: Int64, finishAtMs: Int64) {
        self.clock = clock
        self.heartbeatAtMs = heartbeatAtMs
        self.finishAtMs = finishAtMs
    }

    func scan(
        assetIDs: [UUID],
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws -> LibrarySlimmingScanResult {
        clock.setNowMs(heartbeatAtMs)
        onProgress?(
            LibrarySlimmingScanProgress(
                phase: .clustering,
                completed: 1,
                total: 2
            )
        )
        clock.setNowMs(finishAtMs)
        return LibrarySlimmingScanResult(
            clusters: [],
            pendingAnalysisAssetIDs: [],
            analyzedAssetCount: assetIDs.count,
            policyVersion: NearDuplicateScenePolicy.policyVersion
        )
    }

    func scanCatalog(
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws -> LibrarySlimmingScanResult {
        try scan(assetIDs: [], onProgress: onProgress)
    }

    func scanSeeds(
        seedAssetIDs: [UUID],
        universeAssetIDs: [UUID],
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws -> LibrarySlimmingScanResult {
        _ = seedAssetIDs
        return try scan(assetIDs: universeAssetIDs, onProgress: onProgress)
    }
}

private struct CallbackFreeBlockingSlimmingScanner: LibrarySlimmingScanPort {
    let delay: TimeInterval

    func scan(
        assetIDs: [UUID],
        onProgress _: LibrarySlimmingScanProgressHandler?
    ) throws -> LibrarySlimmingScanResult {
        Thread.sleep(forTimeInterval: delay)
        return LibrarySlimmingScanResult(
            clusters: [],
            pendingAnalysisAssetIDs: [],
            analyzedAssetCount: assetIDs.count,
            policyVersion: NearDuplicateScenePolicy.policyVersion
        )
    }

    func scanCatalog(
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws -> LibrarySlimmingScanResult {
        try scan(assetIDs: [], onProgress: onProgress)
    }

    func scanSeeds(
        seedAssetIDs _: [UUID],
        universeAssetIDs: [UUID],
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws -> LibrarySlimmingScanResult {
        try scan(assetIDs: universeAssetIDs, onProgress: onProgress)
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
            photosOriginals: (any PhotosOriginalContentPort)? = nil,
            photosFeatureImages: (any PhotosFeaturePrintImagePort)? = nil,
            downloadedPreviews: (any DownloadedPreviewCachePort)? = nil,
            videoPosterGenerator: any DerivedVideoPosterGenerating =
                AVFoundationDerivedVideoPosterGenerator()
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
                photosFeatureImages: photosFeatureImages,
                downloadedPreviews: downloadedPreviews,
                clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs),
                videoPosterGenerator: videoPosterGenerator
            )
        }

        @discardableResult
        func seedAsset(
            relativePath: String,
            contents: Data,
            mediaType: String = "public.jpeg",
            mediaCreatedAtMs: Int64? = nil,
            mediaKind: MediaKind = .image,
            durationMs: Int64? = nil
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
                        record_created_at_ms, record_updated_at_ms, file_name, media_kind, duration_ms
                    ) VALUES (?, ?, 'file', ?, NULL, 'current', ?, ?, 1, 'available', ?, ?, ?, ?, ?)
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
                        mediaKind.rawValue,
                        durationMs,
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

        func seedPhotosAsset(
            mediaType: String = "public.jpeg",
            mediaKind: MediaKind = .image,
            durationMs: Int64? = nil
        ) throws -> UUID {
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
                        record_created_at_ms, record_updated_at_ms, file_name,
                        media_kind, duration_ms
                    ) VALUES (?, ?, 'photos', NULL, ?, 'current', ?, 1, 'available', ?, ?, NULL, ?, ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        photosSourceID.uuidString.lowercased(),
                        "LOCAL-\(assetID.uuidString.lowercased())",
                        mediaType,
                        FolderReconcileTestSupport.baseTimeMs,
                        FolderReconcileTestSupport.baseTimeMs,
                        mediaKind.rawValue,
                        durationMs,
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

private struct SimilarityVideoPosterStub: DerivedVideoPosterGenerating {
    func makePosterBytes(
        sourceFileDescriptorURL: URL,
        mediaType _: String,
        durationMs _: Int64,
        maximumPixelSize _: Int
    ) throws -> Data {
        let source = try Data(contentsOf: sourceFileDescriptorURL)
        if source.first == 1 {
            return try XCTUnwrap(
                SimilarityTestSupport.patternedImageData(seed: 101, uti: .png)
            )
        }
        if source.first == 2 {
            return try XCTUnwrap(
                SimilarityTestSupport.patternedImageData(seed: 180, uti: .png)
            )
        }
        return try XCTUnwrap(
            SimilarityTestSupport.patternedImageData(seed: 240, uti: .png)
        )
    }
}

private final class SimilarityPhotosOriginalStub: PhotosOriginalContentPort, @unchecked Sendable {
    private let lock = NSLock()
    var bytes: Data?
    let error: PhotosLibraryError?
    private var storedRequestCount = 0

    init(bytes: Data? = nil, error: PhotosLibraryError? = nil) {
        self.bytes = bytes
        self.error = error
    }

    var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    func requestOriginalImageData(localIdentifier: String) throws -> Data {
        _ = localIdentifier
        return try lock.withLock {
            storedRequestCount += 1
            if let error {
                throw error
            }
            guard let bytes else {
                throw PhotosLibraryError.libraryUnavailable
            }
            return bytes
        }
    }
}

private final class SimilarityPhotosFeatureImageStub: PhotosFeaturePrintImagePort, @unchecked Sendable {
    private let lock = NSLock()
    let bytes: Data?
    let error: PhotosLibraryError?
    private var storedRequestCount = 0

    init(bytes: Data? = nil, error: PhotosLibraryError? = nil) {
        self.bytes = bytes
        self.error = error
    }

    var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    func requestLocalFeatureImage(localIdentifier: String) throws -> Data {
        _ = localIdentifier
        return try lock.withLock {
            storedRequestCount += 1
            if let error {
                throw error
            }
            guard let bytes else {
                throw PhotosLibraryError.libraryUnavailable
            }
            return bytes
        }
    }
}
