import Foundation
import GRDB

struct FullLibrarySuggestionsHandlerDependencies: Sendable {
    let database: CatalogDatabase
    let queue: GRDBJobQueue
    let featureLoader: any SyncFeatureVectorLoading
    let clock: any JobClock
    var publishFailureInjector: (@Sendable () throws -> Void)?
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
        failure(.personalizationPersistenceFailure)
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
                checkpoint: checkpoint
            )
        } catch let error as FullLibrarySuggestionsCodecError {
            switch error {
            case .invalidPayload:
                return failure(.personalizationPayloadInvalid)
            case .invalidCheckpoint:
                return failure(.personalizationCheckpointInvalid)
            }
        } catch let error as PersonalizationCatalogError {
            switch error {
            case .archivedTag:
                return failure(.personalizationTagArchived)
            default:
                return failure(.personalizationPersistenceFailure)
            }
        } catch is PersonalizedSuggestionError {
            return failure(.personalizationInsufficientSamples)
        } catch {
            return failure(.personalizationPersistenceFailure)
        }
    }

    private func executeThrowing(
        lease: JobLeaseToken,
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?
    ) throws -> JobHandlerExecutionResult {
        guard payloadVersion == FullLibrarySuggestionsJobFactory.payloadVersion else {
            return failure(.personalizationPayloadInvalid)
        }
        let decodedPayload = try FullLibrarySuggestionsCodec.decodePayload(payload)
        var state = try FullLibrarySuggestionsCodec.checkpoint(from: checkpoint)
        let review = GRDBPersonalizationReviewRepository(database: dependencies.database)
        let catalog = GRDBPersonalizationRepository(database: dependencies.database)
        var firstBatchPublished = state.firstBatchPublished

        guard try review.tagIsActive(decodedPayload.tagID) else {
            return failure(.personalizationTagArchived)
        }

        if state.frozenPositiveAssetIDs.isEmpty, state.frozenNegativeAssetIDs.isEmpty {
            let samples = try review.fetchFrozenSamples(tagID: decodedPayload.tagID)
            guard samples.positives.count >= 2, samples.negatives.count >= 2 else {
                return failure(.personalizationInsufficientSamples)
            }
            state = FullLibrarySuggestionsCheckpoint(
                lastAssetID: state.lastAssetID,
                firstBatchPublished: state.firstBatchPublished,
                modelRevision: state.modelRevision,
                checkedCount: state.checkedCount,
                eligibleCount: state.eligibleCount,
                suggestedCount: state.suggestedCount,
                skippedCount: state.skippedCount,
                frozenPositiveAssetIDs: samples.positives.map(\.assetID),
                frozenNegativeAssetIDs: samples.negatives.map(\.assetID)
            )
        }

        let total = try review.frozenAssetTotal(
            sourceIDs: decodedPayload.sourceIDs,
            catalogCutoffMs: decodedPayload.catalogCutoffMs
        )
        let scoring = try prepareScoring(
            tagID: decodedPayload.tagID,
            checkpoint: state,
            review: review
        )
        let modelRevision: Int
        if let revision = state.modelRevision {
            modelRevision = revision
        } else {
            modelRevision = try review.nextModelRevision(tagID: decodedPayload.tagID)
        }

        while true {
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
                _ = try dependencies.queue.commitLeaseProtectedBatch(
                    input: SafeBatchCommitInput(
                        lease: lease,
                        outcome: .completed,
                        checkpoint: jobCheckpoint,
                        progress: JobProgress(completed: state.checkedCount, total: total),
                        leaseDurationMs: 60_000
                    )
                ) { _ in }
                return JobHandlerExecutionResult(
                    outcome: .completed,
                    checkpoint: jobCheckpoint,
                    progress: JobProgress(completed: state.checkedCount, total: total),
                    settledByHandler: true
                )
            }

            var checkedDelta = 0
            var eligibleDelta = 0
            var suggestedDelta = 0
            var skippedDelta = 0
            var predictions: [PredictionRegistration] = []
            var batchAssetIDs: [UUID] = []

            for assetID in batch {
                checkedDelta += 1
                if let candidate = try review.candidateRevision(tagID: decodedPayload.tagID, assetID: assetID) {
                    eligibleDelta += 1
                    batchAssetIDs.append(assetID)
                    do {
                        let feature = try dependencies.featureLoader.loadOrGenerateSync(assetID: assetID)
                        guard feature.identity.contentRevision == candidate.contentRevision else {
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
                        if score > 0 {
                            predictions.append(
                                PredictionRegistration(
                                    assetID: assetID,
                                    contentRevision: candidate.contentRevision,
                                    score: score
                                )
                            )
                            suggestedDelta += 1
                        }
                    } catch {
                        skippedDelta += 1
                    }
                } else {
                    skippedDelta += 1
                }
            }

            state = FullLibrarySuggestionsCheckpoint(
                lastAssetID: batch.last,
                firstBatchPublished: true,
                modelRevision: modelRevision,
                checkedCount: state.checkedCount + checkedDelta,
                eligibleCount: state.eligibleCount + eligibleDelta,
                suggestedCount: state.suggestedCount + suggestedDelta,
                skippedCount: state.skippedCount + skippedDelta,
                frozenPositiveAssetIDs: state.frozenPositiveAssetIDs,
                frozenNegativeAssetIDs: state.frozenNegativeAssetIDs
            )
            let progress = JobProgress(completed: state.checkedCount, total: total)
            let jobCheckpoint = try FullLibrarySuggestionsCodec.jobCheckpoint(from: state)
            let createdAtMs = dependencies.clock.nowMs
            let completed = state.checkedCount >= total

            if !firstBatchPublished {
                _ = try dependencies.queue.commitLeaseProtectedBatch(
                    input: SafeBatchCommitInput(
                        lease: lease,
                        outcome: completed ? .completed : .continue,
                        checkpoint: jobCheckpoint,
                        progress: progress,
                        leaseDurationMs: 60_000
                    )
                ) { db in
                    try dependencies.publishFailureInjector?()
                    try catalog.publishModelRevision(
                        ModelRevisionRegistration(
                            tagID: decodedPayload.tagID,
                            revision: modelRevision,
                            threshold: 0,
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
                }
                firstBatchPublished = true
            } else if !predictions.isEmpty {
                _ = try dependencies.queue.commitLeaseProtectedBatch(
                    input: SafeBatchCommitInput(
                        lease: lease,
                        outcome: completed ? .completed : .continue,
                        checkpoint: jobCheckpoint,
                        progress: progress,
                        leaseDurationMs: 60_000
                    )
                ) { db in
                    try catalog.appendPredictions(
                        tagID: decodedPayload.tagID,
                        modelRevision: modelRevision,
                        predictions: predictions,
                        createdAtMs: createdAtMs,
                        on: db
                    )
                }
            } else {
                _ = try dependencies.queue.commitLeaseProtectedBatch(
                    input: SafeBatchCommitInput(
                        lease: lease,
                        outcome: completed ? .completed : .continue,
                        checkpoint: jobCheckpoint,
                        progress: progress,
                        leaseDurationMs: 60_000
                    )
                ) { _ in }
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
    }

    private struct ScoringContext {
        let dimension: Int
        let neighborCount: Int
        let positiveValues: [[Float]]
        let negativeValues: [[Float]]
        let sampleRegistrations: [ModelSampleRegistration]
    }

    private func prepareScoring(
        tagID: UUID,
        checkpoint: FullLibrarySuggestionsCheckpoint,
        review: GRDBPersonalizationReviewRepository
    ) throws -> ScoringContext {
        var loadedPositives: [PersonalizedSuggestionScoringCore.LoadedSample] = []
        var loadedNegatives: [PersonalizedSuggestionScoringCore.LoadedSample] = []

        for assetID in checkpoint.frozenPositiveAssetIDs {
            guard let revision = try sampleContentRevision(assetID: assetID) else { continue }
            let feature = try dependencies.featureLoader.loadOrGenerateSync(assetID: assetID)
            guard feature.identity.contentRevision == revision else { continue }
            loadedPositives.append(
                PersonalizedSuggestionScoringCore.LoadedSample(
                    assetID: assetID,
                    contentRevision: revision,
                    role: .positive,
                    values: try PersonalizedSuggestionScoringCore.decode(feature)
                )
            )
        }
        for assetID in checkpoint.frozenNegativeAssetIDs {
            guard let revision = try sampleContentRevision(assetID: assetID) else { continue }
            let feature = try dependencies.featureLoader.loadOrGenerateSync(assetID: assetID)
            guard feature.identity.contentRevision == revision else { continue }
            loadedNegatives.append(
                PersonalizedSuggestionScoringCore.LoadedSample(
                    assetID: assetID,
                    contentRevision: revision,
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

    private func sampleContentRevision(assetID: UUID) throws -> Int? {
        try dependencies.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT content_revision FROM asset WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }
    }

    private func shouldStopForControl(jobID: UUID) throws -> Bool {
        let snapshot = try dependencies.queue.fetchJob(id: jobID)
        return snapshot.controlRequest != .none
    }

    private func failure(_ code: JobSafeErrorCode) -> JobHandlerExecutionResult {
        JobHandlerExecutionResult(
            outcome: .nonRetryableFailure(code: code),
            checkpoint: nil,
            progress: JobProgress(completed: 0, total: nil)
        )
    }
}
