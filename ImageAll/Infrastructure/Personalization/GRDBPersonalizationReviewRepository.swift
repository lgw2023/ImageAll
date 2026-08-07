import Foundation
import GRDB

enum StandardSuggestionReplacementError: Error, Equatable {
    case identityMismatch
    case assetChanged
}

private struct MappedStandardSuggestion {
    let tagID: String
    let derivedFromConceptID: String?
    let suggestion: LocalModelSuggestion

    func precedes(_ other: MappedStandardSuggestion) -> Bool {
        let isDirect = derivedFromConceptID == nil
        let otherIsDirect = other.derivedFromConceptID == nil
        if isDirect != otherIsDirect {
            return isDirect
        }
        if suggestion.score != other.suggestion.score {
            return suggestion.score > other.suggestion.score
        }
        return (derivedFromConceptID ?? "") < (other.derivedFromConceptID ?? "")
    }
}

struct GRDBPersonalizationReviewRepository: Sendable {
    let database: CatalogDatabase

    func totalPendingSuggestionCount(sourceIDs: [UUID]? = nil) throws -> Int {
        try totalPendingSuggestionCount(mediaKind: .image, sourceIDs: sourceIDs)
    }

    func totalPendingSuggestionCount(
        mediaKind: MediaKind,
        sourceIDs: [UUID]? = nil
    ) throws -> Int {
        if let sourceIDs, sourceIDs.isEmpty { return 0 }
        var sourceClause = ""
        var sourceArguments: [DatabaseValueConvertible] = []
        if let sourceIDs {
            let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ", ")
            sourceClause = " AND a.source_id IN (\(placeholders))"
            sourceArguments = sourceIDs.map { uuid($0) }
        }
        return try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                WITH pending_pairs AS (
                    SELECT p.asset_id, p.tag_id
                    FROM prediction p
                    JOIN tag_model m
                        ON m.media_kind = p.media_kind
                        AND m.tag_id = p.tag_id
                        AND m.current_revision = p.model_revision
                    JOIN tag t ON t.id = p.tag_id AND t.state = 'active'
                    JOIN asset a
                        ON a.id = p.asset_id
                        AND a.content_revision = p.content_revision
                        AND a.locator_state = 'current'
                        AND a.availability = 'available'
                    LEFT JOIN asset_tag_decision d
                        ON d.asset_id = p.asset_id AND d.tag_id = p.tag_id
                    WHERE p.media_kind = ?
                        AND a.media_kind = ?
                        AND p.state = 'pendingReview' AND d.asset_id IS NULL\(sourceClause)
                    UNION ALL
                    SELECT p.asset_id, p.tag_id
                    FROM standard_prediction p
                    JOIN ontology_pack pack
                        ON pack.standard_pack_id = p.standard_pack_id
                        AND pack.standard_pack_revision = p.standard_pack_revision
                        AND pack.state = 'active'
                    JOIN standard_tag_binding binding
                        ON binding.tag_id = p.tag_id
                        AND binding.ontology_id = pack.ontology_id
                        AND binding.ontology_revision = pack.ontology_revision
                    JOIN tag t ON t.id = p.tag_id AND t.state = 'active'
                    JOIN asset a
                        ON a.id = p.asset_id
                        AND a.content_revision = p.content_revision
                        AND a.locator_state = 'current'
                        AND a.availability = 'available'
                    LEFT JOIN asset_tag_decision d
                        ON d.asset_id = p.asset_id AND d.tag_id = p.tag_id
                    WHERE a.media_kind = ?
                        AND p.state = 'pendingReview' AND d.asset_id IS NULL\(sourceClause)
                    UNION ALL
                    SELECT p.asset_id, p.tag_id
                    FROM personal_prediction p
                    JOIN personal_suggestion_model m
                        ON m.media_kind = p.media_kind
                        AND m.method = p.method AND m.tag_id = p.tag_id
                    JOIN personal_suggestion_tag pst
                        ON pst.media_kind = p.media_kind
                        AND pst.method = p.method AND pst.tag_id = p.tag_id
                    JOIN tag t ON t.id = p.tag_id AND t.state = 'active'
                    JOIN asset a
                        ON a.id = p.asset_id
                        AND a.content_revision = p.content_revision
                        AND a.locator_state = 'current'
                        AND a.availability = 'available'
                    LEFT JOIN asset_tag_decision d
                        ON d.asset_id = p.asset_id AND d.tag_id = p.tag_id
                    WHERE p.media_kind = ?
                        AND a.media_kind = ?
                        AND p.state = 'pendingReview' AND d.asset_id IS NULL\(sourceClause)
                )
                SELECT COUNT(*) FROM pending_pairs
                """,
                arguments: StatementArguments(
                    [mediaKind.rawValue, mediaKind.rawValue] + sourceArguments
                        + [mediaKind.rawValue] + sourceArguments
                        + [mediaKind.rawValue, mediaKind.rawValue] + sourceArguments
                )
            ) ?? 0
        }
    }

    func pendingCount(tagID: UUID, sourceIDs: [UUID]? = nil) throws -> Int {
        try pendingCounts(tagID: tagID, sourceIDs: sourceIDs).total
    }

    func pendingCounts(
        tagID: UUID,
        sourceIDs: [UUID]? = nil
    ) throws -> SuggestionOriginCounts {
        try pendingCounts(mediaKind: .image, tagID: tagID, sourceIDs: sourceIDs)
    }

    func pendingCounts(
        mediaKind: MediaKind,
        tagID: UUID,
        sourceIDs: [UUID]? = nil
    ) throws -> SuggestionOriginCounts {
        if let sourceIDs, sourceIDs.isEmpty { return .zero }
        var sourceClause = ""
        var sourceArguments: [DatabaseValueConvertible] = []
        if let sourceIDs {
            let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ", ")
            sourceClause = " AND a.source_id IN (\(placeholders))"
            sourceArguments = sourceIDs.map { uuid($0) }
        }
        return try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                WITH pending_rows AS (
                    SELECT 'featurePrint' AS suggestion_origin
                    FROM prediction p
                    JOIN tag_model m
                        ON m.media_kind = p.media_kind
                        AND m.tag_id = p.tag_id
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
                        AND p.media_kind = ?
                        AND a.media_kind = ?
                        AND p.state = 'pendingReview'
                        AND d.asset_id IS NULL\(sourceClause)
                    UNION ALL
                    SELECT 'standardModel' AS suggestion_origin
                    FROM standard_prediction p
                    JOIN ontology_pack pack
                        ON pack.standard_pack_id = p.standard_pack_id
                        AND pack.standard_pack_revision = p.standard_pack_revision
                        AND pack.state = 'active'
                    JOIN standard_tag_binding binding
                        ON binding.tag_id = p.tag_id
                        AND binding.ontology_id = pack.ontology_id
                        AND binding.ontology_revision = pack.ontology_revision
                    JOIN tag t ON t.id = p.tag_id AND t.state = 'active'
                    JOIN asset a
                        ON a.id = p.asset_id
                        AND a.content_revision = p.content_revision
                        AND a.locator_state = 'current'
                        AND a.availability = 'available'
                    LEFT JOIN asset_tag_decision d
                        ON d.asset_id = p.asset_id AND d.tag_id = p.tag_id
                    WHERE p.tag_id = ?
                        AND a.media_kind = ?
                        AND p.state = 'pendingReview'
                        AND d.asset_id IS NULL\(sourceClause)
                    UNION ALL
                    SELECT CASE
                        WHEN p.method = 'personalAdamW' THEN 'personalAdamW'
                        ELSE 'personalModel'
                    END AS suggestion_origin
                    FROM personal_prediction p
                    JOIN personal_suggestion_model m
                        ON m.media_kind = p.media_kind
                        AND m.method = p.method AND m.tag_id = p.tag_id
                    JOIN personal_suggestion_tag pst
                        ON pst.media_kind = p.media_kind
                        AND pst.method = p.method AND pst.tag_id = p.tag_id
                    JOIN tag t ON t.id = p.tag_id AND t.state = 'active'
                    JOIN asset a
                        ON a.id = p.asset_id
                        AND a.content_revision = p.content_revision
                        AND a.locator_state = 'current'
                        AND a.availability = 'available'
                    LEFT JOIN asset_tag_decision d
                        ON d.asset_id = p.asset_id AND d.tag_id = p.tag_id
                    WHERE p.tag_id = ?
                        AND p.media_kind = ?
                        AND a.media_kind = ?
                        AND p.state = 'pendingReview'
                        AND d.asset_id IS NULL\(sourceClause)
                )
                SELECT
                    COALESCE(SUM(CASE WHEN suggestion_origin = 'featurePrint' THEN 1 ELSE 0 END), 0)
                        AS feature_print_count,
                    COALESCE(SUM(CASE WHEN suggestion_origin = 'standardModel' THEN 1 ELSE 0 END), 0)
                        AS standard_model_count,
                    COALESCE(SUM(CASE WHEN suggestion_origin = 'personalModel' THEN 1 ELSE 0 END), 0)
                        AS personal_model_count,
                    COALESCE(SUM(CASE WHEN suggestion_origin = 'personalAdamW' THEN 1 ELSE 0 END), 0)
                        AS personal_adamw_count
                FROM pending_rows
                """,
                arguments: StatementArguments(
                    [uuid(tagID), mediaKind.rawValue, mediaKind.rawValue] + sourceArguments
                        + [uuid(tagID), mediaKind.rawValue] + sourceArguments
                        + [uuid(tagID), mediaKind.rawValue, mediaKind.rawValue] + sourceArguments
                )
            ) else {
                return .zero
            }
            return SuggestionOriginCounts(
                featurePrint: row["feature_print_count"],
                standardModel: row["standard_model_count"],
                personalModel: row["personal_model_count"],
                personalAdamW: row["personal_adamw_count"]
            )
        }
    }

    func sampleCounts(tagID: UUID) throws -> (accepted: Int, rejected: Int) {
        try sampleCounts(mediaKind: .image, tagID: tagID)
    }

    func sampleCounts(
        mediaKind: MediaKind,
        tagID: UUID
    ) throws -> (accepted: Int, rejected: Int) {
        try database.pool.read { db in
            let accepted = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM asset_tag_decision d
                JOIN asset a ON a.id = d.asset_id
                JOIN source s ON s.id = a.source_id
                WHERE d.tag_id = ? AND d.decision = 'accepted'
                    AND a.media_kind = ?
                    AND a.locator_state = 'current'
                    AND a.availability = 'available'
                    AND s.state = 'active'
                    AND (
                        (s.kind = 'folder' AND a.locator_kind = 'file')
                        OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                    )
                """,
                arguments: [uuid(tagID), mediaKind.rawValue]
            ) ?? 0
            let rejected = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM asset_tag_decision d
                JOIN asset a ON a.id = d.asset_id
                JOIN source s ON s.id = a.source_id
                WHERE d.tag_id = ? AND d.decision = 'rejected'
                    AND a.media_kind = ?
                    AND a.locator_state = 'current'
                    AND a.availability = 'available'
                    AND s.state = 'active'
                    AND (
                        (s.kind = 'folder' AND a.locator_kind = 'file')
                        OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                    )
                """,
                arguments: [uuid(tagID), mediaKind.rawValue]
            ) ?? 0
            return (accepted, rejected)
        }
    }

    func tagHasCurrentModel(tagID: UUID) throws -> Bool {
        try tagHasCurrentModel(mediaKind: .image, tagID: tagID)
    }

    func tagHasCurrentModel(mediaKind: MediaKind, tagID: UUID) throws -> Bool {
        try database.pool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1 FROM tag_model
                    WHERE media_kind = ? AND tag_id = ?
                )
                """,
                arguments: [mediaKind.rawValue, uuid(tagID)]
            ) ?? false
        }
    }

    func tagIsStandard(tagID: UUID) throws -> Bool {
        try database.pool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM standard_tag_binding WHERE tag_id = ?)",
                arguments: [uuid(tagID)]
            ) ?? false
        }
    }

    func fetchFrozenSampleIdentities(tagID: UUID) throws -> (
        positives: [FrozenSampleIdentity],
        negatives: [FrozenSampleIdentity]
    ) {
        try fetchFrozenSampleIdentities(mediaKind: .image, tagID: tagID)
    }

    func fetchFrozenSampleIdentities(
        mediaKind: MediaKind,
        tagID: UUID
    ) throws -> (
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
                        AND a.media_kind = ?
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
                arguments: [uuid(tagID), mediaKind.rawValue]
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
        try personalTrainingSnapshot(
            mediaKind: .image,
            limitingToTagIDs: nil,
            limitingToAssetIDs: nil
        )
    }

    func personalTrainingSnapshot(limitingToAssetIDs assetIDs: Set<UUID>) throws -> PersonalTrainingSnapshot {
        try personalTrainingSnapshot(
            mediaKind: .image,
            limitingToTagIDs: nil,
            limitingToAssetIDs: Optional(assetIDs)
        )
    }

    func personalTrainingSnapshot(
        limitingToTagIDs tagIDs: Set<UUID>,
        limitingToAssetIDs assetIDs: Set<UUID>?
    ) throws -> PersonalTrainingSnapshot {
        try personalTrainingSnapshot(
            mediaKind: .image,
            limitingToTagIDs: Optional(tagIDs),
            limitingToAssetIDs: assetIDs
        )
    }

    func personalTrainingSnapshot(
        mediaKind: MediaKind,
        limitingToTagIDs tagIDs: Set<UUID>,
        limitingToAssetIDs assetIDs: Set<UUID>?
    ) throws -> PersonalTrainingSnapshot {
        try personalTrainingSnapshot(
            mediaKind: mediaKind,
            limitingToTagIDs: Optional(tagIDs),
            limitingToAssetIDs: assetIDs
        )
    }

    private func personalTrainingSnapshot(
        mediaKind: MediaKind,
        limitingToTagIDs tagIDs: Set<UUID>?,
        limitingToAssetIDs assetIDs: Set<UUID>?
    ) throws -> PersonalTrainingSnapshot {
        let catalogScopeID = try database.catalogScopeID()
        if let tagIDs, tagIDs.isEmpty {
            return PersonalTrainingSnapshot(
                catalogScopeID: catalogScopeID,
                mediaKind: mediaKind,
                personalTagIDs: [],
                decisions: []
            )
        }
        if let assetIDs, assetIDs.isEmpty {
            return PersonalTrainingSnapshot(
                catalogScopeID: catalogScopeID,
                mediaKind: mediaKind,
                personalTagIDs: [],
                decisions: []
            )
        }
        let tagIDValues = tagIDs.map { Array($0).map(\.uuidString) }
        let assetIDValues = assetIDs.map { Array($0).map(\.uuidString) }
        return try database.pool.read { db in
            var sql = """
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
                        AND a.media_kind = ?
                        AND d.decision IN ('accepted', 'rejected')
                        AND a.locator_state = 'current'
                        AND a.availability = 'available'
                        AND s.state = 'active'
                        AND (
                            (s.kind = 'folder' AND a.locator_kind = 'file')
                            OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                        )
                """
            var arguments: StatementArguments = [mediaKind.rawValue]
            if let tagIDValues {
                let placeholders = Array(repeating: "?", count: tagIDValues.count).joined(separator: ", ")
                sql += "\n                        AND d.tag_id IN (\(placeholders))"
                for value in tagIDValues.sorted() {
                    arguments += [value.lowercased()]
                }
            }
            if let assetIDValues {
                let placeholders = Array(repeating: "?", count: assetIDValues.count).joined(separator: ", ")
                sql += "\n                        AND d.asset_id IN (\(placeholders))"
                for value in assetIDValues.sorted() {
                    arguments += [value.lowercased()]
                }
            }
            sql += """

                ),
                trainable_tags AS (
                    SELECT tag_id
                    FROM eligible_decisions
                    GROUP BY tag_id
                    HAVING SUM(CASE WHEN decision = 'accepted' THEN 1 ELSE 0 END) >= 2
                )
                SELECT
                    asset_id,
                    content_revision,
                    tag_id,
                    decision
                FROM eligible_decisions
                WHERE tag_id IN (SELECT tag_id FROM trainable_tags)
                    AND decision = 'accepted'
                ORDER BY tag_id ASC, updated_at_ms DESC, asset_id ASC
                """
            // Full-catalog, tag-scoped, and selection-scoped rebuild all use every eligible accepted sample.
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
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
            let resolvedTagIDs = Array(Set(decisions.map(\.tagID))).sorted {
                $0.uuidString < $1.uuidString
            }
            return PersonalTrainingSnapshot(
                catalogScopeID: catalogScopeID,
                mediaKind: mediaKind,
                personalTagIDs: resolvedTagIDs,
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
        try frozenAssetProcessingContext(
            mediaKind: .image,
            tagID: tagID,
            assetID: assetID
        )
    }

    func frozenAssetProcessingContext(
        mediaKind: MediaKind,
        tagID: UUID,
        assetID: UUID
    ) throws -> FrozenAssetProcessingContext? {
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
                    AND a.media_kind = ?
                    AND a.locator_state = 'current'
                    AND (
                        (s.kind = 'folder' AND a.locator_kind = 'file')
                        OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                    )
                """,
                arguments: [uuid(tagID), uuid(assetID), mediaKind.rawValue]
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

    func frozenStandardAssetProcessingContext(assetID: UUID) throws -> FrozenAssetProcessingContext? {
        try frozenStandardAssetProcessingContext(
            mediaKind: .image,
            assetID: assetID
        )
    }

    func frozenStandardAssetProcessingContext(
        mediaKind: MediaKind,
        assetID: UUID
    ) throws -> FrozenAssetProcessingContext? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT a.content_revision, a.availability, a.locator_state, a.record_updated_at_ms,
                    s.state AS source_state
                FROM asset a
                JOIN source s ON s.id = a.source_id
                WHERE a.id = ?
                    AND a.media_kind = ?
                    AND a.locator_state = 'current'
                    AND (
                        (s.kind = 'folder' AND a.locator_kind = 'file')
                        OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                    )
                """,
                arguments: [uuid(assetID), mediaKind.rawValue]
            ) else { return nil }
            return FrozenAssetProcessingContext(
                contentRevision: row["content_revision"],
                availability: row["availability"],
                sourceState: row["source_state"],
                locatorState: row["locator_state"],
                recordUpdatedAtMs: row["record_updated_at_ms"],
                hasDecision: false
            )
        }
    }

    func standardSuggestionTargetMatches(_ target: StandardModelSuggestionTarget) throws -> Bool {
        try database.pool.read { db in
            try standardSuggestionTargetMatches(target, in: db)
        }
    }

    func standardSuggestionTargetMatches(
        _ target: StandardModelSuggestionTarget,
        in db: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1
                FROM ontology_pack p
                JOIN standard_model_revision m
                    ON m.standard_pack_id = p.standard_pack_id
                    AND m.standard_pack_revision = p.standard_pack_revision
                WHERE p.standard_pack_id = ?
                    AND p.standard_pack_revision = ?
                    AND p.state = 'active'
            )
            """,
            arguments: [target.standardPackID, target.standardPackRevision]
        ) == true
    }

    func activePersonalizationSourceIDs() throws -> [UUID] {
        try database.pool.read { db in
            try activePersonalizationSourceIDs(in: db)
        }
    }

    func activePersonalizationSourceIDs(in db: Database) throws -> [UUID] {
        try String.fetchAll(
            db,
            sql: """
            SELECT id FROM source
            WHERE kind IN ('folder', 'photos') AND state = 'active'
            ORDER BY id ASC
            """
        ).compactMap(UUID.init(uuidString:))
    }

    func frozenAssetBatch(
        mediaKind: MediaKind = .image,
        sourceIDs: [UUID],
        catalogCutoffMs: Int64,
        afterAssetID: UUID?,
        limit: Int,
        excludingDecisionsForTagID: UUID? = nil
    ) throws -> [UUID] {
        guard !sourceIDs.isEmpty, limit > 0 else { return [] }
        let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ", ")
        var arguments: [DatabaseValueConvertible] = sourceIDs.map { uuid($0) }
        arguments.append(mediaKind.rawValue)
        arguments.append(catalogCutoffMs)
        var decisionClause = ""
        if let excludingDecisionsForTagID {
            decisionClause = """
                AND NOT EXISTS (
                    SELECT 1 FROM asset_tag_decision d
                    WHERE d.asset_id = a.id AND d.tag_id = ?
                )
                """
            arguments.append(uuid(excludingDecisionsForTagID))
        }
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
                    AND a.media_kind = ?
                    AND (
                        (s.kind = 'folder' AND a.locator_kind = 'file')
                        OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                    )
                    AND a.record_created_at_ms <= ?
                    \(decisionClause)
                    \(afterClause)
                ORDER BY a.id ASC
                LIMIT ?
                """,
                arguments: StatementArguments(arguments)
            ).compactMap(UUID.init(uuidString:))
        }
    }

    func frozenAssetTotal(
        mediaKind: MediaKind = .image,
        sourceIDs: [UUID],
        catalogCutoffMs: Int64,
        excludingDecisionsForTagID: UUID? = nil
    ) throws -> Int {
        guard !sourceIDs.isEmpty else { return 0 }
        let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ", ")
        var arguments: [DatabaseValueConvertible] = sourceIDs.map { uuid($0) }
        arguments.append(mediaKind.rawValue)
        arguments.append(catalogCutoffMs)
        var decisionClause = ""
        if let excludingDecisionsForTagID {
            decisionClause = """
                AND NOT EXISTS (
                    SELECT 1 FROM asset_tag_decision d
                    WHERE d.asset_id = a.id AND d.tag_id = ?
                )
                """
            arguments.append(uuid(excludingDecisionsForTagID))
        }
        return try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM asset a
                JOIN source s ON s.id = a.source_id
                WHERE s.id IN (\(placeholders))
                    AND a.media_kind = ?
                    AND (
                        (s.kind = 'folder' AND a.locator_kind = 'file')
                        OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                    )
                    AND a.record_created_at_ms <= ?
                    \(decisionClause)
                """,
                arguments: StatementArguments(arguments)
            ) ?? 0
        }
    }

    func personalSuggestionCandidates(
        afterAssetID: UUID?,
        limit: Int,
        sourceIDs: [UUID]? = nil,
        excludingDecisionsForTagID: UUID? = nil
    ) throws -> [PersonalSuggestionCandidate] {
        try personalSuggestionCandidates(
            mediaKind: .image,
            afterAssetID: afterAssetID,
            limit: limit,
            sourceIDs: sourceIDs,
            excludingDecisionsForTagID: excludingDecisionsForTagID
        )
    }

    func personalSuggestionCandidates(
        mediaKind: MediaKind,
        afterAssetID: UUID?,
        limit: Int,
        sourceIDs: [UUID]? = nil,
        excludingDecisionsForTagID: UUID? = nil
    ) throws -> [PersonalSuggestionCandidate] {
        guard limit > 0 else { return [] }
        if let sourceIDs, sourceIDs.isEmpty { return [] }
        var sql = """
        SELECT a.id, a.content_revision
        FROM asset a
        JOIN source s ON s.id = a.source_id AND s.state = 'active'
        WHERE a.locator_state = 'current'
            AND a.availability = 'available'
            AND a.media_kind = ?
            AND (
                (s.kind = 'folder' AND a.locator_kind = 'file')
                OR (s.kind = 'photos' AND a.locator_kind = 'photos')
            )
        """
        var arguments: [DatabaseValueConvertible] = [mediaKind.rawValue]
        if let sourceIDs {
            let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ", ")
            sql += " AND a.source_id IN (\(placeholders))"
            arguments.append(contentsOf: sourceIDs.map { uuid($0) })
        }
        if let excludingDecisionsForTagID {
            sql += """
             AND NOT EXISTS (
                SELECT 1 FROM asset_tag_decision d
                WHERE d.asset_id = a.id AND d.tag_id = ?
            )
            """
            arguments.append(uuid(excludingDecisionsForTagID))
        }
        if let afterAssetID {
            sql += " AND a.id > ?"
            arguments.append(uuid(afterAssetID))
        }
        sql += " ORDER BY a.id ASC LIMIT ?"
        arguments.append(limit)
        return try database.pool.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).compactMap { row in
                guard let assetID = UUID(uuidString: row["id"]) else { return nil }
                return PersonalSuggestionCandidate(
                    assetID: assetID,
                    contentRevision: row["content_revision"]
                )
            }
        }
    }

    func activatePersonalSuggestionBundle(
        _ capability: PersonalModelSuggestionCapability,
        activatedAtMs: Int64,
        publishedRunID: UUID? = nil
    ) throws {
        try database.pool.write { db in
            try activatePersonalSuggestionBundle(
                capability,
                activatedAtMs: activatedAtMs,
                publishedRunID: publishedRunID,
                on: db
            )
        }
    }

    func activatePersonalSuggestionBundle(
        _ capability: PersonalModelSuggestionCapability,
        activatedAtMs: Int64,
        publishedRunID: UUID? = nil,
        on db: Database
    ) throws {
        let target = capability.target
        guard activatedAtMs >= 0,
              capability.tagIDs.count == 1,
              let tagID = capability.tagIDs.first,
              target.elementCount > 0,
              isLowercaseSHA256(target.labelVocabularyRevision),
              isLowercaseSHA256(target.weightsSHA256)
        else {
            throw PersonalizationReviewError.persistenceFailure
        }
        guard let method = PersonalSuggestionMethod(bundleID: target.bundleID)?.rawValue else {
            throw PersonalizationReviewError.persistenceFailure
        }
        let tagKey = uuid(tagID)
        if try personalCapabilityMatches(capability, in: db) {
            if let publishedRunID {
                try db.execute(
                    sql: """
                    UPDATE personal_suggestion_model
                    SET published_run_id = ?, activated_at_ms = ?
                    WHERE media_kind = ? AND method = ? AND tag_id = ?
                    """,
                    arguments: [
                        publishedRunID.uuidString.lowercased(),
                        activatedAtMs,
                        target.mediaKind.rawValue,
                        method,
                        tagKey,
                    ]
                )
                guard db.changesCount == 1 else {
                    throw PersonalizationReviewError.persistenceFailure
                }
            }
            return
        }
        try db.execute(
            sql: """
            DELETE FROM personal_prediction
            WHERE media_kind = ? AND method = ? AND tag_id = ?
            """,
            arguments: [target.mediaKind.rawValue, method, tagKey]
        )
        try db.execute(
            sql: """
            DELETE FROM personal_suggestion_tag
            WHERE media_kind = ? AND method = ? AND tag_id = ?
            """,
            arguments: [target.mediaKind.rawValue, method, tagKey]
        )
        try db.execute(
            sql: """
            DELETE FROM personal_suggestion_model
            WHERE media_kind = ? AND method = ? AND tag_id = ?
            """,
            arguments: [target.mediaKind.rawValue, method, tagKey]
        )
        try db.execute(
            sql: """
            INSERT INTO personal_suggestion_model (
                media_kind, method, tag_id, catalog_scope_id, bundle_id, bundle_revision, provider, model_id,
                model_revision, preprocessing_revision, element_count,
                label_vocabulary_revision, weights_sha256, policy_revision, activated_at_ms,
                published_run_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                target.mediaKind.rawValue, method, tagKey,
                target.catalogScopeID, target.bundleID, target.bundleRevision,
                target.provider, target.modelID, target.modelRevision,
                target.preprocessingRevision, target.elementCount,
                target.labelVocabularyRevision, target.weightsSHA256, target.policyRevision,
                activatedAtMs, publishedRunID?.uuidString.lowercased(),
            ]
        )
        try db.execute(
            sql: """
            INSERT INTO personal_suggestion_tag (media_kind, method, tag_id)
            SELECT ?, ?, id FROM tag WHERE id = ? AND state = 'active'
            """,
            arguments: [target.mediaKind.rawValue, method, tagKey]
        )
        guard db.changesCount == 1 else {
            throw PersonalizationReviewError.persistenceFailure
        }
    }

    func publishedRunID(method: PersonalSuggestionMethod, tagID: UUID) throws -> UUID? {
        try publishedRunID(mediaKind: .image, method: method, tagID: tagID)
    }

    func publishedRunID(
        mediaKind: MediaKind,
        method: PersonalSuggestionMethod,
        tagID: UUID
    ) throws -> UUID? {
        try database.pool.read { db in
            guard let raw = try String.fetchOne(
                db,
                sql: """
                SELECT published_run_id
                FROM personal_suggestion_model
                WHERE media_kind = ? AND method = ? AND tag_id = ?
                """,
                arguments: [mediaKind.rawValue, method.rawValue, uuid(tagID)]
            ) else {
                return nil
            }
            return UUID(uuidString: raw)
        }
    }

    func publishedRunID(method: PersonalSuggestionMethod) throws -> UUID? {
        try publishedRunID(mediaKind: .image, method: method)
    }

    func publishedRunID(
        mediaKind: MediaKind,
        method: PersonalSuggestionMethod
    ) throws -> UUID? {
        try database.pool.read { db in
            guard let raw = try String.fetchOne(
                db,
                sql: """
                SELECT published_run_id
                FROM personal_suggestion_model
                WHERE media_kind = ? AND method = ?
                    AND published_run_id IS NOT NULL
                ORDER BY activated_at_ms DESC, tag_id ASC
                LIMIT 1
                """,
                arguments: [mediaKind.rawValue, method.rawValue]
            ) else {
                return nil
            }
            return UUID(uuidString: raw)
        }
    }

    func publishedArtifactSHA256(method: PersonalSuggestionMethod, tagID: UUID) throws -> String? {
        try publishedArtifactSHA256(mediaKind: .image, method: method, tagID: tagID)
    }

    func publishedArtifactSHA256(
        mediaKind: MediaKind,
        method: PersonalSuggestionMethod,
        tagID: UUID
    ) throws -> String? {
        try database.pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT r.artifact_sha256
                FROM personal_suggestion_model m
                JOIN training_run r ON r.id = m.published_run_id
                WHERE m.media_kind = ?
                    AND m.method = ?
                    AND m.tag_id = ?
                    AND r.method = ?
                    AND r.media_kind = ?
                    AND r.state = 'succeeded'
                """,
                arguments: [
                    mediaKind.rawValue,
                    method.rawValue,
                    uuid(tagID),
                    method.rawValue,
                    mediaKind.rawValue,
                ]
            )
        }
    }

    func publishedArtifactSHA256s(method: PersonalSuggestionMethod) throws -> [UUID: String] {
        try publishedArtifactSHA256s(mediaKind: .image, method: method)
    }

    func publishedArtifactSHA256s(
        mediaKind: MediaKind,
        method: PersonalSuggestionMethod
    ) throws -> [UUID: String] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT m.tag_id, r.artifact_sha256
                FROM personal_suggestion_model m
                JOIN training_run r ON r.id = m.published_run_id
                WHERE m.media_kind = ?
                    AND m.method = ?
                    AND r.method = ?
                    AND r.media_kind = ?
                    AND r.state = 'succeeded'
                    AND r.artifact_sha256 IS NOT NULL
                ORDER BY m.tag_id
                """,
                arguments: [
                    mediaKind.rawValue,
                    method.rawValue,
                    method.rawValue,
                    mediaKind.rawValue,
                ]
            )
            var result: [UUID: String] = [:]
            for row in rows {
                guard let tagID = UUID(uuidString: row["tag_id"]),
                      let sha: String = row["artifact_sha256"]
                else { continue }
                result[tagID] = sha
            }
            return result
        }
    }

    func publishedArtifactSHA256(method: PersonalSuggestionMethod) throws -> String? {
        let all = try publishedArtifactSHA256s(mediaKind: .image, method: method)
        guard all.count == 1, let only = all.values.first else { return nil }
        return only
    }

    func usesLegacyActivePointer(method: PersonalSuggestionMethod) throws -> Bool {
        try usesLegacyActivePointer(mediaKind: .image, method: method)
    }

    func usesLegacyActivePointer(
        mediaKind: MediaKind,
        method: PersonalSuggestionMethod
    ) throws -> Bool {
        try database.pool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1 FROM personal_suggestion_model
                    WHERE media_kind = ? AND method = ? AND published_run_id IS NULL
                )
                """,
                arguments: [mediaKind.rawValue, method.rawValue]
            ) == true
        }
    }

    func usesLegacyActivePointer(method: PersonalSuggestionMethod, tagID: UUID) throws -> Bool {
        try usesLegacyActivePointer(
            mediaKind: .image,
            method: method,
            tagID: tagID
        )
    }

    func usesLegacyActivePointer(
        mediaKind: MediaKind,
        method: PersonalSuggestionMethod,
        tagID: UUID
    ) throws -> Bool {
        try database.pool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1 FROM personal_suggestion_model
                    WHERE media_kind = ?
                        AND method = ? AND tag_id = ? AND published_run_id IS NULL
                )
                """,
                arguments: [mediaKind.rawValue, method.rawValue, uuid(tagID)]
            ) == true
        }
    }

    func replacePersonalSuggestions(
        candidate: PersonalSuggestionCandidate,
        predictions: [PersonalSuggestionPrediction],
        expectedCapability: PersonalModelSuggestionCapability,
        createdAtMs: Int64
    ) throws -> Int {
        guard candidate.contentRevision > 0,
              createdAtMs >= 0,
              Set(predictions.map(\.tagID)).count == predictions.count,
              predictions.allSatisfy({ $0.score.isFinite })
        else {
            throw PersonalizationReviewError.persistenceFailure
        }
        return try database.pool.write { db in
            try replacePersonalSuggestions(
                candidate: candidate,
                predictions: predictions,
                expectedCapability: expectedCapability,
                createdAtMs: createdAtMs,
                on: db
            )
        }
    }

    func replacePersonalSuggestions(
        candidate: PersonalSuggestionCandidate,
        predictions: [PersonalSuggestionPrediction],
        expectedCapability: PersonalModelSuggestionCapability,
        createdAtMs: Int64,
        on db: Database
    ) throws -> Int {
        guard candidate.contentRevision > 0,
              createdAtMs >= 0,
              Set(predictions.map(\.tagID)).count == predictions.count,
              predictions.allSatisfy({ $0.score.isFinite })
        else {
            throw PersonalizationReviewError.persistenceFailure
        }
        guard try personalCapabilityMatches(expectedCapability, in: db),
              try Bool.fetchOne(
                  db,
                  sql: """
                  SELECT EXISTS(
                      SELECT 1
                      FROM asset a
                      JOIN source s ON s.id = a.source_id AND s.state = 'active'
                      WHERE a.id = ?
                          AND a.media_kind = ?
                          AND a.content_revision = ?
                          AND a.locator_state = 'current'
                          AND a.availability = 'available'
                          AND (
                              (s.kind = 'folder' AND a.locator_kind = 'file')
                              OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                          )
                  )
                  """,
                  arguments: [
                      uuid(candidate.assetID),
                      expectedCapability.target.mediaKind.rawValue,
                      candidate.contentRevision,
                  ]
              ) == true
        else {
            throw PersonalizationReviewError.persistenceFailure
        }
        guard let method = PersonalSuggestionMethod(
            bundleID: expectedCapability.target.bundleID
        )?.rawValue else {
            throw PersonalizationReviewError.persistenceFailure
        }
        for tagID in expectedCapability.tagIDs {
            try db.execute(
                sql: """
                DELETE FROM personal_prediction
                WHERE media_kind = ?
                    AND asset_id = ? AND method = ? AND tag_id = ?
                """,
                arguments: [
                    expectedCapability.target.mediaKind.rawValue,
                    uuid(candidate.assetID),
                    method,
                    uuid(tagID),
                ]
            )
        }
        var inserted = 0
        for prediction in predictions {
            guard expectedCapability.tagIDs.contains(prediction.tagID) else {
                throw PersonalizationReviewError.persistenceFailure
            }
            try db.execute(
                sql: """
                INSERT INTO personal_prediction (
                    media_kind, method, asset_id, tag_id,
                    content_revision, score, state, created_at_ms
                )
                SELECT ?, ?, ?, pst.tag_id, ?, ?, 'pendingReview', ?
                FROM personal_suggestion_tag pst
                JOIN tag t ON t.id = pst.tag_id AND t.state = 'active'
                WHERE pst.media_kind = ?
                    AND pst.method = ?
                    AND pst.tag_id = ?
                    AND NOT EXISTS (
                        SELECT 1 FROM asset_tag_decision d
                        WHERE d.asset_id = ? AND d.tag_id = pst.tag_id
                    )
                """,
                arguments: [
                    expectedCapability.target.mediaKind.rawValue,
                    method,
                    uuid(candidate.assetID),
                    candidate.contentRevision,
                    prediction.score,
                    createdAtMs,
                    expectedCapability.target.mediaKind.rawValue,
                    method,
                    uuid(prediction.tagID),
                    uuid(candidate.assetID),
                ]
            )
            inserted += db.changesCount
        }
        return inserted
    }

    func replacePersonalTagLibrarySuggestions(
        tagID: UUID,
        hits: [AppPersonalTagLibrarySuggestionHit],
        expectedCapability: PersonalModelSuggestionCapability,
        maximumPendingCount: Int,
        createdAtMs: Int64
    ) throws -> Int {
        try database.pool.write { db in
            try replacePersonalTagLibrarySuggestions(
                tagID: tagID,
                hits: hits,
                expectedCapability: expectedCapability,
                maximumPendingCount: maximumPendingCount,
                createdAtMs: createdAtMs,
                on: db
            )
        }
    }

    func replacePersonalTagLibrarySuggestions(
        tagID: UUID,
        hits: [AppPersonalTagLibrarySuggestionHit],
        expectedCapability: PersonalModelSuggestionCapability,
        maximumPendingCount: Int,
        createdAtMs: Int64,
        on db: Database
    ) throws -> Int {
        guard createdAtMs >= 0,
              maximumPendingCount > 0,
              expectedCapability.tagIDs.contains(tagID),
              Set(hits.map(\.candidate.assetID)).count == hits.count,
              hits.allSatisfy({
                  $0.candidate.contentRevision > 0 && $0.score.isFinite
              })
        else {
            throw PersonalizationReviewError.persistenceFailure
        }
        let rankedHits = hits.sorted {
            if $0.score == $1.score {
                return $0.candidate.assetID.uuidString.lowercased()
                    < $1.candidate.assetID.uuidString.lowercased()
            }
            return $0.score > $1.score
        }
        guard try personalCapabilityMatches(expectedCapability, in: db) else {
                throw PersonalizationReviewError.persistenceFailure
        }
        guard let method = PersonalSuggestionMethod(
            bundleID: expectedCapability.target.bundleID
        )?.rawValue else {
            throw PersonalizationReviewError.persistenceFailure
        }
        guard try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1 FROM personal_suggestion_model psm
                    JOIN personal_suggestion_tag pst
                        ON pst.media_kind = psm.media_kind
                        AND pst.method = psm.method AND pst.tag_id = psm.tag_id
                    JOIN tag t ON t.id = pst.tag_id AND t.state = 'active'
                    WHERE psm.media_kind = ?
                        AND psm.method = ? AND psm.tag_id = ?
                )
                """,
                arguments: [
                    expectedCapability.target.mediaKind.rawValue,
                    method,
                    uuid(tagID),
                ]
        ) == true else {
            throw PersonalizationReviewError.persistenceFailure
        }

        try db.execute(
                sql: """
                DELETE FROM personal_prediction
                WHERE media_kind = ? AND tag_id = ? AND method = ?
                """,
                arguments: [
                    expectedCapability.target.mediaKind.rawValue,
                    uuid(tagID),
                    method,
                ]
            )

            // Ranked hits may still include decided assets from callers that did not
            // pre-filter; never let them consume Top-N slots.
        var inserted = 0
        for hit in rankedHits {
            if inserted >= maximumPendingCount { break }
            let alreadyDecided = try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM asset_tag_decision
                        WHERE asset_id = ? AND tag_id = ?
                    )
                    """,
                    arguments: [uuid(hit.candidate.assetID), uuid(tagID)]
            ) ?? false
            if alreadyDecided { continue }
            let assetOK = try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(
                        SELECT 1
                        FROM asset a
                        JOIN source s ON s.id = a.source_id AND s.state = 'active'
                        WHERE a.id = ?
                            AND a.media_kind = ?
                            AND a.content_revision = ?
                            AND a.locator_state = 'current'
                            AND a.availability = 'available'
                            AND (
                                (s.kind = 'folder' AND a.locator_kind = 'file')
                                OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                            )
                    )
                    """,
                    arguments: [
                        uuid(hit.candidate.assetID),
                        expectedCapability.target.mediaKind.rawValue,
                        hit.candidate.contentRevision,
                    ]
            ) ?? false
            guard assetOK else { continue }
            try db.execute(
                    sql: """
                    INSERT INTO personal_prediction (
                        media_kind, method, asset_id, tag_id,
                        content_revision, score, state, created_at_ms
                    )
                    SELECT ?, ?, ?, pst.tag_id, ?, ?, 'pendingReview', ?
                    FROM personal_suggestion_tag pst
                    WHERE pst.media_kind = ?
                        AND pst.method = ?
                        AND pst.tag_id = ?
                        AND NOT EXISTS (
                            SELECT 1 FROM asset_tag_decision d
                            WHERE d.asset_id = ? AND d.tag_id = pst.tag_id
                        )
                    """,
                    arguments: [
                        expectedCapability.target.mediaKind.rawValue,
                        method,
                        uuid(hit.candidate.assetID),
                        hit.candidate.contentRevision,
                        hit.score,
                        createdAtMs,
                        expectedCapability.target.mediaKind.rawValue,
                        method,
                        uuid(tagID),
                        uuid(hit.candidate.assetID),
                    ]
            )
            inserted += db.changesCount
        }
        return inserted
    }

    func replaceStandardSuggestions(
        assetID: UUID,
        contentRevision: Int,
        suggestions: [LocalModelSuggestion],
        expectedTarget: StandardModelSuggestionTarget,
        createdAtMs: Int64
    ) throws -> Int {
        do {
            return try database.pool.write { db in
                try replaceStandardSuggestions(
                    assetID: assetID,
                    contentRevision: contentRevision,
                    suggestions: suggestions,
                    expectedTarget: expectedTarget,
                    createdAtMs: createdAtMs,
                    on: db
                )
            }
        } catch is StandardSuggestionReplacementError {
            throw PersonalizationReviewError.persistenceFailure
        }
    }

    func replaceStandardSuggestions(
        assetID: UUID,
        contentRevision: Int,
        suggestions: [LocalModelSuggestion],
        expectedTarget: StandardModelSuggestionTarget,
        createdAtMs: Int64,
        on db: Database
    ) throws -> Int {
        guard contentRevision > 0, createdAtMs >= 0 else {
            throw StandardSuggestionReplacementError.assetChanged
        }
        guard !expectedTarget.standardPackID.isEmpty,
              !expectedTarget.standardPackRevision.isEmpty,
              suggestions.allSatisfy({ $0.score.isFinite }),
              Set(suggestions.compactMap(\.conceptID)).count == suggestions.count
        else {
            throw StandardSuggestionReplacementError.identityMismatch
        }

        guard try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1
                FROM ontology_pack p
                JOIN standard_model_revision m
                    ON m.standard_pack_id = p.standard_pack_id
                    AND m.standard_pack_revision = p.standard_pack_revision
                WHERE p.standard_pack_id = ?
                    AND p.standard_pack_revision = ?
                    AND p.state = 'active'
            )
            """,
            arguments: [
                expectedTarget.standardPackID,
                expectedTarget.standardPackRevision,
            ]
        ) == true
        else {
            throw StandardSuggestionReplacementError.identityMismatch
        }
        guard try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1
                FROM asset a
                JOIN source s ON s.id = a.source_id AND s.state = 'active'
                WHERE a.id = ?
                    AND a.content_revision = ?
                    AND a.locator_state = 'current'
                    AND a.availability = 'available'
                    AND (
                        (s.kind = 'folder' AND a.locator_kind = 'file')
                        OR (s.kind = 'photos' AND a.locator_kind = 'photos')
                    )
            )
            """,
            arguments: [uuid(assetID), contentRevision]
        ) == true
        else {
            throw StandardSuggestionReplacementError.assetChanged
        }

        var mappedByTagID: [String: MappedStandardSuggestion] = [:]
        for suggestion in suggestions {
            guard suggestion.track == .standard,
                  let conceptID = suggestion.conceptID,
                  !conceptID.isEmpty,
                  suggestion.tagID == nil,
                  suggestion.standardPackID == expectedTarget.standardPackID,
                  suggestion.standardPackRevision == expectedTarget.standardPackRevision,
                  suggestion.catalogScopeID == nil,
                  suggestion.bundleID == nil,
                  suggestion.bundleRevision == nil,
                  suggestion.elementCount == nil,
                  suggestion.labelVocabularyRevision == nil,
                  suggestion.weightsSHA256 == nil,
                  suggestion.modelID?.isEmpty != true,
                  let ontologyID = suggestion.ontologyID,
                  let ontologyRevision = suggestion.ontologyRevision,
                  let mappingRevision = suggestion.mappingRevision,
                  !suggestion.provider.isEmpty,
                  !suggestion.modelRevision.isEmpty,
                  !suggestion.preprocessingRevision.isEmpty,
                  !ontologyID.isEmpty,
                  !ontologyRevision.isEmpty,
                  !mappingRevision.isEmpty,
                  !suggestion.policyRevision.isEmpty
            else {
                throw StandardSuggestionReplacementError.identityMismatch
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                WITH RECURSIVE concept_closure(concept_id) AS (
                    SELECT ?
                    UNION
                    SELECT edge.parent_concept_id
                    FROM ontology_edge edge
                    JOIN concept_closure closure
                        ON closure.concept_id = edge.child_concept_id
                    WHERE edge.ontology_id = ?
                        AND edge.ontology_revision = ?
                )
                SELECT binding.tag_id, closure.concept_id
                FROM ontology_pack p
                JOIN standard_model_revision m
                    ON m.standard_pack_id = p.standard_pack_id
                    AND m.standard_pack_revision = p.standard_pack_revision
                CROSS JOIN concept_closure closure
                JOIN standard_tag_binding binding
                    ON binding.ontology_id = p.ontology_id
                    AND binding.ontology_revision = p.ontology_revision
                    AND binding.concept_id = closure.concept_id
                JOIN tag t ON t.id = binding.tag_id AND t.state = 'active'
                WHERE p.standard_pack_id = ?
                    AND p.standard_pack_revision = ?
                    AND p.ontology_id = ?
                    AND p.ontology_revision = ?
                    AND p.state = 'active'
                    AND m.provider = ?
                    AND m.model_revision = ?
                    AND m.preprocessing_revision = ?
                    AND m.mapping_revision = ?
                    AND m.policy_revision = ?
                ORDER BY (closure.concept_id = ?) DESC, closure.concept_id
                """,
                arguments: [
                    conceptID,
                    ontologyID,
                    ontologyRevision,
                    expectedTarget.standardPackID,
                    expectedTarget.standardPackRevision,
                    ontologyID,
                    ontologyRevision,
                    suggestion.provider,
                    suggestion.modelRevision,
                    suggestion.preprocessingRevision,
                    mappingRevision,
                    suggestion.policyRevision,
                    conceptID,
                ]
            )
            guard rows.contains(where: { row in
                let rowConceptID: String = row["concept_id"]
                return rowConceptID == conceptID
            }) else {
                throw StandardSuggestionReplacementError.identityMismatch
            }
            for row in rows {
                let tagID: String = row["tag_id"]
                let expandedConceptID: String = row["concept_id"]
                let candidate = MappedStandardSuggestion(
                    tagID: tagID,
                    derivedFromConceptID: expandedConceptID == conceptID ? nil : conceptID,
                    suggestion: suggestion
                )
                if let existing = mappedByTagID[tagID],
                   !candidate.precedes(existing)
                {
                    continue
                }
                mappedByTagID[tagID] = candidate
            }
        }

        try db.execute(
            sql: "DELETE FROM standard_prediction WHERE asset_id = ?",
            arguments: [uuid(assetID)]
        )
        var inserted = 0
        for entry in mappedByTagID.values.sorted(by: { $0.tagID < $1.tagID }) {
            try db.execute(
                sql: """
                INSERT INTO standard_prediction (
                    asset_id, tag_id, content_revision,
                    standard_pack_id, standard_pack_revision,
                    score, recommended_state, state, created_at_ms,
                    derived_from_concept_id
                )
                SELECT ?, ?, ?, ?, ?, ?, ?, 'pendingReview', ?, ?
                WHERE NOT EXISTS (
                    SELECT 1 FROM asset_tag_decision d
                    WHERE d.asset_id = ? AND d.tag_id = ?
                )
                """,
                arguments: [
                    uuid(assetID),
                    entry.tagID,
                    contentRevision,
                    expectedTarget.standardPackID,
                    expectedTarget.standardPackRevision,
                    entry.suggestion.score,
                    entry.suggestion.recommendedState.rawValue,
                    createdAtMs,
                    entry.derivedFromConceptID,
                    uuid(assetID),
                    entry.tagID,
                ]
            )
            inserted += db.changesCount
        }
        return inserted
    }

    func invalidateAllPersonalSuggestionBundles() throws {
        try database.pool.write { db in
            try invalidateAllPersonalSuggestionBundles(on: db)
        }
    }

    func invalidateAllPersonalSuggestionBundles(on db: Database) throws {
        try db.execute(sql: "DELETE FROM personal_suggestion_model")
    }

    func invalidatePersonalSuggestionBundles(mediaKind: MediaKind) throws {
        try database.pool.write { db in
            try invalidatePersonalSuggestionBundles(mediaKind: mediaKind, on: db)
        }
    }

    func invalidatePersonalSuggestionBundles(
        mediaKind: MediaKind,
        on db: Database
    ) throws {
        try db.execute(
            sql: "DELETE FROM personal_suggestion_model WHERE media_kind = ?",
            arguments: [mediaKind.rawValue]
        )
    }

    func personalSuggestionCapabilityMatches(
        _ capability: PersonalModelSuggestionCapability
    ) throws -> Bool {
        try database.pool.read { db in
            try personalCapabilityMatches(capability, in: db)
        }
    }

    func fetchReviewQueuePage(
        tagID: UUID,
        sourceIDs: [UUID]? = nil,
        cursor: ReviewQueueCursor?,
        limit: Int
    ) throws -> ReviewQueuePage {
        try fetchReviewQueuePage(
            mediaKind: .image,
            tagID: tagID,
            sourceIDs: sourceIDs,
            cursor: cursor,
            limit: limit
        )
    }

    func fetchReviewQueuePage(
        mediaKind: MediaKind,
        tagID: UUID,
        sourceIDs: [UUID]? = nil,
        cursor: ReviewQueueCursor?,
        limit: Int
    ) throws -> ReviewQueuePage {
        if let sourceIDs, sourceIDs.isEmpty {
            return ReviewQueuePage(items: [], nextCursor: nil)
        }
        var sourceClause = ""
        var sourceArguments: [DatabaseValueConvertible] = []
        if let sourceIDs {
            let placeholders = Array(repeating: "?", count: sourceIDs.count).joined(separator: ", ")
            sourceClause = " AND a.source_id IN (\(placeholders))"
            sourceArguments = sourceIDs.map { uuid($0) }
        }
        var sql = """
        WITH raw_suggestions AS (
            SELECT p.asset_id, p.score, 1 AS origin_rank, 'featurePrint' AS suggestion_origin,
                a.file_name, a.availability
            FROM prediction p
            JOIN tag_model m
                ON m.media_kind = p.media_kind
                AND m.tag_id = p.tag_id
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
                AND p.media_kind = ?
                AND a.media_kind = ?
                AND p.state = 'pendingReview'
                AND d.asset_id IS NULL\(sourceClause)
            UNION ALL
            SELECT p.asset_id, p.score, 0 AS origin_rank, 'standardModel' AS suggestion_origin,
                a.file_name, a.availability
            FROM standard_prediction p
            JOIN ontology_pack pack
                ON pack.standard_pack_id = p.standard_pack_id
                AND pack.standard_pack_revision = p.standard_pack_revision
                AND pack.state = 'active'
            JOIN standard_tag_binding binding
                ON binding.tag_id = p.tag_id
                AND binding.ontology_id = pack.ontology_id
                AND binding.ontology_revision = pack.ontology_revision
            JOIN tag t ON t.id = p.tag_id AND t.state = 'active'
            JOIN asset a
                ON a.id = p.asset_id
                AND a.content_revision = p.content_revision
                AND a.locator_state = 'current'
                AND a.availability = 'available'
            LEFT JOIN asset_tag_decision d
                ON d.asset_id = p.asset_id AND d.tag_id = p.tag_id
            WHERE p.tag_id = ?
                AND a.media_kind = ?
                AND p.state = 'pendingReview'
                AND d.asset_id IS NULL\(sourceClause)
            UNION ALL
            SELECT p.asset_id, p.score,
                CASE
                    WHEN p.method = 'personalAdamW' THEN 3
                    ELSE 2
                END AS origin_rank,
                CASE
                    WHEN p.method = 'personalAdamW' THEN 'personalAdamW'
                    ELSE 'personalModel'
                END AS suggestion_origin,
                a.file_name, a.availability
            FROM personal_prediction p
            JOIN personal_suggestion_model m
                ON m.media_kind = p.media_kind
                AND m.method = p.method AND m.tag_id = p.tag_id
            JOIN personal_suggestion_tag pst
                ON pst.media_kind = p.media_kind
                AND pst.method = p.method AND pst.tag_id = p.tag_id
            JOIN tag t ON t.id = p.tag_id AND t.state = 'active'
            JOIN asset a
                ON a.id = p.asset_id
                AND a.content_revision = p.content_revision
                AND a.locator_state = 'current'
                AND a.availability = 'available'
            LEFT JOIN asset_tag_decision d
                ON d.asset_id = p.asset_id AND d.tag_id = p.tag_id
            WHERE p.tag_id = ?
                AND p.media_kind = ?
                AND a.media_kind = ?
                AND p.state = 'pendingReview'
                AND d.asset_id IS NULL\(sourceClause)
        )
        SELECT r.asset_id, r.score, r.origin_rank, r.suggestion_origin,
            r.file_name, r.availability,
            (
                SELECT COUNT(*) FROM asset_tag_decision d
                WHERE d.asset_id = r.asset_id AND d.decision = 'accepted'
            ) AS accepted_count,
            (
                SELECT COUNT(*) FROM asset_tag_decision d
                WHERE d.asset_id = r.asset_id AND d.decision = 'rejected'
            ) AS rejected_count
        FROM raw_suggestions r
        WHERE 1 = 1
        """
        var arguments: [DatabaseValueConvertible] =
            [uuid(tagID), mediaKind.rawValue, mediaKind.rawValue] + sourceArguments
            + [uuid(tagID), mediaKind.rawValue] + sourceArguments
            + [uuid(tagID), mediaKind.rawValue, mediaKind.rawValue] + sourceArguments
        if let cursor {
            let boundary = try ReviewQueueCursorCodec.decodeBoundary(cursor)
            sql += """
             AND (
                r.origin_rank < ?
                OR (r.origin_rank = ? AND r.score < ?)
                OR (r.origin_rank = ? AND r.score = ? AND r.asset_id > ?)
             )
            """
            arguments.append(boundary.originRank)
            arguments.append(boundary.originRank)
            arguments.append(boundary.score)
            arguments.append(boundary.originRank)
            arguments.append(boundary.score)
            arguments.append(uuid(boundary.assetID))
        }
        sql += " ORDER BY r.origin_rank DESC, r.score DESC, r.asset_id ASC LIMIT ?"
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
                    rejectedTagCount: row["rejected_count"],
                    suggestionOrigin: ReviewQueueSuggestionOrigin(
                        rawValue: row["suggestion_origin"]
                    ) ?? .featurePrint,
                    score: row["score"]
                )
            }
            let items = Array(mapped.prefix(limit))
            let nextCursor: ReviewQueueCursor?
            if rows.count > limit {
                let boundary = rows[limit - 1]
                let assetID = UUID(uuidString: boundary["asset_id"]) ?? items.last!.assetID
                nextCursor = try ReviewQueueCursorCodec.encodeBoundary(
                    originRank: boundary["origin_rank"],
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
                WITH raw_pending_tags AS (
                    SELECT p.tag_id, 1 AS origin_rank, 'featurePrint' AS suggestion_origin
                    FROM prediction p
                    JOIN tag_model m
                        ON m.media_kind = p.media_kind
                        AND m.tag_id = p.tag_id
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
                    UNION ALL
                    SELECT p.tag_id, 0 AS origin_rank, 'standardModel' AS suggestion_origin
                    FROM standard_prediction p
                    JOIN ontology_pack pack
                        ON pack.standard_pack_id = p.standard_pack_id
                        AND pack.standard_pack_revision = p.standard_pack_revision
                        AND pack.state = 'active'
                    JOIN standard_tag_binding binding
                        ON binding.tag_id = p.tag_id
                        AND binding.ontology_id = pack.ontology_id
                        AND binding.ontology_revision = pack.ontology_revision
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
                    UNION ALL
                    SELECT p.tag_id,
                        CASE
                            WHEN p.method = 'personalAdamW' THEN 3
                            ELSE 2
                        END AS origin_rank,
                        CASE
                            WHEN p.method = 'personalAdamW' THEN 'personalAdamW'
                            ELSE 'personalModel'
                        END AS suggestion_origin
                    FROM personal_prediction p
                    JOIN personal_suggestion_model m
                        ON m.media_kind = p.media_kind
                        AND m.method = p.method AND m.tag_id = p.tag_id
                    JOIN personal_suggestion_tag pst
                        ON pst.media_kind = p.media_kind
                        AND pst.method = p.method AND pst.tag_id = p.tag_id
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
                )
                SELECT p.tag_id, t.name, p.suggestion_origin
                FROM raw_pending_tags p
                JOIN tag t ON t.id = p.tag_id
                ORDER BY t.name COLLATE NOCASE ASC, p.tag_id ASC, p.origin_rank DESC
                """,
                arguments: [uuid(assetID), uuid(assetID), uuid(assetID)]
            ).compactMap { row in
                guard let tagID = UUID(uuidString: row["tag_id"]) else { return nil }
                return AssetPendingSuggestion(
                    tagID: tagID,
                    displayName: row["name"],
                    suggestionOrigin: ReviewQueueSuggestionOrigin(
                        rawValue: row["suggestion_origin"]
                    ) ?? .featurePrint
                )
            }
        }
    }

    func activeSuggestionJob(tagID: UUID) throws -> JobRecordSnapshot? {
        try activeSuggestionJob(mediaKind: .image, tagID: tagID)
    }

    func activeSuggestionJob(
        mediaKind: MediaKind,
        tagID: UUID
    ) throws -> JobRecordSnapshot? {
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
                arguments: [
                    FullLibrarySuggestionsJobFactory.coalescingKey(
                        tagID: tagID,
                        mediaKind: mediaKind
                    ),
                ]
            ) else { return nil }
            return try JobPersistenceMapping.snapshot(from: row)
        }
    }

    func latestPersonalLibrarySuggestionJob() throws -> JobRecordSnapshot? {
        try latestPersonalLibrarySuggestionJob(mediaKind: .image)
    }

    func latestPersonalLibrarySuggestionJob(
        mediaKind: MediaKind
    ) throws -> JobRecordSnapshot? {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM job
                WHERE kind = ?
                ORDER BY
                    CASE
                        WHEN state IN ('pending', 'running', 'paused', 'retryableFailed') THEN 0
                        ELSE 1
                    END ASC,
                    created_at_ms DESC,
                    id DESC
                LIMIT 100
                """,
                arguments: [PersonalLibrarySuggestionsJobFactory.kind]
            )
            for row in rows {
                let snapshot = try JobPersistenceMapping.snapshot(from: row)
                guard let payload = try? PersonalLibrarySuggestionsCodec.decodePayload(
                    snapshot.payload
                ) else { continue }
                if payload.capability.target.mediaKind == mediaKind {
                    return snapshot
                }
            }
            return nil
        }
    }

    func latestStandardLibrarySuggestionJob() throws -> JobRecordSnapshot? {
        try latestStandardLibrarySuggestionJob(mediaKind: .image)
    }

    func latestStandardLibrarySuggestionJob(
        mediaKind: MediaKind
    ) throws -> JobRecordSnapshot? {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM job
                WHERE kind = ?
                ORDER BY
                    CASE
                        WHEN state IN ('pending', 'running', 'paused', 'retryableFailed') THEN 0
                        ELSE 1
                    END ASC,
                    created_at_ms DESC,
                    id DESC
                LIMIT 100
                """,
                arguments: [StandardLibrarySuggestionsJobFactory.kind]
            )
            for row in rows {
                let snapshot = try JobPersistenceMapping.snapshot(from: row)
                guard let payload = try? StandardLibrarySuggestionsCodec.decodePayload(
                    snapshot.payload
                ) else { continue }
                if payload.mediaKind == mediaKind {
                    return snapshot
                }
            }
            return nil
        }
    }

    func nextModelRevision(tagID: UUID) throws -> Int {
        try nextModelRevision(mediaKind: .image, tagID: tagID)
    }

    func nextModelRevision(mediaKind: MediaKind, tagID: UUID) throws -> Int {
        try database.pool.read { db in
            let current: Int = try Int.fetchOne(
                db,
                sql: """
                SELECT COALESCE(MAX(revision), 0)
                FROM tag_model_revision
                WHERE media_kind = ? AND tag_id = ?
                """,
                arguments: [mediaKind.rawValue, uuid(tagID)]
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

    private func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            ("0" ... "9").contains(String($0)) || ("a" ... "f").contains(String($0))
        }
    }

    func personalCapabilityMatches(
        _ capability: PersonalModelSuggestionCapability,
        in db: Database
    ) throws -> Bool {
        let target = capability.target
        guard capability.tagIDs.count == 1,
              let tagID = capability.tagIDs.first,
              let method = PersonalSuggestionMethod(bundleID: target.bundleID)?.rawValue
        else {
            return false
        }
        return try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1
                FROM personal_suggestion_model psm
                JOIN personal_suggestion_tag pst
                    ON pst.media_kind = psm.media_kind
                    AND pst.method = psm.method AND pst.tag_id = psm.tag_id
                JOIN tag t ON t.id = psm.tag_id AND t.state = 'active'
                WHERE psm.media_kind = ?
                    AND psm.method = ?
                    AND psm.tag_id = ?
                    AND psm.catalog_scope_id = ?
                    AND psm.bundle_id = ?
                    AND psm.bundle_revision = ?
                    AND psm.provider = ?
                    AND psm.model_id = ?
                    AND psm.model_revision = ?
                    AND psm.preprocessing_revision = ?
                    AND psm.element_count = ?
                    AND psm.label_vocabulary_revision = ?
                    AND psm.weights_sha256 = ?
                    AND psm.policy_revision = ?
            )
            """,
            arguments: [
                target.mediaKind.rawValue,
                method, uuid(tagID), target.catalogScopeID, target.bundleID, target.bundleRevision,
                target.provider, target.modelID, target.modelRevision,
                target.preprocessingRevision, target.elementCount,
                target.labelVocabularyRevision, target.weightsSHA256, target.policyRevision,
            ]
        ) ?? false
    }
}

enum ReviewQueueCursorCodec {
    private struct BoundaryPayload: Codable {
        let originRank: Int
        let score: Double
        let assetID: UUID
    }

    struct Boundary: Sendable {
        let originRank: Int
        let score: Double
        let assetID: UUID
    }

    static func encodeBoundary(
        originRank: Int,
        score: Double,
        assetID: UUID
    ) throws -> ReviewQueueCursor {
        ReviewQueueCursor(
            token: try JSONEncoder().encode(
                BoundaryPayload(originRank: originRank, score: score, assetID: assetID)
            )
        )
    }

    static func decodeBoundary(_ cursor: ReviewQueueCursor) throws -> Boundary {
        let payload = try JSONDecoder().decode(BoundaryPayload.self, from: cursor.token)
        return Boundary(
            originRank: payload.originRank,
            score: payload.score,
            assetID: payload.assetID
        )
    }
}
