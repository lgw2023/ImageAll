import GRDB
import XCTest
@testable import ImageAll

final class DerivedImageFingerprintTests: XCTestCase {
    func testFingerprintMismatchBeforeRenderRejects() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "pre-fp")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        try await env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE file_fingerprint SET size_bytes = size_bytes + 1 WHERE asset_id = ?",
                arguments: [env.assetID.uuidString.lowercased()]
            )
        }
        let (service, _) = env.makeService()
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected source changed")
        } catch DerivedImageError.derivedSourceChanged {
        }
        let count = try await env.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM derived_image_cache_entry") ?? 0
        }
        XCTAssertEqual(count, 0)
    }

    func testCorruptCacheEntryRebuildsWithoutChangingAsset() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "corrupt-cache")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.GenerousVolumeReader(availableBytes: 50 * 1024 * 1024 * 1024, totalBytes: 100 * 1024 * 1024 * 1024))
        let first = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        try await env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE derived_image_cache_entry SET byte_size = byte_size + 10 WHERE id = ?",
                arguments: [first.entryID.uuidString.lowercased()]
            )
        }
        let revisionBefore = try await env.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT content_revision FROM asset WHERE id = ?", arguments: [env.assetID.uuidString.lowercased()])
        }
        let second = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        XCTAssertEqual(second.origin, .generated)
        let revisionAfter = try await env.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT content_revision FROM asset WHERE id = ?", arguments: [env.assetID.uuidString.lowercased()])
        }
        XCTAssertEqual(revisionBefore, revisionAfter)
    }

    func testConcurrentSameKeyProducesOneEntry() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "concurrent")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.GenerousVolumeReader(availableBytes: 50 * 1024 * 1024 * 1024, totalBytes: 100 * 1024 * 1024 * 1024))
        async let a = service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridRegular))
        async let b = service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridRegular))
        let one = try await a
        let two = try await b
        XCTAssertEqual(one.encodedBytes, two.encodedBytes)
        let count = try await env.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM derived_image_cache_entry WHERE asset_id = ?", arguments: [env.assetID.uuidString.lowercased()])
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try env.listCacheObjectFiles().count, 1)
    }
}
