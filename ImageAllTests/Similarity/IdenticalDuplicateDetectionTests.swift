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

    func testPhotosLocatorAssetIsIneligible() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }
        let photosAssetID = try env.seedPhotosAsset()
        let completion = env.makeCompletionService()
        XCTAssertThrowsError(try completion.completeFolderAsset(assetID: photosAssetID)) { error in
            let typed = error as? FingerprintCompletionError
            XCTAssertTrue(typed == .ineligible || typed == .notFound, "got \(String(describing: typed))")
        }
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
}

private enum SimilarityTestSupport {
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

        func makeCompletionService() -> FingerprintCompletionService {
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
                clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
            )
        }

        @discardableResult
        func seedAsset(
            relativePath: String,
            contents: Data,
            mediaType: String = "public.jpeg"
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
                        locator_state, media_type, content_revision, availability,
                        record_created_at_ms, record_updated_at_ms, file_name
                    ) VALUES (?, ?, 'file', ?, NULL, 'current', ?, 1, 'available', ?, ?, ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(),
                        sourceID.uuidString.lowercased(),
                        relativePath,
                        mediaType,
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
}
