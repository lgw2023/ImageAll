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
            try review.invalidateAllPersonalSuggestionBundles(on: db)
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
        guard let context = try review.frozenStandardAssetProcessingContext(assetID: assetID),
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
            guard try currentPayload() == frozen else {
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

            guard try currentPayload() == frozen else {
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

    func currentPayload() throws -> PersonalModelRebuildJobPayload? {
        try PersonalModelRebuildJobFactory.payload(
            from: GRDBPersonalizationReviewRepository(database: dependencies.database)
                .personalTrainingSnapshot()
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
