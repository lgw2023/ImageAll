import ImageIO
import GRDB
import XCTest
@testable import ImageAll

final class DerivedImageContractTests: XCTestCase {
    func testClosedErrorRawValues() {
        XCTAssertEqual(DerivedImageError.derivedAssetNotFound.rawValue, "derivedAssetNotFound")
        XCTAssertEqual(DerivedImageError.derivedInsufficientSpace.rawValue, "derivedInsufficientSpace")
        XCTAssertEqual(DerivedImageError.derivedCacheUnsafePath.rawValue, "derivedCacheUnsafePath")
    }

    func testEligibleAssetGeneratesWithoutPathLeakage() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "contract")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, bookmarkPort) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        let payload = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        XCTAssertEqual(payload.assetID, env.assetID)
        XCTAssertEqual(payload.representationVersion, 1)
        XCTAssertEqual(payload.pixelWidth, 256)
        XCTAssertEqual(payload.pixelHeight, 256)
        XCTAssertEqual(payload.origin, .generated)
        XCTAssertFalse(payload.encodedBytes.isEmpty)
        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
    }

    func testMissingAssetRejected() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "missing")
        defer { env.cleanup() }
        let (service, _) = env.makeService()
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: UUID(), variant: .preview))
            XCTFail("expected not found")
        } catch DerivedImageError.derivedAssetNotFound {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testHistoricalAssetIneligible() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "historical")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        try await env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET locator_state = 'historical' WHERE id = ?",
                arguments: [env.assetID.uuidString.lowercased()]
            )
        }
        let (service, _) = env.makeService()
        await assertDerivedError(service: service, assetID: env.assetID, expected: .derivedAssetIneligible)
    }

    func testExactKeyHitDoesNotReopenSource() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "hit")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, bookmarkPort) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridRegular))
        let startsAfterGenerate = bookmarkPort.scopeStartCount
        let second = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridRegular))
        XCTAssertEqual(second.origin, .cacheHit)
        XCTAssertEqual(bookmarkPort.scopeStartCount, startsAfterGenerate)
    }

    func testRevisionChangeMissesOldEntry() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "revision")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset(contentRevision: 1)
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        let first = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .preview))
        try await env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET content_revision = 2 WHERE id = ?",
                arguments: [env.assetID.uuidString.lowercased()]
            )
        }
        let second = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .preview))
        XCTAssertNotEqual(first.entryID, second.entryID)
        XCTAssertEqual(second.contentRevision, 2)
    }

    private func assertDerivedError(
        service: DerivedImageCacheService,
        assetID: UUID,
        expected: DerivedImageError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: assetID, variant: .gridSmall))
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as DerivedImageError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}

extension DerivedImageContractTests {
    func testDownloadedPhotosPreviewPersistsInDerivedCacheAcrossServiceRecreation() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "photos-downloaded-preview")
        defer { env.cleanup() }
        try await seedPhotosAsset(in: env)
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)

        let stored = try await service.storeDownloadedPreview(
            assetID: env.assetID,
            sourceBytes: FolderReconcileTestSupport.minimalJPEGData()
        )
        XCTAssertFalse(stored.isEmpty)
        let cached = try await service.loadDownloadedPreview(assetID: env.assetID)
        XCTAssertEqual(cached, stored)

        let (reopenedService, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        let reopened = try await reopenedService.loadDownloadedPreview(assetID: env.assetID)
        XCTAssertEqual(reopened, stored)

        let row = try env.database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT e.variant, e.pixel_width, e.pixel_height, s.kind AS source_kind
                FROM derived_image_cache_entry e
                JOIN asset a ON a.id = e.asset_id
                JOIN source s ON s.id = a.source_id
                WHERE e.asset_id = ?
                """,
                arguments: [env.assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(row?["variant"] as String?, DerivedImageVariant.preview.rawValue)
        XCTAssertLessThanOrEqual(row?["pixel_width"] as Int? ?? .max, 2_048)
        XCTAssertLessThanOrEqual(row?["pixel_height"] as Int? ?? .max, 2_048)
        XCTAssertEqual(row?["source_kind"] as String?, SourceKind.photos.rawValue)
    }

    func testDownloadedPhotosPreviewUsesSeparate512MiBLRUQuota() async throws {
        XCTAssertEqual(DownloadedPreviewCachePolicy.publishedQuotaBytes, 512 * 1024 * 1024)
        let env = try DerivedImageTestSupport.TempEnvironment(label: "photos-preview-quota")
        defer { env.cleanup() }
        try await seedPhotosAsset(in: env)
        let secondAssetID = UUID()
        try await seedAdditionalPhotosAsset(id: secondAssetID, localIdentifier: "def", in: env)
        let sourceBytes = FolderReconcileTestSupport.minimalJPEGData()
        let rendered = try DerivedImageRenderer().render(sourceBytes: sourceBytes, variant: .preview)
        let quota = try XCTUnwrap(UInt64(exactly: rendered.byteSize))
        let clock = MutableJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        let (service, _) = env.makeService(
            volumeReader: DerivedImageTestSupport.generousVolume,
            clock: clock,
            downloadedPreviewQuotaBytes: quota
        )

        _ = try await service.storeDownloadedPreview(assetID: env.assetID, sourceBytes: sourceBytes)
        clock.setNowMs(clock.nowMs + 1)
        let second = try await service.storeDownloadedPreview(assetID: secondAssetID, sourceBytes: sourceBytes)

        let evicted = try await service.loadDownloadedPreview(assetID: env.assetID)
        XCTAssertNil(evicted)
        let cachedSecond = try await service.loadDownloadedPreview(assetID: secondAssetID)
        XCTAssertEqual(cachedSecond, second)
        let cachedAssetIDs = try await env.database.pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT asset_id FROM derived_image_cache_entry ORDER BY asset_id"
            )
        }
        XCTAssertEqual(cachedAssetIDs, [secondAssetID.uuidString.lowercased()])
    }

    func testPhotosAssetIneligible() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "photos")
        defer { env.cleanup() }
        try await env.database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (id, kind, display_name, bookmark, scan_generation, dirty_epoch, state, created_at_ms, updated_at_ms)
                VALUES (?, 'photos', 'Library', NULL, 0, 0, 'active', ?, ?)
                """,
                arguments: [env.sourceID.uuidString.lowercased(), FolderReconcileTestSupport.baseTimeMs, FolderReconcileTestSupport.baseTimeMs]
            )
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, content_revision, availability,
                    record_created_at_ms, record_updated_at_ms
                ) VALUES (?, ?, 'photos', NULL, 'abc', 'current', 'public.heic', 1, 'available', ?, ?)
                """,
                arguments: [env.assetID.uuidString.lowercased(), env.sourceID.uuidString.lowercased(), FolderReconcileTestSupport.baseTimeMs, FolderReconcileTestSupport.baseTimeMs]
            )
        }
        let (service, _) = env.makeService()
        await assertDerivedError(service: service, assetID: env.assetID, expected: .derivedAssetIneligible)
    }

    private func seedPhotosAsset(in env: DerivedImageTestSupport.TempEnvironment) async throws {
        try await env.database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (id, kind, display_name, bookmark, scan_generation, dirty_epoch, state, created_at_ms, updated_at_ms)
                VALUES (?, 'photos', 'Library', NULL, 0, 0, 'active', ?, ?)
                """,
                arguments: [env.sourceID.uuidString.lowercased(), FolderReconcileTestSupport.baseTimeMs, FolderReconcileTestSupport.baseTimeMs]
            )
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, content_revision, availability,
                    record_created_at_ms, record_updated_at_ms, file_name
                ) VALUES (?, ?, 'photos', NULL, 'abc', 'current', 'public.jpeg', 1, 'available', ?, ?, 'photo.jpg')
                """,
                arguments: [env.assetID.uuidString.lowercased(), env.sourceID.uuidString.lowercased(), FolderReconcileTestSupport.baseTimeMs, FolderReconcileTestSupport.baseTimeMs]
            )
        }
    }

    private func seedAdditionalPhotosAsset(
        id: UUID,
        localIdentifier: String,
        in env: DerivedImageTestSupport.TempEnvironment
    ) async throws {
        try await env.database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, content_revision, availability,
                    record_created_at_ms, record_updated_at_ms, file_name
                ) VALUES (?, ?, 'photos', NULL, ?, 'current', 'public.jpeg', 1, 'available', ?, ?, 'second.jpg')
                """,
                arguments: [
                    id.uuidString.lowercased(),
                    env.sourceID.uuidString.lowercased(),
                    localIdentifier,
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                ]
            )
        }
    }
}
