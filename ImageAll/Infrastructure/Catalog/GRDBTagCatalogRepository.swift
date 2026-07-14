import Foundation
import GRDB

struct GRDBTagCatalogRepository: TagCatalogQueryPort, TagDecisionCommandPort, Sendable {
    let database: CatalogDatabase

    func listTags(includeArchived: Bool) throws -> [TagListItem] {
        try CatalogQueryErrorMapping.perform {
            try database.pool.read { db in
                let sql: String
                if includeArchived {
                    sql = """
                    SELECT id, name, state
                    FROM tag
                    ORDER BY normalized_name COLLATE BINARY, id
                    """
                } else {
                    sql = """
                    SELECT id, name, state
                    FROM tag
                    WHERE state = 'active'
                    ORDER BY normalized_name COLLATE BINARY, id
                    """
                }
                return try Row.fetchAll(db, sql: sql).map { row in
                    TagListItem(
                        id: UUID(uuidString: row["id"])!,
                        displayName: row["name"],
                        state: TagState(rawValue: row["state"]) ?? .active
                    )
                }
            }
        }
    }

    func selectionAggregate(tagIDs: [UUID], assetIDs: [UUID]) throws -> [TagSelectionAggregate] {
        let uniqueAssetIDs = Array(Set(assetIDs))
        guard !uniqueAssetIDs.isEmpty else {
            throw CatalogQueryError.emptySelection
        }
        guard uniqueAssetIDs.count <= CatalogQuerySQLHelpers.maxSelectionSize else {
            throw CatalogQueryError.selectionTooLarge
        }
        guard !tagIDs.isEmpty else {
            throw CatalogQueryError.emptySelection
        }

        return try CatalogQueryErrorMapping.perform {
            try database.pool.read { db in
                try validateAssetsExist(db, assetIDs: uniqueAssetIDs)

                var aggregates: [TagSelectionAggregate] = []
                for tagID in tagIDs {
                    let placeholders = Array(repeating: "?", count: uniqueAssetIDs.count).joined(separator: ", ")
                    var arguments = StatementArguments()
                    arguments += [CatalogQuerySQLHelpers.lowercaseUUID(tagID)]
                    for assetID in uniqueAssetIDs {
                        arguments += [CatalogQuerySQLHelpers.lowercaseUUID(assetID)]
                    }

                    let row = try Row.fetchOne(
                        db,
                        sql: """
                        SELECT
                            SUM(CASE WHEN d.decision = 'accepted' THEN 1 ELSE 0 END) AS accepted_count,
                            SUM(CASE WHEN d.decision = 'rejected' THEN 1 ELSE 0 END) AS rejected_count
                        FROM asset_tag_decision d
                        WHERE d.tag_id = ?
                            AND d.asset_id IN (\(placeholders))
                        """,
                        arguments: arguments
                    )

                    let accepted = Int(row?["accepted_count"] ?? 0)
                    let rejected = Int(row?["rejected_count"] ?? 0)
                    let unknown = uniqueAssetIDs.count - accepted - rejected
                    aggregates.append(
                        TagSelectionAggregate(
                            tagID: tagID,
                            acceptedCount: accepted,
                            rejectedCount: rejected,
                            unknownCount: unknown
                        )
                    )
                }
                return aggregates
            }
        }
    }

    func createTag(rawName: String, timestampMs: Int64) throws -> Tag {
        try CatalogQueryErrorMapping.perform {
            try database.pool.write { db in
                let existing = try fetchExistingTags(db)
                let tag: Tag
                switch TagCatalogRules.createTag(rawName: rawName, existingTags: existing) {
                case let .success(created):
                    tag = created
                case let .failure(error):
                    throw mapDomainError(error)
                }

                do {
                    try db.execute(
                        sql: """
                        INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                        VALUES (?, ?, ?, 'active', ?, ?)
                        """,
                        arguments: [
                            CatalogQuerySQLHelpers.lowercaseUUID(tag.id),
                            tag.displayName,
                            tag.normalizedName,
                            timestampMs,
                            timestampMs,
                        ]
                    )
                } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                    throw mapTagInsertConstraint(error, db: db, normalizedName: tag.normalizedName)
                } catch {
                    throw CatalogQueryError.persistenceFailure
                }
                return tag
            }
        }
    }

    func batchAccept(tagID: UUID, assetIDs: [UUID], timestampMs: Int64) throws -> TagMutationResult {
        try applyBatchDecision(tagID: tagID, assetIDs: assetIDs, decision: .accepted, timestampMs: timestampMs)
    }

    func batchReject(tagID: UUID, assetIDs: [UUID], timestampMs: Int64) throws -> TagMutationResult {
        try applyBatchDecision(tagID: tagID, assetIDs: assetIDs, decision: .rejected, timestampMs: timestampMs)
    }

    func batchClear(tagID: UUID, assetIDs: [UUID], timestampMs: Int64) throws -> TagMutationResult {
        let uniqueAssetIDs = try validatedUniqueAssetIDs(assetIDs)
        return try CatalogQueryErrorMapping.perform {
            try database.pool.write { db in
                let tagState = try fetchTagState(db, tagID: tagID)
                guard tagState == .active else {
                    throw CatalogQueryError.archivedTag
                }
                try validateAssetsExist(db, assetIDs: uniqueAssetIDs)

                let priorStates = try fetchPriorStates(db, tagID: tagID, assetIDs: uniqueAssetIDs)
                for chunk in uniqueAssetIDs.chunked(size: CatalogQuerySQLHelpers.sqliteBindChunkSize) {
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                    var arguments = StatementArguments()
                    arguments += [CatalogQuerySQLHelpers.lowercaseUUID(tagID)]
                    for assetID in chunk {
                        arguments += [CatalogQuerySQLHelpers.lowercaseUUID(assetID)]
                    }
                    try db.execute(
                        sql: """
                        DELETE FROM asset_tag_decision
                        WHERE tag_id = ? AND asset_id IN (\(placeholders))
                        """,
                        arguments: arguments
                    )
                }
                return TagMutationResult(priorStates: priorStates)
            }
        }
    }

    func createTagAndApply(
        rawName: String,
        assetIDs: [UUID],
        decision: PersistableTagDecision,
        timestampMs: Int64
    ) throws -> TagCreateAndApplyResult {
        let uniqueAssetIDs = try validatedUniqueAssetIDs(assetIDs)
        return try CatalogQueryErrorMapping.perform {
            try database.pool.write { db in
                let existing = try fetchExistingTags(db)
                let tag: Tag
                switch TagCatalogRules.createTag(rawName: rawName, existingTags: existing) {
                case let .success(created):
                    tag = created
                case let .failure(error):
                    throw mapDomainError(error)
                }

                try validateAssetsExist(db, assetIDs: uniqueAssetIDs)

                do {
                    try db.execute(
                        sql: """
                        INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                        VALUES (?, ?, ?, 'active', ?, ?)
                        """,
                        arguments: [
                            CatalogQuerySQLHelpers.lowercaseUUID(tag.id),
                            tag.displayName,
                            tag.normalizedName,
                            timestampMs,
                            timestampMs,
                        ]
                    )
                } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                    throw mapTagInsertConstraint(error, db: db, normalizedName: tag.normalizedName)
                } catch {
                    throw CatalogQueryError.persistenceFailure
                }

                let priorStates = try fetchPriorStates(db, tagID: tag.id, assetIDs: uniqueAssetIDs)
                try writeDecisionChunks(
                    db,
                    tagID: tag.id,
                    assetIDs: uniqueAssetIDs,
                    decision: decision,
                    timestampMs: timestampMs
                )
                return TagCreateAndApplyResult(
                    tagID: tag.id,
                    displayName: tag.displayName,
                    normalizedName: tag.normalizedName,
                    priorStates: priorStates
                )
            }
        }
    }

    func restorePriorStates(_ snapshot: TagMutationPriorStateSnapshot, timestampMs: Int64) throws {
        let assetIDs = snapshot.priorStates.map(\.assetID)
        let uniqueAssetIDs = Array(Set(assetIDs))
        guard !uniqueAssetIDs.isEmpty else {
            throw CatalogQueryError.emptySelection
        }
        guard uniqueAssetIDs.count <= CatalogQuerySQLHelpers.maxSelectionSize else {
            throw CatalogQueryError.selectionTooLarge
        }

        try CatalogQueryErrorMapping.perform {
            try database.pool.write { db in
                let tagState = try fetchTagState(db, tagID: snapshot.tagID)
                guard tagState == .active else {
                    throw CatalogQueryError.archivedTag
                }
                try validateAssetsExist(db, assetIDs: uniqueAssetIDs)

                for chunk in snapshot.priorStates.chunked(size: CatalogQuerySQLHelpers.sqliteBindChunkSize) {
                    for prior in chunk {
                        switch prior.priorState {
                        case .unknown:
                            try db.execute(
                                sql: """
                                DELETE FROM asset_tag_decision
                                WHERE asset_id = ? AND tag_id = ?
                                """,
                                arguments: [
                                    CatalogQuerySQLHelpers.lowercaseUUID(prior.assetID),
                                    CatalogQuerySQLHelpers.lowercaseUUID(snapshot.tagID),
                                ]
                            )
                        case .accepted, .rejected:
                            let decision = prior.priorState == .accepted ? "accepted" : "rejected"
                            try db.execute(
                                sql: """
                                INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                                VALUES (?, ?, ?, ?)
                                ON CONFLICT(asset_id, tag_id) DO UPDATE SET
                                    decision = excluded.decision,
                                    updated_at_ms = excluded.updated_at_ms
                                """,
                                arguments: [
                                    CatalogQuerySQLHelpers.lowercaseUUID(prior.assetID),
                                    CatalogQuerySQLHelpers.lowercaseUUID(snapshot.tagID),
                                    decision,
                                    timestampMs,
                                ]
                            )
                        }
                    }
                }
            }
        }
    }

    private func applyBatchDecision(
        tagID: UUID,
        assetIDs: [UUID],
        decision: PersistableTagDecision,
        timestampMs: Int64
    ) throws -> TagMutationResult {
        let uniqueAssetIDs = try validatedUniqueAssetIDs(assetIDs)
        return try CatalogQueryErrorMapping.perform {
            try database.pool.write { db in
                let tagState = try fetchTagState(db, tagID: tagID)
                guard tagState == .active else {
                    throw CatalogQueryError.archivedTag
                }
                try validateAssetsExist(db, assetIDs: uniqueAssetIDs)

                let priorStates = try fetchPriorStates(db, tagID: tagID, assetIDs: uniqueAssetIDs)
                try writeDecisionChunks(
                    db,
                    tagID: tagID,
                    assetIDs: uniqueAssetIDs,
                    decision: decision,
                    timestampMs: timestampMs
                )
                return TagMutationResult(priorStates: priorStates)
            }
        }
    }

    private func writeDecisionChunks(
        _ db: Database,
        tagID: UUID,
        assetIDs: [UUID],
        decision: PersistableTagDecision,
        timestampMs: Int64
    ) throws {
        for chunk in assetIDs.chunked(size: CatalogQuerySQLHelpers.sqliteBindChunkSize) {
            for assetID in chunk {
                try db.execute(
                    sql: """
                    INSERT INTO asset_tag_decision (asset_id, tag_id, decision, updated_at_ms)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(asset_id, tag_id) DO UPDATE SET
                        decision = excluded.decision,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                    arguments: [
                        CatalogQuerySQLHelpers.lowercaseUUID(assetID),
                        CatalogQuerySQLHelpers.lowercaseUUID(tagID),
                        decision.rawValue,
                        timestampMs,
                    ]
                )
            }
        }
    }

    private func validatedUniqueAssetIDs(_ assetIDs: [UUID]) throws -> [UUID] {
        let unique = Array(Set(assetIDs))
        guard !unique.isEmpty else {
            throw CatalogQueryError.emptySelection
        }
        guard unique.count <= CatalogQuerySQLHelpers.maxSelectionSize else {
            throw CatalogQueryError.selectionTooLarge
        }
        return unique
    }

    private func fetchExistingTags(_ db: Database) throws -> [Tag] {
        try Row.fetchAll(db, sql: "SELECT id, name, normalized_name, state FROM tag").map { row in
            let normalizedName: String = row["normalized_name"]
            return Tag(
                id: UUID(uuidString: row["id"])!,
                displayName: row["name"],
                normalizedName: normalizedName,
                normalizedNameKey: Data(normalizedName.utf8),
                state: TagState(rawValue: row["state"]) ?? .active
            )
        }
    }

    private func fetchTagState(_ db: Database, tagID: UUID) throws -> TagState {
        guard let raw: String = try String.fetchOne(
            db,
            sql: "SELECT state FROM tag WHERE id = ?",
            arguments: [CatalogQuerySQLHelpers.lowercaseUUID(tagID)]
        ) else {
            throw CatalogQueryError.notFound
        }
        return TagState(rawValue: raw) ?? .active
    }

    private func validateAssetsExist(_ db: Database, assetIDs: [UUID]) throws {
        for chunk in assetIDs.chunked(size: CatalogQuerySQLHelpers.sqliteBindChunkSize) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            var arguments = StatementArguments()
            for assetID in chunk {
                arguments += [CatalogQuerySQLHelpers.lowercaseUUID(assetID)]
            }
            let count = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM asset
                WHERE locator_state = 'current' AND id IN (\(placeholders))
                """,
                arguments: arguments
            ) ?? 0
            if count != chunk.count {
                throw CatalogQueryError.notFound
            }
        }
    }

    private func fetchPriorStates(_ db: Database, tagID: UUID, assetIDs: [UUID]) throws -> [TagMutationPriorState] {
        var priorByAsset: [UUID: TagDecisionQueryState] = [:]
        for assetID in assetIDs {
            priorByAsset[assetID] = .unknown
        }

        for chunk in assetIDs.chunked(size: CatalogQuerySQLHelpers.sqliteBindChunkSize) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            var arguments = StatementArguments()
            arguments += [CatalogQuerySQLHelpers.lowercaseUUID(tagID)]
            for assetID in chunk {
                arguments += [CatalogQuerySQLHelpers.lowercaseUUID(assetID)]
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT asset_id, decision
                FROM asset_tag_decision
                WHERE tag_id = ? AND asset_id IN (\(placeholders))
                """,
                arguments: arguments
            )
            for row in rows {
                let assetID = UUID(uuidString: row["asset_id"])!
                let decisionRaw: String = row["decision"]
                let state: TagDecisionQueryState = decisionRaw == "accepted" ? .accepted : .rejected
                priorByAsset[assetID] = state
            }
        }

        return assetIDs.map { assetID in
            TagMutationPriorState(assetID: assetID, priorState: priorByAsset[assetID] ?? .unknown)
        }
    }

    private func mapTagInsertConstraint(_ error: DatabaseError, db: Database, normalizedName: String) -> CatalogQueryError {
        do {
            if try normalizedNameExists(db, normalizedName: normalizedName) {
                return .duplicateTag
            }
        } catch {
            return .persistenceFailure
        }
        return .persistenceFailure
    }

    private func normalizedNameExists(_ db: Database, normalizedName: String) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM tag WHERE normalized_name = ?",
            arguments: [normalizedName]
        ) ?? 0
        return count > 0
    }

    private func mapDomainError(_ error: DomainError) -> CatalogQueryError {
        switch error {
        case .invalidName:
            .invalidTagName
        case .duplicateTag:
            .duplicateTag
        case .invalidStateTransition:
            .archivedTag
        case .referenceNotFound:
            .notFound
        default:
            .persistenceFailure
        }
    }
}

private extension Array {
    func chunked(size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var chunks: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(Array(self[index ..< end]))
            index = end
        }
        return chunks
    }
}

private extension Row {
    subscript(name: String) -> Int {
        if let value = self[name] as Int? {
            return value
        }
        if let value = self[name] as Int64? {
            return Int(value)
        }
        if let value = self[name] as Double? {
            return Int(value)
        }
        return 0
    }
}
