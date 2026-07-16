import ImageIO
import GRDB
import XCTest
@testable import ImageAll

final class DerivedImageContractTests: XCTestCase {
    func testRegisteredCacheUsageAggregatesAllPreviewVariants() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "cache-usage")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, _) = env.makeService()
        try await env.insertSyntheticCacheEntry(id: UUID(), variant: .gridSmall, byteSize: 100)
        try await env.insertSyntheticCacheEntry(id: UUID(), variant: .gridRegular, byteSize: 200)
        try await env.insertSyntheticCacheEntry(id: UUID(), variant: .preview, byteSize: 300)

        let usage = try service.cacheUsage()

        XCTAssertEqual(usage, DerivedImageCacheUsage(entryCount: 3, registeredBytes: 600))
    }

    func testClearInvalidatesPreviewCacheAndPreservesCatalogFacts() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "cache-clear")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        for variant in DerivedImageVariant.allCases {
            _ = try await service.loadOrGenerate(
                DerivedImageRequest(assetID: env.assetID, variant: variant)
            )
        }
        _ = try env.plantLegalStagingOrphan(bytes: Data([0x01, 0x02]))
        try await seedFactsThatCacheClearMustPreserve(in: env)
        let preservedTables = [
            "asset_tag_decision", "feature", "tag_model_revision", "tag_model_sample",
            "tag_model", "prediction", "job",
        ]
        let before = try await rowCounts(preservedTables, in: env)

        let result = try await service.clearCache()

        XCTAssertEqual(result.removedEntries, 3)
        XCTAssertGreaterThan(result.registeredBytesInvalidated, 0)
        XCTAssertFalse(result.partialReclaim)
        XCTAssertEqual(try service.cacheUsage(), .zero)
        let artifacts = try await env.cacheArtifactCounts()
        let after = try await rowCounts(preservedTables, in: env)
        XCTAssertEqual(artifacts.objects, 0)
        XCTAssertEqual(artifacts.stagingFiles, 0)
        XCTAssertEqual(after, before)
    }

    func testClearRejectsObjectSymlinkBeforeInvalidatingEntries() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "cache-clear-symlink")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        _ = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
        )
        let sentinelBytes = Data("outside-cache".utf8)
        let sentinel = try env.plantExternalSentinel(bytes: sentinelBytes)
        try env.plantObjectSymlinkInObjectsTree(linkTarget: sentinel, entryID: UUID())

        do {
            _ = try await service.clearCache()
            XCTFail("expected unsafe path refusal")
        } catch let error as DerivedImageError {
            XCTAssertEqual(error, .derivedCacheUnsafePath)
        }

        XCTAssertEqual(try service.cacheUsage().entryCount, 1)
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
    }

    func testClearDeletionFailureInvalidatesEntriesAndReportsPartialReclaim() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "cache-clear-delete-fault")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (writer, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        _ = try await writer.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
        )
        let fault = DerivedImageTestSupport.LoggingStoreFaultInjector(
            faultPoint: .evictObjectDelete
        )
        let (service, _) = env.makeService(
            faultInjector: fault,
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        let result = try await service.clearCache()

        XCTAssertTrue(result.partialReclaim)
        XCTAssertEqual(result.removedEntries, 1)
        XCTAssertEqual(try service.cacheUsage(), .zero)
        let artifacts = try await env.cacheArtifactCounts()
        XCTAssertEqual(artifacts.objects, 1)
    }

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

    private func rowCounts(
        _ tables: [String],
        in env: DerivedImageTestSupport.TempEnvironment
    ) async throws -> [String: Int] {
        try await env.database.pool.read { db in
            try Dictionary(uniqueKeysWithValues: tables.map { table in
                (table, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0)
            })
        }
    }

    private func seedFactsThatCacheClearMustPreserve(
        in env: DerivedImageTestSupport.TempEnvironment
    ) async throws {
        let tagID = UUID().uuidString.lowercased()
        let assetID = env.assetID.uuidString.lowercased()
        try await env.database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms) VALUES (?, 'Keep', 'keep', 'active', 1, 1)",
                arguments: [tagID]
            )
            try db.execute(
                sql: "INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms) VALUES (?, ?, 'accepted', 1)",
                arguments: [assetID, tagID]
            )
            try db.execute(
                sql: """
                INSERT INTO feature (
                    asset_id, provider, request_revision, preprocessing_revision,
                    content_revision, element_type, element_count, byte_count,
                    vector_sha256, cache_key, created_at_ms
                ) VALUES (?, 'vision-feature-print', 1, 1, 1, 'float32', 1, 4, ?, 'objects/aa/keep.fprint', 1)
                """,
                arguments: [assetID, Data(repeating: 0x11, count: 32)]
            )
            try db.execute(
                sql: """
                INSERT INTO tag_model_revision (
                    tag_id, revision, provider, request_revision, preprocessing_revision,
                    threshold, positive_count, negative_count, neighbor_count,
                    sample_budget_per_role, created_at_ms
                ) VALUES (?, 1, 'vision-feature-print', 1, 1, 0.5, 1, 1, 1, 1, 1)
                """,
                arguments: [tagID]
            )
            try db.execute(
                sql: """
                INSERT INTO tag_model_sample (
                    tag_id, model_revision, asset_id, content_revision, role, rank,
                    provider, request_revision, preprocessing_revision
                ) VALUES (?, 1, ?, 1, 'positive', 0, 'vision-feature-print', 1, 1)
                """,
                arguments: [tagID, assetID]
            )
            try db.execute(
                sql: "INSERT INTO tag_model (tag_id, current_revision, updated_at_ms) VALUES (?, 1, 1)",
                arguments: [tagID]
            )
            try db.execute(
                sql: "INSERT INTO prediction (asset_id, tag_id, content_revision, model_revision, score, state, created_at_ms) VALUES (?, ?, 1, 1, 0.75, 'pendingReview', 1)",
                arguments: [assetID, tagID]
            )
        }
        _ = try JobTestSupport.enqueueDefault(
            queue: JobTestSupport.makeQueue(database: env.database),
            sourceID: env.sourceID
        )
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
        let cached = try service.loadDownloadedPreview(assetID: env.assetID)
        XCTAssertEqual(cached, stored)

        let (reopenedService, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        let reopened = try reopenedService.loadDownloadedPreview(assetID: env.assetID)
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

        let evicted = try service.loadDownloadedPreview(assetID: env.assetID)
        XCTAssertNil(evicted)
        let cachedSecond = try service.loadDownloadedPreview(assetID: secondAssetID)
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
