import CryptoKit
import Foundation

/// Feature Print Top-K / radius recall + DINOv2 cosine refine → `nearDuplicateScene` clusters.
struct NearDuplicateSceneClusterService: Sendable {
    func cluster(
        featurePrints: [UUID: [Float]],
        embeddings: [UUID: [Float]]
    ) -> [SlimmingCluster] {
        let ids = featurePrints.keys
            .filter { embeddings[$0] != nil }
            .sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        guard ids.count >= 2 else { return [] }

        var parent = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
        var rank: [UUID: Int] = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })

        func find(_ id: UUID) -> UUID {
            var current = id
            while parent[current] != current {
                let next = parent[current]!
                parent[current] = parent[next]
                current = next
            }
            return current
        }
        func union(_ a: UUID, _ b: UUID) {
            let ra = find(a)
            let rb = find(b)
            guard ra != rb else { return }
            let rankA = rank[ra] ?? 0
            let rankB = rank[rb] ?? 0
            if rankA < rankB {
                parent[ra] = rb
            } else if rankA > rankB {
                parent[rb] = ra
            } else {
                parent[rb] = ra
                rank[ra] = rankA + 1
            }
        }

        let topK = NearDuplicateScenePolicy.featurePrintRecallTopK
        let maxL2 = NearDuplicateScenePolicy.featurePrintMaxL2Distance
        let minCosine = NearDuplicateScenePolicy.dinoCosineMinSimilarity
        var acceptedEdges: Set<EdgeKey> = []

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
                let edge = EdgeKey(leftID, neighbor.id)
                guard !acceptedEdges.contains(edge) else { continue }
                guard let leftEmb = embeddings[leftID],
                      let rightEmb = embeddings[neighbor.id],
                      let cosine = SimilarityVectorMath.cosineSimilarity(leftEmb, rightEmb),
                      cosine >= minCosine
                else { continue }
                acceptedEdges.insert(edge)
                union(leftID, neighbor.id)
            }
        }

        var groups: [UUID: [UUID]] = [:]
        for id in ids {
            groups[find(id), default: []].append(id)
        }

        var clusters: [SlimmingCluster] = []
        for (_, membersUnordered) in groups {
            guard membersUnordered.count >= 2 else { continue }
            let members = membersUnordered.sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }
            var maxCosine = 0.0
            for i in 0..<members.count {
                for j in (i + 1)..<members.count {
                    if let cosine = SimilarityVectorMath.cosineSimilarity(
                        embeddings[members[i]]!,
                        embeddings[members[j]]!
                    ) {
                        maxCosine = max(maxCosine, cosine)
                    }
                }
            }
            clusters.append(
                SlimmingCluster(
                    id: Self.stableClusterID(kind: .nearDuplicateScene, members: members),
                    kind: .nearDuplicateScene,
                    memberAssetIDs: members,
                    representativeAssetID: members[0],
                    score: maxCosine,
                    scoreVersion: NearDuplicateScenePolicy.policyVersion
                )
            )
        }

        return clusters.sorted(by: Self.clusterSort)
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
