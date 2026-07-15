import CryptoKit
import GRDB
import XCTest
@testable import ImageAll

final class FeaturePrintCacheTests: XCTestCase {
    func testGeneratesThenLoadsFeaturePrintWithoutMutatingSource() async throws {
        let environment = try DerivedImageTestSupport.TempEnvironment(label: #function)
        defer { environment.cleanup() }
        let sourceURL = try environment.seedAvailableAsset(
            contents: FolderReconcileTestSupport.minimalEncodedImageData(
                uti: "public.jpeg",
                width: 64,
                height: 64
            )
        )
        let before = try environment.sourceFileSnapshot(for: sourceURL)
        let bookmarkPort = FolderReconcileTestSupport.TestBookmarkPort(
            rootByBookmark: [environment.bookmark: environment.sourceRoot]
        )
        let sourceAccess = FolderReconcileSourceAccessService(
            repository: GRDBFolderSourceAuthorizationRepository(database: environment.database),
            bookmarkPort: bookmarkPort,
            rootValidator: FolderRootValidator(),
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )
        let service = FeaturePrintCacheService(
            database: environment.database,
            cachesDirectory: environment.cachesDirectory,
            sourceAccess: sourceAccess,
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )

        let generated = try await service.loadOrGenerate(assetID: environment.assetID)
        let cached = try await service.loadOrGenerate(assetID: environment.assetID)

        XCTAssertEqual(generated.origin, .generated)
        XCTAssertEqual(cached.origin, .cacheHit)
        XCTAssertEqual(cached.identity, generated.identity)
        XCTAssertEqual(cached.vectorData, generated.vectorData)
        XCTAssertGreaterThan(generated.elementCount, 0)
        XCTAssertEqual(generated.vectorData.count, generated.elementCount * MemoryLayout<Float>.size)
        XCTAssertEqual(Data(SHA256.hash(data: generated.vectorData)), generated.vectorSHA256)

        let after = try environment.sourceFileSnapshot(for: sourceURL)
        XCTAssertEqual(after, before)
        let persistedCount = try await environment.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feature") ?? -1
        }
        XCTAssertEqual(persistedCount, 1)
    }

    func testContentRevisionChangeGeneratesDistinctFeature() async throws {
        let environment = try DerivedImageTestSupport.TempEnvironment(label: #function)
        defer { environment.cleanup() }
        let sourceURL = try environment.seedAvailableAsset(
            contents: FolderReconcileTestSupport.minimalEncodedImageData(
                uti: "public.jpeg",
                width: 64,
                height: 64
            )
        )
        let bookmarkPort = FolderReconcileTestSupport.TestBookmarkPort(
            rootByBookmark: [environment.bookmark: environment.sourceRoot]
        )
        let service = FeaturePrintCacheService(
            database: environment.database,
            cachesDirectory: environment.cachesDirectory,
            sourceAccess: FolderReconcileSourceAccessService(
                repository: GRDBFolderSourceAuthorizationRepository(database: environment.database),
                bookmarkPort: bookmarkPort,
                rootValidator: FolderRootValidator(),
                clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
            ),
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )
        let first = try await service.loadOrGenerate(assetID: environment.assetID)

        let revisedSource = try XCTUnwrap(
            FolderReconcileTestSupport.minimalEncodedImageData(
                uti: "public.jpeg",
                width: 96,
                height: 64
            )
        )
        try revisedSource.write(to: sourceURL)
        let refreshed = try DerivedImageSourceReader().readSourceBytes(
            rootURL: environment.sourceRoot,
            relativePath: "photos/sample.jpg"
        ).initialFingerprint
        try await environment.database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET content_revision = 2 WHERE id = ?",
                arguments: [environment.assetID.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE file_fingerprint SET size_bytes = ?, modified_at_ns = ?, resource_id = ? WHERE asset_id = ?",
                arguments: [
                    refreshed.sizeBytes,
                    refreshed.modifiedAtNs,
                    refreshed.resourceID,
                    environment.assetID.uuidString.lowercased(),
                ]
            )
        }

        let context = try XCTUnwrap(
            GRDBDerivedImageCacheRepository(database: environment.database)
                .fetchGenerationContext(assetID: environment.assetID)
        )
        XCTAssertTrue(
            context.matchesHandleFacts(refreshed),
            "catalog=\(context.fingerprintSizeBytes),\(context.fingerprintModifiedAtNs),\(String(describing: context.fingerprintResourceID)); opened=\(refreshed)"
        )

        let revised = try await service.loadOrGenerate(assetID: environment.assetID)

        XCTAssertEqual(first.identity.contentRevision, 1)
        XCTAssertEqual(revised.identity.contentRevision, 2)
        XCTAssertEqual(revised.origin, .generated)
        let featureCount = try await environment.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feature") ?? -1
        }
        XCTAssertEqual(featureCount, 2)
    }
}
