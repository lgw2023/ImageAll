import Darwin
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
        let fileURL = try env.seedAvailableAsset()
        let factsBefore = try await env.generationCatalogFacts()
        let sourceBefore = try env.sourceFileSnapshot(for: fileURL)
        let jobBefore = try await env.jobRecordCount()
        let tagBefore = try await env.tagRecordCount()
        let pinnedReader = try await env.pinnedSeedFingerprintReader(for: fileURL)
        let (service, bookmarkPort) = env.makeService(
            sourceReader: DerivedImageSourceReader(fileResourceReader: pinnedReader),
            volumeReader: DerivedImageTestSupport.GenerousVolumeReader(
                availableBytes: 50 * 1024 * 1024 * 1024,
                totalBytes: 100 * 1024 * 1024 * 1024
            )
        )
        let first = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        XCTAssertEqual(first.origin, .generated)
        try await env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE derived_image_cache_entry SET byte_size = byte_size + 10 WHERE id = ?",
                arguments: [first.entryID.uuidString.lowercased()]
            )
        }
        let second = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
        XCTAssertEqual(second.origin, .generated)
        XCTAssertNotEqual(second.entryID, first.entryID)
        try await DerivedImageTestSupport.assertSingleFinalCacheConvergence(
            env: env,
            expectedEntryID: second.entryID,
            expectedFormat: second.storageFormat,
            replacedEntryID: first.entryID
        )
        try await DerivedImageTestSupport.assertCatalogSourceScopeAndAuxiliaryUntouched(
            env: env,
            fileURL: fileURL,
            factsBefore: factsBefore,
            sourceBefore: sourceBefore,
            bookmarkPort: bookmarkPort,
            jobBefore: jobBefore,
            tagBefore: tagBefore
        )
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

    func testSameOpenFDResourceIDChangeUsesInjectedReaderBoundaryReturnsSourceChanged() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "fd-resource-id")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let factsBefore = try await env.generationCatalogFacts()
        let sourceBefore = try Data(contentsOf: fileURL)
        let persistedID = try await env.database.pool.read { db -> Data? in
            try Data.fetchOne(
                db,
                sql: "SELECT resource_id FROM file_fingerprint WHERE asset_id = ?",
                arguments: [env.assetID.uuidString.lowercased()]
            )
        }
        let scriptedFlip = Data([0x01, 0x02, 0x03, 0x04])
        XCTAssertNotEqual(persistedID, scriptedFlip)

        let reader = DerivedImageTestSupport.FlipSecondResourceIDReader(
            persistedResourceID: persistedID,
            scriptedSecondResourceID: scriptedFlip
        )
        let (service, bookmarkPort) = env.makeService(
            sourceReader: DerivedImageSourceReader(fileResourceReader: reader),
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected source changed")
        } catch DerivedImageError.derivedSourceChanged {
        } catch let error as DerivedImageError {
            XCTFail("expected derivedSourceChanged, got \(error)")
        }

        XCTAssertEqual(reader.resourceIdentifierCallCount, 2)

        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 0)
        XCTAssertEqual(counts.objects, 0)
        XCTAssertEqual(counts.stagingFiles, 0)
        XCTAssertEqual(try Data(contentsOf: fileURL), sourceBefore)
        let factsAfter = try await env.generationCatalogFacts()
        XCTAssertEqual(factsAfter, factsBefore)
    }

    func testSameOpenFDSizeChangeUsesInjectedReaderBoundaryReturnsSourceChanged() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "fd-size")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let factsBefore = try await env.generationCatalogFacts()
        let sourceBefore = try Data(contentsOf: fileURL)
        let appendBytes = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let expectedAfter = sourceBefore + appendBytes

        let reader = DerivedImageTestSupport.GrowSourceOnFirstResourceIDReader(
            sourceLocatorURL: fileURL,
            appendBytes: appendBytes
        )
        let (service, bookmarkPort) = env.makeService(
            sourceReader: DerivedImageSourceReader(fileResourceReader: reader),
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected source changed")
        } catch DerivedImageError.derivedSourceChanged {
        } catch let error as DerivedImageError {
            XCTFail("expected derivedSourceChanged, got \(error)")
        }

        XCTAssertEqual(reader.resourceIdentifierCallCount, 2)

        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 0)
        XCTAssertEqual(counts.objects, 0)
        XCTAssertEqual(counts.stagingFiles, 0)
        XCTAssertEqual(try Data(contentsOf: fileURL), expectedAfter)
        let factsAfter = try await env.generationCatalogFacts()
        XCTAssertEqual(factsAfter, factsBefore)
    }

    func testSameOpenFDMtimeChangeUsesInjectedReaderBoundaryReturnsSourceChanged() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "fd-mtime")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let factsBefore = try await env.generationCatalogFacts()
        let sourceBefore = try Data(contentsOf: fileURL)
        let (_, persistedMtime, _) = env.productionFingerprint(for: fileURL)
        let targetModifiedAtNs = persistedMtime + 1_234_567_890
        XCTAssertNotEqual(targetModifiedAtNs, persistedMtime)

        let reader = DerivedImageTestSupport.SetMtimeOnFirstResourceIDReader(
            sourceLocatorURL: fileURL,
            targetModifiedAtNs: targetModifiedAtNs
        )
        let (service, bookmarkPort) = env.makeService(
            sourceReader: DerivedImageSourceReader(fileResourceReader: reader),
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected source changed")
        } catch DerivedImageError.derivedSourceChanged {
        } catch let error as DerivedImageError {
            XCTFail("expected derivedSourceChanged, got \(error)")
        }

        XCTAssertEqual(reader.resourceIdentifierCallCount, 2)

        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 0)
        XCTAssertEqual(counts.objects, 0)
        XCTAssertEqual(counts.stagingFiles, 0)
        XCTAssertEqual(try Data(contentsOf: fileURL), sourceBefore)
        let expectedMtime = try XCTUnwrap(reader.postMutateModifiedAtNs)
        let probeFD = open(fileURL.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(probeFD, 0)
        defer { Darwin.close(probeFD) }
        let (_, actualMtime) = try DerivedImageSecureIO.fstatRegularFile(fd: probeFD)
        XCTAssertEqual(actualMtime, expectedMtime)
        let factsAfter = try await env.generationCatalogFacts()
        XCTAssertEqual(factsAfter, factsBefore)
    }

    func testLocatorAtomicReplacementAfterSameFDReadUsesInjectedReaderBoundaryReturnsSourceChanged() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "locator-replace")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let alternateBytes = try XCTUnwrap(
            FolderReconcileTestSupport.minimalEncodedImageData(uti: "public.jpeg", width: 8, height: 8)
        )
        let sourceBytes = try Data(contentsOf: fileURL)
        XCTAssertNotEqual(alternateBytes, sourceBytes)
        let alternateURL = try env.writeSource(relativePath: "photos/alternate.jpg", contents: alternateBytes)
        let (_, _, alternateResourceID) = env.productionFingerprint(for: alternateURL)
        let (_, _, sourceResourceID) = env.productionFingerprint(for: fileURL)
        XCTAssertTrue(
            alternateBytes.count != sourceBytes.count
                || alternateResourceID != sourceResourceID
        )

        let factsBefore = try await env.generationCatalogFacts()
        let reader = DerivedImageTestSupport.ReplaceLocatorOnSecondResourceIDReader(
            sourceLocatorURL: fileURL,
            replacementBytes: alternateBytes
        )
        let (service, bookmarkPort) = env.makeService(
            sourceReader: DerivedImageSourceReader(fileResourceReader: reader),
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected source changed")
        } catch DerivedImageError.derivedSourceChanged {
        } catch let error as DerivedImageError {
            XCTFail("expected derivedSourceChanged, got \(error)")
        }

        XCTAssertEqual(reader.resourceIdentifierCallCount, 3)

        XCTAssertEqual(bookmarkPort.scopeStartCount, bookmarkPort.scopeStopCount)
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 0)
        XCTAssertEqual(counts.objects, 0)
        XCTAssertEqual(counts.stagingFiles, 0)
        XCTAssertEqual(try Data(contentsOf: fileURL), alternateBytes)
        let expectedMtime = try XCTUnwrap(reader.postReplaceModifiedAtNs)
        let (_, replacedMtime, replacedResourceID) = env.productionFingerprint(for: fileURL)
        XCTAssertEqual(replacedMtime, expectedMtime)
        XCTAssertNotEqual(replacedResourceID, sourceResourceID)
        let factsAfter = try await env.generationCatalogFacts()
        XCTAssertEqual(factsAfter, factsBefore)
    }
}
