import Foundation
import GRDB

private struct FullLibrarySuggestionsSafeBoundaryReached: Error {
    let snapshot: JobRecordSnapshot
}

struct FullLibrarySuggestionsHandlerDependencies: Sendable {
    let database: CatalogDatabase
    let queue: GRDBJobQueue
    let featureLoader: any SyncFeatureVectorLoading
    let clock: any JobClock
    var minimumScoreForTag: (@Sendable (UUID) throws -> Double)? = nil
    var publishFailureInjector: (@Sendable () throws -> Void)?
    var beforeEachBatch: (@Sendable (Int) -> Void)?
}

struct FullLibrarySuggestionsHandler: LeaseBoundJobHandler, Sendable {
    let dependencies: FullLibrarySuggestionsHandlerDependencies

    var kind: String { FullLibrarySuggestionsJobFactory.kind }
    var supportedPayloadVersions: Set<Int> { [FullLibrarySuggestionsJobFactory.payloadVersion] }
    var supportedCheckpointVersions: Set<Int> { [FullLibrarySuggestionsJobFactory.checkpointVersion] }

    func execute(
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?
    ) -> JobHandlerExecutionResult {
        failure(.personalizationPersistenceFailure, checkpoint: checkpoint, progress: nil)
    }

    func execute(
        lease: JobLeaseToken,
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?,
        context: JobLeaseExecutionContext
    ) throws -> JobHandlerExecutionResult {
        do {
            return try executeThrowing(
                lease: lease,
                payloadVersion: payloadVersion,
                payload: payload,
                checkpoint: checkpoint,
                leaseDurationMs: context.leaseDurationMs
            )
        } catch let error as FullLibrarySuggestionsCodecError {
            switch error {
            case .invalidPayload:
                return failure(.personalizationPayloadInvalid, checkpoint: checkpoint, progress: nil)
            case .invalidCheckpoint:
                return failure(.personalizationCheckpointInvalid, checkpoint: checkpoint, progress: nil)
            }
        } catch let error as PersonalizationCatalogError {
            switch error {
            case .archivedTag:
                return failure(.personalizationTagArchived, checkpoint: checkpoint, progress: nil)
            default:
                return retryableFailure(
                    .personalizationPersistenceFailure,
                    checkpoint: preservedRetryCheckpoint(from: checkpoint),
                    progress: nil
                )
            }
        } catch is PersonalizedSuggestionError {
            return failure(.personalizationInsufficientSamples, checkpoint: checkpoint, progress: nil)
        } catch let error as FeaturePrintError where isRetryableFeatureError(error) {
            return retryableFailure(
                .personalizationPersistenceFailure,
                checkpoint: preservedRetryCheckpoint(from: checkpoint),
                progress: nil
            )
        } catch {
            return retryableFailure(
                .personalizationPersistenceFailure,
                checkpoint: preservedRetryCheckpoint(from: checkpoint),
                progress: nil
            )
        }
    }

    private func executeThrowing(
        lease: JobLeaseToken,
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?,
        leaseDurationMs: Int64
    ) throws -> JobHandlerExecutionResult {
        guard payloadVersion == FullLibrarySuggestionsJobFactory.payloadVersion else {
            return failure(.personalizationPayloadInvalid, checkpoint: checkpoint, progress: nil)
        }
        let decodedPayload = try FullLibrarySuggestionsCodec.decodePayload(payload)
        var state = try FullLibrarySuggestionsCodec.checkpoint(from: checkpoint)
        let review = GRDBPersonalizationReviewRepository(database: dependencies.database)
        let catalog = GRDBPersonalizationRepository(database: dependencies.database)
        try markTrainingRunRunning(jobID: lease.jobID)
        var firstBatchPublished = state.firstBatchPublished
        let modelRevision = decodedPayload.modelRevision
        let minimumScore = try dependencies.minimumScoreForTag?(decodedPayload.tagID) ?? 0

        guard try review.tagIsActive(decodedPayload.tagID) else {
            return failure(.personalizationTagArchived, checkpoint: checkpoint, progress: nil)
        }

        let total = try review.frozenAssetTotal(
            sourceIDs: decodedPayload.sourceIDs,
            catalogCutoffMs: decodedPayload.catalogCutoffMs
        )
        let heartbeatIntervalMs = max(1, leaseDurationMs / 2)
        var lastLeaseRenewedAtMs = dependencies.clock.nowMs
        func heartbeatIfNeeded() throws {
            let nowMs = dependencies.clock.nowMs
            guard nowMs - lastLeaseRenewedAtMs >= heartbeatIntervalMs else { return }
            let snapshot = try dependencies.queue.commitLeaseProtectedBatch(
                input: SafeBatchCommitInput(
                    lease: lease,
                    outcome: .continue,
                    checkpoint: try FullLibrarySuggestionsCodec.jobCheckpoint(from: state),
                    progress: JobProgress(completed: state.checkedCount, total: total),
                    leaseDurationMs: leaseDurationMs
                )
            ) { _ in }
            lastLeaseRenewedAtMs = nowMs
            guard snapshot.state == .running else {
                throw FullLibrarySuggestionsSafeBoundaryReached(snapshot: snapshot)
            }
        }
        var batchNumber = 0

        do {
            let scoring = try prepareScoring(
                payload: decodedPayload,
                heartbeat: heartbeatIfNeeded
            )
            while true {
            dependencies.beforeEachBatch?(batchNumber)
            if try shouldStopForControl(jobID: lease.jobID) {
                let jobCheckpoint = try FullLibrarySuggestionsCodec.jobCheckpoint(from: state)
                return JobHandlerExecutionResult(
                    outcome: .continue,
                    checkpoint: jobCheckpoint,
                    progress: JobProgress(completed: state.checkedCount, total: total),
                    settledByHandler: false
                )
            }

            let batch = try review.frozenAssetBatch(
                sourceIDs: decodedPayload.sourceIDs,
                catalogCutoffMs: decodedPayload.catalogCutoffMs,
                afterAssetID: state.lastAssetID,
                limit: FullLibrarySuggestionsJobFactory.scanBatchSize
            )
            if batch.isEmpty {
                let jobCheckpoint = try FullLibrarySuggestionsCodec.jobCheckpoint(from: state)
                let progress = JobProgress(completed: state.checkedCount, total: total)
                let snapshot = try dependencies.queue.commitLeaseProtectedBatch(
                    input: SafeBatchCommitInput(
                        lease: lease,
                        outcome: .completed,
                        checkpoint: jobCheckpoint,
                        progress: progress,
                        leaseDurationMs: leaseDurationMs
                    )
                ) { db in
                    try completeTrainingRun(
                        jobID: lease.jobID,
                        payload: decodedPayload,
                        state: state,
                        published: false,
                        on: db
                    )
                }
                lastLeaseRenewedAtMs = dependencies.clock.nowMs
                if let stop = stopResultIfNeeded(snapshot: snapshot, checkpoint: jobCheckpoint, progress: progress) {
                    return stop
                }
                return JobHandlerExecutionResult(
                    outcome: .completed,
                    checkpoint: jobCheckpoint,
                    progress: progress,
                    settledByHandler: true
                )
            }

            var checkedDelta = 0
            var eligibleDelta = 0
            var suggestedDelta = 0
            var skippedDelta = 0
            var predictions: [PredictionRegistration] = []
            var batchAssetIDs: [UUID] = []
            let catalogCutoffMs = decodedPayload.catalogCutoffMs

            for assetID in batch {
                checkedDelta += 1
                guard let context = try review.frozenAssetProcessingContext(
                    tagID: decodedPayload.tagID,
                    assetID: assetID
                ) else {
                    skippedDelta += 1
                    continue
                }
                if context.hasDecision {
                    skippedDelta += 1
                    continue
                }
                if context.recordUpdatedAtMs > catalogCutoffMs {
                    skippedDelta += 1
                    continue
                }
                if context.locatorState != AssetLocatorState.current.rawValue {
                    skippedDelta += 1
                    continue
                }
                if context.sourceState != SourceState.active.rawValue {
                    skippedDelta += 1
                    continue
                }
                if context.availability != AssetAvailability.available.rawValue {
                    skippedDelta += 1
                    continue
                }

                eligibleDelta += 1
                batchAssetIDs.append(assetID)
                do {
                    let feature = try loadFeature(
                        assetID: assetID,
                        heartbeat: heartbeatIfNeeded
                    )
                    guard feature.identity.contentRevision == context.contentRevision else {
                        skippedDelta += 1
                        continue
                    }
                    let values = try PersonalizedSuggestionScoringCore.decode(feature)
                    guard values.count == scoring.dimension else {
                        skippedDelta += 1
                        continue
                    }
                    let score = PersonalizedSuggestionScoringCore.scoreCandidate(
                        candidateValues: values,
                        positiveSamples: scoring.positiveValues,
                        negativeSamples: scoring.negativeValues,
                        neighborCount: scoring.neighborCount
                    )
                    if score > minimumScore {
                        predictions.append(
                            PredictionRegistration(
                                assetID: assetID,
                                contentRevision: context.contentRevision,
                                score: score
                            )
                        )
                        suggestedDelta += 1
                    }
                } catch let error as FeaturePrintError where isSkippableFeatureError(error) {
                    skippedDelta += 1
                } catch let error as FeaturePrintError where isRetryableFeatureError(error) {
                    return try retryableFailureWithCommittedState(state: state, total: total)
                } catch let error as PersonalizationCatalogError {
                    throw error
                } catch {
                    throw error
                }
            }

            let nextState = FullLibrarySuggestionsCheckpoint(
                lastAssetID: batch.last,
                firstBatchPublished: true,
                modelRevision: modelRevision,
                checkedCount: state.checkedCount + checkedDelta,
                eligibleCount: state.eligibleCount + eligibleDelta,
                suggestedCount: state.suggestedCount + suggestedDelta,
                skippedCount: state.skippedCount + skippedDelta
            )
            let progress = JobProgress(completed: nextState.checkedCount, total: total)
            let jobCheckpoint = try FullLibrarySuggestionsCodec.jobCheckpoint(from: nextState)
            let createdAtMs = dependencies.clock.nowMs
            let completed = nextState.checkedCount >= total

            let snapshot: JobRecordSnapshot
            do {
                if !firstBatchPublished {
                    snapshot = try dependencies.queue.commitLeaseProtectedBatch(
                        input: SafeBatchCommitInput(
                            lease: lease,
                            outcome: completed ? .completed : .continue,
                            checkpoint: jobCheckpoint,
                            progress: progress,
                            leaseDurationMs: leaseDurationMs
                        )
                    ) { db in
                        try dependencies.publishFailureInjector?()
                        try catalog.publishModelRevision(
                            ModelRevisionRegistration(
                                tagID: decodedPayload.tagID,
                                revision: modelRevision,
                                threshold: minimumScore,
                                neighborCount: scoring.neighborCount,
                                sampleBudgetPerRole: 12,
                                samples: scoring.sampleRegistrations,
                                createdAtMs: createdAtMs
                            ),
                            on: db
                        )
                        if !batchAssetIDs.isEmpty {
                            try catalog.replacePredictions(
                                tagID: decodedPayload.tagID,
                                modelRevision: modelRevision,
                                candidateAssetIDs: batchAssetIDs,
                                predictions: predictions,
                                createdAtMs: createdAtMs,
                                on: db
                            )
                        }
                        try catalog.retainTopPendingPredictions(
                            tagID: decodedPayload.tagID,
                            modelRevision: modelRevision,
                            limit: FullLibrarySuggestionsJobFactory.maxPendingSuggestionsPerTag,
                            on: db
                        )
                        if completed {
                            try completeTrainingRun(
                                jobID: lease.jobID,
                                payload: decodedPayload,
                                state: nextState,
                                published: true,
                                on: db
                            )
                        } else {
                            try recordPartialTrainingRunPublication(
                                jobID: lease.jobID,
                                payload: decodedPayload,
                                state: nextState,
                                on: db
                            )
                        }
                    }
                    firstBatchPublished = true
                } else if !predictions.isEmpty {
                    snapshot = try dependencies.queue.commitLeaseProtectedBatch(
                        input: SafeBatchCommitInput(
                            lease: lease,
                            outcome: completed ? .completed : .continue,
                            checkpoint: jobCheckpoint,
                            progress: progress,
                            leaseDurationMs: leaseDurationMs
                        )
                    ) { db in
                        try catalog.appendPredictions(
                            tagID: decodedPayload.tagID,
                            modelRevision: modelRevision,
                            predictions: predictions,
                            createdAtMs: createdAtMs,
                            on: db
                        )
                        try catalog.retainTopPendingPredictions(
                            tagID: decodedPayload.tagID,
                            modelRevision: modelRevision,
                            limit: FullLibrarySuggestionsJobFactory.maxPendingSuggestionsPerTag,
                            on: db
                        )
                        if completed {
                            try completeTrainingRun(
                                jobID: lease.jobID,
                                payload: decodedPayload,
                                state: nextState,
                                published: true,
                                on: db
                            )
                        } else {
                            try recordPartialTrainingRunPublication(
                                jobID: lease.jobID,
                                payload: decodedPayload,
                                state: nextState,
                                on: db
                            )
                        }
                    }
                } else {
                    snapshot = try dependencies.queue.commitLeaseProtectedBatch(
                        input: SafeBatchCommitInput(
                            lease: lease,
                            outcome: completed ? .completed : .continue,
                            checkpoint: jobCheckpoint,
                            progress: progress,
                            leaseDurationMs: leaseDurationMs
                        )
                    ) { db in
                        if completed {
                            try completeTrainingRun(
                                jobID: lease.jobID,
                                payload: decodedPayload,
                                state: nextState,
                                published: true,
                                on: db
                            )
                        } else {
                            try recordPartialTrainingRunPublication(
                                jobID: lease.jobID,
                                payload: decodedPayload,
                                state: nextState,
                                on: db
                            )
                        }
                    }
                }
            } catch let error as FeaturePrintError where isRetryableFeatureError(error) {
                let preservedCheckpoint = try FullLibrarySuggestionsCodec.jobCheckpoint(from: state)
                return retryableFailure(
                    .personalizationPersistenceFailure,
                    checkpoint: preservedCheckpoint,
                    progress: JobProgress(completed: state.checkedCount, total: total)
                )
            } catch is PersonalizationCatalogError {
                let preservedCheckpoint = try FullLibrarySuggestionsCodec.jobCheckpoint(from: state)
                return retryableFailure(
                    .personalizationPersistenceFailure,
                    checkpoint: preservedCheckpoint,
                    progress: JobProgress(completed: state.checkedCount, total: total)
                )
            }

            lastLeaseRenewedAtMs = dependencies.clock.nowMs
            state = nextState
            batchNumber += 1
            if let stop = stopResultIfNeeded(snapshot: snapshot, checkpoint: jobCheckpoint, progress: progress) {
                return stop
            }
            if completed {
                return JobHandlerExecutionResult(
                    outcome: .completed,
                    checkpoint: jobCheckpoint,
                    progress: progress,
                    settledByHandler: true
                )
            }
            }
        } catch let boundary as FullLibrarySuggestionsSafeBoundaryReached {
            let jobCheckpoint = try FullLibrarySuggestionsCodec.jobCheckpoint(from: state)
            let progress = JobProgress(completed: state.checkedCount, total: total)
            guard let stop = stopResultIfNeeded(
                snapshot: boundary.snapshot,
                checkpoint: jobCheckpoint,
                progress: progress
            ) else {
                throw PersonalizationCatalogError.persistenceFailure
            }
            return stop
        } catch let error as FeaturePrintError where isRetryableFeatureError(error) {
            return try retryableFailureWithCommittedState(state: state, total: total)
        } catch is PersonalizationCatalogError {
            return try retryableFailureWithCommittedState(state: state, total: total)
        }
    }

    private func preservedRetryCheckpoint(from checkpoint: JobCheckpoint?) -> JobCheckpoint? {
        if let checkpoint {
            return checkpoint
        }
        return try? FullLibrarySuggestionsCodec.jobCheckpoint(from: .empty)
    }

    private func markTrainingRunRunning(jobID: UUID) throws {
        let runs = GRDBTrainingRunRepository(database: dependencies.database)
        try dependencies.database.pool.write { db in
            guard let run = try runs.fetch(jobID: jobID, on: db), run.state == .queued else {
                return
            }
            try runs.update(
                id: run.id,
                state: .running,
                startedAtMs: dependencies.clock.nowMs,
                on: db
            )
        }
    }

    private func completeTrainingRun(
        jobID: UUID,
        payload: FullLibrarySuggestionsPayload,
        state: FullLibrarySuggestionsCheckpoint,
        published: Bool,
        on db: Database
    ) throws {
        let runs = GRDBTrainingRunRepository(database: dependencies.database)
        guard let run = try runs.fetch(jobID: jobID, on: db), !run.state.isTerminal else {
            return
        }
        try runs.update(
            id: run.id,
            state: .succeeded,
            finishedAtMs: dependencies.clock.nowMs,
            metricsJSON: try TrainingRunJSON.encode([
                "checkedCount": state.checkedCount,
                "eligibleCount": state.eligibleCount,
                "suggestedCount": state.suggestedCount,
                "skippedCount": state.skippedCount,
            ]),
            artifactKind: published ? "tagModelRevision" : nil,
            artifactRef: published
                ? "tag_model/\(payload.tagID.uuidString.lowercased())/\(payload.modelRevision)"
                : nil,
            resultSummaryJSON: try trainingRunResultSummary(
                payload: payload,
                state: state,
                published: published,
                partial: false
            ),
            on: db
        )
    }

    private func recordPartialTrainingRunPublication(
        jobID: UUID,
        payload: FullLibrarySuggestionsPayload,
        state: FullLibrarySuggestionsCheckpoint,
        on db: Database
    ) throws {
        let runs = GRDBTrainingRunRepository(database: dependencies.database)
        guard let run = try runs.fetch(jobID: jobID, on: db), !run.state.isTerminal else {
            return
        }
        try runs.update(
            id: run.id,
            state: .running,
            metricsJSON: try TrainingRunJSON.encode([
                "checkedCount": state.checkedCount,
                "eligibleCount": state.eligibleCount,
                "suggestedCount": state.suggestedCount,
                "skippedCount": state.skippedCount,
            ]),
            artifactKind: "tagModelRevision",
            artifactRef: "tag_model/\(payload.tagID.uuidString.lowercased())/\(payload.modelRevision)",
            resultSummaryJSON: try trainingRunResultSummary(
                payload: payload,
                state: state,
                published: true,
                partial: true
            ),
            on: db
        )
    }

    private func trainingRunResultSummary(
        payload: FullLibrarySuggestionsPayload,
        state: FullLibrarySuggestionsCheckpoint,
        published: Bool,
        partial: Bool
    ) throws -> String {
        try TrainingRunJSON.encode([
            "published": published,
            "partial": partial,
            "successfulTagCount": published ? 1 : 0,
            "positiveSampleCount": payload.frozenPositiveSamples.count,
            "negativeSampleCount": payload.frozenNegativeSamples.count,
            "checkedCount": state.checkedCount,
            "eligibleCount": state.eligibleCount,
            "suggestedCount": state.suggestedCount,
            "skippedCount": state.skippedCount,
        ])
    }

    private func retryableFailureWithCommittedState(
        state: FullLibrarySuggestionsCheckpoint,
        total: Int
    ) throws -> JobHandlerExecutionResult {
        let preservedCheckpoint = try FullLibrarySuggestionsCodec.jobCheckpoint(from: state)
        return retryableFailure(
            .personalizationPersistenceFailure,
            checkpoint: preservedCheckpoint,
            progress: JobProgress(completed: state.checkedCount, total: total)
        )
    }

    private struct ScoringContext {
        let dimension: Int
        let neighborCount: Int
        let positiveValues: [[Float]]
        let negativeValues: [[Float]]
        let sampleRegistrations: [ModelSampleRegistration]
    }

    private func prepareScoring(
        payload: FullLibrarySuggestionsPayload,
        heartbeat: () throws -> Void
    ) throws -> ScoringContext {
        var loadedPositives: [PersonalizedSuggestionScoringCore.LoadedSample] = []
        var loadedNegatives: [PersonalizedSuggestionScoringCore.LoadedSample] = []

        for sample in payload.frozenPositiveSamples {
            let feature = try loadFeature(assetID: sample.assetID, heartbeat: heartbeat)
            guard feature.identity.contentRevision == sample.contentRevision else { continue }
            loadedPositives.append(
                PersonalizedSuggestionScoringCore.LoadedSample(
                    assetID: sample.assetID,
                    contentRevision: sample.contentRevision,
                    role: .positive,
                    values: try PersonalizedSuggestionScoringCore.decode(feature)
                )
            )
        }
        for sample in payload.frozenNegativeSamples {
            let feature = try loadFeature(assetID: sample.assetID, heartbeat: heartbeat)
            guard feature.identity.contentRevision == sample.contentRevision else { continue }
            loadedNegatives.append(
                PersonalizedSuggestionScoringCore.LoadedSample(
                    assetID: sample.assetID,
                    contentRevision: sample.contentRevision,
                    role: .negative,
                    values: try PersonalizedSuggestionScoringCore.decode(feature)
                )
            )
        }

        guard loadedPositives.count >= 2, loadedNegatives.count >= 2 else {
            throw PersonalizedSuggestionError.insufficientSamples
        }
        let dimension = loadedPositives[0].values.count
        guard dimension > 0,
              (loadedPositives + loadedNegatives).allSatisfy({ $0.values.count == dimension })
        else {
            throw PersonalizedSuggestionError.inconsistentFeatureDimensions
        }
        let neighborCount = min(3, loadedPositives.count, loadedNegatives.count)
        return ScoringContext(
            dimension: dimension,
            neighborCount: neighborCount,
            positiveValues: loadedPositives.map(\.values),
            negativeValues: loadedNegatives.map(\.values),
            sampleRegistrations: PersonalizedSuggestionScoringCore.registrations(
                positives: loadedPositives,
                negatives: loadedNegatives
            )
        )
    }

    private func loadFeature(
        assetID: UUID,
        heartbeat: () throws -> Void
    ) throws -> FeatureVectorPayload {
        try heartbeat()
        let result = Result {
            try dependencies.featureLoader.loadOrGenerateSync(assetID: assetID)
        }
        try heartbeat()
        return try result.get()
    }

    private func shouldStopForControl(jobID: UUID) throws -> Bool {
        let snapshot = try dependencies.queue.fetchJob(id: jobID)
        return snapshot.controlRequest != .none
    }

    private func stopResultIfNeeded(
        snapshot: JobRecordSnapshot,
        checkpoint: JobCheckpoint,
        progress: JobProgress
    ) -> JobHandlerExecutionResult? {
        switch snapshot.state {
        case .running:
            return nil
        case .paused:
            return JobHandlerExecutionResult(
                outcome: .continue,
                checkpoint: checkpoint,
                progress: progress,
                settledByHandler: true
            )
        case .cancelled:
            return JobHandlerExecutionResult(
                outcome: .completed,
                checkpoint: checkpoint,
                progress: progress,
                settledByHandler: true
            )
        case .completed:
            return JobHandlerExecutionResult(
                outcome: .completed,
                checkpoint: checkpoint,
                progress: progress,
                settledByHandler: true
            )
        case .retryableFailed:
            return JobHandlerExecutionResult(
                outcome: .retryableFailure(code: snapshot.lastErrorCode ?? .personalizationPersistenceFailure),
                checkpoint: checkpoint,
                progress: progress,
                settledByHandler: true
            )
        case .terminalFailed:
            return JobHandlerExecutionResult(
                outcome: .nonRetryableFailure(code: snapshot.lastErrorCode ?? .personalizationPersistenceFailure),
                checkpoint: checkpoint,
                progress: progress,
                settledByHandler: true
            )
        case .pending:
            return JobHandlerExecutionResult(
                outcome: .continue,
                checkpoint: checkpoint,
                progress: progress,
                settledByHandler: true
            )
        }
    }

    private func isSkippableFeatureError(_ error: FeaturePrintError) -> Bool {
        switch error {
        case .assetNotFound, .assetIneligible, .authorizationRequired, .sourceUnavailable,
             .sourceChanged, .decodeFailed, .generationFailed:
            return true
        case .cacheUnsafePath, .cachePersistenceFailed:
            return false
        }
    }

    private func isRetryableFeatureError(_ error: FeaturePrintError) -> Bool {
        switch error {
        case .cacheUnsafePath, .cachePersistenceFailed:
            return true
        default:
            return false
        }
    }

    private func failure(
        _ code: JobSafeErrorCode,
        checkpoint: JobCheckpoint?,
        progress: JobProgress?
    ) -> JobHandlerExecutionResult {
        JobHandlerExecutionResult(
            outcome: .nonRetryableFailure(code: code),
            checkpoint: checkpoint,
            progress: progress ?? JobProgress(completed: 0, total: nil)
        )
    }

    private func retryableFailure(
        _ code: JobSafeErrorCode,
        checkpoint: JobCheckpoint?,
        progress: JobProgress?
    ) -> JobHandlerExecutionResult {
        JobHandlerExecutionResult(
            outcome: .retryableFailure(code: code),
            checkpoint: checkpoint,
            progress: progress ?? JobProgress(completed: 0, total: nil)
        )
    }
}
