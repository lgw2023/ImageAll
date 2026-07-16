import CryptoKit
import GRDB
import XCTest
@testable import ImageAll

final class FullLibrarySuggestionsJobTests: XCTestCase {
    func testScansMoreThanFiveHundredAssetsInSingleRevisionWithoutDuplicateCursor() throws {
        let fixture = try makeLargeLibraryFixture(assetCount: 520)
        let handler = makeHandler(database: fixture.database, loader: fixture.loader, queue: fixture.queue)
        let coordinator = makeCoordinator(database: fixture.database, handler: handler, queue: fixture.queue)
        _ = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs,
            database: fixture.database
        )
        drainPersonalizationJobs(coordinator: coordinator, maxSteps: 20)
        let facts = try revisionFacts(database: fixture.database, tagID: fixture.tagID)
        XCTAssertEqual(facts.revisionCount, 1)
        XCTAssertEqual(facts.predictionCount, facts.positiveCandidateCount)
        XCTAssertGreaterThan(facts.predictionCount, 0)
        XCTAssertEqual(facts.checkedCount, 520)
    }

    func testFirstBatchTransactionFailureRollsBackAndKeepsOldQueue() throws {
        let fixture = try makeLargeLibraryFixture(assetCount: 8, preseedPredictions: 3)
        var dependencies = makeHandlerDependencies(
            database: fixture.database,
            loader: fixture.loader,
            queue: fixture.queue
        )
        dependencies.publishFailureInjector = { throw PersonalizationCatalogError.persistenceFailure }
        let handler = FullLibrarySuggestionsHandler(dependencies: dependencies)
        let coordinator = makeCoordinator(database: fixture.database, handler: handler, queue: fixture.queue)
        _ = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs,
            database: fixture.database
        )
        _ = try coordinator.claimAndExecuteOnce(personalizationClaim())
        let facts = try revisionFacts(database: fixture.database, tagID: fixture.tagID)
        XCTAssertEqual(facts.revisionCount, 1)
        XCTAssertEqual(facts.currentRevision, 1)
        XCTAssertEqual(facts.predictionCount, 3)
    }

    func testPauseSurvivesRestartAndResumeContinues() throws {
        let fixture = try makeLargeLibraryFixture(assetCount: 250)
        let handler = makeHandler(database: fixture.database, loader: fixture.loader, queue: fixture.queue)
        let coordinator = makeCoordinator(database: fixture.database, handler: handler, queue: fixture.queue)
        let job = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs,
            database: fixture.database
        )
        _ = try fixture.queue.applyStateCommand(JobStateCommand(jobID: job.id, operation: .pause))
        let paused = try fixture.queue.fetchJob(id: job.id)
        XCTAssertEqual(paused.state, .paused)
        _ = try fixture.queue.applyStateCommand(
            JobStateCommand(jobID: job.id, operation: .resume(notBeforeMs: DatabaseTestSupport.timestampMs))
        )
        drainPersonalizationJobs(coordinator: coordinator, maxSteps: 2)
        let facts = try revisionFacts(database: fixture.database, tagID: fixture.tagID)
        XCTAssertEqual(facts.revisionCount, 1)
        XCTAssertEqual(facts.checkedCount, 250)
    }

    func testCancelRetainsPublishedSuggestions() throws {
        let fixture = try makeLargeLibraryFixture(assetCount: 60)
        let handler = makeHandler(database: fixture.database, loader: fixture.loader, queue: fixture.queue)
        let coordinator = makeCoordinator(database: fixture.database, handler: handler, queue: fixture.queue)
        _ = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs,
            database: fixture.database
        )
        drainPersonalizationJobs(coordinator: coordinator, maxSteps: 2)
        let retainedCount = try pendingCount(database: fixture.database, tagID: fixture.tagID)
        XCTAssertGreaterThan(retainedCount, 0)
        let updateJob = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs + 1,
            database: fixture.database
        )
        _ = try fixture.queue.applyStateCommand(JobStateCommand(jobID: updateJob.id, operation: .cancel))
        _ = try coordinator.claimAndExecuteOnce(personalizationClaim())
        XCTAssertEqual(try pendingCount(database: fixture.database, tagID: fixture.tagID), retainedCount)
    }

    func testTwoTagsRunSeriallyAndFolderReconcileClaimsOnlyItsKind() throws {
        let fixture = try makeLargeLibraryFixture(assetCount: 40)
        let secondTag = UUID(uuidString: "30000000-0000-4000-8000-000000000099")!
        try fixture.database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms) VALUES (?, 'Pets', 'pets', 'active', ?, ?)",
                arguments: [
                    secondTag.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
        }
        try seedDecisions(
            database: fixture.database,
            tagID: secondTag,
            accepted: fixture.positiveIDs.prefix(2).map { $0 },
            rejected: fixture.negativeIDs.prefix(2).map { $0 }
        )
        let fakeReconcile = FakeJobHandler(kind: FolderReconcileJobFactory.kind) { _, _, _ in
            JobHandlerExecutionResult(
                outcome: .completed,
                checkpoint: nil,
                progress: JobProgress(completed: 1, total: 1)
            )
        }
        let personalizationHandler = makeHandler(
            database: fixture.database,
            loader: fixture.loader,
            queue: fixture.queue
        )
        let coordinator = JobExecutionCoordinator(
            queue: fixture.queue,
            registry: MultiJobHandlerRegistry(handlers: [fakeReconcile, personalizationHandler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: fixture.queue)
        )
        _ = try fixture.queue.enqueue(
            EnqueueJobCommand(
                id: UUID(),
                kind: FolderReconcileJobFactory.kind,
                payloadVersion: 1,
                payload: Data("{}".utf8),
                sourceID: fixture.sourceID,
                coalescingKey: "folder-test",
                priority: 0,
                maxAttempts: 3,
                notBeforeMs: DatabaseTestSupport.timestampMs
            )
        )
        _ = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs,
            database: fixture.database
        )
        _ = try enqueueJob(
            queue: fixture.queue,
            tagID: secondTag,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs,
            database: fixture.database
        )
        let folderResult = try coordinator.claimAndExecuteOnce(
            ClaimNextInput(
                owner: "folder-worker",
                leaseDurationMs: 60_000,
                allowedKinds: [FolderReconcileJobFactory.kind]
            )
        )
        XCTAssertEqual(folderResult?.snapshot.kind, FolderReconcileJobFactory.kind)
        let firstPersonalization = try coordinator.claimAndExecuteOnce(personalizationClaim())
        XCTAssertEqual(firstPersonalization?.snapshot.kind, FullLibrarySuggestionsJobFactory.kind)
        let secondPersonalization = try fixture.queue.claimNext(personalizationClaim())
        XCTAssertNotNil(secondPersonalization)
        XCTAssertNil(
            try fixture.queue.claimNext(
                ClaimNextInput(
                    owner: "folder-worker-2",
                    leaseDurationMs: 60_000,
                    allowedKinds: [FolderReconcileJobFactory.kind]
                )
            )
        )
    }

    func testFrozenScopeExcludesAssetsIndexedAfterCutoff() throws {
        let fixture = try makeLargeLibraryFixture(assetCount: 10)
        let lateAsset = UUID(uuidString: "20000000-0000-4000-8000-000000000999")!
        try fixture.database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, media_created_at_ms, media_modified_at_ms,
                    file_name, content_revision, availability, record_created_at_ms, record_updated_at_ms
                ) VALUES (?, ?, 'file', 'late.jpg', NULL, 'current', 'public.jpeg', ?, ?, 'late.jpg', 1, 'available', ?, ?)
                """,
                arguments: [
                    lateAsset.uuidString.lowercased(),
                    fixture.sourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                    fixture.cutoffMs + 10_000,
                    fixture.cutoffMs + 10_000,
                ]
            )
        }
        let handler = makeHandler(database: fixture.database, loader: fixture.loader, queue: fixture.queue)
        let coordinator = makeCoordinator(database: fixture.database, handler: handler, queue: fixture.queue)
        _ = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs,
            database: fixture.database
        )
        drainPersonalizationJobs(coordinator: coordinator, maxSteps: 5)
        let pending = try pendingAssetIDs(database: fixture.database, tagID: fixture.tagID)
        XCTAssertFalse(pending.contains(lateAsset))
    }

    func testManualDecisionImmediatelyHidesSuggestion() throws {
        let fixture = try makeLargeLibraryFixture(assetCount: 12)
        let handler = makeHandler(database: fixture.database, loader: fixture.loader, queue: fixture.queue)
        let coordinator = makeCoordinator(database: fixture.database, handler: handler, queue: fixture.queue)
        _ = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs,
            database: fixture.database
        )
        drainPersonalizationJobs(coordinator: coordinator, maxSteps: 5)
        let first = try XCTUnwrap(try pendingAssetIDs(database: fixture.database, tagID: fixture.tagID).first)
        _ = try fixture.tags.batchReject(tagID: fixture.tagID, assetIDs: [first], timestampMs: DatabaseTestSupport.timestampMs + 99)
        XCTAssertFalse(try pendingAssetIDs(database: fixture.database, tagID: fixture.tagID).contains(first))
    }

    func testReviewPortProjectionsExcludeScoreAndSupportPaging() throws {
        let fixture = try makeLargeLibraryFixture(assetCount: 30)
        let handler = makeHandler(database: fixture.database, loader: fixture.loader, queue: fixture.queue)
        let coordinator = makeCoordinator(database: fixture.database, handler: handler, queue: fixture.queue)
        _ = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs,
            database: fixture.database
        )
        drainPersonalizationJobs(coordinator: coordinator, maxSteps: 5)
        let review = PersonalizationReviewService(
            database: fixture.database,
            queue: fixture.queue,
            executionCoordinator: coordinator,
            tags: fixture.tags,
            clock: FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        )
        let page = try review.fetchReviewQueue(tagID: fixture.tagID, cursor: nil, limit: 10)
        XCTAssertEqual(page.items.count, 10)
        XCTAssertNotNil(page.nextCursor)
        assertProjectionExcludesScoreField(page.items[0])
        if let cursor = page.nextCursor {
            assertProjectionExcludesScoreField(cursor)
            let cursorMirror = Mirror(reflecting: cursor)
            XCTAssertTrue(cursorMirror.children.contains { $0.label == "token" })
        }
        let firstPageIDs = Set(page.items.map(\.assetID))
        let secondPage = try review.fetchReviewQueue(
            tagID: fixture.tagID,
            cursor: page.nextCursor,
            limit: 10
        )
        XCTAssertFalse(secondPage.items.isEmpty)
        assertProjectionExcludesScoreField(secondPage.items[0])
        let secondPageIDs = Set(secondPage.items.map(\.assetID))
        XCTAssertTrue(firstPageIDs.isDisjoint(with: secondPageIDs))
        XCTAssertEqual(
            firstPageIDs.count + secondPageIDs.count,
            firstPageIDs.union(secondPageIDs).count
        )
        let total = try review.totalPendingSuggestionCount()
        XCTAssertGreaterThan(total, 10)
    }

    private func assertProjectionExcludesScoreField(_ value: Any) {
        let mirror = Mirror(reflecting: value)
        XCTAssertFalse(mirror.children.contains { $0.label == "score" })
    }

    func testProgressivePredictionsVisibleAfterFirstBatchOnly() throws {
        let fixture = try makeLargeLibraryFixture(assetCount: 150)
        var dependencies = makeHandlerDependencies(
            database: fixture.database,
            loader: fixture.loader,
            queue: fixture.queue
        )
        let batchCounter = BatchCounter()
        let capturedJobID = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs,
            database: fixture.database
        ).id
        dependencies.beforeEachBatch = { _ in
            if batchCounter.increment() == 2 {
                _ = try? fixture.queue.applyStateCommand(
                    JobStateCommand(jobID: capturedJobID, operation: .pause)
                )
            }
        }
        let handler = FullLibrarySuggestionsHandler(dependencies: dependencies)
        let coordinator = makeCoordinator(database: fixture.database, handler: handler, queue: fixture.queue)
        _ = try coordinator.claimAndExecuteOnce(personalizationClaim())
        let partial = try pendingCount(database: fixture.database, tagID: fixture.tagID)
        XCTAssertGreaterThan(partial, 0)
        let paused = try fixture.queue.fetchJob(id: capturedJobID)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertGreaterThan(paused.progress.completed, 0)
        XCTAssertLessThan(paused.progress.completed, 150)
    }

    func testPauseAfterFirstBatchStopsWithPartialProgress() throws {
        let fixture = try makeLargeLibraryFixture(assetCount: 150)
        var dependencies = makeHandlerDependencies(
            database: fixture.database,
            loader: fixture.loader,
            queue: fixture.queue
        )
        let batchCounter = BatchCounter()
        let capturedJobID = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs,
            database: fixture.database
        ).id
        dependencies.beforeEachBatch = { _ in
            if batchCounter.increment() == 2 {
                _ = try? fixture.queue.applyStateCommand(
                    JobStateCommand(jobID: capturedJobID, operation: .pause)
                )
            }
        }
        let handler = FullLibrarySuggestionsHandler(dependencies: dependencies)
        let coordinator = makeCoordinator(database: fixture.database, handler: handler, queue: fixture.queue)
        _ = try coordinator.claimAndExecuteOnce(personalizationClaim())
        let paused = try fixture.queue.fetchJob(id: capturedJobID)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertGreaterThan(try pendingCount(database: fixture.database, tagID: fixture.tagID), 0)
        XCTAssertGreaterThan(paused.progress.completed, 0)
        XCTAssertLessThan(paused.progress.completed, 150)
    }

    func testCancelAfterFirstBatchRetainsPartialSuggestions() throws {
        let fixture = try makeLargeLibraryFixture(assetCount: 120)
        var dependencies = makeHandlerDependencies(
            database: fixture.database,
            loader: fixture.loader,
            queue: fixture.queue
        )
        let batchCounter = BatchCounter()
        let capturedJobID = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs,
            database: fixture.database
        ).id
        dependencies.beforeEachBatch = { _ in
            if batchCounter.increment() == 2 {
                _ = try? fixture.queue.applyStateCommand(
                    JobStateCommand(jobID: capturedJobID, operation: .cancel)
                )
            }
        }
        let handler = FullLibrarySuggestionsHandler(dependencies: dependencies)
        let coordinator = makeCoordinator(database: fixture.database, handler: handler, queue: fixture.queue)
        _ = try coordinator.claimAndExecuteOnce(personalizationClaim())
        let retained = try pendingCount(database: fixture.database, tagID: fixture.tagID)
        XCTAssertGreaterThan(retained, 0)
    }

    func testCacheUnsafePathFailureIsRetryableAndPreservesCheckpoint() throws {
        let fixture = try makeLargeLibraryFixture(assetCount: 20)
        let base = fixture.loader
        let failingLoader = CacheFailureAfterSamplesLoader(base: base)
        let handler = makeHandler(database: fixture.database, loader: failingLoader, queue: fixture.queue)
        let coordinator = makeCoordinator(database: fixture.database, handler: handler, queue: fixture.queue)
        let job = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs,
            database: fixture.database
        )
        _ = try coordinator.claimAndExecuteOnce(personalizationClaim())
        let snapshot = try fixture.queue.fetchJob(id: job.id)
        XCTAssertEqual(snapshot.state, .retryableFailed)
        XCTAssertNotNil(snapshot.checkpoint)
    }

    func testPostCutoffAssetModificationIncreasesCheckedAndSkippedWithoutPrediction() throws {
        let fixture = try makeLargeLibraryFixture(assetCount: 12)
        let modifiedAsset = try XCTUnwrap(
            try fixture.database.pool.read { db in
                try String.fetchOne(
                    db,
                    sql: """
                    SELECT id FROM asset
                    WHERE source_id = ? AND id LIKE '21000000-%'
                    ORDER BY id ASC LIMIT 1
                    """,
                    arguments: [fixture.sourceID.uuidString.lowercased()]
                )
            }.flatMap(UUID.init(uuidString:))
        )
        try fixture.database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE asset SET record_updated_at_ms = ?, content_revision = content_revision + 1
                WHERE id = ?
                """,
                arguments: [
                    fixture.cutoffMs + 5_000,
                    modifiedAsset.uuidString.lowercased(),
                ]
            )
        }
        let handler = makeHandler(database: fixture.database, loader: fixture.loader, queue: fixture.queue)
        let coordinator = makeCoordinator(database: fixture.database, handler: handler, queue: fixture.queue)
        _ = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs,
            database: fixture.database
        )
        drainPersonalizationJobs(coordinator: coordinator, maxSteps: 5, queue: fixture.queue)
        let facts = try revisionFacts(database: fixture.database, tagID: fixture.tagID)
        let pending = try pendingAssetIDs(database: fixture.database, tagID: fixture.tagID)
        XCTAssertFalse(pending.contains(modifiedAsset))
        XCTAssertEqual(facts.checkedCount, 12)
        XCTAssertGreaterThanOrEqual(facts.skippedCount, 1)
    }

    func testPostEnqueueFeedbackDoesNotChangeFrozenSamples() throws {
        let fixture = try makeLargeLibraryFixture(assetCount: 20)
        let review = GRDBPersonalizationReviewRepository(database: fixture.database)
        let samplesBefore = try review.fetchFrozenSampleIdentities(tagID: fixture.tagID)
        let job = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs,
            database: fixture.database
        )
        let newFeedbackAsset = try XCTUnwrap(
            try fixture.database.pool.read { db in
                try String.fetchOne(
                    db,
                    sql: """
                    SELECT id FROM asset
                    WHERE source_id = ? AND id LIKE '21000000-%'
                    ORDER BY id DESC LIMIT 1
                    """,
                    arguments: [fixture.sourceID.uuidString.lowercased()]
                )
            }.flatMap(UUID.init(uuidString:))
        )
        try seedDecisions(
            database: fixture.database,
            tagID: fixture.tagID,
            accepted: [newFeedbackAsset],
            rejected: []
        )
        let handler = makeHandler(database: fixture.database, loader: fixture.loader, queue: fixture.queue)
        let coordinator = makeCoordinator(database: fixture.database, handler: handler, queue: fixture.queue)
        drainPersonalizationJobs(coordinator: coordinator, maxSteps: 5)
        let payload = try fixture.database.pool.read { db -> FullLibrarySuggestionsPayload in
            let row = try Row.fetchOne(db, sql: "SELECT payload FROM job WHERE id = ?", arguments: [job.id.uuidString.lowercased()])!
            return try FullLibrarySuggestionsCodec.decodePayload(row["payload"])
        }
        XCTAssertEqual(payload.frozenPositiveSamples, samplesBefore.positives)
        XCTAssertEqual(payload.frozenNegativeSamples, samplesBefore.negatives)
    }

    func testUpdateReplacesCurrentQueueAndPreservesManualDecisions() throws {
        let fixture = try makeLargeLibraryFixture(assetCount: 30, preseedPredictions: 5)
        let preseedPending = try pendingAssetIDs(database: fixture.database, tagID: fixture.tagID)
        let decided = try XCTUnwrap(preseedPending.first)
        _ = try fixture.tags.batchAccept(
            tagID: fixture.tagID,
            assetIDs: [decided],
            timestampMs: DatabaseTestSupport.timestampMs + 50
        )
        let handler = makeHandler(database: fixture.database, loader: fixture.loader, queue: fixture.queue)
        let coordinator = makeCoordinator(database: fixture.database, handler: handler, queue: fixture.queue)
        _ = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs + 1,
            database: fixture.database
        )
        drainPersonalizationJobs(coordinator: coordinator, maxSteps: 5)
        let facts = try revisionFacts(database: fixture.database, tagID: fixture.tagID)
        XCTAssertEqual(facts.currentRevision, 2)
        XCTAssertFalse(try pendingAssetIDs(database: fixture.database, tagID: fixture.tagID).contains(decided))
        let decision = try fixture.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT decision FROM asset_tag_decision WHERE asset_id = ? AND tag_id = ?",
                arguments: [decided.uuidString.lowercased(), fixture.tagID.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(decision, "accepted")
    }

    func testDisabledSourceAssetsAreSkippedNotDroppedFromProgress() throws {
        let fixture = try makeLargeLibraryFixture(assetCount: 20)
        let handler = makeHandler(database: fixture.database, loader: fixture.loader, queue: fixture.queue)
        let coordinator = makeCoordinator(database: fixture.database, handler: handler, queue: fixture.queue)
        _ = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs,
            database: fixture.database
        )
        try fixture.database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET state = 'disabled' WHERE id = ?",
                arguments: [fixture.sourceID.uuidString.lowercased()]
            )
        }
        drainPersonalizationJobs(coordinator: coordinator, maxSteps: 3)
        let facts = try revisionFacts(database: fixture.database, tagID: fixture.tagID)
        XCTAssertEqual(facts.checkedCount, 20)
        XCTAssertGreaterThan(facts.skippedCount, 0)
        XCTAssertEqual(try pendingCount(database: fixture.database, tagID: fixture.tagID), 0)
    }

    func testRetryableFailureAfterFirstBatchPreservesCommittedCheckpointAndCompletesFully() throws {
        let referenceFixture = try makeLargeLibraryFixture(assetCount: 120)
        let referenceHandler = makeHandler(
            database: referenceFixture.database,
            loader: referenceFixture.loader,
            queue: referenceFixture.queue
        )
        let referenceCoordinator = makeCoordinator(
            database: referenceFixture.database,
            handler: referenceHandler,
            queue: referenceFixture.queue
        )
        _ = try enqueueJob(
            queue: referenceFixture.queue,
            tagID: referenceFixture.tagID,
            sourceIDs: [referenceFixture.sourceID],
            cutoffMs: referenceFixture.cutoffMs,
            database: referenceFixture.database
        )
        drainPersonalizationJobs(
            coordinator: referenceCoordinator,
            maxSteps: 5,
            queue: referenceFixture.queue
        )
        let referencePredictions = Set(
            try pendingAssetIDs(database: referenceFixture.database, tagID: referenceFixture.tagID)
        )

        let fixture = try makeLargeLibraryFixture(assetCount: 120)
        let failureLoader = BatchScopedFailureLoader(base: fixture.loader)
        failureLoader.failOnBatch = 1
        var failureDependencies = makeHandlerDependencies(
            database: fixture.database,
            loader: failureLoader,
            queue: fixture.queue
        )
        failureDependencies.beforeEachBatch = { batchNumber in
            failureLoader.activeBatch = batchNumber
        }
        let failureHandler = FullLibrarySuggestionsHandler(dependencies: failureDependencies)
        let failureCoordinator = makeCoordinator(
            database: fixture.database,
            handler: failureHandler,
            queue: fixture.queue
        )
        let failureJob = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs,
            database: fixture.database
        )
        _ = try failureCoordinator.claimAndExecuteOnce(personalizationClaim())
        let failedSnapshot = try fixture.queue.fetchJob(id: failureJob.id)
        XCTAssertEqual(failedSnapshot.state, .retryableFailed)
        let failedCheckpoint = try FullLibrarySuggestionsCodec.checkpoint(from: XCTUnwrap(failedSnapshot.checkpoint))
        XCTAssertTrue(failedCheckpoint.firstBatchPublished)
        XCTAssertEqual(failedCheckpoint.checkedCount, 100)

        failureLoader.failOnBatch = nil
        drainPersonalizationJobs(coordinator: failureCoordinator, maxSteps: 5, queue: fixture.queue)
        let recoveredFacts = try revisionFacts(database: fixture.database, tagID: fixture.tagID)
        XCTAssertEqual(recoveredFacts.checkedCount, 120)
        let recoveredPredictions = Set(try pendingAssetIDs(database: fixture.database, tagID: fixture.tagID))
        XCTAssertEqual(recoveredPredictions, referencePredictions)
    }

    func testPersonalizationDoesNotClaimWhileFolderReconcileWaiting() throws {
        let fixture = try makeLargeLibraryFixture(assetCount: 10)
        let fakeReconcile = FakeJobHandler(kind: FolderReconcileJobFactory.kind) { _, _, _ in
            JobHandlerExecutionResult(
                outcome: .completed,
                checkpoint: nil,
                progress: JobProgress(completed: 1, total: 1)
            )
        }
        let personalizationHandler = makeHandler(
            database: fixture.database,
            loader: fixture.loader,
            queue: fixture.queue
        )
        let coordinator = JobExecutionCoordinator(
            queue: fixture.queue,
            registry: MultiJobHandlerRegistry(handlers: [fakeReconcile, personalizationHandler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: fixture.queue)
        )
        let reviewService = PersonalizationReviewService(
            database: fixture.database,
            queue: fixture.queue,
            executionCoordinator: coordinator,
            tags: fixture.tags,
            clock: FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        )
        let folderJobID = UUID()
        _ = try fixture.queue.enqueue(
            try FolderReconcileJobFactory.makeEnqueueCommand(
                jobID: folderJobID,
                sourceID: fixture.sourceID,
                notBeforeMs: DatabaseTestSupport.timestampMs
            )
        )
        _ = try enqueueJob(
            queue: fixture.queue,
            tagID: fixture.tagID,
            sourceIDs: [fixture.sourceID],
            cutoffMs: fixture.cutoffMs,
            database: fixture.database
        )
        XCTAssertFalse(try reviewService.runPendingSuggestionJobs(maxSteps: 1))
        XCTAssertEqual(try fixture.queue.fetchJob(id: folderJobID).state, .pending)

        _ = try coordinator.claimAndExecuteOnce(
            ClaimNextInput(
                owner: "folder-worker",
                leaseDurationMs: 60_000,
                allowedKinds: [FolderReconcileJobFactory.kind]
            )
        )
        XCTAssertTrue(try reviewService.runPendingSuggestionJobs(maxSteps: 1))
    }

    func testRunnerRefreshTicksWhileWorkerBlocked() async {
        let review = BlockingPersonalizationReviewPort(blockDuration: 0.6)
        let counter = RefreshCounter()
        let worker = Task {
            await PersonalizationSuggestionRunner.runOneStep(review: review) {
                counter.bump()
            }
        }
        for _ in 0 ..< 20 {
            if review.activeWorkersCount > 0 { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(review.activeWorkersCount, 1)
        let parallel = Task {
            await PersonalizationSuggestionRunner.runOneStep(review: review, refresh: nil)
        }
        let parallelResult = await parallel.value
        XCTAssertFalse(parallelResult)
        XCTAssertEqual(review.peakConcurrentWorkers, 1)
        for _ in 0 ..< 30 {
            if counter.value >= 2 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThanOrEqual(counter.value, 2)
        _ = await worker.value
    }
}

private struct LargeLibraryFixture {
    let database: CatalogDatabase
    let queue: GRDBJobQueue
    let tags: GRDBTagCatalogRepository
    let loader: StubSyncFeatureVectorLoader
    let sourceID: UUID
    let tagID: UUID
    let cutoffMs: Int64
    let positiveIDs: [UUID]
    let negativeIDs: [UUID]
}

private func makeLargeLibraryFixture(
    assetCount: Int,
    preseedPredictions: Int = 0
) throws -> LargeLibraryFixture {
    let fixture = try CatalogQueryTestSupport.openQueryDatabase()
    let sourceID = fixture.ids.sourceA
    let tagID = fixture.ids.tagFamily
    let cutoffMs = DatabaseTestSupport.timestampMs + 5_000
    try fixture.database.pool.write { db in
        try db.execute(
            sql: "UPDATE source SET state = 'active' WHERE id = ?",
            arguments: [sourceID.uuidString.lowercased()]
        )
    }
    var assetIDs: [UUID] = []
    try fixture.database.pool.write { db in
        for index in 0 ..< assetCount {
            let assetID = UUID(uuidString: String(format: "21000000-0000-4000-8000-%012X", index + 1))!
            assetIDs.append(assetID)
            try db.execute(
                sql: """
                INSERT INTO asset (
                    id, source_id, locator_kind, relative_path, photos_local_identifier,
                    locator_state, media_type, media_created_at_ms, media_modified_at_ms,
                    file_name, content_revision, availability, record_created_at_ms, record_updated_at_ms
                ) VALUES (?, ?, 'file', ?, NULL, 'current', 'public.jpeg', ?, ?, ?, 1, 'available', ?, ?)
                """,
                arguments: [
                    assetID.uuidString.lowercased(),
                    sourceID.uuidString.lowercased(),
                    "bulk/item-\(index).jpg",
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                    "item-\(index).jpg",
                    cutoffMs - 1,
                    cutoffMs - 1,
                ]
            )
        }
    }
    try fixture.database.pool.write { db in
        try db.execute(
            sql: """
            UPDATE asset
            SET record_created_at_ms = ?, record_updated_at_ms = ?
            WHERE source_id = ?
                AND id LIKE '20000000-%'
            """,
            arguments: [
                cutoffMs + 10_000,
                cutoffMs + 10_000,
                sourceID.uuidString.lowercased(),
            ]
        )
    }
    let positives = Array(assetIDs.prefix(2)) + [fixture.ids.assetMiddle]
    let negatives = Array(assetIDs.dropFirst(2).prefix(2)) + [fixture.ids.assetDuplicateTimeA, fixture.ids.assetDuplicateTimeB]
    try seedDecisions(database: fixture.database, tagID: tagID, accepted: positives, rejected: negatives)
    var vectors: [UUID: [Float]] = [:]
    for assetID in assetIDs {
        if positives.contains(assetID) {
            vectors[assetID] = [0, 0]
        } else if negatives.contains(assetID) {
            vectors[assetID] = [10, 10]
        } else {
            vectors[assetID] = [1, 1]
        }
    }
    for sample in positives {
        vectors[sample] = [0, 0]
    }
    for sample in negatives {
        vectors[sample] = [10, 10]
    }
    if preseedPredictions > 0 {
        let loader = StubSyncFeatureVectorLoader(database: fixture.database, vectors: vectors)
        for sampleID in positives + negatives {
            _ = try loader.loadOrGenerateSync(assetID: sampleID)
        }
        let catalog = GRDBPersonalizationRepository(database: fixture.database)
        let positiveSamples = positives.map {
            PersonalizedSuggestionScoringCore.LoadedSample(
                assetID: $0, contentRevision: 1, role: .positive, values: [0, 0]
            )
        }
        let negativeSamples = negatives.map {
            PersonalizedSuggestionScoringCore.LoadedSample(
                assetID: $0, contentRevision: 1, role: .negative, values: [10, 10]
            )
        }
        let samples = PersonalizedSuggestionScoringCore.registrations(
            positives: positiveSamples,
            negatives: negativeSamples
        )
        try catalog.publishModelRevision(
            ModelRevisionRegistration(
                tagID: tagID,
                revision: 1,
                threshold: 0,
                neighborCount: 2,
                sampleBudgetPerRole: 12,
                samples: samples,
                createdAtMs: DatabaseTestSupport.timestampMs
            )
        )
        let predictions = Array(assetIDs.dropFirst(4).prefix(preseedPredictions)).map {
            PredictionRegistration(assetID: $0, contentRevision: 1, score: 0.5)
        }
        try catalog.replacePredictions(
            tagID: tagID,
            modelRevision: 1,
            candidateAssetIDs: Array(assetIDs.dropFirst(4).prefix(preseedPredictions)),
            predictions: predictions,
            createdAtMs: DatabaseTestSupport.timestampMs
        )
    }
    let queue = JobTestSupport.makeQueue(database: fixture.database, retryDelayMs: 0)
    return LargeLibraryFixture(
        database: fixture.database,
        queue: queue,
        tags: fixture.tags,
        loader: StubSyncFeatureVectorLoader(database: fixture.database, vectors: vectors),
        sourceID: sourceID,
        tagID: tagID,
        cutoffMs: cutoffMs,
        positiveIDs: positives,
        negativeIDs: negatives
    )
}

private func seedDecisions(
    database: CatalogDatabase,
    tagID: UUID,
    accepted: [UUID],
    rejected: [UUID]
) throws {
    try database.pool.write { db in
        for assetID in accepted {
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'accepted', ?)
                ON CONFLICT(asset_id, tag_id) DO UPDATE SET decision = 'accepted', updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [assetID.uuidString.lowercased(), tagID.uuidString.lowercased(), DatabaseTestSupport.timestampMs]
            )
        }
        for assetID in rejected {
            try db.execute(
                sql: """
                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                VALUES (?, ?, 'rejected', ?)
                ON CONFLICT(asset_id, tag_id) DO UPDATE SET decision = 'rejected', updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [assetID.uuidString.lowercased(), tagID.uuidString.lowercased(), DatabaseTestSupport.timestampMs + 1]
            )
        }
    }
}

private final class BatchScopedFailureLoader: SyncFeatureVectorLoading, @unchecked Sendable {
    let base: StubSyncFeatureVectorLoader
    private let lock = NSLock()
    var activeBatch = -1
    var failOnBatch: Int?

    init(base: StubSyncFeatureVectorLoader) {
        self.base = base
    }

    func loadOrGenerateSync(assetID: UUID) throws -> FeatureVectorPayload {
        lock.lock()
        let shouldFail = failOnBatch.map { activeBatch >= $0 } ?? false
        lock.unlock()
        if shouldFail {
            throw FeaturePrintError.cacheUnsafePath
        }
        return try base.loadOrGenerateSync(assetID: assetID)
    }
}

private final class BlockingPersonalizationReviewPort: PersonalizationReviewPort, @unchecked Sendable {
    private let lock = NSLock()
    private var activeWorkers = 0
    private(set) var peakConcurrentWorkers = 0
    let blockDuration: TimeInterval

    init(blockDuration: TimeInterval) {
        self.blockDuration = blockDuration
    }

    var activeWorkersCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeWorkers
    }

    func totalPendingSuggestionCount() throws -> Int { 0 }
    func tagOverviews() throws -> [SuggestionTagOverview] { [] }
    func fetchReviewQueue(tagID: UUID, cursor: ReviewQueueCursor?, limit: Int) throws -> ReviewQueuePage {
        ReviewQueuePage(items: [], nextCursor: nil)
    }
    func pendingSuggestionsForAsset(assetID: UUID) throws -> [AssetPendingSuggestion] { [] }
    func enqueueFullLibrarySuggestions(tagID: UUID, mode: PersonalizationReviewEnqueueMode) throws -> UUID {
        UUID()
    }
    func pauseSuggestionJob(jobID: UUID) throws {}
    func resumeSuggestionJob(jobID: UUID) throws {}
    func cancelSuggestionJob(jobID: UUID) throws {}

    func runPendingSuggestionJobs(maxSteps: Int?) throws -> Bool {
        lock.lock()
        activeWorkers += 1
        peakConcurrentWorkers = max(peakConcurrentWorkers, activeWorkers)
        lock.unlock()
        defer {
            lock.lock()
            activeWorkers -= 1
            lock.unlock()
        }
        Thread.sleep(forTimeInterval: blockDuration)
        return true
    }
}

private final class RefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class CacheFailureAfterSamplesLoader: SyncFeatureVectorLoading, @unchecked Sendable {
    let base: StubSyncFeatureVectorLoader
    private var loadCount = 0

    init(base: StubSyncFeatureVectorLoader) {
        self.base = base
    }

    func loadOrGenerateSync(assetID: UUID) throws -> FeatureVectorPayload {
        loadCount += 1
        if loadCount > 7 {
            throw FeaturePrintError.cacheUnsafePath
        }
        return try base.loadOrGenerateSync(assetID: assetID)
    }
}

private struct StubSyncFeatureVectorLoader: SyncFeatureVectorLoading {
    let database: CatalogDatabase
    let vectors: [UUID: [Float]]

    func loadOrGenerateSync(assetID: UUID) throws -> FeatureVectorPayload {
        let values = vectors[assetID] ?? [9, 9]
        let contentRevision = try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT content_revision FROM asset WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }
        guard let contentRevision else { throw FeaturePrintError.assetNotFound }
        let data = values.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
        }
        let digest = Data(SHA256.hash(data: data))
        let identity = FeatureIdentity(assetID: assetID, contentRevision: contentRevision)
        let canonical = assetID.uuidString.lowercased()
        let shard = String(canonical.replacingOccurrences(of: "-", with: "").prefix(2))
        try GRDBPersonalizationRepository(database: database).registerFeature(
            FeatureRegistration(
                identity: identity,
                elementCount: values.count,
                byteCount: data.count,
                vectorSHA256: digest,
                cacheKey: "objects/\(shard)/\(canonical)-stub.fprint",
                createdAtMs: DatabaseTestSupport.timestampMs
            )
        )
        return FeatureVectorPayload(
            identity: identity,
            elementCount: values.count,
            vectorData: data,
            vectorSHA256: digest,
            origin: .generated
        )
    }
}

private func makeHandlerDependencies(
    database: CatalogDatabase,
    loader: any SyncFeatureVectorLoading,
    queue: GRDBJobQueue
) -> FullLibrarySuggestionsHandlerDependencies {
    FullLibrarySuggestionsHandlerDependencies(
        database: database,
        queue: queue,
        featureLoader: loader,
        clock: FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
    )
}

private func makeHandler(
    database: CatalogDatabase,
    loader: any SyncFeatureVectorLoading,
    queue: GRDBJobQueue
) -> FullLibrarySuggestionsHandler {
    FullLibrarySuggestionsHandler(dependencies: makeHandlerDependencies(
        database: database,
        loader: loader,
        queue: queue
    ))
}

private final class BatchCounter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private func makeCoordinator(
    database: CatalogDatabase,
    handler: FullLibrarySuggestionsHandler,
    queue: GRDBJobQueue? = nil
) -> JobExecutionCoordinator {
    let queue = queue ?? JobTestSupport.makeQueue(database: database)
    return JobExecutionCoordinator(
        queue: queue,
        registry: MultiJobHandlerRegistry(handlers: [handler]),
        leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
    )
}

private func enqueueJob(
    queue: GRDBJobQueue,
    tagID: UUID,
    sourceIDs: [UUID],
    cutoffMs: Int64,
    database: CatalogDatabase
) throws -> JobRecordSnapshot {
    let review = GRDBPersonalizationReviewRepository(database: database)
    let samples = try review.fetchFrozenSampleIdentities(tagID: tagID)
    let modelRevision = try review.nextModelRevision(tagID: tagID)
    return try queue.enqueue(
        try FullLibrarySuggestionsJobEnqueue.makeEnqueueCommand(
            jobID: UUID(),
            tagID: tagID,
            sourceIDs: sourceIDs,
            catalogCutoffMs: cutoffMs,
            modelRevision: modelRevision,
            frozenPositiveSamples: samples.positives,
            frozenNegativeSamples: samples.negatives,
            notBeforeMs: DatabaseTestSupport.timestampMs
        )
    )
}

private func personalizationClaim() -> ClaimNextInput {
    ClaimNextInput(
        owner: "personalization-worker-\(UUID().uuidString.lowercased())",
        leaseDurationMs: 60_000,
        allowedKinds: [FullLibrarySuggestionsJobFactory.kind]
    )
}

private func drainPersonalizationJobs(
    coordinator: JobExecutionCoordinator,
    maxSteps: Int,
    queue: GRDBJobQueue? = nil
) {
    for _ in 0 ..< maxSteps {
        if let queue {
            try? queue.settleRetryableJobs()
        }
        guard (try? coordinator.claimAndExecuteOnce(personalizationClaim())) != nil else { break }
    }
}

private struct RevisionFacts {
    let revisionCount: Int
    let currentRevision: Int?
    let predictionCount: Int
    let positiveCandidateCount: Int
    let checkedCount: Int
    let skippedCount: Int
}

private func revisionFacts(database: CatalogDatabase, tagID: UUID) throws -> RevisionFacts {
    try database.pool.read { db in
        let revisionCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM tag_model_revision WHERE tag_id = ?",
            arguments: [tagID.uuidString.lowercased()]
        ) ?? 0
        let currentRevision = try Int.fetchOne(
            db,
            sql: "SELECT current_revision FROM tag_model WHERE tag_id = ?",
            arguments: [tagID.uuidString.lowercased()]
        )
        let predictionCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM prediction WHERE tag_id = ? AND model_revision = ?",
            arguments: [tagID.uuidString.lowercased(), currentRevision ?? 0]
        ) ?? 0
        let positiveCandidateCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM prediction WHERE tag_id = ? AND model_revision = ? AND score > 0",
            arguments: [tagID.uuidString.lowercased(), currentRevision ?? 0]
        ) ?? 0
        let checkedCount = try Int.fetchOne(
            db,
            sql: """
            SELECT progress_completed FROM job
            WHERE coalescing_key = ?
            ORDER BY updated_at_ms DESC LIMIT 1
            """,
            arguments: [FullLibrarySuggestionsJobFactory.coalescingKey(tagID: tagID)]
        ) ?? 0
        let skippedCount: Int
        if let checkpointRow = try Row.fetchOne(
            db,
            sql: """
            SELECT checkpoint FROM job
            WHERE coalescing_key = ?
            ORDER BY updated_at_ms DESC LIMIT 1
            """,
            arguments: [FullLibrarySuggestionsJobFactory.coalescingKey(tagID: tagID)]
        ), let checkpointData: Data = checkpointRow["checkpoint"] {
            let jobCheckpoint = JobCheckpoint(version: FullLibrarySuggestionsJobFactory.checkpointVersion, data: checkpointData)
            skippedCount = (try? FullLibrarySuggestionsCodec.checkpoint(from: jobCheckpoint).skippedCount) ?? 0
        } else {
            skippedCount = 0
        }
        return RevisionFacts(
            revisionCount: revisionCount,
            currentRevision: currentRevision,
            predictionCount: predictionCount,
            positiveCandidateCount: positiveCandidateCount,
            checkedCount: checkedCount,
            skippedCount: skippedCount
        )
    }
}

private func pendingCount(database: CatalogDatabase, tagID: UUID) throws -> Int {
    try GRDBPersonalizationReviewRepository(database: database).pendingCount(tagID: tagID)
}

private func pendingAssetIDs(database: CatalogDatabase, tagID: UUID) throws -> [UUID] {
    try GRDBPersonalizationRepository(database: database)
        .pendingPredictions(tagID: tagID, limit: 500)
        .map(\.assetID)
}
