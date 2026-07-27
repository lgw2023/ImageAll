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

    init(
        database: CatalogDatabase,
        identicalScan: any IdenticalDuplicateScanPort,
        fingerprintCompletion: (any FingerprintCompletionPort)?,
        featureLoader: any SlimmingFeatureVectorLoading,
        embeddingLoader: any SlimmingEmbeddingLoading,
        thresholdReader: any NearDuplicateSceneThresholdReading = StaticNearDuplicateSceneThresholds(
            value: .factory
        ),
        bucketCalendar: Calendar = .current
    ) {
        self.database = database
        self.identicalScan = identicalScan
        self.fingerprintCompletion = fingerprintCompletion
        self.featureLoader = featureLoader
        self.embeddingLoader = embeddingLoader
        self.thresholdReader = thresholdReader
        self.bucketCalendar = bucketCalendar
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

        let vectorCandidates = universe.filter { !claimed.contains($0) }
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
            seedAssetIDs: seeds.filter { !claimed.contains($0) },
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
                _ = try fingerprintCompletion.completeFolderAsset(assetID: assetID)
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
