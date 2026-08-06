import CryptoKit
import Foundation
import GRDB

struct PersonalizationReviewService: PersonalizationReviewPort, Sendable {
    let database: CatalogDatabase
    let queue: GRDBJobQueue
    let executionCoordinator: JobExecutionCoordinator
    let tags: GRDBTagCatalogRepository
    let clock: any JobClock
    let personalLibrarySuggestionsEnabled: Bool
    let standardLibrarySuggestionsEnabled: Bool
    let personalModelRebuildEnabled: Bool

    init(
        database: CatalogDatabase,
        queue: GRDBJobQueue,
        executionCoordinator: JobExecutionCoordinator,
        tags: GRDBTagCatalogRepository,
        clock: any JobClock,
        personalLibrarySuggestionsEnabled: Bool = true,
        standardLibrarySuggestionsEnabled: Bool = false,
        personalModelRebuildEnabled: Bool = false
    ) {
        self.database = database
        self.queue = queue
        self.executionCoordinator = executionCoordinator
        self.tags = tags
        self.clock = clock
        self.personalLibrarySuggestionsEnabled = personalLibrarySuggestionsEnabled
        self.standardLibrarySuggestionsEnabled = standardLibrarySuggestionsEnabled
        self.personalModelRebuildEnabled = personalModelRebuildEnabled
    }

    private var review: GRDBPersonalizationReviewRepository {
        GRDBPersonalizationReviewRepository(database: database)
    }

    func totalPendingSuggestionCount(sourceIDs: [UUID]?) throws -> Int {
        try review.totalPendingSuggestionCount(sourceIDs: sourceIDs)
    }

    func tagOverviews(sourceIDs: [UUID]?) throws -> [SuggestionTagOverview] {
        try tagOverviews(mediaKind: .image, sourceIDs: sourceIDs)
    }

    func totalPendingSuggestionCount(
        mediaKind: MediaKind,
        sourceIDs: [UUID]?
    ) throws -> Int {
        try review.totalPendingSuggestionCount(
            mediaKind: mediaKind,
            sourceIDs: sourceIDs
        )
    }

    func tagOverviews(
        mediaKind: MediaKind,
        sourceIDs: [UUID]?
    ) throws -> [SuggestionTagOverview] {
        let tags = try tags.listTags(includeArchived: false)
        return try tags.map { tag in
            let samples = try review.sampleCounts(
                mediaKind: mediaKind,
                tagID: tag.id
            )
            let pendingCounts = try review.pendingCounts(
                mediaKind: mediaKind,
                tagID: tag.id,
                sourceIDs: sourceIDs
            )
            let pending = pendingCounts.total
            let job = try review.activeSuggestionJob(tagID: tag.id)
            let status = mapTaskStatus(tag: tag, samples: samples, job: job)
            let checkpoint = try job.flatMap { try FullLibrarySuggestionsCodec.checkpoint(from: $0.checkpoint) }
            let hasModel = try review.tagHasCurrentModel(
                mediaKind: mediaKind,
                tagID: tag.id
            )
            let isStandard = try review.tagIsStandard(tagID: tag.id)
            let missingPositive = max(0, 2 - samples.accepted)
            let missingNegative = max(0, 2 - samples.rejected)
            let samplesReady = missingPositive == 0 && missingNegative == 0
            let canGenerate = !isStandard && samplesReady && !hasModel && job == nil
            let canUpdate = !isStandard && samplesReady && hasModel && job == nil
            let canGeneratePersonalModel = !isStandard && samples.accepted >= 2 && job == nil
            return SuggestionTagOverview(
                id: tag.id,
                displayName: tag.displayName,
                acceptedSampleCount: samples.accepted,
                rejectedSampleCount: samples.rejected,
                pendingSuggestionCount: pending,
                pendingSuggestionCounts: pendingCounts,
                taskStatus: status,
                checkedCount: checkpoint?.checkedCount ?? job?.progress.completed ?? 0,
                totalCount: job?.progress.total,
                skippedCount: checkpoint?.skippedCount ?? 0,
                missingPositiveCount: missingPositive,
                missingNegativeCount: missingNegative,
                canGenerate: canGenerate,
                canUpdate: canUpdate,
                canGeneratePersonalModel: canGeneratePersonalModel,
                canReview: pending > 0,
                canPause: job?.state == .running || job?.state == .pending,
                canResume: job?.state == .paused,
                canCancel: job.map { !$0.state.isTerminal } ?? false,
                activeJobID: job?.id
            )
        }.sorted(by: sortOverviews)
    }

    func personalTrainingSnapshot() throws -> PersonalTrainingSnapshot {
        try review.personalTrainingSnapshot()
    }

    func personalTrainingSnapshot(limitingToAssetIDs assetIDs: Set<UUID>) throws -> PersonalTrainingSnapshot {
        try review.personalTrainingSnapshot(limitingToAssetIDs: assetIDs)
    }

    func personalTrainingSnapshot(
        limitingToTagIDs tagIDs: Set<UUID>,
        limitingToAssetIDs assetIDs: Set<UUID>?
    ) throws -> PersonalTrainingSnapshot {
        try review.personalTrainingSnapshot(
            limitingToTagIDs: tagIDs,
            limitingToAssetIDs: assetIDs
        )
    }

    func personalTrainingSnapshot(
        mediaKind: MediaKind,
        limitingToTagIDs tagIDs: Set<UUID>,
        limitingToAssetIDs assetIDs: Set<UUID>?
    ) throws -> PersonalTrainingSnapshot {
        try review.personalTrainingSnapshot(
            mediaKind: mediaKind,
            limitingToTagIDs: tagIDs,
            limitingToAssetIDs: assetIDs
        )
    }

    func enqueuePersonalModelRebuildIfReady() throws -> UUID? {
        guard personalModelRebuildEnabled else { return nil }
        let payloads = try PersonalModelRebuildJobFactory.payloads(
            from: review.personalTrainingSnapshot()
        )
        guard !payloads.isEmpty else { return nil }
        let scheduled = clock.nowMs.addingReportingOverflow(
            PersonalModelRebuildJobFactory.debounceDelayMs
        )
        guard !scheduled.overflow else {
            throw PersonalizationReviewError.persistenceFailure
        }
        var firstJobID: UUID?
        for payload in payloads {
            let command = try PersonalModelRebuildJobEnqueue.makeEnqueueCommand(
                jobID: UUID(),
                payload: payload,
                notBeforeMs: scheduled.partialValue
            )
            let jobID: UUID
            do {
                jobID = try queue.enqueue(command).id
            } catch let JobQueueError.activeCoalescingConflict(existingJobID) {
                jobID = existingJobID
            }
            if firstJobID == nil {
                firstJobID = jobID
            }
        }
        return firstJobID
    }

    func fetchReviewQueue(
        tagID: UUID,
        sourceIDs: [UUID]?,
        cursor: ReviewQueueCursor?,
        limit: Int
    ) throws -> ReviewQueuePage {
        try review.fetchReviewQueuePage(
            tagID: tagID,
            sourceIDs: sourceIDs,
            cursor: cursor,
            limit: limit
        )
    }

    func fetchReviewQueue(
        mediaKind: MediaKind,
        tagID: UUID,
        sourceIDs: [UUID]?,
        cursor: ReviewQueueCursor?,
        limit: Int
    ) throws -> ReviewQueuePage {
        try review.fetchReviewQueuePage(
            mediaKind: mediaKind,
            tagID: tagID,
            sourceIDs: sourceIDs,
            cursor: cursor,
            limit: limit
        )
    }

    func pendingSuggestionsForAsset(assetID: UUID) throws -> [AssetPendingSuggestion] {
        try review.pendingSuggestionsForAsset(assetID: assetID)
    }

    func personalSuggestionCandidates(
        afterAssetID: UUID?,
        limit: Int,
        sourceIDs: [UUID]?,
        excludingDecisionsForTagID: UUID?
    ) throws -> [PersonalSuggestionCandidate] {
        try review.personalSuggestionCandidates(
            afterAssetID: afterAssetID,
            limit: limit,
            sourceIDs: sourceIDs,
            excludingDecisionsForTagID: excludingDecisionsForTagID
        )
    }

    func personalSuggestionCandidates(
        mediaKind: MediaKind,
        afterAssetID: UUID?,
        limit: Int,
        sourceIDs: [UUID]?,
        excludingDecisionsForTagID: UUID?
    ) throws -> [PersonalSuggestionCandidate] {
        try review.personalSuggestionCandidates(
            mediaKind: mediaKind,
            afterAssetID: afterAssetID,
            limit: limit,
            sourceIDs: sourceIDs,
            excludingDecisionsForTagID: excludingDecisionsForTagID
        )
    }

    func activatePersonalSuggestionBundle(
        _ capability: PersonalModelSuggestionCapability
    ) throws {
        try review.activatePersonalSuggestionBundle(capability, activatedAtMs: clock.nowMs)
    }

    func replacePersonalSuggestions(
        candidate: PersonalSuggestionCandidate,
        predictions: [PersonalSuggestionPrediction],
        expectedCapability: PersonalModelSuggestionCapability
    ) throws -> Int {
        try review.replacePersonalSuggestions(
            candidate: candidate,
            predictions: predictions,
            expectedCapability: expectedCapability,
            createdAtMs: clock.nowMs
        )
    }

    func replacePersonalTagLibrarySuggestions(
        tagID: UUID,
        hits: [AppPersonalTagLibrarySuggestionHit],
        expectedCapability: PersonalModelSuggestionCapability,
        maximumPendingCount: Int
    ) throws -> Int {
        try review.replacePersonalTagLibrarySuggestions(
            tagID: tagID,
            hits: hits,
            expectedCapability: expectedCapability,
            maximumPendingCount: maximumPendingCount,
            createdAtMs: clock.nowMs
        )
    }

    func replaceStandardSuggestions(
        assetID: UUID,
        contentRevision: Int,
        suggestions: [LocalModelSuggestion],
        expectedTarget: StandardModelSuggestionTarget
    ) throws -> Int {
        try review.replaceStandardSuggestions(
            assetID: assetID,
            contentRevision: contentRevision,
            suggestions: suggestions,
            expectedTarget: expectedTarget,
            createdAtMs: clock.nowMs
        )
    }

    func invalidateAllPersonalSuggestionBundles() throws {
        try review.invalidateAllPersonalSuggestionBundles()
    }

    func invalidatePersonalSuggestionBundles(mediaKind: MediaKind) throws {
        try review.invalidatePersonalSuggestionBundles(mediaKind: mediaKind)
    }

    func enqueueFullLibrarySuggestions(
        tagID: UUID,
        mode: PersonalizationReviewEnqueueMode,
        sourceIDs: [UUID]?
    ) throws -> UUID {
        try enqueueFullLibrarySuggestions(
            mediaKind: .image,
            tagID: tagID,
            mode: mode,
            sourceIDs: sourceIDs
        )
    }

    func enqueueFullLibrarySuggestions(
        mediaKind: MediaKind,
        tagID: UUID,
        mode: PersonalizationReviewEnqueueMode,
        sourceIDs: [UUID]?
    ) throws -> UUID {
        let samples = try review.fetchFrozenSampleIdentities(
            mediaKind: mediaKind,
            tagID: tagID
        )
        guard samples.positives.count >= 2, samples.negatives.count >= 2 else {
            let accepted = samples.positives.count
            let rejected = samples.negatives.count
            throw PersonalizationReviewError.insufficientSamples(
                positiveMissing: max(0, 2 - accepted),
                negativeMissing: max(0, 2 - rejected)
            )
        }
        if let job = try review.activeSuggestionJob(mediaKind: mediaKind, tagID: tagID),
           !job.state.isTerminal
        {
            throw PersonalizationReviewError.activeJobConflict
        }
        let resolvedSourceIDs = try resolvePersonalizationSourceIDs(sourceIDs)
        let allActiveSourceIDs = try resolvePersonalizationSourceIDs(nil)
        let usesAllActiveSources = sourceIDs == nil
            || Set(resolvedSourceIDs) == Set(allActiveSourceIDs)
        let modelRevision = try review.nextModelRevision(
            mediaKind: mediaKind,
            tagID: tagID
        )
        let jobID = UUID()
        let runID = UUID()
        let nowMs = clock.nowMs
        let catalogScopeID = try database.catalogScopeID()
        let command = try FullLibrarySuggestionsJobEnqueue.makeEnqueueCommand(
            jobID: jobID,
            tagID: tagID,
            mediaKind: mediaKind,
            sourceIDs: resolvedSourceIDs,
            catalogCutoffMs: nowMs,
            modelRevision: modelRevision,
            frozenPositiveSamples: samples.positives,
            frozenNegativeSamples: samples.negatives,
            notBeforeMs: nowMs
        )
        let run = TrainingRunRecord(
            id: runID,
            mediaKind: mediaKind,
            method: .featureKnn,
            state: .queued,
            createdAtMs: nowMs,
            startedAtMs: nil,
            finishedAtMs: nil,
            catalogScopeID: catalogScopeID,
            jobID: jobID,
            tagID: tagID,
            sampleSummaryJSON: try TrainingRunJSON.encode([
                "mediaKind": mediaKind.rawValue,
                "tagCount": 1,
                "tagIDs": [tagID.uuidString.lowercased()],
                "positiveCount": samples.positives.count,
                "negativeCount": samples.negatives.count,
                "sourceCount": resolvedSourceIDs.count,
                "scope": usesAllActiveSources ? "allActiveSources" : "selectedSources",
                "scopeKind": usesAllActiveSources ? "allActiveSources" : "selectedSources",
                "requestedSourceCount": usesAllActiveSources ? 0 : (sourceIDs?.count ?? 0),
                "resolvedSourceCount": resolvedSourceIDs.count,
                "snapshotRevision": SHA256.hash(data: command.payload)
                    .map { String(format: "%02x", $0) }
                    .joined(),
            ]),
            sampleManifestSHA256: nil,
            configJSON: try TrainingRunJSON.encode([
                "mediaKind": mediaKind.rawValue,
                "action": mode == .generate ? "generate" : "update",
                "provider": "vision.featurePrint",
                "modelRevision": modelRevision,
                "minimumPositiveCount": 2,
                "minimumNegativeCount": 2,
                "neighborCountMaximum": 3,
                "sourceIDs": resolvedSourceIDs.map { $0.uuidString.lowercased() },
            ]),
            metricsJSON: "{}",
            artifactKind: nil,
            artifactRef: nil,
            artifactSHA256: nil,
            resultSummaryJSON: "{}",
            errorCode: nil
        )
        do {
            try database.pool.write { db in
                try JobInsertInTransaction.insertPendingJob(
                    db,
                    command: command,
                    nowMs: nowMs
                )
                try GRDBTrainingRunRepository(database: database).insert(run, on: db)
            }
        } catch JobQueueError.activeCoalescingConflict {
            throw PersonalizationReviewError.activeJobConflict
        }
        return jobID
    }

    func featureSuggestionJob(jobID: UUID) throws -> FeatureSuggestionJobProjection? {
        let job = try queue.fetchJob(id: jobID)
        guard job.kind == FullLibrarySuggestionsJobFactory.kind else {
            return nil
        }
        let checkpoint = try FullLibrarySuggestionsCodec.checkpoint(from: job.checkpoint)
        return FeatureSuggestionJobProjection(
            id: job.id,
            state: job.state,
            candidateCount: checkpoint.eligibleCount,
            aboveThresholdCount: checkpoint.suggestedCount,
            skippedCount: checkpoint.skippedCount
        )
    }

    func enqueuePersonalLibrarySuggestions(
        capability: PersonalModelSuggestionCapability,
        sourceIDs: [UUID]?
    ) throws -> UUID {
        guard personalLibrarySuggestionsEnabled,
              capability.target.catalogScopeID == (try database.catalogScopeID())
        else {
            throw PersonalizationReviewError.persistenceFailure
        }
        let jobID = UUID()
        let nowMs = clock.nowMs
        do {
            return try database.pool.write { db in
                if let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT * FROM job
                    WHERE coalescing_key = ?
                        AND state IN ('pending', 'running', 'paused', 'retryableFailed')
                    ORDER BY created_at_ms DESC, id DESC
                    LIMIT 1
                    """,
                    arguments: [
                        PersonalLibrarySuggestionsJobFactory.coalescingKey(
                            catalogScopeID: capability.target.catalogScopeID,
                            mediaKind: capability.target.mediaKind
                        ),
                    ]
                ) {
                    let existing = try JobPersistenceMapping.snapshot(from: row)
                    let existingPayload = try PersonalLibrarySuggestionsCodec.decodePayload(
                        existing.payload
                    )
                    guard existingPayload.capability == capability,
                          try review.personalCapabilityMatches(capability, in: db)
                    else {
                        throw PersonalizationReviewError.activeJobConflict
                    }
                    return existing.id
                }
                let resolvedSourceIDs = try resolvePersonalizationSourceIDs(sourceIDs, in: db)
                let command = try PersonalLibrarySuggestionsJobEnqueue.makeEnqueueCommand(
                    jobID: jobID,
                    mediaKind: capability.target.mediaKind,
                    sourceIDs: resolvedSourceIDs,
                    catalogCutoffMs: nowMs,
                    capability: capability,
                    notBeforeMs: nowMs
                )
                try review.activatePersonalSuggestionBundle(
                    capability,
                    activatedAtMs: nowMs,
                    on: db
                )
                try JobInsertInTransaction.insertPendingJob(
                    db,
                    command: command,
                    nowMs: nowMs
                )
                return jobID
            }
        } catch JobQueueError.activeCoalescingConflict {
            throw PersonalizationReviewError.activeJobConflict
        }
    }

    func personalLibrarySuggestionJob() throws -> PersonalLibrarySuggestionJobProjection? {
        try personalLibrarySuggestionJob(mediaKind: .image)
    }

    func personalLibrarySuggestionJob(
        mediaKind: MediaKind
    ) throws -> PersonalLibrarySuggestionJobProjection? {
        guard let job = try review.latestPersonalLibrarySuggestionJob(
            mediaKind: mediaKind
        ) else { return nil }
        let checkpoint = (try? PersonalLibrarySuggestionsCodec.checkpoint(from: job.checkpoint))
            ?? .empty
        return PersonalLibrarySuggestionJobProjection(
            id: job.id,
            state: job.state,
            checkedCount: checkpoint.checkedCount,
            totalCount: job.progress.total,
            suggestedCount: checkpoint.suggestedCount,
            skippedCount: checkpoint.skippedCount,
            lastErrorCode: job.lastErrorCode
        )
    }

    func enqueueStandardLibrarySuggestions(
        target: StandardModelSuggestionTarget,
        sourceIDs: [UUID]?
    ) throws -> UUID {
        try enqueueStandardLibrarySuggestions(
            mediaKind: .image,
            target: target,
            sourceIDs: sourceIDs
        )
    }

    func enqueueStandardLibrarySuggestions(
        mediaKind: MediaKind,
        target: StandardModelSuggestionTarget,
        sourceIDs: [UUID]?
    ) throws -> UUID {
        guard standardLibrarySuggestionsEnabled,
              StandardLibrarySuggestionsCodec.validateTarget(target)
        else {
            throw PersonalizationReviewError.persistenceFailure
        }
        let jobID = UUID()
        let nowMs = clock.nowMs
        do {
            return try database.pool.write { db in
                guard try review.standardSuggestionTargetMatches(target, in: db) else {
                    throw PersonalizationReviewError.persistenceFailure
                }
                if let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT * FROM job
                    WHERE coalescing_key = ?
                        AND state IN ('pending', 'running', 'paused', 'retryableFailed')
                    ORDER BY created_at_ms DESC, id DESC
                    LIMIT 1
                    """,
                    arguments: [
                        StandardLibrarySuggestionsJobFactory.coalescingKey(
                            standardPackID: target.standardPackID,
                            mediaKind: mediaKind
                        ),
                    ]
                ) {
                    let existing = try JobPersistenceMapping.snapshot(from: row)
                    let existingPayload = try StandardLibrarySuggestionsCodec.decodePayload(
                        existing.payload
                    )
                    guard existingPayload.target == target else {
                        throw PersonalizationReviewError.activeJobConflict
                    }
                    return existing.id
                }
                let resolvedSourceIDs = try resolvePersonalizationSourceIDs(sourceIDs, in: db)
                let command = try StandardLibrarySuggestionsJobEnqueue.makeEnqueueCommand(
                    jobID: jobID,
                    mediaKind: mediaKind,
                    sourceIDs: resolvedSourceIDs,
                    catalogCutoffMs: nowMs,
                    target: target,
                    notBeforeMs: nowMs
                )
                try JobInsertInTransaction.insertPendingJob(
                    db,
                    command: command,
                    nowMs: nowMs
                )
                return jobID
            }
        } catch JobQueueError.activeCoalescingConflict {
            throw PersonalizationReviewError.activeJobConflict
        }
    }

    func standardLibrarySuggestionJob() throws -> StandardLibrarySuggestionJobProjection? {
        try standardLibrarySuggestionJob(mediaKind: .image)
    }

    func standardLibrarySuggestionJob(
        mediaKind: MediaKind
    ) throws -> StandardLibrarySuggestionJobProjection? {
        guard let job = try review.latestStandardLibrarySuggestionJob(
            mediaKind: mediaKind
        ) else { return nil }
        let checkpoint = (try? StandardLibrarySuggestionsCodec.checkpoint(from: job.checkpoint))
            ?? .empty
        return StandardLibrarySuggestionJobProjection(
            id: job.id,
            state: job.state,
            checkedCount: checkpoint.checkedCount,
            totalCount: job.progress.total,
            suggestedCount: checkpoint.suggestedCount,
            skippedCount: checkpoint.skippedCount,
            lastErrorCode: job.lastErrorCode
        )
    }

    func pauseSuggestionJob(jobID: UUID) throws {
        _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .pause))
    }

    func resumeSuggestionJob(jobID: UUID) throws {
        _ = try queue.applyStateCommand(
            JobStateCommand(jobID: jobID, operation: .resume(notBeforeMs: clock.nowMs))
        )
    }

    func cancelSuggestionJob(jobID: UUID) throws {
        let snapshot = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .cancel))
        try synchronizeFeatureTrainingRun(with: snapshot)
    }

    func runPendingSuggestionJobs(maxSteps: Int? = nil) throws -> Bool {
        try queue.settleRetryableJobs()
        try synchronizeTerminalFeatureTrainingRuns()
        if try queue.hasBlockingReconcileWork(nowMs: clock.nowMs) {
            return false
        }
        let claim = ClaimNextInput(
            owner: PersonalizationSuggestionRunner.claimOwner,
            leaseDurationMs: 60_000,
            allowedKinds: [FullLibrarySuggestionsJobFactory.kind]
        )
        var steps = 0
        var didWork = false
        while true {
            if let maxSteps, steps >= maxSteps { break }
            if try queue.hasBlockingReconcileWork(nowMs: clock.nowMs) { break }
            guard let result = try executionCoordinator.claimAndExecuteOnce(claim) else { break }
            try synchronizeFeatureTrainingRun(with: result.snapshot)
            didWork = true
            steps += 1
            if result.snapshot.state == .terminalFailed {
                break
            }
        }
        return didWork
    }

    func runPendingSuggestionJobsAsync(maxSteps: Int? = nil) async throws -> Bool {
        try queue.settleRetryableJobs()
        try synchronizeTerminalFeatureTrainingRuns()
        if try queue.hasBlockingReconcileWork(nowMs: clock.nowMs) {
            return false
        }
        var allowedKinds = Set([FullLibrarySuggestionsJobFactory.kind])
        if personalLibrarySuggestionsEnabled {
            allowedKinds.insert(PersonalLibrarySuggestionsJobFactory.kind)
        }
        if standardLibrarySuggestionsEnabled {
            allowedKinds.insert(StandardLibrarySuggestionsJobFactory.kind)
        }
        if personalModelRebuildEnabled {
            allowedKinds.insert(PersonalModelRebuildJobFactory.kind)
        }
        let claim = ClaimNextInput(
            owner: PersonalizationSuggestionRunner.claimOwner,
            leaseDurationMs: 60_000,
            allowedKinds: allowedKinds
        )
        var steps = 0
        var didWork = false
        while true {
            if let maxSteps, steps >= maxSteps { break }
            if try queue.hasBlockingReconcileWork(nowMs: clock.nowMs) { break }
            guard let result = try await executionCoordinator.claimAndExecuteOnceAsync(claim) else { break }
            try synchronizeFeatureTrainingRun(with: result.snapshot)
            didWork = true
            steps += 1
            if result.snapshot.state == .terminalFailed {
                break
            }
        }
        return didWork
    }

    func nextSuggestionRetryDelayNanoseconds() throws -> UInt64? {
        var kinds = [FullLibrarySuggestionsJobFactory.kind]
        if personalLibrarySuggestionsEnabled {
            kinds.append(PersonalLibrarySuggestionsJobFactory.kind)
        }
        if standardLibrarySuggestionsEnabled {
            kinds.append(StandardLibrarySuggestionsJobFactory.kind)
        }
        if personalModelRebuildEnabled {
            kinds.append(PersonalModelRebuildJobFactory.kind)
        }
        let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ", ")
        var arguments = kinds.map { $0 as any DatabaseValueConvertible }
        arguments.append(clock.nowMs)
        let nextNotBeforeMs: Int64? = try database.pool.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                SELECT MIN(not_before_ms) FROM job
                WHERE kind IN (\(placeholders))
                    AND (
                        (state = 'pending' AND not_before_ms > ?)
                        OR (state = 'retryableFailed' AND attempts < max_attempts)
                    )
                """,
                arguments: StatementArguments(arguments)
            )
        }
        guard let nextNotBeforeMs else { return nil }
        let difference = nextNotBeforeMs.subtractingReportingOverflow(clock.nowMs)
        guard !difference.overflow, difference.partialValue > 0 else { return 0 }
        let nanoseconds = UInt64(difference.partialValue).multipliedReportingOverflow(
            by: 1_000_000
        )
        return nanoseconds.overflow ? UInt64.max : nanoseconds.partialValue
    }

    private func resolvePersonalizationSourceIDs(_ requested: [UUID]?) throws -> [UUID] {
        let active = try review.activePersonalizationSourceIDs()
        return try resolvePersonalizationSourceIDs(requested, active: active)
    }

    private func synchronizeTerminalFeatureTrainingRuns() throws {
        let jobIDs: [UUID] = try database.pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT j.id
                FROM job j
                JOIN training_run r ON r.job_id = j.id
                WHERE r.method = 'featureKnn'
                    AND r.state IN ('queued', 'running')
                    AND j.state IN ('completed', 'terminalFailed', 'cancelled')
                """
            ).compactMap(UUID.init(uuidString:))
        }
        for jobID in jobIDs {
            try synchronizeFeatureTrainingRun(with: queue.fetchJob(id: jobID))
        }
    }

    private func synchronizeFeatureTrainingRun(with snapshot: JobRecordSnapshot) throws {
        guard snapshot.kind == FullLibrarySuggestionsJobFactory.kind else { return }
        let runs = GRDBTrainingRunRepository(database: database)
        try database.pool.write { db in
            guard let run = try runs.fetch(jobID: snapshot.id, on: db),
                  !run.state.isTerminal
            else {
                return
            }
            switch snapshot.state {
            case .completed:
                var result = try TrainingRunJSON.decodeObject(run.resultSummaryJSON)
                result["published"] = run.artifactRef != nil
                result["partial"] = false
                try runs.update(
                    id: run.id,
                    state: .succeeded,
                    finishedAtMs: clock.nowMs,
                    resultSummaryJSON: try TrainingRunJSON.encode(result),
                    on: db
                )
            case .terminalFailed:
                let errorCode = snapshot.lastErrorCode?.rawValue ?? "attemptsExhausted"
                var result = try TrainingRunJSON.decodeObject(run.resultSummaryJSON)
                result["published"] = run.artifactRef != nil
                result["partial"] = run.artifactRef != nil
                result["errorCode"] = errorCode
                try runs.update(
                    id: run.id,
                    state: .failed,
                    finishedAtMs: clock.nowMs,
                    resultSummaryJSON: try TrainingRunJSON.encode(result),
                    errorCode: errorCode,
                    on: db
                )
            case .cancelled:
                var result = try TrainingRunJSON.decodeObject(run.resultSummaryJSON)
                result["published"] = run.artifactRef != nil
                result["partial"] = run.artifactRef != nil
                result["cancelled"] = true
                try runs.update(
                    id: run.id,
                    state: .cancelled,
                    finishedAtMs: clock.nowMs,
                    resultSummaryJSON: try TrainingRunJSON.encode(result),
                    on: db
                )
            case .pending, .running, .paused, .retryableFailed:
                break
            }
        }
    }

    private func resolvePersonalizationSourceIDs(
        _ requested: [UUID]?,
        in db: Database
    ) throws -> [UUID] {
        let active = try review.activePersonalizationSourceIDs(in: db)
        return try resolvePersonalizationSourceIDs(requested, active: active)
    }

    private func resolvePersonalizationSourceIDs(
        _ requested: [UUID]?,
        active: [UUID]
    ) throws -> [UUID] {
        let resolved: [UUID]
        if let requested {
            let activeSet = Set(active)
            let requestedSet = Set(requested)
            resolved = active.filter { requestedSet.contains($0) && activeSet.contains($0) }
        } else {
            resolved = active
        }
        guard !resolved.isEmpty else {
            throw PersonalizationReviewError.persistenceFailure
        }
        return resolved
    }

    private func mapTaskStatus(
        tag: TagListItem,
        samples: (accepted: Int, rejected: Int),
        job: JobRecordSnapshot?
    ) -> SuggestionTaskPresentation {
        if samples.accepted < 2 || samples.rejected < 2 {
            return .notReady
        }
        guard let job else {
            return .ready
        }
        switch job.state {
        case .pending:
            return .waiting
        case .running:
            return .running
        case .paused:
            return .paused
        case .retryableFailed:
            return .retryableFailure
        case .completed:
            return .completed
        case .terminalFailed:
            return .terminalFailure
        case .cancelled:
            return .cancelled
        }
    }

    private func sortOverviews(_ lhs: SuggestionTagOverview, _ rhs: SuggestionTagOverview) -> Bool {
        let lhsRank = sortRank(lhs)
        let rhsRank = sortRank(rhs)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.pendingSuggestionCount != rhs.pendingSuggestionCount {
            return lhs.pendingSuggestionCount > rhs.pendingSuggestionCount
        }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    private func sortRank(_ overview: SuggestionTagOverview) -> Int {
        switch overview.taskStatus {
        case .running: return 0
        case .waiting: return 1
        case .paused, .retryableFailure: return 2
        default:
            return overview.pendingSuggestionCount > 0 ? 3 : 4
        }
    }
}
