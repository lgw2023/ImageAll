import Foundation
import GRDB

struct IdenticalDuplicateClusterService: IdenticalDuplicateScanPort {
    let database: CatalogDatabase

    func clusterIdenticalDuplicates(
        assetIDs: [UUID],
        mediaKind: MediaKind
    ) throws -> [IdenticalDuplicateCluster] {
        let uniqueIDs = Array(Set(assetIDs)).sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        guard !uniqueIDs.isEmpty else { return [] }

        var clusters = mediaKind == .video ? try originalVideoClusters(assetIDs: uniqueIDs) : []
        let records = try loadRecords(assetIDs: uniqueIDs, mediaKind: mediaKind)
        guard !records.isEmpty else { return clusters.sorted(by: Self.clusterSort) }

        var claimed = Set(clusters.flatMap(\.memberAssetIDs))

        // Video exact evidence comes only from the independent original-byte table.
        // Poster hashes below never enter the byte-identical lane.
        if mediaKind == .image {
            var bySHA: [Data: [FingerprintRecord]] = [:]
            for record in records where record.digestOrigin == .verifiedOriginalBytes {
                bySHA[record.sha256, default: []].append(record)
            }
            for (_, group) in bySHA.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
                guard group.count >= 2 else { continue }
                let members = group.map(\.assetID).sorted {
                    $0.uuidString.lowercased() < $1.uuidString.lowercased()
                }
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
        }

        // 2) Perceptual duplicates among remaining assets. A dHash match only
        // produces a candidate; every pair in a deletion-grade cluster must
        // also pass normalized RGB and aspect-ratio verification.
        let remaining = records.filter { !claimed.contains($0.assetID) }
        guard remaining.count >= 2 else {
            return clusters.sorted(by: Self.clusterSort)
        }

        let threshold = IdenticalDuplicatePolicy.perceptualDuplicateMaxHammingDistance
        var unassigned = remaining.sorted {
            $0.assetID.uuidString.lowercased() < $1.assetID.uuidString.lowercased()
        }
        while let first = unassigned.first {
            unassigned.removeFirst()
            var group = [first]
            var retained: [FingerprintRecord] = []
            for candidate in unassigned {
                if group.allSatisfy({
                    Self.isVerifiedPerceptualDuplicate(
                        $0,
                        candidate,
                        hammingThreshold: threshold
                    )
                }) {
                    group.append(candidate)
                } else {
                    retained.append(candidate)
                }
            }
            unassigned = retained
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

    private func originalVideoClusters(assetIDs: [UUID]) throws -> [IdenticalDuplicateCluster] {
        try database.pool.read { db in
            let placeholders = Array(repeating: "?", count: assetIDs.count).joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT d.asset_id, d.sha256, d.size_bytes
                FROM asset_original_content_digest d
                JOIN asset a ON a.id = d.asset_id
                JOIN source s ON s.id = a.source_id
                JOIN file_fingerprint f ON f.asset_id = a.id
                WHERE a.id IN (\(placeholders)) AND a.media_kind = 'video'
                  AND a.locator_kind = 'file' AND a.locator_state = 'current'
                  AND a.availability = 'available' AND s.kind = 'folder' AND s.state = 'active'
                  AND d.content_revision = a.content_revision AND d.source_id = a.source_id
                  AND d.relative_path = a.relative_path AND d.size_bytes = f.size_bytes
                  AND d.modified_at_ns = f.modified_at_ns AND d.catalog_resource_id IS f.resource_id
                  AND d.provenance = ?
                """, arguments: StatementArguments(assetIDs.map { $0.uuidString.lowercased() } + [OriginalVideoDigestService.policy]))
            struct Key: Hashable { let digest: Data; let size: Int64 }
            var groups: [Key: [UUID]] = [:]
            for row in rows {
                guard let id = UUID(uuidString: row["asset_id"]),
                      let digest: Data = row["sha256"], digest.count == 32 else { continue }
                groups[Key(digest: digest, size: row["size_bytes"]), default: []].append(id)
            }
            return groups.values.compactMap { members in
                guard members.count > 1 else { return nil }
                let sorted = members.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
                return IdenticalDuplicateCluster(kind: .byteIdentical, memberAssetIDs: sorted,
                    representativeAssetID: sorted[0], score: 0)
            }
        }
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
        let digestOrigin: AssetContentDigestOrigin
        let dHash: UInt64
        let verificationSignature: Data
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private static func isVerifiedPerceptualDuplicate(
        _ left: FingerprintRecord,
        _ right: FingerprintRecord,
        hammingThreshold: Int
    ) -> Bool {
        guard PerceptualImageHash.hammingDistance(left.dHash, right.dHash) <= hammingThreshold else {
            return false
        }
        return PerceptualImageHash.verificationMatches(
            leftSignature: left.verificationSignature,
            leftWidth: left.pixelWidth,
            leftHeight: left.pixelHeight,
            rightSignature: right.verificationSignature,
            rightWidth: right.pixelWidth,
            rightHeight: right.pixelHeight
        )
    }

    private func loadRecords(
        assetIDs: [UUID],
        mediaKind: MediaKind
    ) throws -> [FingerprintRecord] {
        let placeholders = Array(repeating: "?", count: assetIDs.count).joined(separator: ",")
        let idStrings = assetIDs.map { $0.uuidString.lowercased() }
        return try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    p.asset_id,
                    p.content_sha256,
                    p.content_digest_origin,
                    p.perceptual_hash,
                    p.verification_signature,
                    p.pixel_width,
                    p.pixel_height
                FROM asset_similarity_fingerprint p
                JOIN asset a ON a.id = p.asset_id
                WHERE p.asset_id IN (\(placeholders))
                  AND p.content_sha256 IS NOT NULL
                  AND p.verification_signature IS NOT NULL
                  AND p.pixel_width IS NOT NULL
                  AND p.pixel_height IS NOT NULL
                  AND p.algo_version = ?
                  AND p.content_revision = a.content_revision
                  AND a.media_kind = ?
                """,
                arguments: StatementArguments(
                    idStrings + [
                        IdenticalDuplicatePolicy.perceptualAlgoVersion(for: mediaKind),
                        mediaKind.rawValue,
                    ]
                )
            )
            return rows.compactMap { row -> FingerprintRecord? in
                guard let assetID = UUID(uuidString: row["asset_id"]),
                      let sha256: Data = row["content_sha256"],
                      sha256.count == 32,
                      let digestOrigin = AssetContentDigestOrigin(
                          rawValue: row["content_digest_origin"]
                      ),
                      let perceptual: Data = row["perceptual_hash"],
                      let hashValue = PerceptualImageHash.decodeHash(perceptual),
                      let verification: Data = row["verification_signature"],
                      verification.count == 768,
                      let pixelWidth: Int = row["pixel_width"],
                      let pixelHeight: Int = row["pixel_height"],
                      pixelWidth > 0,
                      pixelHeight > 0
                else {
                    return nil
                }
                return FingerprintRecord(
                    assetID: assetID,
                    sha256: sha256,
                    digestOrigin: digestOrigin,
                    dHash: hashValue,
                    verificationSignature: verification,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight
                )
            }
        }
    }
}
