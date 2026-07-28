import Foundation
import GRDB

struct LibrarySlimmingScanService: LibrarySlimmingScanPort {
    let database: CatalogDatabase
    let identicalScan: any IdenticalDuplicateScanPort
    let fingerprintCompletion: (any FingerprintCompletionPort)?
    let featureLoader: any SlimmingFeatureVectorLoading
    let embeddingLoader: any SlimmingEmbeddingLoading
    let thresholdReader: any NearDuplicateSceneThresholdReading
    let bucketCalendar: Calendar
    /// ADR-045 LS-P11: when set, `scanSeeds` narrows the vector-load/compare set to each
    /// seed's Feature Print LSH neighborhood whenever the whole universe is index-ready.
    let sourceIndex: (any SourceSimilarityIndexPort)?

    init(
        database: CatalogDatabase,
        identicalScan: any IdenticalDuplicateScanPort,
        fingerprintCompletion: (any FingerprintCompletionPort)?,
        featureLoader: any SlimmingFeatureVectorLoading,
        embeddingLoader: any SlimmingEmbeddingLoading,
        thresholdReader: any NearDuplicateSceneThresholdReading = StaticNearDuplicateSceneThresholds(
            value: .factory
        ),
        bucketCalendar: Calendar = .current,
        sourceIndex: (any SourceSimilarityIndexPort)? = nil
    ) {
        self.database = database
        self.identicalScan = identicalScan
        self.fingerprintCompletion = fingerprintCompletion
        self.featureLoader = featureLoader
        self.embeddingLoader = embeddingLoader
        self.thresholdReader = thresholdReader
        self.bucketCalendar = bucketCalendar
        self.sourceIndex = sourceIndex
    }

    func scanCatalog(onProgress: LibrarySlimmingScanProgressHandler?) throws -> LibrarySlimmingScanResult {
        let assetIDs = try database.pool.read { db -> [UUID] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT a.id
                FROM asset a
                JOIN asset_locator l ON l.asset_id = a.id
                JOIN source s ON s.id = a.source_id
                WHERE l.state = ?
                  AND a.availability = ?
                  AND s.state = ?
                ORDER BY a.id ASC
                """,
                arguments: [
                    AssetLocatorState.current.rawValue,
                    AssetAvailability.available.rawValue,
                    SourceState.active.rawValue,
                ]
            )
            return rows.compactMap { row in
                UUID(uuidString: row["id"])
            }
        }
        return try scan(assetIDs: assetIDs, onProgress: onProgress)
    }

    func scanSeeds(
        seedAssetIDs: [UUID],
        universeAssetIDs: [UUID],
        onProgress: LibrarySlimmingScanProgressHandler? = nil
    ) throws -> LibrarySlimmingScanResult {
        let seeds = Array(Set(seedAssetIDs)).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        let universe = Array(Set(universeAssetIDs).union(seeds)).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        guard !seeds.isEmpty else {
            return LibrarySlimmingScanResult(
                clusters: [],
                pendingAnalysisAssetIDs: [],
                analyzedAssetCount: 0,
                policyVersion: thresholdReader.thresholds().policyVersion
            )
        }

        let thresholds = thresholdReader.thresholds().clamped()

        (featureLoader as? SlimmingBudgetResetting)?
            .resetScanBudgets(forAssetCount: universe.count)
        (embeddingLoader as? SlimmingBudgetResetting)?
            .resetScanBudgets(forAssetCount: universe.count)

        try prepareFingerprints(assetIDs: universe, onProgress: onProgress)

        onProgress?(
            LibrarySlimmingScanProgress(phase: .clustering, completed: 0, total: 1)
        )

        let seedSet = Set(seeds)
        let identical = try identicalScan.clusterIdenticalDuplicates(assetIDs: universe)
        let identicalWithSeeds = identical.filter { cluster in
            cluster.memberAssetIDs.contains(where: seedSet.contains)
        }
        var claimed = Set<UUID>()
        for cluster in identicalWithSeeds {
            claimed.formUnion(cluster.memberAssetIDs)
        }

        let unclaimedSeeds = seeds.filter { !claimed.contains($0) }
        var vectorCandidates = universe.filter { !claimed.contains($0) }
        if let sourceIndex, !unclaimedSeeds.isEmpty {
            let plan = try sourceIndex.candidateAssetIDs(
                seedAssetIDs: unclaimedSeeds,
                universeAssetIDs: universe
            )
            if case let .restricted(candidates) = plan {
                let restricted = Set(candidates).union(unclaimedSeeds).subtracting(claimed)
                vectorCandidates = universe.filter { restricted.contains($0) }
            }
        }
        let (featurePrints, embeddings, pending) = try loadVectors(
            assetIDs: vectorCandidates,
            onProgress: onProgress
        )

        let sceneModelIdentity = withPolicyVersion(
            embeddingLoader.embeddingModelIdentity() ?? .featurePrintOnly,
            policyVersion: thresholds.policyVersion
        )
        // Seed mode intentionally does not bucket — preserve cross-day recall.
        let sceneClusters = NearDuplicateSceneClusterService().clusterAroundSeeds(
            seedAssetIDs: unclaimedSeeds,
            featurePrints: featurePrints,
            embeddings: embeddings,
            modelIdentity: sceneModelIdentity,
            thresholds: thresholds
        )

        let identicalMapped = mapIdenticalClusters(identicalWithSeeds, policyVersion: thresholds.policyVersion)
        onProgress?(
            LibrarySlimmingScanProgress(phase: .clustering, completed: 1, total: 1)
        )

        let seedPending = seeds.filter { seed in
            pending.contains(seed) || (!claimed.contains(seed)
                && featurePrints[seed] == nil)
        }
        let clusters = (identicalMapped + sceneClusters).sorted(by: Self.clusterSort)
        return LibrarySlimmingScanResult(
            clusters: clusters,
            pendingAnalysisAssetIDs: Array(Set(seedPending)).sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            },
            analyzedAssetCount: universe.count,
            policyVersion: thresholds.policyVersion
        )
    }

    func scan(
        assetIDs: [UUID],
        onProgress: LibrarySlimmingScanProgressHandler? = nil
    ) throws -> LibrarySlimmingScanResult {
        let uniqueIDs = Array(Set(assetIDs)).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        let thresholds = thresholdReader.thresholds().clamped()
        (featureLoader as? SlimmingBudgetResetting)?
            .resetScanBudgets(forAssetCount: uniqueIDs.count)
        (embeddingLoader as? SlimmingBudgetResetting)?
            .resetScanBudgets(forAssetCount: uniqueIDs.count)

        guard !uniqueIDs.isEmpty else {
            return LibrarySlimmingScanResult(
                clusters: [],
                pendingAnalysisAssetIDs: [],
                analyzedAssetCount: 0,
                policyVersion: thresholds.policyVersion
            )
        }

        try prepareFingerprints(assetIDs: uniqueIDs, onProgress: onProgress)

        onProgress?(
            LibrarySlimmingScanProgress(phase: .clustering, completed: 0, total: 1)
        )
        let identical = try identicalScan.clusterIdenticalDuplicates(assetIDs: uniqueIDs)
        var claimed = Set<UUID>()
        for cluster in identical {
            claimed.formUnion(cluster.memberAssetIDs)
        }

        let vectorCandidates = uniqueIDs.filter { !claimed.contains($0) }
        let (featurePrints, embeddings, pending) = try loadVectors(
            assetIDs: vectorCandidates,
            onProgress: onProgress
        )

        let sceneModelIdentity = withPolicyVersion(
            embeddingLoader.embeddingModelIdentity() ?? .featurePrintOnly,
            policyVersion: thresholds.policyVersion
        )
        let sceneClusters = try clusterScenes(
            assetIDs: vectorCandidates,
            featurePrints: featurePrints,
            embeddings: embeddings,
            modelIdentity: sceneModelIdentity,
            thresholds: thresholds
        )

        let identicalMapped = mapIdenticalClusters(identical, policyVersion: thresholds.policyVersion)
        onProgress?(
            LibrarySlimmingScanProgress(phase: .clustering, completed: 1, total: 1)
        )

        let clusters = (identicalMapped + sceneClusters).sorted(by: Self.clusterSort)
        return LibrarySlimmingScanResult(
            clusters: clusters,
            pendingAnalysisAssetIDs: pending.sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            },
            analyzedAssetCount: uniqueIDs.count,
            policyVersion: thresholds.policyVersion
        )
    }

    private func clusterScenes(
        assetIDs: [UUID],
        featurePrints: [UUID: [Float]],
        embeddings: [UUID: [Float]],
        modelIdentity: SlimmingVectorModelIdentity,
        thresholds: NearDuplicateSceneThresholds
    ) throws -> [SlimmingCluster] {
        let service = NearDuplicateSceneClusterService()
        guard assetIDs.count >= thresholds.sceneBucketActivationAssetCount else {
            return service.cluster(
                featurePrints: featurePrints,
                embeddings: embeddings,
                modelIdentity: modelIdentity,
                thresholds: thresholds
            )
        }

        let createdAtByAsset = try loadMediaCreatedAtMs(assetIDs: assetIDs)
        var buckets: [String: [UUID]] = [:]
        for assetID in assetIDs {
            let key = SlimmingCaptureDayBucketing.bucketKey(
                mediaCreatedAtMs: createdAtByAsset[assetID],
                calendar: bucketCalendar
            )
            buckets[key, default: []].append(assetID)
        }

        var clusters: [SlimmingCluster] = []
        for key in buckets.keys.sorted() {
            guard let members = buckets[key], members.count >= 2 else { continue }
            let memberSet = Set(members)
            let bucketFeaturePrints = featurePrints.filter { memberSet.contains($0.key) }
            let bucketEmbeddings = embeddings.filter { memberSet.contains($0.key) }
            clusters.append(
                contentsOf: service.cluster(
                    featurePrints: bucketFeaturePrints,
                    embeddings: bucketEmbeddings,
                    modelIdentity: modelIdentity,
                    thresholds: thresholds
                )
            )
        }
        return clusters
    }

    private func loadMediaCreatedAtMs(assetIDs: [UUID]) throws -> [UUID: Int64] {
        guard !assetIDs.isEmpty else { return [:] }
        let idStrings = assetIDs.map { $0.uuidString.lowercased() }
        let placeholders = Array(repeating: "?", count: idStrings.count).joined(separator: ", ")
        return try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, media_created_at_ms
                FROM asset
                WHERE id IN (\(placeholders))
                """,
                arguments: StatementArguments(idStrings)
            )
            var result: [UUID: Int64] = [:]
            for row in rows {
                guard let id = UUID(uuidString: row["id"]) else { continue }
                let ms: Int64? = row["media_created_at_ms"]
                if let ms {
                    result[id] = ms
                }
            }
            return result
        }
    }

    private func withPolicyVersion(
        _ identity: SlimmingVectorModelIdentity,
        policyVersion: String
    ) -> SlimmingVectorModelIdentity {
        SlimmingVectorModelIdentity(
            featurePrintProvider: identity.featurePrintProvider,
            featurePrintRequestRevision: identity.featurePrintRequestRevision,
            featurePrintPreprocessingRevision: identity.featurePrintPreprocessingRevision,
            embeddingProvider: identity.embeddingProvider,
            embeddingModelID: identity.embeddingModelID,
            embeddingModelRevision: identity.embeddingModelRevision,
            embeddingPreprocessingRevision: identity.embeddingPreprocessingRevision,
            perceptualAlgoVersion: identity.perceptualAlgoVersion,
            policyVersion: policyVersion
        )
    }

    private func prepareFingerprints(
        assetIDs: [UUID],
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws {
        guard let fingerprintCompletion else { return }
        let total = assetIDs.count
        for (index, assetID) in assetIDs.enumerated() {
            onProgress?(
                LibrarySlimmingScanProgress(
                    phase: .preparingFingerprints,
                    completed: index,
                    total: total
                )
            )
            do {
                _ = try fingerprintCompletion.completeAsset(assetID: assetID)
            } catch FingerprintCompletionError.ineligible,
                    FingerprintCompletionError.notFound,
                    FingerprintCompletionError.sourceUnavailable,
                    FingerprintCompletionError.authorizationRequired,
                    FingerprintCompletionError.decodeFailed,
                    FingerprintCompletionError.sourceChanged,
                    FingerprintCompletionError.persistenceFailed
            {
                continue
            } catch {
                continue
            }
        }
        onProgress?(
            LibrarySlimmingScanProgress(
                phase: .preparingFingerprints,
                completed: total,
                total: total
            )
        )
    }

    private func loadVectors(
        assetIDs: [UUID],
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws -> (featurePrints: [UUID: [Float]], embeddings: [UUID: [Float]], pending: [UUID]) {
        var pending: [UUID] = []
        var featurePrints: [UUID: [Float]] = [:]
        var embeddings: [UUID: [Float]] = [:]

        let vectorTotal = assetIDs.count
        for (index, assetID) in assetIDs.enumerated() {
            onProgress?(
                LibrarySlimmingScanProgress(
                    phase: .loadingFeaturePrints,
                    completed: index,
                    total: vectorTotal
                )
            )
            guard let feature = try featureLoader.featureVector(assetID: assetID) else {
                pending.append(assetID)
                continue
            }
            featurePrints[assetID] = feature
        }
        onProgress?(
            LibrarySlimmingScanProgress(
                phase: .loadingFeaturePrints,
                completed: vectorTotal,
                total: vectorTotal
            )
        )

        let embeddingCandidates = assetIDs.filter { !pending.contains($0) }
        let embeddingTotal = embeddingCandidates.count
        for (index, assetID) in embeddingCandidates.enumerated() {
            onProgress?(
                LibrarySlimmingScanProgress(
                    phase: .loadingEmbeddings,
                    completed: index,
                    total: embeddingTotal
                )
            )
            guard let embedding = try embeddingLoader.embedding(assetID: assetID) else {
                pending.append(assetID)
                continue
            }
            embeddings[assetID] = embedding
        }
        onProgress?(
            LibrarySlimmingScanProgress(
                phase: .loadingEmbeddings,
                completed: embeddingTotal,
                total: embeddingTotal
            )
        )
        return (featurePrints, embeddings, pending)
    }

    private func mapIdenticalClusters(
        _ identical: [IdenticalDuplicateCluster],
        policyVersion: String
    ) -> [SlimmingCluster] {
        let identicalModelIdentity = SlimmingVectorModelIdentity(
            featurePrintProvider: nil,
            featurePrintRequestRevision: nil,
            featurePrintPreprocessingRevision: nil,
            embeddingProvider: nil,
            embeddingModelID: nil,
            embeddingModelRevision: nil,
            embeddingPreprocessingRevision: nil,
            perceptualAlgoVersion: IdenticalDuplicatePolicy.perceptualAlgoVersion,
            policyVersion: policyVersion
        )
        return identical.map { cluster -> SlimmingCluster in
            let kind: SlimmingClusterKind = switch cluster.kind {
            case .byteIdentical: .byteIdentical
            case .perceptualDuplicate: .perceptualDuplicate
            }
            let score: Double = switch cluster.kind {
            case .byteIdentical:
                1.0
            case .perceptualDuplicate:
                max(0, 1.0 - Double(cluster.score) / 64.0)
            }
            return SlimmingCluster(
                id: NearDuplicateSceneClusterService.stableClusterID(
                    kind: kind,
                    members: cluster.memberAssetIDs
                ),
                kind: kind,
                memberAssetIDs: cluster.memberAssetIDs,
                representativeAssetID: cluster.representativeAssetID,
                score: score,
                modelIdentity: identicalModelIdentity
            )
        }
    }

    private static func clusterSort(_ lhs: SlimmingCluster, _ rhs: SlimmingCluster) -> Bool {
        let leftRank = kindRank(lhs.kind)
        let rightRank = kindRank(rhs.kind)
        if leftRank != rightRank { return leftRank < rightRank }
        if lhs.memberAssetIDs.count != rhs.memberAssetIDs.count {
            return lhs.memberAssetIDs.count > rhs.memberAssetIDs.count
        }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.representativeAssetID.uuidString.lowercased()
            < rhs.representativeAssetID.uuidString.lowercased()
    }

    private static func kindRank(_ kind: SlimmingClusterKind) -> Int {
        switch kind {
        case .byteIdentical: 0
        case .perceptualDuplicate: 1
        case .nearDuplicateScene: 2
        }
    }
}

final class BudgetedFeaturePrintSlimmingLoader: SlimmingFeatureVectorLoading, SlimmingBudgetResetting,
    @unchecked Sendable
{
    private let service: any SyncFeatureVectorLoading
    private let lock = NSLock()
    private var generationBudget = 0
    private var generationsUsed = 0

    init(service: any SyncFeatureVectorLoading) {
        self.service = service
    }

    func resetScanBudgets(forAssetCount assetCount: Int) {
        let budgets = SlimmingScanBudgetPolicy.budgets(forAssetCount: assetCount)
        lock.lock()
        generationBudget = budgets.featurePrintGenerations
        generationsUsed = 0
        lock.unlock()
    }

    func featureVector(assetID: UUID) throws -> [Float]? {
        if let cached = try service.loadCachedSync(assetID: assetID) {
            return try PersonalizedSuggestionScoringCore.decode(cached)
        }

        lock.lock()
        let allowed = generationsUsed < generationBudget
        if allowed { generationsUsed += 1 }
        lock.unlock()
        guard allowed else { return nil }

        do {
            let payload = try service.loadOrGenerateSync(assetID: assetID)
            return try PersonalizedSuggestionScoringCore.decode(payload)
        } catch {
            return nil
        }
    }
}

/// Returns embeddings only when the optional loader can supply them; otherwise nil → pending.
struct OptionalSlimmingEmbeddingLoader: SlimmingEmbeddingLoading, SlimmingBudgetResetting {
    let base: (any SlimmingEmbeddingLoading)?

    func resetScanBudgets(forAssetCount assetCount: Int) {
        (base as? SlimmingBudgetResetting)?.resetScanBudgets(forAssetCount: assetCount)
    }

    func embeddingModelIdentity() -> SlimmingVectorModelIdentity? {
        base?.embeddingModelIdentity()
    }

    func embedding(assetID: UUID) throws -> [Float]? {
        guard let base else { return nil }
        return try base.embedding(assetID: assetID)
    }
}

struct DictionarySlimmingFeatureLoader: SlimmingFeatureVectorLoading {
    let vectors: [UUID: [Float]]

    func featureVector(assetID: UUID) throws -> [Float]? {
        vectors[assetID]
    }
}

struct DictionarySlimmingEmbeddingLoader: SlimmingEmbeddingLoading {
    let vectors: [UUID: [Float]]
    let modelIdentity: SlimmingVectorModelIdentity?

    init(
        vectors: [UUID: [Float]],
        modelIdentity: SlimmingVectorModelIdentity? = nil
    ) {
        self.vectors = vectors
        self.modelIdentity = modelIdentity
    }

    func embeddingModelIdentity() -> SlimmingVectorModelIdentity? {
        modelIdentity
    }

    func embedding(assetID: UUID) throws -> [Float]? {
        vectors[assetID]
    }
}

struct LibrarySlimmingAnalysisJobSnapshot: Sendable, Equatable {
    let jobID: UUID
    let state: JobState
    let controlRequest: JobControlRequest
    let progress: JobProgress
    let result: LibrarySlimmingScanResult?
}

struct LibrarySlimmingAnalysisJobSummary: Sendable, Equatable, Identifiable {
    var id: UUID { jobID }
    let jobID: UUID
    let mode: LibrarySlimmingAnalyzeMode
    let state: JobState
    let controlRequest: JobControlRequest
    let progress: JobProgress
    let memberCount: Int
    let seedCount: Int
    let clusterCount: Int
    let hasResult: Bool
    let createdAtMs: Int64
    let updatedAtMs: Int64
}

protocol LibrarySlimmingAnalysisJobPort: Sendable {
    func enqueue(
        mode: LibrarySlimmingAnalyzeMode,
        assetIDs: [UUID],
        seedAssetIDs: [UUID]
    ) throws -> LibrarySlimmingAnalysisJobSnapshot
    func runPending() throws
    func pause(jobID: UUID) throws -> LibrarySlimmingAnalysisJobSnapshot
    func resume(jobID: UUID) throws -> LibrarySlimmingAnalysisJobSnapshot
    func snapshot(jobID: UUID) throws -> LibrarySlimmingAnalysisJobSnapshot
    func latestActiveOrCompleted() throws -> LibrarySlimmingAnalysisJobSnapshot?
    func listJobs() throws -> [LibrarySlimmingAnalysisJobSummary]
    func delete(jobID: UUID) throws
}

enum LibrarySlimmingAnalysisJobFactory {
    static let kind = "librarySlimming.analysis.v1"
    static let payloadVersion = 1
    static let checkpointVersion = 1
    static let priority = 10
    static let maxAttempts = 5
    static let fingerprintBatchSize = 16
    static let vectorBatchSize = 16
    static let automaticCompletionPasses = 3
    static let leaseDurationMs: Int64 = 10 * 60 * 1_000

    struct Payload: Codable, Sendable, Equatable {
        let mode: LibrarySlimmingAnalyzeMode
    }

    enum Phase: String, Codable, Sendable {
        case fingerprints
        case vectors
        case clustering
    }

    struct Checkpoint: Codable, Sendable, Equatable {
        var phase: Phase
        var nextOrdinal: Int
        var completionPass: Int
        var completedFloor: Int
    }

    static func makeCommand(
        jobID: UUID,
        mode: LibrarySlimmingAnalyzeMode,
        notBeforeMs: Int64
    ) throws -> EnqueueJobCommand {
        // Each analysis is an independent durable record. No coalescing key
        // so multiple history / in-flight jobs can coexist without cancelling
        // each other; claim/execute still serializes work via the job queue.
        EnqueueJobCommand(
            id: jobID,
            kind: kind,
            payloadVersion: payloadVersion,
            payload: try JSONEncoder().encode(Payload(mode: mode)),
            sourceID: nil,
            coalescingKey: nil,
            priority: priority,
            maxAttempts: maxAttempts,
            notBeforeMs: notBeforeMs
        )
    }

    static func decodePayload(_ data: Data) throws -> Payload {
        try JSONDecoder().decode(Payload.self, from: data)
    }

    static func decodeCheckpoint(_ checkpoint: JobCheckpoint?) throws -> Checkpoint {
        guard let checkpoint else {
            return Checkpoint(
                phase: .fingerprints,
                nextOrdinal: 0,
                completionPass: 1,
                completedFloor: 0
            )
        }
        guard checkpoint.version == checkpointVersion else {
            throw JobQueueError.unsupportedCheckpointVersion(
                kind: kind,
                version: checkpoint.version
            )
        }
        return try JSONDecoder().decode(Checkpoint.self, from: checkpoint.data)
    }

    static func encodeCheckpoint(_ value: Checkpoint) throws -> JobCheckpoint {
        JobCheckpoint(version: checkpointVersion, data: try JSONEncoder().encode(value))
    }
}

struct LibrarySlimmingAnalysisService: LibrarySlimmingAnalysisJobPort {
    let database: CatalogDatabase
    let queue: GRDBJobQueue
    let clock: any JobClock
    private let coordinator: JobExecutionCoordinator

    init(
        database: CatalogDatabase,
        queue: GRDBJobQueue,
        fingerprintCompletion: any FingerprintCompletionPort,
        featureLoader: any SlimmingFeatureVectorLoading,
        embeddingLoader: any SlimmingEmbeddingLoading,
        scanner: any LibrarySlimmingScanPort,
        clock: any JobClock
    ) {
        self.database = database
        self.queue = queue
        self.clock = clock
        let handler = LibrarySlimmingAnalysisHandler(
            database: database,
            queue: queue,
            fingerprintCompletion: fingerprintCompletion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            scanner: scanner,
            clock: clock
        )
        coordinator = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [handler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )
    }

    func enqueue(
        mode: LibrarySlimmingAnalyzeMode,
        assetIDs: [UUID],
        seedAssetIDs: [UUID]
    ) throws -> LibrarySlimmingAnalysisJobSnapshot {
        let seeds = Set(seedAssetIDs)
        let members = Array(Set(assetIDs).union(seeds)).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        guard !members.isEmpty else {
            throw FingerprintCompletionError.notFound
        }
        let jobID = UUID()
        let nowMs = clock.nowMs
        let command = try LibrarySlimmingAnalysisJobFactory.makeCommand(
            jobID: jobID,
            mode: mode,
            notBeforeMs: nowMs
        )
        try database.pool.write { db in
            // The resumable job and its frozen analysis universe are one
            // durable unit. A crash must never expose a claimable empty job.
            try JobInsertInTransaction.insertPendingJob(db, command: command, nowMs: nowMs)
            for (ordinal, assetID) in members.enumerated() {
                try db.execute(
                    sql: """
                    INSERT INTO library_slimming_scan_member (
                        job_id, asset_id, ordinal, is_seed
                    ) VALUES (?, ?, ?, ?)
                    """,
                    arguments: [
                        jobID.uuidString.lowercased(),
                        assetID.uuidString.lowercased(),
                        ordinal,
                        seeds.contains(assetID) ? 1 : 0,
                    ]
                )
            }
        }
        return try snapshot(jobID: jobID)
    }

    func runPending() throws {
        try queue.settleRetryableJobs()
        let claim = ClaimNextInput(
            owner: "imageall-library-slimming-analysis-\(UUID().uuidString.lowercased())",
            leaseDurationMs: LibrarySlimmingAnalysisJobFactory.leaseDurationMs,
            allowedKinds: [LibrarySlimmingAnalysisJobFactory.kind]
        )
        while let execution = try coordinator.claimAndExecuteOnce(claim) {
            if execution.snapshot.state == .paused
                || execution.snapshot.state == .terminalFailed
                || execution.snapshot.state == .cancelled
            {
                break
            }
        }
    }

    func pause(jobID: UUID) throws -> LibrarySlimmingAnalysisJobSnapshot {
        _ = try queue.applyStateCommand(
            JobStateCommand(jobID: jobID, operation: .pause)
        )
        return try snapshot(jobID: jobID)
    }

    func resume(jobID: UUID) throws -> LibrarySlimmingAnalysisJobSnapshot {
        _ = try queue.applyStateCommand(
            JobStateCommand(
                jobID: jobID,
                operation: .resume(notBeforeMs: clock.nowMs)
            )
        )
        return try snapshot(jobID: jobID)
    }

    func snapshot(jobID: UUID) throws -> LibrarySlimmingAnalysisJobSnapshot {
        let job = try queue.fetchJob(id: jobID)
        let result = try database.pool.read { db -> LibrarySlimmingScanResult? in
            guard let data: Data = try Data.fetchOne(
                db,
                sql: "SELECT result_json FROM library_slimming_scan_result WHERE job_id = ?",
                arguments: [jobID.uuidString.lowercased()]
            ) else {
                return nil
            }
            return try JSONDecoder().decode(LibrarySlimmingScanResult.self, from: data)
        }
        return LibrarySlimmingAnalysisJobSnapshot(
            jobID: job.id,
            state: job.state,
            controlRequest: job.controlRequest,
            progress: job.progress,
            result: result
        )
    }

    func latestActiveOrCompleted() throws -> LibrarySlimmingAnalysisJobSnapshot? {
        let jobID = try database.pool.read { db -> UUID? in
            guard let raw: String = try String.fetchOne(
                db,
                sql: """
                SELECT id
                FROM job
                WHERE kind = ?
                ORDER BY
                    CASE WHEN state IN ('pending', 'running', 'paused', 'retryableFailed')
                        THEN 0 ELSE 1 END,
                    updated_at_ms DESC,
                    id DESC
                LIMIT 1
                """,
                arguments: [LibrarySlimmingAnalysisJobFactory.kind]
            ) else {
                return nil
            }
            return UUID(uuidString: raw)
        }
        guard let jobID else { return nil }
        return try snapshot(jobID: jobID)
    }

    func listJobs() throws -> [LibrarySlimmingAnalysisJobSummary] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    job.id AS id,
                    job.payload AS payload,
                    job.state AS state,
                    job.control_request AS control_request,
                    job.progress_completed AS progress_completed,
                    job.progress_total AS progress_total,
                    job.created_at_ms AS created_at_ms,
                    job.updated_at_ms AS updated_at_ms,
                    (
                        SELECT COUNT(*)
                        FROM library_slimming_scan_member m
                        WHERE m.job_id = job.id
                    ) AS member_count,
                    (
                        SELECT COUNT(*)
                        FROM library_slimming_scan_member m
                        WHERE m.job_id = job.id AND m.is_seed = 1
                    ) AS seed_count,
                    (
                        SELECT result_json
                        FROM library_slimming_scan_result r
                        WHERE r.job_id = job.id
                    ) AS result_json
                FROM job
                WHERE job.kind = ?
                ORDER BY job.created_at_ms DESC, job.id DESC
                """,
                arguments: [LibrarySlimmingAnalysisJobFactory.kind]
            )
            return try rows.map { row in
                let rawID: String = row["id"]
                guard let jobID = UUID(uuidString: rawID) else {
                    throw JobQueueError.unknownPersistedRawValue(field: "id", value: rawID)
                }
                let payloadData: Data = row["payload"]
                let payload = try LibrarySlimmingAnalysisJobFactory.decodePayload(payloadData)
                let resultData: Data? = row["result_json"]
                let clusterCount: Int
                if let resultData,
                   let result = try? JSONDecoder().decode(
                       LibrarySlimmingScanResult.self,
                       from: resultData
                   )
                {
                    clusterCount = result.clusters.count
                } else {
                    clusterCount = 0
                }
                return LibrarySlimmingAnalysisJobSummary(
                    jobID: jobID,
                    mode: payload.mode,
                    state: try JobPersistenceMapping.jobState(from: row["state"]),
                    controlRequest: try JobPersistenceMapping.controlRequest(
                        from: row["control_request"]
                    ),
                    progress: JobProgress(
                        completed: row["progress_completed"],
                        total: row["progress_total"]
                    ),
                    memberCount: row["member_count"],
                    seedCount: row["seed_count"],
                    clusterCount: clusterCount,
                    hasResult: resultData != nil,
                    createdAtMs: row["created_at_ms"],
                    updatedAtMs: row["updated_at_ms"]
                )
            }
        }
    }

    func delete(jobID: UUID) throws {
        let deleted = try database.pool.write { db -> Int in
            let state: String? = try String.fetchOne(
                db,
                sql: "SELECT state FROM job WHERE id = ? AND kind = ?",
                arguments: [
                    jobID.uuidString.lowercased(),
                    LibrarySlimmingAnalysisJobFactory.kind,
                ]
            )
            guard let state else {
                throw JobQueueError.jobNotFound(jobID)
            }
            guard state != JobState.running.rawValue else {
                throw JobQueueError.invalidTransition(
                    currentState: .running,
                    operation: "delete"
                )
            }
            try db.execute(
                sql: "DELETE FROM job WHERE id = ? AND kind = ? AND state != ?",
                arguments: [
                    jobID.uuidString.lowercased(),
                    LibrarySlimmingAnalysisJobFactory.kind,
                    JobState.running.rawValue,
                ]
            )
            return db.changesCount
        }
        guard deleted > 0 else {
            throw JobQueueError.jobNotFound(jobID)
        }
    }
}

private struct LibrarySlimmingAnalysisHandler: LeaseBoundJobHandler {
    let database: CatalogDatabase
    let queue: GRDBJobQueue
    let fingerprintCompletion: any FingerprintCompletionPort
    let featureLoader: any SlimmingFeatureVectorLoading
    let embeddingLoader: any SlimmingEmbeddingLoading
    let scanner: any LibrarySlimmingScanPort
    let clock: any JobClock

    var kind: String { LibrarySlimmingAnalysisJobFactory.kind }
    var supportedPayloadVersions: Set<Int> { [LibrarySlimmingAnalysisJobFactory.payloadVersion] }
    var supportedCheckpointVersions: Set<Int> {
        [LibrarySlimmingAnalysisJobFactory.checkpointVersion]
    }

    func execute(
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?
    ) -> JobHandlerExecutionResult {
        failure(checkpoint: checkpoint)
    }

    func execute(
        lease: JobLeaseToken,
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?,
        context: JobLeaseExecutionContext
    ) throws -> JobHandlerExecutionResult {
        _ = context
        guard payloadVersion == LibrarySlimmingAnalysisJobFactory.payloadVersion else {
            return failure(checkpoint: checkpoint)
        }
        do {
            let payload = try LibrarySlimmingAnalysisJobFactory.decodePayload(payload)
            var state = try LibrarySlimmingAnalysisJobFactory.decodeCheckpoint(checkpoint)
            let total = try memberCount(jobID: lease.jobID)
            let progressTotal = total * 2 + 1

            while true {
                if try hasControlRequest(jobID: lease.jobID) {
                    return JobHandlerExecutionResult(
                        outcome: .continue,
                        checkpoint: try LibrarySlimmingAnalysisJobFactory.encodeCheckpoint(state),
                        progress: progress(state: state, total: total, progressTotal: progressTotal)
                    )
                }
                switch state.phase {
                case .fingerprints:
                    let batch = try memberBatch(
                        jobID: lease.jobID,
                        fromOrdinal: state.nextOrdinal,
                        limit: LibrarySlimmingAnalysisJobFactory.fingerprintBatchSize
                    )
                    if batch.isEmpty {
                        state.phase = .vectors
                        state.nextOrdinal = 0
                        (featureLoader as? SlimmingBudgetResetting)?
                            .resetScanBudgets(forAssetCount: total)
                        (embeddingLoader as? SlimmingBudgetResetting)?
                            .resetScanBudgets(forAssetCount: total)
                        continue
                    }
                    for member in batch {
                        _ = try? fingerprintCompletion.completeAsset(assetID: member.assetID)
                    }
                    state.nextOrdinal = (batch.last?.ordinal ?? state.nextOrdinal) + 1
                    if let settled = try commitProgress(
                        lease: lease,
                        state: state,
                        total: total,
                        progressTotal: progressTotal
                    ) {
                        return settled
                    }
                case .vectors:
                    let batch = try memberBatch(
                        jobID: lease.jobID,
                        fromOrdinal: state.nextOrdinal,
                        limit: LibrarySlimmingAnalysisJobFactory.vectorBatchSize
                    )
                    if batch.isEmpty {
                        state.phase = .clustering
                        state.nextOrdinal = 0
                        continue
                    }
                    for member in batch {
                        guard (try? featureLoader.featureVector(assetID: member.assetID)) != nil else {
                            continue
                        }
                        _ = try? embeddingLoader.embedding(assetID: member.assetID)
                    }
                    state.nextOrdinal = (batch.last?.ordinal ?? state.nextOrdinal) + 1
                    if let settled = try commitProgress(
                        lease: lease,
                        state: state,
                        total: total,
                        progressTotal: progressTotal
                    ) {
                        return settled
                    }
                case .clustering:
                    let members = try allMembers(jobID: lease.jobID)
                    let assetIDs = members.map(\.assetID)
                    let seeds = members.filter(\.isSeed).map(\.assetID)
                    let result: LibrarySlimmingScanResult
                    if payload.mode == .seeds {
                        result = try scanner.scanSeeds(
                            seedAssetIDs: seeds,
                            universeAssetIDs: assetIDs,
                            onProgress: nil
                        )
                    } else {
                        result = try scanner.scan(assetIDs: assetIDs, onProgress: nil)
                    }
                    if !result.pendingAnalysisAssetIDs.isEmpty,
                       state.completionPass
                        < LibrarySlimmingAnalysisJobFactory.automaticCompletionPasses
                    {
                        state = .init(
                            phase: .fingerprints,
                            nextOrdinal: 0,
                            completionPass: state.completionPass + 1,
                            completedFloor: total * 2
                        )
                        if let settled = try commitProgress(
                            lease: lease,
                            state: state,
                            total: total,
                            progressTotal: progressTotal
                        ) {
                            return settled
                        }
                        continue
                    }
                    let encodedResult = try JSONEncoder().encode(result)
                    let finalCheckpoint = try LibrarySlimmingAnalysisJobFactory.encodeCheckpoint(state)
                    let finalProgress = JobProgress(
                        completed: progressTotal,
                        total: progressTotal
                    )
                    _ = try queue.commitLeaseProtectedBatch(
                        input: SafeBatchCommitInput(
                            lease: lease,
                            outcome: .completed,
                            checkpoint: finalCheckpoint,
                            progress: finalProgress,
                            leaseDurationMs: LibrarySlimmingAnalysisJobFactory.leaseDurationMs
                        )
                    ) { db in
                        try db.execute(
                            sql: """
                            INSERT INTO library_slimming_scan_result (
                                job_id, result_json, updated_at_ms
                            ) VALUES (?, ?, ?)
                            ON CONFLICT(job_id) DO UPDATE SET
                                result_json = excluded.result_json,
                                updated_at_ms = excluded.updated_at_ms
                            """,
                            arguments: [
                                lease.jobID.uuidString.lowercased(),
                                encodedResult,
                                clock.nowMs,
                            ]
                        )
                    }
                    return JobHandlerExecutionResult(
                        outcome: .completed,
                        checkpoint: finalCheckpoint,
                        progress: finalProgress,
                        settledByHandler: true
                    )
                }
            }
        } catch {
            let persisted = try? queue.fetchJob(id: lease.jobID)
            return JobHandlerExecutionResult(
                outcome: .retryableFailure(code: .librarySlimmingAnalysisFailed),
                checkpoint: persisted?.checkpoint ?? checkpoint,
                progress: persisted?.progress ?? JobProgress(completed: 0, total: nil)
            )
        }
    }

    private struct Member {
        let ordinal: Int
        let assetID: UUID
        let isSeed: Bool
    }

    private func memberCount(jobID: UUID) throws -> Int {
        try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM library_slimming_scan_member WHERE job_id = ?",
                arguments: [jobID.uuidString.lowercased()]
            ) ?? 0
        }
    }

    private func memberBatch(jobID: UUID, fromOrdinal: Int, limit: Int) throws -> [Member] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT ordinal, asset_id, is_seed
                FROM library_slimming_scan_member
                WHERE job_id = ? AND ordinal >= ?
                ORDER BY ordinal
                LIMIT ?
                """,
                arguments: [jobID.uuidString.lowercased(), fromOrdinal, limit]
            )
            return rows.compactMap(Self.member)
        }
    }

    private func allMembers(jobID: UUID) throws -> [Member] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT ordinal, asset_id, is_seed
                FROM library_slimming_scan_member
                WHERE job_id = ?
                ORDER BY ordinal
                """,
                arguments: [jobID.uuidString.lowercased()]
            ).compactMap(Self.member)
        }
    }

    private static func member(_ row: Row) -> Member? {
        guard let assetID = UUID(uuidString: row["asset_id"]) else { return nil }
        return Member(
            ordinal: row["ordinal"],
            assetID: assetID,
            isSeed: (row["is_seed"] as Int) == 1
        )
    }

    private func hasControlRequest(jobID: UUID) throws -> Bool {
        try queue.fetchJob(id: jobID).controlRequest != .none
    }

    private func progress(
        state: LibrarySlimmingAnalysisJobFactory.Checkpoint,
        total: Int,
        progressTotal: Int
    ) -> JobProgress {
        let completed: Int = switch state.phase {
        case .fingerprints:
            min(state.nextOrdinal, total)
        case .vectors:
            total + min(state.nextOrdinal, total)
        case .clustering:
            total * 2
        }
        return JobProgress(
            completed: max(state.completedFloor, completed),
            total: progressTotal
        )
    }

    private func commitProgress(
        lease: JobLeaseToken,
        state: LibrarySlimmingAnalysisJobFactory.Checkpoint,
        total: Int,
        progressTotal: Int
    ) throws -> JobHandlerExecutionResult? {
        let checkpoint = try LibrarySlimmingAnalysisJobFactory.encodeCheckpoint(state)
        let progress = progress(state: state, total: total, progressTotal: progressTotal)
        let snapshot = try queue.submitSafeBatch(
            SafeBatchCommitInput(
                lease: lease,
                outcome: .continue,
                checkpoint: checkpoint,
                progress: progress,
                leaseDurationMs: LibrarySlimmingAnalysisJobFactory.leaseDurationMs
            )
        )
        guard snapshot.state != .running else { return nil }
        return JobHandlerExecutionResult(
            outcome: .continue,
            checkpoint: checkpoint,
            progress: progress,
            settledByHandler: true
        )
    }

    private func failure(checkpoint: JobCheckpoint?) -> JobHandlerExecutionResult {
        JobHandlerExecutionResult(
            outcome: .nonRetryableFailure(code: .librarySlimmingAnalysisFailed),
            checkpoint: checkpoint,
            progress: JobProgress(completed: 0, total: nil)
        )
    }
}
