import Foundation
import GRDB

struct GRDBTrainingRunRepository: Sendable {
    let database: CatalogDatabase

    func insert(_ run: TrainingRunRecord) throws {
        try database.pool.write { db in
            try insert(run, on: db)
        }
    }

    func insert(_ run: TrainingRunRecord, on db: Database) throws {
        guard run.createdAtMs >= 0,
              (run.startedAtMs == nil || run.startedAtMs! >= 0),
              (run.finishedAtMs == nil || run.finishedAtMs! >= 0),
              run.state.isTerminal == (run.finishedAtMs != nil),
              !run.catalogScopeID.isEmpty,
              Self.isObjectJSON(run.sampleSummaryJSON),
              Self.isObjectJSON(run.configJSON),
              Self.isObjectJSON(run.metricsJSON),
              Self.isObjectJSON(run.resultSummaryJSON),
              run.sampleManifestSHA256.map(Self.isLowercaseSHA256) ?? true,
              run.artifactSHA256.map(Self.isLowercaseSHA256) ?? true
        else {
            throw PersonalizationReviewError.persistenceFailure
        }
        try db.execute(
            sql: """
            INSERT INTO training_run (
                id, method, state, created_at_ms, started_at_ms, finished_at_ms,
                catalog_scope_id, job_id, sample_summary_json, sample_manifest_sha256,
                config_json, metrics_json, artifact_kind, artifact_ref, artifact_sha256,
                result_summary_json, error_code
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                run.id.uuidString.lowercased(),
                run.method.rawValue,
                run.state.rawValue,
                run.createdAtMs,
                run.startedAtMs,
                run.finishedAtMs,
                run.catalogScopeID,
                run.jobID?.uuidString.lowercased(),
                run.sampleSummaryJSON,
                run.sampleManifestSHA256,
                run.configJSON,
                run.metricsJSON,
                run.artifactKind,
                run.artifactRef,
                run.artifactSHA256,
                run.resultSummaryJSON,
                run.errorCode,
            ]
        )
    }

    func update(
        id: UUID,
        state: TrainingRunState,
        startedAtMs: Int64? = nil,
        finishedAtMs: Int64? = nil,
        metricsJSON: String? = nil,
        artifactKind: String? = nil,
        artifactRef: String? = nil,
        artifactSHA256: String? = nil,
        resultSummaryJSON: String? = nil,
        errorCode: String? = nil
    ) throws {
        try database.pool.write { db in
            try update(
                id: id,
                state: state,
                startedAtMs: startedAtMs,
                finishedAtMs: finishedAtMs,
                metricsJSON: metricsJSON,
                artifactKind: artifactKind,
                artifactRef: artifactRef,
                artifactSHA256: artifactSHA256,
                resultSummaryJSON: resultSummaryJSON,
                errorCode: errorCode,
                on: db
            )
        }
    }

    func update(
        id: UUID,
        state: TrainingRunState,
        startedAtMs: Int64? = nil,
        finishedAtMs: Int64? = nil,
        metricsJSON: String? = nil,
        artifactKind: String? = nil,
        artifactRef: String? = nil,
        artifactSHA256: String? = nil,
        resultSummaryJSON: String? = nil,
        errorCode: String? = nil,
        on db: Database
    ) throws {
        if state.isTerminal {
            guard let finishedAtMs, finishedAtMs >= 0 else {
                throw PersonalizationReviewError.persistenceFailure
            }
        } else if finishedAtMs != nil {
            throw PersonalizationReviewError.persistenceFailure
        }
        if let metricsJSON, !Self.isObjectJSON(metricsJSON) {
            throw PersonalizationReviewError.persistenceFailure
        }
        if let resultSummaryJSON, !Self.isObjectJSON(resultSummaryJSON) {
            throw PersonalizationReviewError.persistenceFailure
        }
        if let artifactSHA256, !Self.isLowercaseSHA256(artifactSHA256) {
            throw PersonalizationReviewError.persistenceFailure
        }
        var sets = ["state = ?"]
        var arguments: [DatabaseValueConvertible?] = [state.rawValue]
        if let startedAtMs {
            sets.append("started_at_ms = ?")
            arguments.append(startedAtMs)
        }
        if let finishedAtMs {
            sets.append("finished_at_ms = ?")
            arguments.append(finishedAtMs)
        } else if !state.isTerminal {
            sets.append("finished_at_ms = NULL")
        }
        if let metricsJSON {
            sets.append("metrics_json = ?")
            arguments.append(metricsJSON)
        }
        if let artifactKind {
            sets.append("artifact_kind = ?")
            arguments.append(artifactKind)
        }
        if let artifactRef {
            sets.append("artifact_ref = ?")
            arguments.append(artifactRef)
        }
        if let artifactSHA256 {
            sets.append("artifact_sha256 = ?")
            arguments.append(artifactSHA256)
        }
        if let resultSummaryJSON {
            sets.append("result_summary_json = ?")
            arguments.append(resultSummaryJSON)
        }
        if let errorCode {
            sets.append("error_code = ?")
            arguments.append(errorCode)
        }
        arguments.append(id.uuidString.lowercased())
        try db.execute(
            sql: """
            UPDATE training_run
            SET \(sets.joined(separator: ", "))
            WHERE id = ?
            """,
            arguments: StatementArguments(arguments)
        )
        guard db.changesCount == 1 else {
            throw PersonalizationReviewError.persistenceFailure
        }
    }

    func fetch(id: UUID) throws -> TrainingRunRecord? {
        try database.pool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM training_run WHERE id = ?",
                arguments: [id.uuidString.lowercased()]
            ).flatMap(Self.map)
        }
    }

    func fetch(jobID: UUID) throws -> TrainingRunRecord? {
        try database.pool.read { db in
            try fetch(jobID: jobID, on: db)
        }
    }

    func fetch(jobID: UUID, on db: Database) throws -> TrainingRunRecord? {
        try Row.fetchOne(
            db,
            sql: "SELECT * FROM training_run WHERE job_id = ?",
            arguments: [jobID.uuidString.lowercased()]
        ).flatMap(Self.map)
    }

    func list(
        method: TrainingRunMethod? = nil,
        limit: Int = 50
    ) throws -> [TrainingRunRecord] {
        guard limit > 0 else { return [] }
        return try database.pool.read { db in
            try list(method: method, limit: limit, on: db)
        }
    }

    func list(
        method: TrainingRunMethod?,
        limit: Int,
        on db: Database
    ) throws -> [TrainingRunRecord] {
        guard limit > 0 else { return [] }
        var sql = "SELECT * FROM training_run"
        var arguments: [DatabaseValueConvertible] = []
        if let method {
            sql += " WHERE method = ?"
            arguments.append(method.rawValue)
        }
        sql += " ORDER BY created_at_ms DESC, id ASC LIMIT ?"
        arguments.append(limit)
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            .compactMap(Self.map)
    }

    fileprivate static func map(_ row: Row) -> TrainingRunRecord? {
        guard let id = UUID(uuidString: row["id"]),
              let method = TrainingRunMethod(rawValue: row["method"]),
              let state = TrainingRunState(rawValue: row["state"])
        else {
            return nil
        }
        let jobID: UUID? = {
            guard let raw: String = row["job_id"] else { return nil }
            return UUID(uuidString: raw)
        }()
        return TrainingRunRecord(
            id: id,
            method: method,
            state: state,
            createdAtMs: row["created_at_ms"],
            startedAtMs: row["started_at_ms"],
            finishedAtMs: row["finished_at_ms"],
            catalogScopeID: row["catalog_scope_id"],
            jobID: jobID,
            sampleSummaryJSON: row["sample_summary_json"],
            sampleManifestSHA256: row["sample_manifest_sha256"],
            configJSON: row["config_json"],
            metricsJSON: row["metrics_json"],
            artifactKind: row["artifact_kind"],
            artifactRef: row["artifact_ref"],
            artifactSHA256: row["artifact_sha256"],
            resultSummaryJSON: row["result_summary_json"],
            errorCode: row["error_code"]
        )
    }

    private static func isObjectJSON(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first == "{" && trimmed.last == "}"
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            ("0" ... "9").contains(String($0)) || ("a" ... "f").contains(String($0))
        }
    }
}

struct GRDBTrainingWorkspaceRepository: TrainingWorkspacePort, Sendable {
    let database: CatalogDatabase

    func snapshot(
        method: TrainingRunMethod?,
        limit: Int = 200
    ) throws -> TrainingWorkspaceSnapshot {
        try database.pool.read { db in
            let runs = try GRDBTrainingRunRepository(database: database)
                .list(method: method, limit: limit, on: db)
            let featurePublished = try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM tag_model m
                    JOIN tag t ON t.id = m.tag_id AND t.state = 'active'
                    JOIN tag_model_revision r
                        ON r.tag_id = m.tag_id AND r.revision = m.current_revision
                )
                """
            ) == true
            let featureRow = try Row.fetchOne(
                db,
                sql: """
                SELECT id, artifact_ref
                FROM training_run
                WHERE method = 'featureKnn'
                    AND state = 'succeeded'
                    AND artifact_ref IS NOT NULL
                ORDER BY created_at_ms DESC, id ASC
                LIMIT 1
                """
            )
            var slots = [
                TrainingWorkspaceSlot(
                    method: .featureKnn,
                    isPublished: featurePublished,
                    publishedRunID: featurePublished
                        ? featureRow
                            .flatMap { row -> String? in row["id"] }
                            .flatMap(UUID.init(uuidString:))
                        : nil,
                    artifactRef: featurePublished
                        ? featureRow.flatMap { row -> String? in row["artifact_ref"] }
                        : nil
                ),
            ]
            for (method, personalMethod) in [
                (TrainingRunMethod.personalCentroid, PersonalSuggestionMethod.personalCentroid),
                (TrainingRunMethod.personalAdamW, PersonalSuggestionMethod.personalAdamW),
            ] {
                let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT r.id, r.artifact_ref
                    FROM personal_suggestion_model m
                    JOIN training_run r ON r.id = m.published_run_id
                    WHERE m.method = ?
                        AND r.method = ?
                        AND r.state = 'succeeded'
                        AND r.artifact_ref IS NOT NULL
                    """,
                    arguments: [personalMethod.rawValue, method.rawValue]
                )
                slots.append(
                    TrainingWorkspaceSlot(
                        method: method,
                        isPublished: row != nil,
                        publishedRunID: row
                            .flatMap { value -> String? in value["id"] }
                            .flatMap(UUID.init(uuidString:)),
                        artifactRef: row.flatMap { value -> String? in value["artifact_ref"] }
                    )
                )
            }
            return TrainingWorkspaceSnapshot(runs: runs, slots: slots)
        }
    }
}

enum TrainingRunJSON {
    static func encode(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw PersonalizationReviewError.persistenceFailure
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let value = String(data: data, encoding: .utf8) else {
            throw PersonalizationReviewError.persistenceFailure
        }
        return value
    }

    static func decodeObject(_ value: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(value.utf8))
            as? [String: Any]
        else {
            throw PersonalizationReviewError.persistenceFailure
        }
        return object
    }
}
