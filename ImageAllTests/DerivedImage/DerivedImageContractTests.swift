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

    func testClearCacheConvergesTenThousandRegisteredObjectsWithinScaleGate() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "cache-clear-scale")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let sourceBefore = try env.sourceTreeSnapshot()
        let entryCount = 10_000
        try await env.seedScaleCacheEntriesAndObjects(count: entryCount)
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        XCTAssertEqual(
            try service.cacheUsage(),
            DerivedImageCacheUsage(entryCount: entryCount, registeredBytes: UInt64(entryCount))
        )

        let startedAt = ContinuousClock.now
        let result = try await service.clearCache()
        let elapsed = ContinuousClock.now - startedAt

        XCTAssertEqual(result.removedEntries, entryCount)
        XCTAssertEqual(result.registeredBytesInvalidated, UInt64(entryCount))
        XCTAssertEqual(result.removedObjects, entryCount)
        XCTAssertEqual(result.removedBytes, UInt64(entryCount))
        XCTAssertFalse(result.partialReclaim)
        XCTAssertEqual(try service.cacheUsage(), .zero)
        let artifacts = try await env.cacheArtifactCounts()
        XCTAssertEqual(artifacts.entries, 0)
        XCTAssertEqual(artifacts.objects, 0)
        XCTAssertEqual(artifacts.stagingFiles, 0)
        XCTAssertEqual(try env.sourceTreeSnapshot(), sourceBefore)
        XCTAssertLessThan(elapsed, .seconds(15))

        let attachment = XCTAttachment(
            string: "entries=\(entryCount) clear_seconds=\(elapsed) removed_bytes=\(result.removedBytes)"
        )
        attachment.name = "ImageAll 10k cache clear baseline"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHundredJPEGsReconcileQueryGenerateAndHitCacheWithinImageIOGate() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "image-io-scale")
        defer { env.cleanup() }
        let assetCount = 100
        let jpeg = try XCTUnwrap(
            FolderReconcileTestSupport.minimalEncodedImageData(
                uti: "public.jpeg",
                width: 128,
                height: 96
            )
        )
        for index in 0 ..< assetCount {
            _ = try env.writeSource(
                relativePath: "scale/image-\(index).jpg",
                contents: jpeg
            )
        }
        let sourceBefore = try env.sourceTreeSnapshot()

        let pipelineStartedAt = ContinuousClock.now
        let reconcileStartedAt = ContinuousClock.now
        try await env.runProductionReconcileForFixture()
        let reconcileElapsed = ContinuousClock.now - reconcileStartedAt

        let queryStartedAt = ContinuousClock.now
        let query = GRDBAssetCatalogQueryRepository(database: env.database)
        let page = try query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(sourceIDs: [env.sourceID]),
                sort: .fileNameAscending,
                cursor: nil,
                limit: assetCount
            )
        )
        let terminalPage = try query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(sourceIDs: [env.sourceID]),
                sort: .fileNameAscending,
                cursor: try XCTUnwrap(page.nextCursor),
                limit: assetCount
            )
        )
        let queryElapsed = ContinuousClock.now - queryStartedAt
        XCTAssertEqual(page.items.count, assetCount)
        XCTAssertTrue(terminalPage.items.isEmpty)
        XCTAssertNil(terminalPage.nextCursor)

        let (service, bookmarkPort) = env.makeService(
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        let generationStartedAt = ContinuousClock.now
        var generatedBytes = 0
        for item in page.items {
            let payload = try await service.loadOrGenerate(
                DerivedImageRequest(assetID: item.assetID, variant: .gridRegular)
            )
            XCTAssertEqual(payload.origin, .generated)
            XCTAssertEqual(payload.pixelWidth, 512)
            XCTAssertEqual(payload.pixelHeight, 512)
            XCTAssertFalse(payload.encodedBytes.isEmpty)
            generatedBytes += payload.encodedBytes.count
        }
        let generationElapsed = ContinuousClock.now - generationStartedAt
        let scopeStartsAfterGeneration = bookmarkPort.scopeStartCount

        let cacheHitStartedAt = ContinuousClock.now
        for item in page.items {
            let payload = try await service.loadOrGenerate(
                DerivedImageRequest(assetID: item.assetID, variant: .gridRegular)
            )
            XCTAssertEqual(payload.origin, .cacheHit)
        }
        let cacheHitElapsed = ContinuousClock.now - cacheHitStartedAt
        let pipelineElapsed = ContinuousClock.now - pipelineStartedAt

        XCTAssertEqual(bookmarkPort.scopeStartCount, scopeStartsAfterGeneration)
        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
        XCTAssertEqual(
            try service.cacheUsage().entryCount,
            assetCount
        )
        let artifacts = try await env.cacheArtifactCounts()
        XCTAssertEqual(artifacts.entries, assetCount)
        XCTAssertEqual(artifacts.objects, assetCount)
        XCTAssertEqual(artifacts.stagingFiles, 0)
        XCTAssertEqual(try env.sourceTreeSnapshot(), sourceBefore)
        XCTAssertLessThan(pipelineElapsed, .seconds(30))

        let attachment = XCTAttachment(
            string: "assets=\(assetCount) reconcile_seconds=\(reconcileElapsed) "
                + "query_seconds=\(queryElapsed) generation_seconds=\(generationElapsed) "
                + "cache_hit_seconds=\(cacheHitElapsed) pipeline_seconds=\(pipelineElapsed) "
                + "generated_bytes=\(generatedBytes)"
        )
        attachment.name = "ImageAll 100-image end-to-end I/O baseline"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMixedSupportedFormatsReconcileAndLoadConcurrentlyThroughLibraryPipeline() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "mixed-image-io")
        defer { env.cleanup() }
        let fixtures: [(extension: String, mediaType: String, data: Data)] = [
            ("jpg", "public.jpeg", try XCTUnwrap(
                FolderReconcileTestSupport.minimalEncodedImageData(
                    uti: "public.jpeg", width: 128, height: 96
                )
            )),
            ("png", "public.png", try XCTUnwrap(
                FolderReconcileTestSupport.minimalEncodedImageData(
                    uti: "public.png", width: 96, height: 128
                )
            )),
            ("heic", "public.heic", try XCTUnwrap(FolderReconcileTestSupport.minimalHEICData())),
            ("heif", "public.heif", FolderReconcileTestSupport.minimalHEIFData()),
            ("tiff", "public.tiff", try XCTUnwrap(FolderReconcileTestSupport.minimalTIFFData())),
            ("webp", "org.webmproject.webp", FolderReconcileTestSupport.minimalWebPData()),
        ]
        let copiesPerFormat = 5
        for fixture in fixtures {
            XCTAssertEqual(
                FolderReconcileTestSupport.imageIOActualType(for: fixture.data),
                fixture.mediaType
            )
            for index in 0 ..< copiesPerFormat {
                _ = try env.writeSource(
                    relativePath: "mixed/\(fixture.extension)-\(index).\(fixture.extension)",
                    contents: fixture.data
                )
            }
        }
        let assetCount = fixtures.count * copiesPerFormat
        let sourceBefore = try env.sourceTreeSnapshot()

        let pipelineStartedAt = ContinuousClock.now
        try await env.runProductionReconcileForFixture()
        let query = GRDBAssetCatalogQueryRepository(database: env.database)
        let page = try query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(sourceIDs: [env.sourceID]),
                sort: .fileNameAscending,
                cursor: nil,
                limit: assetCount
            )
        )
        let terminalPage = try query.fetchAssetPage(
            AssetPageRequest(
                filter: AssetPageFilter(sourceIDs: [env.sourceID]),
                sort: .fileNameAscending,
                cursor: try XCTUnwrap(page.nextCursor),
                limit: assetCount
            )
        )
        XCTAssertEqual(page.items.count, assetCount)
        XCTAssertTrue(terminalPage.items.isEmpty)
        XCTAssertNil(terminalPage.nextCursor)
        XCTAssertEqual(
            Dictionary(grouping: page.items, by: \.mediaType).mapValues(\.count),
            Dictionary(uniqueKeysWithValues: fixtures.map { ($0.mediaType, copiesPerFormat) })
        )

        let (service, bookmarkPort) = env.makeService(
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        let loader = DerivedImageTestSupport.makeLibraryAssetImageLoader(
            database: env.database,
            fileImages: service,
            maximumConcurrentLoads: 4
        )
        let coldStartedAt = ContinuousClock.now
        let coldPayloads = try await loadGridImages(page.items, using: loader)
        let coldElapsed = ContinuousClock.now - coldStartedAt
        XCTAssertEqual(coldPayloads.count, assetCount)
        try assertRegularGridPayloads(coldPayloads)
        let scopeStartsAfterColdPass = bookmarkPort.scopeStartCount

        let warmStartedAt = ContinuousClock.now
        let warmPayloads = try await loadGridImages(page.items, using: loader)
        let warmElapsed = ContinuousClock.now - warmStartedAt
        let pipelineElapsed = ContinuousClock.now - pipelineStartedAt
        XCTAssertEqual(warmPayloads.count, assetCount)
        try assertRegularGridPayloads(warmPayloads)

        XCTAssertEqual(bookmarkPort.scopeStartCount, scopeStartsAfterColdPass)
        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
        XCTAssertEqual(try service.cacheUsage().entryCount, assetCount)
        let artifacts = try await env.cacheArtifactCounts()
        XCTAssertEqual(artifacts.entries, assetCount)
        XCTAssertEqual(artifacts.objects, assetCount)
        XCTAssertEqual(artifacts.stagingFiles, 0)
        XCTAssertEqual(try env.sourceTreeSnapshot(), sourceBefore)
        XCTAssertLessThan(pipelineElapsed, .seconds(30))

        let attachment = XCTAttachment(
            string: "assets=\(assetCount) formats=\(fixtures.count) copies_per_format=\(copiesPerFormat) "
                + "cold_seconds=\(coldElapsed) warm_seconds=\(warmElapsed) "
                + "pipeline_seconds=\(pipelineElapsed)"
        )
        attachment.name = "ImageAll mixed-format concurrent I/O baseline"
        attachment.lifetime = .keepAlways
        add(attachment)
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

    private func loadGridImages(
        _ items: [AssetGridItemProjection],
        using loader: LibraryAssetImageLoader
    ) async throws -> [Data] {
        try await withThrowingTaskGroup(of: Data.self) { group in
            for item in items {
                group.addTask {
                    try await loader.load(assetID: item.assetID, variant: .grid)
                }
            }
            var payloads: [Data] = []
            for try await payload in group {
                payloads.append(payload)
            }
            return payloads
        }
    }

    private func assertRegularGridPayloads(
        _ payloads: [Data],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertFalse(payloads.isEmpty, file: file, line: line)
        for payload in payloads {
            XCTAssertFalse(payload.isEmpty, file: file, line: line)
            let source = try XCTUnwrap(
                CGImageSourceCreateWithData(payload as CFData, nil),
                file: file,
                line: line
            )
            let image = try XCTUnwrap(
                CGImageSourceCreateImageAtIndex(source, 0, nil),
                file: file,
                line: line
            )
            XCTAssertEqual(image.width, 512, file: file, line: line)
            XCTAssertEqual(image.height, 512, file: file, line: line)
        }
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
    func testLocalPhotosThumbnailPersistsInDerivedCacheAcrossServiceRecreation() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "photos-local-thumbnail")
        defer { env.cleanup() }
        try await seedPhotosAsset(in: env)
        let sourceBytes = FolderReconcileTestSupport.minimalJPEGData()
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)

        let stored = try await service.storePhotoThumbnail(
            assetID: env.assetID,
            sourceBytes: sourceBytes
        )
        XCTAssertFalse(stored.isEmpty)
        XCTAssertEqual(try service.loadPhotoThumbnail(assetID: env.assetID), stored)

        let (reopenedService, _) = env.makeService(
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        XCTAssertEqual(try reopenedService.loadPhotoThumbnail(assetID: env.assetID), stored)

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
        XCTAssertEqual(row?["variant"] as String?, DerivedImageVariant.gridRegular.rawValue)
        XCTAssertEqual(row?["pixel_width"] as Int?, 512)
        XCTAssertEqual(row?["pixel_height"] as Int?, 512)
        XCTAssertEqual(row?["source_kind"] as String?, SourceKind.photos.rawValue)
    }

    func testCorruptLocalPhotosThumbnailIsRejectedAndCanBeRebuilt() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "photos-local-thumbnail-corrupt")
        defer { env.cleanup() }
        try await seedPhotosAsset(in: env)
        let sourceBytes = FolderReconcileTestSupport.minimalJPEGData()
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)

        _ = try await service.storePhotoThumbnail(
            assetID: env.assetID,
            sourceBytes: sourceBytes
        )
        let storedEntry = try await env.database.pool.read { db -> (UUID, DerivedImageStorageFormat)? in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, storage_format
                FROM derived_image_cache_entry
                WHERE asset_id = ? AND variant = 'gridRegular'
                """,
                arguments: [env.assetID.uuidString.lowercased()]
            ),
                let id = UUID(uuidString: row["id"]),
                let format = DerivedImageStorageFormat(rawValue: row["storage_format"])
            else {
                return nil
            }
            return (id, format)
        }
        let entry = try XCTUnwrap(storedEntry)
        try env.tamperCacheObjectSameByteSize(entryID: entry.0, format: entry.1)

        XCTAssertNil(try service.loadPhotoThumbnail(assetID: env.assetID))
        let invalidated = try await env.cacheArtifactCounts()
        XCTAssertEqual(invalidated.entries, 0)
        XCTAssertEqual(invalidated.objects, 0)

        let rebuilt = try await service.storePhotoThumbnail(
            assetID: env.assetID,
            sourceBytes: sourceBytes
        )
        XCTAssertEqual(try service.loadPhotoThumbnail(assetID: env.assetID), rebuilt)
        let rebuiltCounts = try await env.cacheArtifactCounts()
        XCTAssertEqual(rebuiltCounts.entries, 1)
        XCTAssertEqual(rebuiltCounts.objects, 1)
        XCTAssertEqual(rebuiltCounts.stagingFiles, 0)
    }

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
