import Foundation

struct FolderReconcileRootAccessAdapter: Sendable {
    let repository: GRDBFolderSourceAuthorizationRepository
    let bookmarkPort: any SecurityScopedBookmarkPort

    func withActiveSourceRootURL<T>(sourceID: UUID, perform: (URL) throws -> T) throws -> T {
        switch try repository.lookupSource(id: sourceID) {
        case .notFound:
            throw FolderReconcileHandlerError.sourceUnavailable
        case .wrongKind:
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

            let resolved = try bookmarkPort.resolveBookmark(record.bookmark)
            let started = bookmarkPort.startAccessing(resolved.url)
            guard started else {
                throw FolderReconcileHandlerError.authorizationRequired
            }
            defer {
                bookmarkPort.stopAccessing(resolved.url)
            }
            return try perform(resolved.url)
        }
    }
}

enum FolderReconcileHandlerError: Error, Equatable {
    case sourceUnavailable
    case authorizationRequired
    case enumerationIncomplete
}

struct FolderReconcileHandler: LeaseBoundJobHandler {
    let rootAccess: FolderReconcileRootAccessAdapter
    let enumerationConfig: FolderEnumerationConfig

    var kind: String { FolderReconcileJobFactory.kind }
    var supportedPayloadVersions: Set<Int> { [FolderReconcileJobFactory.payloadVersion] }
    var supportedCheckpointVersions: Set<Int> { [1] }

    init(
        rootAccess: FolderReconcileRootAccessAdapter,
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
        let persisted = try resolvePersistedJob(lease: lease, batchPort: context.reconcileBatch)
        switch FolderReconcilePayloadValidation.validate(
            payloadVersion: payloadVersion,
            payload: payload,
            jobSourceID: persisted.sourceID
        ) {
        case let .success(valid):
            return try runReconcile(
                lease: lease,
                sourceID: valid.sourceID,
                checkpoint: checkpoint,
                persisted: persisted,
                context: context
            )
        case let .failure(.invalid(code)):
            if let sourceID = persisted.sourceID {
                _ = try context.reconcileBatch.stopIncomplete(
                    FolderStopIncompleteInput(
                        lease: lease,
                        sourceID: sourceID,
                        checkpoint: makeEmptyCheckpoint(lease: lease, persisted: persisted),
                        leaseDurationMs: context.leaseDurationMs,
                        errorCode: code
                    )
                )
            }
            return JobHandlerExecutionResult(
                outcome: .nonRetryableFailure(code: code),
                checkpoint: nil,
                progress: JobProgress(completed: persisted.progressCompleted, total: nil),
                settledByHandler: true
            )
        }
    }

    private func runReconcile(
        lease: JobLeaseToken,
        sourceID: UUID,
        checkpoint: JobCheckpoint?,
        persisted: PersistedJobContext,
        context: JobLeaseExecutionContext
    ) throws -> JobHandlerExecutionResult {
        if let checkpoint, checkpoint.version != 1 {
            return try failNonRetryable(
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
                guard FolderReconcileCheckpointCodec.validateAgainstJob(
                    decoded,
                    scanGeneration: persisted.scanGeneration,
                    startedDirtyEpoch: persisted.startedDirtyEpoch
                ) else {
                    return try failNonRetryable(
                        lease: lease,
                        sourceID: sourceID,
                        code: FolderReconcileSafeErrorCode.checkpointInvalid,
                        persisted: persisted,
                        context: context
                    )
                }
            } catch {
                return try failNonRetryable(
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
                    leaseDurationMs: context.leaseDurationMs
                )
            )
        } catch let error as FolderReconcileRepositoryError where error == .checkpointInvalid {
            return try failNonRetryable(
                lease: lease,
                sourceID: sourceID,
                code: FolderReconcileSafeErrorCode.checkpointInvalid,
                persisted: persisted,
                context: context
            )
        } catch let error as JobQueueError {
            if case .staleLease = error {
                throw error
            }
            if case .expiredLease = error {
                throw error
            }
            throw error
        }

        var currentCheckpoint = begin.checkpoint
        var pendingObservations: [FolderReconcileAssetObservation] = []
        let classifier = FolderMediaClassifier()

        do {
            try rootAccess.withActiveSourceRootURL(sourceID: sourceID) { rootURL in
                let enumerator = FolderDirectoryEnumerator(rootURL: rootURL, config: enumerationConfig)
                let (hadDirectoryError, finished) = try enumerator.enumerate { entry in
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
                            pendingObservations.append(makeObservation(
                                relativePath: relativePath,
                                fileName: fileName,
                                availability: .available,
                                metadata: metadata
                            ))
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
                        || shouldFlushBoundary(currentCheckpoint)
                    {
                        try flushBatch(
                            lease: lease,
                            sourceID: sourceID,
                            generation: begin.generation,
                            startedDirtyEpoch: begin.startedDirtyEpoch,
                            checkpoint: &currentCheckpoint,
                            observations: &pendingObservations,
                            context: context,
                            force: true
                        )
                    }
                }

                if hadDirectoryError || !finished {
                    throw FolderReconcileTraversalFailure.incomplete
                }

                try flushBatch(
                    lease: lease,
                    sourceID: sourceID,
                    generation: begin.generation,
                    startedDirtyEpoch: begin.startedDirtyEpoch,
                    checkpoint: &currentCheckpoint,
                    observations: &pendingObservations,
                    context: context,
                    force: true
                )
            }
        } catch FolderReconcileTraversalFailure.unsafeRelativePath {
            _ = try context.reconcileBatch.stopIncomplete(
                FolderStopIncompleteInput(
                    lease: lease,
                    sourceID: sourceID,
                    checkpoint: currentCheckpoint,
                    leaseDurationMs: context.leaseDurationMs,
                    errorCode: FolderReconcileSafeErrorCode.unsafeRelativePath
                )
            )
            return settledRetryable(
                checkpoint: currentCheckpoint,
                code: FolderReconcileSafeErrorCode.unsafeRelativePath
            )
        } catch FolderReconcileHandlerError.authorizationRequired {
            _ = try context.reconcileBatch.stopIncomplete(
                FolderStopIncompleteInput(
                    lease: lease,
                    sourceID: sourceID,
                    checkpoint: currentCheckpoint,
                    leaseDurationMs: context.leaseDurationMs,
                    errorCode: FolderReconcileSafeErrorCode.authorizationRequired
                )
            )
            return settledNonRetryable(code: FolderReconcileSafeErrorCode.authorizationRequired, checkpoint: currentCheckpoint)
        } catch FolderReconcileHandlerError.sourceUnavailable, FolderReconcileTraversalFailure.incomplete {
            _ = try context.reconcileBatch.stopIncomplete(
                FolderStopIncompleteInput(
                    lease: lease,
                    sourceID: sourceID,
                    checkpoint: currentCheckpoint,
                    leaseDurationMs: context.leaseDurationMs,
                    errorCode: FolderReconcileSafeErrorCode.enumerationIncomplete
                )
            )
            return settledRetryable(checkpoint: currentCheckpoint, code: FolderReconcileSafeErrorCode.enumerationIncomplete)
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

        return JobHandlerExecutionResult(
            outcome: .completed,
            checkpoint: try makeJobCheckpoint(currentCheckpoint),
            progress: JobProgress(completed: currentCheckpoint.candidateFiles, total: nil),
            settledByHandler: true
        )
    }

    private func flushBatch(
        lease: JobLeaseToken,
        sourceID: UUID,
        generation: Int,
        startedDirtyEpoch: Int,
        checkpoint: inout FolderReconcileCheckpointV1,
        observations: inout [FolderReconcileAssetObservation],
        context: JobLeaseExecutionContext,
        force: Bool = false
    ) throws {
        guard force || !observations.isEmpty || shouldFlushBoundary(checkpoint) else {
            return
        }
        _ = try context.reconcileBatch.commitAssetBatch(
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
    }

    private func shouldFlushBoundary(_ checkpoint: FolderReconcileCheckpointV1) -> Bool {
        checkpoint.enumeratedEntries % enumerationConfig.workUnitLimit == 0
            && checkpoint.enumeratedEntries > 0
    }

    private func makeObservation(
        relativePath: String,
        fileName: String,
        availability: AssetAvailability,
        metadata: FolderMediaMetadata
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
            resourceID: metadata.resourceID
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

    private func failNonRetryable(
        lease: JobLeaseToken,
        sourceID: UUID,
        code: JobSafeErrorCode,
        persisted: PersistedJobContext,
        context: JobLeaseExecutionContext
    ) throws -> JobHandlerExecutionResult {
        _ = try context.reconcileBatch.stopIncomplete(
            FolderStopIncompleteInput(
                lease: lease,
                sourceID: sourceID,
                checkpoint: makeEmptyCheckpoint(lease: lease, persisted: persisted),
                leaseDurationMs: context.leaseDurationMs,
                errorCode: code
            )
        )
        return settledNonRetryable(code: code, checkpoint: makeEmptyCheckpoint(lease: lease, persisted: persisted))
    }

    private func settledNonRetryable(code: JobSafeErrorCode, checkpoint: FolderReconcileCheckpointV1) -> JobHandlerExecutionResult {
        JobHandlerExecutionResult(
            outcome: .nonRetryableFailure(code: code),
            checkpoint: try? makeJobCheckpoint(checkpoint),
            progress: JobProgress(completed: checkpoint.candidateFiles, total: nil),
            settledByHandler: true
        )
    }

    private func settledRetryable(checkpoint: FolderReconcileCheckpointV1, code: JobSafeErrorCode) -> JobHandlerExecutionResult {
        JobHandlerExecutionResult(
            outcome: .retryableFailure(code: code),
            checkpoint: try? makeJobCheckpoint(checkpoint),
            progress: JobProgress(completed: checkpoint.candidateFiles, total: nil),
            settledByHandler: true
        )
    }

    private func makeJobCheckpoint(_ checkpoint: FolderReconcileCheckpointV1) throws -> JobCheckpoint {
        JobCheckpoint(version: 1, data: try FolderReconcileCheckpointCodec.encode(checkpoint))
    }

    private func makeEmptyCheckpoint(lease: JobLeaseToken, persisted: PersistedJobContext) -> FolderReconcileCheckpointV1 {
        FolderReconcileCheckpointV1(
            generation: persisted.scanGeneration ?? 1,
            startedDirtyEpoch: persisted.startedDirtyEpoch ?? 0,
            attempt: lease.attempts
        )
    }

    private func resolvePersistedJob(
        lease: JobLeaseToken,
        batchPort: any FolderReconcileBatchPort
    ) throws -> PersistedJobContext {
        guard let repository = batchPort as? GRDBFolderReconcileRepository else {
            return PersistedJobContext(sourceID: nil, scanGeneration: nil, startedDirtyEpoch: nil, progressCompleted: 0)
        }
        return try repository.queue.fetchJob(id: lease.jobID).mapToPersisted()
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

private extension JobRecordSnapshot {
    func mapToPersisted() -> PersistedJobContext {
        PersistedJobContext(
            sourceID: sourceID,
            scanGeneration: scanGeneration,
            startedDirtyEpoch: startedDirtyEpoch,
            progressCompleted: progress.completed
        )
    }
}
