import GRDB
import XCTest
@testable import ImageAll

final class DerivedImageFaultTests: XCTestCase {
    private let generateClockMs: Int64 = FolderReconcileTestSupport.baseTimeMs
    private let hitClockMs: Int64 = FolderReconcileTestSupport.baseTimeMs + 60_000

    // MARK: - 1. staging 排他创建失败

    func testStagingCreateFaultLeavesNoEntryObjectOrStagingAndPreservesCatalog() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "fault-staging-create")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let storeFault = DerivedImageTestSupport.LoggingStoreFaultInjector(faultPoint: .stagingCreate)
        let (service, bookmarkPort) = env.makeService(
            faultInjector: storeFault,
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        let catalogBefore = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)

        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected persistence failure")
        } catch DerivedImageError.derivedCachePersistenceFailed {
        }

        XCTAssertEqual(storeFault.callCount(for: .stagingCreate), 1)
        let catalogAfter = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        DerivedImageTestSupport.assertFaultMatrixCatalogSnapshotUnchanged(
            before: catalogBefore,
            after: catalogAfter
        )
        DerivedImageTestSupport.assertBookmarkPortScopeBalanced(bookmarkPort)
        let entriesAfter = try await env.cacheEntrySnapshots()
        let treeAfter = try env.cacheTreeSnapshot()
        XCTAssertTrue(entriesAfter.isEmpty)
        XCTAssertTrue(treeAfter.isEmpty)
    }

    // MARK: - 2. staging 写中断（RED：seam 在 write 前；调用后旧 invalid candidate 必须保持）

    func testStagingWriteFaultRequiresPartialStagingRegularFileAtProductionSeam() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "fault-staging-write")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let reader = try await env.pinnedSeedFingerprintReader(for: fileURL)
        let sourceReader = DerivedImageSourceReader(fileResourceReader: reader)
        let (baselineService, _) = env.makeService(
            sourceReader: sourceReader,
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        let baseline = try await baselineService.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
        )
        let expectedArtifactByteSize = Int64(baseline.encodedBytes.count)
        try env.tamperCacheObjectSameByteSize(
            entryID: baseline.entryID,
            format: baseline.storageFormat
        )

        let catalogBefore = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        let entriesBefore = try await env.cacheEntrySnapshots()
        let treeBefore = try env.cacheTreeSnapshot()

        let storeFault = DerivedImageTestSupport.StagingWriteObservingFaultInjector(
            cachesDirectory: env.cachesDirectory
        )
        let (service, rebuildBookmarkPort) = env.makeService(
            faultInjector: storeFault,
            sourceReader: sourceReader,
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected persistence failure")
        } catch DerivedImageError.derivedCachePersistenceFailed {
        }

        XCTAssertEqual(storeFault.callCount(for: .stagingWrite), 1)
        let observation = try XCTUnwrap(storeFault.observation)
        let partialSize = try XCTUnwrap(
            observation.partialStagingByteSize,
            "stagingWrite seam must observe a partial staging regular file"
        )
        XCTAssertGreaterThan(partialSize, 0, "partial staging must be non-zero at stagingWrite seam")
        XCTAssertLessThan(
            partialSize,
            expectedArtifactByteSize,
            "partial staging must be smaller than final artifact at stagingWrite seam"
        )

        let catalogAfter = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        DerivedImageTestSupport.assertFaultMatrixCatalogSnapshotUnchanged(
            before: catalogBefore,
            after: catalogAfter
        )
        DerivedImageTestSupport.assertBookmarkPortScopeBalanced(rebuildBookmarkPort)
        let entriesAfter = try await env.cacheEntrySnapshots()
        let treeAfter = try env.cacheTreeSnapshot()
        DerivedImageTestSupport.assertCacheEntrySnapshotsEqual(entriesBefore, entriesAfter)
        DerivedImageTestSupport.assertCacheTreeSnapshotsEqual(treeBefore, treeAfter)
        XCTAssertTrue(treeAfter.filter { $0.type == .staging }.isEmpty, "failed call must leave zero staging")
    }

    // MARK: - 3–5. pre-final publish faults

    func testStagingSyncFaultLeavesNoEntryObjectOrStagingAndPreservesCatalog() async throws {
        try await assertPreFinalPublishFaultClearsArtifacts(
            label: "fault-staging-sync",
            faultPoint: .stagingSync
        )
    }

    func testStagingValidateFaultLeavesNoEntryObjectOrStagingAndPreservesCatalog() async throws {
        try await assertPreFinalPublishFaultClearsArtifacts(
            label: "fault-staging-validate",
            faultPoint: .stagingValidate
        )
    }

    func testFinalRenameFaultLeavesNoEntryObjectOrStagingAndPreservesCatalog() async throws {
        try await assertPreFinalPublishFaultClearsArtifacts(
            label: "fault-final-rename",
            faultPoint: .finalRename
        )
    }

    // MARK: - 6. final 已发布、DB 事务开始前中断

    func testAfterRenameBeforeDBFaultLeavesSingleOrphanAndMaintenanceIsIdempotent() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "fault-after-rename-before-db")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let storeFault = DerivedImageTestSupport.LoggingStoreFaultInjector(faultPoint: .afterRenameBeforeDB)
        let (service, bookmarkPort) = env.makeService(
            faultInjector: storeFault,
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        let catalogBefore = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)

        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected persistence failure")
        } catch DerivedImageError.derivedCachePersistenceFailed {
        }

        XCTAssertEqual(storeFault.callCount(for: .afterRenameBeforeDB), 1)
        let catalogAfterFault = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        DerivedImageTestSupport.assertFaultMatrixCatalogSnapshotUnchanged(
            before: catalogBefore,
            after: catalogAfterFault
        )
        DerivedImageTestSupport.assertBookmarkPortScopeBalanced(bookmarkPort)
        let entriesAfterFault = try await env.cacheEntrySnapshots()
        let treeAfterFault = try env.cacheTreeSnapshot()
        XCTAssertTrue(entriesAfterFault.isEmpty)
        XCTAssertEqual(treeAfterFault.count, 1)
        XCTAssertEqual(treeAfterFault[0].type, .object)
        XCTAssertEqual(try env.countCacheObjects(), 1)

        let maintenance = try await service.performMaintenance()
        XCTAssertEqual(maintenance.removedObjects, 1)
        let treeAfterMaintenance = try env.cacheTreeSnapshot()
        XCTAssertTrue(treeAfterMaintenance.isEmpty)
        let second = try await service.performMaintenance()
        XCTAssertEqual(second.removedObjects, 0)
    }

    // MARK: - 7. invalid-candidate replacement rollback（RED：validateHit 先删旧 entry/object）

    func testInvalidCandidateReplacementRollbackPreservesOldEntryColumnsAndOldObject() async throws {
        try await assertInvalidCandidateReplacementFaultPreservesOldState(
            label: "replacement-rollback"
        )
    }

    // MARK: - fresh insert fault（DML 后 `.insert` seam，事务回滚零 row）

    func testFreshInsertFaultRollsBackEntryAndLeavesOneCompleteOrphan() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "fresh-insert-orphan")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let repoFault = DerivedImageTestSupport.LoggingRepositoryFaultInjector(faultPoint: .insert)
        let (service, bookmarkPort) = env.makeService(
            repositoryFaultInjector: repoFault,
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        let catalogBefore = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)

        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected persistence failure")
        } catch DerivedImageError.derivedCachePersistenceFailed {
        }

        XCTAssertEqual(repoFault.callCount(for: .insert), 1)
        let catalogAfter = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        DerivedImageTestSupport.assertFaultMatrixCatalogSnapshotUnchanged(
            before: catalogBefore,
            after: catalogAfter
        )
        DerivedImageTestSupport.assertBookmarkPortScopeBalanced(bookmarkPort)
        let entriesAfter = try await env.cacheEntrySnapshots()
        let treeAfter = try env.cacheTreeSnapshot()
        XCTAssertTrue(entriesAfter.isEmpty)
        XCTAssertEqual(treeAfter.filter { $0.type == .object }.count, 1)
        XCTAssertTrue(treeAfter.filter { $0.type == .staging }.isEmpty)

        let maintenance = try await service.performMaintenance()
        XCTAssertEqual(maintenance.removedObjects, 1)
        XCTAssertTrue(try env.cacheTreeSnapshot().isEmpty)
        let second = try await service.performMaintenance()
        XCTAssertEqual(second.removedObjects, 0)
    }

    // MARK: - 8. final revalidation repository fault

    func testFinalRevalidationRepositoryFaultTriggersOnceAndLeavesOrphanWithoutEntry() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "fault-final-revalidation")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let repoFault = DerivedImageTestSupport.LoggingRepositoryFaultInjector(faultPoint: .revalidation)
        let (service, bookmarkPort) = env.makeService(
            repositoryFaultInjector: repoFault,
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        let catalogBefore = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)

        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected persistence failure")
        } catch DerivedImageError.derivedCachePersistenceFailed {
        }

        XCTAssertEqual(repoFault.callCount(for: .revalidation), 1)
        XCTAssertEqual(
            repoFault.callCount(for: .insert),
            0,
            "revalidation fault must occur after revalidate and before any insert DML or probe"
        )
        let catalogAfter = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        DerivedImageTestSupport.assertFaultMatrixCatalogSnapshotUnchanged(
            before: catalogBefore,
            after: catalogAfter
        )
        DerivedImageTestSupport.assertBookmarkPortScopeBalanced(bookmarkPort)
        let entriesAfter = try await env.cacheEntrySnapshots()
        let treeAfter = try env.cacheTreeSnapshot()
        XCTAssertTrue(entriesAfter.isEmpty)
        XCTAssertEqual(treeAfter.filter { $0.type == .object }.count, 1)
        XCTAssertTrue(treeAfter.filter { $0.type == .staging }.isEmpty)
    }

    // MARK: - 9. LRU touch（UPDATE 后 seam，事务回滚旧 timestamp）

    func testLRUTouchFaultAfterUpdateRollsBackTimestampAndPreservesEntry() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "fault-lru-touch")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let clock = MutableJobClock(nowMs: generateClockMs)
        let repoFault = DerivedImageTestSupport.LoggingRepositoryFaultInjector(faultPoint: .lruTouch)
        let (service, bookmarkPort) = env.makeService(
            repositoryFaultInjector: repoFault,
            volumeReader: DerivedImageTestSupport.generousVolume,
            clock: clock
        )
        let first = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridRegular)
        )
        XCTAssertEqual(first.origin, DerivedImageOrigin.generated)
        let entriesBefore = try await env.cacheEntrySnapshots()
        let treeBefore = try env.cacheTreeSnapshot()
        let scopeAfterGenerate = bookmarkPort.scopeStartCount
        let lastAccessBefore = try await env.entryLastAccessedMs(id: first.entryID)

        clock.setNowMs(hitClockMs)
        do {
            _ = try await service.loadOrGenerate(
                DerivedImageRequest(assetID: env.assetID, variant: .gridRegular)
            )
            XCTFail("expected persistence failure")
        } catch DerivedImageError.derivedCachePersistenceFailed {
        }

        XCTAssertEqual(repoFault.callCount(for: .lruTouch), 1)
        let entriesAfter = try await env.cacheEntrySnapshots()
        let treeAfter = try env.cacheTreeSnapshot()
        DerivedImageTestSupport.assertCacheEntrySnapshotsEqual(entriesBefore, entriesAfter)
        DerivedImageTestSupport.assertCacheTreeSnapshotsEqual(treeBefore, treeAfter)
        let lastAccessAfterFault = try await env.entryLastAccessedMs(id: first.entryID)
        XCTAssertEqual(lastAccessAfterFault, lastAccessBefore)
        XCTAssertEqual(bookmarkPort.scopeStartCount, scopeAfterGenerate)
        DerivedImageTestSupport.assertBookmarkPortScopeBalanced(bookmarkPort)
    }

    // MARK: - 11. 旧对象删除失败（RED：invalid-candidate replacement 路径不可达 oldObjectDelete）

    func testOldObjectDeleteFaultTriggeredOnceFromInvalidCandidateReplacementPath() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "fault-old-object-delete")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let reader = try await env.pinnedSeedFingerprintReader(for: fileURL)
        let sourceReader = DerivedImageSourceReader(fileResourceReader: reader)
        let (baselineService, _) = env.makeService(
            sourceReader: sourceReader,
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        let first = try await baselineService.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
        )
        try env.tamperCacheObjectSameByteSize(
            entryID: first.entryID,
            format: first.storageFormat
        )
        let entriesBefore = try await env.cacheEntrySnapshots()
        let treeBefore = try env.cacheTreeSnapshot()
        let catalogBefore = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)

        let storeFault = DerivedImageTestSupport.LoggingStoreFaultInjector(faultPoint: .oldObjectDelete)
        let (service, rebuildBookmarkPort) = env.makeService(
            faultInjector: storeFault,
            sourceReader: sourceReader,
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        let second = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
        )

        XCTAssertEqual(storeFault.callCount(for: .oldObjectDelete), 1)
        XCTAssertEqual(second.origin, DerivedImageOrigin.generated)
        XCTAssertNotEqual(second.entryID, first.entryID)
        let entriesAfter = try await env.cacheEntrySnapshots()
        XCTAssertEqual(entriesAfter.count, 1)
        XCTAssertNotEqual(entriesAfter[0].id, first.entryID)
        XCTAssertTrue(env.finalObjectExists(entryID: second.entryID, format: second.storageFormat))
        XCTAssertTrue(
            env.finalObjectExists(entryID: first.entryID, format: first.storageFormat),
            "old object must remain as orphan when oldObjectDelete faults"
        )
        let treeAfter = try env.cacheTreeSnapshot()
        XCTAssertEqual(treeAfter.filter { $0.type == .object }.count, 2)
        let catalogAfter = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        DerivedImageTestSupport.assertFaultMatrixCatalogSnapshotUnchanged(
            before: catalogBefore,
            after: catalogAfter
        )
        DerivedImageTestSupport.assertBookmarkPortScopeBalanced(rebuildBookmarkPort)
        XCTAssertNotEqual(entriesAfter, entriesBefore)
        XCTAssertNotEqual(treeAfter, treeBefore)
    }

    // MARK: - invalid candidate 端到端

    func testInvalidCandidateNeverReturnedAsPayloadAndEntryPreservedOnRebuildFailure() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "invalid-candidate-payload")
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let reader = try await env.pinnedSeedFingerprintReader(for: fileURL)
        let sourceReader = DerivedImageSourceReader(fileResourceReader: reader)
        let (baselineService, _) = env.makeService(
            sourceReader: sourceReader,
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        let first = try await baselineService.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
        )
        try env.tamperCacheObjectSameByteSize(
            entryID: first.entryID,
            format: first.storageFormat
        )
        let corruptedBytes = try env.readCacheObjectBytesNoFollow(
            entryID: first.entryID,
            format: first.storageFormat,
            expectedSize: Int64(first.encodedBytes.count)
        )
        let catalogBefore = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        let entriesBefore = try await env.cacheEntrySnapshots()
        let treeBefore = try env.cacheTreeSnapshot()

        let repoFault = DerivedImageTestSupport.LoggingRepositoryFaultInjector(faultPoint: .insert)
        let (service, rebuildBookmarkPort) = env.makeService(
            repositoryFaultInjector: repoFault,
            sourceReader: sourceReader,
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        do {
            let result = try await service.loadOrGenerate(
                DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
            )
            XCTAssertNotEqual(result.origin, DerivedImageOrigin.cacheHit, "invalid candidate must not be returned as cache hit")
            XCTAssertNotEqual(result.encodedBytes, corruptedBytes, "invalid candidate bytes must not be returned")
            XCTFail("expected persistence failure after invalid candidate rebuild")
        } catch DerivedImageError.derivedCachePersistenceFailed {
        }

        XCTAssertEqual(repoFault.callCount(for: .insert), 1)
        let catalogAfter = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        DerivedImageTestSupport.assertFaultMatrixCatalogSnapshotUnchanged(
            before: catalogBefore,
            after: catalogAfter
        )
        DerivedImageTestSupport.assertBookmarkPortScopeBalanced(rebuildBookmarkPort)
        let entriesAfter = try await env.cacheEntrySnapshots()
        let treeAfter = try env.cacheTreeSnapshot()
        let oldObjectBefore = try XCTUnwrap(treeBefore.first { $0.type == .object })
        DerivedImageTestSupport.assertInvalidCandidateInsertFailurePreservesOldArtifactsAndSingleNewOrphan(
            baseline: first,
            oldObjectBefore: oldObjectBefore,
            entriesBefore: entriesBefore,
            entriesAfter: entriesAfter,
            treeAfter: treeAfter
        )
    }

    // MARK: - staging cleanup failure must not override business error

    func testStagingSyncFaultStillDerivedCachePersistenceFailedWhenStagingCleanupBlocked() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "fault-staging-cleanup-blocked")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let storeFault = DerivedImageTestSupport.StagingSyncCleanupBlockingFaultInjector(
            cachesDirectory: env.cachesDirectory
        )
        defer { storeFault.restoreBlockedStagingArtifact() }
        let (service, bookmarkPort) = env.makeService(
            faultInjector: storeFault,
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        let catalogBefore = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)

        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected persistence failure")
        } catch DerivedImageError.derivedCachePersistenceFailed {
        } catch {
            XCTFail("cleanup failure must not override business error, got \(error)")
        }

        XCTAssertEqual(storeFault.callCount(for: .stagingSync), 1)
        let blockedRelative = try XCTUnwrap(storeFault.blockedStagingRelativeComponent)
        let treeAfterFault = try env.cacheTreeSnapshot()
        XCTAssertEqual(treeAfterFault.filter { $0.type == .staging }.count, 1)
        XCTAssertEqual(treeAfterFault.first?.relativeComponent, blockedRelative)

        storeFault.restoreBlockedStagingArtifact()
        let treeAfterRestore = try env.cacheTreeSnapshot()
        XCTAssertTrue(treeAfterRestore.filter { $0.type == .staging }.isEmpty)

        let catalogAfter = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        DerivedImageTestSupport.assertFaultMatrixCatalogSnapshotUnchanged(
            before: catalogBefore,
            after: catalogAfter
        )
        DerivedImageTestSupport.assertBookmarkPortScopeBalanced(bookmarkPort)
    }

    // MARK: - legal staging orphan maintenance

    func testMaintenanceRemovesLegalStagingOrphanAndSecondRunIsIdempotent() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "fault-staging-orphan-maintenance")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let orphanBytes = FolderReconcileTestSupport.minimalJPEGData()
        let orphanName = try env.plantLegalStagingOrphan(bytes: orphanBytes)
        let treeBefore = try env.cacheTreeSnapshot()
        XCTAssertEqual(treeBefore.filter { $0.type == .staging }.count, 1)
        XCTAssertEqual(treeBefore.first?.relativeComponent, "\(DerivedImageCachePathLayout.stagingComponent)/\(orphanName)")

        let (service, _) = env.makeService(volumeReader: DerivedImageTestSupport.generousVolume)
        let maintenance = try await service.performMaintenance()
        XCTAssertEqual(maintenance.removedObjects, 1)
        XCTAssertTrue(try env.cacheTreeSnapshot().isEmpty)
        let second = try await service.performMaintenance()
        XCTAssertEqual(second.removedObjects, 0)
    }

    // MARK: - 12. 重开真实临时文件库

    func testSuccessfulPublishThenReopenDatabaseReadsSameEntryBytesFormatAndDimensions() async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: "fault-reopen")
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let (service, originalBookmarkPort) = env.makeService(
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        let catalogBefore = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        let published = try await service.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .preview)
        )
        XCTAssertEqual(published.origin, DerivedImageOrigin.generated)
        let entriesBeforeReopen = try await env.cacheEntrySnapshots()
        XCTAssertEqual(entriesBeforeReopen.count, 1)
        DerivedImageTestSupport.assertBookmarkPortScopeBalanced(originalBookmarkPort)

        let reopenedBookmarkPort = FolderReconcileTestSupport.TestBookmarkPort(
            rootByBookmark: [env.bookmark: env.sourceRoot]
        )
        let reopened = try CatalogDatabase.open(at: env.databaseURL)
        let reopenedService = DerivedImageCacheService(
            database: reopened,
            cachesDirectory: env.cachesDirectory,
            sourceAccess: FolderReconcileSourceAccessService(
                repository: GRDBFolderSourceAuthorizationRepository(database: reopened),
                bookmarkPort: reopenedBookmarkPort,
                rootValidator: FolderRootValidator(),
                clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
            ),
            volumeReader: DerivedImageTestSupport.generousVolume,
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )
        let hit = try await reopenedService.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .preview)
        )

        XCTAssertEqual(hit.origin, DerivedImageOrigin.cacheHit)
        XCTAssertEqual(hit.entryID, published.entryID)
        XCTAssertEqual(hit.encodedBytes, published.encodedBytes)
        XCTAssertEqual(hit.storageFormat, published.storageFormat)
        XCTAssertEqual(hit.pixelWidth, published.pixelWidth)
        XCTAssertEqual(hit.pixelHeight, published.pixelHeight)
        XCTAssertEqual(hit.contentRevision, published.contentRevision)
        XCTAssertEqual(hit.representationVersion, published.representationVersion)
        DerivedImageTestSupport.assertBookmarkPortHasZeroScopeAccess(reopenedBookmarkPort)
        DerivedImageTestSupport.assertBookmarkPortScopeBalanced(originalBookmarkPort)

        let entriesAfterReopen = try await env.cacheEntrySnapshots()
        DerivedImageTestSupport.assertCacheEntrySnapshotsEqual(entriesBeforeReopen, entriesAfterReopen)
        let catalogAfter = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        DerivedImageTestSupport.assertFaultMatrixCatalogSnapshotUnchanged(
            before: catalogBefore,
            after: catalogAfter
        )
    }

    // MARK: - Shared helpers

    private func assertPreFinalPublishFaultClearsArtifacts(
        label: String,
        faultPoint: DerivedImageCacheStoreFaultPoint
    ) async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: label)
        defer { env.cleanup() }
        _ = try env.seedAvailableAsset()
        let storeFault = DerivedImageTestSupport.LoggingStoreFaultInjector(faultPoint: faultPoint)
        let (service, bookmarkPort) = env.makeService(
            faultInjector: storeFault,
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        let catalogBefore = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)

        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected persistence failure")
        } catch DerivedImageError.derivedCachePersistenceFailed {
        }

        XCTAssertEqual(storeFault.callCount(for: faultPoint), 1)
        let catalogAfter = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        DerivedImageTestSupport.assertFaultMatrixCatalogSnapshotUnchanged(
            before: catalogBefore,
            after: catalogAfter
        )
        DerivedImageTestSupport.assertBookmarkPortScopeBalanced(bookmarkPort)
        let entriesAfter = try await env.cacheEntrySnapshots()
        let treeAfter = try env.cacheTreeSnapshot()
        XCTAssertTrue(entriesAfter.isEmpty)
        XCTAssertTrue(treeAfter.isEmpty)
    }

    private func assertInvalidCandidateReplacementFaultPreservesOldState(
        label: String
    ) async throws {
        let env = try DerivedImageTestSupport.TempEnvironment(label: label)
        defer { env.cleanup() }
        let fileURL = try env.seedAvailableAsset()
        let reader = try await env.pinnedSeedFingerprintReader(for: fileURL)
        let sourceReader = DerivedImageSourceReader(fileResourceReader: reader)
        let (baselineService, _) = env.makeService(
            sourceReader: sourceReader,
            volumeReader: DerivedImageTestSupport.generousVolume
        )
        let first = try await baselineService.loadOrGenerate(
            DerivedImageRequest(assetID: env.assetID, variant: .gridSmall)
        )
        try env.tamperCacheObjectSameByteSize(
            entryID: first.entryID,
            format: first.storageFormat
        )
        let catalogBefore = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        let entriesBefore = try await env.cacheEntrySnapshots()
        let treeBefore = try env.cacheTreeSnapshot()

        let repoFault = DerivedImageTestSupport.LoggingRepositoryFaultInjector(faultPoint: .insert)
        let (service, rebuildBookmarkPort) = env.makeService(
            repositoryFaultInjector: repoFault,
            sourceReader: sourceReader,
            volumeReader: DerivedImageTestSupport.generousVolume
        )

        do {
            _ = try await service.loadOrGenerate(DerivedImageRequest(assetID: env.assetID, variant: .gridSmall))
            XCTFail("expected persistence failure")
        } catch DerivedImageError.derivedCachePersistenceFailed {
        }

        XCTAssertEqual(repoFault.callCount(for: .insert), 1)
        let catalogAfter = try await DerivedImageTestSupport.captureFaultMatrixCatalogSnapshot(env: env)
        DerivedImageTestSupport.assertFaultMatrixCatalogSnapshotUnchanged(
            before: catalogBefore,
            after: catalogAfter
        )
        DerivedImageTestSupport.assertBookmarkPortScopeBalanced(rebuildBookmarkPort)
        let entriesAfter = try await env.cacheEntrySnapshots()
        let treeAfter = try env.cacheTreeSnapshot()
        let oldObjectBefore = try XCTUnwrap(treeBefore.first { $0.type == .object })
        DerivedImageTestSupport.assertInvalidCandidateInsertFailurePreservesOldArtifactsAndSingleNewOrphan(
            baseline: first,
            oldObjectBefore: oldObjectBefore,
            entriesBefore: entriesBefore,
            entriesAfter: entriesAfter,
            treeAfter: treeAfter
        )
        XCTAssertFalse(
            entriesAfter.contains { $0.id != first.entryID },
            "no new entry may point at a replacement object after rollback"
        )
    }
}
