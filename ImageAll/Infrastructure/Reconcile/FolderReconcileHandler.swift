import Foundation

struct FolderReconcileSourceAccessService: Sendable {
    let repository: GRDBFolderSourceAuthorizationRepository
    let bookmarkPort: any SecurityScopedBookmarkPort
    let rootValidator: FolderRootValidator
    let clock: any JobClock
    var onScopeStart: (@Sendable () -> Void)?
    var onScopeStop: (@Sendable () -> Void)?

    func withActiveSourceRootURL<T>(sourceID: UUID, perform: (URL) throws -> T) throws -> T {
        switch try repository.lookupSource(id: sourceID) {
        case .notFound, .wrongKind:
            throw FolderReconcileHandlerError.sourceUnavailable
        case let .folder(record):
            switch record.state {
            case .active:
                break
            case .unavailable:
                throw FolderReconcileHandlerError.sourceUnavailable
            case .authorizationRequired:
                throw FolderReconcileHandlerError.authorizationRequired
            case .disabled:
                throw FolderReconcileHandlerError.sourceUnavailable
            }
            return try resolveAccess(source: record, perform: perform)
        }
    }

    private func resolveAccess<T>(
        source: StoredFolderSourceRecord,
        perform: (URL) throws -> T
    ) throws -> T {
        let resolved: BookmarkResolveResult
        do {
            resolved = try bookmarkPort.resolveBookmark(source.bookmark)
        } catch {
            let observation = FolderAccessFailureClassifier.classifyBookmarkResolveFailure(error)
            try persistAccessObservation(
                sourceID: source.id,
                observation: observation
            )
            switch observation {
            case .offline:
                throw FolderReconcileHandlerError.sourceUnavailable
            case .authorizationRequired:
                throw FolderReconcileHandlerError.authorizationRequired
            }
        }

        onScopeStart?()
        let started = bookmarkPort.startAccessing(resolved.url)
        guard started else {
            onScopeStop?()
            try persistAccessObservation(
                sourceID: source.id,
                observation: FolderAccessFailureClassifier.classifyScopeStartFailure()
            )
            throw FolderReconcileHandlerError.authorizationRequired
        }
        defer {
            bookmarkPort.stopAccessing(resolved.url)
            onScopeStop?()
        }

        switch rootValidator.validateRoot(at: resolved.url) {
        case .valid:
            break
        case .invalid:
            try persistAccessObservation(
                sourceID: source.id,
                observation: FolderAccessFailureClassifier.classifyInvalidRoot()
            )
            throw FolderReconcileHandlerError.authorizationRequired
        }

        if resolved.isStale {
            do {
                try refreshStaleBookmarkInCurrentScope(sourceID: source.id, resolvedURL: resolved.url)
            } catch {
                throw FolderReconcileHandlerError.authorizationRequired
            }
        }

        return try perform(resolved.url)
    }

    private func refreshStaleBookmarkInCurrentScope(sourceID: UUID, resolvedURL: URL) throws {
        let newBookmark: Data
        do {
            newBookmark = try bookmarkPort.createReadOnlyBookmark(for: resolvedURL)
        } catch {
            try persistAccessObservation(sourceID: sourceID, observation: .authorizationRequired)
            throw FolderReconcileHandlerError.authorizationRequired
        }

        try repository.replaceStaleBookmark(
            sourceID: sourceID,
            bookmark: newBookmark,
            nowMs: clock.nowMs
        )
    }

    private func persistAccessObservation(
        sourceID: UUID,
        observation: FolderAccessFailureObservation
    ) throws {
        let state: SourceState
        switch observation {
        case .offline:
            state = .unavailable
        case .authorizationRequired:
            state = .authorizationRequired
        }
        try repository.updateSourceState(sourceID: sourceID, state: state, nowMs: clock.nowMs)
    }
}

enum FolderReconcileHandlerError: Error, Equatable {
    case sourceUnavailable
    case authorizationRequired
    case enumerationIncomplete
}

struct FolderReconcileHandler: LeaseBoundJobHandler {
    let rootAccess: FolderReconcileSourceAccessService
    let enumerationConfig: FolderEnumerationConfig

    var kind: String { FolderReconcileJobFactory.kind }
    var supportedPayloadVersions: Set<Int> { [FolderReconcileJobFactory.payloadVersion] }
    var supportedCheckpointVersions: Set<Int> { [1] }

    init(
        rootAccess: FolderReconcileSourceAccessService,
        enumerationConfig: FolderEnumerationConfig = .productionDefault
    ) {
        self.rootAccess = rootAccess
        self.enumerationConfig = enumerationConfig
    }

    func execute(
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?
    ) -> JobHandlerExecutionResult {
        JobHandlerExecutionResult(
            outcome: .retryableFailure(code: FolderReconcileSafeErrorCode.enumerationIncomplete),
            checkpoint: checkpoint,
            progress: JobProgress(completed: 0, total: nil)
        )
    }

    func execute(
        lease: JobLeaseToken,
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?,
        context: JobLeaseExecutionContext
    ) throws -> JobHandlerExecutionResult {
        let persisted = try resolvePersistedJob(lease: lease, context: context)
        switch FolderReconcilePayloadValidation.validate(
            payloadVersion: payloadVersion,
            payload: payload,
            jobSourceID: persisted.sourceID
        ) {
        case let .success(valid):
            return try runReconcile(
                lease: lease,
                sourceID: valid.sourceID,
                payloadVersion: payloadVersion,
                payload: payload,
                checkpoint: checkpoint,
                persisted: persisted,
                context: context
            )
        case let .failure(.invalid(code)):
            let outcome = FolderReconcileSafeErrorSettlement.outcome(for: code)
            _ = try context.reconcileBatch.stopIncomplete(
                FolderStopIncompleteInput(
                    lease: lease,
                    sourceID: persisted.sourceID ?? validSourceIDFromPayload(payload),
                    checkpoint: nil,
                    leaseDurationMs: context.leaseDurationMs,
                    errorCode: code,
                    outcome: outcome
                )
            )
            return JobHandlerExecutionResult(
                outcome: outcome,
                checkpoint: nil,
                progress: JobProgress(completed: persisted.progressCompleted, total: nil),
                settledByHandler: true
            )
        }
    }

    private func runReconcile(
        lease: JobLeaseToken,
        sourceID: UUID,
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?,
        persisted: PersistedJobContext,
        context: JobLeaseExecutionContext
    ) throws -> JobHandlerExecutionResult {
        if let checkpoint, checkpoint.version != 1 {
            return try failWithCode(
                lease: lease,
                sourceID: sourceID,
                code: FolderReconcileSafeErrorCode.checkpointInvalid,
                persisted: persisted,
                context: context
            )
        }

        if let checkpoint {
            do {
                let decoded = try FolderReconcileCheckpointCodec.decode(checkpoint.data)
                guard FolderReconcileCheckpointCodec.validateResumable(
                    decoded,
                    scanGeneration: persisted.scanGeneration,
                    startedDirtyEpoch: persisted.startedDirtyEpoch,
                    currentAttempt: lease.attempts
                ) else {
                    return try failWithCode(
                        lease: lease,
                        sourceID: sourceID,
                        code: FolderReconcileSafeErrorCode.checkpointInvalid,
                        persisted: persisted,
                        context: context
                    )
                }
            } catch {
                return try failWithCode(
                    lease: lease,
                    sourceID: sourceID,
                    code: FolderReconcileSafeErrorCode.checkpointInvalid,
                    persisted: persisted,
                    context: context
                )
            }
        }

        let begin: FolderBeginGenerationResult
        do {
            begin = try context.reconcileBatch.beginGeneration(
                FolderBeginGenerationInput(
                    lease: lease,
                    sourceID: sourceID,
                    payloadVersion: payloadVersion,
                    payload: payload,
                    leaseDurationMs: context.leaseDurationMs
                )
            )
        } catch let error as FolderReconcileRepositoryError where error == .checkpointInvalid {
            return try failWithCode(
                lease: lease,
                sourceID: sourceID,
                code: FolderReconcileSafeErrorCode.checkpointInvalid,
                persisted: persisted,
                context: context
            )
        }

        var currentCheckpoint = begin.checkpoint
        var pendingObservations: [FolderReconcileAssetObservation] = []
        let classifier = FolderMediaClassifier()

        do {
            try rootAccess.withActiveSourceRootURL(sourceID: sourceID) { rootURL in
                let session = FolderDirectoryEnumerator(rootURL: rootURL, config: enumerationConfig).makeSession()

                while let entry = try session.nextEntry() {
                    currentCheckpoint = incrementEnumerated(currentCheckpoint)

                    switch entry {
                    case .ignored:
                        currentCheckpoint = incrementIgnored(currentCheckpoint)
                    case .unsafeRelativePath:
                        throw FolderReconcileTraversalFailure.unsafeRelativePath
                    case let .candidateFile(relativePath, fileName):
                        currentCheckpoint = incrementCandidate(currentCheckpoint)
                        let fileURL = rootURL.appendingPathComponent(relativePath)
                        switch classifier.classify(fileURL: fileURL, fileName: fileName) {
                        case .ignored:
                            currentCheckpoint = incrementIgnored(currentCheckpoint)
                        case let .available(metadata):
                            let (observation, conflicts) = try resolveAvailableObservation(
                                rootURL: rootURL,
                                relativePath: relativePath,
                                fileName: fileName,
                                metadata: metadata,
                                batchPort: context.reconcileBatch,
                                sourceID: sourceID,
                                generation: begin.generation
                            )
                            currentCheckpoint = addIdentityConflicts(currentCheckpoint, by: conflicts)
                            pendingObservations.append(observation)
                            currentCheckpoint = incrementCommitted(currentCheckpoint)
                        case let .unsupported(metadata):
                            pendingObservations.append(makeObservation(
                                relativePath: relativePath,
                                fileName: fileName,
                                availability: .unsupported,
                                metadata: metadata
                            ))
                            currentCheckpoint = incrementCommitted(currentCheckpoint, unsupported: true)
                        case let .unreadable(metadata):
                            pendingObservations.append(makeObservation(
                                relativePath: relativePath,
                                fileName: fileName,
                                availability: .unreadable,
                                metadata: metadata
                            ))
                            currentCheckpoint = incrementCommitted(currentCheckpoint, unreadable: true)
                        }
                    }

                    if pendingObservations.count >= enumerationConfig.assetBatchLimit
                        || session.needsBoundaryFlush
                    {
                        currentCheckpoint = try flushBatch(
                            lease: lease,
                            sourceID: sourceID,
                            generation: begin.generation,
                            startedDirtyEpoch: begin.startedDirtyEpoch,
                            checkpoint: currentCheckpoint,
                            observations: &pendingObservations,
                            context: context
                        )
                        session.markBoundaryFlushed()
                    }
                }

                if session.directoryHadError {
                    throw FolderReconcileTraversalFailure.incomplete
                }

                currentCheckpoint = try flushBatch(
                    lease: lease,
                    sourceID: sourceID,
                    generation: begin.generation,
                    startedDirtyEpoch: begin.startedDirtyEpoch,
                    checkpoint: currentCheckpoint,
                    observations: &pendingObservations,
                    context: context
                )
            }
        } catch FolderReconcileTraversalFailure.unsafeRelativePath {
            return try settleIncomplete(
                lease: lease,
                sourceID: sourceID,
                checkpoint: currentCheckpoint,
                code: FolderReconcileSafeErrorCode.unsafeRelativePath,
                context: context
            )
        } catch FolderReconcileHandlerError.authorizationRequired {
            return try settleIncomplete(
                lease: lease,
                sourceID: sourceID,
                checkpoint: currentCheckpoint,
                code: FolderReconcileSafeErrorCode.authorizationRequired,
                context: context
            )
        } catch FolderReconcileHandlerError.sourceUnavailable {
            return try settleIncomplete(
                lease: lease,
                sourceID: sourceID,
                checkpoint: currentCheckpoint,
                code: FolderReconcileSafeErrorCode.sourceUnavailable,
                context: context
            )
        } catch FolderReconcileTraversalFailure.incomplete {
            return try settleIncomplete(
                lease: lease,
                sourceID: sourceID,
                checkpoint: currentCheckpoint,
                code: FolderReconcileSafeErrorCode.enumerationIncomplete,
                context: context
            )
        }

        _ = try context.reconcileBatch.completeGeneration(
            FolderCompleteGenerationInput(
                lease: lease,
                sourceID: sourceID,
                generation: begin.generation,
                startedDirtyEpoch: begin.startedDirtyEpoch,
                checkpoint: currentCheckpoint,
                leaseDurationMs: context.leaseDurationMs
            )
        )

        let finalProgress = max(persisted.progressCompleted, currentCheckpoint.candidateFiles)
        return JobHandlerExecutionResult(
            outcome: .completed,
            checkpoint: try makeJobCheckpoint(currentCheckpoint),
            progress: JobProgress(completed: finalProgress, total: nil),
            settledByHandler: true
        )
    }

    private func resolveAvailableObservation(
        rootURL: URL,
        relativePath: String,
        fileName: String,
        metadata: FolderMediaMetadata,
        batchPort: any FolderReconcileBatchPort,
        sourceID: UUID,
        generation: Int
    ) throws -> (FolderReconcileAssetObservation, Int) {
        let probe: FolderMovePathProbe
        var conflicts = 0

        guard let resourceID = metadata.resourceID else {
            return (makeObservation(
                relativePath: relativePath,
                fileName: fileName,
                availability: .available,
                metadata: metadata,
                movePathProbe: nil
            ), 0)
        }

        let candidates = try batchPort.lookupMoveCandidates(
            sourceID: sourceID,
            resourceID: resourceID,
            excludingGeneration: generation
        )

        if candidates.count > 1 {
            probe = .multipleCandidates
            conflicts = 1
        } else if let candidate = candidates.first {
            probe = probeOldPath(
                rootURL: rootURL,
                candidateRelativePath: candidate.relativePath,
                resourceID: resourceID
            )
            if probe == .oldPathSameResourceID || probe == .oldPathProbeError {
                conflicts = 1
            }
        } else {
            probe = .noCandidate
        }

        return (makeObservation(
            relativePath: relativePath,
            fileName: fileName,
            availability: .available,
            metadata: metadata,
            movePathProbe: probe
        ), conflicts)
    }

    private func probeOldPath(
        rootURL: URL,
        candidateRelativePath: String,
        resourceID: Data
    ) -> FolderMovePathProbe {
        let oldPathURL = rootURL.appendingPathComponent(candidateRelativePath)
        guard FileManager.default.fileExists(atPath: oldPathURL.path) else {
            return .oldPathMissing
        }
        guard let oldResourceID = FolderFileResourceProbe.resourceIdentifier(at: oldPathURL) else {
            return .oldPathProbeError
        }
        if oldResourceID == resourceID {
            return .oldPathSameResourceID
        }
        return .oldPathDifferentResourceID
    }

    @discardableResult
    private func flushBatch(
        lease: JobLeaseToken,
        sourceID: UUID,
        generation: Int,
        startedDirtyEpoch: Int,
        checkpoint: FolderReconcileCheckpointV1,
        observations: inout [FolderReconcileAssetObservation],
        context: JobLeaseExecutionContext
    ) throws -> FolderReconcileCheckpointV1 {
        let result = try context.reconcileBatch.commitAssetBatch(
            FolderAssetBatchInput(
                lease: lease,
                sourceID: sourceID,
                generation: generation,
                startedDirtyEpoch: startedDirtyEpoch,
                checkpoint: checkpoint,
                observations: observations,
                leaseDurationMs: context.leaseDurationMs,
                outcome: .continue
            )
        )
        observations.removeAll(keepingCapacity: true)
        return addIdentityConflicts(checkpoint, by: result.identityConflictsAdded)
    }

    private func settleIncomplete(
        lease: JobLeaseToken,
        sourceID: UUID,
        checkpoint: FolderReconcileCheckpointV1,
        code: JobSafeErrorCode,
        context: JobLeaseExecutionContext
    ) throws -> JobHandlerExecutionResult {
        let outcome = FolderReconcileSafeErrorSettlement.outcome(for: code)
        _ = try context.reconcileBatch.stopIncomplete(
            FolderStopIncompleteInput(
                lease: lease,
                sourceID: sourceID,
                checkpoint: checkpoint,
                leaseDurationMs: context.leaseDurationMs,
                errorCode: code,
                outcome: outcome
            )
        )
        return JobHandlerExecutionResult(
            outcome: outcome,
            checkpoint: try? makeJobCheckpoint(checkpoint),
            progress: JobProgress(completed: checkpoint.candidateFiles, total: nil),
            settledByHandler: true
        )
    }

    private func makeObservation(
        relativePath: String,
        fileName: String,
        availability: AssetAvailability,
        metadata: FolderMediaMetadata,
        movePathProbe: FolderMovePathProbe? = nil
    ) -> FolderReconcileAssetObservation {
        FolderReconcileAssetObservation(
            relativePath: relativePath,
            fileName: fileName,
            mediaType: metadata.mediaType,
            width: metadata.width,
            height: metadata.height,
            mediaCreatedAtMs: metadata.mediaCreatedAtMs,
            availability: availability,
            sizeBytes: metadata.sizeBytes,
            modifiedAtNs: metadata.modifiedAtNs,
            resourceID: metadata.resourceID,
            movePathProbe: movePathProbe
        )
    }

    private func addIdentityConflicts(_ checkpoint: FolderReconcileCheckpointV1, by count: Int) -> FolderReconcileCheckpointV1 {
        FolderReconcileCheckpointV1(
            generation: checkpoint.generation,
            startedDirtyEpoch: checkpoint.startedDirtyEpoch,
            attempt: checkpoint.attempt,
            enumeratedEntries: checkpoint.enumeratedEntries,
            candidateFiles: checkpoint.candidateFiles,
            committedAssets: checkpoint.committedAssets,
            ignoredEntries: checkpoint.ignoredEntries,
            unsupportedAssets: checkpoint.unsupportedAssets,
            unreadableAssets: checkpoint.unreadableAssets,
            identityConflicts: checkpoint.identityConflicts + count
        )
    }

    private func incrementEnumerated(_ checkpoint: FolderReconcileCheckpointV1) -> FolderReconcileCheckpointV1 {
        FolderReconcileCheckpointV1(
            generation: checkpoint.generation,
            startedDirtyEpoch: checkpoint.startedDirtyEpoch,
            attempt: checkpoint.attempt,
            enumeratedEntries: checkpoint.enumeratedEntries + 1,
            candidateFiles: checkpoint.candidateFiles,
            committedAssets: checkpoint.committedAssets,
            ignoredEntries: checkpoint.ignoredEntries,
            unsupportedAssets: checkpoint.unsupportedAssets,
            unreadableAssets: checkpoint.unreadableAssets,
            identityConflicts: checkpoint.identityConflicts
        )
    }

    private func incrementIgnored(_ checkpoint: FolderReconcileCheckpointV1) -> FolderReconcileCheckpointV1 {
        FolderReconcileCheckpointV1(
            generation: checkpoint.generation,
            startedDirtyEpoch: checkpoint.startedDirtyEpoch,
            attempt: checkpoint.attempt,
            enumeratedEntries: checkpoint.enumeratedEntries,
            candidateFiles: checkpoint.candidateFiles,
            committedAssets: checkpoint.committedAssets,
            ignoredEntries: checkpoint.ignoredEntries + 1,
            unsupportedAssets: checkpoint.unsupportedAssets,
            unreadableAssets: checkpoint.unreadableAssets,
            identityConflicts: checkpoint.identityConflicts
        )
    }

    private func incrementCandidate(_ checkpoint: FolderReconcileCheckpointV1) -> FolderReconcileCheckpointV1 {
        FolderReconcileCheckpointV1(
            generation: checkpoint.generation,
            startedDirtyEpoch: checkpoint.startedDirtyEpoch,
            attempt: checkpoint.attempt,
            enumeratedEntries: checkpoint.enumeratedEntries,
            candidateFiles: checkpoint.candidateFiles + 1,
            committedAssets: checkpoint.committedAssets,
            ignoredEntries: checkpoint.ignoredEntries,
            unsupportedAssets: checkpoint.unsupportedAssets,
            unreadableAssets: checkpoint.unreadableAssets,
            identityConflicts: checkpoint.identityConflicts
        )
    }

    private func incrementCommitted(
        _ checkpoint: FolderReconcileCheckpointV1,
        unsupported: Bool = false,
        unreadable: Bool = false
    ) -> FolderReconcileCheckpointV1 {
        FolderReconcileCheckpointV1(
            generation: checkpoint.generation,
            startedDirtyEpoch: checkpoint.startedDirtyEpoch,
            attempt: checkpoint.attempt,
            enumeratedEntries: checkpoint.enumeratedEntries,
            candidateFiles: checkpoint.candidateFiles,
            committedAssets: checkpoint.committedAssets + 1,
            ignoredEntries: checkpoint.ignoredEntries,
            unsupportedAssets: checkpoint.unsupportedAssets + (unsupported ? 1 : 0),
            unreadableAssets: checkpoint.unreadableAssets + (unreadable ? 1 : 0),
            identityConflicts: checkpoint.identityConflicts
        )
    }

    private func failWithCode(
        lease: JobLeaseToken,
        sourceID: UUID,
        code: JobSafeErrorCode,
        persisted: PersistedJobContext,
        context: JobLeaseExecutionContext
    ) throws -> JobHandlerExecutionResult {
        let outcome = FolderReconcileSafeErrorSettlement.outcome(for: code)
        let checkpoint = persisted.scanGeneration.map { generation in
            FolderReconcileCheckpointV1(
                generation: generation,
                startedDirtyEpoch: persisted.startedDirtyEpoch ?? 0,
                attempt: lease.attempts
            )
        }
        _ = try context.reconcileBatch.stopIncomplete(
            FolderStopIncompleteInput(
                lease: lease,
                sourceID: sourceID,
                checkpoint: checkpoint,
                leaseDurationMs: context.leaseDurationMs,
                errorCode: code,
                outcome: outcome
            )
        )
        return JobHandlerExecutionResult(
            outcome: outcome,
            checkpoint: checkpoint.flatMap { try? makeJobCheckpoint($0) },
            progress: JobProgress(completed: persisted.progressCompleted, total: nil),
            settledByHandler: true
        )
    }

    private func makeJobCheckpoint(_ checkpoint: FolderReconcileCheckpointV1) throws -> JobCheckpoint {
        JobCheckpoint(version: 1, data: try FolderReconcileCheckpointCodec.encode(checkpoint))
    }

    private func resolvePersistedJob(
        lease: JobLeaseToken,
        context: JobLeaseExecutionContext
    ) throws -> PersistedJobContext {
        let job = try context.jobLookup.fetchJobContext(jobID: lease.jobID)
        return PersistedJobContext(
            sourceID: job.sourceID,
            scanGeneration: job.scanGeneration,
            startedDirtyEpoch: job.startedDirtyEpoch,
            progressCompleted: job.progressCompleted
        )
    }

    private func validSourceIDFromPayload(_ payload: Data) -> UUID {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let sourceIDString = object["source_id"] as? String,
              let sourceID = UUID(uuidString: sourceIDString)
        else {
            return UUID()
        }
        return sourceID
    }
}

enum FolderFileResourceProbe {
    static func resourceIdentifier(at url: URL) -> Data? {
        let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
        guard let object = values?.fileResourceIdentifier else {
            return nil
        }
        if let data = object as? Data {
            return data
        }
        if let number = object as? NSNumber {
            return number.stringValue.data(using: .utf8)
        }
        return nil
    }
}

private enum FolderReconcileTraversalFailure: Error {
    case unsafeRelativePath
    case incomplete
}

private struct PersistedJobContext {
    let sourceID: UUID?
    let scanGeneration: Int?
    let startedDirtyEpoch: Int?
    let progressCompleted: Int
}
