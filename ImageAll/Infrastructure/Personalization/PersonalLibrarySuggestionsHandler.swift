import Foundation

protocol PersonalLibrarySuggestionImageLoading: Sendable {
    func loadPersonalSuggestionPreview(assetID: UUID) async throws -> Data
}

extension LibraryAssetImageLoader: PersonalLibrarySuggestionImageLoading {
    func loadPersonalSuggestionPreview(assetID: UUID) async throws -> Data {
        try await load(assetID: assetID, variant: .preview)
    }
}

struct PersonalLibrarySuggestionsHandlerDependencies: Sendable {
    let database: CatalogDatabase
    let queue: GRDBJobQueue
    let images: any PersonalLibrarySuggestionImageLoading
    let client: any LocalModelSuggestionClient
    let catalogScopeID: String
    let clock: any JobClock
    var publishFailureInjector: (@Sendable () throws -> Void)?
}

struct PersonalLibrarySuggestionsHandler: AsyncLeaseBoundJobHandler, Sendable {
    let dependencies: PersonalLibrarySuggestionsHandlerDependencies

    var kind: String { PersonalLibrarySuggestionsJobFactory.kind }
    var supportedPayloadVersions: Set<Int> { [PersonalLibrarySuggestionsJobFactory.payloadVersion] }
    var supportedCheckpointVersions: Set<Int> { [PersonalLibrarySuggestionsJobFactory.checkpointVersion] }

    func execute(
        payloadVersion _: Int,
        payload _: Data,
        checkpoint: JobCheckpoint?
    ) -> JobHandlerExecutionResult {
        retryableFailure(
            .personalizationPersistenceFailure,
            checkpoint: checkpoint,
            progress: JobProgress(completed: 0, total: nil)
        )
    }

    func executeAsync(
        lease: JobLeaseToken,
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?,
        context: JobLeaseExecutionContext
    ) async throws -> JobHandlerExecutionResult {
        guard payloadVersion == PersonalLibrarySuggestionsJobFactory.payloadVersion else {
            return terminalFailure(
                .personalizationPayloadInvalid,
                checkpoint: checkpoint,
                progress: JobProgress(completed: 0, total: nil)
            )
        }

        let decodedPayload: PersonalLibrarySuggestionsPayload
        let decodedCheckpoint: PersonalLibrarySuggestionsCheckpoint
        do {
            decodedPayload = try PersonalLibrarySuggestionsCodec.decodePayload(payload)
            decodedCheckpoint = try PersonalLibrarySuggestionsCodec.checkpoint(from: checkpoint)
        } catch let error as PersonalLibrarySuggestionsCodecError {
            switch error {
            case .invalidPayload:
                return terminalFailure(
                    .personalizationPayloadInvalid,
                    checkpoint: checkpoint,
                    progress: JobProgress(completed: 0, total: nil)
                )
            case .invalidCheckpoint:
                return terminalFailure(
                    .personalizationCheckpointInvalid,
                    checkpoint: checkpoint,
                    progress: JobProgress(completed: 0, total: nil)
                )
            }
        } catch {
            return terminalFailure(
                .personalizationPayloadInvalid,
                checkpoint: checkpoint,
                progress: JobProgress(completed: 0, total: nil)
            )
        }

        guard decodedPayload.capability.target.catalogScopeID == dependencies.catalogScopeID,
              decodedCheckpoint.capability == nil
                  || decodedCheckpoint.capability == decodedPayload.capability
        else {
            return terminalFailure(
                .personalizationCheckpointInvalid,
                checkpoint: checkpoint,
                progress: JobProgress(completed: decodedCheckpoint.checkedCount, total: nil)
            )
        }

        return try await executeValidated(
            lease: lease,
            payload: decodedPayload,
            initialCheckpoint: decodedCheckpoint,
            leaseDurationMs: context.leaseDurationMs
        )
    }
}

private extension PersonalLibrarySuggestionsHandler {
    enum ModelFailure: Error {
        case unavailable
        case mismatch
        case serviceUnavailable
        case inference
    }

    func executeValidated(
        lease: JobLeaseToken,
        payload: PersonalLibrarySuggestionsPayload,
        initialCheckpoint: PersonalLibrarySuggestionsCheckpoint,
        leaseDurationMs: Int64
    ) async throws -> JobHandlerExecutionResult {
        let review = GRDBPersonalizationReviewRepository(database: dependencies.database)
        let total: Int
        do {
            total = try review.frozenAssetTotal(
                sourceIDs: payload.sourceIDs,
                catalogCutoffMs: payload.catalogCutoffMs
            )
        } catch {
            return retryableFailure(
                .personalizationPersistenceFailure,
                checkpoint: try? PersonalLibrarySuggestionsCodec.jobCheckpoint(from: initialCheckpoint),
                progress: JobProgress(completed: initialCheckpoint.checkedCount, total: nil)
            )
        }

        guard initialCheckpoint.checkedCount <= total else {
            return terminalFailure(
                .personalizationCheckpointInvalid,
                checkpoint: try? PersonalLibrarySuggestionsCodec.jobCheckpoint(from: initialCheckpoint),
                progress: JobProgress(completed: 0, total: total)
            )
        }

        var state = initialCheckpoint
        do {
            guard try review.personalSuggestionCapabilityMatches(payload.capability) else {
                throw ModelFailure.mismatch
            }
            try await confirmCapability(payload.capability)

            while true {
                try Task.checkCancellation()
                let batch = try review.frozenAssetBatch(
                    sourceIDs: payload.sourceIDs,
                    catalogCutoffMs: payload.catalogCutoffMs,
                    afterAssetID: state.lastAssetID,
                    limit: 1
                )
                guard let assetID = batch.first else {
                    let finalized = checkpoint(
                        from: state,
                        lastAssetID: state.lastAssetID,
                        capability: payload.capability,
                        checkedDelta: 0,
                        suggestedDelta: 0,
                        skippedDelta: 0
                    )
                    return try settle(
                        lease: lease,
                        outcome: .completed,
                        checkpoint: finalized,
                        total: total,
                        leaseDurationMs: leaseDurationMs
                    )
                }

                let result = try await process(
                    assetID: assetID,
                    payload: payload,
                    review: review
                )
                let createdAtMs = dependencies.clock.nowMs
                let snapshot = try dependencies.queue.commitLeaseProtectedBatch(lease: lease) { db in
                    let inserted: Int
                    switch result {
                    case let .predictions(candidate, predictions):
                        inserted = try review.replacePersonalSuggestions(
                            candidate: candidate,
                            predictions: predictions,
                            expectedCapability: payload.capability,
                            createdAtMs: createdAtMs,
                            on: db
                        )
                    case .skipped:
                        inserted = 0
                    }
                    try dependencies.publishFailureInjector?()
                    let next = checkpoint(
                        from: state,
                        lastAssetID: assetID,
                        capability: payload.capability,
                        checkedDelta: 1,
                        suggestedDelta: inserted,
                        skippedDelta: result.isSkipped ? 1 : 0
                    )
                    return SafeBatchCommitInput(
                        lease: lease,
                        outcome: next.checkedCount >= total ? .completed : .continue,
                        checkpoint: try PersonalLibrarySuggestionsCodec.jobCheckpoint(from: next),
                        progress: JobProgress(completed: next.checkedCount, total: total),
                        leaseDurationMs: leaseDurationMs
                    )
                }
                let committed = try PersonalLibrarySuggestionsCodec.checkpoint(from: snapshot.checkpoint)
                state = committed
                if snapshot.state != .running {
                    return settledResult(snapshot: snapshot)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as ModelFailure {
            switch failure {
            case .unavailable, .mismatch:
                let code: JobSafeErrorCode = failure == .unavailable
                    ? .personalLibraryBundleUnavailable
                    : .personalLibraryBundleMismatch
                return try invalidateAndSettle(
                    lease: lease,
                    code: code,
                    state: state,
                    total: total,
                    leaseDurationMs: leaseDurationMs,
                    review: review
                )
            case .serviceUnavailable:
                return retryableFailure(
                    .personalLibraryServiceUnavailable,
                    checkpoint: try? PersonalLibrarySuggestionsCodec.jobCheckpoint(from: state),
                    progress: JobProgress(completed: state.checkedCount, total: total)
                )
            case .inference:
                return retryableFailure(
                    .personalLibraryInferenceFailure,
                    checkpoint: try? PersonalLibrarySuggestionsCodec.jobCheckpoint(from: state),
                    progress: JobProgress(completed: state.checkedCount, total: total)
                )
            }
        } catch {
            return retryableFailure(
                .personalizationPersistenceFailure,
                checkpoint: try? PersonalLibrarySuggestionsCodec.jobCheckpoint(from: state),
                progress: JobProgress(completed: state.checkedCount, total: total)
            )
        }
    }

    enum AssetResult {
        case skipped
        case predictions(PersonalSuggestionCandidate, [PersonalSuggestionPrediction])

        var isSkipped: Bool {
            if case .skipped = self { return true }
            return false
        }
    }

    func process(
        assetID: UUID,
        payload: PersonalLibrarySuggestionsPayload,
        review: GRDBPersonalizationReviewRepository
    ) async throws -> AssetResult {
        guard let tagID = payload.capability.tagIDs.first,
              let context = try review.frozenAssetProcessingContext(
                  tagID: tagID,
                  assetID: assetID
              ),
              context.recordUpdatedAtMs <= payload.catalogCutoffMs,
              context.locatorState == AssetLocatorState.current.rawValue,
              context.sourceState == SourceState.active.rawValue,
              context.availability == AssetAvailability.available.rawValue
        else {
            return .skipped
        }

        let imageData: Data
        do {
            imageData = try await dependencies.images.loadPersonalSuggestionPreview(assetID: assetID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .skipped
        }

        try await confirmCapability(payload.capability)
        let suggestions: [LocalModelSuggestion]
        do {
            suggestions = try await dependencies.client.suggestions(
                imageData: imageData,
                requestID: UUID().uuidString.lowercased(),
                target: .personal(payload.capability.target)
            )
        } catch {
            throw classify(error)
        }
        try await confirmCapability(payload.capability)
        return .predictions(
            PersonalSuggestionCandidate(
                assetID: assetID,
                contentRevision: context.contentRevision
            ),
            try validatedPredictions(suggestions, capability: payload.capability)
        )
    }

    func confirmCapability(_ expected: PersonalModelSuggestionCapability) async throws {
        do {
            guard case let .available(actual) = try await dependencies.client.personalCapability()
            else {
                throw ModelFailure.unavailable
            }
            guard actual == expected else {
                throw ModelFailure.mismatch
            }
        } catch let failure as ModelFailure {
            throw failure
        } catch {
            throw classify(error)
        }
    }

    func classify(_ error: Error) -> ModelFailure {
        guard let error = error as? LocalModelSuggestionClientError else {
            return .inference
        }
        switch error {
        case .identityMismatch:
            return .mismatch
        case .serviceUnavailable, .invalidEndpoint:
            return .serviceUnavailable
        case let .rejected(statusCode, code)
            where statusCode == 409 && code == "personal_bundle_mismatch":
            return .mismatch
        case let .rejected(statusCode, code)
            where statusCode == 503 && code == "personal_bundle_unavailable":
            return .unavailable
        case let .rejected(statusCode, _) where statusCode == 503:
            return .serviceUnavailable
        case .invalidResponse, .rejected:
            return .inference
        }
    }

    func validatedPredictions(
        _ suggestions: [LocalModelSuggestion],
        capability: PersonalModelSuggestionCapability
    ) throws -> [PersonalSuggestionPrediction] {
        let tagIDs = suggestions.compactMap(\.tagID)
        guard tagIDs.count == suggestions.count,
              Set(tagIDs).count == tagIDs.count,
              suggestions.allSatisfy({ suggestion in
                  guard let tagID = suggestion.tagID else { return false }
                  let target = capability.target
                  return suggestion.score.isFinite
                      && suggestion.track == .personal
                      && suggestion.conceptID == nil
                      && suggestion.recommendedState == .suggested
                      && capability.tagIDs.contains(tagID)
                      && suggestion.catalogScopeID == target.catalogScopeID
                      && suggestion.bundleID == target.bundleID
                      && suggestion.bundleRevision == target.bundleRevision
                      && suggestion.provider == target.provider
                      && suggestion.modelID == target.modelID
                      && suggestion.modelRevision == target.modelRevision
                      && suggestion.preprocessingRevision == target.preprocessingRevision
                      && suggestion.elementCount == target.elementCount
                      && suggestion.labelVocabularyRevision == target.labelVocabularyRevision
                      && suggestion.weightsSHA256 == target.weightsSHA256
                      && suggestion.policyRevision == target.policyRevision
                      && suggestion.standardPackID == nil
                      && suggestion.standardPackRevision == nil
              })
        else {
            throw ModelFailure.mismatch
        }
        return suggestions.map {
            PersonalSuggestionPrediction(tagID: $0.tagID!, score: $0.score)
        }
    }

    func checkpoint(
        from state: PersonalLibrarySuggestionsCheckpoint,
        lastAssetID: UUID?,
        capability: PersonalModelSuggestionCapability,
        checkedDelta: Int,
        suggestedDelta: Int,
        skippedDelta: Int
    ) -> PersonalLibrarySuggestionsCheckpoint {
        PersonalLibrarySuggestionsCheckpoint(
            lastAssetID: lastAssetID,
            capability: capability,
            checkedCount: state.checkedCount + checkedDelta,
            suggestedCount: state.suggestedCount + suggestedDelta,
            skippedCount: state.skippedCount + skippedDelta
        )
    }

    func settle(
        lease: JobLeaseToken,
        outcome: JobHandlerOutcome,
        checkpoint: PersonalLibrarySuggestionsCheckpoint,
        total: Int,
        leaseDurationMs: Int64
    ) throws -> JobHandlerExecutionResult {
        let snapshot = try dependencies.queue.commitLeaseProtectedBatch(
            input: SafeBatchCommitInput(
                lease: lease,
                outcome: outcome,
                checkpoint: try PersonalLibrarySuggestionsCodec.jobCheckpoint(from: checkpoint),
                progress: JobProgress(completed: checkpoint.checkedCount, total: total),
                leaseDurationMs: leaseDurationMs
            )
        ) { _ in }
        return settledResult(snapshot: snapshot)
    }

    func invalidateAndSettle(
        lease: JobLeaseToken,
        code: JobSafeErrorCode,
        state: PersonalLibrarySuggestionsCheckpoint,
        total: Int,
        leaseDurationMs: Int64,
        review: GRDBPersonalizationReviewRepository
    ) throws -> JobHandlerExecutionResult {
        let jobCheckpoint = try PersonalLibrarySuggestionsCodec.jobCheckpoint(from: state)
        let snapshot = try dependencies.queue.commitLeaseProtectedBatch(
            input: SafeBatchCommitInput(
                lease: lease,
                outcome: .nonRetryableFailure(code: code),
                checkpoint: jobCheckpoint,
                progress: JobProgress(completed: state.checkedCount, total: total),
                leaseDurationMs: leaseDurationMs
            )
        ) { db in
            try review.invalidatePersonalSuggestionBundle(on: db)
        }
        return settledResult(snapshot: snapshot)
    }

    func settledResult(snapshot: JobRecordSnapshot) -> JobHandlerExecutionResult {
        let outcome: JobHandlerOutcome = switch snapshot.state {
        case .completed, .cancelled:
            .completed
        case .retryableFailed:
            .retryableFailure(code: snapshot.lastErrorCode ?? .personalizationPersistenceFailure)
        case .terminalFailed:
            .nonRetryableFailure(code: snapshot.lastErrorCode ?? .personalizationPersistenceFailure)
        case .pending, .running, .paused:
            .continue
        }
        return JobHandlerExecutionResult(
            outcome: outcome,
            checkpoint: snapshot.checkpoint,
            progress: snapshot.progress,
            settledByHandler: true
        )
    }

    func terminalFailure(
        _ code: JobSafeErrorCode,
        checkpoint: JobCheckpoint?,
        progress: JobProgress
    ) -> JobHandlerExecutionResult {
        JobHandlerExecutionResult(
            outcome: .nonRetryableFailure(code: code),
            checkpoint: checkpoint,
            progress: progress
        )
    }

    func retryableFailure(
        _ code: JobSafeErrorCode,
        checkpoint: JobCheckpoint?,
        progress: JobProgress
    ) -> JobHandlerExecutionResult {
        JobHandlerExecutionResult(
            outcome: .retryableFailure(code: code),
            checkpoint: checkpoint,
            progress: progress
        )
    }
}
