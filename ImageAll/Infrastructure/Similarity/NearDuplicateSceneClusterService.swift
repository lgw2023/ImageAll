import CryptoKit
import Foundation

/// Feature Print Top-K / radius recall + DINOv2 cosine refine → complete-linkage `nearDuplicateScene` cliques.
struct NearDuplicateSceneClusterService: Sendable {
    func cluster(
        featurePrints: [UUID: [Float]],
        embeddings: [UUID: [Float]],
        modelIdentity: SlimmingVectorModelIdentity,
        thresholds: NearDuplicateSceneThresholds = .factory,
        onProgress: ((Int, Int) -> Void)? = nil,
        onFeatureDistanceEvaluation: (() -> Void)? = nil
    ) -> [SlimmingCluster] {
        let ids = featurePrints.keys
            .filter { embeddings[$0] != nil }
            .sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        guard ids.count >= 2 else { return [] }

        let effective = thresholds.clamped()
        let topK = effective.featurePrintRecallMode == .allCandidates
            ? Int.max
            : effective.featurePrintRecallTopK

        let recallEdges: Set<EdgeKey>
        if effective.usesExhaustiveFeaturePrintRecall
            || ids.count <= NearDuplicateScenePolicy.largeBucketActivationAssetCount
        {
            recallEdges = exhaustiveRecallEdges(
                ids: ids,
                featurePrints: featurePrints,
                topK: topK,
                thresholds: effective,
                onProgress: onProgress,
                onFeatureDistanceEvaluation: onFeatureDistanceEvaluation
            )
        } else {
            recallEdges = boundedLSHRecallEdges(
                ids: ids,
                featurePrints: featurePrints,
                topK: topK,
                thresholds: effective,
                onProgress: onProgress,
                onFeatureDistanceEvaluation: onFeatureDistanceEvaluation
            )
        }

        var adjacency: [UUID: Set<UUID>] = Dictionary(uniqueKeysWithValues: ids.map { ($0, []) })
        for edge in recallEdges {
            guard let leftEmb = embeddings[edge.a],
                  let rightEmb = embeddings[edge.b],
                  let cosine = SimilarityVectorMath.cosineSimilarity(leftEmb, rightEmb),
                  effective.acceptsDINOCosine(cosine)
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

    private func exhaustiveRecallEdges(
        ids: [UUID],
        featurePrints: [UUID: [Float]],
        topK: Int,
        thresholds: NearDuplicateSceneThresholds,
        onProgress: ((Int, Int) -> Void)?,
        onFeatureDistanceEvaluation: (() -> Void)?
    ) -> Set<EdgeKey> {
        var recallEdges: Set<EdgeKey> = []
        onProgress?(0, ids.count)
        for i in 0..<ids.count {
            let leftID = ids[i]
            guard let leftFP = featurePrints[leftID] else { continue }
            var neighbors: [(id: UUID, distance: Double)] = []
            neighbors.reserveCapacity(ids.count - 1)
            for j in 0..<ids.count where j != i {
                let rightID = ids[j]
                guard let rightFP = featurePrints[rightID] else { continue }
                onFeatureDistanceEvaluation?()
                guard let distance = SimilarityVectorMath.l2Distance(leftFP, rightFP),
                      thresholds.acceptsFeaturePrintDistance(distance)
                else { continue }
                neighbors.append((rightID, distance))
            }
            Self.appendTopKEdges(
                from: leftID,
                neighbors: neighbors,
                topK: topK,
                into: &recallEdges
            )
            Self.reportProgress(i + 1, total: ids.count, onProgress: onProgress)
        }
        return recallEdges
    }

    private func boundedLSHRecallEdges(
        ids: [UUID],
        featurePrints: [UUID: [Float]],
        topK: Int,
        thresholds: NearDuplicateSceneThresholds,
        onProgress: ((Int, Int) -> Void)?,
        onFeatureDistanceEvaluation: (() -> Void)?
    ) -> Set<EdgeKey> {
        var recallEdges: Set<EdgeKey> = []
        var idsByDimension: [Int: [UUID]] = [:]
        for id in ids {
            guard let vector = featurePrints[id], !vector.isEmpty else { continue }
            idsByDimension[vector.count, default: []].append(id)
        }

        var completed = 0
        onProgress?(0, ids.count)
        for dimension in idsByDimension.keys.sorted() {
            guard let dimensionIDs = idsByDimension[dimension] else { continue }
            let sortedIDs = dimensionIDs.sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }
            let seed = "\(NearDuplicateScenePolicy.policyVersion)|lsh|bits="
                + "\(NearDuplicateScenePolicy.largeBucketLSHBitCount)|dim=\(dimension)"
            let planes = FeaturePrintLSH.generatePlanes(
                seed: seed,
                bitCount: NearDuplicateScenePolicy.largeBucketLSHBitCount,
                dimension: dimension
            )
            var keyByID: [UUID: UInt64] = [:]
            var idsByKey: [UInt64: [UUID]] = [:]
            for id in sortedIDs {
                guard let vector = featurePrints[id] else { continue }
                let key = FeaturePrintLSH.bucketKey(vector: vector, planes: planes)
                keyByID[id] = key
                idsByKey[key, default: []].append(id)
            }
            for key in idsByKey.keys {
                idsByKey[key]?.sort {
                    $0.uuidString.lowercased() < $1.uuidString.lowercased()
                }
            }
            let positionByID = Dictionary(
                uniqueKeysWithValues: idsByKey.values.flatMap { bucket in
                    bucket.enumerated().map { ($0.element, $0.offset) }
                }
            )

            for id in sortedIDs {
                defer {
                    completed += 1
                    Self.reportProgress(completed, total: ids.count, onProgress: onProgress)
                }
                guard let leftFP = featurePrints[id],
                      let key = keyByID[id]
                else { continue }
                let neighborKeys = FeaturePrintLSH.neighborKeys(
                    key: key,
                    bitCount: NearDuplicateScenePolicy.largeBucketLSHBitCount,
                    maxHamming: NearDuplicateScenePolicy.largeBucketNeighborMaxHamming
                ).sorted {
                    let leftDistance = ($0 ^ key).nonzeroBitCount
                    let rightDistance = ($1 ^ key).nonzeroBitCount
                    if leftDistance != rightDistance { return leftDistance < rightDistance }
                    return $0 < $1
                }
                let candidates = Self.boundedCandidates(
                    for: id,
                    ownKey: key,
                    neighborKeys: neighborKeys,
                    idsByKey: idsByKey,
                    positionByID: positionByID,
                    limit: NearDuplicateScenePolicy.largeBucketCandidateLimit
                )
                var neighbors: [(id: UUID, distance: Double)] = []
                neighbors.reserveCapacity(candidates.count)
                for candidate in candidates {
                    guard let rightFP = featurePrints[candidate] else { continue }
                    onFeatureDistanceEvaluation?()
                    guard let distance = SimilarityVectorMath.l2Distance(leftFP, rightFP),
                          thresholds.acceptsFeaturePrintDistance(distance)
                    else { continue }
                    neighbors.append((candidate, distance))
                }
                Self.appendTopKEdges(
                    from: id,
                    neighbors: neighbors,
                    topK: topK,
                    into: &recallEdges
                )
            }
        }
        onProgress?(ids.count, ids.count)
        return recallEdges
    }

    private static func boundedCandidates(
        for id: UUID,
        ownKey: UInt64,
        neighborKeys: [UInt64],
        idsByKey: [UInt64: [UUID]],
        positionByID: [UUID: Int],
        limit: Int
    ) -> [UUID] {
        guard limit > 0 else { return [] }
        var result: [UUID] = []
        result.reserveCapacity(limit)

        for neighborKey in neighborKeys {
            guard result.count < limit,
                  let bucket = idsByKey[neighborKey],
                  !bucket.isEmpty
            else { continue }
            let start: Int
            if neighborKey == ownKey, let ownPosition = positionByID[id] {
                start = (ownPosition + 1) % bucket.count
            } else {
                start = stableOffset(id: id, key: neighborKey, count: bucket.count)
            }
            for offset in 0..<bucket.count {
                let candidate = bucket[(start + offset) % bucket.count]
                if candidate == id { continue }
                result.append(candidate)
                if result.count == limit { return result }
            }
        }
        return result
    }

    private static func stableOffset(id: UUID, key: UInt64, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let prefix = id.uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        let value = UInt64(prefix, radix: 16) ?? 0
        return Int((value ^ key) % UInt64(count))
    }

    private static func appendTopKEdges(
        from id: UUID,
        neighbors: [(id: UUID, distance: Double)],
        topK: Int,
        into edges: inout Set<EdgeKey>
    ) {
        let sorted = neighbors.sorted {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            return $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
        }
        for neighbor in sorted.prefix(topK) {
            edges.insert(EdgeKey(id, neighbor.id))
        }
    }

    private static func reportProgress(
        _ completed: Int,
        total: Int,
        onProgress: ((Int, Int) -> Void)?
    ) {
        if completed == total || completed.isMultiple(of: 64) {
            onProgress?(completed, total)
        }
    }

    /// Query-style clustering: seeds are evaluated in stable order and each
    /// universe candidate is claimed by at most one complete-link seed cluster.
    func clusterAroundSeeds(
        seedAssetIDs: [UUID],
        featurePrints: [UUID: [Float]],
        embeddings: [UUID: [Float]],
        modelIdentity: SlimmingVectorModelIdentity,
        thresholds: NearDuplicateSceneThresholds = .factory
    ) -> [SlimmingCluster] {
        let seeds = Array(Set(seedAssetIDs))
            .filter { featurePrints[$0] != nil && embeddings[$0] != nil }
            .sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        let seedSet = Set(seeds)
        let candidates = featurePrints.keys
            .filter { embeddings[$0] != nil && !seedSet.contains($0) }
            .sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        guard !seeds.isEmpty, !candidates.isEmpty else { return [] }

        let effective = thresholds.clamped()
        let topK = effective.featurePrintRecallMode == .allCandidates
            ? Int.max
            : effective.featurePrintRecallTopK

        var clusters: [SlimmingCluster] = []
        var claimedCandidates = Set<UUID>()

        for seed in seeds {
            guard let seedFP = featurePrints[seed],
                  let seedEmb = embeddings[seed]
            else { continue }

            var neighbors: [(id: UUID, distance: Double, cosine: Double)] = []
            for candidate in candidates where !claimedCandidates.contains(candidate) {
                guard let candidateFP = featurePrints[candidate],
                      let distance = SimilarityVectorMath.l2Distance(seedFP, candidateFP),
                      effective.acceptsFeaturePrintDistance(distance),
                      let candidateEmb = embeddings[candidate],
                      let cosine = SimilarityVectorMath.cosineSimilarity(seedEmb, candidateEmb),
                      effective.acceptsDINOCosine(cosine)
                else { continue }
                neighbors.append((candidate, distance, cosine))
            }
            neighbors.sort {
                if $0.distance != $1.distance { return $0.distance < $1.distance }
                if $0.cosine != $1.cosine { return $0.cosine > $1.cosine }
                return $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
            }
            var hits: [UUID] = []
            for neighbor in neighbors {
                if hits.count == topK {
                    break
                }
                let isCompleteLink = hits.allSatisfy { existingID in
                    guard let existingFP = featurePrints[existingID],
                          let candidateFP = featurePrints[neighbor.id],
                          let distance = SimilarityVectorMath.l2Distance(
                              existingFP,
                              candidateFP
                          ),
                          effective.acceptsFeaturePrintDistance(distance),
                          let existingEmbedding = embeddings[existingID],
                          let candidateEmbedding = embeddings[neighbor.id],
                          let cosine = SimilarityVectorMath.cosineSimilarity(
                              existingEmbedding,
                              candidateEmbedding
                          )
                    else {
                        return false
                    }
                    return effective.acceptsDINOCosine(cosine)
                }
                if isCompleteLink {
                    hits.append(neighbor.id)
                }
            }
            guard !hits.isEmpty else { continue }
            claimedCandidates.formUnion(hits)

            let members = ([seed] + hits).sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }
            var score = 1.0
            for i in 0 ..< members.count {
                for j in (i + 1) ..< members.count {
                    if let left = embeddings[members[i]],
                       let right = embeddings[members[j]],
                       let cosine = SimilarityVectorMath.cosineSimilarity(left, right)
                    {
                        score = min(score, cosine)
                    }
                }
            }
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
        let allowed = Set(ids)
        for seed in ids {
            var clique = [seed]
            let candidates = (adjacency[seed] ?? [])
                .intersection(allowed)
                .sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
            for candidate in candidates {
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
