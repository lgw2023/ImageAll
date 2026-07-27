import Foundation
import GRDB

struct LibrarySlimmingScanService: LibrarySlimmingScanPort {
    let database: CatalogDatabase
    let identicalScan: any IdenticalDuplicateScanPort
    let fingerprintCompletion: (any FingerprintCompletionPort)?
    let featureLoader: any SlimmingFeatureVectorLoading
    let embeddingLoader: any SlimmingEmbeddingLoading

    func scanCatalog(limit: Int) throws -> LibrarySlimmingScanResult {
        let capped = max(0, limit)
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
                LIMIT ?
                """,
                arguments: [
                    AssetLocatorState.current.rawValue,
                    AssetAvailability.available.rawValue,
                    SourceState.active.rawValue,
                    capped,
                ]
            )
            return rows.compactMap { row in
                UUID(uuidString: row["id"])
            }
        }
        return try scan(assetIDs: assetIDs)
    }

    func scan(assetIDs: [UUID]) throws -> LibrarySlimmingScanResult {
        (embeddingLoader as? CatalogSlimmingEmbeddingLoader)?.resetGenerationBudget()

        let uniqueIDs = Array(Set(assetIDs)).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        guard !uniqueIDs.isEmpty else {
            return LibrarySlimmingScanResult(
                clusters: [],
                pendingAnalysisAssetIDs: [],
                analyzedAssetCount: 0,
                policyVersion: NearDuplicateScenePolicy.policyVersion
            )
        }

        if let fingerprintCompletion {
            for assetID in uniqueIDs {
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
        }

        let identical = try identicalScan.clusterIdenticalDuplicates(assetIDs: uniqueIDs)
        var claimed = Set<UUID>()
        for cluster in identical {
            claimed.formUnion(cluster.memberAssetIDs)
        }

        var pending: [UUID] = []
        var featurePrints: [UUID: [Float]] = [:]
        var embeddings: [UUID: [Float]] = [:]

        for assetID in uniqueIDs where !claimed.contains(assetID) {
            guard let feature = try featureLoader.featureVector(assetID: assetID) else {
                pending.append(assetID)
                continue
            }
            guard let embedding = try embeddingLoader.embedding(assetID: assetID) else {
                pending.append(assetID)
                continue
            }
            featurePrints[assetID] = feature
            embeddings[assetID] = embedding
        }

        let sceneClusters = NearDuplicateSceneClusterService().cluster(
            featurePrints: featurePrints,
            embeddings: embeddings
        )

        let identicalMapped = identical.map { cluster -> SlimmingCluster in
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
                scoreVersion: IdenticalDuplicatePolicy.perceptualAlgoVersion
            )
        }

        let clusters = (identicalMapped + sceneClusters).sorted(by: Self.clusterSort)
        return LibrarySlimmingScanResult(
            clusters: clusters,
            pendingAnalysisAssetIDs: pending.sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            },
            analyzedAssetCount: uniqueIDs.count,
            policyVersion: NearDuplicateScenePolicy.policyVersion
        )
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

struct FeaturePrintSlimmingVectorLoader: SlimmingFeatureVectorLoading {
    let service: any SyncFeatureVectorLoading

    func featureVector(assetID: UUID) throws -> [Float]? {
        do {
            let payload = try service.loadOrGenerateSync(assetID: assetID)
            return try PersonalizedSuggestionScoringCore.decode(payload)
        } catch {
            return nil
        }
    }
}

/// Returns embeddings only when the optional loader can supply them; otherwise nil → pending.
struct OptionalSlimmingEmbeddingLoader: SlimmingEmbeddingLoading {
    let base: (any SlimmingEmbeddingLoading)?

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

    func embedding(assetID: UUID) throws -> [Float]? {
        vectors[assetID]
    }
}
