import Darwin
import Foundation
import GRDB
import XCTest
@testable import ImageAll

final class DerivedImageHardeningTests: XCTestCase {
    // MARK: - Cluster A: production reconcile + scope on success

    func testProductionReconcileFingerprintCompatibleWithGeneration() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "reconcile-fp")
        defer { env.cleanup() }
        _ = try await env.seedViaProductionReconcile(relativePath: "photos/reconcile.jpg")
        let (service, bookmarkPort) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        let payload = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
        )
        XCTAssertEqual(payload.origin, .generated)
        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
    }

    func testScopeBalancedAfterCacheHit() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "scope-hit")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, bookmarkPort) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridRegular))
        let scopeAfterGenerate = bookmarkPort.scopeStartCount
        _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridRegular))
        XCTAssertEqual(bookmarkPort.scopeStartCount, scopeAfterGenerate)
        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
    }

    // MARK: - Cluster A: non-active Source hit/miss per state

    func testValidHitWhenSourceDisabledDoesNotOpenScope() async throws {
        try await assertValidHitForNonActiveSource(state: "disabled", label: "disabled-hit")
    }

    func testValidHitWhenSourceUnavailableDoesNotOpenScope() async throws {
        try await assertValidHitForNonActiveSource(state: "unavailable", label: "unavailable-hit")
    }

    func testValidHitWhenSourceAuthorizationRequiredDoesNotOpenScope() async throws {
        try await assertValidHitForNonActiveSource(state: "authorizationRequired", label: "authreq-hit")
    }

    func testMissWhenSourceDisabledDoesNotOpenScope() async throws {
        try await assertMissForNonActiveSource(state: "disabled", label: "disabled-miss")
    }

    func testMissWhenSourceUnavailableDoesNotOpenScope() async throws {
        try await assertMissForNonActiveSource(state: "unavailable", label: "unavailable-miss")
    }

    func testMissWhenSourceAuthorizationRequiredDoesNotOpenScope() async throws {
        try await assertMissForNonActiveSource(state: "authorizationRequired", label: "authreq-miss")
    }

    // MARK: - Cluster A: catalog availability rejection without artifacts

    func testCatalogAvailabilityMissingLeavesNoArtifacts() async throws {
        try await assertCatalogAvailabilityRejectsWithoutArtifacts(availability: "missing", label: "avail-missing")
    }

    func testCatalogAvailabilityUnreadableLeavesNoArtifacts() async throws {
        try await assertCatalogAvailabilityRejectsWithoutArtifacts(availability: "unreadable", label: "avail-unreadable")
    }

    func testCatalogAvailabilityUnsupportedLeavesNoArtifacts() async throws {
        try await assertCatalogAvailabilityRejectsWithoutArtifacts(availability: "unsupported", label: "avail-unsupported")
    }

    func testSourceLocatorSymlinkReplacementReturnsSourceChanged() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "source-symlink")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()

        let externalRoot = env.root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        let sentinelURL = externalRoot.appendingPathComponent("sentinel.jpg")
        let sentinelBytes = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
        try sentinelBytes.write(to: sentinelURL)
        let sentinelMtime = try sentinelURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: sentinelURL)
        let symlinkType = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.type] as? FileAttributeType
        XCTAssertEqual(symlinkType, .typeSymbolicLink)
        let factsBefore = try await env.generationCatalogFacts()

        let (service, bookmarkPort) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected source changed")
        } catch DerivedImageError.derivedSourceChanged {
        } catch let error as DerivedImageError {
            XCTFail("expected derivedSourceChanged, got \(error)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount, "scope must balance")
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 0, "entries")
        XCTAssertEqual(counts.objects, 0, "objects")
        XCTAssertEqual(counts.stagingFiles, 0, "staging")

        let factsAfter = try await env.generationCatalogFacts()
        XCTAssertEqual(factsAfter, factsBefore)
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinelBytes)
        if let sentinelMtime {
            let afterMtime = try sentinelURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            XCTAssertEqual(afterMtime, sentinelMtime)
        }
        let linkTypeAfter = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.type] as? FileAttributeType
        XCTAssertEqual(linkTypeAfter, .typeSymbolicLink)
    }

    func testMissingSourceFileLeavesNoArtifacts() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "missing-file")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let factsBefore = try await env.generationCatalogFacts()
        let sourceBefore = try Data(contentsOf: fileURL)
        try FileManager.default.removeItem(at: fileURL)
        let (service, bookmarkPort) = env.makeService()
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected failure")
        } catch DerivedImageError.derivedSourceUnavailable {
        }
        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 0)
        XCTAssertEqual(counts.objects, 0)
        XCTAssertEqual(counts.stagingFiles, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        try await assertCatalogFactsAndSourceUnchanged(
            env: env,
            fileURL: fileURL,
            factsBefore: factsBefore,
            sourceBefore: sourceBefore
        )
    }

    func testCorruptSourceBytesDecodeFailureLeavesNoArtifacts() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "decode-fail")
        defer { env.cleanup() }
        let corrupt = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        let fileURL = try env.seedAvailableAsset(contents: corrupt)
        let factsBefore = try await env.generationCatalogFacts()
        let (service, bookmarkPort) = env.makeService()
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected decode failure")
        } catch DerivedImageError.derivedDecodeFailed {
        }
        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 0)
        XCTAssertEqual(counts.objects, 0)
        XCTAssertEqual(counts.stagingFiles, 0)
        try await assertCatalogFactsAndSourceUnchanged(
            env: env,
            fileURL: fileURL,
            factsBefore: factsBefore,
            sourceBefore: corrupt
        )
    }

    func testUnknownMediaTypeLeavesNoArtifacts() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "unsupported-uti")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset(mediaType: "public.bmp")
        let factsBefore = try await env.generationCatalogFacts()
        let sourceBefore = try Data(contentsOf: fileURL)
        let (service, bookmarkPort) = env.makeService()
        try await assertRejectsWithoutArtifacts(
            env: env,
            service: service,
            bookmarkPort: bookmarkPort,
            expected: .derivedAssetIneligible
        )
        try await assertCatalogFactsAndSourceUnchanged(
            env: env,
            fileURL: fileURL,
            factsBefore: factsBefore,
            sourceBefore: sourceBefore
        )
    }

    func testHistoricalLocatorLeavesNoArtifacts() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "historical")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        try await env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET locator_state = 'historical' WHERE id = ?",
                arguments: [env.assetID.uuidString.lowercased()]
            )
        }
        let factsBefore = try await env.generationCatalogFacts()
        let sourceBefore = try Data(contentsOf: fileURL)
        let (service, bookmarkPort) = env.makeService()
        try await assertRejectsWithoutArtifacts(
            env: env,
            service: service,
            bookmarkPort: bookmarkPort,
            expected: .derivedAssetIneligible
        )
        try await assertCatalogFactsAndSourceUnchanged(
            env: env,
            fileURL: fileURL,
            factsBefore: factsBefore,
            sourceBefore: sourceBefore
        )
    }

    func testPhotosLocatorLeavesNoArtifacts() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "photos-locator")
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
                    record_created_at_ms, record_updated_at_ms, file_name
                ) VALUES (?, ?, 'photos', NULL, 'abc', 'current', 'public.heic', 1, 'available', ?, ?, 'photo.heic')
                """,
                arguments: [env.assetID.uuidString.lowercased(), env.sourceID.uuidString.lowercased(), FolderReconcileTestSupport.baseTimeMs, FolderReconcileTestSupport.baseTimeMs]
            )
        }
        let factsBefore = try await env.stableAssetFacts()
        let (service, bookmarkPort) = env.makeService()
        try await assertRejectsWithoutArtifacts(
            env: env,
            service: service,
            bookmarkPort: bookmarkPort,
            expected: .derivedAssetIneligible
        )
        let factsAfter = try await env.stableAssetFacts()
        XCTAssertEqual(factsAfter.revision, factsBefore.revision)
    }

    func testMissingFingerprintLeavesNoArtifacts() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "no-fp")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let factsBefore = try await env.stableAssetFacts()
        let sourceBefore = try Data(contentsOf: fileURL)
        try await env.database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM file_fingerprint WHERE asset_id = ?",
                arguments: [env.assetID.uuidString.lowercased()]
            )
        }
        let (service, bookmarkPort) = env.makeService()
        try await assertRejectsWithoutArtifacts(
            env: env,
            service: service,
            bookmarkPort: bookmarkPort,
            expected: .derivedAssetIneligible
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), sourceBefore)
        let factsAfter = try await env.stableAssetFacts()
        XCTAssertEqual(factsAfter.revision, factsBefore.revision)
        XCTAssertNil(factsAfter.sizeBytes)
    }

    // MARK: - Cluster A: scope pairing on failure branches

    func testScopeBalancedAfterSourceChanged() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "scope-source-changed")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        try await env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE file_fingerprint SET size_bytes = size_bytes + 1 WHERE asset_id = ?",
                arguments: [env.assetID.uuidString.lowercased()]
            )
        }
        let (service, bookmarkPort) = env.makeService()
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected source changed")
        } catch DerivedImageError.derivedSourceChanged {
        }
        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 0)
        XCTAssertEqual(counts.objects, 0)
    }

    func testScopeBalancedAfterCapacityUnavailable() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "scope-capacity")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, bookmarkPort) = env.makeService(volumeReader: DerivedImageTestSupport.FailingVolumeReader())
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected capacity unavailable")
        } catch DerivedImageError.derivedCapacityUnavailable {
        }
        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 0)
        XCTAssertEqual(counts.objects, 0)
    }

    func testScopeBalancedAfterPublishFailure() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "scope-publish-fail")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, bookmarkPort) = env.makeService(
            faultInjector: DerivedImageTestSupport.SinglePointFaultInjector(point: .afterRenameBeforeDB),
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected persistence failure")
        } catch DerivedImageError.derivedCachePersistenceFailed {
        }
        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 0)
        XCTAssertEqual(counts.objects, 1)
    }

    func testScopeBalancedAfterRepositoryInsertFailure() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "scope-repo-fail")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, bookmarkPort) = env.makeService(
            repositoryFaultInjector: DerivedImageTestSupport.SinglePointRepositoryFaultInjector(point: .insert),
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected persistence failure")
        } catch DerivedImageError.derivedCachePersistenceFailed {
        }
        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 0)
        XCTAssertEqual(counts.objects, 1)
    }

    func testClosedDatabaseFailureDoesNotEscapePublicErrorDomain() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "closed-database-error-domain")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        try CatalogDatabase.closePool(env.database.pool)

        do {
            _ = try await service.loadOrGenerate(
                DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
            )
            XCTFail("expected persistence failure")
        } catch let error as DerivedImageError {
            XCTAssertEqual(error, .derivedCachePersistenceFailed)
        } catch {
            XCTFail("public port leaked a non-DerivedImageError: \(type(of: error))")
        }
    }

    func testRepeatedLayoutOpenFailureDoesNotLeakFileDescriptors() throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "layout-open-fd-leak")
        defer { env.cleanup() }

        let versionRoot = env.cacheVersionRoot()
        try FileManager.default.createDirectory(
            at: DerivedImageCachePathLayout.stagingDirectory(under: versionRoot),
            withIntermediateDirectories: true
        )
        try Data([0x01]).write(
            to: DerivedImageCachePathLayout.objectsDirectory(under: versionRoot)
        )

        let store = DerivedImageCacheStore(cachesDirectory: env.cachesDirectory)
        let descriptorsBefore = openFileDescriptorCount()
        for _ in 0..<20 {
            XCTAssertThrowsError(try store.ensureLayout()) { error in
                XCTAssertEqual(error as? DerivedImageError, .derivedCacheUnsafePath)
            }
        }
        XCTAssertEqual(openFileDescriptorCount(), descriptorsBefore)
    }

    // MARK: - Existing hardening retained from prior slices

    func testPublishDoesNotReplaceExistingObject() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "rename-excl")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        let first = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        let objectPath = DerivedImageCachePathLayout.objectURL(
            versionRoot: env.cacheVersionRoot(),
            entryID: first.entryID,
            format: first.storageFormat
        )
        let sentinel = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try sentinel.write(to: objectPath)

        let session = try DerivedImageCacheStore(cachesDirectory: env.cachesDirectory).ensureLayout()
        defer { session.closeHandles() }
        let stagingName = DerivedImageCachePathLayout.stagingFileName()
        let replacement = try DerivedImageRenderer().render(
            sourceBytes: FolderReconcileTestSupport.minimalJPEGData(),
            variant: .gridSmall
        )
        _ = try session.writeStagingExclusive(name: stagingName, bytes: replacement.bytes)
        do {
            try session.publishStagingFile(stagingName: stagingName, entryID: first.entryID, format: first.storageFormat)
            XCTFail("expected publish failure")
        } catch DerivedImageError.derivedCachePersistenceFailed {
        }
        let onDisk = try Data(contentsOf: objectPath)
        XCTAssertEqual(onDisk, sentinel)
        let entryCount = try await env.database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM derived_image_cache_entry") ?? 0
        }
        XCTAssertEqual(entryCount, 1)
    }

    func testInvalidEntryRemovedAndObjectSweptSameMaintenancePass() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "maint-recalc")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        let payload = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        let objectURL = DerivedImageCachePathLayout.objectURL(
            versionRoot: env.cacheVersionRoot(),
            entryID: payload.entryID,
            format: payload.storageFormat
        )
        try Data([0x00]).write(to: objectURL)
        let maintenance = try await service.performMaintenance()
        XCTAssertEqual(maintenance.removedEntries, 1)
        XCTAssertEqual(maintenance.removedObjects, 1)
        let second = try await service.performMaintenance()
        XCTAssertEqual(second.removedEntries, 0)
        XCTAssertEqual(second.removedObjects, 0)
    }

    func testExternalSentinelUntouchedDuringMaintenance() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "sentinel")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))

        let externalRoot = env.root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        let sentinelURL = externalRoot.appendingPathComponent("sentinel.bin")
        let sentinel = Data([0x01, 0x02, 0x03, 0x04])
        try sentinel.write(to: sentinelURL)

        let stagingRoot = DerivedImageCachePathLayout.stagingDirectory(under: env.cacheVersionRoot())
        let rogueLink = stagingRoot.appendingPathComponent("rogue-link")
        try FileManager.default.createSymbolicLink(at: rogueLink, withDestinationURL: sentinelURL)

        let maintenance = try await service.performMaintenance()
        XCTAssertGreaterThanOrEqual(maintenance.unsafeObjects, 1)
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rogueLink.path))
    }

    private func openFileDescriptorCount() -> Int {
        (0..<4_096).reduce(into: 0) { count, descriptor in
            if Darwin.fcntl(Int32(descriptor), F_GETFD) != -1 {
                count += 1
            }
        }
    }
}

extension DerivedImageHardeningTests {
    func testQuotaPolicyReserveBoundaries() {
        let total100GiB: UInt64 = 100 * 1024 * 1024 * 1024
        XCTAssertEqual(DerivedImageQuotaPolicy.reserveBytes(totalVolumeBytes: total100GiB), 5 * 1024 * 1024 * 1024)
        let total20GiB: UInt64 = 20 * 1024 * 1024 * 1024
        XCTAssertEqual(DerivedImageQuotaPolicy.reserveBytes(totalVolumeBytes: total20GiB), 5 * 1024 * 1024 * 1024)
        XCTAssertNil(DerivedImageQuotaPolicy.adding(UInt64.max, 1))
        XCTAssertNil(DerivedImageQuotaPolicy.subtracting(0, 1))
    }

    private func assertValidHitForNonActiveSource(state: String, label: String) async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: label)
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, bookmarkPort) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .preview))
        let scopeAfterGenerate = bookmarkPort.scopeStartCount
        try await env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET state = ? WHERE id = ?",
                arguments: [state, env.sourceID.uuidString.lowercased()]
            )
        }
        let hit = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .preview))
        XCTAssertEqual(hit.origin, .cacheHit)
        XCTAssertEqual(bookmarkPort.scopeStartCount, scopeAfterGenerate)
        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
    }

    private func assertMissForNonActiveSource(state: String, label: String) async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: label)
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        try await env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET state = ? WHERE id = ?",
                arguments: [state, env.sourceID.uuidString.lowercased()]
            )
        }
        let (service, bookmarkPort) = env.makeService()
        try await assertRejectsWithoutArtifacts(
            env: env,
            service: service,
            bookmarkPort: bookmarkPort,
            expected: .derivedAssetIneligible
        )
    }

    private func assertCatalogAvailabilityRejectsWithoutArtifacts(
        availability: String,
        label: String
    ) async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: label)
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        try await env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET availability = ? WHERE id = ?",
                arguments: [availability, env.assetID.uuidString.lowercased()]
            )
        }
        let factsBefore = try await env.generationCatalogFacts()
        let sourceBefore = try Data(contentsOf: fileURL)
        let (service, bookmarkPort) = env.makeService()
        try await assertRejectsWithoutArtifacts(
            env: env,
            service: service,
            bookmarkPort: bookmarkPort,
            expected: .derivedAssetIneligible
        )
        try await assertCatalogFactsAndSourceUnchanged(
            env: env,
            fileURL: fileURL,
            factsBefore: factsBefore,
            sourceBefore: sourceBefore
        )
    }

    private func assertRejectsWithoutArtifacts(
        env: DerivedImageTestSupport.TempEnvironment,
        service: DerivedImageCacheService,
        bookmarkPort: FolderReconcileTestSupport.TestBookmarkPort,
        expected: DerivedImageError
    ) async throws {
        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected \(expected)")
        } catch let error as DerivedImageError {
            XCTAssertEqual(error, expected)
        }
        XCTAssertEqual(bookmarkPort.scopeStartCount, 0)
        XCTAssertEqual(bookmarkPort.scopeStopCount, 0)
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 0)
        XCTAssertEqual(counts.objects, 0)
        XCTAssertEqual(counts.stagingFiles, 0)
    }

    private func assertCatalogFactsAndSourceUnchanged(
        env: DerivedImageTestSupport.TempEnvironment,
        fileURL: URL,
        factsBefore: DerivedImageTestSupport.GenerationCatalogFacts,
        sourceBefore: Data
    ) async throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            XCTAssertEqual(try Data(contentsOf: fileURL), sourceBefore)
        }
        let factsAfter = try await env.generationCatalogFacts()
        XCTAssertEqual(factsAfter, factsBefore)
    }
}
