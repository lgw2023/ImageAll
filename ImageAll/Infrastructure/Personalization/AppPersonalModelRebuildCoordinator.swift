import CryptoKit
import Foundation

struct AppPersonalTrainingSnapshotPortSource: AppPersonalTrainingSnapshotSource {
    let readSnapshot: @Sendable () throws -> PersonalTrainingSnapshot

    init(readSnapshot: @escaping @Sendable () throws -> PersonalTrainingSnapshot) {
        self.readSnapshot = readSnapshot
    }

    func currentSnapshot() async throws -> PersonalTrainingSnapshot {
        try readSnapshot()
    }
}

struct AppPersonalTrainingEmbeddingCacheSource: AppPersonalTrainingEmbeddingSource {
    let cache: AppCoreMLEmbeddingCache

    func cachedEmbedding(
        for key: PersonalTrainingEmbeddingCacheKey
    ) async throws -> PersonalTrainingEmbedding? {
        guard let catalogScopeID = UUID(uuidString: key.catalogScopeID) else {
            return nil
        }
        return try cache.cachedEmbedding(
            for: AppCoreMLEmbeddingCacheKey(
                catalogScopeID: catalogScopeID,
                assetID: key.assetID,
                contentRevision: Int64(key.contentRevision)
            )
        ).map {
            PersonalTrainingEmbedding(
                encoder: PersonalTrainingEncoderIdentity($0.identity),
                values: $0.values
            )
        }
    }
}

actor AppPersonalModelRebuildRuntime: AppPersonalModelRebuilding {
    private let expectedCatalogScopeID: String
    private let activationCoordinator: AppModelActivationCoordinator
    private let cachesDirectory: URL
    private let applicationSupportDirectory: URL
    private let family: AppPersonalLinearHeadFamily
    private let database: CatalogDatabase?
    private let clock: any JobClock
    private let beforeDatabasePublish: (@Sendable () throws -> Void)?
    private var isRebuilding = false
    private var activeCoordinator: AppPersonalModelRebuildCoordinator?

    init(
        expectedCatalogScopeID: String,
        activationCoordinator: AppModelActivationCoordinator,
        cachesDirectory: URL,
        applicationSupportDirectory: URL,
        family: AppPersonalLinearHeadFamily = .centroid,
        database: CatalogDatabase? = nil,
        clock: any JobClock = SystemJobClock(),
        beforeDatabasePublish: (@Sendable () throws -> Void)? = nil
    ) {
        self.expectedCatalogScopeID = expectedCatalogScopeID
        self.activationCoordinator = activationCoordinator
        self.cachesDirectory = cachesDirectory
        self.applicationSupportDirectory = applicationSupportDirectory
        self.family = family
        self.database = database
        self.clock = clock
        self.beforeDatabasePublish = beforeDatabasePublish
    }

    func rebuild(
        snapshotSource: any AppPersonalTrainingSnapshotSource
    ) async throws -> AppPersonalLinearHeadIdentity {
        guard !isRebuilding else {
            throw AppPersonalModelRebuildError.alreadyRunning
        }
        isRebuilding = true
        defer { isRebuilding = false }
        guard let service = await activationCoordinator.readyService(),
              case let .ready(identity) = service.availability
        else {
            throw AppPersonalModelRebuildError.modelUnavailable
        }
        let source = try await snapshotSource.currentSnapshot()
        let runID = try beginTrainingRun(snapshot: source)
        let auditedSnapshotSource = AppPersonalPinnedFirstSnapshotSource(
            initial: source,
            following: snapshotSource
        )
        let store = AppPersonalLinearHeadStore(
            applicationSupportDirectory: applicationSupportDirectory,
            expectedCatalogScopeID: expectedCatalogScopeID,
            expectedEncoderIdentity: identity,
            family: family
        )
        let coordinator = AppPersonalModelRebuildCoordinator(
            expectedCatalogScopeID: expectedCatalogScopeID,
            encoderIdentity: identity,
            snapshotSource: auditedSnapshotSource,
            embeddingSource: AppPersonalTrainingEmbeddingCacheSource(
                cache: AppCoreMLEmbeddingCache(
                    cachesDirectory: cachesDirectory,
                    service: service
                )
            ),
            store: store,
            family: family
        )
        activeCoordinator = coordinator
        defer { activeCoordinator = nil }
        do {
            if let database {
                let review = GRDBPersonalizationReviewRepository(database: database)
                let publishedArtifactSHA256 = try review.publishedArtifactSHA256(
                    method: family.personalSuggestionMethod
                )
                if publishedArtifactSHA256 == nil,
                   try review.usesLegacyActivePointer(method: family.personalSuggestionMethod)
                {
                    _ = await store.start()
                } else {
                    _ = await store.start(
                        publishedArtifactSHA256: publishedArtifactSHA256
                    )
                }
            } else {
                _ = await store.start()
            }
            let execution = try await coordinator.rebuildExecution(
                activateImmediately: database == nil
            )
            if let database, let runID {
                let finishedAtMs = clock.nowMs
                let capability = AppPersonalSuggestionCapabilityMapper.capability(
                    from: execution.identity,
                    family: family
                )
                let review = GRDBPersonalizationReviewRepository(database: database)
                let runs = GRDBTrainingRunRepository(database: database)
                let resultSummaryJSON = try Self.successResultSummary(
                    snapshot: source
                )
                try await database.pool.write { db in
                    try beforeDatabasePublish?()
                    try review.activatePersonalSuggestionBundle(
                        capability,
                        activatedAtMs: finishedAtMs,
                        publishedRunID: runID,
                        on: db
                    )
                    try runs.update(
                        id: runID,
                        state: .succeeded,
                        finishedAtMs: finishedAtMs,
                        metricsJSON: execution.metricsJSON,
                        artifactKind: execution.artifactKind,
                        artifactRef: execution.artifactRef,
                        artifactSHA256: execution.artifactSHA256,
                        resultSummaryJSON: resultSummaryJSON,
                        on: db
                    )
                }
                _ = await store.start(
                    publishedArtifactSHA256: execution.artifactSHA256
                )
            }
            return execution.identity
        } catch {
            if let database, let runID {
                let terminalState: TrainingRunState = Self.isCancellation(error)
                    ? .cancelled
                    : .failed
                do {
                    try GRDBTrainingRunRepository(database: database).update(
                        id: runID,
                        state: terminalState,
                        finishedAtMs: clock.nowMs,
                        resultSummaryJSON: #"{"published":false}"#,
                        errorCode: terminalState == .failed ? Self.errorCode(error) : nil
                    )
                } catch {
                    throw PersonalizationReviewError.persistenceFailure
                }
            }
            throw error
        }
    }

    func cancel() async {
        await activeCoordinator?.cancel()
    }

    private func beginTrainingRun(snapshot: PersonalTrainingSnapshot) throws -> UUID? {
        guard let database else { return nil }
        let runID = UUID()
        let nowMs = clock.nowMs
        let runs = GRDBTrainingRunRepository(database: database)
        try database.pool.write { db in
            try runs.insert(
                TrainingRunRecord(
                    id: runID,
                    method: family.trainingRunMethod,
                    state: .queued,
                    createdAtMs: nowMs,
                    startedAtMs: nil,
                    finishedAtMs: nil,
                    catalogScopeID: expectedCatalogScopeID,
                    jobID: nil,
                    sampleSummaryJSON: try Self.sampleSummary(snapshot: snapshot),
                    sampleManifestSHA256: nil,
                    configJSON: try Self.configJSON(family: family),
                    metricsJSON: "{}",
                    artifactKind: nil,
                    artifactRef: nil,
                    artifactSHA256: nil,
                    resultSummaryJSON: "{}",
                    errorCode: nil
                ),
                on: db
            )
            try runs.update(
                id: runID,
                state: .running,
                startedAtMs: nowMs,
                on: db
            )
        }
        return runID
    }

    private static func sampleSummary(snapshot: PersonalTrainingSnapshot) throws -> String {
        let tags = snapshot.personalTagIDs.sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }.map { tagID -> [String: Any] in
            let decisions = snapshot.decisions.filter { $0.tagID == tagID }
            return [
                "tagID": tagID.uuidString.lowercased(),
                "positiveCount": decisions.filter { $0.state == .manualAccepted }.count,
                "negativeCount": decisions.filter { $0.state == .manualRejected }.count,
            ]
        }
        let samples = Set(snapshot.decisions.map {
            TrainingRunSampleIdentity(
                assetID: $0.assetID,
                contentRevision: $0.contentRevision
            )
        })
        return try AppPersonalTrainingRunJSON.object([
            "scope": "resolvedSnapshot",
            "tagCount": snapshot.personalTagIDs.count,
            "sampleCount": samples.count,
            "perTag": tags,
        ])
    }

    private static func configJSON(family: AppPersonalLinearHeadFamily) throws -> String {
        switch family {
        case .centroid:
            return try AppPersonalTrainingRunJSON.object([
                "algorithmRevision": AppPersonalLinearHeadTrainer.algorithmRevision,
                "minimumAcceptedPerTag": 2,
            ])
        case .adamW:
            let config = AppPersonalAdamWTrainingConfig.default
            return try AppPersonalTrainingRunJSON.object([
                "algorithmRevision": AppPersonalAdamWLinearHeadTrainer.algorithmRevision,
                "maxEpochs": config.maxEpochs,
                "learningRate": config.learningRate,
                "weightDecay": config.weightDecay,
                "beta1": config.beta1,
                "beta2": config.beta2,
                "epsilon": config.epsilon,
                "patience": config.patience,
                "validationFraction": config.validationFraction,
                "seed": Int(config.seed),
                "minimumAcceptedPerTag": 2,
            ])
        }
    }

    private static func successResultSummary(
        snapshot: PersonalTrainingSnapshot
    ) throws -> String {
        let samples = Set(snapshot.decisions.map {
            TrainingRunSampleIdentity(
                assetID: $0.assetID,
                contentRevision: $0.contentRevision
            )
        })
        return try AppPersonalTrainingRunJSON.object([
            "published": true,
            "tagCount": snapshot.personalTagIDs.count,
            "sampleCount": samples.count,
        ])
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? AppPersonalModelRebuildError) == .cancelled
    }

    private static func errorCode(_ error: Error) -> String {
        guard let rebuild = error as? AppPersonalModelRebuildError else {
            return "trainingFailed"
        }
        return switch rebuild {
        case .alreadyRunning: "alreadyRunning"
        case .cancelled: "cancelled"
        case .invalidSnapshot: "invalidSnapshot"
        case .modelUnavailable: "modelUnavailable"
        case .embeddingUnavailable: "embeddingUnavailable"
        case .staleSnapshot: "staleSnapshot"
        }
    }
}

private actor AppPersonalPinnedFirstSnapshotSource: AppPersonalTrainingSnapshotSource {
    private var initial: PersonalTrainingSnapshot?
    private let following: any AppPersonalTrainingSnapshotSource

    init(
        initial: PersonalTrainingSnapshot,
        following: any AppPersonalTrainingSnapshotSource
    ) {
        self.initial = initial
        self.following = following
    }

    func currentSnapshot() async throws -> PersonalTrainingSnapshot {
        if let initial {
            self.initial = nil
            return initial
        }
        return try await following.currentSnapshot()
    }
}

struct AppPersonalModelRebuildExecution: Equatable, Sendable {
    let identity: AppPersonalLinearHeadIdentity
    let metricsJSON: String
    let artifactKind: String
    let artifactRef: String
    let artifactSHA256: String
}

actor AppPersonalModelRebuildCoordinator {
    private let expectedCatalogScopeID: String
    private let encoderIdentity: AppCoreMLModelIdentity
    private let snapshotSource: any AppPersonalTrainingSnapshotSource
    private let embeddingSource: any AppPersonalTrainingEmbeddingSource
    private let store: AppPersonalLinearHeadStore
    private let family: AppPersonalLinearHeadFamily
    private var activeTask: Task<AppPersonalModelRebuildExecution, Error>?

    init(
        expectedCatalogScopeID: String,
        encoderIdentity: AppCoreMLModelIdentity,
        snapshotSource: any AppPersonalTrainingSnapshotSource,
        embeddingSource: any AppPersonalTrainingEmbeddingSource,
        store: AppPersonalLinearHeadStore,
        family: AppPersonalLinearHeadFamily = .centroid
    ) {
        self.expectedCatalogScopeID = expectedCatalogScopeID
        self.encoderIdentity = encoderIdentity
        self.snapshotSource = snapshotSource
        self.embeddingSource = embeddingSource
        self.store = store
        self.family = family
    }

    func rebuild() async throws -> AppPersonalLinearHeadIdentity {
        try await rebuildExecution().identity
    }

    func rebuildExecution(
        activateImmediately: Bool = true
    ) async throws -> AppPersonalModelRebuildExecution {
        guard activeTask == nil else {
            throw AppPersonalModelRebuildError.alreadyRunning
        }
        let task = Task {
            try await self.performRebuild(activateImmediately: activateImmediately)
        }
        activeTask = task
        defer { activeTask = nil }
        do {
            return try await task.value
        } catch is CancellationError {
            throw AppPersonalModelRebuildError.cancelled
        }
    }

    func cancel() {
        activeTask?.cancel()
    }

    private func performRebuild(
        activateImmediately: Bool
    ) async throws -> AppPersonalModelRebuildExecution {
        try Task.checkCancellation()
        let source = try await snapshotSource.currentSnapshot()
        try Task.checkCancellation()
        guard source.catalogScopeID == expectedCatalogScopeID else {
            throw AppPersonalModelRebuildError.invalidSnapshot
        }
        let expectedEncoder = PersonalTrainingEncoderIdentity(encoderIdentity)
        let revisions = Set(source.decisions.map {
            AssetRevision(assetID: $0.assetID, contentRevision: $0.contentRevision)
        }).sorted(by: AssetRevision.isOrderedBefore)
        var embeddings: [PersonalTrainingEmbeddingRow] = []
        for revision in revisions {
            let key = PersonalTrainingEmbeddingCacheKey(
                catalogScopeID: source.catalogScopeID,
                assetID: revision.assetID,
                contentRevision: revision.contentRevision
            )
            let cached: PersonalTrainingEmbedding?
            do {
                cached = try await embeddingSource.cachedEmbedding(for: key)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AppPersonalModelRebuildError.embeddingUnavailable
            }
            guard let embedding = cached,
                  embedding.encoder == expectedEncoder
            else {
                throw AppPersonalModelRebuildError.embeddingUnavailable
            }
            try Task.checkCancellation()
            embeddings.append(
                PersonalTrainingEmbeddingRow(
                    assetID: revision.assetID,
                    contentRevision: revision.contentRevision,
                    values: embedding.values
                )
            )
        }
        let tagIDs = source.personalTagIDs.sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        let decisionSnapshotRevision = Self.decisionSnapshotRevision(source)
        let labelVocabularyRevision = Self.labelVocabularyRevision(tagIDs)
        let snapshot = PersonalModelRebuildSnapshot(
            catalogScopeID: source.catalogScopeID,
            decisionSnapshotRevision: decisionSnapshotRevision,
            encoder: expectedEncoder,
            personalTagIDs: tagIDs,
            labelVocabularyRevision: labelVocabularyRevision,
            embeddings: embeddings,
            decisions: source.decisions
        )
        let artifact: AppPersonalLinearHeadArtifact
        let metricsJSON: String
        do {
            switch family {
            case .centroid:
                artifact = try AppPersonalLinearHeadTrainer.train(
                    snapshot: snapshot,
                    encoderIdentity: encoderIdentity
                )
                metricsJSON = "{}"
            case .adamW:
                let trained = try AppPersonalAdamWLinearHeadTrainer.train(
                    snapshot: snapshot,
                    encoderIdentity: encoderIdentity
                )
                artifact = trained.0
                metricsJSON = try Self.metricsJSON(report: trained.1)
            }
        } catch {
            throw AppPersonalModelRebuildError.invalidSnapshot
        }
        let current = try await snapshotSource.currentSnapshot()
        try Task.checkCancellation()
        let currentTagIDs = current.personalTagIDs.sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        guard Self.decisionSnapshotRevision(current) == decisionSnapshotRevision,
              Self.labelVocabularyRevision(currentTagIDs) == labelVocabularyRevision
        else {
            throw AppPersonalModelRebuildError.staleSnapshot
        }
        let staged = try await store.stage(artifact)
        let identity: AppPersonalLinearHeadIdentity
        if activateImmediately {
            let capability = try await store.activate(
                artifactSHA256: staged.artifactSHA256
            )
            guard case let .ready(activeIdentity) = capability else {
                throw AppPersonalModelRebuildError.invalidSnapshot
            }
            identity = activeIdentity
        } else {
            identity = staged.identity
        }
        return AppPersonalModelRebuildExecution(
            identity: identity,
            metricsJSON: metricsJSON,
            artifactKind: family.artifactKind,
            artifactRef: family.artifactRef(sha256: staged.artifactSHA256),
            artifactSHA256: staged.artifactSHA256
        )
    }

    private static func metricsJSON(
        report: AppPersonalAdamWTrainingReport
    ) throws -> String {
        try AppPersonalTrainingRunJSON.object([
            "epochsRun": report.epochsRun,
            "bestValidationLoss": report.bestValidationLoss,
            "stoppedEarly": report.stoppedEarly,
            "epochs": report.epochMetrics.map {
                [
                    "epoch": $0.epoch,
                    "validationLoss": $0.validationLoss,
                ] as [String: Any]
            },
        ])
    }

    private static func labelVocabularyRevision(_ tagIDs: [UUID]) -> String {
        sha256(tagIDs.map { $0.uuidString.lowercased() }.joined(separator: "\n"))
    }

    private static func decisionSnapshotRevision(_ snapshot: PersonalTrainingSnapshot) -> String {
        let decisions = snapshot.decisions.sorted { lhs, rhs in
            decisionKey(lhs) < decisionKey(rhs)
        }
        let lines = ["catalog|\(snapshot.catalogScopeID)"]
            + snapshot.personalTagIDs.map { "tag|\($0.uuidString.lowercased())" }.sorted()
            + decisions.map {
                "decision|\($0.assetID.uuidString.lowercased())|\($0.contentRevision)|\($0.tagID.uuidString.lowercased())|\($0.state.rawValue)"
            }
        return sha256(lines.joined(separator: "\n"))
    }

    private static func decisionKey(_ decision: PersonalTrainingDecision) -> String {
        "\(decision.tagID.uuidString.lowercased())|\(decision.assetID.uuidString.lowercased())|\(decision.contentRevision)|\(decision.state.rawValue)"
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private struct AssetRevision: Hashable {
        let assetID: UUID
        let contentRevision: Int

        static func isOrderedBefore(_ lhs: Self, _ rhs: Self) -> Bool {
            let lhsID = lhs.assetID.uuidString.lowercased()
            let rhsID = rhs.assetID.uuidString.lowercased()
            return lhsID == rhsID
                ? lhs.contentRevision < rhs.contentRevision
                : lhsID < rhsID
        }
    }
}

private struct TrainingRunSampleIdentity: Hashable {
    let assetID: UUID
    let contentRevision: Int
}

private enum AppPersonalTrainingRunJSON {
    static func object(_ value: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw AppPersonalModelRebuildError.invalidSnapshot
        }
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
        )
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw AppPersonalModelRebuildError.invalidSnapshot
        }
        return encoded
    }
}

extension AppPersonalLinearHeadFamily {
    var personalSuggestionMethod: PersonalSuggestionMethod {
        switch self {
        case .centroid: .personalCentroid
        case .adamW: .personalAdamW
        }
    }

    var trainingRunMethod: TrainingRunMethod {
        switch self {
        case .centroid: .personalCentroid
        case .adamW: .personalAdamW
        }
    }

    var artifactKind: String {
        switch self {
        case .centroid: "personalCentroidHead"
        case .adamW: "personalAdamWHead"
        }
    }

    func artifactRef(sha256: String) -> String {
        "PersonalModels/\(directoryName)/v1/objects/\(sha256).\(objectExtension)"
    }
}

extension PersonalTrainingEncoderIdentity {
    init(_ identity: AppCoreMLModelIdentity) {
        self.init(
            provider: identity.provider,
            modelID: identity.modelID,
            modelRevision: identity.modelRevision,
            preprocessingRevision: identity.preprocessingRevision,
            elementCount: identity.elementCount
        )
    }
}
