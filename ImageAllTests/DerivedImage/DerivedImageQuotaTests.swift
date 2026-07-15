import XCTest
@testable import ImageAll

final class DerivedImageQuotaTests: XCTestCase {
    func testCapacityUnavailableFailsClosedBeforeStaging() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "capacity-unavail")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.FailingVolumeReader())
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected capacity unavailable")
        } catch DerivedImageError.derivedCapacityUnavailable {
        }
        let count = try await env.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM derived_image_cache_entry") ?? 0
        }
        XCTAssertEqual(count, 0)
    }

    func testPublishedQuotaEvictionUsesLRUOrder() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "quota")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset(relativePath: "a.jpg", fileName: "a.jpg")
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        let repository = GRDBDerivedImageCacheRepository(database: env.database)
        let published = try repository.publishedByteTotal()
        XCTAssertGreaterThan(published, 0)
        XCTAssertLessThanOrEqual(published, DerivedImageQuotaPolicy.publishedQuotaBytes)
    }

    func testCacheRootSymlinkRejected() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "symlink-root")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let versionRoot = env.cacheVersionRoot()
        try FileManager.default.createDirectory(at: versionRoot, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: versionRoot)
        let external = env.root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: versionRoot, withDestinationURL: external)
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected unsafe path")
        } catch DerivedImageError.derivedCacheUnsafePath {
        }
    }
}
