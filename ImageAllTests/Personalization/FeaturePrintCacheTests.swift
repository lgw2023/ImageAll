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
}
