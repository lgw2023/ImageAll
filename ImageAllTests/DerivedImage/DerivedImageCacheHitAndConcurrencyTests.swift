import Darwin
import XCTest
@testable import ImageAll

final class DerivedImageCacheHitAndConcurrencyTests: XCTestCase {
    private let generateClockMs: Int64 = FolderReconcileTestSupport.baseTimeMs
    private let hitClockMs: Int64 = FolderReconcileTestSupport.baseTimeMs + 60_000

    func testValidExactKeyHitTouchesLastAccessedAndPreservesCatalog() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "valid-hit")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let factsBefore = try await env.generationCatalogFacts()
        let sourceBefore = try env.sourceFileSnapshot(for: fileURL)
        let jobBefore = try await env.jobRecordCount()
        let tagBefore = try await env.tagRecordCount()

        let clock = MutableJobClock(nowMs: generateClockMs)
        let (service, bookmarkPort) = env.makeService(
            volumeReader: DerivedImageTestSupport.generousVolume,
            clock: clock
        )
        let first = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridRegular)
        )
        XCTAssertEqual(first.origin, .generated)
        let scopeAfterGenerate = bookmarkPort.scopeStartCount
        let lastAccessAfterGenerate = try await env.entryLastAccessedMs(id: first.entryID)
        XCTAssertEqual(lastAccessAfterGenerate, generateClockMs)

        clock.setNowMs(hitClockMs)
        let second = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridRegular)
        )

        XCTAssertEqual(second.origin, .cacheHit)
        XCTAssertEqual(second.entryID, first.entryID)
        XCTAssertEqual(second.encodedBytes, first.encodedBytes)
        XCTAssertEqual(second.storageFormat, first.storageFormat)
        XCTAssertEqual(second.pixelWidth, first.pixelWidth)
        XCTAssertEqual(second.pixelHeight, first.pixelHeight)
        let lastAccessAfterHit = try await env.entryLastAccessedMs(id: first.entryID)
        XCTAssertEqual(lastAccessAfterHit, hitClockMs)
        XCTAssertEqual(bookmarkPort.scopeStartCount, scopeAfterGenerate)
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

    func testMissingCacheObjectDeletesEntryAndRebuilds() async throws {
        try await assertInvalidHitRebuilds(
            label: "missing-object",
            corrupt: { env, first in
                try env.removeCacheObject(entryID: first.entryID, format: first.storageFormat)
            }
        )
    }

    func testTruncatedCacheObjectRebuilds() async throws {
        try await assertInvalidHitRebuilds(
            label: "truncated-object",
            corrupt: { env, first in
                try env.truncateCacheObject(
                    entryID: first.entryID,
                    format: first.storageFormat,
                    keepBytes: 32
                )
            }
        )
    }

    func testSameByteSizeTamperedCacheObjectRejectedBySHAAndRebuilds() async throws {
        try await assertInvalidHitRebuilds(
            label: "same-size-tamper",
            corrupt: { env, first in
                try env.tamperCacheObjectSameByteSize(
                    entryID: first.entryID,
                    format: first.storageFormat
                )
            }
        )
    }

    func testStorageFormatSpoofRejectedByUTIAndRebuilds() async throws {
        try await assertInvalidHitRebuilds(
            label: "format-spoof",
            corrupt: { env, first in
                let pngBytes = FolderReconcileTestSupport.minimalPNGData()
                try env.replaceCacheObjectBytes(
                    entryID: first.entryID,
                    format: first.storageFormat,
                    bytes: pngBytes
                )
                try await env.updateCacheEntryByteSizeAndHash(
                    id: first.entryID,
                    byteSize: Int64(pngBytes.count),
                    encodedSHA256: DerivedImageTestSupport.sha256Data(for: pngBytes)
                )
            }
        )
    }

    func testPixelDimensionSpoofRejectedAndRebuilds() async throws {
        try await assertInvalidHitRebuilds(
            label: "dimension-spoof",
            variant: .preview,
            corrupt: { env, first in
                let wrongWidth = first.pixelWidth > 1 ? first.pixelWidth - 1 : first.pixelWidth + 1
                let wrongHeight = first.pixelHeight > 1 ? first.pixelHeight - 1 : first.pixelHeight + 1
                try await env.updateCacheEntryPixelDimensions(
                    id: first.entryID,
                    pixelWidth: wrongWidth,
                    pixelHeight: wrongHeight
                )
            }
        )
    }

    func testContentRevisionIncreaseKeepsOldEntryAndObject() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "revision-isolation")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset(contentRevision: 1)
        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        let revisionOne = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .preview)
        )
        try await env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET content_revision = 2 WHERE id = ?",
                arguments: [env.assetID.uuidString.lowercased()]
            )
        }
        let revisionTwo = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .preview)
        )

        XCTAssertNotEqual(revisionOne.entryID, revisionTwo.entryID)
        XCTAssertEqual(revisionOne.contentRevision, 1)
        XCTAssertEqual(revisionTwo.contentRevision, 2)
        XCTAssertEqual(revisionTwo.origin, .generated)

        let entryIDs = try await env.fetchCacheEntryIDs(assetID: env.assetID)
        XCTAssertEqual(entryIDs.count, 2)
        XCTAssertEqual(try env.listCacheObjectFiles().count, 2)
        XCTAssertTrue(
            env.finalObjectExists(entryID: revisionOne.entryID, format: revisionOne.storageFormat)
        )
        XCTAssertTrue(
            env.finalObjectExists(entryID: revisionTwo.entryID, format: revisionTwo.storageFormat)
        )
        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.stagingFiles, 0)
    }

    func testSameServiceConcurrentSameKeyProducesOneEntry() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "same-service-concurrent")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let checkpoint = DerivedImageTestSupport.FinalPublishCheckpoint()
        let (service, _) = env.makeService(
            finalPublishCheckpoint: checkpoint,
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        let firstTask = Task {
            try await service.loadOrGenerate(
                DerivedImageRequest(assetID: env.assetID, variant: .gridRegular)
            )
        }
        let snapshot = try checkpoint.waitUntilFinalObjectPublished(timeout: 10)
        let secondTask = Task {
            try await service.loadOrGenerate(
                DerivedImageRequest(assetID: env.assetID, variant: .gridRegular)
            )
        }
        checkpoint.releaseFinalPublish()

        let first = try await firstTask.value
        let second = try await secondTask.value
        XCTAssertEqual(first.encodedBytes, second.encodedBytes)
        DerivedImageTestSupport.assertCheckpointReachedWithPublishedObject(env: env, snapshot: snapshot)

        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 1)
        XCTAssertEqual(counts.objects, 1)
        XCTAssertEqual(counts.stagingFiles, 0)
    }

    func testEnsureSubdirectoryClassifiesSymlinkAsUnsafePath() throws {
        let parent = try makeEnsureSubdirectoryFixtureRoot(label: "symlink")
        defer { try? FileManager.default.removeItem(at: parent) }

        let target = parent.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: parent.appendingPathComponent("subdir").path,
            withDestinationPath: target.path
        )

        let parentFD = try openDirectoryFD(at: parent)
        defer { Darwin.close(parentFD) }

        XCTAssertThrowsError(try DerivedImageSecureIO.ensureSubdirectory(parentFD: parentFD, name: "subdir")) { error in
            XCTAssertEqual(error as? DerivedImageSecureIOError, .unsafePath)
        }
    }

    func testEnsureSubdirectoryClassifiesRegularFileAsUnsafePath() throws {
        let parent = try makeEnsureSubdirectoryFixtureRoot(label: "regular-file")
        defer { try? FileManager.default.removeItem(at: parent) }

        let fileURL = parent.appendingPathComponent("subdir")
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: Data([0x41])))

        let parentFD = try openDirectoryFD(at: parent)
        defer { Darwin.close(parentFD) }

        XCTAssertThrowsError(try DerivedImageSecureIO.ensureSubdirectory(parentFD: parentFD, name: "subdir")) { error in
            XCTAssertEqual(error as? DerivedImageSecureIOError, .unsafePath)
        }
    }

    func testEnsureSubdirectoryOpensExistingDirectory() throws {
        let parent = try makeEnsureSubdirectoryFixtureRoot(label: "existing-dir")
        defer { try? FileManager.default.removeItem(at: parent) }

        try FileManager.default.createDirectory(
            at: parent.appendingPathComponent("subdir", isDirectory: true),
            withIntermediateDirectories: true
        )

        let parentFD = try openDirectoryFD(at: parent)
        defer { Darwin.close(parentFD) }

        let subdirFD = try DerivedImageSecureIO.ensureSubdirectory(parentFD: parentFD, name: "subdir")
        defer { Darwin.close(subdirFD) }
        XCTAssertGreaterThanOrEqual(subdirFD, 0)
    }

    func testCrossInstanceConcurrentSameKeyRaceReturnsWinnerBytes() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "cross-instance-race")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.cacheVersionRoot().path))

        let barrier = DerivedImageTestSupport.CrossInstanceRaceBarrier(requiredParticipants: 2)
        let (serviceA, _) = env.makeService(
            publishCheckpoint: barrier,
            finalPublishCheckpoint: barrier,
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        let (serviceB, _) = env.makeService(
            publishCheckpoint: barrier,
            finalPublishCheckpoint: barrier,
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        let taskA = Task {
            try await serviceA.loadOrGenerate(
                DerivedImageRequest(assetID: env.assetID, variant: .gridRegular)
            )
        }
        let taskB = Task {
            try await serviceB.loadOrGenerate(
                DerivedImageRequest(assetID: env.assetID, variant: .gridRegular)
            )
        }

        var orchestrationError: Error?
        var provisionalEntryIDs: [UUID] = []
        do {
            try runCrossInstanceRaceOrchestration(barrier: barrier)
            provisionalEntryIDs = barrier.provisionalEntryIDsSnapshot()
            guard provisionalEntryIDs.count == 2 else {
                throw CrossInstanceOrchestrationError.invalidProvisionalEntryCount(provisionalEntryIDs.count)
            }
            guard provisionalEntryIDs[0] != provisionalEntryIDs[1] else {
                throw CrossInstanceOrchestrationError.duplicateProvisionalEntryIDs
            }
            barrier.releaseFinal()
        } catch {
            orchestrationError = error
        }

        barrier.releaseAll()
        async let resultA = taskA.result
        async let resultB = taskB.result
        let payloadResults = await (resultA, resultB)

        if let orchestrationError {
            throw orchestrationError
        }
        let generatedA = try payloadResults.0.get()
        let generatedB = try payloadResults.1.get()
        try await assertCrossInstanceWinnerLoserEvidence(
            env: env,
            resultA: generatedA,
            resultB: generatedB,
            provisionalEntryIDs: provisionalEntryIDs
        )
    }

    private func assertInvalidHitRebuilds(
        label: String,
        variant: DerivedImageVariant = .gridSmall,
        corrupt: (DerivedImageTestSupport.TempEnvironment, DerivedImagePayload) async throws -> Void
    ) async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: label)
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let factsBefore = try await env.generationCatalogFacts()
        let sourceBefore = try env.sourceFileSnapshot(for: fileURL)
        let jobBefore = try await env.jobRecordCount()
        let tagBefore = try await env.tagRecordCount()

        let (service, bookmarkPort) = env.makeService(
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        let first = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: variant)
        )
        XCTAssertEqual(first.origin, .generated)

        try await corrupt(env, first)

        let second = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: variant)
        )
        XCTAssertEqual(second.origin, .generated)
        XCTAssertNotEqual(second.entryID, first.entryID)
        XCTAssertFalse(second.encodedBytes.isEmpty)

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
}

private enum CrossInstanceOrchestrationError: Error, Equatable {
    case invalidProvisionalEntryCount(Int)
    case duplicateProvisionalEntryIDs
}

extension DerivedImageCacheHitAndConcurrencyTests {
    private func makeEnsureSubdirectoryFixtureRoot(label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAllEnsureSubdir-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func openDirectoryFD(at url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw NSError(domain: "DerivedImageCacheHitAndConcurrencyTests", code: 1)
        }
        return fd
    }

    private func runCrossInstanceRaceOrchestration(
        barrier: DerivedImageTestSupport.CrossInstanceRaceBarrier
    ) throws {
        try barrier.waitUntilStagingBlocked(timeout: 15)
        barrier.releaseStaging()
        try barrier.waitUntilFinalBlocked(timeout: 15)
    }

    private func assertCrossInstanceWinnerLoserEvidence(
        env: DerivedImageTestSupport.TempEnvironment,
        resultA: DerivedImagePayload,
        resultB: DerivedImagePayload,
        provisionalEntryIDs: [UUID]
    ) async throws {
        let generated = resultA.origin == .generated ? resultA : resultB
        let cacheHit = resultA.origin == .cacheHit ? resultA : resultB
        XCTAssertEqual(generated.origin, .generated)
        XCTAssertEqual(cacheHit.origin, .cacheHit)

        let winner = generated
        XCTAssertEqual(resultA.entryID, winner.entryID)
        XCTAssertEqual(resultB.entryID, winner.entryID)
        XCTAssertEqual(resultA.encodedBytes, winner.encodedBytes)
        XCTAssertEqual(resultB.encodedBytes, winner.encodedBytes)
        XCTAssertTrue(provisionalEntryIDs.contains(winner.entryID))

        let loserProvisionalID = try XCTUnwrap(provisionalEntryIDs.first { $0 != winner.entryID })
        XCTAssertNotEqual(loserProvisionalID, winner.entryID)

        let counts = try await env.cacheArtifactCounts()
        XCTAssertEqual(counts.entries, 1)
        XCTAssertEqual(counts.objects, 1)
        XCTAssertEqual(counts.stagingFiles, 0)
        let winnerExists = try await env.cacheEntryExists(id: winner.entryID)
        let loserProvisionalExists = try await env.cacheEntryExists(id: loserProvisionalID)
        XCTAssertTrue(winnerExists)
        XCTAssertFalse(loserProvisionalExists)
        XCTAssertTrue(env.finalObjectExists(entryID: winner.entryID, format: winner.storageFormat))
        XCTAssertFalse(
            env.finalObjectExists(entryID: loserProvisionalID, format: winner.storageFormat)
        )
        let objectNames = try env.listCacheObjectFiles()
        XCTAssertEqual(objectNames.count, 1)
    }
}
