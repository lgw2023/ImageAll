import Foundation

struct PersonalizationReviewService: PersonalizationReviewPort, Sendable {
    let database: CatalogDatabase
    let queue: GRDBJobQueue
    let executionCoordinator: JobExecutionCoordinator
    let tags: GRDBTagCatalogRepository
    let clock: any JobClock

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
            let missingPositive = max(0, 2 - samples.accepted)
            let missingNegative = max(0, 2 - samples.rejected)
            let samplesReady = missingPositive == 0 && missingNegative == 0
            let canGenerate = samplesReady && !hasModel && job == nil
            let canUpdate = samplesReady && hasModel && job == nil
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
