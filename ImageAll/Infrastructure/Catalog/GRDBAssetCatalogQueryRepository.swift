import Foundation
import GRDB

struct GRDBAssetCatalogQueryRepository: AssetCatalogQueryPort, Sendable {
    let database: CatalogDatabase

    func fetchAssetPage(_ request: AssetPageRequest) throws -> AssetPageResult {
        guard (CatalogQuerySQLHelpers.minPageLimit ... CatalogQuerySQLHelpers.maxPageLimit).contains(request.limit) else {
            throw CatalogQueryError.invalidPageLimit
        }
        if let cursor = request.cursor, cursor.sort != request.sort {
            throw CatalogQueryError.cursorSortMismatch
        }

        return try database.pool.read { db in
            var arguments = StatementArguments()
            let whereClause = try buildWhereClause(filter: request.filter, arguments: &arguments)
            let orderClause = orderClause(for: request.sort)
            if let cursor = request.cursor {
                let cursorClause = try buildCursorClause(cursor: cursor, arguments: &arguments)
                let sql = """
                SELECT
                    asset.id AS asset_id,
                    asset.source_id AS source_id,
                    source.display_name AS source_display_name,
                    source.state AS source_state,
                    asset.relative_path AS relative_path,
                    asset.file_name AS file_name,
                    asset.media_type AS media_type,
                    asset.media_created_at_ms AS media_created_at_ms,
                    asset.media_modified_at_ms AS media_modified_at_ms,
                    asset.width AS width,
                    asset.height AS height,
                    asset.availability AS availability,
                    asset.content_revision AS content_revision,
                    \(CatalogQuerySQLHelpers.timeEmptyMarkerSQL) AS time_empty_marker,
                    \(CatalogQuerySQLHelpers.coalescedMediaTimeSQL) AS coalesced_time_ms,
                    (
                        SELECT COUNT(*)
                        FROM asset_tag_decision d
                        WHERE d.asset_id = asset.id AND d.decision = 'accepted'
                    ) AS accepted_tag_count,
                    (
                        SELECT COUNT(*)
                        FROM asset_tag_decision d
                        WHERE d.asset_id = asset.id AND d.decision = 'rejected'
                    ) AS rejected_tag_count
                FROM asset
                INNER JOIN source ON source.id = asset.source_id
                WHERE asset.locator_state = 'current'
                    AND \(whereClause)
                    AND \(cursorClause)
                ORDER BY \(orderClause)
                LIMIT ?
                """
                arguments += [request.limit]
                let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
                return try makePageResult(rows: rows, sort: request.sort, limit: request.limit)
            }

            let sql = """
            SELECT
                asset.id AS asset_id,
                asset.source_id AS source_id,
                source.display_name AS source_display_name,
                source.state AS source_state,
                asset.relative_path AS relative_path,
                asset.file_name AS file_name,
                asset.media_type AS media_type,
                asset.media_created_at_ms AS media_created_at_ms,
                asset.media_modified_at_ms AS media_modified_at_ms,
                asset.width AS width,
                asset.height AS height,
                asset.availability AS availability,
                asset.content_revision AS content_revision,
                \(CatalogQuerySQLHelpers.timeEmptyMarkerSQL) AS time_empty_marker,
                \(CatalogQuerySQLHelpers.coalescedMediaTimeSQL) AS coalesced_time_ms,
                (
                    SELECT COUNT(*)
                    FROM asset_tag_decision d
                    WHERE d.asset_id = asset.id AND d.decision = 'accepted'
                ) AS accepted_tag_count,
                (
                    SELECT COUNT(*)
                    FROM asset_tag_decision d
                    WHERE d.asset_id = asset.id AND d.decision = 'rejected'
                ) AS rejected_tag_count
            FROM asset
            INNER JOIN source ON source.id = asset.source_id
            WHERE asset.locator_state = 'current'
                AND \(whereClause)
            ORDER BY \(orderClause)
            LIMIT ?
            """
            arguments += [request.limit]
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return try makePageResult(rows: rows, sort: request.sort, limit: request.limit)
        }
    }

    func fetchInspectorDetail(assetID: UUID) throws -> AssetInspectorDetail {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT
                    asset.id AS asset_id,
                    asset.source_id AS source_id,
                    source.display_name AS source_display_name,
                    source.state AS source_state,
                    asset.relative_path AS relative_path,
                    asset.file_name AS file_name,
                    asset.media_type AS media_type,
                    asset.media_created_at_ms AS media_created_at_ms,
                    asset.media_modified_at_ms AS media_modified_at_ms,
                    asset.width AS width,
                    asset.height AS height,
                    asset.availability AS availability,
                    asset.content_revision AS content_revision,
                    file_fingerprint.size_bytes AS fingerprint_size_bytes,
                    file_fingerprint.modified_at_ns AS fingerprint_modified_at_ns,
                    (
                        SELECT COUNT(*)
                        FROM asset_tag_decision d
                        WHERE d.asset_id = asset.id AND d.decision = 'accepted'
                    ) AS accepted_tag_count,
                    (
                        SELECT COUNT(*)
                        FROM asset_tag_decision d
                        WHERE d.asset_id = asset.id AND d.decision = 'rejected'
                    ) AS rejected_tag_count
                FROM asset
                INNER JOIN source ON source.id = asset.source_id
                LEFT JOIN file_fingerprint ON file_fingerprint.asset_id = asset.id
                WHERE asset.id = ? AND asset.locator_state = 'current'
                """,
                arguments: [CatalogQuerySQLHelpers.lowercaseUUID(assetID)]
            ) else {
                throw CatalogQueryError.notFound
            }

            let tagRows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    tag.id AS tag_id,
                    tag.name AS tag_name,
                    tag.state AS tag_state,
                    asset_tag_decision.decision AS decision
                FROM tag
                LEFT JOIN asset_tag_decision
                    ON asset_tag_decision.tag_id = tag.id
                    AND asset_tag_decision.asset_id = ?
                ORDER BY tag.normalized_name COLLATE BINARY, tag.id
                """,
                arguments: [CatalogQuerySQLHelpers.lowercaseUUID(assetID)]
            )

            let tags: [InspectorTagState] = tagRows.map { tagRow in
                let decisionRaw: String? = tagRow["decision"]
                let decision: TagDecisionQueryState
                switch decisionRaw {
                case "accepted":
                    decision = .accepted
                case "rejected":
                    decision = .rejected
                default:
                    decision = .unknown
                }
                return InspectorTagState(
                    tagID: UUID(uuidString: tagRow["tag_id"])!,
                    displayName: tagRow["tag_name"],
                    tagState: TagState(rawValue: tagRow["tag_state"]) ?? .active,
                    decision: decision
                )
            }

            return AssetInspectorDetail(
                assetID: UUID(uuidString: row["asset_id"])!,
                sourceID: UUID(uuidString: row["source_id"])!,
                sourceDisplayName: row["source_display_name"],
                sourceState: SourceState(rawValue: row["source_state"]) ?? .active,
                relativePath: row["relative_path"],
                fileName: row["file_name"],
                mediaType: row["media_type"],
                mediaCreatedAtMs: row["media_created_at_ms"],
                mediaModifiedAtMs: row["media_modified_at_ms"],
                width: row["width"],
                height: row["height"],
                availability: AssetAvailability(rawValue: row["availability"]) ?? .available,
                contentRevision: row["content_revision"],
                acceptedTagCount: row["accepted_tag_count"],
                rejectedTagCount: row["rejected_tag_count"],
                fingerprintSizeBytes: row["fingerprint_size_bytes"],
                fingerprintModifiedAtNs: row["fingerprint_modified_at_ns"],
                tags: tags
            )
        }
    }

    private func makePageResult(rows: [Row], sort: AssetPageSort, limit: Int) throws -> AssetPageResult {
        let items: [AssetGridItemProjection] = rows.map { row in
            AssetGridItemProjection(
                assetID: UUID(uuidString: row["asset_id"])!,
                sourceID: UUID(uuidString: row["source_id"])!,
                sourceDisplayName: row["source_display_name"],
                sourceState: SourceState(rawValue: row["source_state"]) ?? .active,
                relativePath: row["relative_path"],
                fileName: row["file_name"],
                mediaType: row["media_type"],
                mediaCreatedAtMs: row["media_created_at_ms"],
                mediaModifiedAtMs: row["media_modified_at_ms"],
                width: row["width"],
                height: row["height"],
                availability: AssetAvailability(rawValue: row["availability"]) ?? .available,
                contentRevision: row["content_revision"],
                acceptedTagCount: row["accepted_tag_count"],
                rejectedTagCount: row["rejected_tag_count"]
            )
        }

        let nextCursor: AssetPageCursor?
        if items.count == limit, let last = items.last, let lastRow = rows.last {
            nextCursor = makeCursor(from: lastRow, sort: sort, assetID: last.assetID)
        } else {
            nextCursor = nil
        }

        return AssetPageResult(items: items, nextCursor: nextCursor)
    }

    private func makeCursor(from row: Row, sort: AssetPageSort, assetID: UUID) -> AssetPageCursor {
        switch sort {
        case .newest, .oldest:
            let marker = row.intValue(named: "time_empty_marker")
            let coalesced: Int64? = row["coalesced_time_ms"]
            return AssetPageCursor(
                sort: sort,
                payload: .timeSort(timeEmptyMarker: marker, coalescedTimeMs: coalesced, assetID: assetID)
            )
        case .fileNameAscending:
            let fileName: String? = row["file_name"]
            let hasFileName = fileName == nil ? 1 : 0
            return AssetPageCursor(
                sort: sort,
                payload: .fileNameSort(hasFileName: hasFileName, fileName: fileName, assetID: assetID)
            )
        }
    }

    private func orderClause(for sort: AssetPageSort) -> String {
        switch sort {
        case .newest:
            return """
            \(CatalogQuerySQLHelpers.timeEmptyMarkerSQL) ASC,
            \(CatalogQuerySQLHelpers.coalescedMediaTimeSQL) DESC,
            asset.id DESC
            """
        case .oldest:
            return """
            \(CatalogQuerySQLHelpers.timeEmptyMarkerSQL) ASC,
            \(CatalogQuerySQLHelpers.coalescedMediaTimeSQL) ASC,
            asset.id ASC
            """
        case .fileNameAscending:
            return """
            \(CatalogQuerySQLHelpers.fileNamePresenceSQL) ASC,
            asset.file_name COLLATE NOCASE ASC,
            asset.id ASC
            """
        }
    }

    private func buildCursorClause(cursor: AssetPageCursor, arguments: inout StatementArguments) throws -> String {
        switch (cursor.sort, cursor.payload) {
        case (.newest, .timeSort(let marker, let time, let assetID)):
            if marker == 0, let time {
                arguments += [
                    marker,
                    marker,
                    time,
                    time,
                    CatalogQuerySQLHelpers.lowercaseUUID(assetID),
                ]
                return """
                (
                    \(CatalogQuerySQLHelpers.timeEmptyMarkerSQL) > ?
                    OR (
                        \(CatalogQuerySQLHelpers.timeEmptyMarkerSQL) = ?
                        AND (
                            \(CatalogQuerySQLHelpers.coalescedMediaTimeSQL) < ?
                            OR (
                                \(CatalogQuerySQLHelpers.coalescedMediaTimeSQL) = ?
                                AND asset.id < ?
                            )
                        )
                    )
                )
                """
            }
            arguments += [marker, marker, CatalogQuerySQLHelpers.lowercaseUUID(assetID)]
            return """
            (
                \(CatalogQuerySQLHelpers.timeEmptyMarkerSQL) > ?
                OR (
                    \(CatalogQuerySQLHelpers.timeEmptyMarkerSQL) = ?
                    AND asset.id < ?
                )
            )
            """
        case (.oldest, .timeSort(let marker, let time, let assetID)):
            if marker == 0, let time {
                arguments += [
                    marker,
                    marker,
                    time,
                    time,
                    CatalogQuerySQLHelpers.lowercaseUUID(assetID),
                ]
                return """
                (
                    \(CatalogQuerySQLHelpers.timeEmptyMarkerSQL) > ?
                    OR (
                        \(CatalogQuerySQLHelpers.timeEmptyMarkerSQL) = ?
                        AND (
                            \(CatalogQuerySQLHelpers.coalescedMediaTimeSQL) > ?
                            OR (
                                \(CatalogQuerySQLHelpers.coalescedMediaTimeSQL) = ?
                                AND asset.id > ?
                            )
                        )
                    )
                )
                """
            }
            arguments += [marker, marker, CatalogQuerySQLHelpers.lowercaseUUID(assetID)]
            return """
            (
                \(CatalogQuerySQLHelpers.timeEmptyMarkerSQL) > ?
                OR (
                    \(CatalogQuerySQLHelpers.timeEmptyMarkerSQL) = ?
                    AND asset.id > ?
                )
            )
            """
        case (.fileNameAscending, .fileNameSort(let hasFileName, let fileName, let assetID)):
            if hasFileName == 0, let fileName {
                arguments += [
                    hasFileName,
                    hasFileName,
                    fileName,
                    fileName,
                    CatalogQuerySQLHelpers.lowercaseUUID(assetID),
                ]
                return """
                (
                    \(CatalogQuerySQLHelpers.fileNamePresenceSQL) > ?
                    OR (
                        \(CatalogQuerySQLHelpers.fileNamePresenceSQL) = ?
                        AND (
                            asset.file_name COLLATE NOCASE > ? COLLATE NOCASE
                            OR (
                                asset.file_name COLLATE NOCASE = ? COLLATE NOCASE
                                AND asset.id > ?
                            )
                        )
                    )
                )
                """
            }
            arguments += [hasFileName, hasFileName, CatalogQuerySQLHelpers.lowercaseUUID(assetID)]
            return """
            (
                \(CatalogQuerySQLHelpers.fileNamePresenceSQL) > ?
                OR (
                    \(CatalogQuerySQLHelpers.fileNamePresenceSQL) = ?
                    AND asset.id > ?
                )
            )
            """
        default:
            throw CatalogQueryError.cursorSortMismatch
        }
    }

    private func buildWhereClause(filter: AssetPageFilter, arguments: inout StatementArguments) throws -> String {
        var clauses = ["1 = 1"]

        if !filter.sourceIDs.isEmpty {
            let placeholders = Array(repeating: "?", count: filter.sourceIDs.count).joined(separator: ", ")
            clauses.append("asset.source_id IN (\(placeholders))")
            for sourceID in filter.sourceIDs {
                arguments += [CatalogQuerySQLHelpers.lowercaseUUID(sourceID)]
            }
        }

        if !filter.availabilities.isEmpty {
            let placeholders = Array(repeating: "?", count: filter.availabilities.count).joined(separator: ", ")
            clauses.append("asset.availability IN (\(placeholders))")
            for availability in filter.availabilities {
                arguments += [availability.rawValue]
            }
        }

        if !filter.mediaTypes.isEmpty {
            let placeholders = Array(repeating: "?", count: filter.mediaTypes.count).joined(separator: ", ")
            clauses.append("asset.media_type IN (\(placeholders))")
            for mediaType in filter.mediaTypes {
                arguments += [mediaType]
            }
        }

        switch filter.tagPresence {
        case .any:
            break
        case .tagged:
            clauses.append(
                """
                EXISTS (
                    SELECT 1 FROM asset_tag_decision d
                    WHERE d.asset_id = asset.id AND d.decision = 'accepted'
                )
                """
            )
        case .untagged:
            clauses.append(
                """
                NOT EXISTS (
                    SELECT 1 FROM asset_tag_decision d
                    WHERE d.asset_id = asset.id AND d.decision = 'accepted'
                )
                """
            )
        }

        if !filter.tagDecisionFilters.isEmpty {
            switch filter.tagMatchMode {
            case .all:
                for tagFilter in filter.tagDecisionFilters {
                    clauses.append(
                        """
                        EXISTS (
                            SELECT 1 FROM asset_tag_decision d
                            WHERE d.asset_id = asset.id
                                AND d.tag_id = ?
                                AND d.decision = ?
                        )
                        """
                    )
                    arguments += [
                        CatalogQuerySQLHelpers.lowercaseUUID(tagFilter.tagID),
                        tagFilter.decision.rawValue,
                    ]
                }
            case .any:
                var anyClauses: [String] = []
                for tagFilter in filter.tagDecisionFilters {
                    anyClauses.append("(d.tag_id = ? AND d.decision = ?)")
                    arguments += [
                        CatalogQuerySQLHelpers.lowercaseUUID(tagFilter.tagID),
                        tagFilter.decision.rawValue,
                    ]
                }
                clauses.append(
                    """
                    EXISTS (
                        SELECT 1 FROM asset_tag_decision d
                        WHERE d.asset_id = asset.id
                            AND (\(anyClauses.joined(separator: " OR ")))
                    )
                    """
                )
            }
        }

        if let searchText = CatalogQuerySQLHelpers.normalizedSearchText(filter.searchText) {
            let pattern = "%\(CatalogQuerySQLHelpers.escapeLikePattern(searchText))%"
            arguments += [pattern, pattern, pattern, pattern]
            clauses.append(
                """
                (
                    asset.file_name LIKE ? ESCAPE '\\'
                    OR asset.relative_path LIKE ? ESCAPE '\\'
                    OR source.display_name LIKE ? ESCAPE '\\'
                    OR EXISTS (
                        SELECT 1
                        FROM asset_tag_decision d
                        INNER JOIN tag ON tag.id = d.tag_id
                        WHERE d.asset_id = asset.id
                            AND tag.name LIKE ? ESCAPE '\\'
                    )
                )
                """
            )
        }

        return clauses.joined(separator: " AND ")
    }
}

private extension Row {
    func intValue(named name: String) -> Int {
        if let value = self[name] as Int? {
            return value
        }
        if let value = self[name] as Int64? {
            return Int(value)
        }
        return 0
    }
}
