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

        return try CatalogQueryErrorMapping.perform {
            try database.pool.read { db in
            var arguments = StatementArguments()
            let whereClause = try buildWhereClause(db: db, filter: request.filter, arguments: &arguments)
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
                    asset.media_kind AS media_kind,
                    asset.media_type AS media_type,
                    asset.duration_ms AS duration_ms,
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
                asset.media_kind AS media_kind,
                asset.media_type AS media_type,
                asset.duration_ms AS duration_ms,
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
    }

    func fetchGalleryOverview() throws -> GalleryOverviewSnapshot {
        try CatalogQueryErrorMapping.perform {
            try database.pool.read { db in
                let exactRows = try Row.fetchAll(
                    db,
                    sql: """
                    \(Self.galleryOverviewAssetCTE),
                    exact_group AS (
                        SELECT
                            overview_asset.media_kind,
                            fingerprint.content_sha256,
                            COUNT(*) AS member_count
                        FROM overview_asset
                        JOIN asset_similarity_fingerprint AS fingerprint
                          ON fingerprint.asset_id = overview_asset.id
                         AND fingerprint.content_revision = overview_asset.content_revision
                        WHERE fingerprint.content_digest_origin = 'verifiedOriginalBytes'
                          AND fingerprint.content_sha256 IS NOT NULL
                        GROUP BY overview_asset.media_kind, fingerprint.content_sha256
                    )
                    SELECT
                        media_kind,
                        SUM(member_count) AS fingerprint_count,
                        SUM(CASE WHEN member_count > 1 THEN member_count - 1 ELSE 0 END)
                            AS redundant_count
                    FROM exact_group
                    GROUP BY media_kind
                    """
                )
                let exactByKind = Dictionary(
                    uniqueKeysWithValues: exactRows.compactMap { row -> (MediaKind, (Int, Int))? in
                        guard let raw: String = row["media_kind"],
                              let mediaKind = MediaKind(rawValue: raw)
                        else { return nil }
                        let fingerprintCount: Int = row["fingerprint_count"]
                        let redundantCount: Int = row["redundant_count"]
                        return (mediaKind, (fingerprintCount, redundantCount))
                    }
                )
                let mediaCountRows = try Row.fetchAll(
                    db,
                    sql: """
                    \(Self.galleryOverviewAssetCTE)
                    SELECT media_kind, COUNT(*) AS total_count
                    FROM overview_asset
                    GROUP BY media_kind
                    """
                )
                let totalByKind = Dictionary(
                    uniqueKeysWithValues: mediaCountRows.compactMap { row -> (MediaKind, Int)? in
                        guard let raw: String = row["media_kind"],
                              let mediaKind = MediaKind(rawValue: raw)
                        else { return nil }
                        let count: Int = row["total_count"]
                        return (mediaKind, count)
                    }
                )
                let media = MediaKind.allCases.map { mediaKind in
                    let totalCount = totalByKind[mediaKind, default: 0]
                    let exact = exactByKind[mediaKind] ?? (0, 0)
                    return GalleryOverviewMediaSummary(
                        mediaKind: mediaKind,
                        totalCount: totalCount,
                        exactUniqueCount: max(0, totalCount - exact.1),
                        exactRedundantCount: exact.1,
                        exactFingerprintCount: exact.0
                    )
                }

                let sourceRows = try Row.fetchAll(
                    db,
                    sql: """
                    \(Self.galleryOverviewAssetCTE)
                    SELECT
                        source_id,
                        source_display_name,
                        source_kind,
                        source_state,
                        SUM(CASE WHEN media_kind = 'image' THEN 1 ELSE 0 END) AS image_count,
                        SUM(CASE WHEN media_kind = 'video' THEN 1 ELSE 0 END) AS video_count,
                        COUNT(*) AS total_count
                    FROM overview_asset
                    GROUP BY source_id, source_display_name, source_kind, source_state
                    ORDER BY total_count DESC, source_display_name COLLATE NOCASE, source_id
                    """
                )
                let sources = try sourceRows.map { row -> GalleryOverviewSourceSummary in
                    guard let rawID: String = row["source_id"],
                          let sourceID = UUID(uuidString: rawID),
                          let kindRaw: String = row["source_kind"],
                          let kind = SourceKind(rawValue: kindRaw),
                          let stateRaw: String = row["source_state"],
                          let state = SourceState(rawValue: stateRaw)
                    else { throw CatalogQueryError.persistenceFailure }
                    return GalleryOverviewSourceSummary(
                        sourceID: sourceID,
                        displayName: row["source_display_name"],
                        kind: kind,
                        state: state,
                        imageCount: row["image_count"],
                        videoCount: row["video_count"]
                    )
                }

                let tagRows = try Row.fetchAll(
                    db,
                    sql: """
                    \(Self.galleryOverviewAssetCTE)
                    SELECT
                        tag.id AS tag_id,
                        tag.name AS tag_name,
                        SUM(CASE WHEN overview_asset.media_kind = 'image' THEN 1 ELSE 0 END)
                            AS image_count,
                        SUM(CASE WHEN overview_asset.media_kind = 'video' THEN 1 ELSE 0 END)
                            AS video_count,
                        COUNT(*) AS total_count
                    FROM asset_tag_decision AS decision
                    JOIN overview_asset ON overview_asset.id = decision.asset_id
                    JOIN tag ON tag.id = decision.tag_id
                    WHERE decision.decision = 'accepted'
                      AND tag.state = 'active'
                    GROUP BY tag.id, tag.name, tag.normalized_name
                    ORDER BY total_count DESC, tag.normalized_name COLLATE BINARY, tag.id
                    LIMIT 12
                    """
                )
                let positiveTags = try tagRows.map { row -> GalleryOverviewTagSummary in
                    guard let rawID: String = row["tag_id"],
                          let tagID = UUID(uuidString: rawID)
                    else { throw CatalogQueryError.persistenceFailure }
                    return GalleryOverviewTagSummary(
                        tagID: tagID,
                        displayName: row["tag_name"],
                        imageCount: row["image_count"],
                        videoCount: row["video_count"]
                    )
                }

                let positiveCounts = try Row.fetchOne(
                    db,
                    sql: """
                    \(Self.galleryOverviewAssetCTE)
                    SELECT
                        COUNT(DISTINCT decision.asset_id) AS asset_count,
                        COUNT(*) AS decision_count
                    FROM asset_tag_decision AS decision
                    JOIN overview_asset ON overview_asset.id = decision.asset_id
                    JOIN tag ON tag.id = decision.tag_id
                    WHERE decision.decision = 'accepted'
                      AND tag.state = 'active'
                    """
                )

                let yearRows = try Row.fetchAll(
                    db,
                    sql: """
                    \(Self.galleryOverviewAssetCTE)
                    SELECT
                        CAST(strftime('%Y', media_time_ms / 1000, 'unixepoch') AS INTEGER) AS year,
                        SUM(CASE WHEN media_kind = 'image' THEN 1 ELSE 0 END) AS image_count,
                        SUM(CASE WHEN media_kind = 'video' THEN 1 ELSE 0 END) AS video_count
                    FROM overview_asset
                    WHERE media_time_ms IS NOT NULL
                    GROUP BY year
                    ORDER BY year
                    """
                )
                let years = yearRows.map { row in
                    GalleryOverviewYearSummary(
                        year: row["year"],
                        imageCount: row["image_count"],
                        videoCount: row["video_count"]
                    )
                }
                let undatedCount = try Int.fetchOne(
                    db,
                    sql: """
                    \(Self.galleryOverviewAssetCTE)
                    SELECT COUNT(*) FROM overview_asset WHERE media_time_ms IS NULL
                    """
                ) ?? 0

                let availabilityRows = try Row.fetchAll(
                    db,
                    sql: """
                    \(Self.galleryOverviewAssetCTE)
                    SELECT
                        availability,
                        SUM(CASE WHEN media_kind = 'image' THEN 1 ELSE 0 END) AS image_count,
                        SUM(CASE WHEN media_kind = 'video' THEN 1 ELSE 0 END) AS video_count
                    FROM overview_asset
                    GROUP BY availability
                    ORDER BY CASE availability
                        WHEN 'available' THEN 0
                        WHEN 'missing' THEN 1
                        WHEN 'unreadable' THEN 2
                        WHEN 'unsupported' THEN 3
                        ELSE 4
                    END
                    """
                )
                let availability = try availabilityRows.map { row -> GalleryOverviewAvailabilitySummary in
                    guard let raw: String = row["availability"],
                          let value = AssetAvailability(rawValue: raw)
                    else { throw CatalogQueryError.persistenceFailure }
                    return GalleryOverviewAvailabilitySummary(
                        availability: value,
                        imageCount: row["image_count"],
                        videoCount: row["video_count"]
                    )
                }

                return GalleryOverviewSnapshot(
                    media: media,
                    sources: sources,
                    positiveTags: positiveTags,
                    years: years,
                    availability: availability,
                    undatedCount: undatedCount,
                    positiveLabeledAssetCount: positiveCounts?["asset_count"] ?? 0,
                    acceptedDecisionCount: positiveCounts?["decision_count"] ?? 0
                )
            }
        }
    }

    func fetchInspectorDetail(assetID: UUID) throws -> AssetInspectorDetail {
        try CatalogQueryErrorMapping.perform {
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
                    asset.media_kind AS media_kind,
                    asset.media_type AS media_type,
                    asset.duration_ms AS duration_ms,
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
                WHERE asset.id = ?
                    AND asset.locator_state = 'current'
                    AND \(Self.nonBrowseableRecycleEntryExclusionSQL)
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
                mediaKind: MediaKind(rawValue: row["media_kind"]) ?? .image,
                mediaType: row["media_type"],
                durationMs: row["duration_ms"],
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
    }

    func fetchPhotosCatalogAssetCount(sourceID: UUID) throws -> Int {
        try CatalogQueryErrorMapping.perform {
            try database.pool.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*)
                    FROM asset
                    WHERE source_id = ?
                        AND locator_kind = 'photos'
                        AND locator_state = 'current'
                        AND availability = 'available'
                    """,
                    arguments: [CatalogQuerySQLHelpers.lowercaseUUID(sourceID)]
                ) ?? 0
            }
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
                mediaKind: MediaKind(rawValue: row["media_kind"]) ?? .image,
                mediaType: row["media_type"],
                durationMs: row["duration_ms"],
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

    private func buildWhereClause(
        db: Database,
        filter: AssetPageFilter,
        arguments: inout StatementArguments
    ) throws -> String {
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
        } else {
            clauses.append("asset.availability != ?")
            arguments += [AssetAvailability.recycled.rawValue]
        }

        if !filter.availabilities.contains(.recycled) {
            clauses.append(Self.nonBrowseableRecycleEntryExclusionSQL)
        }

        if !filter.mediaTypes.isEmpty {
            let placeholders = Array(repeating: "?", count: filter.mediaTypes.count).joined(separator: ", ")
            clauses.append("asset.media_type IN (\(placeholders))")
            for mediaType in filter.mediaTypes {
                arguments += [mediaType]
            }
        }

        if !filter.mediaKinds.isEmpty {
            let placeholders = Array(repeating: "?", count: filter.mediaKinds.count)
                .joined(separator: ", ")
            clauses.append("asset.media_kind IN (\(placeholders))")
            for mediaKind in filter.mediaKinds {
                arguments += [mediaKind.rawValue]
            }
        }

        if let selection = filter.worldMapSelection {
            clauses.append(
                try buildWorldMapSelectionClause(
                    selection,
                    arguments: &arguments
                )
            )
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

        for excludedTagID in filter.excludedTagIDs {
            clauses.append(
                """
                NOT EXISTS (
                    SELECT 1 FROM asset_tag_decision d
                    WHERE d.asset_id = asset.id
                        AND d.tag_id = ?
                        AND d.decision = 'accepted'
                )
                """
            )
            arguments += [CatalogQuerySQLHelpers.lowercaseUUID(excludedTagID)]
        }

        if let searchText = CatalogQuerySQLHelpers.normalizedSearchText(filter.searchText) {
            let pattern = "%\(CatalogQuerySQLHelpers.escapeLikePattern(searchText))%"
            let matchingSourceIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM source WHERE display_name LIKE ? ESCAPE '\\'",
                arguments: [pattern]
            )
            let matchingTagIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM tag WHERE name LIKE ? ESCAPE '\\'",
                arguments: [pattern]
            )

            var searchClauses: [String]
            if let trigramPhrase = CatalogQuerySQLHelpers.trigramLiteralPhrase(searchText) {
                searchClauses = [
                    """
                    (
                        asset.rowid IN (
                            SELECT rowid
                            FROM asset_search
                            WHERE asset_search MATCH ?
                        )
                        AND (
                            asset.file_name LIKE ? ESCAPE '\\'
                            OR asset.relative_path LIKE ? ESCAPE '\\'
                        )
                    )
                    """
                ]
                arguments += [trigramPhrase, pattern, pattern]
            } else {
                searchClauses = [
                    "asset.file_name LIKE ? ESCAPE '\\'",
                    "asset.relative_path LIKE ? ESCAPE '\\'",
                ]
                arguments += [pattern, pattern]
            }

            if !matchingSourceIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: matchingSourceIDs.count).joined(separator: ", ")
                searchClauses.append("asset.source_id IN (\(placeholders))")
                for sourceID in matchingSourceIDs {
                    arguments += [sourceID]
                }
            }

            if !matchingTagIDs.isEmpty {
                let placeholders = Array(repeating: "?", count: matchingTagIDs.count).joined(separator: ", ")
                searchClauses.append(
                    """
                    EXISTS (
                        SELECT 1
                        FROM asset_tag_decision d
                        WHERE d.asset_id = asset.id
                            AND d.tag_id IN (\(placeholders))
                    )
                    """
                )
                for tagID in matchingTagIDs {
                    arguments += [tagID]
                }
            }

            clauses.append("(\(searchClauses.joined(separator: " OR ")))")
        }

        return clauses.joined(separator: " AND ")
    }

    private func buildWorldMapSelectionClause(
        _ selection: WorldMapCatalogSelectionQuery,
        arguments: inout StatementArguments
    ) throws -> String {
        guard selection.cellDegrees.isFinite,
              (0.002 ... 360).contains(selection.cellDegrees),
              selection.longitudeBucket >= 0,
              Double(selection.longitudeBucket) * selection.cellDegrees <= 360.000_001,
              selection.latitudeBucket >= 0,
              Double(selection.latitudeBucket) * selection.cellDegrees <= 180.000_001
        else {
            throw CatalogQueryError.invalidSpatialFilter
        }

        var locationClauses = [
            "location.latitude IS NOT NULL",
            "location.longitude IS NOT NULL",
            "CAST((location.longitude + 180.0) / ? AS INTEGER) = ?",
            "CAST((location.latitude + 90.0) / ? AS INTEGER) = ?",
        ]
        arguments += [
            selection.cellDegrees,
            selection.longitudeBucket,
            selection.cellDegrees,
            selection.latitudeBucket,
        ]

        if let bounds = selection.bounds {
            guard bounds.west.isFinite,
                  bounds.south.isFinite,
                  bounds.east.isFinite,
                  bounds.north.isFinite,
                  (-90 ... 90).contains(bounds.south),
                  (-90 ... 90).contains(bounds.north),
                  bounds.south < bounds.north
            else {
                throw CatalogQueryError.invalidSpatialFilter
            }
            locationClauses.append("location.latitude BETWEEN ? AND ?")
            arguments += [bounds.south, bounds.north]

            let coversEveryLongitude = abs(bounds.east - bounds.west) >= 359.999
            if !coversEveryLongitude {
                guard (-180 ... 180).contains(bounds.west),
                      (-180 ... 180).contains(bounds.east)
                else {
                    throw CatalogQueryError.invalidSpatialFilter
                }
                if bounds.west > bounds.east {
                    locationClauses.append(
                        "(location.longitude >= ? OR location.longitude <= ?)"
                    )
                } else {
                    locationClauses.append("location.longitude BETWEEN ? AND ?")
                }
                arguments += [bounds.west, bounds.east]
            }
        }

        return """
        asset.availability = 'available'
        AND asset.media_kind = 'image'
        AND \(Self.nonBrowseableRecycleEntryExclusionSQL)
        AND EXISTS (
            SELECT 1
            FROM asset_location AS location
            WHERE location.asset_id = asset.id
              AND \(locationClauses.joined(separator: "\n              AND "))
        )
        """
    }

    /// Recycle lifecycle state is authoritative for browse visibility.
    ///
    /// Photos reconciliation can legitimately change a recycled asset's
    /// `availability` from `recycled` to `missing` after PhotoKit stops returning
    /// it. Materializing this uncorrelated subquery once per catalog request keeps
    /// those records out of normal pages across relaunches without relying on an
    /// in-memory hidden-ID set or scanning `recycle_entry` once per asset row.
    private static let nonBrowseableRecycleEntryExclusionSQL = """
    asset.id NOT IN (
        SELECT recycle_entry.asset_id
        FROM recycle_entry
        WHERE recycle_entry.asset_id IS NOT NULL
          AND recycle_entry.state IN (
              'pending', 'recycled', 'restoring', 'purging', 'purged'
          )
    )
    """

    private static let galleryOverviewAssetCTE = """
    WITH overview_asset AS (
        SELECT
            asset.id,
            asset.source_id,
            source.display_name AS source_display_name,
            source.kind AS source_kind,
            source.state AS source_state,
            asset.media_kind,
            asset.availability,
            asset.content_revision,
            coalesce(asset.media_created_at_ms, asset.media_modified_at_ms) AS media_time_ms
        FROM asset
        JOIN source ON source.id = asset.source_id
        WHERE asset.locator_state = 'current'
          AND asset.availability != 'recycled'
          AND \(nonBrowseableRecycleEntryExclusionSQL)
    )
    """
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
