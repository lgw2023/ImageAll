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

    init(
        database: CatalogDatabase,
        queue: GRDBJobQueue,
        executionCoordinator: JobExecutionCoordinator,
        tags: GRDBTagCatalogRepository,
        clock: any JobClock,
        personalLibrarySuggestionsEnabled: Bool = true,
        standardLibrarySuggestionsEnabled: Bool = false
    ) {
        self.database = database
        self.queue = queue
        self.executionCoordinator = executionCoordinator
        self.tags = tags
        self.clock = clock
        self.personalLibrarySuggestionsEnabled = personalLibrarySuggestionsEnabled
        self.standardLibrarySuggestionsEnabled = standardLibrarySuggestionsEnabled
    }

    private var review: GRDBPersonalizationReviewRepository {
        GRDBPersonalizationReviewRepository(database: database)
    }

    func totalPendingSuggestionCount() throws -> Int {
        try review.totalPendingSuggestionCount()
    }

    func tagOverviews() throws -> [SuggestionTagOverview] {
        let tags = try tags.listTags(includeArchived: false)
        return try tags.map { tag in
            let samples = try review.sampleCounts(tagID: tag.id)
            let pending = try review.pendingCount(tagID: tag.id)
            let job = try review.activeSuggestionJob(tagID: tag.id)
            let status = mapTaskStatus(tag: tag, samples: samples, job: job)
            let checkpoint = try job.flatMap { try FullLibrarySuggestionsCodec.checkpoint(from: $0.checkpoint) }
            let hasModel = try review.tagHasCurrentModel(tagID: tag.id)
            let isStandard = try review.tagIsStandard(tagID: tag.id)
            let missingPositive = max(0, 2 - samples.accepted)
            let missingNegative = max(0, 2 - samples.rejected)
            let samplesReady = missingPositive == 0 && missingNegative == 0
            let canGenerate = !isStandard && samplesReady && !hasModel && job == nil
            let canUpdate = !isStandard && samplesReady && hasModel && job == nil
            return SuggestionTagOverview(
                id: tag.id,
                displayName: tag.displayName,
                acceptedSampleCount: samples.accepted,
                rejectedSampleCount: samples.rejected,
                pendingSuggestionCount: pending,
                taskStatus: status,
                checkedCount: checkpoint?.checkedCount ?? job?.progress.completed ?? 0,
                totalCount: job?.progress.total,
                skippedCount: checkpoint?.skippedCount ?? 0,
                missingPositiveCount: missingPositive,
                missingNegativeCount: missingNegative,
                canGenerate: canGenerate,
                canUpdate: canUpdate,
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

    func fetchReviewQueue(
        tagID: UUID,
        cursor: ReviewQueueCursor?,
        limit: Int
    ) throws -> ReviewQueuePage {
        try review.fetchReviewQueuePage(tagID: tagID, cursor: cursor, limit: limit)
    }

    func pendingSuggestionsForAsset(assetID: UUID) throws -> [AssetPendingSuggestion] {
        try review.pendingSuggestionsForAsset(assetID: assetID)
    }

    func personalSuggestionCandidates(
        afterAssetID: UUID?,
        limit: Int
    ) throws -> [PersonalSuggestionCandidate] {
        try review.personalSuggestionCandidates(afterAssetID: afterAssetID, limit: limit)
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

    func invalidatePersonalSuggestionBundle() throws {
        try review.invalidatePersonalSuggestionBundle()
    }

    func enqueueFullLibrarySuggestions(
        tagID: UUID,
        mode: PersonalizationReviewEnqueueMode
    ) throws -> UUID {
        _ = mode
        let samples = try review.fetchFrozenSampleIdentities(tagID: tagID)
        guard samples.positives.count >= 2, samples.negatives.count >= 2 else {
            let accepted = samples.positives.count
            let rejected = samples.negatives.count
            throw PersonalizationReviewError.insufficientSamples(
                positiveMissing: max(0, 2 - accepted),
                negativeMissing: max(0, 2 - rejected)
            )
        }
        if let job = try review.activeSuggestionJob(tagID: tagID),
           !job.state.isTerminal
        {
            throw PersonalizationReviewError.activeJobConflict
        }
        let sourceIDs = try review.activePersonalizationSourceIDs()
        guard !sourceIDs.isEmpty else {
            throw PersonalizationReviewError.persistenceFailure
        }
        let modelRevision = try review.nextModelRevision(tagID: tagID)
        let jobID = UUID()
        let command = try FullLibrarySuggestionsJobEnqueue.makeEnqueueCommand(
            jobID: jobID,
            tagID: tagID,
            sourceIDs: sourceIDs,
            catalogCutoffMs: clock.nowMs,
            modelRevision: modelRevision,
            frozenPositiveSamples: samples.positives,
            frozenNegativeSamples: samples.negatives,
            notBeforeMs: clock.nowMs
        )
        do {
            _ = try queue.enqueue(command)
        } catch JobQueueError.activeCoalescingConflict {
            throw PersonalizationReviewError.activeJobConflict
        }
        return jobID
    }

    func enqueuePersonalLibrarySuggestions(
        capability: PersonalModelSuggestionCapability
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
                    WHERE kind = ?
                        AND state IN ('pending', 'running', 'paused', 'retryableFailed')
                    ORDER BY created_at_ms DESC, id DESC
                    LIMIT 1
                    """,
                    arguments: [PersonalLibrarySuggestionsJobFactory.kind]
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
                let sourceIDs = try review.activePersonalizationSourceIDs(in: db)
                guard !sourceIDs.isEmpty else {
                    throw PersonalizationReviewError.persistenceFailure
                }
                let command = try PersonalLibrarySuggestionsJobEnqueue.makeEnqueueCommand(
                    jobID: jobID,
                    sourceIDs: sourceIDs,
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
        guard let job = try review.latestPersonalLibrarySuggestionJob() else { return nil }
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
        target: StandardModelSuggestionTarget
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
                    WHERE kind = ?
                        AND state IN ('pending', 'running', 'paused', 'retryableFailed')
                    ORDER BY created_at_ms DESC, id DESC
                    LIMIT 1
                    """,
                    arguments: [StandardLibrarySuggestionsJobFactory.kind]
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
                let sourceIDs = try review.activePersonalizationSourceIDs(in: db)
                guard !sourceIDs.isEmpty else {
                    throw PersonalizationReviewError.persistenceFailure
                }
                let command = try StandardLibrarySuggestionsJobEnqueue.makeEnqueueCommand(
                    jobID: jobID,
                    sourceIDs: sourceIDs,
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
        guard let job = try review.latestStandardLibrarySuggestionJob() else { return nil }
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
        _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: .cancel))
    }

    func runPendingSuggestionJobs(maxSteps: Int? = nil) throws -> Bool {
        try queue.settleRetryableJobs()
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
        let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ", ")
        let nextNotBeforeMs: Int64? = try database.pool.read { db in
            try Int64.fetchOne(
                db,
                sql: """
                SELECT MIN(not_before_ms) FROM job
                WHERE kind IN (\(placeholders))
                    AND state = 'retryableFailed'
                    AND attempts < max_attempts
                """,
                arguments: StatementArguments(kinds)
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
