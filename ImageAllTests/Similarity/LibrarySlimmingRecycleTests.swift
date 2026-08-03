import CryptoKit
import Darwin
import Foundation
import GRDB
import XCTest
@testable import ImageAll

final class LibrarySlimmingRecycleTests: XCTestCase {
    func testAsyncInteractiveIOPriorityGateKeepsExclusiveLifecycleWindow() async {
        let gate = InteractiveIOPriorityGate()
        let interactiveStarted = DispatchSemaphore(value: 0)
        let competingWorkStarted = DispatchSemaphore(value: 0)

        let lifecycleTask = Task.detached {
            await gate.withInteractiveWork {
                await Task.yield()
                interactiveStarted.signal()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        XCTAssertEqual(interactiveStarted.wait(timeout: .now() + 1), .success)

        let competingTask = Task.detached {
            gate.withInteractiveWork {
                competingWorkStarted.signal()
            }
        }
        XCTAssertEqual(competingWorkStarted.wait(timeout: .now() + 0.05), .timedOut)

        XCTAssertEqual(competingWorkStarted.wait(timeout: .now() + 1), .success)
        await lifecycleTask.value
        _ = await competingTask.value
        XCTAssertFalse(gate.hasInteractiveWork)
    }

    func testInteractiveIOPriorityGateBlocksBackgroundWorkUntilRecycleFinishes() async {
        let gate = InteractiveIOPriorityGate()
        let interactiveStarted = DispatchSemaphore(value: 0)
        let releaseInteractive = DispatchSemaphore(value: 0)
        let backgroundPassed = DispatchSemaphore(value: 0)

        let interactiveTask = Task.detached {
            gate.withInteractiveWork {
                interactiveStarted.signal()
                _ = releaseInteractive.wait(timeout: .now() + 2)
            }
        }
        XCTAssertEqual(interactiveStarted.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(gate.hasInteractiveWork)

        let backgroundTask = Task.detached {
            gate.waitForInteractiveWorkToFinish()
            backgroundPassed.signal()
        }
        XCTAssertEqual(backgroundPassed.wait(timeout: .now() + 0.05), .timedOut)

        releaseInteractive.signal()
        XCTAssertEqual(backgroundPassed.wait(timeout: .now() + 1), .success)
        await interactiveTask.value
        await backgroundTask.value
        XCTAssertFalse(gate.hasInteractiveWork)
    }

    func testInteractiveGateDrainsCurrentBackgroundBeforeStarting() async {
        let gate = InteractiveIOPriorityGate()
        let firstBackgroundStarted = DispatchSemaphore(value: 0)
        let releaseFirstBackground = DispatchSemaphore(value: 0)
        let interactiveWaiting = DispatchSemaphore(value: 0)
        let interactiveStarted = DispatchSemaphore(value: 0)
        let releaseInteractive = DispatchSemaphore(value: 0)
        let secondBackgroundStarted = DispatchSemaphore(value: 0)

        let firstBackground = Task.detached {
            gate.withBackgroundWork {
                firstBackgroundStarted.signal()
                _ = releaseFirstBackground.wait(timeout: .now() + 2)
            }
        }
        XCTAssertEqual(firstBackgroundStarted.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(gate.hasBackgroundWork)

        let interactive = Task.detached {
            gate.withInteractiveWork(
                onWaitingForBackground: { interactiveWaiting.signal() }
            ) {
                interactiveStarted.signal()
                _ = releaseInteractive.wait(timeout: .now() + 2)
            }
        }
        XCTAssertEqual(interactiveWaiting.wait(timeout: .now() + 1), .success)

        let secondBackground = Task.detached {
            gate.withBackgroundWork {
                secondBackgroundStarted.signal()
            }
        }
        XCTAssertEqual(secondBackgroundStarted.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertEqual(interactiveStarted.wait(timeout: .now() + 0.05), .timedOut)

        releaseFirstBackground.signal()
        XCTAssertEqual(interactiveStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(secondBackgroundStarted.wait(timeout: .now() + 0.05), .timedOut)

        releaseInteractive.signal()
        XCTAssertEqual(secondBackgroundStarted.wait(timeout: .now() + 1), .success)
        await firstBackground.value
        await interactive.value
        _ = await secondBackground.value
        XCTAssertFalse(gate.hasInteractiveWork)
        XCTAssertFalse(gate.hasBackgroundWork)
    }

    func testRecycleFailureCauseIsExclusiveOnlyWhenItCoversEveryFailure() {
        let folderFailureID = UUID()
        let photosFailureID = UUID()
        let unclassifiedFailureID = UUID()
        let folderOnly = LibrarySlimmingRecycleMoveOutcome(
            recycledEntryIDs: [],
            skippedPhotosAssetIDs: [],
            failedAssetIDs: [folderFailureID],
            authorizationRequiredSourceIDs: [],
            authorizationRequiredAssetIDs: [],
            authorizationDeniedPhotosAssetIDs: [],
            mutationAuthorizationInvalidAssetIDs: [folderFailureID]
        )
        var folderMixed = folderOnly
        folderMixed.failedAssetIDs.append(unclassifiedFailureID)
        let photosOnly = LibrarySlimmingRecycleMoveOutcome(
            recycledEntryIDs: [],
            skippedPhotosAssetIDs: [],
            failedAssetIDs: [photosFailureID],
            authorizationRequiredSourceIDs: [],
            authorizationRequiredAssetIDs: [],
            authorizationDeniedPhotosAssetIDs: [],
            photosMutationFailedAssetIDs: [photosFailureID]
        )
        var photosMixed = photosOnly
        photosMixed.failedAssetIDs.append(unclassifiedFailureID)

        XCTAssertTrue(folderOnly.hasOnlyMutationAuthorizationInvalidFailures)
        XCTAssertFalse(folderMixed.hasOnlyMutationAuthorizationInvalidFailures)
        XCTAssertTrue(photosOnly.hasOnlyPhotosMutationFailures)
        XCTAssertFalse(photosMixed.hasOnlyPhotosMutationFailures)
    }

    func testMoveConfirmationPolicyOnlySkipsOrdinaryBatchesUpToFive() {
        for count in 1 ... 5 {
            XCTAssertFalse(
                LibrarySlimmingMoveConfirmationPolicy.requiresConfirmation(
                    assetCount: count,
                    skipsSmallMoveConfirmation: true,
                    isIdenticalCleanup: false
                )
            )
        }
        XCTAssertTrue(
            LibrarySlimmingMoveConfirmationPolicy.requiresConfirmation(
                assetCount: 6,
                skipsSmallMoveConfirmation: true,
                isIdenticalCleanup: false
            )
        )
        XCTAssertTrue(
            LibrarySlimmingMoveConfirmationPolicy.requiresConfirmation(
                assetCount: 1,
                skipsSmallMoveConfirmation: true,
                isIdenticalCleanup: true
            )
        )
    }

    func testIdenticalCleanupPlannerDeletesPhotosThenLongerSourceNamesAndKeepsOne() {
        let photosID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let longNameID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let shortNameID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let cluster = SlimmingCluster(
            id: UUID(),
            kind: .byteIdentical,
            memberAssetIDs: [photosID, longNameID, shortNameID],
            representativeAssetID: photosID,
            score: 1,
            modelIdentity: .featurePrintOnly
        )
        let candidates = [
            LibrarySlimmingIdenticalCleanupCandidate(
                assetID: photosID,
                sourceID: UUID(),
                sourceKind: .photos,
                sourceDisplayName: "Apple Photos"
            ),
            LibrarySlimmingIdenticalCleanupCandidate(
                assetID: longNameID,
                sourceID: UUID(),
                sourceKind: .file,
                sourceDisplayName: "2024 下半年 粒粒和卫卫 iCloud 备份"
            ),
            LibrarySlimmingIdenticalCleanupCandidate(
                assetID: shortNameID,
                sourceID: UUID(),
                sourceKind: .file,
                sourceDisplayName: "2024"
            ),
        ]

        let plan = LibrarySlimmingIdenticalCleanupPlanner.makePlan(
            clusters: [cluster],
            candidates: candidates
        )

        XCTAssertEqual(plan.groupCount, 1)
        XCTAssertEqual(plan.assetIDsToRecycle, [photosID, longNameID])
        XCTAssertEqual(plan.survivorAssetIDs, [shortNameID])
        XCTAssertEqual(plan.retainedAssetCount, 1)
        XCTAssertEqual(plan.verifiedAssetCount, 3)
        XCTAssertEqual(plan.groupSizeHistogram, [3: 1])
        XCTAssertEqual(plan.photosAssetCount, 1)
        XCTAssertEqual(plan.fileAssetCount, 1)
        XCTAssertEqual(plan.skippedGroupCount, 0)
    }

    func testIdenticalCleanupPlannerHandlesAllGroupsButIgnoresSimilarGroups() {
        let firstIDs = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
        ]
        let secondIDs = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
        ]
        let similarIDs = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
        ]
        let clusters = [
            SlimmingCluster(
                id: UUID(),
                kind: .byteIdentical,
                memberAssetIDs: firstIDs,
                representativeAssetID: firstIDs[0],
                score: 1,
                modelIdentity: .featurePrintOnly
            ),
            SlimmingCluster(
                id: UUID(),
                kind: .byteIdentical,
                memberAssetIDs: secondIDs,
                representativeAssetID: secondIDs[0],
                score: 1,
                modelIdentity: .featurePrintOnly
            ),
            SlimmingCluster(
                id: UUID(),
                kind: .nearDuplicateScene,
                memberAssetIDs: similarIDs,
                representativeAssetID: similarIDs[0],
                score: 0.95,
                modelIdentity: .featurePrintOnly
            ),
        ]
        let sharedSourceID = UUID()
        let candidates = (firstIDs + secondIDs + similarIDs).map {
            LibrarySlimmingIdenticalCleanupCandidate(
                assetID: $0,
                sourceID: sharedSourceID,
                sourceKind: .file,
                sourceDisplayName: "同名来源"
            )
        }

        let plan = LibrarySlimmingIdenticalCleanupPlanner.makePlan(
            clusters: clusters,
            candidates: candidates
        )

        XCTAssertEqual(plan.groupCount, 2)
        XCTAssertEqual(plan.assetIDsToRecycle.count, 3)
        XCTAssertEqual(Set(plan.survivorAssetIDs), Set([firstIDs[0], secondIDs[0]]))
        XCTAssertEqual(plan.retainedAssetCount, 2)
        XCTAssertEqual(plan.verifiedAssetCount, 5)
        XCTAssertEqual(plan.groupSizeHistogram, [2: 1, 3: 1])
        XCTAssertTrue(plan.assetIDsToRecycle.allSatisfy { !similarIDs.contains($0) })
    }

    func testRecycleServicePlansIdenticalCleanupFromCurrentCatalogSourceFacts() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let file = try env.seedAsset(
            relativePath: "2024/keep.jpg",
            contents: Data("identical".utf8)
        )
        let photosID = try env.seedPhotosAsset(localIdentifier: "cleanup-plan-photo")
        let digest = Data(SHA256.hash(data: Data("identical".utf8)))
        try env.seedVerifiedSimilarityFingerprint(assetID: file.assetID, sha256: digest)
        try env.seedVerifiedSimilarityFingerprint(assetID: photosID, sha256: digest)
        let cluster = SlimmingCluster(
            id: UUID(),
            kind: .byteIdentical,
            memberAssetIDs: [file.assetID, photosID],
            representativeAssetID: photosID,
            score: 1,
            modelIdentity: .featurePrintOnly
        )

        let plan = try env.makeRecycleService().makeIdenticalCleanupPlan(
            clusters: [cluster]
        )

        XCTAssertEqual(plan.groupCount, 1)
        XCTAssertEqual(plan.assetIDsToRecycle, [photosID])
        XCTAssertEqual(plan.survivorAssetIDs, [file.assetID])
        XCTAssertEqual(plan.photosAssetCount, 1)
        XCTAssertEqual(plan.fileAssetCount, 0)
        XCTAssertEqual(plan.skippedGroupCount, 0)
        XCTAssertEqual(Set(plan.assetProofs.map(\.assetID)), Set([file.assetID, photosID]))
    }

    func testRecycleServiceRejectsStaleExactClusterWhenCurrentHashesDiffer() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let first = try env.seedAsset(relativePath: "first.jpg", contents: Data("first".utf8))
        let second = try env.seedAsset(relativePath: "second.jpg", contents: Data("second".utf8))
        try env.seedVerifiedSimilarityFingerprint(
            assetID: first.assetID,
            sha256: Data(SHA256.hash(data: Data("first".utf8)))
        )
        try env.seedVerifiedSimilarityFingerprint(
            assetID: second.assetID,
            sha256: Data(SHA256.hash(data: Data("second".utf8)))
        )
        let cluster = SlimmingCluster(
            id: UUID(),
            kind: .byteIdentical,
            memberAssetIDs: [first.assetID, second.assetID],
            representativeAssetID: first.assetID,
            score: 0,
            modelIdentity: .featurePrintOnly
        )

        let plan = try env.makeRecycleService().makeIdenticalCleanupPlan(clusters: [cluster])

        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.skippedGroupCount, 1)
    }

    func testIdenticalCleanupExecutionRejectsChangedContentRevisionBeforeMutation() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let bytes = Data("same".utf8)
        let first = try env.seedAsset(relativePath: "first.jpg", contents: bytes)
        let second = try env.seedAsset(relativePath: "second.jpg", contents: bytes)
        let digest = Data(SHA256.hash(data: bytes))
        try env.seedVerifiedSimilarityFingerprint(assetID: first.assetID, sha256: digest)
        try env.seedVerifiedSimilarityFingerprint(assetID: second.assetID, sha256: digest)
        let cluster = SlimmingCluster(
            id: UUID(),
            kind: .byteIdentical,
            memberAssetIDs: [first.assetID, second.assetID],
            representativeAssetID: first.assetID,
            score: 0,
            modelIdentity: .featurePrintOnly
        )
        let service = env.makeRecycleService()
        let plan = try service.makeIdenticalCleanupPlan(clusters: [cluster])
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET content_revision = 2 WHERE id = ?",
                arguments: [plan.assetIDsToRecycle[0].uuidString.lowercased()]
            )
        }

        XCTAssertThrowsError(
            try service.moveIdenticalCleanupAssetsToRecycle(plan: plan, onProgress: { _ in })
        ) { error in
            XCTAssertEqual(error as? LibrarySlimmingRecycleError, .cleanupPlanChanged)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.fileURL.path))
    }

    func testIdenticalCleanupPreflightsFolderAuthorizationBeforeAnyPhotoKitMutation() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let bytes = Data("same-preflight".utf8)
        let first = try env.seedAsset(relativePath: "first.jpg", contents: bytes)
        let second = try env.seedAsset(relativePath: "second.jpg", contents: bytes)
        let photosID = try env.seedPhotosAsset(localIdentifier: "preflight-photo")
        let digest = Data(SHA256.hash(data: bytes))
        for assetID in [first.assetID, second.assetID, photosID] {
            try env.seedVerifiedSimilarityFingerprint(assetID: assetID, sha256: digest)
        }
        let cluster = SlimmingCluster(
            id: UUID(),
            kind: .byteIdentical,
            memberAssetIDs: [first.assetID, second.assetID, photosID],
            representativeAssetID: first.assetID,
            score: 0,
            modelIdentity: .featurePrintOnly
        )
        let photos = FakePhotosLibraryMutationPort()
        photos.presenceByID["preflight-photo"] = .available
        let service = env.makeRecycleService(
            mutationAccess: DirectFolderMutationAccess(rootsBySourceID: [:]),
            photosMutation: photos
        )
        let plan = try service.makeIdenticalCleanupPlan(clusters: [cluster])

        let outcome = try service.moveIdenticalCleanupAssetsToRecycle(
            plan: plan,
            onProgress: { _ in }
        )

        XCTAssertEqual(Set(outcome.failedAssetIDs), Set(plan.assetIDsToRecycle))
        XCTAssertEqual(outcome.authorizationRequiredSourceIDs, [env.sourceID])
        XCTAssertTrue(photos.moveRequestBatches.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.fileURL.path))
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)
    }

    func testIdenticalCleanupPreflightsPhotosAuthorizationBeforeAnyFolderMutation() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let bytes = Data("same-photos-preflight".utf8)
        let first = try env.seedAsset(relativePath: "first.jpg", contents: bytes)
        let second = try env.seedAsset(relativePath: "second.jpg", contents: bytes)
        let photosID = try env.seedPhotosAsset(localIdentifier: "denied-preflight-photo")
        let digest = Data(SHA256.hash(data: bytes))
        for assetID in [first.assetID, second.assetID, photosID] {
            try env.seedVerifiedSimilarityFingerprint(assetID: assetID, sha256: digest)
        }
        let cluster = SlimmingCluster(
            id: UUID(),
            kind: .byteIdentical,
            memberAssetIDs: [first.assetID, second.assetID, photosID],
            representativeAssetID: first.assetID,
            score: 0,
            modelIdentity: .featurePrintOnly
        )
        let photos = FakePhotosLibraryMutationPort()
        photos.authorization = .denied
        photos.presenceByID["denied-preflight-photo"] = .available
        let service = env.makeRecycleService(photosMutation: photos)
        let plan = try service.makeIdenticalCleanupPlan(clusters: [cluster])

        let outcome = try service.moveIdenticalCleanupAssetsToRecycle(
            plan: plan,
            onProgress: { _ in }
        )

        XCTAssertEqual(Set(outcome.failedAssetIDs), Set(plan.assetIDsToRecycle))
        XCTAssertEqual(outcome.authorizationDeniedPhotosAssetIDs, [photosID])
        XCTAssertTrue(photos.moveRequestBatches.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.fileURL.path))
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)
    }

    func testRecycleServiceVerifiesActualPostDeleteRetainedNonredundantCount() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let survivor = try env.seedAsset(
            relativePath: "keep.jpg",
            contents: Data("identical".utf8)
        )
        let redundantA = try env.seedAsset(
            relativePath: "redundant-a.jpg",
            contents: Data("identical".utf8)
        )
        let redundantB = try env.seedAsset(
            relativePath: "redundant-b.jpg",
            contents: Data("identical".utf8)
        )
        let clusterID = UUID()
        let plan = LibrarySlimmingIdenticalCleanupPlan(
            decisions: [
                LibrarySlimmingIdenticalCleanupDecision(
                    clusterID: clusterID,
                    survivorAssetID: survivor.assetID,
                    assetIDsToRecycle: [redundantA.assetID, redundantB.assetID]
                ),
            ],
            skippedGroupCount: 0,
            photosAssetCount: 0,
            fileAssetCount: 2
        )
        let service = env.makeRecycleService()

        _ = try service.moveAssetsToRecycle(assetIDs: plan.assetIDsToRecycle)
        let verification = try service.verifyIdenticalCleanup(plan: plan)

        XCTAssertEqual(verification.observedAssetCount, 3)
        XCTAssertEqual(verification.currentAvailableAssetIDs, [survivor.assetID])
        XCTAssertEqual(verification.retainedNonredundantAssetIDs, [survivor.assetID])
        XCTAssertEqual(verification.retainedNonredundantAssetCount, 1)
        XCTAssertEqual(
            Set(verification.recycledRedundantAssetIDs),
            Set([redundantA.assetID, redundantB.assetID])
        )
        XCTAssertEqual(verification.recycledRedundantAssetCount, 2)
        XCTAssertEqual(verification.verifiedGroupIDs, [clusterID])
        XCTAssertEqual(verification.verifiedGroupCount, 1)
        XCTAssertEqual(verification.targetGroupCount, 1)
        XCTAssertEqual(verification.targetRetainedAssetCount, 1)
        XCTAssertTrue(verification.remainingRedundantAssetIDs.isEmpty)
        XCTAssertTrue(verification.unresolvedAssetIDs.isEmpty)
        XCTAssertTrue(verification.unresolvedGroupIDs.isEmpty)
        XCTAssertTrue(verification.isComplete)
    }

    func testRecycleServiceReportsActualMoveProgressForEachTerminalFileAsset() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let first = try env.seedAsset(
            relativePath: "first.jpg",
            contents: Data("first".utf8)
        )
        let second = try env.seedAsset(
            relativePath: "second.jpg",
            contents: Data("second".utf8)
        )
        let progress = RecycleMoveProgressProbe()

        _ = try env.makeRecycleService().moveAssetsToRecycle(
            assetIDs: [first.assetID, second.assetID],
            onProgress: { progress.append($0) }
        )

        XCTAssertEqual(progress.values.first?.phase, .preparing)
        XCTAssertEqual(
            progress.values.filter { $0.phase == .completedAsset },
            [
                LibrarySlimmingRecycleMoveProgress(
                    completedAssetCount: 1,
                    totalAssetCount: 2,
                    totalFileBytes: 11
                ),
                LibrarySlimmingRecycleMoveProgress(
                    completedAssetCount: 2,
                    totalAssetCount: 2,
                    totalFileBytes: 11
                ),
            ]
        )
    }

    func testRecycleServiceDoesNotCountIncompleteGroupAsRetainedNonredundant() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let survivor = try env.seedAsset(
            relativePath: "keep.jpg",
            contents: Data("identical".utf8)
        )
        let recycled = try env.seedAsset(
            relativePath: "recycled.jpg",
            contents: Data("identical".utf8)
        )
        let stillAvailable = try env.seedAsset(
            relativePath: "still-available.jpg",
            contents: Data("identical".utf8)
        )
        let clusterID = UUID()
        let plan = LibrarySlimmingIdenticalCleanupPlan(
            decisions: [
                LibrarySlimmingIdenticalCleanupDecision(
                    clusterID: clusterID,
                    survivorAssetID: survivor.assetID,
                    assetIDsToRecycle: [recycled.assetID, stillAvailable.assetID]
                ),
            ],
            skippedGroupCount: 0,
            photosAssetCount: 0,
            fileAssetCount: 2
        )
        let service = env.makeRecycleService()

        _ = try service.moveAssetsToRecycle(assetIDs: [recycled.assetID])
        let verification = try service.verifyIdenticalCleanup(plan: plan)

        XCTAssertEqual(verification.observedAssetCount, 3)
        XCTAssertEqual(verification.currentAvailableAssetCount, 2)
        XCTAssertTrue(verification.retainedNonredundantAssetIDs.isEmpty)
        XCTAssertEqual(verification.recycledRedundantAssetIDs, [recycled.assetID])
        XCTAssertEqual(verification.remainingRedundantAssetIDs, [stillAvailable.assetID])
        XCTAssertTrue(verification.unresolvedAssetIDs.isEmpty)
        XCTAssertTrue(verification.verifiedGroupIDs.isEmpty)
        XCTAssertEqual(verification.unresolvedGroupIDs, [clusterID])
        XCTAssertEqual(verification.targetGroupCount, 1)
        XCTAssertEqual(verification.targetRetainedAssetCount, 1)
        XCTAssertFalse(verification.isComplete)
    }

    func testCountdownFormatterUsesDaysAndHours() {
        let now: Int64 = 1_700_000_000_000
        XCTAssertEqual(
            RecycleCountdownFormatter.text(purgeAfterMs: now + LibrarySlimmingRecyclePolicy.dayMs * 3, nowMs: now),
            "3 天后永久删除"
        )
        XCTAssertEqual(
            RecycleCountdownFormatter.text(purgeAfterMs: now + 5 * 60 * 60 * 1_000, nowMs: now),
            "5 小时后永久删除"
        )
        XCTAssertEqual(
            RecycleCountdownFormatter.text(purgeAfterMs: now - 1, nowMs: now),
            "即将永久删除"
        )
        XCTAssertEqual(
            RecycleCountdownFormatter.recordCleanupText(
                cleanupAfterMs: now + LibrarySlimmingRecyclePolicy.dayMs * 3,
                nowMs: now
            ),
            "ImageAll 将在 3 天后清理此记录"
        )
    }

    func testMutationAccessRejectsReadOnlyBookmarkUntilUserGrantsWriteAccess() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        _ = try env.seedAsset(relativePath: "album/read-only.jpg", contents: Data("readonly".utf8))
        let bookmarks = RecordingMutationBookmarkPort(resolvedURL: env.sourceRoot)
        let access = FolderMutationAccessService(
            database: env.database,
            bookmarkPort: bookmarks
        )

        XCTAssertThrowsError(
            try access.withWritableSourceRoot(sourceID: env.sourceID) { _ in () }
        ) { error in
            XCTAssertEqual(
                error as? LibrarySlimmingRecycleError,
                .mutationAuthorizationRequired
            )
        }
        XCTAssertEqual(bookmarks.resolveCount, 0)
    }

    func testPreflightAuthorizationFailureIsVisibleAndDiscardableWithoutFileIO() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let originalBytes = Data("authorization-gated-original".utf8)
        let seeded = try env.seedAsset(
            relativePath: "album/preflight.jpg",
            contents: originalBytes
        )
        let service = env.makeRecycleService(
            mutationAccess: DirectFolderMutationAccess(rootsBySourceID: [:])
        )

        let outcome = try service.moveAssetsToRecycle(assetIDs: [seeded.assetID])

        XCTAssertEqual(outcome.failedAssetIDs, [seeded.assetID])
        XCTAssertEqual(outcome.authorizationRequiredAssetIDs, [seeded.assetID])
        XCTAssertEqual(try Data(contentsOf: seeded.fileURL), originalBytes)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: env.quarantineRoot,
                includingPropertiesForKeys: nil
            ),
            []
        )
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)
        let visible = try service.listRecycleBinEntries()
        let failure = try XCTUnwrap(visible.first)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(failure.state, .failed)
        XCTAssertEqual(
            failure.errorCode,
            RecycleFailureCode.mutationAuthorizationRequired
        )
        XCTAssertEqual(failure.resolution, .discardPreflightFailure)

        try service.discardFailedPreflightEntry(entryID: failure.id)

        XCTAssertTrue(try service.listRecycleBinEntries().isEmpty)
        XCTAssertEqual(try Data(contentsOf: seeded.fileURL), originalBytes)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: env.quarantineRoot,
                includingPropertiesForKeys: nil
            ),
            []
        )
    }

    func testMutationAccessAllowsExplicitRestoreAccessForDisabledSource() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        _ = try env.seedAsset(
            relativePath: "album/disabled.jpg",
            contents: Data("disabled".utf8)
        )
        try env.database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source_mutation_authorization (
                    source_id, bookmark, updated_at_ms
                ) VALUES (?, ?, ?)
                """,
                arguments: [
                    env.sourceID.uuidString.lowercased(),
                    Data("writable".utf8),
                    FolderReconcileTestSupport.baseTimeMs,
                ]
            )
            try db.execute(
                sql: """
                UPDATE source
                SET state = 'disabled'
                WHERE id = ?
                """,
                arguments: [env.sourceID.uuidString.lowercased()]
            )
        }
        let bookmarks = RecordingMutationBookmarkPort(resolvedURL: env.sourceRoot)
        let access = FolderMutationAccessService(
            database: env.database,
            bookmarkPort: bookmarks
        )

        let resolvedPath = try access.withWritableSourceRoot(
            sourceID: env.sourceID
        ) { $0.path }

        XCTAssertEqual(resolvedPath, env.sourceRoot.path)
        XCTAssertEqual(bookmarks.resolveCount, 1)
    }

    func testMutationAccessTreatsPersistedButUnresolvableWriteBookmarkAsInvalid() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        _ = try env.seedAsset(
            relativePath: "album/stale.jpg",
            contents: Data("stale".utf8)
        )
        try env.database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source_mutation_authorization (
                    source_id, bookmark, updated_at_ms
                ) VALUES (?, ?, ?)
                """,
                arguments: [
                    env.sourceID.uuidString.lowercased(),
                    Data("stale-writable".utf8),
                    FolderReconcileTestSupport.baseTimeMs,
                ]
            )
        }
        let access = FolderMutationAccessService(
            database: env.database,
            bookmarkPort: FailingMutationBookmarkPort()
        )

        XCTAssertThrowsError(
            try access.withWritableSourceRoot(sourceID: env.sourceID) { _ in () }
        ) { error in
            XCTAssertEqual(
                error as? LibrarySlimmingRecycleError,
                .mutationAuthorizationInvalid
            )
        }
    }

    func testMoveDoesNotRequestInteractiveAuthorizationForInvalidPersistedBookmark() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "album/invalid-auth.jpg",
            contents: Data("invalid-auth".utf8)
        )
        let service = env.makeRecycleService(
            mutationAccess: InvalidFolderMutationAccess()
        )

        let outcome = try service.moveAssetsToRecycle(assetIDs: [seeded.assetID])

        XCTAssertEqual(outcome.failedAssetIDs, [seeded.assetID])
        XCTAssertEqual(outcome.mutationAuthorizationInvalidAssetIDs, [seeded.assetID])
        XCTAssertTrue(outcome.authorizationRequiredSourceIDs.isEmpty)
        XCTAssertTrue(outcome.authorizationRequiredAssetIDs.isEmpty)
        XCTAssertTrue(outcome.photosMutationFailedAssetIDs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.fileURL.path))
    }

    @MainActor
    func testMutationAuthorizationPersistsWritableBookmarkForSameSourceRoot() async throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        _ = try env.seedAsset(relativePath: "album/authorize.jpg", contents: Data("authorize".utf8))
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        picker.configuredResponses = [env.sourceRoot]
        let writableBookmark = Data("writable-bookmark".utf8)
        let bookmarks = RecordingMutationBookmarkPort(
            resolvedURL: env.sourceRoot,
            writableBookmark: writableBookmark
        )
        let authorization = FolderMutationAuthorizationCoordinator(
            database: env.database,
            picker: picker,
            bookmarkPort: bookmarks,
            rootValidator: FolderRootValidator(),
            relationshipChecker: FoundationFolderRootRelationshipChecker(),
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )
        let sourceID = env.sourceID
        let database = env.database

        let outcome = try await authorization.authorizeMutation(sourceID: sourceID)

        XCTAssertEqual(outcome, .authorized(sourceID: sourceID))
        XCTAssertEqual(picker.initialDirectoryURLs, [env.sourceRoot])
        let stored: Data? = try await database.pool.read { db in
            try Data.fetchOne(
                db,
                sql: """
                SELECT bookmark
                FROM source_mutation_authorization
                WHERE source_id = ?
                """,
                arguments: [sourceID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(stored, writableBookmark)
        XCTAssertEqual(bookmarks.writableCreationCount, 1)
    }

    @MainActor
    func testMutationAuthorizationRejectsDifferentFolderWithoutPersistingBookmark() async throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        _ = try env.seedAsset(
            relativePath: "album/reject-mismatch.jpg",
            contents: Data("mismatch".utf8)
        )
        let otherRoot = env.root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let picker = FolderAuthorizationTestSupport.FakeDirectoryPicker()
        picker.configuredResponses = [otherRoot]
        let bookmarks = RecordingMutationBookmarkPort(resolvedURL: env.sourceRoot)
        let authorization = FolderMutationAuthorizationCoordinator(
            database: env.database,
            picker: picker,
            bookmarkPort: bookmarks,
            rootValidator: FolderRootValidator(),
            relationshipChecker: FoundationFolderRootRelationshipChecker(),
            clock: FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        )
        let sourceID = env.sourceID
        let database = env.database

        do {
            _ = try await authorization.authorizeMutation(sourceID: sourceID)
            XCTFail("different folder must not receive mutation authorization")
        } catch {
            XCTAssertEqual(error as? FolderAuthorizationError, .identityMismatch)
        }
        let stored: Data? = try await database.pool.read { db in
            try Data.fetchOne(
                db,
                sql: """
                SELECT bookmark
                FROM source_mutation_authorization
                WHERE source_id = ?
                """,
                arguments: [sourceID.uuidString.lowercased()]
            )
        }
        XCTAssertNil(stored)
        XCTAssertEqual(bookmarks.writableCreationCount, 0)
    }

    func testSameVolumeMoveRestoreAndPurge() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }

        let bytes = Data("recycle-fixture".utf8)
        let seeded = try env.seedAsset(relativePath: "album/a.jpg", contents: bytes)
        let service = env.makeRecycleService()

        let outcome = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        XCTAssertEqual(outcome.recycledEntryIDs.count, 1)
        XCTAssertTrue(outcome.skippedPhotosAssetIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.fileURL.path))

        let entries = try service.listRecycledEntries()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        let quarantineURL = env.quarantineRoot.appendingPathComponent(entry.quarantineRelativePath!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
        XCTAssertEqual(try Data(contentsOf: quarantineURL), bytes)

        let availability: String = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            ) ?? ""
        }
        XCTAssertEqual(availability, AssetAvailability.recycled.rawValue)

        try service.restore(entryID: entry.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: seeded.fileURL), bytes)
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)

        // Re-recycle then purge.
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let recycled = try XCTUnwrap(try service.listRecycledEntries().first)
        try service.purgeNow(entryID: recycled.id)
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)
        let retainedAsset = try env.database.pool.read { db -> Row? in
            try Row.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(retainedAsset?["availability"] as String?, AssetAvailability.recycled.rawValue)
    }

    func testSameVolumeVideoMoveDoesNotRequireFullFileSHA256() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }

        let bytes = Data("video-fixture".utf8)
        let seeded = try env.seedAsset(relativePath: "album/video.mov", contents: bytes)
        try env.database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE asset
                SET media_kind = 'video',
                    media_type = 'com.apple.quicktime-movie',
                    duration_ms = 4000
                WHERE id = ?
                """,
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE file_fingerprint SET sha256 = NULL WHERE asset_id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }

        let service = env.makeRecycleService()
        let outcome = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])

        XCTAssertEqual(outcome.recycledEntryIDs.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        let quarantineURL = env.quarantineRoot.appendingPathComponent(
            try XCTUnwrap(entry.quarantineRelativePath)
        )
        XCTAssertEqual(try Data(contentsOf: quarantineURL), bytes)
    }

    func testRestoredHistoricalAssetResolvesToMatchingCurrentSuccessor() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "album/restored.jpg",
            contents: Data("restored-successor".utf8)
        )
        let service = env.makeRecycleService()
        _ = try service.moveAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        try service.restore(entryID: entry.id)
        let successorID = UUID()
        try env.database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE asset
                SET locator_state = 'historical', availability = 'missing'
                WHERE id = ?
                """,
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, content_revision, availability,
                    record_created_at_ms, record_updated_at_ms, file_name
                )
                SELECT
                    ?, source_id, locator_kind, relative_path, photos_local_identifier,
                    'current', media_type, content_revision, 'available',
                    record_created_at_ms, record_updated_at_ms, file_name
                FROM asset
                WHERE id = ?
                """,
                arguments: [
                    successorID.uuidString.lowercased(),
                    seeded.assetID.uuidString.lowercased(),
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO file_fingerprint (
                    asset_id, size_bytes, modified_at_ns, resource_id, sha256
                )
                SELECT ?, size_bytes, modified_at_ns, resource_id, sha256
                FROM file_fingerprint
                WHERE asset_id = ?
                """,
                arguments: [
                    successorID.uuidString.lowercased(),
                    seeded.assetID.uuidString.lowercased(),
                ]
            )
        }

        XCTAssertEqual(
            try service.restoredAssetReplacements(from: [seeded.assetID]),
            [seeded.assetID: successorID]
        )
    }

    func testRestoreConflictKeepsRecycleEntry() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let bytes = Data("conflict".utf8)
        let seeded = try env.seedAsset(relativePath: "only.jpg", contents: bytes)
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)

        // Place a conflict file at the original path.
        try Data("other".utf8).write(to: seeded.fileURL)

        XCTAssertThrowsError(try service.restore(entryID: entry.id)) { error in
            XCTAssertEqual(error as? LibrarySlimmingRecycleError, .restoreConflict)
        }
        XCTAssertEqual(try service.listRecycledEntries().count, 1)
        let quarantineURL = env.quarantineRoot.appendingPathComponent(entry.quarantineRelativePath!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
    }

    func testPurgeFailureKeepsAssetAndRecycleEntryTracked() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "purge/failure.jpg",
            contents: Data("keep-tracked".utf8)
        )
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET quarantine_relative_path = '../unsafe' WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
        }

        XCTAssertThrowsError(try service.purgeNow(entryID: entry.id)) { error in
            XCTAssertEqual(error as? LibrarySlimmingRecycleError, .ioFailure)
        }

        XCTAssertEqual(try service.listRecycledEntries().map(\.id), [entry.id])
        let assetCount = try env.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM asset WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            ) ?? 0
        }
        XCTAssertEqual(assetCount, 1)
    }

    func testSuccessfulPurgeRetainsScrubbedAuditAndKnowledgeTombstone() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "purge/tombstone.jpg",
            contents: Data("tombstone".utf8)
        )
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)

        try service.purgeNow(entryID: entry.id)

        let tombstone = try env.database.pool.read { db -> Row? in
            try Row.fetchOne(
                db,
                sql: """
                SELECT asset_id, state, quarantine_relative_path, original_relative_path
                FROM recycle_entry WHERE id = ?
                """,
                arguments: [entry.id.uuidString.lowercased()]
            )
        }
        let row = try XCTUnwrap(tombstone)
        XCTAssertEqual(row["asset_id"] as String?, seeded.assetID.uuidString.lowercased())
        XCTAssertEqual(row["state"] as String, RecycleEntryState.purged.rawValue)
        XCTAssertNil(row["quarantine_relative_path"] as String?)
        XCTAssertNil(row["original_relative_path"] as String?)
    }

    func testPurgeDeletesPixelCacheButRetainsTagDecisionsAndCatalogKnowledge() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "purge/tagged.jpg",
            contents: Data("tagged".utf8)
        )
        let derivedCacheObjectURL = try env.seedDerivedImageCache(assetID: seeded.assetID)
        let tagID = UUID()
        try env.database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO tag (
                    id, name, normalized_name, state, created_at_ms, updated_at_ms, group_id
                ) VALUES (?, 'Tagged', 'tagged', 'active', ?, ?, ?)
                """,
                arguments: [
                    tagID.uuidString.lowercased(),
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                    TagGroupSeed.other.id.uuidString.lowercased(),
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'accepted', ?)
                """,
                arguments: [
                    seeded.assetID.uuidString.lowercased(),
                    tagID.uuidString.lowercased(),
                    FolderReconcileTestSupport.baseTimeMs,
                ]
            )
        }
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)

        try service.purgeNow(entryID: entry.id)

        let retainedCounts = try env.database.pool.read {
            db -> (asset: Int, decision: Int, fingerprint: Int, pixelCache: Int) in
            let key = seeded.assetID.uuidString.lowercased()
            return (
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM asset WHERE id = ? AND availability = 'recycled'",
                    arguments: [key]
                ) ?? 0,
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM asset_tag_decision WHERE asset_id = ?",
                    arguments: [key]
                ) ?? 0,
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM file_fingerprint WHERE asset_id = ?",
                    arguments: [key]
                ) ?? 0,
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM derived_image_cache_entry WHERE asset_id = ?",
                    arguments: [key]
                ) ?? 0
            )
        }
        XCTAssertEqual(retainedCounts.asset, 1)
        XCTAssertEqual(retainedCounts.decision, 1)
        XCTAssertEqual(retainedCounts.fingerprint, 1)
        XCTAssertEqual(retainedCounts.pixelCache, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: derivedCacheObjectURL.path))
    }

    func testCrossVolumeCopyPathViaForceFlag() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let bytes = Data(repeating: 7, count: 4096)
        let seeded = try env.seedAsset(relativePath: "cross.jpg", contents: bytes)
        var service = env.makeRecycleService()
        let phaseProbe = FolderQuarantinePhaseProbe()
        let moveProgressProbe = RecycleMoveProgressProbe()
        service.quarantineIO.forceCrossVolumeCopy = true
        service.quarantineIO.onPhaseCompleted = { phase, elapsedMs in
            phaseProbe.append(phase, elapsedMs: elapsedMs)
        }

        let outcome = try service.moveAssetsToRecycle(
            assetIDs: [seeded.assetID],
            onProgress: { moveProgressProbe.append($0) }
        )
        XCTAssertEqual(outcome.recycledEntryIDs.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        let quarantineURL = env.quarantineRoot.appendingPathComponent(entry.quarantineRelativePath!)
        XCTAssertEqual(try Data(contentsOf: quarantineURL), bytes)
        XCTAssertFalse(phaseProbe.phases.contains(.sourceInitialHash))
        XCTAssertTrue(phaseProbe.phases.contains(.copy))
        XCTAssertTrue(phaseProbe.phases.contains(.destinationHash))
        XCTAssertTrue(phaseProbe.phases.contains(.sourceFinalVerification))
        XCTAssertTrue(phaseProbe.elapsedMilliseconds.allSatisfy { $0 >= 0 })
        XCTAssertTrue(moveProgressProbe.values.map(\.phase).contains(.preparing))
        XCTAssertTrue(moveProgressProbe.values.map(\.phase).contains(.copying))
        XCTAssertTrue(moveProgressProbe.values.map(\.phase).contains(.verifyingDestination))
        XCTAssertTrue(moveProgressProbe.values.map(\.phase).contains(.verifyingSource))
        XCTAssertEqual(moveProgressProbe.values.last?.phase, .completedAsset)
        XCTAssertEqual(moveProgressProbe.values.last?.copiedBytes, Int64(bytes.count))
        XCTAssertEqual(moveProgressProbe.values.last?.totalFileBytes, Int64(bytes.count))
    }

    func testCrossVolumeCopyRepresentativeTemporaryFixture() throws {
        let fixturePath = ProcessInfo.processInfo.environment[
            "IMAGEALL_RECYCLE_PERF_FIXTURE"
        ].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/tmp/ImageAllRecycleRepresentativeFixture"
        guard FileManager.default.fileExists(atPath: fixturePath) else {
            throw XCTSkip("No disposable performance fixture was supplied")
        }

        let fixtureURL = URL(fileURLWithPath: fixturePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let allowedRoots = [
            FileManager.default.temporaryDirectory,
            URL(fileURLWithPath: "/tmp", isDirectory: true),
        ].map { $0.resolvingSymlinksInPath().standardizedFileURL }
        guard allowedRoots.contains(where: {
            fixtureURL.path.hasPrefix($0.path + "/")
        }) else {
            XCTFail("Performance fixture must be a disposable copy in a temporary directory")
            return
        }

        let values = try fixtureURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize > 0 else {
            XCTFail("Performance fixture must be a non-empty regular file")
            return
        }
        let bytes = try Data(contentsOf: fixtureURL, options: .mappedIfSafe)
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "representative-image.jpg",
            contents: bytes
        )
        var service = env.makeRecycleService()
        let phaseProbe = FolderQuarantinePhaseProbe()
        service.quarantineIO.forceCrossVolumeCopy = true
        service.quarantineIO.onPhaseCompleted = { phase, elapsedMs in
            phaseProbe.append(phase, elapsedMs: elapsedMs)
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let outcome = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let totalMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000

        XCTAssertEqual(outcome.recycledEntryIDs.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        XCTAssertFalse(phaseProbe.phases.contains(.sourceInitialHash))
        let phaseSummary = zip(phaseProbe.phases, phaseProbe.elapsedMilliseconds)
            .map { "\($0.0.rawValue)=\(String(format: "%.3f", $0.1))ms" }
            .joined(separator: ",")
        let performanceSummary = "IMAGEALL_RECYCLE_PERF bytes=\(fileSize) "
            + "total_ms=\(String(format: "%.3f", totalMs)) phases=\(phaseSummary)"
        XCTContext.runActivity(named: performanceSummary) { _ in }
        print(performanceSummary)
    }

    func testCrossVolumeRoundTripPreservesFileMetadata() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "metadata/preserved.jpg",
            contents: Data("metadata".utf8)
        )
        XCTAssertEqual(chmod(seeded.fileURL.path, mode_t(0o640)), 0)
        let attributeName = "com.imageall.recycle-test"
        let attributeValue = Data("finder-metadata".utf8)
        try setExtendedAttribute(
            attributeValue,
            name: attributeName,
            at: seeded.fileURL
        )
        let originalAttributes = try FileManager.default.attributesOfItem(
            atPath: seeded.fileURL.path
        )
        let originalModifiedAt = try XCTUnwrap(
            originalAttributes[.modificationDate] as? Date
        )

        var service = env.makeRecycleService()
        service.quarantineIO.forceCrossVolumeCopy = true
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        let quarantineURL = env.quarantineRoot.appendingPathComponent(
            try XCTUnwrap(entry.quarantineRelativePath)
        )

        let quarantineAttributes = try FileManager.default.attributesOfItem(
            atPath: quarantineURL.path
        )
        XCTAssertEqual(
            (quarantineAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o640
        )
        XCTAssertEqual(
            try extendedAttribute(name: attributeName, at: quarantineURL),
            attributeValue
        )
        XCTAssertEqual(
            try XCTUnwrap(quarantineAttributes[.modificationDate] as? Date)
                .timeIntervalSince1970,
            originalModifiedAt.timeIntervalSince1970,
            accuracy: 0.001
        )

        try service.restore(entryID: entry.id)

        let restoredAttributes = try FileManager.default.attributesOfItem(
            atPath: seeded.fileURL.path
        )
        XCTAssertEqual(
            (restoredAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o640
        )
        XCTAssertEqual(
            try extendedAttribute(name: attributeName, at: seeded.fileURL),
            attributeValue
        )
        XCTAssertEqual(
            try XCTUnwrap(restoredAttributes[.modificationDate] as? Date)
                .timeIntervalSince1970,
            originalModifiedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testRestoreRejectsTamperedQuarantineObject() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let original = Data("trusted-original".utf8)
        let tampered = Data("tampered-content".utf8)
        XCTAssertEqual(original.count, tampered.count)
        let seeded = try env.seedAsset(
            relativePath: "tamper/restore.jpg",
            contents: original
        )
        let service = env.makeRecycleService()
        _ = try service.moveAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        let quarantineURL = env.quarantineRoot.appendingPathComponent(
            try XCTUnwrap(entry.quarantineRelativePath)
        )
        try tampered.write(to: quarantineURL)

        XCTAssertThrowsError(try service.restore(entryID: entry.id)) { error in
            XCTAssertEqual(error as? LibrarySlimmingRecycleError, .ioFailure)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: quarantineURL), tampered)
        XCTAssertEqual(try service.listRecycledEntries().map(\.id), [entry.id])
    }

    func testCrossVolumeCopyFailsClosedWhenSourceChangesDuringCopy() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let original = Data("copy-start".utf8)
        let replacement = Data("changed-during-copy".utf8)
        let seeded = try env.seedAsset(
            relativePath: "concurrent/changed.jpg",
            contents: original
        )
        var service = env.makeRecycleService()
        service.quarantineIO.forceCrossVolumeCopy = true
        service.quarantineIO.beforeSourceFinalVerification = {
            try? replacement.write(to: seeded.fileURL)
        }

        let outcome = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])

        XCTAssertEqual(outcome.failedAssetIDs, [seeded.assetID])
        XCTAssertEqual(outcome.sourceChangedAssetIDs, [seeded.assetID])
        XCTAssertTrue(outcome.recycledEntryIDs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: seeded.fileURL), replacement)
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)
    }

    func testRecycleFailsClosedWhenFileChangedAfterCatalogScan() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let original = Data("catalog-version".utf8)
        let replacement = Data("replacement-version".utf8)
        let seeded = try env.seedAsset(
            relativePath: "identity/changed.jpg",
            contents: original
        )
        try replacement.write(to: seeded.fileURL)
        let service = env.makeRecycleService()

        let outcome = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])

        XCTAssertEqual(outcome.failedAssetIDs, [seeded.assetID])
        XCTAssertTrue(outcome.recycledEntryIDs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: seeded.fileURL), replacement)
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)
    }

    func testRecycleFailsClosedWhenFileIdentityChangesEvenIfBytesMatch() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let bytes = Data("same-bytes-new-file".utf8)
        let seeded = try env.seedAsset(
            relativePath: "identity/replaced.jpg",
            contents: bytes
        )
        let replacementURL = seeded.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("replacement.tmp")
        try bytes.write(to: replacementURL)
        try FileManager.default.removeItem(at: seeded.fileURL)
        try FileManager.default.moveItem(at: replacementURL, to: seeded.fileURL)
        let service = env.makeRecycleService()

        let outcome = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])

        XCTAssertEqual(outcome.failedAssetIDs, [seeded.assetID])
        XCTAssertTrue(outcome.recycledEntryIDs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: seeded.fileURL), bytes)
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)
    }

    func testFailedMutationAuthorizationCanBeRetriedAfterGrant() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "retry/authorization.jpg",
            contents: Data("retry".utf8)
        )
        let denied = env.makeRecycleService(
            mutationAccess: DirectFolderMutationAccess(rootsBySourceID: [:])
        )
        let first = try denied.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        XCTAssertEqual(first.failedAssetIDs, [seeded.assetID])
        XCTAssertEqual(first.authorizationRequiredSourceIDs, [env.sourceID])

        let granted = env.makeRecycleService()
        let second = try granted.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])

        XCTAssertEqual(second.recycledEntryIDs.count, 1)
        XCTAssertTrue(second.failedAssetIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        XCTAssertEqual(try granted.listRecycledEntries().count, 1)
    }

    func testRecycleUsesCurrentSimilaritySHAWhenRescanClearedFileSHA() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let bytes = Data("completed-similarity-fingerprint".utf8)
        let seeded = try env.seedAsset(
            relativePath: "retry/rescan-race.jpg",
            contents: bytes
        )
        try env.database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE file_fingerprint
                SET sha256 = NULL
                WHERE asset_id = ?
                """,
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
            try db.execute(
                sql: """
                INSERT INTO asset_similarity_fingerprint (
                    asset_id, content_revision, algo_version, perceptual_hash,
                    content_sha256, content_digest_origin, created_at_ms, updated_at_ms
                ) VALUES (?, 1, 'fixture-v1', ?, ?, 'verifiedOriginalBytes', ?, ?)
                """,
                arguments: [
                    seeded.assetID.uuidString.lowercased(),
                    Data(repeating: 0x5A, count: 8),
                    Data(SHA256.hash(data: bytes)),
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                ]
            )
        }
        let service = env.makeRecycleService()

        let outcome = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])

        XCTAssertEqual(outcome.recycledEntryIDs.count, 1)
        XCTAssertTrue(outcome.failedAssetIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        XCTAssertEqual(try service.listRecycledEntries().count, 1)
    }

    func testSpaceFirstDeleteRemovesSourceWithoutCreatingQuarantineAndCleansCachesLater()
        throws
    {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "fast/delete.jpg",
            contents: Data("release-source-space".utf8)
        )
        let cachedPreview = try env.seedDerivedImageCache(assetID: seeded.assetID)
        let service = env.makeRecycleService()
        let phaseProbe = FolderQuarantinePhaseProbe()
        var instrumented = service
        instrumented.quarantineIO.onPhaseStarted = {
            phaseProbe.append($0, elapsedMs: 0)
        }

        let outcome = try instrumented.deleteAssetsImmediately(
            assetIDs: [seeded.assetID],
            onProgress: { _ in }
        )

        XCTAssertEqual(outcome.permanentlyDeletedAssetIDs, [seeded.assetID])
        XCTAssertTrue(outcome.recycledEntryIDs.isEmpty)
        XCTAssertTrue(outcome.failedAssetIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.quarantineRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedPreview.path))
        XCTAssertEqual(
            phaseProbe.phases,
            [.sourceFinalVerification, .unlinkSource, .sourceDirectorySync]
        )
        let pendingCleanupState = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM recycle_entry WHERE asset_id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(pendingCleanupState, RecycleEntryState.purging.rawValue)
        XCTAssertTrue(try instrumented.listRecycledEntries().isEmpty)

        XCTAssertEqual(
            try instrumented.purgeExpired(nowMs: FolderReconcileTestSupport.baseTimeMs),
            1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedPreview.path))
        let final = try env.database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT state, original_relative_path FROM recycle_entry WHERE asset_id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(final?["state"] as String?, RecycleEntryState.purged.rawValue)
        XCTAssertNil(final?["original_relative_path"] as String?)
    }

    func testSpaceFirstDeleteRejectsChangedSourceAndKeepsOriginal() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "fast/changed.jpg",
            contents: Data("before".utf8)
        )
        try Data("after-with-different-size".utf8).write(to: seeded.fileURL)
        let service = env.makeRecycleService()

        let outcome = try service.deleteAssetsImmediately(
            assetIDs: [seeded.assetID],
            onProgress: { _ in }
        )

        XCTAssertEqual(outcome.failedAssetIDs, [seeded.assetID])
        XCTAssertEqual(outcome.sourceChangedAssetIDs, [seeded.assetID])
        XCTAssertTrue(outcome.permanentlyDeletedAssetIDs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: seeded.fileURL), Data("after-with-different-size".utf8))
    }

    func testSpaceFirstDeleteSyncFailureRecoversCommittedUnlink() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "fast/sync-recovery.jpg",
            contents: Data("fast-sync-recovery".utf8)
        )
        var service = env.makeRecycleService()
        service.quarantineIO.synchronizeDirectoryFD = { _ in
            throw FolderQuarantineIOError.ioFailure
        }

        let outcome = try service.deleteAssetsImmediately(
            assetIDs: [seeded.assetID],
            onProgress: { _ in }
        )

        XCTAssertTrue(outcome.failedAssetIDs.isEmpty)
        XCTAssertEqual(outcome.durabilityPendingAssetIDs, [seeded.assetID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        let interrupted = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM recycle_entry WHERE asset_id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(interrupted, RecycleEntryState.pending.rawValue)

        service.quarantineIO = FolderQuarantineIO()
        XCTAssertEqual(try service.recoverInterruptedOperations(), 1)
        let recovered = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM recycle_entry WHERE asset_id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(recovered, RecycleEntryState.purged.rawValue)
    }

    func testSpaceFirstDeleteCatalogCommitFailureKeepsDurablePendingIntent() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "fast/catalog-recovery.jpg",
            contents: Data("fast-catalog-recovery".utf8)
        )
        let service = env.makeRecycleService()
        try env.database.pool.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER reject_space_first_completion
                    BEFORE UPDATE OF state ON recycle_entry
                    WHEN NEW.state = 'purging'
                    BEGIN
                        SELECT RAISE(ABORT, 'fixture completion failure');
                    END
                    """
            )
        }

        let outcome = try service.deleteAssetsImmediately(
            assetIDs: [seeded.assetID],
            onProgress: { _ in }
        )

        XCTAssertTrue(outcome.failedAssetIDs.isEmpty)
        XCTAssertEqual(outcome.durabilityPendingAssetIDs, [seeded.assetID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        let pending = try env.database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT state, error_code FROM recycle_entry WHERE asset_id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(pending?["state"] as String?, RecycleEntryState.pending.rawValue)
        XCTAssertEqual(
            pending?["error_code"] as String?,
            "spaceFirstSourceDeletionPending"
        )

        try env.database.pool.write { db in
            try db.execute(sql: "DROP TRIGGER reject_space_first_completion")
        }
        XCTAssertEqual(try service.recoverInterruptedOperations(), 1)
        let recovered = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM recycle_entry WHERE asset_id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(recovered, RecycleEntryState.purged.rawValue)
    }

    func testRecoveryFinalizesMoveInterruptedAfterFilesystemSuccess() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "recovery/pending.jpg",
            contents: Data("pending-recovery".utf8)
        )
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET state = 'pending' WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE asset SET availability = 'available' WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }

        let recovered = try service.recoverInterruptedOperations()

        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(try service.listRecycledEntries().map(\.id), [entry.id])
        let availability = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(availability, AssetAvailability.recycled.rawValue)
    }

    func testCommittedRenameSyncFailureKeepsPendingIntentForRecovery() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let bytes = Data("rename-sync-recovery".utf8)
        let seeded = try env.seedAsset(
            relativePath: "recovery/rename-sync.jpg",
            contents: bytes
        )
        var service = env.makeRecycleService()
        service.quarantineIO.synchronizeDirectoryFD = { _ in
            throw FolderQuarantineIOError.ioFailure
        }

        let outcome = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])

        XCTAssertEqual(outcome.failedAssetIDs, [seeded.assetID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        let pending = try env.database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT state, quarantine_relative_path
                FROM recycle_entry
                WHERE asset_id = ?
                """,
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }
        let pendingRow = try XCTUnwrap(pending)
        XCTAssertEqual(pendingRow["state"] as String, RecycleEntryState.pending.rawValue)
        let quarantineURL = env.quarantineRoot.appendingPathComponent(
            pendingRow["quarantine_relative_path"] as String
        )
        XCTAssertEqual(try Data(contentsOf: quarantineURL), bytes)

        service.quarantineIO = FolderQuarantineIO()
        XCTAssertEqual(try service.recoverInterruptedOperations(), 1)
        XCTAssertEqual(try service.listRecycledEntries().count, 1)
    }

    func testRecoveryTreatsMissingOriginalParentDirectoryAsMissingObject() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "recovery/removed-parent/pending.jpg",
            contents: Data("missing-parent".utf8)
        )
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        try FileManager.default.removeItem(at: seeded.fileURL.deletingLastPathComponent())
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET state = 'pending' WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE asset SET availability = 'available' WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }

        let recovered = try service.recoverInterruptedOperations()

        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(try service.listRecycledEntries().map(\.id), [entry.id])
    }

    func testRecoveryRetainsQuarantineWhenOriginalPathWasRecreated() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let originalBytes = Data("original-before-interruption".utf8)
        let replacementBytes = Data("replacement-after-interruption".utf8)
        let seeded = try env.seedAsset(
            relativePath: "recovery/recreated.jpg",
            contents: originalBytes
        )
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        let quarantineURL = env.quarantineRoot.appendingPathComponent(
            try XCTUnwrap(entry.quarantineRelativePath)
        )
        try replacementBytes.write(to: seeded.fileURL)
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET state = 'pending' WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE asset SET availability = 'available' WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }

        let recovered = try service.recoverInterruptedOperations()

        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(try Data(contentsOf: seeded.fileURL), replacementBytes)
        XCTAssertEqual(try Data(contentsOf: quarantineURL), originalBytes)
        let row = try env.database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT state, error_code FROM recycle_entry WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(row?["state"] as String?, RecycleEntryState.failed.rawValue)
        XCTAssertEqual(row?["error_code"] as String?, "interruptedConflict")
    }

    func testRetryFailedEntryFinalizesRecycleWhenOnlyQuarantineExists() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let bytes = Data("failed-reinspection".utf8)
        let seeded = try env.seedAsset(
            relativePath: "recovery/failed-reinspection.jpg",
            contents: bytes
        )
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        let quarantineURL = env.quarantineRoot.appendingPathComponent(
            try XCTUnwrap(entry.quarantineRelativePath)
        )
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET state = 'failed', error_code = 'ioFailure' WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE asset SET availability = 'available' WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }

        try service.retryInterruptedEntry(entryID: entry.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: quarantineURL), bytes)
        let resolved = try XCTUnwrap(try service.listRecycleBinEntries().first)
        XCTAssertEqual(resolved.id, entry.id)
        XCTAssertEqual(resolved.state, .recycled)
        XCTAssertNil(resolved.errorCode)
        let availability = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(availability, AssetAvailability.recycled.rawValue)
    }

    func testRecoveryFinalizesRestoreInterruptedAfterFilesystemSuccess() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let bytes = Data("restore-recovery".utf8)
        let seeded = try env.seedAsset(
            relativePath: "recovery/restoring.jpg",
            contents: bytes
        )
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET state = 'restoring' WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
        }
        try FolderQuarantineIO().moveOutOfQuarantine(
            quarantineRootURL: env.quarantineRoot,
            quarantineRelativePath: try XCTUnwrap(entry.quarantineRelativePath),
            sourceRootURL: env.sourceRoot,
            originalRelativePath: try XCTUnwrap(entry.originalRelativePath)
        )

        let recovered = try service.recoverInterruptedOperations()

        XCTAssertEqual(recovered, 1)
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)
        XCTAssertEqual(try Data(contentsOf: seeded.fileURL), bytes)
        let availability = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(availability, AssetAvailability.available.rawValue)
    }

    func testRecoveryFinalizesPurgeInterruptedAfterFilesystemSuccess() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "recovery/purging.jpg",
            contents: Data("purge-recovery".utf8)
        )
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET state = 'purging' WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
        }
        try FolderQuarantineIO().deleteQuarantineObject(
            quarantineRootURL: env.quarantineRoot,
            quarantineRelativePath: try XCTUnwrap(entry.quarantineRelativePath)
        )

        let recovered = try service.recoverInterruptedOperations()

        XCTAssertEqual(recovered, 1)
        let tombstone = try env.database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT asset_id, state, quarantine_relative_path, original_relative_path
                FROM recycle_entry WHERE id = ?
                """,
                arguments: [entry.id.uuidString.lowercased()]
            )
        }
        let row = try XCTUnwrap(tombstone)
        XCTAssertEqual(row["asset_id"] as String?, seeded.assetID.uuidString.lowercased())
        XCTAssertEqual(row["state"] as String, RecycleEntryState.purged.rawValue)
        XCTAssertNil(row["quarantine_relative_path"] as String?)
        XCTAssertNil(row["original_relative_path"] as String?)
        let assetCount = try env.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM asset WHERE id = ?",
                arguments: [seeded.assetID.uuidString.lowercased()]
            ) ?? 0
        }
        XCTAssertEqual(assetCount, 1)
    }

    func testCommittedPurgeSyncFailureKeepsPurgingIntentForRecovery() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(
            relativePath: "recovery/purge-sync.jpg",
            contents: Data("purge-sync-recovery".utf8)
        )
        var service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        let quarantineURL = env.quarantineRoot.appendingPathComponent(
            try XCTUnwrap(entry.quarantineRelativePath)
        )
        service.quarantineIO.synchronizeDirectoryFD = { _ in
            throw FolderQuarantineIOError.ioFailure
        }

        XCTAssertThrowsError(try service.purgeNow(entryID: entry.id)) { error in
            XCTAssertEqual(error as? LibrarySlimmingRecycleError, .ioFailure)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantineURL.path))
        let interruptedState = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM recycle_entry WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(interruptedState, RecycleEntryState.purging.rawValue)

        service.quarantineIO = FolderQuarantineIO()
        XCTAssertEqual(try service.recoverInterruptedOperations(), 1)
        let finalState = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM recycle_entry WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(finalState, RecycleEntryState.purged.rawValue)
    }

    func testPhotosAssetIsSkipped() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset()
        let service = env.makeRecycleService()
        let outcome = try service.moveAssetsToRecycle(assetIDs: [photosID])
        XCTAssertTrue(outcome.recycledEntryIDs.isEmpty)
        XCTAssertEqual(outcome.authorizationDeniedPhotosAssetIDs, [photosID])
    }

    func testPhotosSoftDeleteWritesRecycleEntryWithoutQuarantine() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "local-photos-1")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["local-photos-1"] = .available
        let service = env.makeRecycleService(photosMutation: fake)
        let outcome = try service.moveAssetsToRecycle(assetIDs: [photosID])
        XCTAssertEqual(outcome.recycledEntryIDs.count, 1)
        XCTAssertEqual(fake.movedToRecentlyDeleted, ["local-photos-1"])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        XCTAssertEqual(entry.sourceKind, .photos)
        XCTAssertEqual(entry.photosLocalIdentifier, "local-photos-1")
        XCTAssertNil(entry.quarantineRelativePath)
        let quarantineChildren = try FileManager.default.contentsOfDirectory(
            at: env.quarantineRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(quarantineChildren.isEmpty)
        let availability = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [photosID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(availability, "recycled")
    }

    func testPhotosSoftDeleteBatchesMultipleAssetsIntoOneSystemMutationRequest() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let firstID = try env.seedPhotosAsset(localIdentifier: "batch-photos-1")
        let secondID = try env.seedPhotosAsset(localIdentifier: "batch-photos-2")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["batch-photos-1"] = .available
        fake.presenceByID["batch-photos-2"] = .available
        let service = env.makeRecycleService(photosMutation: fake)

        let outcome = try service.moveAssetsToRecycle(assetIDs: [firstID, secondID])

        XCTAssertEqual(outcome.recycledEntryIDs.count, 2)
        XCTAssertEqual(
            fake.moveRequestBatches,
            [["batch-photos-1", "batch-photos-2"]]
        )
    }

    func testPhotosSoftDeleteDoesNotMarkAllRecycledWhenAdapterReportsPartialMutation() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let firstID = try env.seedPhotosAsset(localIdentifier: "partial-photos-1")
        let secondID = try env.seedPhotosAsset(localIdentifier: "partial-photos-2")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["partial-photos-1"] = .available
        fake.presenceByID["partial-photos-2"] = .available
        fake.reportedMovedIdentifiers = ["partial-photos-1"]
        let service = env.makeRecycleService(photosMutation: fake)

        let outcome = try service.moveAssetsToRecycle(assetIDs: [firstID, secondID])

        XCTAssertTrue(outcome.recycledEntryIDs.isEmpty)
        XCTAssertEqual(Set(outcome.failedAssetIDs), Set([firstID, secondID]))
        XCTAssertEqual(Set(outcome.photosMutationFailedAssetIDs), Set([firstID, secondID]))
        XCTAssertTrue(outcome.mutationAuthorizationInvalidAssetIDs.isEmpty)
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)
    }

    func testPhotosSystemMutationFailurePersistsSafeDiagnostic() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "diagnostic-photo")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["diagnostic-photo"] = .available
        let diagnostic = PhotosLibraryMutationFailureDiagnostic(
            category: .libraryUnavailable,
            domain: "PHPhotosErrorDomain",
            code: 3114
        )
        fake.moveError = .systemChangeFailed(diagnostic)
        let service = env.makeRecycleService(photosMutation: fake)

        let outcome = try service.moveAssetsToRecycle(assetIDs: [photosID])

        XCTAssertEqual(outcome.failedAssetIDs, [photosID])
        XCTAssertEqual(outcome.photosMutationFailedAssetIDs, [photosID])
        XCTAssertEqual(outcome.photosMutationFailureCategories, [.libraryUnavailable])
        XCTAssertEqual(outcome.photosMutationFailureCodes, ["PHPhotosErrorDomain#3114"])
        let persistedCode = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT error_code FROM recycle_entry WHERE asset_id = ?",
                arguments: [photosID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(
            persistedCode,
            "photosMutationFailed.libraryUnavailable.PHPhotosErrorDomain.3114"
        )
    }

    func testPhotosAssetNotFoundIsReportedAsSourceChanged() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "stale-photo")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["stale-photo"] = .available
        fake.moveError = .assetNotFound
        let service = env.makeRecycleService(photosMutation: fake)

        let outcome = try service.moveAssetsToRecycle(assetIDs: [photosID])

        XCTAssertEqual(outcome.failedAssetIDs, [photosID])
        XCTAssertEqual(outcome.sourceChangedAssetIDs, [photosID])
        XCTAssertTrue(outcome.photosMutationFailedAssetIDs.isEmpty)
        let persistedCode = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT error_code FROM recycle_entry WHERE asset_id = ?",
                arguments: [photosID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(persistedCode, "photosAssetNotFound")
    }

    func testRecycleRejectsHistoricalPhotosLocatorBeforePhotoKitMutation() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "historical-photo")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["historical-photo"] = .available
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE asset SET locator_state = 'historical' WHERE id = ?",
                arguments: [photosID.uuidString.lowercased()]
            )
        }

        let outcome = try env.makeRecycleService(photosMutation: fake)
            .moveAssetsToRecycle(assetIDs: [photosID])

        XCTAssertEqual(outcome.failedAssetIDs, [photosID])
        XCTAssertTrue(fake.moveRequestBatches.isEmpty)
    }

    func testPhotosAuthorizationDeniedDoesNotMutate() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "denied-id")
        let fake = FakePhotosLibraryMutationPort()
        fake.authorization = .denied
        let service = env.makeRecycleService(photosMutation: fake)
        let outcome = try service.moveAssetsToRecycle(assetIDs: [photosID])
        XCTAssertTrue(outcome.recycledEntryIDs.isEmpty)
        XCTAssertEqual(outcome.authorizationDeniedPhotosAssetIDs, [photosID])
        XCTAssertTrue(outcome.photosMutationFailedAssetIDs.isEmpty)
        XCTAssertTrue(fake.movedToRecentlyDeleted.isEmpty)
    }

    func testPhotosAuthorizationNotDeterminedDoesNotMutate() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "not-determined-id")
        let fake = FakePhotosLibraryMutationPort()
        fake.authorization = .notDetermined
        let service = env.makeRecycleService(photosMutation: fake)
        let outcome = try service.moveAssetsToRecycle(assetIDs: [photosID])
        XCTAssertTrue(outcome.recycledEntryIDs.isEmpty)
        XCTAssertEqual(outcome.authorizationDeniedPhotosAssetIDs, [photosID])
        XCTAssertTrue(outcome.photosMutationFailedAssetIDs.isEmpty)
        XCTAssertTrue(fake.movedToRecentlyDeleted.isEmpty)
    }

    func testPhotosPendingRecoveryFinalizesWhenSystemAssetIsNoLongerAvailable() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "pending-id")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["pending-id"] = .available
        let service = env.makeRecycleService(photosMutation: fake)
        _ = try service.moveAssetsToRecycle(assetIDs: [photosID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET state = 'pending' WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE asset SET availability = 'available' WHERE id = ?",
                arguments: [photosID.uuidString.lowercased()]
            )
        }

        let recovered = try service.recoverInterruptedOperations()

        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(try service.listRecycledEntries().map(\.id), [entry.id])
        XCTAssertEqual(fake.movedToRecentlyDeleted, ["pending-id"])
        let availability = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [photosID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(availability, AssetAvailability.recycled.rawValue)
    }

    func testSpaceFirstModeStillUsesSystemRecentlyDeletedForPhotos() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "space-first-photos")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["space-first-photos"] = .available
        let service = env.makeRecycleService(photosMutation: fake)

        let outcome = try service.deleteAssetsImmediately(
            assetIDs: [photosID],
            onProgress: { _ in }
        )

        XCTAssertEqual(outcome.recycledEntryIDs.count, 1)
        XCTAssertTrue(outcome.permanentlyDeletedAssetIDs.isEmpty)
        XCTAssertEqual(fake.movedToRecentlyDeleted, ["space-first-photos"])
        XCTAssertEqual(try service.listRecycledEntries().first?.sourceKind, .photos)
    }

    func testPhotosPendingRecoveryKeepsAmbiguousAvailableAssetDuringConvergenceGrace() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "pending-grace-id")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["pending-grace-id"] = .available
        let service = env.makeRecycleService(photosMutation: fake)
        _ = try service.moveAssetsToRecycle(assetIDs: [photosID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET state = 'pending' WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
            try db.execute(
                sql: "UPDATE asset SET availability = 'available' WHERE id = ?",
                arguments: [photosID.uuidString.lowercased()]
            )
        }
        fake.presenceByID["pending-grace-id"] = .available

        let recovered = try service.recoverInterruptedOperations()

        XCTAssertEqual(recovered, 0)
        let state = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM recycle_entry WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(state, RecycleEntryState.pending.rawValue)
    }

    func testPhotosReconcileMarksRestoredWhenAvailableAgain() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "restore-id")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["restore-id"] = .available
        let service = env.makeRecycleService(photosMutation: fake)
        _ = try service.moveAssetsToRecycle(assetIDs: [photosID])
        XCTAssertEqual(fake.presenceByID["restore-id"], .recentlyDeleted)
        fake.presenceByID["restore-id"] = .available
        let advancedClock = FixedJobClock(
            nowMs: FolderReconcileTestSupport.baseTimeMs
                + LibrarySlimmingRecyclePolicy.photosDeleteConvergenceGraceMs
                + 1
        )
        let advancedService = env.makeRecycleService(
            clock: advancedClock,
            photosMutation: fake
        )
        let converged = try advancedService.reconcilePhotosRecycleEntries()
        XCTAssertEqual(converged, 1)
        XCTAssertTrue(try advancedService.listRecycledEntries().isEmpty)
        let availability = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [photosID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(availability, "available")
    }

    func testPhotosReconcileDoesNotRestoreDuringDeleteConvergenceGrace() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "converging-id")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["converging-id"] = .available
        let service = env.makeRecycleService(photosMutation: fake)
        _ = try service.moveAssetsToRecycle(assetIDs: [photosID])
        fake.presenceByID["converging-id"] = .available

        let converged = try service.reconcilePhotosRecycleEntries()

        XCTAssertEqual(converged, 0)
        XCTAssertEqual(try service.listRecycledEntries().map(\.assetID), [photosID])
        let availability = try env.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT availability FROM asset WHERE id = ?",
                arguments: [photosID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(availability, AssetAvailability.recycled.rawValue)
    }

    func testPhotosReconcileLoadsAllPresenceFactsInOneBatch() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let firstID = try env.seedPhotosAsset(localIdentifier: "batch-presence-1")
        let secondID = try env.seedPhotosAsset(localIdentifier: "batch-presence-2")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["batch-presence-1"] = .available
        fake.presenceByID["batch-presence-2"] = .available
        let service = env.makeRecycleService(photosMutation: fake)
        _ = try service.moveAssetsToRecycle(assetIDs: [firstID, secondID])
        fake.presenceByID["batch-presence-1"] = .available
        fake.presenceByID["batch-presence-2"] = .available
        let advancedClock = FixedJobClock(
            nowMs: FolderReconcileTestSupport.baseTimeMs
                + LibrarySlimmingRecyclePolicy.photosDeleteConvergenceGraceMs
                + 1
        )
        let advancedService = env.makeRecycleService(
            clock: advancedClock,
            photosMutation: fake
        )

        let converged = try advancedService.reconcilePhotosRecycleEntries()

        XCTAssertEqual(converged, 2)
        XCTAssertEqual(
            fake.presenceRequestBatches.map(Set.init),
            [Set(["batch-presence-1", "batch-presence-2"])]
        )
    }

    func testSlimmingHiddenAssetIDsIncludesRecycledAssets() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(relativePath: "hidden.jpg", contents: Data("x".utf8))
        let service = env.makeRecycleService()
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])

        let hidden = try service.slimmingHiddenAssetIDs(from: [seeded.assetID, UUID()])

        XCTAssertEqual(hidden, Set([seeded.assetID]))
    }

    func testPhotosRestoreWhileRecentlyDeletedRequiresPhotosApp() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "still-deleted")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["still-deleted"] = .available
        let service = env.makeRecycleService(photosMutation: fake)
        _ = try service.moveAssetsToRecycle(assetIDs: [photosID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        XCTAssertThrowsError(try service.restore(entryID: entry.id)) { error in
            XCTAssertEqual(
                error as? LibrarySlimmingRecycleError,
                .photosRestoreRequiresPhotosApp
            )
        }
        XCTAssertEqual(try service.listRecycledEntries().count, 1)
    }

    func testPhotosPurgeIsManagedBySystemPhotos() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "purge-id")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["purge-id"] = .available
        let service = env.makeRecycleService(photosMutation: fake)
        _ = try service.moveAssetsToRecycle(assetIDs: [photosID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        XCTAssertThrowsError(try service.purgeNow(entryID: entry.id)) { error in
            XCTAssertEqual(
                error as? LibrarySlimmingRecycleError,
                .photosManagedBySystem
            )
        }
        XCTAssertEqual(try service.listRecycledEntries().map(\.id), [entry.id])
        let assetCount = try env.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM asset WHERE id = ?",
                arguments: [photosID.uuidString.lowercased()]
            ) ?? 0
        }
        XCTAssertEqual(assetCount, 1)
    }

    func testPhotosInterruptedPurgeReturnsToRecycleBinWithoutSystemMutation() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let photosID = try env.seedPhotosAsset(localIdentifier: "interrupted-purge-id")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["interrupted-purge-id"] = .available
        let service = env.makeRecycleService(photosMutation: fake)
        _ = try service.moveAssetsToRecycle(assetIDs: [photosID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        try env.database.pool.write { db in
            try db.execute(
                sql: "UPDATE recycle_entry SET state = 'purging' WHERE id = ?",
                arguments: [entry.id.uuidString.lowercased()]
            )
        }

        let recovered = try service.recoverInterruptedOperations()

        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(try service.listRecycledEntries().map(\.id), [entry.id])
        XCTAssertEqual(fake.movedToRecentlyDeleted, ["interrupted-purge-id"])
    }

    func testPhotosReconcilePurgesMissingAfterExpiry() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let clock = FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        let photosID = try env.seedPhotosAsset(localIdentifier: "missing-id")
        let fake = FakePhotosLibraryMutationPort()
        fake.presenceByID["missing-id"] = .available
        let service = env.makeRecycleService(clock: clock, photosMutation: fake)
        let cachedOriginalURL = try env.seedPhotosOriginalCache(
            assetID: photosID,
            localIdentifier: "missing-id",
            clock: clock
        )
        _ = try service.moveAssetsToRecycle(assetIDs: [photosID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)
        try env.database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET trashed_at_ms = ?, purge_after_ms = ?
                WHERE id = ?
                """,
                arguments: [clock.nowMs - 2, clock.nowMs - 1, entry.id.uuidString.lowercased()]
            )
        }
        fake.presenceByID["missing-id"] = .missing
        let converged = try service.reconcilePhotosRecycleEntries()
        XCTAssertEqual(converged, 1)
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedOriginalURL.path))
        let retained = try env.database.pool.read { db -> (asset: Int, pixelCache: Int) in
            let key = photosID.uuidString.lowercased()
            return (
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM asset WHERE id = ? AND availability = 'recycled'",
                    arguments: [key]
                ) ?? 0,
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM photos_original_cache_entry WHERE asset_id = ?",
                    arguments: [key]
                ) ?? 0
            )
        }
        XCTAssertEqual(retained.asset, 1)
        XCTAssertEqual(retained.pixelCache, 0)
    }

    func testPurgeExpiredRemovesDueEntries() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let seeded = try env.seedAsset(relativePath: "due.jpg", contents: Data("x".utf8))
        let clock = FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        let service = env.makeRecycleService(clock: clock)
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)

        // Force expiry without violating purge_after_ms >= trashed_at_ms.
        try env.database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE recycle_entry
                SET trashed_at_ms = ?, purge_after_ms = ?
                WHERE id = ?
                """,
                arguments: [clock.nowMs - 2, clock.nowMs - 1, entry.id.uuidString.lowercased()]
            )
        }
        let purged = try service.purgeExpired(nowMs: clock.nowMs)
        XCTAssertEqual(purged, 1)
        XCTAssertTrue(try service.listRecycledEntries().isEmpty)
    }

    func testPurgeJobIsScheduledForEarliestRecycleExpiry() throws {
        let env = try RecycleTestEnv(label: #function)
        defer { env.cleanup() }
        let clock = FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs)
        let queue = GRDBJobQueue(
            database: env.database,
            clock: clock,
            retryPolicy: FixedDelayRetryPolicy(delayMs: 1_000)
        )
        let seeded = try env.seedAsset(
            relativePath: "schedule/expiry.jpg",
            contents: Data("scheduled".utf8)
        )
        let service = env.makeRecycleService(clock: clock, jobQueue: queue)
        _ = try service.moveFolderAssetsToRecycle(assetIDs: [seeded.assetID])
        let entry = try XCTUnwrap(try service.listRecycledEntries().first)

        try service.enqueuePurgeExpired()

        let scheduledAt = try env.database.pool.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT not_before_ms FROM job WHERE kind = ?",
                arguments: [LibrarySlimmingPurgeJobFactory.kind]
            )
        }
        XCTAssertEqual(scheduledAt, entry.purgeAfterMs)
    }
}

private final class RecycleMoveProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [LibrarySlimmingRecycleMoveProgress] = []

    var values: [LibrarySlimmingRecycleMoveProgress] {
        lock.withLock { storedValues }
    }

    func append(_ progress: LibrarySlimmingRecycleMoveProgress) {
        lock.withLock {
            storedValues.append(progress)
        }
    }
}

private final class FolderQuarantinePhaseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPhases: [FolderQuarantineIOPhase] = []
    private var storedElapsedMilliseconds: [Double] = []

    var phases: [FolderQuarantineIOPhase] {
        lock.withLock { storedPhases }
    }

    var elapsedMilliseconds: [Double] {
        lock.withLock { storedElapsedMilliseconds }
    }

    func append(_ phase: FolderQuarantineIOPhase, elapsedMs: Double) {
        lock.withLock {
            storedPhases.append(phase)
            storedElapsedMilliseconds.append(elapsedMs)
        }
    }
}

private final class RecordingMutationBookmarkPort: SecurityScopedBookmarkPort, @unchecked Sendable {
    let resolvedURL: URL
    let writableBookmark: Data
    private(set) var resolveCount = 0
    private(set) var writableCreationCount = 0

    init(
        resolvedURL: URL,
        writableBookmark: Data = Data("writable".utf8)
    ) {
        self.resolvedURL = resolvedURL
        self.writableBookmark = writableBookmark
    }

    func createReadOnlyBookmark(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func createWritableBookmark(for url: URL) throws -> Data {
        writableCreationCount += 1
        return writableBookmark
    }

    func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolveResult {
        resolveCount += 1
        return BookmarkResolveResult(url: resolvedURL, isStale: false)
    }

    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}

private struct FailingMutationBookmarkPort: SecurityScopedBookmarkPort {
    func createReadOnlyBookmark(for url: URL) throws -> Data {
        Data(url.path.utf8)
    }

    func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolveResult {
        throw FolderAuthorizationError.authorizationUnavailable
    }

    func startAccessing(_ url: URL) -> Bool { false }
    func stopAccessing(_ url: URL) {}
}

private struct InvalidFolderMutationAccess: FolderMutationAccessing {
    func withWritableSourceRoot<T>(
        sourceID _: UUID,
        perform _: (URL) throws -> T
    ) throws -> T {
        throw LibrarySlimmingRecycleError.mutationAuthorizationInvalid
    }
}

private final class RecycleTestEnv {
    let root: URL
    let sourceRoot: URL
    let quarantineRoot: URL
    let derivedCachesDirectory: URL
    let photosOriginalRoot: URL
    let database: CatalogDatabase
    let sourceID: UUID
    private var didInsertSource = false

    struct SeededAsset {
        let assetID: UUID
        let fileURL: URL
    }

    init(label: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageAllRecycle-\(label)-\(UUID().uuidString)", isDirectory: true)
        sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let support = root.appendingPathComponent("Application Support/ImageAll", isDirectory: true)
        quarantineRoot = QuarantinePathLayout.rootURL(applicationSupportDirectory: support)
        derivedCachesDirectory = root.appendingPathComponent("Caches/ImageAll", isDirectory: true)
        photosOriginalRoot = support.appendingPathComponent("Photos Originals/v1", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        database = try CatalogDatabase.open(at: root.appendingPathComponent("catalog.sqlite"))
        sourceID = UUID()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeRecycleService(
        clock: any JobClock = FixedJobClock(nowMs: FolderReconcileTestSupport.baseTimeMs),
        mutationAccess: (any FolderMutationAccessing)? = nil,
        jobQueue: (any JobQueue)? = nil,
        photosMutation: (any PhotosLibraryMutationPort)? = nil
    ) -> LibrarySlimmingRecycleService {
        LibrarySlimmingRecycleService(
            database: database,
            mutationAccess: mutationAccess
                ?? DirectFolderMutationAccess(rootsBySourceID: [sourceID: sourceRoot]),
            quarantineRootURL: quarantineRoot,
            clock: clock,
            jobQueue: jobQueue,
            photosMutation: photosMutation,
            pixelCachePurger: AppOwnedAssetPixelCachePurger(
                database: database,
                derivedCachesDirectory: derivedCachesDirectory,
                photosOriginalCache: PhotosOriginalCacheService(
                    database: database,
                    rootURL: photosOriginalRoot,
                    clock: clock
                )
            )
        )
    }

    func seedDerivedImageCache(assetID: UUID) throws -> URL {
        let entryID = UUID()
        let bytes = Data("derived-pixel-bytes".utf8)
        let store = DerivedImageCacheStore(cachesDirectory: derivedCachesDirectory)
        _ = try store.ensureLayout()
        let objectURL = DerivedImageCachePathLayout.objectURL(
            versionRoot: store.versionRoot,
            entryID: entryID,
            format: .jpeg
        )
        try FileManager.default.createDirectory(
            at: objectURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: objectURL)
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO derived_image_cache_entry (
                    id, asset_id, content_revision, representation_version,
                    variant, storage_format, pixel_width, pixel_height,
                    byte_size, encoded_sha256, created_at_ms, last_accessed_at_ms
                ) VALUES (?, ?, 1, 1, 'gridSmall', 'jpeg', 256, 256, ?, ?, ?, ?)
                """,
                arguments: [
                    entryID.uuidString.lowercased(),
                    assetID.uuidString.lowercased(),
                    Int64(bytes.count),
                    Data(SHA256.hash(data: bytes)),
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                ]
            )
        }
        return objectURL
    }

    func seedPhotosOriginalCache(
        assetID: UUID,
        localIdentifier: String,
        clock: any JobClock
    ) throws -> URL {
        let cache = PhotosOriginalCacheService(
            database: database,
            rootURL: photosOriginalRoot,
            clock: clock
        )
        _ = try cache.store(
            assetID: assetID,
            contentRevision: 1,
            localIdentifier: localIdentifier,
            mediaType: "public.jpeg",
            sourceBytes: Data("photos-original-pixels".utf8)
        )
        let objectName = try database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT object_name FROM photos_original_cache_entry WHERE asset_id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }
        return photosOriginalRoot.appendingPathComponent(try XCTUnwrap(objectName))
    }

    @discardableResult
    func seedAsset(relativePath: String, contents: Data) throws -> SeededAsset {
        let assetID = UUID()
        let fileURL = sourceRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL)
        let fileName = RelativePathRules.fileName(from: relativePath) ?? fileURL.lastPathComponent
        try database.pool.write { db in
            if !didInsertSource {
                try db.execute(
                    sql: """
                    INSERT INTO source (
                        id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                        state, created_at_ms, updated_at_ms
                    ) VALUES (?, 'folder', 'Fixture', ?, 0, 0, 'active', ?, ?)
                    """,
                    arguments: [
                        sourceID.uuidString.lowercased(),
                        Data("bookmark".utf8),
                        FolderReconcileTestSupport.baseTimeMs,
                        FolderReconcileTestSupport.baseTimeMs,
                    ]
                )
                didInsertSource = true
            }
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, content_revision, availability,
                    record_created_at_ms, record_updated_at_ms, file_name
                ) VALUES (?, ?, 'file', ?, NULL, 'current', 'public.jpeg', 1, 'available', ?, ?, ?)
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    sourceID.uuidString.lowercased(),
                    relativePath,
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                    fileName,
                ]
            )
            let resources = FoundationFolderFileResourceReader()
            guard let sizeBytes = resources.fileSizeBytes(for: fileURL),
                  let modifiedAtNs = resources.modifiedAtNs(for: fileURL)
            else {
                throw LibrarySlimmingRecycleError.ioFailure
            }
            try db.execute(
                sql: """
                INSERT INTO file_fingerprint (
                    asset_id, size_bytes, modified_at_ns, resource_id, sha256
                ) VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    sizeBytes,
                    modifiedAtNs,
                    resources.resourceIdentifier(for: fileURL),
                    Data(SHA256.hash(data: contents)),
                ]
            )
        }
        return SeededAsset(assetID: assetID, fileURL: fileURL)
    }

    func seedPhotosAsset(localIdentifier: String = "local-id") throws -> UUID {
        let photosSourceID = UUID()
        let assetID = UUID()
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (
                    id, kind, display_name, bookmark, scan_generation, dirty_epoch,
                    state, created_at_ms, updated_at_ms
                ) VALUES (?, 'photos', 'Photos', NULL, 0, 0, 'active', ?, ?)
                """,
                arguments: [
                    photosSourceID.uuidString.lowercased(),
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, content_revision, availability,
                    record_created_at_ms, record_updated_at_ms, file_name
                ) VALUES (?, ?, 'photos', NULL, ?, 'current', 'public.jpeg', 1, 'available', ?, ?, NULL)
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    photosSourceID.uuidString.lowercased(),
                    localIdentifier,
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                ]
            )
        }
        return assetID
    }

    func seedVerifiedSimilarityFingerprint(assetID: UUID, sha256: Data) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset_similarity_fingerprint (
                    asset_id, content_revision, algo_version, perceptual_hash,
                    created_at_ms, updated_at_ms, content_sha256,
                    content_digest_origin
                ) VALUES (?, 1, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET
                    content_revision = excluded.content_revision,
                    algo_version = excluded.algo_version,
                    perceptual_hash = excluded.perceptual_hash,
                    updated_at_ms = excluded.updated_at_ms,
                    content_sha256 = excluded.content_sha256,
                    content_digest_origin = excluded.content_digest_origin
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    IdenticalDuplicatePolicy.perceptualAlgoVersion,
                    Data(repeating: 0, count: 8),
                    FolderReconcileTestSupport.baseTimeMs,
                    FolderReconcileTestSupport.baseTimeMs,
                    sha256,
                    AssetContentDigestOrigin.verifiedOriginalBytes.rawValue,
                ]
            )
        }
    }
}

private final class FakePhotosLibraryMutationPort: PhotosLibraryMutationPort, @unchecked Sendable {
    var authorization: PhotosAuthorizationState = .authorized
    var presenceByID: [String: PhotosAssetPresence] = [:]
    private(set) var movedToRecentlyDeleted: [String] = []
    private(set) var moveRequestBatches: [[String]] = []
    private(set) var presenceRequestBatches: [[String]] = []
    var reportedMovedIdentifiers: [String]?
    var moveError: PhotosLibraryMutationError?

    func authorizationState() -> PhotosAuthorizationState {
        authorization
    }

    func requestAuthorization() async -> PhotosAuthorizationState {
        authorization
    }

    func moveToRecentlyDeleted(localIdentifiers: [String]) throws -> [String] {
        guard authorization == .authorized else {
            throw PhotosLibraryMutationError.authorizationDenied
        }
        moveRequestBatches.append(localIdentifiers)
        if let moveError {
            throw moveError
        }
        for id in localIdentifiers {
            guard presenceByID[id] == .available else {
                throw PhotosLibraryMutationError.assetNotFound
            }
            movedToRecentlyDeleted.append(id)
            presenceByID[id] = .recentlyDeleted
        }
        return reportedMovedIdentifiers ?? localIdentifiers
    }

    func presence(localIdentifier: String) throws -> PhotosAssetPresence {
        guard authorization == .authorized else {
            throw PhotosLibraryMutationError.authorizationDenied
        }
        return presenceByID[localIdentifier] ?? .missing
    }

    func presences(localIdentifiers: [String]) throws -> [String: PhotosAssetPresence] {
        guard authorization == .authorized else {
            throw PhotosLibraryMutationError.authorizationDenied
        }
        presenceRequestBatches.append(localIdentifiers)
        return Dictionary(
            uniqueKeysWithValues: localIdentifiers.map {
                ($0, presenceByID[$0] ?? .missing)
            }
        )
    }

}

private func setExtendedAttribute(_ data: Data, name: String, at url: URL) throws {
    let result = url.path.withCString { path in
        name.withCString { attributeName in
            data.withUnsafeBytes { bytes in
                setxattr(
                    path,
                    attributeName,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
        }
    }
    guard result == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private func extendedAttribute(name: String, at url: URL) throws -> Data {
    let size = url.path.withCString { path in
        name.withCString { attributeName in
            getxattr(path, attributeName, nil, 0, 0, 0)
        }
    }
    guard size >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    var data = Data(count: size)
    let readCount = data.withUnsafeMutableBytes { bytes in
        url.path.withCString { path in
            name.withCString { attributeName in
                getxattr(
                    path,
                    attributeName,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    0
                )
            }
        }
    }
    guard readCount == size else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return data
}
