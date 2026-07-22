import Foundation
import GRDB

struct GRDBSuggestionThresholdRepository: SuggestionThresholdPort {
    let database: CatalogDatabase

    func defaults() throws -> SuggestionThresholdDefaults {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT method, min_score
                FROM suggestion_score_threshold_default
                """
            )
            var result = SuggestionThresholdDefaults.factory
            for row in rows {
                let methodRaw: String = row["method"]
                guard let method = SuggestionScoreThresholdMethod(rawValue: methodRaw) else {
                    continue
                }
                let score: Double = row["min_score"]
                result[method] = score
            }
            return result
        }
    }

    func setDefault(
        method: SuggestionScoreThresholdMethod,
        minScore: Double,
        updatedAtMs: Int64
    ) throws {
        guard minScore.isFinite, updatedAtMs >= 0 else {
            throw SuggestionThresholdError.invalidScore
        }
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO suggestion_score_threshold_default (
                    method, min_score, updated_at_ms
                ) VALUES (?, ?, ?)
                ON CONFLICT(method) DO UPDATE SET
                    min_score = excluded.min_score,
                    updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [method.rawValue, minScore, updatedAtMs]
            )
        }
    }

    func overrideMinScore(
        tagID: UUID,
        method: SuggestionScoreThresholdMethod
    ) throws -> Double? {
        try database.pool.read { db in
            try Double.fetchOne(
                db,
                sql: """
                SELECT min_score
                FROM suggestion_score_threshold_override
                WHERE tag_id = ? AND method = ?
                """,
                arguments: [uuid(tagID), method.rawValue]
            )
        }
    }

    func setOverride(
        tagID: UUID,
        method: SuggestionScoreThresholdMethod,
        minScore: Double,
        updatedAtMs: Int64
    ) throws {
        guard minScore.isFinite, updatedAtMs >= 0 else {
            throw SuggestionThresholdError.invalidScore
        }
        try database.pool.write { db in
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM tag WHERE id = ? AND state = 'active')",
                arguments: [uuid(tagID)]
            ) ?? false
            guard exists else {
                throw SuggestionThresholdError.tagNotFound
            }
            try db.execute(
                sql: """
                INSERT INTO suggestion_score_threshold_override (
                    tag_id, method, min_score, updated_at_ms
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(tag_id, method) DO UPDATE SET
                    min_score = excluded.min_score,
                    updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [uuid(tagID), method.rawValue, minScore, updatedAtMs]
            )
        }
    }

    func clearOverride(
        tagID: UUID,
        method: SuggestionScoreThresholdMethod
    ) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                DELETE FROM suggestion_score_threshold_override
                WHERE tag_id = ? AND method = ?
                """,
                arguments: [uuid(tagID), method.rawValue]
            )
        }
    }

    func effectiveMinScore(
        tagID: UUID,
        method: SuggestionScoreThresholdMethod
    ) throws -> Double {
        if let override = try overrideMinScore(tagID: tagID, method: method) {
            return override
        }
        return try defaults()[method]
    }

    func listTagOverrides() throws -> [SuggestionTagThresholdOverrideRow] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT o.tag_id, t.name, o.method, o.min_score
                FROM suggestion_score_threshold_override o
                JOIN tag t ON t.id = o.tag_id AND t.state = 'active'
                ORDER BY t.normalized_name ASC, o.method ASC
                """
            )
            var byTag: [UUID: (name: String, overrides: [SuggestionScoreThresholdMethod: Double])] = [:]
            for row in rows {
                guard let tagID = UUID(uuidString: row["tag_id"]) else { continue }
                let methodRaw: String = row["method"]
                guard let method = SuggestionScoreThresholdMethod(rawValue: methodRaw) else {
                    continue
                }
                let score: Double = row["min_score"]
                let name: String = row["name"]
                var entry = byTag[tagID] ?? (name: name, overrides: [:])
                entry.overrides[method] = score
                byTag[tagID] = entry
            }
            return byTag.keys.sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }.compactMap { tagID in
                guard let entry = byTag[tagID] else { return nil }
                return SuggestionTagThresholdOverrideRow(
                    tagID: tagID,
                    displayName: entry.name,
                    overrides: entry.overrides
                )
            }.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        }
    }

    func prunePendingBelowThreshold(
        tagID: UUID,
        method: SuggestionScoreThresholdMethod,
        minScore: Double
    ) throws -> Int {
        guard minScore.isFinite else {
            throw SuggestionThresholdError.invalidScore
        }
        return try database.pool.write { db in
            switch method {
            case .featureKnn:
                try db.execute(
                    sql: """
                    DELETE FROM prediction
                    WHERE tag_id = ?
                        AND state = 'pendingReview'
                        AND score <= ?
                    """,
                    arguments: [uuid(tagID), minScore]
                )
                return db.changesCount
            case .personalCentroid, .personalAdamW:
                try db.execute(
                    sql: """
                    DELETE FROM personal_prediction
                    WHERE tag_id = ?
                        AND method = ?
                        AND state = 'pendingReview'
                        AND score <= ?
                    """,
                    arguments: [uuid(tagID), method.rawValue, minScore]
                )
                return db.changesCount
            }
        }
    }

    private func uuid(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}
