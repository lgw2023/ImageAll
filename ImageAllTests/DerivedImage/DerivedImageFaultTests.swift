import GRDB
import XCTest
@testable import ImageAll

final class DerivedImageFaultTests: XCTestCase {
    func testStagingCreateFaultLeavesNoEntry() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "fault-staging")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, _) = env.makeService(
            faultInjector: DerivedImageTestSupport.SinglePointFaultInjector(point: .stagingCreate),
            volumeReader: DerivedImageTestSupport.GenerousVolumeReader(availableBytes: 50 * 1024 * 1024 * 1024, totalBytes: 100 * 1024 * 1024 * 1024)
        )
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected persistence failure")
        } catch DerivedImageError.derivedCachePersistenceFailed {
        }
        let entryCount = try await env.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM derived_image_cache_entry") ?? 0
        }
        XCTAssertEqual(entryCount, 0)
        XCTAssertTrue(try env.listCacheObjectFiles().isEmpty)
    }

    func testAfterRenameBeforeDBFaultLeavesOrphanOnly() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "fault-orphan")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, _) = env.makeService(
            faultInjector: DerivedImageTestSupport.SinglePointFaultInjector(point: .afterRenameBeforeDB),
            volumeReader: DerivedImageTestSupport.GenerousVolumeReader(availableBytes: 50 * 1024 * 1024 * 1024, totalBytes: 100 * 1024 * 1024 * 1024)
        )
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected persistence failure")
        } catch DerivedImageError.derivedCachePersistenceFailed {
        }
        let entryCount = try await env.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM derived_image_cache_entry") ?? 0
        }
        XCTAssertEqual(entryCount, 0)
        XCTAssertEqual(try env.listCacheObjectFiles().count, 1)
        let maintenance = try await service.performMaintenance()
        XCTAssertEqual(maintenance.removedObjects, 1)
        let second = try await service.performMaintenance()
        XCTAssertEqual(second.removedObjects, 0)
    }

    func testSuccessfulPublishThenReopenDatabaseReadsEntry() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "reopen")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.GenerousVolumeReader(availableBytes: 50 * 1024 * 1024 * 1024, totalBytes: 100 * 1024 * 1024 * 1024))
        _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .preview))
        let reopened = try CatalogDatabase.open(at: env.databaseURL)
        let reopenedService = DerivedImageCacheService(
            database: reopened,
            cachesDirectory: env.cachesDirectory,
            sourceAccess: FolderReconcileSourceAccessService(
                repository: GRDBFolderSourceAuthorizationRepository(database: reopened),
                bookmarkPort: FolderReconcileTestSupport.TestBookmarkPort(rootByBookmark: [env.bookmark: env.sourceRoot]),
                rootValidator: FolderRootValidator(),
                clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
            ),
            volumeReader: DerivedImageTestSupport.GenerousVolumeReader(availableBytes: 50 * 1024 * 1024 * 1024, totalBytes: 100 * 1024 * 1024 * 1024)
        )
        let hit = try await reopenedService.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .preview))
        XCTAssertEqual(hit.origin, .cacheHit)
    }
}
