import Foundation
import GRDB

struct IdenticalDuplicateClusterService: IdenticalDuplicateScanPort {
    let database: CatalogDatabase

    func clusterIdenticalDuplicates(assetIDs: [UUID]) throws -> [IdenticalDuplicateCluster] {
        let uniqueIDs = Array(Set(assetIDs)).sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        guard !uniqueIDs.isEmpty else { return [] }

        let records = try loadRecords(assetIDs: uniqueIDs)
        guard !records.isEmpty else { return [] }

        var claimed = Set<UUID>()
        var clusters: [IdenticalDuplicateCluster] = []

        // 1) Byte-identical groups by sha256.
        var bySHA: [Data: [FingerprintRecord]] = [:]
        for record in records {
            bySHA[record.sha256, default: []].append(record)
        }
        for (_, group) in bySHA.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            guard group.count >= 2 else { continue }
            let members = group.map(\.assetID).sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
            for id in members { claimed.insert(id) }
            clusters.append(
                IdenticalDuplicateCluster(
                    kind: .byteIdentical,
                    memberAssetIDs: members,
                    representativeAssetID: members[0],
                    score: 0
                )
            )
        }

        // 2) Perceptual duplicates among remaining assets (union-find on Hamming ≤ τ).
        let remaining = records.filter { !claimed.contains($0.assetID) }
        guard remaining.count >= 2 else {
            return clusters.sorted(by: Self.clusterSort)
        }

        var parent = Dictionary(uniqueKeysWithValues: remaining.map { ($0.assetID, $0.assetID) })
        var rank: [UUID: Int] = Dictionary(uniqueKeysWithValues: remaining.map { ($0.assetID, 0) })

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

        let threshold = IdenticalDuplicatePolicy.perceptualDuplicateMaxHammingDistance
        for i in 0..<remaining.count {
            for j in (i + 1)..<remaining.count {
                let left = remaining[i]
                let right = remaining[j]
                let distance = PerceptualImageHash.hammingDistance(left.dHash, right.dHash)
                if distance <= threshold {
                    union(left.assetID, right.assetID)
                }
            }
        }

        var groups: [UUID: [FingerprintRecord]] = [:]
        for record in remaining {
            groups[find(record.assetID), default: []].append(record)
        }
        for (_, group) in groups {
            guard group.count >= 2 else { continue }
            let members = group.map(\.assetID).sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
            var maxDistance = 0
            for i in 0..<group.count {
                for j in (i + 1)..<group.count {
                    maxDistance = max(
                        maxDistance,
                        PerceptualImageHash.hammingDistance(group[i].dHash, group[j].dHash)
                    )
                }
            }
            clusters.append(
                IdenticalDuplicateCluster(
                    kind: .perceptualDuplicate,
                    memberAssetIDs: members,
                    representativeAssetID: members[0],
                    score: maxDistance
                )
            )
        }

        return clusters.sorted(by: Self.clusterSort)
    }

    private static func clusterSort(_ lhs: IdenticalDuplicateCluster, _ rhs: IdenticalDuplicateCluster) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind == .byteIdentical
        }
        if lhs.memberAssetIDs.count != rhs.memberAssetIDs.count {
            return lhs.memberAssetIDs.count > rhs.memberAssetIDs.count
        }
        return lhs.representativeAssetID.uuidString.lowercased()
            < rhs.representativeAssetID.uuidString.lowercased()
    }

    private struct FingerprintRecord: Sendable {
        let assetID: UUID
        let sha256: Data
        let dHash: UInt64
    }

    private func loadRecords(assetIDs: [UUID]) throws -> [FingerprintRecord] {
        let placeholders = Array(repeating: "?", count: assetIDs.count).joined(separator: ",")
        let idStrings = assetIDs.map { $0.uuidString.lowercased() }
        return try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT f.asset_id, f.sha256, p.perceptual_hash
                FROM file_fingerprint f
                JOIN asset_similarity_fingerprint p ON p.asset_id = f.asset_id
                JOIN asset a ON a.id = f.asset_id
                WHERE f.asset_id IN (\(placeholders))
                  AND f.sha256 IS NOT NULL
                  AND p.algo_version = ?
                  AND p.content_revision = a.content_revision
                """,
                arguments: StatementArguments(idStrings + [IdenticalDuplicatePolicy.perceptualAlgoVersion])
            )
            return rows.compactMap { row -> FingerprintRecord? in
                guard let assetID = UUID(uuidString: row["asset_id"]),
                      let sha256: Data = row["sha256"],
                      sha256.count == 32,
                      let perceptual: Data = row["perceptual_hash"],
                      let hashValue = PerceptualImageHash.decodeHash(perceptual)
                else {
                    return nil
                }
                return FingerprintRecord(assetID: assetID, sha256: sha256, dHash: hashValue)
            }
        }
    }
}
