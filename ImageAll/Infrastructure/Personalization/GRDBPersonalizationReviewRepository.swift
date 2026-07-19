import Foundation
import GRDB

struct GRDBPersonalizationReviewRepository: Sendable {
    let database: CatalogDatabase

    func totalPendingSuggestionCount() throws -> Int {
        try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM prediction p
                JOIN tag_model m
                    ON m.tag_id = p.tag_id
                    AND m.current_revision = p.model_revision
                JOIN tag t ON t.id = p.tag_id AND t.state = 'active'
                JOIN asset a
                    ON a.id = p.asset_id
                    AND a.content_revision = p.content_revision
                    AND a.locator_state = 'current'
                    AND a.availability = 'available'
                LEFT JOIN asset_tag_decision d
                    ON d.asset_id = p.asset_id AND d.tag_id = p.tag_id
                WHERE p.state = 'pendingReview'
                    AND d.asset_id IS NULL
                """
            ) ?? 0
        }
    }

    func pendingCount(tagID: UUID) throws -> Int {
        try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM prediction p
                JOIN tag_model m
                    ON m.tag_id = p.tag_id
                    AND m.current_revision = p.model_revision
                JOIN tag t ON t.id = p.tag_id AND t.state = 'active'
                JOIN asset a
                    ON a.id = p.asset_id
                    AND a.content_revision = p.content_revision
                    AND a.locator_state = 'current'
                    AND a.availability = 'available'
                LEFT JOIN asset_tag_decision d
                    ON d.asset_id = p.asset_id AND d.tag_id = p.tag_id
                WHERE p.tag_id = ?
                    AND p.state = 'pendingReview'
                    AND d.asset_id IS NULL
                """,
                arguments: [uuid(tagID)]
            ) ?? 0
        }
    }

    func sampleCounts(tagID: UUID) throws -> (accepted: Int, rejected: Int) {
        try database.pool.read { db in
            let accepted = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM asset_tag_decision d
                JOIN asset a ON a.id = d.asset_id
                JOIN source s ON s.id = a.source_id
                WHERE d.tag_id = ? AND d.decision = 'accepted'
                    AND a.locator_state = 'current'
                    AND a.availability = 'available'
                    AND s.state = 'active'
                    AND (
                        (s.kind = 'folder' AND a.locator_kind = 'file')
                        OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                    )
                """,
                arguments: [uuid(tagID)]
            ) ?? 0
            let rejected = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM asset_tag_decision d
                JOIN asset a ON a.id = d.asset_id
                JOIN source s ON s.id = a.source_id
                WHERE d.tag_id = ? AND d.decision = 'rejected'
                    AND a.locator_state = 'current'
                    AND a.availability = 'available'
                    AND s.state = 'active'
                    AND (
                        (s.kind = 'folder' AND a.locator_kind = 'file')
                        OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                    )
                """,
                arguments: [uuid(tagID)]
            ) ?? 0
            return (accepted, rejected)
        }
    }

    func tagHasCurrentModel(tagID: UUID) throws -> Bool {
        try database.pool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM tag_model WHERE tag_id = ?)",
                arguments: [uuid(tagID)]
            ) ?? false
        }
    }

    func fetchFrozenSampleIdentities(tagID: UUID) throws -> (
        positives: [FrozenSampleIdentity],
        negatives: [FrozenSampleIdentity]
    ) {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                WITH ranked AS (
                    SELECT
                        a.id,
                        a.content_revision,
                        d.decision,
                        ROW_NUMBER() OVER (
                            PARTITION BY d.decision
                            ORDER BY d.updated_at_ms DESC, a.id ASC
                        ) AS role_rank
                    FROM asset_tag_decision d
                    JOIN asset a ON a.id = d.asset_id
                    JOIN source s ON s.id = a.source_id
                    WHERE d.tag_id = ?
                        AND d.decision IN ('accepted', 'rejected')
                        AND a.locator_state = 'current'
                        AND a.availability = 'available'
                        AND s.state = 'active'
                        AND (
                            (s.kind = 'folder' AND a.locator_kind = 'file')
                            OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                        )
                )
                SELECT id, content_revision, decision
                FROM ranked
                WHERE role_rank <= 12
                ORDER BY decision ASC, role_rank ASC
                """,
                arguments: [uuid(tagID)]
            )
            var positives: [FrozenSampleIdentity] = []
            var negatives: [FrozenSampleIdentity] = []
            for row in rows {
                guard let assetID = UUID(uuidString: row["id"]) else { continue }
                let identity = FrozenSampleIdentity(
                    assetID: assetID,
                    contentRevision: row["content_revision"]
                )
                if row["decision"] as String == "accepted" {
                    positives.append(identity)
                } else {
                    negatives.append(identity)
                }
            }
            return (positives, negatives)
        }
    }

    func personalTrainingSnapshot() throws -> PersonalTrainingSnapshot {
        let catalogScopeID = try database.catalogScopeID()
        return try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                WITH eligible_decisions AS (
                    SELECT
                        d.asset_id,
                        a.content_revision,
                        d.tag_id,
                        d.decision,
                        d.updated_at_ms
                    FROM asset_tag_decision d
                    JOIN tag t ON t.id = d.tag_id
                    JOIN asset a ON a.id = d.asset_id
                    JOIN source s ON s.id = a.source_id
                    WHERE t.state = 'active'
                        AND d.decision IN ('accepted', 'rejected')
                        AND a.locator_state = 'current'
                        AND a.availability = 'available'
                        AND s.state = 'active'
                        AND (
                            (s.kind = 'folder' AND a.locator_kind = 'file')
                            OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                        )
                ),
                trainable_tags AS (
                    SELECT tag_id
                    FROM eligible_decisions
                    GROUP BY tag_id
                    HAVING SUM(CASE WHEN decision = 'accepted' THEN 1 ELSE 0 END) >= 2
                        AND SUM(CASE WHEN decision = 'rejected' THEN 1 ELSE 0 END) >= 2
                ),
                ranked AS (
                    SELECT
                        asset_id,
                        content_revision,
                        tag_id,
                        decision,
                        ROW_NUMBER() OVER (
                            PARTITION BY tag_id, decision
                            ORDER BY updated_at_ms DESC, asset_id ASC
                        ) AS role_rank
                    FROM eligible_decisions
                    WHERE tag_id IN (SELECT tag_id FROM trainable_tags)
                )
                SELECT asset_id, content_revision, tag_id, decision
                FROM ranked
                WHERE role_rank <= 12
                ORDER BY tag_id ASC, decision ASC, role_rank ASC
                """
            )
            let decisions = rows.compactMap { row -> PersonalTrainingDecision? in
                guard let assetID = UUID(uuidString: row["asset_id"]),
                      let tagID = UUID(uuidString: row["tag_id"])
                else {
                    return nil
                }
                let decision: String = row["decision"]
                return PersonalTrainingDecision(
                    assetID: assetID,
                    contentRevision: row["content_revision"],
                    tagID: tagID,
                    state: decision == "accepted" ? .manualAccepted : .manualRejected
                )
            }
            let tagIDs = Array(Set(decisions.map(\.tagID))).sorted {
                $0.uuidString < $1.uuidString
            }
            return PersonalTrainingSnapshot(
                catalogScopeID: catalogScopeID,
                personalTagIDs: tagIDs,
                decisions: decisions
            )
        }
    }

    struct FrozenAssetProcessingContext: Sendable {
        let contentRevision: Int
        let availability: String
        let sourceState: String
        let locatorState: String
        let recordUpdatedAtMs: Int64
        let hasDecision: Bool
    }

    func frozenAssetProcessingContext(tagID: UUID, assetID: UUID) throws -> FrozenAssetProcessingContext? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT a.content_revision, a.availability, a.locator_state, a.record_updated_at_ms,
                    s.state AS source_state,
                    EXISTS(
                        SELECT 1 FROM asset_tag_decision d
                        WHERE d.asset_id = a.id AND d.tag_id = ?
                    ) AS has_decision
                FROM asset a
                JOIN source s ON s.id = a.source_id
                WHERE a.id = ?
                    AND a.locator_state = 'current'
                    AND (
                        (s.kind = 'folder' AND a.locator_kind = 'file')
                        OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                    )
                """,
                arguments: [uuid(tagID), uuid(assetID)]
            ) else { return nil }
            return FrozenAssetProcessingContext(
                contentRevision: row["content_revision"],
                availability: row["availability"],
                sourceState: row["source_state"],
                locatorState: row["locator_state"],
                recordUpdatedAtMs: row["record_updated_at_ms"],
                hasDecision: row["has_decision"]
            )
        }
    }

    func activePersonalizationSourceIDs() throws -> [UUID] {
        try database.pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT id FROM source
                WHERE kind IN ('folder', 'photos') AND state = 'active'
                ORDER BY id ASC
                """
            ).compactMap(UUID.init(uuidString:))
        }
    }

    func frozenAssetBatch(
        sourceIDs: [UUID],
        catalogCutoffMs: Int64,
        afterAssetID: UUID?,
        limit: Int
    ) throws -> [UUID] {
        guard !sourceIDs.isEmpty, limit > 0 else { return [] }
        let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ", ")
        var arguments: [DatabaseValueConvertible] = sourceIDs.map { uuid($0) }
        arguments.append(catalogCutoffMs)
        var afterClause = ""
        if let afterAssetID {
            afterClause = "AND a.id > ?"
            arguments.append(uuid(afterAssetID))
        }
        arguments.append(limit)
        return try database.pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT a.id
                FROM asset a
                JOIN source s ON s.id = a.source_id
                WHERE s.id IN (\(placeholders))
                    AND (
                        (s.kind = 'folder' AND a.locator_kind = 'file')
                        OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                    )
                    AND a.record_created_at_ms <= ?
                    \(afterClause)
                ORDER BY a.id ASC
                LIMIT ?
                """,
                arguments: StatementArguments(arguments)
            ).compactMap(UUID.init(uuidString:))
        }
    }

    func frozenAssetTotal(
        sourceIDs: [UUID],
        catalogCutoffMs: Int64
    ) throws -> Int {
        guard !sourceIDs.isEmpty else { return 0 }
        let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ", ")
        return try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM asset a
                JOIN source s ON s.id = a.source_id
                WHERE s.id IN (\(placeholders))
                    AND (
                        (s.kind = 'folder' AND a.locator_kind = 'file')
                        OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                    )
                    AND a.record_created_at_ms <= ?
                """,
                arguments: StatementArguments(sourceIDs.map { uuid($0) } + [catalogCutoffMs])
            ) ?? 0
        }
    }

    func fetchReviewQueuePage(
        tagID: UUID,
        cursor: ReviewQueueCursor?,
        limit: Int
    ) throws -> ReviewQueuePage {
        var sql = """
        SELECT p.asset_id, p.score, a.file_name, a.availability,
            (
                SELECT COUNT(*) FROM asset_tag_decision d
                WHERE d.asset_id = a.id AND d.decision = 'accepted'
            ) AS accepted_count,
            (
                SELECT COUNT(*) FROM asset_tag_decision d
                WHERE d.asset_id = a.id AND d.decision = 'rejected'
            ) AS rejected_count
        FROM prediction p
        JOIN tag_model m
            ON m.tag_id = p.tag_id
            AND m.current_revision = p.model_revision
        JOIN tag t ON t.id = p.tag_id AND t.state = 'active'
        JOIN asset a
            ON a.id = p.asset_id
            AND a.content_revision = p.content_revision
            AND a.locator_state = 'current'
            AND a.availability = 'available'
        LEFT JOIN asset_tag_decision d
            ON d.asset_id = p.asset_id AND d.tag_id = p.tag_id
        WHERE p.tag_id = ?
            AND p.state = 'pendingReview'
            AND d.asset_id IS NULL
        """
        var arguments: [DatabaseValueConvertible] = [uuid(tagID)]
        if let cursor {
            let boundary = try ReviewQueueCursorCodec.decodeBoundary(cursor)
            sql += """
             AND (
                p.score < ?
                OR (p.score = ? AND p.asset_id > ?)
             )
            """
            arguments.append(boundary.score)
            arguments.append(boundary.score)
            arguments.append(uuid(boundary.assetID))
        }
        sql += " ORDER BY p.score DESC, p.asset_id ASC LIMIT ?"
        arguments.append(limit + 1)

        return try database.pool.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            let mapped: [ReviewQueueItemProjection] = rows.compactMap { row in
                guard let assetID = UUID(uuidString: row["asset_id"]) else { return nil }
                let availabilityRaw: String = row["availability"]
                guard let availability = AssetAvailability(rawValue: availabilityRaw) else { return nil }
                return ReviewQueueItemProjection(
                    assetID: assetID,
                    fileName: row["file_name"],
                    availability: availability,
                    acceptedTagCount: row["accepted_count"],
                    rejectedTagCount: row["rejected_count"]
                )
            }
            let items = Array(mapped.prefix(limit))
            let nextCursor: ReviewQueueCursor?
            if rows.count > limit {
                let boundary = rows[limit - 1]
                let assetID = UUID(uuidString: boundary["asset_id"]) ?? items.last!.assetID
                nextCursor = try ReviewQueueCursorCodec.encodeBoundary(
                    score: boundary["score"],
                    assetID: assetID
                )
            } else {
                nextCursor = nil
            }
            return ReviewQueuePage(items: items, nextCursor: nextCursor)
        }
    }

    func pendingSuggestionsForAsset(assetID: UUID) throws -> [AssetPendingSuggestion] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT p.tag_id, t.name
                FROM prediction p
                JOIN tag_model m
                    ON m.tag_id = p.tag_id
                    AND m.current_revision = p.model_revision
                JOIN tag t ON t.id = p.tag_id AND t.state = 'active'
                JOIN asset a
                    ON a.id = p.asset_id
                    AND a.content_revision = p.content_revision
                    AND a.locator_state = 'current'
                    AND a.availability = 'available'
                LEFT JOIN asset_tag_decision d
                    ON d.asset_id = p.asset_id AND d.tag_id = p.tag_id
                WHERE p.asset_id = ?
                    AND p.state = 'pendingReview'
                    AND d.asset_id IS NULL
                ORDER BY t.name COLLATE NOCASE ASC, p.tag_id ASC
                """,
                arguments: [uuid(assetID)]
            ).compactMap { row in
                guard let tagID = UUID(uuidString: row["tag_id"]) else { return nil }
                return AssetPendingSuggestion(tagID: tagID, displayName: row["name"])
            }
        }
    }

    func activeSuggestionJob(tagID: UUID) throws -> JobRecordSnapshot? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM job
                WHERE coalescing_key = ?
                    AND state IN ('pending', 'running', 'paused', 'retryableFailed')
                ORDER BY created_at_ms DESC
                LIMIT 1
                """,
                arguments: [FullLibrarySuggestionsJobFactory.coalescingKey(tagID: tagID)]
            ) else { return nil }
            return try JobPersistenceMapping.snapshot(from: row)
        }
    }

    func nextModelRevision(tagID: UUID) throws -> Int {
        try database.pool.read { db in
            let current: Int = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(revision), 0) FROM tag_model_revision WHERE tag_id = ?",
                arguments: [uuid(tagID)]
            ) ?? 0
            return current + 1
        }
    }

    func fetchFrozenSamples(tagID: UUID) throws -> (
        positives: [PersonalizedSuggestionScoringCore.CandidateRevision],
        negatives: [PersonalizedSuggestionScoringCore.CandidateRevision]
    ) {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                WITH ranked AS (
                    SELECT
                        a.id,
                        a.content_revision,
                        d.decision,
                        ROW_NUMBER() OVER (
                            PARTITION BY d.decision
                            ORDER BY d.updated_at_ms DESC, a.id ASC
                        ) AS role_rank
                    FROM asset_tag_decision d
                    JOIN asset a ON a.id = d.asset_id
                    JOIN source s ON s.id = a.source_id
                    WHERE d.tag_id = ?
                        AND d.decision IN ('accepted', 'rejected')
                        AND a.locator_state = 'current'
                        AND a.availability = 'available'
                        AND s.state = 'active'
                        AND (
                            (s.kind = 'folder' AND a.locator_kind = 'file')
                            OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                        )
                )
                SELECT id, content_revision, decision
                FROM ranked
                WHERE role_rank <= 12
                ORDER BY decision ASC, role_rank ASC
                """,
                arguments: [uuid(tagID)]
            )
            var positives: [PersonalizedSuggestionScoringCore.CandidateRevision] = []
            var negatives: [PersonalizedSuggestionScoringCore.CandidateRevision] = []
            for row in rows {
                guard let assetID = UUID(uuidString: row["id"]) else { continue }
                let candidate = PersonalizedSuggestionScoringCore.CandidateRevision(
                    assetID: assetID,
                    contentRevision: row["content_revision"]
                )
                if row["decision"] as String == "accepted" {
                    positives.append(candidate)
                } else {
                    negatives.append(candidate)
                }
            }
            return (positives, negatives)
        }
    }

    func candidateRevision(tagID: UUID, assetID: UUID) throws -> PersonalizedSuggestionScoringCore.CandidateRevision? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT a.content_revision
                FROM asset a
                JOIN source s ON s.id = a.source_id
                WHERE a.id = ?
                    AND a.locator_state = 'current'
                    AND a.availability = 'available'
                    AND s.state = 'active'
                    AND (
                        (s.kind = 'folder' AND a.locator_kind = 'file')
                        OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                    )
                    AND NOT EXISTS (
                        SELECT 1 FROM asset_tag_decision d
                        WHERE d.asset_id = a.id AND d.tag_id = ?
                    )
                """,
                arguments: [uuid(assetID), uuid(tagID)]
            ) else { return nil }
            return PersonalizedSuggestionScoringCore.CandidateRevision(
                assetID: assetID,
                contentRevision: row["content_revision"]
            )
        }
    }

    func tagIsActive(_ tagID: UUID) throws -> Bool {
        try database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM tag WHERE id = ?",
                arguments: [uuid(tagID)]
            ) == TagState.active.rawValue
        }
    }

    private func uuid(_ value: UUID) -> String {
        value.uuidString.lowercased()
    }
}

enum ReviewQueueCursorCodec {
    private struct BoundaryPayload: Codable {
        let score: Double
        let assetID: UUID
    }

    struct Boundary: Sendable {
        let score: Double
        let assetID: UUID
    }

    static func encodeBoundary(score: Double, assetID: UUID) throws -> ReviewQueueCursor {
        ReviewQueueCursor(
            token: try JSONEncoder().encode(
                BoundaryPayload(score: score, assetID: assetID)
            )
        )
    }

    static func decodeBoundary(_ cursor: ReviewQueueCursor) throws -> Boundary {
        let payload = try JSONDecoder().decode(BoundaryPayload.self, from: cursor.token)
        return Boundary(score: payload.score, assetID: payload.assetID)
    }
}
