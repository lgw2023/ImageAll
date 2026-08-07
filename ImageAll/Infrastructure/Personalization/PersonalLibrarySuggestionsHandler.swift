import Foundation

protocol PersonalLibrarySuggestionImageLoading: Sendable {
    func loadPersonalSuggestionPreview(assetID: UUID) async throws -> Data
}

extension LibraryAssetImageLoader: PersonalLibrarySuggestionImageLoading {
    func loadPersonalSuggestionPreview(assetID: UUID) async throws -> Data {
        try await loadModelSuggestionPreview(assetID: assetID)
    }
}

struct PersonalLibrarySuggestionsHandlerDependencies: Sendable {
    let database: CatalogDatabase
    let queue: GRDBJobQueue
    let images: any PersonalLibrarySuggestionImageLoading
    let client: (any LocalModelSuggestionClient)?
    let catalogScopeID: String
    let clock: any JobClock
    var appSuggestersByBundleID: [String: any AppPersonalTagLibrarySuggesting] = [:]
    var embeddingCache: (any AppSelectedAssetEmbeddingCaching)? = nil
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
        let exclusionTagID = payload.capability.tagIDs.first
        let total: Int
        do {
            total = try review.frozenAssetTotal(
                mediaKind: payload.capability.target.mediaKind,
                sourceIDs: payload.sourceIDs,
                catalogCutoffMs: payload.catalogCutoffMs,
                excludingDecisionsForTagID: exclusionTagID
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

        if payload.usesAppRuntime {
            return try await executeAppRuntimeValidated(
                lease: lease,
                payload: payload,
                initialCheckpoint: initialCheckpoint,
                total: total,
                leaseDurationMs: leaseDurationMs,
                review: review
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
                    mediaKind: payload.capability.target.mediaKind,
                    sourceIDs: payload.sourceIDs,
                    catalogCutoffMs: payload.catalogCutoffMs,
                    afterAssetID: state.lastAssetID,
                    limit: 1,
                    excludingDecisionsForTagID: exclusionTagID
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
                    mediaKind: payload.capability.target.mediaKind,
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

    func executeAppRuntimeValidated(
        lease: JobLeaseToken,
        payload: PersonalLibrarySuggestionsPayload,
        initialCheckpoint: PersonalLibrarySuggestionsCheckpoint,
        total: Int,
        leaseDurationMs: Int64,
        review: GRDBPersonalizationReviewRepository
    ) async throws -> JobHandlerExecutionResult {
        guard let minimumScore = payload.minimumScore,
              let maximumPendingCount = payload.maximumPendingCount,
              let tagID = payload.capability.tagIDs.first,
              let suggester = dependencies.appSuggestersByBundleID[
                  payload.capability.target.bundleID
              ],
              let embeddingCache = dependencies.embeddingCache
        else {
            return retryableFailure(
                .personalLibraryServiceUnavailable,
                checkpoint: try? PersonalLibrarySuggestionsCodec.jobCheckpoint(
                    from: initialCheckpoint
                ),
                progress: JobProgress(completed: initialCheckpoint.checkedCount, total: total)
            )
        }

        var state = initialCheckpoint
        do {
            guard try review.personalSuggestionCapabilityMatches(payload.capability),
                  try await suggester.capability(
                      mediaKind: payload.capability.target.mediaKind,
                      tagID: tagID
                  ) == payload.capability
            else {
                throw ModelFailure.mismatch
            }

            while true {
                try Task.checkCancellation()
                let assetIDs = try review.frozenAssetBatch(
                    mediaKind: payload.capability.target.mediaKind,
                    sourceIDs: payload.sourceIDs,
                    catalogCutoffMs: payload.catalogCutoffMs,
                    afterAssetID: state.lastAssetID,
                    limit: AppPersonalTagLibrarySuggestionLimits.persistentBatchSize,
                    excludingDecisionsForTagID: tagID
                )
                guard !assetIDs.isEmpty else {
                    return try publishAppRuntimeAndSettle(
                        lease: lease,
                        payload: payload,
                        state: state,
                        total: total,
                        maximumPendingCount: maximumPendingCount,
                        leaseDurationMs: leaseDurationMs,
                        review: review
                    )
                }

                var candidates: [PersonalSuggestionCandidate] = []
                candidates.reserveCapacity(assetIDs.count)
                var ineligibleCount = 0
                for assetID in assetIDs {
                    guard let context = try review.frozenAssetProcessingContext(
                        mediaKind: payload.capability.target.mediaKind,
                        tagID: tagID,
                        assetID: assetID
                    ),
                    !context.hasDecision,
                    context.recordUpdatedAtMs <= payload.catalogCutoffMs,
                    context.locatorState == AssetLocatorState.current.rawValue,
                    context.sourceState == SourceState.active.rawValue,
                    context.availability == AssetAvailability.available.rawValue,
                    context.contentRevision > 0
                    else {
                        ineligibleCount += 1
                        continue
                    }
                    candidates.append(
                        PersonalSuggestionCandidate(
                            assetID: assetID,
                            contentRevision: context.contentRevision
                        )
                    )
                }

                let suggestionBatch: AppPersonalTagLibrarySuggestionBatch
                if candidates.isEmpty {
                    suggestionBatch = AppPersonalTagLibrarySuggestionBatch(
                        tagID: tagID,
                        capability: payload.capability,
                        hits: [],
                        checkedCount: 0,
                        aboveThresholdCount: 0,
                        skippedCount: 0
                    )
                } else {
                    let images = dependencies.images
                    let requests = candidates.map { candidate in
                        AppSelectedAssetEmbeddingRequest(
                            assetID: candidate.assetID,
                            contentRevision: candidate.contentRevision,
                            imageData: {
                                try await images.loadPersonalSuggestionPreview(
                                    assetID: candidate.assetID
                                )
                            }
                        )
                    }
                    let cached = try await embeddingCache.cacheSelectedAssets(
                        requests,
                        maximumConcurrentImageLoads:
                            AppPersonalTagLibrarySuggestionLimits.maximumConcurrentImageLoads
                    )
                    let embeddings = cached.map { value in
                        value.map {
                            AppCoreMLEmbedding(identity: $0.identity, values: $0.values)
                        }
                    }
                    let frozenCandidates = candidates
                    let frozenEmbeddings = embeddings
                    suggestionBatch = try await suggester.suggest(
                        mediaKind: payload.capability.target.mediaKind,
                        tagID: tagID,
                        candidates: candidates,
                        maximumPendingCount: maximumPendingCount,
                        minimumScore: minimumScore,
                        embeddingBatch: { requested in
                            guard requested == frozenCandidates else {
                                throw AppPersonalTagLibrarySuggestionError.identityMismatch
                            }
                            return frozenEmbeddings
                        },
                        progress: nil
                    )
                    guard suggestionBatch.capability == payload.capability else {
                        throw ModelFailure.mismatch
                    }
                }

                let next = appCheckpoint(
                    from: state,
                    lastAssetID: assetIDs.last,
                    capability: payload.capability,
                    checkedDelta: assetIDs.count,
                    aboveThresholdDelta: suggestionBatch.aboveThresholdCount,
                    skippedDelta: ineligibleCount + suggestionBatch.skippedCount,
                    newHits: suggestionBatch.hits,
                    maximumPendingCount: maximumPendingCount
                )
                let createdAtMs = dependencies.clock.nowMs
                let shouldComplete = next.checkedCount >= total
                let snapshot = try dependencies.queue.commitLeaseProtectedBatch(
                    lease: lease
                ) { db in
                    var committed = next
                    if shouldComplete {
                        let inserted = try review.replacePersonalTagLibrarySuggestions(
                            tagID: tagID,
                            hits: next.topHits.map(\.suggestionHit),
                            expectedCapability: payload.capability,
                            maximumPendingCount: maximumPendingCount,
                            createdAtMs: createdAtMs,
                            on: db
                        )
                        committed = PersonalLibrarySuggestionsCheckpoint(
                            lastAssetID: next.lastAssetID,
                            capability: next.capability,
                            checkedCount: next.checkedCount,
                            suggestedCount: inserted,
                            skippedCount: next.skippedCount,
                            aboveThresholdCount: next.aboveThresholdCount,
                            topHits: next.topHits
                        )
                    }
                    try dependencies.publishFailureInjector?()
                    return SafeBatchCommitInput(
                        lease: lease,
                        outcome: shouldComplete ? .completed : .continue,
                        checkpoint: try PersonalLibrarySuggestionsCodec.jobCheckpoint(
                            from: committed
                        ),
                        progress: JobProgress(completed: committed.checkedCount, total: total),
                        leaseDurationMs: leaseDurationMs
                    )
                }
                state = try PersonalLibrarySuggestionsCodec.checkpoint(
                    from: snapshot.checkpoint
                )
                if snapshot.state != .running {
                    return settledResult(snapshot: snapshot)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch AppPersonalTagLibrarySuggestionError.personalUnavailable,
                AppPersonalTagLibrarySuggestionError.tagNotInPersonalModel,
                ModelFailure.mismatch
        {
            return try invalidateAndSettle(
                lease: lease,
                code: .personalLibraryBundleMismatch,
                state: state,
                total: total,
                leaseDurationMs: leaseDurationMs,
                mediaKind: payload.capability.target.mediaKind,
                review: review
            )
        } catch AppPersonalTagLibrarySuggestionError.modelUnavailable,
                AppSelectedAssetEmbeddingCacheError.modelUnavailable
        {
            return retryableFailure(
                .personalLibraryServiceUnavailable,
                checkpoint: try? PersonalLibrarySuggestionsCodec.jobCheckpoint(from: state),
                progress: JobProgress(completed: state.checkedCount, total: total)
            )
        } catch {
            return retryableFailure(
                .personalLibraryInferenceFailure,
                checkpoint: try? PersonalLibrarySuggestionsCodec.jobCheckpoint(from: state),
                progress: JobProgress(completed: state.checkedCount, total: total)
            )
        }
    }

    func process(
        assetID: UUID,
        payload: PersonalLibrarySuggestionsPayload,
        review: GRDBPersonalizationReviewRepository
    ) async throws -> AssetResult {
        guard let tagID = payload.capability.tagIDs.first,
              let context = try review.frozenAssetProcessingContext(
                  mediaKind: payload.capability.target.mediaKind,
                  tagID: tagID,
                  assetID: assetID
              ),
              !context.hasDecision,
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
            guard let client = dependencies.client else {
                throw ModelFailure.serviceUnavailable
            }
            suggestions = try await client.suggestions(
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
            guard let client = dependencies.client else {
                throw ModelFailure.serviceUnavailable
            }
            guard case let .available(actual) = try await client.personalCapability()
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
            skippedCount: state.skippedCount + skippedDelta,
            aboveThresholdCount: state.aboveThresholdCount,
            topHits: state.topHits
        )
    }

    func appCheckpoint(
        from state: PersonalLibrarySuggestionsCheckpoint,
        lastAssetID: UUID?,
        capability: PersonalModelSuggestionCapability,
        checkedDelta: Int,
        aboveThresholdDelta: Int,
        skippedDelta: Int,
        newHits: [AppPersonalTagLibrarySuggestionHit],
        maximumPendingCount: Int
    ) -> PersonalLibrarySuggestionsCheckpoint {
        let merged = (state.topHits.map(\.suggestionHit) + newHits).sorted {
            if $0.score == $1.score {
                return $0.candidate.assetID.uuidString.lowercased()
                    < $1.candidate.assetID.uuidString.lowercased()
            }
            return $0.score > $1.score
        }
        let topHits = merged.prefix(maximumPendingCount).map {
            PersonalLibrarySuggestionsCheckpointHit(
                assetID: $0.candidate.assetID,
                contentRevision: $0.candidate.contentRevision,
                score: $0.score
            )
        }
        let aboveThresholdCount = state.aboveThresholdCount + aboveThresholdDelta
        return PersonalLibrarySuggestionsCheckpoint(
            lastAssetID: lastAssetID,
            capability: capability,
            checkedCount: state.checkedCount + checkedDelta,
            suggestedCount: aboveThresholdCount,
            skippedCount: state.skippedCount + skippedDelta,
            aboveThresholdCount: aboveThresholdCount,
            topHits: topHits
        )
    }

    func publishAppRuntimeAndSettle(
        lease: JobLeaseToken,
        payload: PersonalLibrarySuggestionsPayload,
        state: PersonalLibrarySuggestionsCheckpoint,
        total: Int,
        maximumPendingCount: Int,
        leaseDurationMs: Int64,
        review: GRDBPersonalizationReviewRepository
    ) throws -> JobHandlerExecutionResult {
        guard let tagID = payload.capability.tagIDs.first else {
            return terminalFailure(
                .personalizationPayloadInvalid,
                checkpoint: try? PersonalLibrarySuggestionsCodec.jobCheckpoint(from: state),
                progress: JobProgress(completed: state.checkedCount, total: total)
            )
        }
        let unaccounted = max(0, total - state.checkedCount)
        let createdAtMs = dependencies.clock.nowMs
        let snapshot = try dependencies.queue.commitLeaseProtectedBatch(lease: lease) { db in
            let inserted = try review.replacePersonalTagLibrarySuggestions(
                tagID: tagID,
                hits: state.topHits.map(\.suggestionHit),
                expectedCapability: payload.capability,
                maximumPendingCount: maximumPendingCount,
                createdAtMs: createdAtMs,
                on: db
            )
            let finalized = PersonalLibrarySuggestionsCheckpoint(
                lastAssetID: state.lastAssetID,
                capability: payload.capability,
                checkedCount: total,
                suggestedCount: inserted,
                skippedCount: state.skippedCount + unaccounted,
                aboveThresholdCount: state.aboveThresholdCount,
                topHits: state.topHits
            )
            try dependencies.publishFailureInjector?()
            return SafeBatchCommitInput(
                lease: lease,
                outcome: .completed,
                checkpoint: try PersonalLibrarySuggestionsCodec.jobCheckpoint(from: finalized),
                progress: JobProgress(completed: total, total: total),
                leaseDurationMs: leaseDurationMs
            )
        }
        return settledResult(snapshot: snapshot)
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
        mediaKind: MediaKind,
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
            try review.invalidatePersonalSuggestionBundles(
                mediaKind: mediaKind,
                on: db
            )
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

protocol StandardLibrarySuggestionImageLoading: Sendable {
    func loadStandardSuggestionPreview(assetID: UUID) async throws -> Data
}

extension LibraryAssetImageLoader: StandardLibrarySuggestionImageLoading {
    func loadStandardSuggestionPreview(assetID: UUID) async throws -> Data {
        try await load(assetID: assetID, variant: .preview)
    }
}

struct StandardLibrarySuggestionsHandlerDependencies: Sendable {
    let database: CatalogDatabase
    let queue: GRDBJobQueue
    let images: any StandardLibrarySuggestionImageLoading
    let client: any LocalModelSuggestionClient
    let clock: any JobClock
    var publishFailureInjector: (@Sendable () throws -> Void)?
}

struct StandardLibrarySuggestionsHandler: AsyncLeaseBoundJobHandler, Sendable {
    let dependencies: StandardLibrarySuggestionsHandlerDependencies

    var kind: String { StandardLibrarySuggestionsJobFactory.kind }
    var supportedPayloadVersions: Set<Int> { [StandardLibrarySuggestionsJobFactory.payloadVersion] }
    var supportedCheckpointVersions: Set<Int> { [StandardLibrarySuggestionsJobFactory.checkpointVersion] }

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
        guard payloadVersion == StandardLibrarySuggestionsJobFactory.payloadVersion else {
            return terminalFailure(
                .personalizationPayloadInvalid,
                checkpoint: checkpoint,
                progress: JobProgress(completed: 0, total: nil)
            )
        }

        let decodedPayload: StandardLibrarySuggestionsPayload
        let decodedCheckpoint: StandardLibrarySuggestionsCheckpoint
        do {
            decodedPayload = try StandardLibrarySuggestionsCodec.decodePayload(payload)
            decodedCheckpoint = try StandardLibrarySuggestionsCodec.checkpoint(from: checkpoint)
        } catch let error as StandardLibrarySuggestionsCodecError {
            let code: JobSafeErrorCode = error == .invalidPayload
                ? .personalizationPayloadInvalid
                : .personalizationCheckpointInvalid
            return terminalFailure(
                code,
                checkpoint: checkpoint,
                progress: JobProgress(completed: 0, total: nil)
            )
        } catch {
            return terminalFailure(
                .personalizationPayloadInvalid,
                checkpoint: checkpoint,
                progress: JobProgress(completed: 0, total: nil)
            )
        }

        guard decodedCheckpoint.target == nil
                || decodedCheckpoint.target == decodedPayload.target
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

private extension StandardLibrarySuggestionsHandler {
    enum ModelFailure: Error {
        case mismatch
        case serviceUnavailable
        case inference
    }

    enum AssetResult {
        case skipped
        case predictions(contentRevision: Int, suggestions: [LocalModelSuggestion])

        var isSkipped: Bool {
            if case .skipped = self { return true }
            return false
        }
    }

    func executeValidated(
        lease: JobLeaseToken,
        payload: StandardLibrarySuggestionsPayload,
        initialCheckpoint: StandardLibrarySuggestionsCheckpoint,
        leaseDurationMs: Int64
    ) async throws -> JobHandlerExecutionResult {
        let review = GRDBPersonalizationReviewRepository(database: dependencies.database)
        let total: Int
        do {
            total = try review.frozenAssetTotal(
                mediaKind: payload.mediaKind,
                sourceIDs: payload.sourceIDs,
                catalogCutoffMs: payload.catalogCutoffMs
            )
        } catch {
            return retryableFailure(
                .personalizationPersistenceFailure,
                checkpoint: try? StandardLibrarySuggestionsCodec.jobCheckpoint(from: initialCheckpoint),
                progress: JobProgress(completed: initialCheckpoint.checkedCount, total: nil)
            )
        }

        guard initialCheckpoint.checkedCount <= total else {
            return terminalFailure(
                .personalizationCheckpointInvalid,
                checkpoint: try? StandardLibrarySuggestionsCodec.jobCheckpoint(from: initialCheckpoint),
                progress: JobProgress(completed: 0, total: total)
            )
        }

        var state = initialCheckpoint
        do {
            guard try review.standardSuggestionTargetMatches(payload.target) else {
                throw ModelFailure.mismatch
            }
            while true {
                try Task.checkCancellation()
                let batch = try review.frozenAssetBatch(
                    mediaKind: payload.mediaKind,
                    sourceIDs: payload.sourceIDs,
                    catalogCutoffMs: payload.catalogCutoffMs,
                    afterAssetID: state.lastAssetID,
                    limit: 1
                )
                guard let assetID = batch.first else {
                    return try settle(
                        lease: lease,
                        outcome: .completed,
                        checkpoint: state,
                        total: total,
                        leaseDurationMs: leaseDurationMs
                    )
                }

                let result = try await process(assetID: assetID, payload: payload, review: review)
                let createdAtMs = dependencies.clock.nowMs
                let snapshot = try dependencies.queue.commitLeaseProtectedBatch(lease: lease) { db in
                    guard try review.standardSuggestionTargetMatches(payload.target, in: db) else {
                        throw ModelFailure.mismatch
                    }
                    let inserted: Int
                    var skipped = result.isSkipped
                    switch result {
                    case let .predictions(contentRevision, suggestions):
                        do {
                            inserted = try review.replaceStandardSuggestions(
                                assetID: assetID,
                                contentRevision: contentRevision,
                                suggestions: suggestions,
                                expectedTarget: payload.target,
                                createdAtMs: createdAtMs,
                                on: db
                            )
                        } catch StandardSuggestionReplacementError.identityMismatch {
                            throw ModelFailure.mismatch
                        } catch StandardSuggestionReplacementError.assetChanged {
                            inserted = 0
                            skipped = true
                        }
                    case .skipped:
                        inserted = 0
                    }
                    try dependencies.publishFailureInjector?()
                    let next = StandardLibrarySuggestionsCheckpoint(
                        lastAssetID: assetID,
                        target: payload.target,
                        checkedCount: state.checkedCount + 1,
                        suggestedCount: state.suggestedCount + inserted,
                        skippedCount: state.skippedCount + (skipped ? 1 : 0)
                    )
                    return SafeBatchCommitInput(
                        lease: lease,
                        outcome: next.checkedCount >= total ? .completed : .continue,
                        checkpoint: try StandardLibrarySuggestionsCodec.jobCheckpoint(from: next),
                        progress: JobProgress(completed: next.checkedCount, total: total),
                        leaseDurationMs: leaseDurationMs
                    )
                }
                state = try StandardLibrarySuggestionsCodec.checkpoint(from: snapshot.checkpoint)
                if snapshot.state != .running {
                    return settledResult(snapshot: snapshot)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as ModelFailure {
            switch failure {
            case .mismatch:
                return terminalFailure(
                    .standardLibraryIdentityMismatch,
                    checkpoint: try? StandardLibrarySuggestionsCodec.jobCheckpoint(from: state),
                    progress: JobProgress(completed: state.checkedCount, total: total)
                )
            case .serviceUnavailable:
                return retryableFailure(
                    .standardLibraryServiceUnavailable,
                    checkpoint: try? StandardLibrarySuggestionsCodec.jobCheckpoint(from: state),
                    progress: JobProgress(completed: state.checkedCount, total: total)
                )
            case .inference:
                return retryableFailure(
                    .standardLibraryInferenceFailure,
                    checkpoint: try? StandardLibrarySuggestionsCodec.jobCheckpoint(from: state),
                    progress: JobProgress(completed: state.checkedCount, total: total)
                )
            }
        } catch {
            return retryableFailure(
                .personalizationPersistenceFailure,
                checkpoint: try? StandardLibrarySuggestionsCodec.jobCheckpoint(from: state),
                progress: JobProgress(completed: state.checkedCount, total: total)
            )
        }
    }

    func process(
        assetID: UUID,
        payload: StandardLibrarySuggestionsPayload,
        review: GRDBPersonalizationReviewRepository
    ) async throws -> AssetResult {
        guard let context = try review.frozenStandardAssetProcessingContext(
            mediaKind: payload.mediaKind,
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
            imageData = try await dependencies.images.loadStandardSuggestionPreview(assetID: assetID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .skipped
        }

        do {
            let suggestions = try await dependencies.client.suggestions(
                imageData: imageData,
                requestID: UUID().uuidString.lowercased(),
                target: .standard(payload.target)
            )
            return .predictions(
                contentRevision: context.contentRevision,
                suggestions: suggestions
            )
        } catch {
            throw classify(error)
        }
    }

    func classify(_ error: Error) -> ModelFailure {
        guard let error = error as? LocalModelSuggestionClientError else {
            return .inference
        }
        switch error {
        case .identityMismatch, .invalidResponse:
            return .mismatch
        case .serviceUnavailable, .invalidEndpoint:
            return .serviceUnavailable
        case let .rejected(statusCode, _) where statusCode == 503:
            return .serviceUnavailable
        case let .rejected(statusCode, _) where statusCode == 409:
            return .mismatch
        case .rejected:
            return .inference
        }
    }

    func settle(
        lease: JobLeaseToken,
        outcome: JobHandlerOutcome,
        checkpoint: StandardLibrarySuggestionsCheckpoint,
        total: Int,
        leaseDurationMs: Int64
    ) throws -> JobHandlerExecutionResult {
        let snapshot = try dependencies.queue.commitLeaseProtectedBatch(
            input: SafeBatchCommitInput(
                lease: lease,
                outcome: outcome,
                checkpoint: try StandardLibrarySuggestionsCodec.jobCheckpoint(from: checkpoint),
                progress: JobProgress(completed: checkpoint.checkedCount, total: total),
                leaseDurationMs: leaseDurationMs
            )
        ) { _ in }
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

struct PersonalModelRebuildJobHandlerDependencies: Sendable {
    let database: CatalogDatabase
    let client: any LocalModelSuggestionClient
    let catalogScopeID: String
    let clock: any JobClock
}

struct PersonalModelRebuildJobHandler: AsyncLeaseBoundJobHandler, Sendable {
    let dependencies: PersonalModelRebuildJobHandlerDependencies

    var kind: String { PersonalModelRebuildJobFactory.kind }
    var supportedPayloadVersions: Set<Int> { [PersonalModelRebuildJobFactory.payloadVersion] }
    var supportedCheckpointVersions: Set<Int> { [PersonalModelRebuildJobFactory.checkpointVersion] }

    func execute(
        payloadVersion _: Int,
        payload _: Data,
        checkpoint: JobCheckpoint?
    ) -> JobHandlerExecutionResult {
        retryableFailure(.personalizationPersistenceFailure, checkpoint: checkpoint)
    }

    func executeAsync(
        lease _: JobLeaseToken,
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?,
        context _: JobLeaseExecutionContext
    ) async throws -> JobHandlerExecutionResult {
        guard payloadVersion == PersonalModelRebuildJobFactory.payloadVersion,
              checkpoint == nil,
              let frozen = try? PersonalModelRebuildJobCodec.decodePayload(payload),
              frozen.catalogScopeID == dependencies.catalogScopeID
        else {
            return terminalFailure(.personalRebuildInvalidSnapshot)
        }

        do {
            guard frozen.personalTagIDs.count == 1,
                  try currentPayload(matching: frozen) == frozen
            else {
                return completed()
            }
            let encoder: PersonalTrainingEncoderIdentity
            do {
                guard case let .ready(_, provider) = try await dependencies.client.serviceHealth()
                else {
                    throw ModelFailure.serviceUnavailable
                }
                encoder = provider
            } catch let failure as ModelFailure {
                throw failure
            } catch {
                throw classify(error)
            }

            let expectedActiveBundle: PersonalModelActiveBundleIdentity?
            do {
                switch try await dependencies.client.personalCapability() {
                case .unavailable:
                    expectedActiveBundle = nil
                case let .available(capability):
                    guard capability.target.catalogScopeID == frozen.catalogScopeID else {
                        throw ModelFailure.bundleMismatch
                    }
                    expectedActiveBundle = PersonalModelActiveBundleIdentity(
                        bundleRevision: capability.target.bundleRevision,
                        weightsSHA256: capability.target.weightsSHA256
                    )
                }
            } catch let failure as ModelFailure {
                throw failure
            } catch {
                throw classify(error)
            }

            let rebuilt: PersonalModelSuggestionCapability
            do {
                rebuilt = try await dependencies.client.rebuildPersonalModelFromCache(
                    requestID: UUID().uuidString.lowercased(),
                    expectedActiveBundle: expectedActiveBundle,
                    snapshot: PersonalModelCachedRebuildSnapshot(
                        catalogScopeID: frozen.catalogScopeID,
                        decisionSnapshotRevision: frozen.decisionSnapshotRevision,
                        encoder: encoder,
                        personalTagIDs: frozen.personalTagIDs,
                        labelVocabularyRevision: frozen.labelVocabularyRevision,
                        embeddingKeys: frozen.embeddingKeys,
                        decisions: frozen.decisions
                    )
                )
                guard case let .available(confirmed) = try await dependencies.client
                    .personalCapability(),
                    confirmed == rebuilt
                else {
                    throw ModelFailure.bundleMismatch
                }
            } catch let failure as ModelFailure {
                throw failure
            } catch {
                throw classify(error)
            }

            guard try currentPayload(matching: frozen) == frozen else {
                return completed()
            }
            try GRDBPersonalizationReviewRepository(database: dependencies.database)
                .activatePersonalSuggestionBundle(
                    rebuilt,
                    activatedAtMs: dependencies.clock.nowMs
                )
            return completed()
        } catch let failure as ModelFailure {
            switch failure {
            case .cacheMiss:
                return terminalFailure(.personalRebuildCacheMiss)
            case .invalidSnapshot:
                return terminalFailure(.personalRebuildInvalidSnapshot)
            case .bundleMismatch:
                return retryableFailure(.personalRebuildBundleMismatch, checkpoint: nil)
            case .serviceUnavailable:
                return retryableFailure(.personalRebuildServiceUnavailable, checkpoint: nil)
            }
        } catch {
            return retryableFailure(.personalizationPersistenceFailure, checkpoint: nil)
        }
    }
}

private extension PersonalModelRebuildJobHandler {
    enum ModelFailure: Error {
        case cacheMiss
        case invalidSnapshot
        case bundleMismatch
        case serviceUnavailable
    }

    func currentPayload(
        matching frozen: PersonalModelRebuildJobPayload
    ) throws -> PersonalModelRebuildJobPayload? {
        guard let tagID = frozen.personalTagIDs.first,
              frozen.personalTagIDs.count == 1
        else {
            return nil
        }
        return try PersonalModelRebuildJobFactory.payload(
            from: GRDBPersonalizationReviewRepository(database: dependencies.database)
                .personalTrainingSnapshot(
                    limitingToTagIDs: [tagID],
                    limitingToAssetIDs: nil
                )
        )
    }

    func classify(_ error: Error) -> ModelFailure {
        guard let error = error as? LocalModelSuggestionClientError else {
            return .serviceUnavailable
        }
        switch error {
        case .serviceUnavailable, .invalidEndpoint:
            return .serviceUnavailable
        case .identityMismatch, .invalidResponse:
            return .invalidSnapshot
        case let .rejected(statusCode, code)
            where statusCode == 409 && code == "personal_embedding_cache_miss":
            return .cacheMiss
        case let .rejected(statusCode, code)
            where statusCode == 409 && code == "personal_bundle_mismatch":
            return .bundleMismatch
        case let .rejected(statusCode, _) where statusCode == 503:
            return .serviceUnavailable
        case .rejected:
            return .invalidSnapshot
        }
    }

    func completed() -> JobHandlerExecutionResult {
        JobHandlerExecutionResult(
            outcome: .completed,
            checkpoint: nil,
            progress: JobProgress(completed: 1, total: 1)
        )
    }

    func terminalFailure(_ code: JobSafeErrorCode) -> JobHandlerExecutionResult {
        JobHandlerExecutionResult(
            outcome: .nonRetryableFailure(code: code),
            checkpoint: nil,
            progress: JobProgress(completed: 0, total: 1)
        )
    }

    func retryableFailure(
        _ code: JobSafeErrorCode,
        checkpoint: JobCheckpoint?
    ) -> JobHandlerExecutionResult {
        JobHandlerExecutionResult(
            outcome: .retryableFailure(code: code),
            checkpoint: checkpoint,
            progress: JobProgress(completed: 0, total: 1)
        )
    }
}
