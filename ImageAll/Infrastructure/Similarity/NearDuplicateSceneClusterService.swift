import CryptoKit
import Foundation

/// Feature Print Top-K / radius recall + DINOv2 cosine refine → complete-linkage `nearDuplicateScene` cliques.
struct NearDuplicateSceneClusterService: Sendable {
    func cluster(
        featurePrints: [UUID: [Float]],
        embeddings: [UUID: [Float]],
        modelIdentity: SlimmingVectorModelIdentity
    ) -> [SlimmingCluster] {
        let ids = featurePrints.keys
            .filter { embeddings[$0] != nil }
            .sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        guard ids.count >= 2 else { return [] }

        let topK = NearDuplicateScenePolicy.featurePrintRecallTopK
        let maxL2 = NearDuplicateScenePolicy.featurePrintMaxL2Distance
        let minCosine = NearDuplicateScenePolicy.dinoCosineMinSimilarity

        var recallEdges: Set<EdgeKey> = []
        for i in 0..<ids.count {
            let leftID = ids[i]
            guard let leftFP = featurePrints[leftID] else { continue }
            var neighbors: [(id: UUID, distance: Double)] = []
            neighbors.reserveCapacity(ids.count - 1)
            for j in 0..<ids.count where j != i {
                let rightID = ids[j]
                guard let rightFP = featurePrints[rightID],
                      let distance = SimilarityVectorMath.l2Distance(leftFP, rightFP),
                      distance <= maxL2
                else { continue }
                neighbors.append((rightID, distance))
            }
            neighbors.sort {
                if $0.distance != $1.distance { return $0.distance < $1.distance }
                return $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
            }
            for neighbor in neighbors.prefix(topK) {
                recallEdges.insert(EdgeKey(leftID, neighbor.id))
            }
        }

        var adjacency: [UUID: Set<UUID>] = Dictionary(uniqueKeysWithValues: ids.map { ($0, []) })
        for edge in recallEdges {
            guard let leftEmb = embeddings[edge.a],
                  let rightEmb = embeddings[edge.b],
                  let cosine = SimilarityVectorMath.cosineSimilarity(leftEmb, rightEmb),
                  cosine >= minCosine
            else { continue }
            adjacency[edge.a, default: []].insert(edge.b)
            adjacency[edge.b, default: []].insert(edge.a)
        }

        let cliques = Self.nonOverlappingMaximalCliques(ids: ids, adjacency: adjacency)
        var clusters: [SlimmingCluster] = []
        for members in cliques {
            var minCosineInCluster = 1.0
            for i in 0..<members.count {
                for j in (i + 1)..<members.count {
                    if let cosine = SimilarityVectorMath.cosineSimilarity(
                        embeddings[members[i]]!,
                        embeddings[members[j]]!
                    ) {
                        minCosineInCluster = min(minCosineInCluster, cosine)
                    }
                }
            }
            clusters.append(
                SlimmingCluster(
                    id: Self.stableClusterID(kind: .nearDuplicateScene, members: members),
                    kind: .nearDuplicateScene,
                    memberAssetIDs: members,
                    representativeAssetID: members[0],
                    score: minCosineInCluster,
                    modelIdentity: modelIdentity
                )
            )
        }

        return clusters.sorted(by: Self.clusterSort)
    }

    /// Query-style clustering: each seed independently retrieves similar neighbors.
    /// The same universe member may appear in multiple seed clusters.
    func clusterAroundSeeds(
        seedAssetIDs: [UUID],
        featurePrints: [UUID: [Float]],
        embeddings: [UUID: [Float]],
        modelIdentity: SlimmingVectorModelIdentity
    ) -> [SlimmingCluster] {
        let seeds = Array(Set(seedAssetIDs))
            .filter { featurePrints[$0] != nil && embeddings[$0] != nil }
            .sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        let candidates = featurePrints.keys
            .filter { embeddings[$0] != nil && !seeds.contains($0) }
            .sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        guard !seeds.isEmpty, !candidates.isEmpty else { return [] }

        let topK = NearDuplicateScenePolicy.featurePrintRecallTopK
        let maxL2 = NearDuplicateScenePolicy.featurePrintMaxL2Distance
        let minCosine = NearDuplicateScenePolicy.dinoCosineMinSimilarity

        var clusters: [SlimmingCluster] = []

        for seed in seeds {
            guard let seedFP = featurePrints[seed],
                  let seedEmb = embeddings[seed]
            else { continue }

            var neighbors: [(id: UUID, distance: Double, cosine: Double)] = []
            for candidate in candidates {
                guard let candidateFP = featurePrints[candidate],
                      let distance = SimilarityVectorMath.l2Distance(seedFP, candidateFP),
                      distance <= maxL2,
                      let candidateEmb = embeddings[candidate],
                      let cosine = SimilarityVectorMath.cosineSimilarity(seedEmb, candidateEmb),
                      cosine >= minCosine
                else { continue }
                neighbors.append((candidate, distance, cosine))
            }
            neighbors.sort {
                if $0.distance != $1.distance { return $0.distance < $1.distance }
                if $0.cosine != $1.cosine { return $0.cosine > $1.cosine }
                return $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
            }
            let hits = neighbors.prefix(topK).map(\.id)
            guard !hits.isEmpty else { continue }

            let members = ([seed] + hits).sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }
            let score = neighbors.prefix(topK).map(\.cosine).min() ?? minCosine
            clusters.append(
                SlimmingCluster(
                    id: Self.stableClusterID(kind: .nearDuplicateScene, members: members),
                    kind: .nearDuplicateScene,
                    memberAssetIDs: members,
                    representativeAssetID: members[0],
                    score: score,
                    modelIdentity: modelIdentity
                )
            )
        }

        return clusters.sorted(by: Self.clusterSort)
    }

    static func nonOverlappingMaximalCliques(
        ids: [UUID],
        adjacency: [UUID: Set<UUID>]
    ) -> [[UUID]] {
        var remaining = ids
        var cliques: [[UUID]] = []
        while true {
            guard let clique = Self.largestClique(in: remaining, adjacency: adjacency),
                  clique.count >= 2
            else {
                break
            }
            cliques.append(clique)
            let cliqueSet = Set(clique)
            remaining.removeAll { cliqueSet.contains($0) }
        }
        return cliques
    }

    static func largestClique(in ids: [UUID], adjacency: [UUID: Set<UUID>]) -> [UUID]? {
        var best: [UUID] = []
        for seed in ids {
            var clique = [seed]
            for candidate in ids where candidate != seed {
                if clique.allSatisfy({ adjacency[$0]?.contains(candidate) == true }) {
                    clique.append(candidate)
                }
            }
            let sorted = clique.sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }
            if sorted.count > best.count {
                best = sorted
            }
        }
        return best.isEmpty ? nil : best
    }

    static func stableClusterID(kind: SlimmingClusterKind, members: [UUID]) -> UUID {
        let material = ([kind.rawValue] + members.map { $0.uuidString.lowercased() })
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(material.utf8))
        let bytes = Array(digest)
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }

    private static func clusterSort(_ lhs: SlimmingCluster, _ rhs: SlimmingCluster) -> Bool {
        if lhs.memberAssetIDs.count != rhs.memberAssetIDs.count {
            return lhs.memberAssetIDs.count > rhs.memberAssetIDs.count
        }
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        return lhs.representativeAssetID.uuidString.lowercased()
            < rhs.representativeAssetID.uuidString.lowercased()
    }

    private struct EdgeKey: Hashable {
        let a: UUID
        let b: UUID

        init(_ left: UUID, _ right: UUID) {
            if left.uuidString.lowercased() <= right.uuidString.lowercased() {
                a = left
                b = right
            } else {
                a = right
                b = left
            }
        }
    }
}
