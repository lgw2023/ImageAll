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

    func scanCatalog(
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws -> LibrarySlimmingScanResult {
        try scanCatalog(mediaKind: .image, onProgress: onProgress)
    }

    func scan(
        assetIDs: [UUID],
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws -> LibrarySlimmingScanResult {
        try scan(assetIDs: assetIDs, mediaKind: .image, onProgress: onProgress)
    }

    func scanSeeds(
        seedAssetIDs: [UUID],
        universeAssetIDs: [UUID],
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws -> LibrarySlimmingScanResult {
        try scanSeeds(
            seedAssetIDs: seedAssetIDs,
            universeAssetIDs: universeAssetIDs,
            mediaKind: .image,
            onProgress: onProgress
        )
    }

    func scanCatalog(
        mediaKind: MediaKind,
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws -> LibrarySlimmingScanResult {
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
                  AND a.media_kind = ?
                ORDER BY a.id ASC
                """,
                arguments: [
                    AssetLocatorState.current.rawValue,
                    AssetAvailability.available.rawValue,
                    SourceState.active.rawValue,
                    mediaKind.rawValue,
                ]
            )
            return rows.compactMap { row in
                UUID(uuidString: row["id"])
            }
        }
        return try scan(assetIDs: assetIDs, mediaKind: mediaKind, onProgress: onProgress)
    }

    func scanSeeds(
        seedAssetIDs: [UUID],
        universeAssetIDs: [UUID],
        mediaKind: MediaKind,
        onProgress: LibrarySlimmingScanProgressHandler? = nil
    ) throws -> LibrarySlimmingScanResult {
        let requestedSeeds = Array(Set(seedAssetIDs)).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        let requestedUniverse = Array(Set(universeAssetIDs).union(requestedSeeds)).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        let universe = try retainingRequestedMedia(
            assetIDs: requestedUniverse,
            mediaKind: mediaKind
        )
        let universeSet = Set(universe)
        let seeds = requestedSeeds.filter(universeSet.contains)
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
        let identical = try identicalScan.clusterIdenticalDuplicates(
            assetIDs: universe,
            mediaKind: mediaKind
        )
        let identicalWithSeeds = identical.filter { cluster in
            cluster.memberAssetIDs.contains(where: seedSet.contains)
        }
        var claimed = Set<UUID>()
        for cluster in identicalWithSeeds {
            claimed.formUnion(cluster.memberAssetIDs)
        }

        let unclaimedSeeds = seeds.filter { !claimed.contains($0) }
        var vectorCandidates = universe.filter { !claimed.contains($0) }
        if let sourceIndex,
           !unclaimedSeeds.isEmpty,
           !thresholds.usesExhaustiveFeaturePrintRecall
        {
            let plan = try sourceIndex.candidateAssetIDs(
                seedAssetIDs: unclaimedSeeds,
                universeAssetIDs: universe,
                mediaKind: mediaKind
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

        let identicalMapped = mapIdenticalClusters(
            identicalWithSeeds,
            mediaKind: mediaKind,
            policyVersion: thresholds.policyVersion
        )
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
        mediaKind: MediaKind,
        onProgress: LibrarySlimmingScanProgressHandler? = nil
    ) throws -> LibrarySlimmingScanResult {
        let requestedIDs = Array(Set(assetIDs)).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        let uniqueIDs = try retainingRequestedMedia(
            assetIDs: requestedIDs,
            mediaKind: mediaKind
        )
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
        let identical = try identicalScan.clusterIdenticalDuplicates(
            assetIDs: uniqueIDs,
            mediaKind: mediaKind
        )
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
            thresholds: thresholds,
            onProgress: onProgress
        )

        let identicalMapped = mapIdenticalClusters(
            identical,
            mediaKind: mediaKind,
            policyVersion: thresholds.policyVersion
        )
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
        thresholds: NearDuplicateSceneThresholds,
        onProgress: LibrarySlimmingScanProgressHandler?
    ) throws -> [SlimmingCluster] {
        let service = NearDuplicateSceneClusterService()
        guard thresholds.usesCaptureDayBuckets(assetCount: assetIDs.count) else {
            return service.cluster(
                featurePrints: featurePrints,
                embeddings: embeddings,
                modelIdentity: modelIdentity,
                thresholds: thresholds,
                onProgress: { completed, total in
                    onProgress?(
                        LibrarySlimmingScanProgress(
                            phase: .clustering,
                            completed: completed,
                            total: total
                        )
                    )
                }
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

        let clusteringTotal = buckets.values.reduce(into: 0) { total, members in
            if members.count >= 2 {
                total += members.count
            }
        }
        var clusteringCompleted = 0
        onProgress?(
            LibrarySlimmingScanProgress(
                phase: .clustering,
                completed: 0,
                total: max(clusteringTotal, 1)
            )
        )
        var clusters: [SlimmingCluster] = []
        for key in buckets.keys.sorted() {
            guard let members = buckets[key], members.count >= 2 else { continue }
            let memberSet = Set(members)
            let bucketFeaturePrints = featurePrints.filter { memberSet.contains($0.key) }
            let bucketEmbeddings = embeddings.filter { memberSet.contains($0.key) }
            let completedBeforeBucket = clusteringCompleted
            clusters.append(
                contentsOf: service.cluster(
                    featurePrints: bucketFeaturePrints,
                    embeddings: bucketEmbeddings,
                    modelIdentity: modelIdentity,
                    thresholds: thresholds,
                    onProgress: { completed, _ in
                        onProgress?(
                            LibrarySlimmingScanProgress(
                                phase: .clustering,
                                completed: completedBeforeBucket + completed,
                                total: max(clusteringTotal, 1)
                            )
                        )
                    }
                )
            )
            clusteringCompleted += members.count
        }
        onProgress?(
            LibrarySlimmingScanProgress(
                phase: .clustering,
                completed: max(clusteringTotal, 1),
                total: max(clusteringTotal, 1)
            )
        )
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

    /// Production scans only compare the requested media domain. Unknown IDs are
    /// retained for dictionary-backed unit scanners, while catalog-backed assets
    /// from the opposite domain are rejected.
    private func retainingRequestedMedia(
        assetIDs: [UUID],
        mediaKind: MediaKind
    ) throws -> [UUID] {
        guard !assetIDs.isEmpty else { return [] }
        let idStrings = assetIDs.map { $0.uuidString.lowercased() }
        let placeholders = Array(repeating: "?", count: idStrings.count).joined(separator: ", ")
        let knownKinds = try database.pool.read { db -> [UUID: MediaKind] in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, media_kind FROM asset WHERE id IN (\(placeholders))",
                arguments: StatementArguments(idStrings)
            )
            var result: [UUID: MediaKind] = [:]
            for row in rows {
                guard let id = UUID(uuidString: row["id"]),
                      let kind = MediaKind(rawValue: row["media_kind"])
                else { continue }
                result[id] = kind
            }
            return result
        }
        return assetIDs.filter { knownKinds[$0] == nil || knownKinds[$0] == mediaKind }
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
        mediaKind: MediaKind = .image,
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
            perceptualAlgoVersion: IdenticalDuplicatePolicy.perceptualAlgoVersion(for: mediaKind),
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
    let seedAssetIDs: [UUID]

    init(
        jobID: UUID,
        state: JobState,
        controlRequest: JobControlRequest,
        progress: JobProgress,
        result: LibrarySlimmingScanResult?,
        seedAssetIDs: [UUID] = []
    ) {
        self.jobID = jobID
        self.state = state
        self.controlRequest = controlRequest
        self.progress = progress
        self.result = result
        self.seedAssetIDs = seedAssetIDs
    }
}

struct LibrarySlimmingAnalysisJobSummary: Sendable, Equatable, Identifiable {
    var id: UUID { jobID }
    let jobID: UUID
    let mode: LibrarySlimmingAnalyzeMode
    let mediaKind: MediaKind
    let state: JobState
    let controlRequest: JobControlRequest
    let progress: JobProgress
    let attempts: Int
    let maxAttempts: Int
    let memberCount: Int
    let seedCount: Int
    let clusterCount: Int
    let hasResult: Bool
    let createdAtMs: Int64
    let updatedAtMs: Int64
    let sourceNames: [String]

    init(
        jobID: UUID,
        mode: LibrarySlimmingAnalyzeMode,
        mediaKind: MediaKind = .image,
        state: JobState,
        controlRequest: JobControlRequest,
        progress: JobProgress,
        attempts: Int,
        maxAttempts: Int,
        memberCount: Int,
        seedCount: Int,
        clusterCount: Int,
        hasResult: Bool,
        createdAtMs: Int64,
        updatedAtMs: Int64,
        sourceNames: [String] = []
    ) {
        self.jobID = jobID
        self.mode = mode
        self.mediaKind = mediaKind
        self.state = state
        self.controlRequest = controlRequest
        self.progress = progress
        self.attempts = attempts
        self.maxAttempts = maxAttempts
        self.memberCount = memberCount
        self.seedCount = seedCount
        self.clusterCount = clusterCount
        self.hasResult = hasResult
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.sourceNames = sourceNames
    }
}

protocol LibrarySlimmingAnalysisJobPort: Sendable {
    func enqueue(
        mode: LibrarySlimmingAnalyzeMode,
        assetIDs: [UUID],
        seedAssetIDs: [UUID]
    ) throws -> LibrarySlimmingAnalysisJobSnapshot
    func enqueue(
        mode: LibrarySlimmingAnalyzeMode,
        assetIDs: [UUID],
        seedAssetIDs: [UUID],
        mediaKind: MediaKind
    ) throws -> LibrarySlimmingAnalysisJobSnapshot
    func runPending() throws
    func pause(jobID: UUID) throws -> LibrarySlimmingAnalysisJobSnapshot
    func resume(jobID: UUID) throws -> LibrarySlimmingAnalysisJobSnapshot
    func snapshot(jobID: UUID) throws -> LibrarySlimmingAnalysisJobSnapshot
    func latestActiveOrCompleted() throws -> LibrarySlimmingAnalysisJobSnapshot?
    func listJobs() throws -> [LibrarySlimmingAnalysisJobSummary]
    func listJobs(mediaKind: MediaKind) throws -> [LibrarySlimmingAnalysisJobSummary]
    func delete(jobID: UUID) throws
}

extension LibrarySlimmingAnalysisJobPort {
    func enqueue(
        mode: LibrarySlimmingAnalyzeMode,
        assetIDs: [UUID],
        seedAssetIDs: [UUID],
        mediaKind _: MediaKind
    ) throws -> LibrarySlimmingAnalysisJobSnapshot {
        try enqueue(mode: mode, assetIDs: assetIDs, seedAssetIDs: seedAssetIDs)
    }

    func listJobs(mediaKind: MediaKind) throws -> [LibrarySlimmingAnalysisJobSummary] {
        try listJobs().filter { $0.mediaKind == mediaKind }
    }
}

enum LibrarySlimmingAnalysisJobFactory {
    static let kind = "librarySlimming.analysis.v1"
    static let payloadVersion = 1
    static let checkpointVersion = 1
    static let priority = 10
    static let maxAttempts = 10
    static let fingerprintBatchSize = 16
    static let vectorBatchSize = 16
    static let automaticCompletionPasses = 3
    static let leaseDurationMs: Int64 = 10 * 60 * 1_000

    struct Payload: Codable, Sendable, Equatable {
        let mode: LibrarySlimmingAnalyzeMode
        let mediaKind: MediaKind

        init(mode: LibrarySlimmingAnalyzeMode, mediaKind: MediaKind = .image) {
            self.mode = mode
            self.mediaKind = mediaKind
        }

        private enum CodingKeys: String, CodingKey {
            case mode
            case mediaKind
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            mode = try values.decode(LibrarySlimmingAnalyzeMode.self, forKey: .mode)
            mediaKind = try values.decodeIfPresent(MediaKind.self, forKey: .mediaKind) ?? .image
        }
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
        mediaKind: MediaKind = .image,
        notBeforeMs: Int64
    ) throws -> EnqueueJobCommand {
        // Each analysis is an independent durable record. No coalescing key
        // so multiple history / in-flight jobs can coexist without cancelling
        // each other; claim/execute still serializes work via the job queue.
        EnqueueJobCommand(
            id: jobID,
            kind: kind,
            payloadVersion: payloadVersion,
            payload: try JSONEncoder().encode(Payload(mode: mode, mediaKind: mediaKind)),
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
    private let leaseDurationMs: Int64
    private let coordinator: JobExecutionCoordinator

    init(
        database: CatalogDatabase,
        queue: GRDBJobQueue,
        fingerprintCompletion: any FingerprintCompletionPort,
        featureLoader: any SlimmingFeatureVectorLoading,
        embeddingLoader: any SlimmingEmbeddingLoading,
        scanner: any LibrarySlimmingScanPort,
        clock: any JobClock,
        leaseDurationMs: Int64 = LibrarySlimmingAnalysisJobFactory.leaseDurationMs
    ) {
        self.database = database
        self.queue = queue
        self.clock = clock
        self.leaseDurationMs = leaseDurationMs
        let handler = LibrarySlimmingAnalysisHandler(
            database: database,
            queue: queue,
            fingerprintCompletion: fingerprintCompletion,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader,
            scanner: scanner,
            clock: clock,
            leaseDurationMs: leaseDurationMs
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
        try enqueue(
            mode: mode,
            assetIDs: assetIDs,
            seedAssetIDs: seedAssetIDs,
            mediaKind: .image
        )
    }

    func enqueue(
        mode: LibrarySlimmingAnalyzeMode,
        assetIDs: [UUID],
        seedAssetIDs: [UUID],
        mediaKind: MediaKind
    ) throws -> LibrarySlimmingAnalysisJobSnapshot {
        let seeds = Set(seedAssetIDs)
        let members = Array(Set(assetIDs).union(seeds)).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        guard !members.isEmpty else {
            throw FingerprintCompletionError.notFound
        }
        let normalizedMembers = members.map { $0.uuidString.lowercased() }
        let placeholders = Array(repeating: "?", count: normalizedMembers.count)
            .joined(separator: ", ")
        let matchingCount = try database.pool.read { db in
            var arguments: [DatabaseValueConvertible] = normalizedMembers
            arguments.append(mediaKind.rawValue)
            return try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM asset
                WHERE id IN (\(placeholders)) AND media_kind = ?
                """,
                arguments: StatementArguments(arguments)
            ) ?? 0
        }
        guard matchingCount == members.count else {
            throw FingerprintCompletionError.ineligible
        }
        let jobID = UUID()
        let nowMs = clock.nowMs
        let command = try LibrarySlimmingAnalysisJobFactory.makeCommand(
            jobID: jobID,
            mode: mode,
            mediaKind: mediaKind,
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
        try queue.recoverExpiredRunningJobs()
        try reconcileActiveRetryBudgets()
        try queue.settleRetryableJobs()
        let claim = ClaimNextInput(
            owner: "imageall-library-slimming-analysis-\(UUID().uuidString.lowercased())",
            leaseDurationMs: leaseDurationMs,
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
        try queue.recoverExpiredRunningJobs()
        try reconcileActiveRetryBudgets(jobID: jobID)
        let current = try queue.fetchJob(id: jobID)
        if current.state == .pending, current.attempts < current.maxAttempts {
            return try snapshot(jobID: jobID)
        }
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
        let persisted = try database.pool.read { db -> (LibrarySlimmingScanResult?, [UUID]) in
            let result: LibrarySlimmingScanResult?
            if let data: Data = try Data.fetchOne(
                db,
                sql: "SELECT result_json FROM library_slimming_scan_result WHERE job_id = ?",
                arguments: [jobID.uuidString.lowercased()]
            ) {
                result = try JSONDecoder().decode(LibrarySlimmingScanResult.self, from: data)
            } else {
                result = nil
            }
            let rawSeedIDs = try String.fetchAll(
                db,
                sql: """
                SELECT asset_id
                FROM library_slimming_scan_member
                WHERE job_id = ? AND is_seed = 1
                ORDER BY ordinal ASC
                """,
                arguments: [jobID.uuidString.lowercased()]
            )
            return (result, rawSeedIDs.compactMap { UUID(uuidString: $0) })
        }
        return LibrarySlimmingAnalysisJobSnapshot(
            jobID: job.id,
            state: job.state,
            controlRequest: job.controlRequest,
            progress: job.progress,
            result: persisted.0,
            seedAssetIDs: persisted.1
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
        try queue.recoverExpiredRunningJobs()
        try reconcileActiveRetryBudgets()
        return try database.pool.read { db in
            let sourceRows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    member.job_id AS job_id,
                    source.display_name AS display_name,
                    MIN(member.ordinal) AS first_ordinal
                FROM library_slimming_scan_member member
                INNER JOIN asset ON asset.id = member.asset_id
                INNER JOIN source ON source.id = asset.source_id
                INNER JOIN job ON job.id = member.job_id
                WHERE job.kind = ?
                GROUP BY member.job_id, source.id, source.display_name
                ORDER BY member.job_id, first_ordinal, source.id
                """,
                arguments: [LibrarySlimmingAnalysisJobFactory.kind]
            )
            var sourceNamesByJobID: [String: [String]] = [:]
            for sourceRow in sourceRows {
                let jobID: String = sourceRow["job_id"]
                let displayName: String = sourceRow["display_name"]
                sourceNamesByJobID[jobID, default: []].append(displayName)
            }

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
                    job.attempts AS attempts,
                    job.max_attempts AS max_attempts,
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
                    mediaKind: payload.mediaKind,
                    state: try JobPersistenceMapping.jobState(from: row["state"]),
                    controlRequest: try JobPersistenceMapping.controlRequest(
                        from: row["control_request"]
                    ),
                    progress: JobProgress(
                        completed: row["progress_completed"],
                        total: row["progress_total"]
                    ),
                    attempts: row["attempts"],
                    maxAttempts: row["max_attempts"],
                    memberCount: row["member_count"],
                    seedCount: row["seed_count"],
                    clusterCount: clusterCount,
                    hasResult: resultData != nil,
                    createdAtMs: row["created_at_ms"],
                    updatedAtMs: row["updated_at_ms"],
                    sourceNames: sourceNamesByJobID[rawID, default: []]
                )
            }
        }
    }

    func listJobs(mediaKind: MediaKind) throws -> [LibrarySlimmingAnalysisJobSummary] {
        try listJobs().filter { $0.mediaKind == mediaKind }
    }

    private func reconcileActiveRetryBudgets(jobID: UUID? = nil) throws {
        var filterArguments: [DatabaseValueConvertible] = [
            LibrarySlimmingAnalysisJobFactory.kind,
            LibrarySlimmingAnalysisJobFactory.maxAttempts,
        ]
        let jobFilter: String
        if let jobID {
            jobFilter = "AND id = ?"
            filterArguments.append(jobID.uuidString.lowercased())
        } else {
            jobFilter = ""
        }
        let needsUpgrade = try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM job
                    WHERE kind = ?
                        AND state IN ('pending', 'running', 'paused', 'retryableFailed')
                        AND max_attempts < ?
                        \(jobFilter)
                )
                """,
                arguments: StatementArguments(filterArguments)
            ) == 1
        }
        guard needsUpgrade else { return }

        try database.pool.write { db in
            let arguments = [LibrarySlimmingAnalysisJobFactory.maxAttempts] + filterArguments
            try db.execute(
                sql: """
                UPDATE job
                SET max_attempts = ?
                WHERE kind = ?
                    AND state IN ('pending', 'running', 'paused', 'retryableFailed')
                    AND max_attempts < ?
                    \(jobFilter)
                """,
                arguments: StatementArguments(arguments)
            )
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
    let leaseDurationMs: Int64

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
                    if let settled = try commitProgress(
                        lease: lease,
                        state: state,
                        total: total,
                        progressTotal: progressTotal
                    ) {
                        return settled
                    }
                    let members = try allMembers(jobID: lease.jobID)
                    let assetIDs = members.map(\.assetID)
                    let seeds = members.filter(\.isSeed).map(\.assetID)
                    let clusteringCheckpoint =
                        try LibrarySlimmingAnalysisJobFactory.encodeCheckpoint(state)
                    let clusteringProgress = progress(
                        state: state,
                        total: total,
                        progressTotal: progressTotal
                    )
                    let heartbeat = LibrarySlimmingAnalysisLeaseHeartbeat(
                        queue: queue,
                        clock: clock,
                        lease: lease,
                        checkpoint: clusteringCheckpoint,
                        progress: clusteringProgress,
                        leaseDurationMs: leaseDurationMs
                    )
                    heartbeat.start()
                    let scanProgress: LibrarySlimmingScanProgressHandler = { progress in
                        if progress.phase == .clustering
                            || progress.completed == progress.total
                            || progress.completed.isMultiple(of: 256)
                        {
                            heartbeat.renewIfDue()
                        }
                    }
                    let result: LibrarySlimmingScanResult
                    do {
                        if payload.mode == .seeds {
                            result = try scanner.scanSeeds(
                                seedAssetIDs: seeds,
                                universeAssetIDs: assetIDs,
                                mediaKind: payload.mediaKind,
                                onProgress: scanProgress
                            )
                        } else {
                            result = try scanner.scan(
                                assetIDs: assetIDs,
                                mediaKind: payload.mediaKind,
                                onProgress: scanProgress
                            )
                        }
                    } catch {
                        heartbeat.stop()
                        throw error
                    }
                    heartbeat.stop()
                    switch heartbeat.status() {
                    case .active:
                        break
                    case .settled:
                        return JobHandlerExecutionResult(
                            outcome: .continue,
                            checkpoint: clusteringCheckpoint,
                            progress: clusteringProgress,
                            settledByHandler: true
                        )
                    case let .failed(error):
                        throw error
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
                            leaseDurationMs: leaseDurationMs
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
                leaseDurationMs: leaseDurationMs
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

private final class LibrarySlimmingAnalysisLeaseHeartbeat: @unchecked Sendable {
    enum Status {
        case active
        case settled
        case failed(Error)
    }

    private let queue: GRDBJobQueue
    private let clock: any JobClock
    private let lease: JobLeaseToken
    private let checkpoint: JobCheckpoint
    private let progress: JobProgress
    private let leaseDurationMs: Int64
    private let minimumRenewIntervalMs: Int64
    private let lock = NSLock()
    private var lastRenewedAtMs: Int64
    private var storedStatus: Status = .active
    private var timer: DispatchSourceTimer?
    private var isStopped = false

    init(
        queue: GRDBJobQueue,
        clock: any JobClock,
        lease: JobLeaseToken,
        checkpoint: JobCheckpoint,
        progress: JobProgress,
        leaseDurationMs: Int64
    ) {
        self.queue = queue
        self.clock = clock
        self.lease = lease
        self.checkpoint = checkpoint
        self.progress = progress
        self.leaseDurationMs = leaseDurationMs
        minimumRenewIntervalMs = max(100, leaseDurationMs / 3)
        lastRenewedAtMs = clock.nowMs
    }

    func start() {
        lock.lock()
        guard timer == nil, !isStopped, case .active = storedStatus else {
            lock.unlock()
            return
        }
        let interval = DispatchTimeInterval.milliseconds(Int(minimumRenewIntervalMs))
        let source = DispatchSource.makeTimerSource(
            queue: DispatchQueue(
                label: "com.gwlee.ImageAll.library-slimming-lease-heartbeat"
            )
        )
        source.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(max(1, Int(minimumRenewIntervalMs / 10)))
        )
        source.setEventHandler { [weak self] in
            self?.renewIfDue()
        }
        timer = source
        source.resume()
        lock.unlock()
    }

    func stop() {
        lock.lock()
        isStopped = true
        let source = timer
        timer = nil
        source?.setEventHandler {}
        source?.cancel()
        lock.unlock()
    }

    func renewIfDue() {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped, case .active = storedStatus else { return }
        let nowMs = clock.nowMs
        guard nowMs - lastRenewedAtMs >= minimumRenewIntervalMs else { return }
        do {
            let snapshot = try queue.submitSafeBatch(
                SafeBatchCommitInput(
                    lease: lease,
                    outcome: .continue,
                    checkpoint: checkpoint,
                    progress: progress,
                    leaseDurationMs: leaseDurationMs
                )
            )
            lastRenewedAtMs = nowMs
            if snapshot.state != .running {
                storedStatus = .settled
            }
        } catch {
            storedStatus = .failed(error)
        }
    }

    func status() -> Status {
        lock.lock()
        defer { lock.unlock() }
        return storedStatus
    }
}
