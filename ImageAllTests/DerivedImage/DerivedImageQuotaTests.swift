import XCTest
@testable import ImageAll

final class DerivedImageQuotaTests: XCTestCase {
    private let gib = DerivedImageTestSupport.gib

    // MARK: - 1. Fixed integer policy boundaries

    func testQuotaPolicyPublishedQuotaReserveAndArithmeticBoundaries() {
        XCTAssertEqual(DerivedImageQuotaPolicy.publishedQuotaBytes, 20 * gib)

        let total100GiBMinus1 = (100 * gib) - 1
        XCTAssertEqual(
            DerivedImageQuotaPolicy.reserveBytes(totalVolumeBytes: total100GiBMinus1),
            5 * gib
        )

        let total100GiB = 100 * gib
        XCTAssertEqual(
            DerivedImageQuotaPolicy.reserveBytes(totalVolumeBytes: total100GiB),
            5 * gib
        )

        let total100GiBPlus20 = (100 * gib) + 20
        XCTAssertEqual(
            DerivedImageQuotaPolicy.reserveBytes(totalVolumeBytes: total100GiBPlus20),
            (5 * gib) + 1
        )

        let total200GiB = 200 * gib
        XCTAssertEqual(
            DerivedImageQuotaPolicy.reserveBytes(totalVolumeBytes: total200GiB),
            10 * gib
        )

        let totalBelowMinimum = 4 * gib
        XCTAssertNil(DerivedImageQuotaPolicy.reserveBytes(totalVolumeBytes: totalBelowMinimum))

        let exactSum = DerivedImageQuotaPolicy.adding(10, 20)
        XCTAssertEqual(exactSum, 30)
        XCTAssertNil(DerivedImageQuotaPolicy.adding(UInt64.max, 1))
        XCTAssertNil(DerivedImageQuotaPolicy.subtracting(0, 1))
    }

    // MARK: - 2. Capacity fail closed

    func testCapacityUnavailableNilVolumeReaderFailsClosedBeforeStaging() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "capacity-nil")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let catalogBefore = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        let (service, bookmarkPort) = env.makeService(
            volumeReader: DerivedImageTestSupport.FailingVolumeReader()
        )
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected capacity unavailable")
        } catch DerivedImageError.derivedCapacityUnavailable {
        }
        try await DerivedImageTestSupport.assertCapacityFailClosedUntouched(
            env: env,
            bookmarkPort: bookmarkPort,
            catalogBefore: catalogBefore
        )
        _ = fileURL
    }

    func testCapacityUnavailableThrowingVolumeReaderFailsClosedBeforeStaging() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "capacity-throw")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let catalogBefore = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        let (service, bookmarkPort) = env.makeService(
            volumeReader: DerivedImageTestSupport.ThrowingVolumeReader()
        )
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected capacity unavailable")
        } catch DerivedImageError.derivedCapacityUnavailable {
        } catch {
            XCTFail("expected derivedCapacityUnavailable, got \(error)")
        }
        try await DerivedImageTestSupport.assertCapacityFailClosedUntouched(
            env: env,
            bookmarkPort: bookmarkPort,
            catalogBefore: catalogBefore
        )
        _ = fileURL
    }

    // MARK: - 3. Reserve admission boundary

    func testReserveAdmissionSucceedsWhenAvailableEqualsReservePlusIncoming() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "reserve-admit-ok")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let artifact = try DerivedImageTestSupport.renderIncomingGridSmallArtifact()
        let incoming = UInt64(artifact.byteSize)
        let total = 100 * gib
        let reserve = try XCTUnwrap(DerivedImageQuotaPolicy.reserveBytes(totalVolumeBytes: total))
        let available = reserve + incoming
        let (service, bookmarkPort) = env.makeService(
            volumeReader: DerivedImageTestSupport.GenerousVolumeReader(
                availableBytes: available,
                totalBytes: total
            )
        )
        let published = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
        )
        XCTAssertEqual(published.origin, .generated)
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 1)
        XCTAssertEqual(counts.objects, 1)
        XCTAssertEqual(counts.stagingFiles, 0)
        DerivedImageTestSupport.assertBookmarkPortScopeBalanced(bookmarkPort)
    }

    func testReserveAdmissionRejectsWhenAvailableOneByteBelowReservePlusIncoming() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "reserve-admit-fail")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let catalogBefore = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        let artifact = try DerivedImageTestSupport.renderIncomingGridSmallArtifact()
        let incoming = UInt64(artifact.byteSize)
        let total = 100 * gib
        let reserve = try XCTUnwrap(DerivedImageQuotaPolicy.reserveBytes(totalVolumeBytes: total))
        let available = reserve + incoming - 1
        let (service, bookmarkPort) = env.makeService(
            volumeReader: DerivedImageTestSupport.GenerousVolumeReader(
                availableBytes: available,
                totalBytes: total
            )
        )
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected insufficient space")
        } catch DerivedImageError.derivedInsufficientSpace {
        }
        try await DerivedImageTestSupport.assertCapacityFailClosedUntouched(
            env: env,
            bookmarkPort: bookmarkPort,
            catalogBefore: catalogBefore
        )
        _ = fileURL
    }

    func testInteractiveRequestFallsBackToMemoryWhenReserveCannotBeMet() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "reserve-memory-fallback")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let artifact = try DerivedImageTestSupport.renderIncomingGridSmallArtifact()
        let incoming = UInt64(artifact.byteSize)
        let total = 100 * gib
        let reserve = try XCTUnwrap(DerivedImageQuotaPolicy.reserveBytes(totalVolumeBytes: total))
        let (service, bookmarkPort) = env.makeService(
            volumeReader: DerivedImageTestSupport.GenerousVolumeReader(
                availableBytes: reserve + incoming - 1,
                totalBytes: total
            )
        )

        let payload = try await service.loadOrGenerate(
            DerivedImageRequest(
                assetID: env.assetID,
                variant: .gridSmall,
                persistence: .memoryFallbackAllowed
            )
        )

        XCTAssertEqual(payload.origin, .memoryOnly)
        XCTAssertFalse(payload.encodedBytes.isEmpty)
        try await DerivedImageTestSupport.assertZeroCacheArtifacts(env: env)
        DerivedImageTestSupport.assertBookmarkPortScopeBalanced(bookmarkPort)
    }

    // MARK: - 4. Low-space eviction requery

    func testEvictionRequeriesVolumeAfterObjectDeleteAndThenAdmits() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "evict-requery-ok")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let artifact = try DerivedImageTestSupport.renderIncomingGridSmallArtifact()
        let incoming = UInt64(artifact.byteSize)
        let total = 100 * gib
        let reserve = try XCTUnwrap(DerivedImageQuotaPolicy.reserveBytes(totalVolumeBytes: total))
        let victim = try await seedVictimWithInflatedQuotaEntry(env: env, logicalBytes: 10 * gib)
        let reader = DerivedImageTestSupport.SequentialVolumeReader(
            sequence: [
                DerivedImageVolumeFacts(availableBytes: reserve + incoming - 1, totalBytes: total),
                DerivedImageVolumeFacts(availableBytes: reserve + incoming, totalBytes: total),
            ]
        )
        let (service, _) = env.makeService(volumeReader: reader)
        let published = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
        )
        XCTAssertEqual(published.origin, .generated)
        XCTAssertEqual(reader.queryCount, 2)
        let victimExists = try await env.cacheEntryExists(id: victim)
        XCTAssertFalse(victimExists)
        XCTAssertFalse(env.finalObjectExists(entryID: victim, format: .jpeg))
    }

    func testEvictionNeverTreatsLogicalByteSizeAsAvailableCapacityRecovery() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "evict-never-enough")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let catalogBefore = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        let artifact = try DerivedImageTestSupport.renderIncomingGridSmallArtifact()
        let incoming = UInt64(artifact.byteSize)
        let total = 100 * gib
        let reserve = try XCTUnwrap(DerivedImageQuotaPolicy.reserveBytes(totalVolumeBytes: total))
        _ = try await seedVictimWithInflatedQuotaEntry(env: env, logicalBytes: 10 * gib)
        let reader = DerivedImageTestSupport.ConstantVolumeReader(
            availableBytes: reserve + incoming - 1,
            totalBytes: total
        )
        let (service, bookmarkPort) = env.makeService(volumeReader: reader)
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected insufficient space")
        } catch DerivedImageError.derivedInsufficientSpace {
        }
        try await DerivedImageTestSupport.assertZeroCacheArtifacts(env: env)
        let catalogAfter = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        DerivedImageTestSupport.assertFaultMatrixCatalogSnapshotUnchanged(
            before: catalogBefore,
            after: catalogAfter
        )
        DerivedImageTestSupport.assertBookmarkPortScopeBalanced(bookmarkPort)
        _ = fileURL
    }

    // MARK: - 5. Published quota and stable LRU tie-break

    func testPublishedQuotaEvictsStableLRUSmallerUUIDWhenLastAccessedEqual() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "quota-lru-stable")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset(relativePath: "a.jpg", fileName: "a.jpg")
        let catalogBefore = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        let sourceBefore = try env.sourceTreeSnapshot()
        let jobBefore = try await env.jobRecordCount()
        let tagBefore = try await env.tagRecordCount()
        let artifact = try DerivedImageTestSupport.renderIncomingGridSmallArtifact()
        let largerID = UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!
        let smallerID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let tieMs: Int64 = 100
        let tenGiB = Int64(10 * gib)
        let hash = DerivedImageTestSupport.sha256Data(for: artifact.bytes)
        try env.plantUnreferencedFinalObject(entryID: largerID, bytes: artifact.bytes)
        try env.plantUnreferencedFinalObject(entryID: smallerID, bytes: artifact.bytes)
        try await env.database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO derived_image_cache_entry (
                    id, asset_id, content_revision, representation_version, variant,
                    storage_format, pixel_width, pixel_height, byte_size, encoded_sha256,
                    created_at_ms, last_accessed_at_ms
                ) VALUES (?, ?, 1, 1, 'gridRegular', 'jpeg', 512, 512, ?, ?, 200, ?)
                """,
                arguments: [
                    largerID.uuidString.lowercased(),
                    env.assetID.uuidString.lowercased(),
                    tenGiB,
                    hash,
                    tieMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO derived_image_cache_entry (
                    id, asset_id, content_revision, representation_version, variant,
                    storage_format, pixel_width, pixel_height, byte_size, encoded_sha256,
                    created_at_ms, last_accessed_at_ms
                ) VALUES (?, ?, 1, 1, 'preview', 'jpeg', 256, 256, ?, ?, 300, ?)
                """,
                arguments: [
                    smallerID.uuidString.lowercased(),
                    env.assetID.uuidString.lowercased(),
                    tenGiB,
                    hash,
                    tieMs,
                ]
            )
        }
        let (service, bookmarkPort) = env.makeService(
            volumeReader: DerivedImageTestSupport.GenerousVolumeReader(
                availableBytes: 50 * gib,
                totalBytes: 100 * gib
            )
        )
        _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        let smallerExists = try await env.cacheEntryExists(id: smallerID)
        let largerExists = try await env.cacheEntryExists(id: largerID)
        XCTAssertFalse(smallerExists, "stable LRU must evict lexicographically smaller UUID at tied timestamp")
        XCTAssertTrue(largerExists)
        XCTAssertFalse(env.finalObjectExists(entryID: smallerID, format: .jpeg))
        XCTAssertTrue(env.finalObjectExists(entryID: largerID, format: .jpeg))
        let catalogAfter = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        XCTAssertEqual(catalogAfter.catalogFacts, catalogBefore.catalogFacts)
        XCTAssertEqual(try env.sourceTreeSnapshot(), sourceBefore)
        XCTAssertEqual(catalogAfter.jobCount, jobBefore)
        XCTAssertEqual(catalogAfter.tagCount, tagBefore)
        DerivedImageTestSupport.assertBookmarkPortScopeBalanced(bookmarkPort)
        _ = fileURL
    }

    // MARK: - 6. Object delete failure during eviction

    func testEvictObjectDeleteFailureLeavesOrphanAndReturnsInsufficientSpace() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "evict-object-delete-fail")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let sentinelURL = try env.plantExternalSentinel()
        let sentinelBefore = try env.sourceFileSnapshot(for: sentinelURL)
        let catalogBefore = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        let sourceBefore = try env.sourceTreeSnapshot()
        let victim = try await seedVictimWithInflatedQuotaEntry(env: env, logicalBytes: 10 * gib)
        let artifact = try DerivedImageTestSupport.renderIncomingGridSmallArtifact()
        let incoming = UInt64(artifact.byteSize)
        let total = 100 * gib
        let reserve = try XCTUnwrap(DerivedImageQuotaPolicy.reserveBytes(totalVolumeBytes: total))
        let reader = DerivedImageTestSupport.ConstantVolumeReader(
            availableBytes: reserve + incoming - 1,
            totalBytes: total
        )
        let fault = DerivedImageTestSupport.LoggingStoreFaultInjector(faultPoint: .evictObjectDelete)
        let (service, bookmarkPort) = env.makeService(
            faultInjector: fault,
            volumeReader: reader
        )
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected insufficient space")
        } catch DerivedImageError.derivedInsufficientSpace {
        }
        XCTAssertEqual(reader.volumeQueryCount, 1)
        XCTAssertEqual(fault.callCount(for: .evictObjectDelete), 1)
        let victimEntryExists = try await env.cacheEntryExists(id: victim)
        XCTAssertFalse(victimEntryExists, "entry row must still be removed even when object delete fails")
        XCTAssertTrue(env.finalObjectExists(entryID: victim, format: .jpeg), "failed delete must leave orphan inside cache root")
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 0)
        XCTAssertEqual(counts.stagingFiles, 0)
        XCTAssertEqual(counts.objects, 1, "evicted object must remain as orphan until maintenance")
        let maintenance = try await service.performMaintenance()
        DerivedImageTestSupport.assertMaintenanceResultStructure(maintenance)
        XCTAssertEqual(maintenance.removedObjects, 1)
        let second = try await service.performMaintenance()
        DerivedImageTestSupport.assertMaintenanceSecondRunAllZero(second)
        let catalogAfter = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        DerivedImageTestSupport.assertFaultMatrixCatalogSnapshotUnchanged(
            before: catalogBefore,
            after: catalogAfter
        )
        XCTAssertEqual(try env.sourceTreeSnapshot(), sourceBefore)
        let sentinelAfter = try env.sourceFileSnapshot(for: sentinelURL)
        XCTAssertEqual(sentinelAfter.bytes, sentinelBefore.bytes)
        XCTAssertEqual(sentinelAfter.modifiedAtNs, sentinelBefore.modifiedAtNs)
        DerivedImageTestSupport.assertBookmarkPortScopeBalanced(bookmarkPort)
        _ = fileURL
    }

    func testEvictionDoesNotUnlinkObjectSymlink() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "evict-object-symlink")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let sentinelURL = try env.plantExternalSentinel()
        let sentinelBefore = try env.sourceFileSnapshot(for: sentinelURL)
        let victim = try await seedVictimWithInflatedQuotaEntry(env: env, logicalBytes: 10 * gib)
        try env.replacePublishedObjectWithSymlink(
            entryID: victim,
            format: .jpeg,
            linkTarget: sentinelURL
        )
        let objectRelative = env.objectRelativeComponent(entryID: victim, format: .jpeg)
        let incoming = UInt64(try DerivedImageTestSupport.renderIncomingGridSmallArtifact().byteSize)
        let total = 100 * gib
        let reserve = try XCTUnwrap(DerivedImageQuotaPolicy.reserveBytes(totalVolumeBytes: total))
        let (service, _) = env.makeService(
            volumeReader: DerivedImageTestSupport.ConstantVolumeReader(
                availableBytes: reserve + incoming - 1,
                totalBytes: total
            )
        )

        do {
            _ = try await service.loadOrGenerate(
                DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
            )
            XCTFail("expected insufficient space")
        } catch DerivedImageError.derivedInsufficientSpace {
        }

        let victimEntryExists = try await env.cacheEntryExists(id: victim)
        XCTAssertFalse(victimEntryExists)
        XCTAssertEqual(try env.noFollowCacheFixtureKind(relativeComponent: objectRelative), .symlink)
        let sentinelAfter = try env.sourceFileSnapshot(for: sentinelURL)
        DerivedImageTestSupport.assertExternalSentinelUnchanged(
            before: sentinelBefore,
            after: sentinelAfter
        )
    }

    // MARK: - 7. Maintenance convergence matrix

    func testMaintenanceRemovesAssetCascadeOrphanAndSecondRunIsIdempotent() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "maint-cascade")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        let payload = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
        )
        let objectBytes = Int64(payload.encodedBytes.count)
        try await env.deleteAssetCascadingCacheEntry()
        let first = try await service.performMaintenance()
        DerivedImageTestSupport.assertMaintenanceResultStructure(first)
        XCTAssertEqual(first.removedEntries, 0)
        XCTAssertEqual(first.removedObjects, 1)
        XCTAssertEqual(first.removedBytes, UInt64(objectBytes))
        XCTAssertEqual(first.unsafeObjects, 0)
        let second = try await service.performMaintenance()
        DerivedImageTestSupport.assertMaintenanceSecondRunAllZero(second)
    }

    func testMaintenanceRemovesMissingObjectEntryAndObjectSamePass() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "maint-missing")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        let payload = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
        )
        try env.removeCacheObject(entryID: payload.entryID, format: payload.storageFormat)
        let first = try await service.performMaintenance()
        DerivedImageTestSupport.assertMaintenanceResultStructure(first)
        XCTAssertEqual(first.removedEntries, 1)
        XCTAssertEqual(first.removedObjects, 0)
        XCTAssertEqual(first.removedBytes, 0)
        XCTAssertEqual(first.unsafeObjects, 0)
        let second = try await service.performMaintenance()
        DerivedImageTestSupport.assertMaintenanceSecondRunAllZero(second)
    }

    func testMaintenanceRemovesCorruptRegularObjectEntryAndObjectSamePass() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "maint-corrupt")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        let payload = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
        )
        let objectBytes = Int64(payload.encodedBytes.count)
        try env.tamperCacheObjectSameByteSize(entryID: payload.entryID, format: payload.storageFormat)
        let first = try await service.performMaintenance()
        DerivedImageTestSupport.assertMaintenanceResultStructure(first)
        XCTAssertEqual(first.removedEntries, 1)
        XCTAssertEqual(first.removedObjects, 1)
        XCTAssertEqual(first.removedBytes, UInt64(objectBytes))
        XCTAssertEqual(first.unsafeObjects, 0)
        let second = try await service.performMaintenance()
        DerivedImageTestSupport.assertMaintenanceSecondRunAllZero(second)
    }

    func testMaintenanceRemovesUnreferencedFinalObjectAndSecondRunIsIdempotent() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "maint-unreferenced")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let orphanID = UUID()
        let orphanBytes = FolderReconcileTestSupport.minimalJPEGData()
        try env.plantUnreferencedFinalObject(entryID: orphanID, bytes: orphanBytes)
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        let first = try await service.performMaintenance()
        DerivedImageTestSupport.assertMaintenanceResultStructure(first)
        XCTAssertEqual(first.removedEntries, 0)
        XCTAssertEqual(first.removedObjects, 1)
        XCTAssertEqual(first.removedBytes, UInt64(orphanBytes.count))
        XCTAssertEqual(first.unsafeObjects, 0)
        let second = try await service.performMaintenance()
        DerivedImageTestSupport.assertMaintenanceSecondRunAllZero(second)
    }

    func testMaintenanceRemovesLegacyStagingOrphanAndSecondRunIsIdempotent() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "maint-staging")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let orphanBytes = FolderReconcileTestSupport.minimalJPEGData()
        _ = try env.plantLegalStagingOrphan(bytes: orphanBytes)
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        let first = try await service.performMaintenance()
        DerivedImageTestSupport.assertMaintenanceResultStructure(first)
        XCTAssertEqual(first.removedEntries, 0)
        XCTAssertEqual(first.removedObjects, 1)
        XCTAssertEqual(first.removedBytes, UInt64(orphanBytes.count))
        XCTAssertEqual(first.unsafeObjects, 0)
        let second = try await service.performMaintenance()
        DerivedImageTestSupport.assertMaintenanceSecondRunAllZero(second)
    }

    // MARK: - 8. Unknown and no-follow maintenance

    func testMaintenanceCountsIllegalObjectNameAsUnsafeWithoutDeletingSentinel() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "maint-illegal-name")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let sentinelURL = try env.plantExternalSentinel()
        let sentinelBefore = try env.sourceFileSnapshot(for: sentinelURL)
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        try env.plantIllegalObjectNameInObjectsTree()
        let maintenance = try await service.performMaintenance()
        DerivedImageTestSupport.assertMaintenanceResultStructure(maintenance)
        XCTAssertGreaterThanOrEqual(maintenance.unsafeObjects, 1)
        XCTAssertEqual(
            try env.noFollowCacheFixtureKind(relativeComponent: "objects/aa/not-a-valid-entry-id.jpg"),
            .regularFile
        )
        let sentinelAfter = try env.sourceFileSnapshot(for: sentinelURL)
        DerivedImageTestSupport.assertExternalSentinelUnchanged(before: sentinelBefore, after: sentinelAfter)
    }

    func testMaintenanceCountsUnknownDirectoryLevelAsUnsafeWithoutDeletingSentinel() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "maint-unknown-dir")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let sentinelURL = try env.plantExternalSentinel()
        let sentinelBefore = try env.sourceFileSnapshot(for: sentinelURL)
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        try env.plantUnknownObjectsDirectoryLevel()
        let maintenance = try await service.performMaintenance()
        DerivedImageTestSupport.assertMaintenanceResultStructure(maintenance)
        XCTAssertGreaterThanOrEqual(maintenance.unsafeObjects, 1)
        XCTAssertEqual(
            try env.noFollowCacheFixtureKind(relativeComponent: "objects/unknown-level"),
            .directory
        )
        let sentinelAfter = try env.sourceFileSnapshot(for: sentinelURL)
        DerivedImageTestSupport.assertExternalSentinelUnchanged(before: sentinelBefore, after: sentinelAfter)
    }

    func testMaintenanceDoesNotFollowUnreferencedObjectSymlinkOrDeleteSentinel() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "maint-object-symlink")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let sentinelURL = try env.plantExternalSentinel()
        let sentinelBefore = try env.sourceFileSnapshot(for: sentinelURL)
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        let payload = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
        )
        let linkEntryID = UUID()
        try env.plantObjectSymlinkInObjectsTree(linkTarget: sentinelURL, entryID: linkEntryID)
        let linkRelative = env.objectRelativeComponent(entryID: linkEntryID, format: .jpeg)
        let maintenance = try await service.performMaintenance()
        DerivedImageTestSupport.assertMaintenanceResultStructure(maintenance)
        XCTAssertGreaterThanOrEqual(maintenance.unsafeObjects, 1)
        XCTAssertEqual(try env.noFollowCacheFixtureKind(relativeComponent: linkRelative), .symlink)
        XCTAssertTrue(env.finalObjectExists(entryID: payload.entryID, format: payload.storageFormat))
        let sentinelAfter = try env.sourceFileSnapshot(for: sentinelURL)
        DerivedImageTestSupport.assertExternalSentinelUnchanged(before: sentinelBefore, after: sentinelAfter)
    }

    func testPublishedObjectSymlinkRejectedFromPublicLoadAndMaintenancePreservesEntryAndSentinel() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "published-object-symlink")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let sentinelURL = try env.plantExternalSentinel()
        let sentinelBefore = try env.sourceFileSnapshot(for: sentinelURL)
        let catalogBefore = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        let payload = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
        )
        let entriesBefore = try await env.cacheEntrySnapshots()
        let objectRelative = env.objectRelativeComponent(entryID: payload.entryID, format: payload.storageFormat)
        try env.replacePublishedObjectWithSymlink(
            entryID: payload.entryID,
            format: payload.storageFormat,
            linkTarget: sentinelURL
        )
        do {
            _ = try await service.loadOrGenerate(
                DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
            )
            XCTFail("expected unsafe path when published object is a symlink")
        } catch DerivedImageError.derivedCacheUnsafePath {
        }
        do {
            _ = try await service.performMaintenance()
            XCTFail("expected unsafe path from maintenance when published object is a symlink")
        } catch DerivedImageError.derivedCacheUnsafePath {
        }
        let entriesAfter = try await env.cacheEntrySnapshots()
        DerivedImageTestSupport.assertCacheEntrySnapshotsEqual(entriesBefore, entriesAfter)
        let catalogAfter = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        DerivedImageTestSupport.assertFaultMatrixCatalogSnapshotUnchanged(
            before: catalogBefore,
            after: catalogAfter
        )
        XCTAssertEqual(try env.noFollowCacheFixtureKind(relativeComponent: objectRelative), .symlink)
        let sentinelAfter = try env.sourceFileSnapshot(for: sentinelURL)
        DerivedImageTestSupport.assertExternalSentinelUnchanged(before: sentinelBefore, after: sentinelAfter)
    }

    func testMaintenanceDoesNotFollowShardSymlinkOrDeleteSentinel() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "maint-shard-symlink")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let sentinelURL = try env.plantExternalSentinel()
        let sentinelBefore = try env.sourceFileSnapshot(for: sentinelURL)
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        _ = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
        )
        try env.plantShardSymlinkInObjectsTree(linkTarget: sentinelURL, shardName: "zz")
        let maintenance = try await service.performMaintenance()
        DerivedImageTestSupport.assertMaintenanceResultStructure(maintenance)
        XCTAssertGreaterThanOrEqual(maintenance.unsafeObjects, 1)
        XCTAssertEqual(try env.noFollowCacheFixtureKind(relativeComponent: "objects/zz"), .symlink)
        let sentinelAfter = try env.sourceFileSnapshot(for: sentinelURL)
        DerivedImageTestSupport.assertExternalSentinelUnchanged(before: sentinelBefore, after: sentinelAfter)
    }

    // MARK: - 9. Directory component replacement

    func testDerivedImagesRootSymlinkRejectedFromPublicLoad() async throws {
        try await assertCacheLayoutSymlinkRejected(
            label: "derived-root-symlink",
            component: .derivedImagesRoot
        )
    }

    func testVersionRootSymlinkRejectedFromPublicLoad() async throws {
        try await assertCacheLayoutSymlinkRejected(
            label: "version-root-symlink",
            component: .versionRoot
        )
    }

    func testStagingDirectorySymlinkRejectedFromPublicLoad() async throws {
        try await assertCacheLayoutSymlinkRejected(
            label: "staging-symlink",
            component: .stagingDirectory
        )
    }

    func testObjectsDirectorySymlinkRejectedFromPublicLoad() async throws {
        try await assertCacheLayoutSymlinkRejected(
            label: "objects-symlink",
            component: .objectsDirectory
        )
    }

    func testShardDirectorySymlinkRejectedFromPublicLoadAndMaintenance() async throws {
        try await assertCacheLayoutSymlinkRejected(
            label: "shard-symlink",
            component: .shard(entryID: UUID()),
            bootstrapEntryID: { env, service in
                let payload = try await service.loadOrGenerate(
                    DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
                )
                return payload.entryID
            }
        )
    }

    // MARK: - 10. Ancestor alias and sourceRoot injection

    func testAncestorAliasCachesDirectoryRejectedAndExternalTreeUntouched() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "ancestor-alias")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let aliasCaches = try env.makeAliasCachesDirectory()
        let sentinelURL = try env.plantExternalSentinel()
        let sentinelBefore = try env.sourceFileSnapshot(for: sentinelURL)
        let sourceBefore = try env.sourceTreeSnapshot()
        let (service, _) = env.makeService(
            cachesDirectory: aliasCaches,
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected unsafe path")
        } catch DerivedImageError.derivedCacheUnsafePath {
        }
        do {
            _ = try await service.performMaintenance()
            XCTFail("expected unsafe path")
        } catch DerivedImageError.derivedCacheUnsafePath {
        }
        XCTAssertFalse(env.derivedImagesExistsUnderExternalTree())
        let sentinelAfter = try env.sourceFileSnapshot(for: sentinelURL)
        XCTAssertEqual(sentinelAfter.bytes, sentinelBefore.bytes)
        XCTAssertEqual(try env.sourceTreeSnapshot(), sourceBefore)
    }

    func testSourceRootMisInjectedAsCachesDirectoryRejectedAndSourceTreeUntouched() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "source-root-injection")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let sourceBefore = try env.sourceTreeSnapshot()
        let (service, _) = env.makeService(
            cachesDirectory: env.sourceRoot,
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected unsafe path")
        } catch DerivedImageError.derivedCacheUnsafePath {
        }
        do {
            _ = try await service.performMaintenance()
            XCTFail("expected unsafe path")
        } catch DerivedImageError.derivedCacheUnsafePath {
        }
        XCTAssertEqual(try env.sourceTreeSnapshot(), sourceBefore)
        let derivedUnderSource = env.sourceRoot
            .appendingPathComponent("DerivedImages", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: derivedUnderSource.path))
    }
}

// MARK: - Shared helpers

private extension DerivedImageQuotaTests {
    func seedVictimWithInflatedQuotaEntry(
        env: DerivedImageTestSupport.TempEnvironment,
        logicalBytes: UInt64
    ) async throws -> UUID {
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        let victim = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridRegular)
        )
        try await env.database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE derived_image_cache_entry
                SET byte_size = ?
                WHERE id = ?
                """,
                arguments: [Int64(logicalBytes), victim.entryID.uuidString.lowercased()]
            )
        }
        return victim.entryID
    }

    func assertCacheLayoutSymlinkRejected(
        label: String,
        component: DerivedImageTestSupport.TempEnvironment.CacheLayoutComponent,
        bootstrapEntryID: (
            (DerivedImageTestSupport.TempEnvironment, DerivedImageCacheService) async throws -> UUID
        )? = nil
    ) async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: label)
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let external = env.externalSentinelDirectory()
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        var resolvedComponent = component
        var preservedEntryID: UUID?
        if case .derivedImagesRoot = component {
            // layout not bootstrapped yet
        } else {
            let bootstrap = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
            if let bootstrapEntryID {
                let entryID = try await bootstrapEntryID(env, bootstrap.0)
                preservedEntryID = entryID
                if case .shard = component {
                    resolvedComponent = .shard(entryID: entryID)
                }
            } else {
                _ = try await bootstrap.0.loadOrGenerate(
                    DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
                )
            }
        }
        try env.replaceCacheLayoutComponentWithSymlink(resolvedComponent, linkTarget: external)
        let sentinelURL = try env.plantExternalSentinel()
        let sentinelBefore = try env.sourceFileSnapshot(for: sentinelURL)
        let entriesBefore = try await env.cacheEntrySnapshots()
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected unsafe path from public load")
        } catch DerivedImageError.derivedCacheUnsafePath {
        }
        do {
            _ = try await service.performMaintenance()
            XCTFail("expected unsafe path from maintenance")
        } catch DerivedImageError.derivedCacheUnsafePath {
        }
        try env.assertLayoutComponentStillSymlink(resolvedComponent)
        if let preservedEntryID {
            let entryStillExists = try await env.cacheEntryExists(id: preservedEntryID)
            XCTAssertTrue(entryStillExists)
            let entriesAfter = try await env.cacheEntrySnapshots()
            DerivedImageTestSupport.assertCacheEntrySnapshotsEqual(entriesBefore, entriesAfter)
        }
        let sentinelAfter = try env.sourceFileSnapshot(for: sentinelURL)
        DerivedImageTestSupport.assertExternalSentinelUnchanged(before: sentinelBefore, after: sentinelAfter)
    }
}
