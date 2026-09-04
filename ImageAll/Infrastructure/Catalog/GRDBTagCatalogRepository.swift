import CryptoKit
import Foundation
import GRDB

struct GRDBTagCatalogRepository: TagCatalogQueryPort, TagDecisionCommandPort, StandardOntologyCatalogPort, Sendable {
    let database: CatalogDatabase

    func listTags(includeArchived: Bool) throws -> [TagListItem] {
        try CatalogQueryErrorMapping.perform {
            try database.pool.read { db in
                let sql: String
                if includeArchived {
                    sql = """
                    SELECT tag.id, tag.name, tag.state,
                        coalesce(tag.group_id, ?) AS group_id
                    FROM tag
                    LEFT JOIN standard_tag_binding binding ON binding.tag_id = tag.id
                    LEFT JOIN ontology_concept concept
                        ON concept.ontology_id = binding.ontology_id
                        AND concept.ontology_revision = binding.ontology_revision
                        AND concept.concept_id = binding.concept_id
                    ORDER BY coalesce(concept.normalized_name, tag.normalized_name) COLLATE BINARY, tag.id
                    """
                } else {
                    sql = """
                    SELECT tag.id, tag.name, tag.state,
                        coalesce(tag.group_id, ?) AS group_id
                    FROM tag
                    LEFT JOIN standard_tag_binding binding ON binding.tag_id = tag.id
                    LEFT JOIN ontology_concept concept
                        ON concept.ontology_id = binding.ontology_id
                        AND concept.ontology_revision = binding.ontology_revision
                        AND concept.concept_id = binding.concept_id
                    WHERE tag.state = 'active'
                    ORDER BY coalesce(concept.normalized_name, tag.normalized_name) COLLATE BINARY, tag.id
                    """
                }
                let fallbackGroup = TagGroupSeed.other.id.uuidString.lowercased()
                return try Row.fetchAll(db, sql: sql, arguments: [fallbackGroup]).map { row in
                    TagListItem(
                        id: UUID(uuidString: row["id"])!,
                        displayName: row["name"],
                        state: TagState(rawValue: row["state"]) ?? .active,
                        groupID: UUID(uuidString: row["group_id"]) ?? TagGroupSeed.other.id
                    )
                }
            }
        }
    }

    func listTagGroups() throws -> [TagGroupListItem] {
        try CatalogQueryErrorMapping.perform {
            try database.pool.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, name, sort_order, is_system
                    FROM tag_group
                    ORDER BY sort_order ASC, id ASC
                    """
                ).map { row in
                    TagGroupListItem(
                        id: UUID(uuidString: row["id"])!,
                        displayName: row["name"],
                        sortOrder: row["sort_order"],
                        isSystem: (row["is_system"] as Int64) != 0
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

    func installStandardOntologyPackage(
        _ package: StandardOntologyPackageInput,
        timestampMs: Int64
    ) throws -> StandardOntologyInstallResult {
        let validated = try validateStandardOntologyPackage(package, timestampMs: timestampMs)

        do {
            return try database.pool.write { db in
                if let installed = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT
                        p.standard_pack_revision,
                        p.ontology_id,
                        p.ontology_revision,
                        p.locale_revision,
                        p.manifest_sha256,
                        m.provider,
                        m.model_revision,
                        m.preprocessing_revision,
                        m.mapping_revision,
                        m.policy_revision,
                        m.weights_sha256
                    FROM ontology_pack p
                    JOIN standard_model_revision m
                        ON m.standard_pack_id = p.standard_pack_id
                        AND m.standard_pack_revision = p.standard_pack_revision
                    WHERE p.standard_pack_id = ?
                    ORDER BY p.standard_pack_revision
                    LIMIT 1
                    """,
                    arguments: [package.standardPackID]
                ) {
                    guard standardPackageIdentityMatches(installed, package: package),
                          try installedStandardPackageContentsMatch(db, package: package, concepts: validated.concepts)
                    else {
                        throw StandardOntologyCatalogError.conflictingPackage
                    }
                    return StandardOntologyInstallResult(
                        installedTags: try fetchStandardTags(
                            db,
                            ontologyID: package.ontologyID,
                            ontologyRevision: package.ontologyRevision
                        ),
                        wasAlreadyInstalled: true
                    )
                }

                let ontologyIdentityCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM ontology_pack WHERE ontology_id = ?",
                    arguments: [package.ontologyID]
                ) ?? 0
                guard ontologyIdentityCount == 0 else {
                    throw StandardOntologyCatalogError.conflictingPackage
                }
                for concept in validated.concepts {
                    let tagID = standardTagID(ontologyID: package.ontologyID, conceptID: concept.conceptID)
                    let tagIdentityCount = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM tag WHERE id = ? OR normalized_name = ?",
                        arguments: [
                            tagID.uuidString.lowercased(),
                            standardTagStorageKey(tagID: tagID),
                        ]
                    ) ?? 0
                    guard tagIdentityCount == 0 else {
                        throw StandardOntologyCatalogError.conflictingPackage
                    }
                }

                try db.execute(
                    sql: """
                    INSERT INTO ontology_pack (
                        standard_pack_id, standard_pack_revision, ontology_id, ontology_revision,
                        locale_revision, manifest_sha256, state, installed_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, 'active', ?)
                    """,
                    arguments: [
                        package.standardPackID,
                        package.standardPackRevision,
                        package.ontologyID,
                        package.ontologyRevision,
                        package.localeRevision,
                        package.manifestSHA256,
                        timestampMs,
                    ]
                )

                for concept in validated.concepts {
                    try db.execute(
                        sql: """
                        INSERT INTO ontology_concept (
                            ontology_id, ontology_revision, concept_id,
                            canonical_name, normalized_name
                        ) VALUES (?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            package.ontologyID,
                            package.ontologyRevision,
                            concept.conceptID,
                            concept.displayName,
                            concept.normalizedName,
                        ]
                    )
                }

                for edge in package.edges {
                    try db.execute(
                        sql: """
                        INSERT INTO ontology_edge (
                            ontology_id, ontology_revision, parent_concept_id, child_concept_id
                        ) VALUES (?, ?, ?, ?)
                        """,
                        arguments: [
                            package.ontologyID,
                            package.ontologyRevision,
                            edge.parentConceptID,
                            edge.childConceptID,
                        ]
                    )
                }

                try db.execute(
                    sql: """
                    INSERT INTO standard_model_revision (
                        standard_pack_id, standard_pack_revision, provider, model_revision,
                        preprocessing_revision, mapping_revision, policy_revision, weights_sha256
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        package.standardPackID,
                        package.standardPackRevision,
                        package.provider,
                        package.modelRevision,
                        package.preprocessingRevision,
                        package.mappingRevision,
                        package.policyRevision,
                        package.weightsSHA256,
                    ]
                )

                for concept in validated.concepts {
                    let tagID = standardTagID(ontologyID: package.ontologyID, conceptID: concept.conceptID)
                    try db.execute(
                        sql: """
                        INSERT INTO standard_tag_binding (
                            tag_id, ontology_id, ontology_revision, concept_id
                        ) VALUES (?, ?, ?, ?)
                        """,
                        arguments: [
                            tagID.uuidString.lowercased(),
                            package.ontologyID,
                            package.ontologyRevision,
                            concept.conceptID,
                        ]
                    )
                    try db.execute(
                        sql: """
                        INSERT INTO tag (
                            id, name, normalized_name, state, created_at_ms, updated_at_ms, group_id
                        ) VALUES (?, ?, ?, 'active', ?, ?, ?)
                        """,
                        arguments: [
                            tagID.uuidString.lowercased(),
                            concept.displayName,
                            standardTagStorageKey(tagID: tagID),
                            timestampMs,
                            timestampMs,
                            TagGroupSeed.classify(displayName: concept.displayName).id.uuidString.lowercased(),
                        ]
                    )
                }

                return StandardOntologyInstallResult(
                    installedTags: try fetchStandardTags(
                        db,
                        ontologyID: package.ontologyID,
                        ontologyRevision: package.ontologyRevision
                    ),
                    wasAlreadyInstalled: false
                )
            }
        } catch let error as StandardOntologyCatalogError {
            throw error
        } catch {
            throw StandardOntologyCatalogError.persistenceFailure
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
                        INSERT INTO tag (
                            id, name, normalized_name, state, created_at_ms, updated_at_ms, group_id
                        ) VALUES (?, ?, ?, 'active', ?, ?, ?)
                        """,
                        arguments: [
                            CatalogQuerySQLHelpers.lowercaseUUID(tag.id),
                            tag.displayName,
                            tag.normalizedName,
                            timestampMs,
                            timestampMs,
                            TagGroupSeed.classify(displayName: tag.displayName).id.uuidString.lowercased(),
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

    func createMissingTags(rawNames: [String], timestampMs: Int64) throws -> [Tag] {
        try CatalogQueryErrorMapping.perform {
            try database.pool.write { db in
                var existing = try fetchExistingTags(db)
                var created: [Tag] = []

                for rawName in rawNames {
                    let tag: Tag
                    switch TagCatalogRules.createTag(rawName: rawName, existingTags: existing) {
                    case let .success(newTag):
                        tag = newTag
                    case .failure(.duplicateTag):
                        continue
                    case let .failure(error):
                        throw mapDomainError(error)
                    }

                    do {
                        try db.execute(
                            sql: """
                            INSERT INTO tag (
                                id, name, normalized_name, state, created_at_ms, updated_at_ms, group_id
                            ) VALUES (?, ?, ?, 'active', ?, ?, ?)
                            """,
                            arguments: [
                                CatalogQuerySQLHelpers.lowercaseUUID(tag.id),
                                tag.displayName,
                                tag.normalizedName,
                                timestampMs,
                                timestampMs,
                                TagGroupSeed.classify(displayName: tag.displayName).id.uuidString.lowercased(),
                            ]
                        )
                    } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                        throw mapTagInsertConstraint(error, db: db, normalizedName: tag.normalizedName)
                    } catch {
                        throw CatalogQueryError.persistenceFailure
                    }

                    existing.append(tag)
                    created.append(tag)
                }

                return created
            }
        }
    }

    func renameTag(tagID: UUID, rawName: String, timestampMs: Int64) throws -> Tag {
        try CatalogQueryErrorMapping.perform {
            try database.pool.write { db in
                let existing = try fetchExistingTags(db)
                guard let current = existing.first(where: { $0.id == tagID }) else {
                    throw CatalogQueryError.notFound
                }

                let renamed: Tag
                switch TagCatalogRules.renameTag(current, rawName: rawName, existingTags: existing) {
                case let .success(tag):
                    renamed = tag
                case let .failure(error):
                    throw mapDomainError(error)
                }

                let locationAssetIDs = try WorldMapPlaceResolutionService.acceptedAssetIDs(
                    db,
                    tagID: tagID
                )

                do {
                    try db.execute(
                        sql: """
                        UPDATE tag
                        SET name = ?, normalized_name = ?, updated_at_ms = ?
                        WHERE id = ?
                        """,
                        arguments: [
                            renamed.displayName,
                            renamed.normalizedName,
                            timestampMs,
                            CatalogQuerySQLHelpers.lowercaseUUID(tagID),
                        ]
                    )
                } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                    throw mapTagInsertConstraint(error, db: db, normalizedName: renamed.normalizedName)
                } catch {
                    throw CatalogQueryError.persistenceFailure
                }
                try db.execute(
                    sql: "DELETE FROM tag_place_binding WHERE tag_id = ?",
                    arguments: [CatalogQuerySQLHelpers.lowercaseUUID(tagID)]
                )
                try WorldMapPlaceResolutionService.refreshCanonicalLocations(
                    db,
                    assetIDs: locationAssetIDs,
                    nowMs: timestampMs
                )
                return renamed
            }
        }
    }

    func archiveTag(tagID: UUID, timestampMs: Int64) throws -> Tag {
        try CatalogQueryErrorMapping.perform {
            try database.pool.write { db in
                let existing = try fetchExistingTags(db)
                guard let current = existing.first(where: { $0.id == tagID }) else {
                    throw CatalogQueryError.notFound
                }

                let archived: Tag
                switch TagCatalogRules.archiveTag(current) {
                case let .success(tag):
                    archived = tag
                case let .failure(error):
                    throw mapDomainError(error)
                }

                try db.execute(
                    sql: "UPDATE tag SET state = 'archived', updated_at_ms = ? WHERE id = ?",
                    arguments: [timestampMs, CatalogQuerySQLHelpers.lowercaseUUID(tagID)]
                )
                let locationAssetIDs = try WorldMapPlaceResolutionService.acceptedAssetIDs(
                    db,
                    tagID: tagID
                )
                try db.execute(
                    sql: "DELETE FROM tag_place_binding WHERE tag_id = ?",
                    arguments: [CatalogQuerySQLHelpers.lowercaseUUID(tagID)]
                )
                try WorldMapPlaceResolutionService.refreshCanonicalLocations(
                    db,
                    assetIDs: locationAssetIDs,
                    nowMs: timestampMs
                )
                return archived
            }
        }
    }

    func moveTag(tagID: UUID, toGroupID: UUID, timestampMs: Int64) throws -> TagListItem {
        try CatalogQueryErrorMapping.perform {
            try database.pool.write { db in
                guard try tagExists(db, tagID: tagID) else {
                    throw CatalogQueryError.notFound
                }
                guard try tagGroupExists(db, groupID: toGroupID) else {
                    throw CatalogQueryError.notFound
                }
                try db.execute(
                    sql: """
                    UPDATE tag
                    SET group_id = ?, updated_at_ms = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        CatalogQuerySQLHelpers.lowercaseUUID(toGroupID),
                        timestampMs,
                        CatalogQuerySQLHelpers.lowercaseUUID(tagID),
                    ]
                )
                return try fetchTagListItem(db, tagID: tagID)
            }
        }
    }

    func createTagGroup(rawName: String, timestampMs: Int64) throws -> TagGroupListItem {
        try CatalogQueryErrorMapping.perform {
            try database.pool.write { db in
                let existing = try fetchExistingGroups(db)
                let nextSort = (existing.map(\.sortOrder).max() ?? -1) + 1
                let created: TagGroup
                switch TagGroupRules.createGroup(
                    rawName: rawName,
                    existingGroups: existing,
                    sortOrder: nextSort
                ) {
                case let .success(group):
                    created = group
                case let .failure(error):
                    throw mapDomainError(error)
                }

                do {
                    try db.execute(
                        sql: """
                        INSERT INTO tag_group (
                            id, name, sort_order, is_system, created_at_ms, updated_at_ms
                        ) VALUES (?, ?, ?, 0, ?, ?)
                        """,
                        arguments: [
                            CatalogQuerySQLHelpers.lowercaseUUID(created.id),
                            created.displayName,
                            created.sortOrder,
                            timestampMs,
                            timestampMs,
                        ]
                    )
                } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                    throw CatalogQueryError.duplicateTag
                } catch {
                    throw CatalogQueryError.persistenceFailure
                }
                return TagGroupListItem(
                    id: created.id,
                    displayName: created.displayName,
                    sortOrder: created.sortOrder,
                    isSystem: false
                )
            }
        }
    }

    func renameTagGroup(groupID: UUID, rawName: String, timestampMs: Int64) throws -> TagGroupListItem {
        try CatalogQueryErrorMapping.perform {
            try database.pool.write { db in
                let existing = try fetchExistingGroups(db)
                guard let current = existing.first(where: { $0.id == groupID }) else {
                    throw CatalogQueryError.notFound
                }
                let renamed: TagGroup
                switch TagGroupRules.renameGroup(current, rawName: rawName, existingGroups: existing) {
                case let .success(group):
                    renamed = group
                case .failure(.invalidStateTransition):
                    throw CatalogQueryError.systemGroupProtected
                case let .failure(error):
                    throw mapDomainError(error)
                }
                do {
                    try db.execute(
                        sql: """
                        UPDATE tag_group
                        SET name = ?, updated_at_ms = ?
                        WHERE id = ?
                        """,
                        arguments: [
                            renamed.displayName,
                            timestampMs,
                            CatalogQuerySQLHelpers.lowercaseUUID(groupID),
                        ]
                    )
                } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                    throw CatalogQueryError.duplicateTag
                } catch {
                    throw CatalogQueryError.persistenceFailure
                }
                return TagGroupListItem(
                    id: renamed.id,
                    displayName: renamed.displayName,
                    sortOrder: renamed.sortOrder,
                    isSystem: renamed.isSystem
                )
            }
        }
    }

    func reorderTagGroups(groupIDs: [UUID], timestampMs: Int64) throws -> [TagGroupListItem] {
        try CatalogQueryErrorMapping.perform {
            try database.pool.write { db in
                let existing = try fetchExistingGroups(db)
                let existingIDs = Set(existing.map(\.id))
                guard groupIDs.count == existing.count,
                      Set(groupIDs).count == groupIDs.count,
                      Set(groupIDs) == existingIDs
                else {
                    throw CatalogQueryError.persistenceFailure
                }

                let groupsByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
                let reordered = groupIDs.enumerated().compactMap { offset, groupID -> TagGroup? in
                    guard let group = groupsByID[groupID] else { return nil }
                    return TagGroup(
                        id: group.id,
                        displayName: group.displayName,
                        sortOrder: offset,
                        isSystem: group.isSystem
                    )
                }
                guard reordered.count == existing.count else {
                    throw CatalogQueryError.persistenceFailure
                }

                for group in reordered {
                    try db.execute(
                        sql: """
                        UPDATE tag_group
                        SET sort_order = ?, updated_at_ms = ?
                        WHERE id = ?
                        """,
                        arguments: [
                            group.sortOrder,
                            timestampMs,
                            CatalogQuerySQLHelpers.lowercaseUUID(group.id),
                        ]
                    )
                }

                return reordered.map {
                    TagGroupListItem(
                        id: $0.id,
                        displayName: $0.displayName,
                        sortOrder: $0.sortOrder,
                        isSystem: $0.isSystem
                    )
                }
            }
        }
    }

    func deleteTagGroup(groupID: UUID, timestampMs: Int64) throws {
        try CatalogQueryErrorMapping.perform {
            try database.pool.write { db in
                let existing = try fetchExistingGroups(db)
                guard let current = existing.first(where: { $0.id == groupID }) else {
                    throw CatalogQueryError.notFound
                }
                switch TagGroupRules.deleteGroup(current) {
                case .success:
                    break
                case .failure(.invalidStateTransition):
                    throw CatalogQueryError.systemGroupProtected
                case let .failure(error):
                    throw mapDomainError(error)
                }

                let fallbackGroupID = TagGroupSeed.other.id
                try db.execute(
                    sql: """
                    UPDATE tag
                    SET group_id = ?, updated_at_ms = ?
                    WHERE group_id = ?
                    """,
                    arguments: [
                        CatalogQuerySQLHelpers.lowercaseUUID(fallbackGroupID),
                        timestampMs,
                        CatalogQuerySQLHelpers.lowercaseUUID(groupID),
                    ]
                )
                try db.execute(
                    sql: "DELETE FROM tag_group WHERE id = ?",
                    arguments: [CatalogQuerySQLHelpers.lowercaseUUID(groupID)]
                )
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
                try WorldMapPlaceResolutionService.refreshCanonicalLocations(
                    db,
                    assetIDs: uniqueAssetIDs,
                    nowMs: timestampMs
                )
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
                        INSERT INTO tag (
                            id, name, normalized_name, state, created_at_ms, updated_at_ms, group_id
                        ) VALUES (?, ?, ?, 'active', ?, ?, ?)
                        """,
                        arguments: [
                            CatalogQuerySQLHelpers.lowercaseUUID(tag.id),
                            tag.displayName,
                            tag.normalizedName,
                            timestampMs,
                            timestampMs,
                            TagGroupSeed.classify(displayName: tag.displayName).id.uuidString.lowercased(),
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
        try CatalogQueryErrorMapping.perform {
            try database.pool.write { db in
                try restorePriorStates(in: db, snapshot: snapshot, timestampMs: timestampMs)
            }
        }
    }

    func restorePriorStates(
        in db: Database,
        snapshot: TagMutationPriorStateSnapshot,
        timestampMs: Int64
    ) throws {
        let assetIDs = snapshot.priorStates.map(\.assetID)
        let uniqueAssetIDs = Array(Set(assetIDs))
        guard !uniqueAssetIDs.isEmpty else {
            throw CatalogQueryError.emptySelection
        }
        guard uniqueAssetIDs.count <= CatalogQuerySQLHelpers.maxSelectionSize else {
            throw CatalogQueryError.selectionTooLarge
        }

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
        try WorldMapPlaceResolutionService.refreshCanonicalLocations(
            db,
            assetIDs: uniqueAssetIDs,
            nowMs: timestampMs
        )
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
                try applyBatchDecision(
                    in: db,
                    tagID: tagID,
                    assetIDs: uniqueAssetIDs,
                    decision: decision,
                    timestampMs: timestampMs
                )
            }
        }
    }

    func applyBatchDecision(
        in db: Database,
        tagID: UUID,
        assetIDs: [UUID],
        decision: PersistableTagDecision,
        timestampMs: Int64
    ) throws -> TagMutationResult {
        let uniqueAssetIDs = try validatedUniqueAssetIDs(assetIDs)
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
        try WorldMapPlaceResolutionService.refreshCanonicalLocations(
            db,
            assetIDs: uniqueAssetIDs,
            nowMs: timestampMs
        )
        return TagMutationResult(priorStates: priorStates)
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
        try Row.fetchAll(
            db,
            sql: """
            SELECT tag.id, tag.name, tag.normalized_name, tag.state
            FROM tag
            LEFT JOIN standard_tag_binding binding ON binding.tag_id = tag.id
            WHERE binding.tag_id IS NULL
            """
        ).map { row in
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
            sql: """
            SELECT COUNT(*)
            FROM tag
            LEFT JOIN standard_tag_binding binding ON binding.tag_id = tag.id
            WHERE binding.tag_id IS NULL AND tag.normalized_name = ?
            """,
            arguments: [normalizedName]
        ) ?? 0
        return count > 0
    }

    private func validateStandardOntologyPackage(
        _ package: StandardOntologyPackageInput,
        timestampMs: Int64
    ) throws -> ValidatedStandardOntologyPackage {
        guard timestampMs >= 0,
              isValidStandardField(package.standardPackID, maxLength: 200),
              isValidStandardField(package.standardPackRevision, maxLength: 200),
              isValidStandardField(package.ontologyID, maxLength: 200),
              isValidStandardField(package.ontologyRevision, maxLength: 200),
              isValidStandardField(package.localeRevision, maxLength: 200),
              isValidSHA256(package.manifestSHA256),
              isValidStandardField(package.provider, maxLength: 200),
              isValidStandardField(package.modelRevision, maxLength: 200),
              isValidStandardField(package.preprocessingRevision, maxLength: 200),
              isValidStandardField(package.mappingRevision, maxLength: 200),
              isValidStandardField(package.policyRevision, maxLength: 200),
              isValidSHA256(package.weightsSHA256),
              !package.concepts.isEmpty
        else {
            throw StandardOntologyCatalogError.invalidPackage
        }

        var conceptIDs = Set<String>()
        var concepts: [ValidatedStandardOntologyConcept] = []
        for concept in package.concepts {
            guard isValidStandardField(concept.conceptID, maxLength: 300),
                  conceptIDs.insert(concept.conceptID).inserted,
                  !concept.canonicalName.contains("\0"),
                  concept.canonicalName.count <= 200
            else {
                throw StandardOntologyCatalogError.invalidPackage
            }
            let name: TagNameParts
            switch TagNameNormalizer.validateAndNormalize(concept.canonicalName) {
            case let .success(parts):
                name = parts
            case .failure:
                throw StandardOntologyCatalogError.invalidPackage
            }
            guard name.displayName == concept.canonicalName,
                  name.normalizedName.count <= 200
            else {
                throw StandardOntologyCatalogError.invalidPackage
            }
            concepts.append(
                ValidatedStandardOntologyConcept(
                    conceptID: concept.conceptID,
                    displayName: name.displayName,
                    normalizedName: name.normalizedName
                )
            )
        }

        var edgeKeys = Set<String>()
        var indegree = Dictionary(uniqueKeysWithValues: conceptIDs.map { ($0, 0) })
        var childrenByParent: [String: [String]] = [:]
        for edge in package.edges {
            guard conceptIDs.contains(edge.parentConceptID),
                  conceptIDs.contains(edge.childConceptID),
                  edge.parentConceptID != edge.childConceptID,
                  edgeKeys.insert("\(edge.parentConceptID)\0\(edge.childConceptID)").inserted
            else {
                throw StandardOntologyCatalogError.invalidPackage
            }
            childrenByParent[edge.parentConceptID, default: []].append(edge.childConceptID)
            indegree[edge.childConceptID, default: 0] += 1
        }

        var queue = indegree.filter { $0.value == 0 }.map(\.key)
        var visitedCount = 0
        while let conceptID = queue.popLast() {
            visitedCount += 1
            for child in childrenByParent[conceptID, default: []] {
                indegree[child, default: 0] -= 1
                if indegree[child] == 0 {
                    queue.append(child)
                }
            }
        }
        guard visitedCount == conceptIDs.count else {
            throw StandardOntologyCatalogError.invalidPackage
        }

        return ValidatedStandardOntologyPackage(
            concepts: concepts.sorted { $0.conceptID < $1.conceptID }
        )
    }

    private func isValidStandardField(_ value: String, maxLength: Int) -> Bool {
        !value.isEmpty && value.count <= maxLength && !value.contains("\0")
    }

    private func isValidSHA256(_ value: String) -> Bool {
        let lowercaseHex = Set("0123456789abcdef")
        return value.count == 64 && value.allSatisfy(lowercaseHex.contains)
    }

    private func standardPackageIdentityMatches(
        _ row: Row,
        package: StandardOntologyPackageInput
    ) -> Bool {
        (row["standard_pack_revision"] as String?) == package.standardPackRevision
            && (row["ontology_id"] as String?) == package.ontologyID
            && (row["ontology_revision"] as String?) == package.ontologyRevision
            && (row["locale_revision"] as String?) == package.localeRevision
            && (row["manifest_sha256"] as String?) == package.manifestSHA256
            && (row["provider"] as String?) == package.provider
            && (row["model_revision"] as String?) == package.modelRevision
            && (row["preprocessing_revision"] as String?) == package.preprocessingRevision
            && (row["mapping_revision"] as String?) == package.mappingRevision
            && (row["policy_revision"] as String?) == package.policyRevision
            && (row["weights_sha256"] as String?) == package.weightsSHA256
    }

    private func installedStandardPackageContentsMatch(
        _ db: Database,
        package: StandardOntologyPackageInput,
        concepts: [ValidatedStandardOntologyConcept]
    ) throws -> Bool {
        let installedConcepts = try Row.fetchAll(
            db,
            sql: """
            SELECT concept_id, canonical_name, normalized_name
            FROM ontology_concept
            WHERE ontology_id = ? AND ontology_revision = ?
            ORDER BY concept_id
            """,
            arguments: [package.ontologyID, package.ontologyRevision]
        ).map { row in
            ValidatedStandardOntologyConcept(
                conceptID: row["concept_id"],
                displayName: row["canonical_name"],
                normalizedName: row["normalized_name"]
            )
        }
        guard installedConcepts == concepts else { return false }

        let installedEdges = try Row.fetchAll(
            db,
            sql: """
            SELECT parent_concept_id, child_concept_id
            FROM ontology_edge
            WHERE ontology_id = ? AND ontology_revision = ?
            ORDER BY parent_concept_id, child_concept_id
            """,
            arguments: [package.ontologyID, package.ontologyRevision]
        ).map { row in
            StandardOntologyEdgeInput(
                parentConceptID: row["parent_concept_id"],
                childConceptID: row["child_concept_id"]
            )
        }
        let expectedEdges = package.edges.sorted {
            ($0.parentConceptID, $0.childConceptID) < ($1.parentConceptID, $1.childConceptID)
        }
        return installedEdges == expectedEdges
    }

    private func fetchStandardTags(
        _ db: Database,
        ontologyID: String,
        ontologyRevision: String
    ) throws -> [TagListItem] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT id, name, state, coalesce(group_id, ?) AS group_id
            FROM standard_tag_binding binding
            JOIN tag ON tag.id = binding.tag_id
            JOIN ontology_concept concept
                ON concept.ontology_id = binding.ontology_id
                AND concept.ontology_revision = binding.ontology_revision
                AND concept.concept_id = binding.concept_id
            WHERE binding.ontology_id = ? AND binding.ontology_revision = ?
            ORDER BY concept.normalized_name COLLATE BINARY, tag.id
            """,
            arguments: [
                TagGroupSeed.other.id.uuidString.lowercased(),
                ontologyID,
                ontologyRevision,
            ]
        ).map { row in
            TagListItem(
                id: UUID(uuidString: row["id"])!,
                displayName: row["name"],
                state: TagState(rawValue: row["state"]) ?? .active,
                groupID: UUID(uuidString: row["group_id"]) ?? TagGroupSeed.other.id
            )
        }
    }

    private func standardTagID(ontologyID: String, conceptID: String) -> UUID {
        var bytes = Array(
            SHA256.hash(data: Data("imageall-standard-tag\0\(ontologyID)\0\(conceptID)".utf8)).prefix(16)
        )
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let uuidString = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        return UUID(uuidString: uuidString)!
    }

    private func standardTagStorageKey(tagID: UUID) -> String {
        "__imageall_standard__:\(tagID.uuidString.lowercased())"
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

    private func fetchTagListItem(_ db: Database, tagID: UUID) throws -> TagListItem {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT id, name, state, coalesce(group_id, ?) AS group_id
            FROM tag
            WHERE id = ?
            """,
            arguments: [
                TagGroupSeed.other.id.uuidString.lowercased(),
                CatalogQuerySQLHelpers.lowercaseUUID(tagID),
            ]
        ) else {
            throw CatalogQueryError.notFound
        }
        return TagListItem(
            id: UUID(uuidString: row["id"])!,
            displayName: row["name"],
            state: TagState(rawValue: row["state"]) ?? .active,
            groupID: UUID(uuidString: row["group_id"]) ?? TagGroupSeed.other.id
        )
    }

    private func fetchExistingGroups(_ db: Database) throws -> [TagGroup] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT id, name, sort_order, is_system
            FROM tag_group
            ORDER BY sort_order ASC, id ASC
            """
        ).map { row in
            TagGroup(
                id: UUID(uuidString: row["id"])!,
                displayName: row["name"],
                sortOrder: row["sort_order"],
                isSystem: (row["is_system"] as Int64) != 0
            )
        }
    }

    private func tagExists(_ db: Database, tagID: UUID) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM tag WHERE id = ?)",
            arguments: [CatalogQuerySQLHelpers.lowercaseUUID(tagID)]
        ) ?? false
    }

    private func tagGroupExists(_ db: Database, groupID: UUID) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM tag_group WHERE id = ?)",
            arguments: [CatalogQuerySQLHelpers.lowercaseUUID(groupID)]
        ) ?? false
    }
}

struct ContextualTagFeedService: ContextualTagFeedPort, Sendable {
    static let policyRevision = "context-event-v1"
    static let maximumGroupSize = 24

    let database: CatalogDatabase

    private struct PendingFeedRank {
        let id: UUID
        let affinity: ContextualTagFeedAffinity
        let hasImageModel: Bool
        let acceptedCount: Int
        let candidateCount: Int
        let createdAtMs: Int64

        static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
            if lhs.affinity != rhs.affinity { return lhs.affinity < rhs.affinity }
            if lhs.hasImageModel != rhs.hasImageModel { return !lhs.hasImageModel }
            if lhs.acceptedCount != rhs.acceptedCount {
                return lhs.acceptedCount < rhs.acceptedCount
            }
            if lhs.candidateCount != rhs.candidateCount {
                return lhs.candidateCount > rhs.candidateCount
            }
            if lhs.createdAtMs != rhs.createdAtMs { return lhs.createdAtMs < rhs.createdAtMs }
            return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
    }

    private func scopedTagFilter(
        _ tagIDs: Set<UUID>?,
        column: String
    ) -> (sql: String, arguments: StatementArguments) {
        guard let tagIDs else { return ("", StatementArguments()) }
        let tokens = tagIDs.map(CatalogQuerySQLHelpers.lowercaseUUID).sorted()
        let placeholders = Array(repeating: "?", count: tokens.count).joined(separator: ", ")
        var arguments = StatementArguments()
        for token in tokens { arguments += [token] }
        return ("AND \(column) IN (\(placeholders))", arguments)
    }

    func pendingCount(tagIDs: Set<UUID>?) throws -> Int {
        if let tagIDs, tagIDs.isEmpty { return 0 }
        return try database.pool.read { db in
            let filter = scopedTagFilter(tagIDs, column: "feed.tag_id")
            return try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM contextual_tag_feed feed
                JOIN tag ON tag.id = feed.tag_id AND tag.state = 'active'
                WHERE feed.state = 'pending' \(filter.sql)
                """,
                arguments: filter.arguments
            ) ?? 0
        }
    }

    func fetchPendingGroups(
        limit: Int,
        tagIDs: Set<UUID>?
    ) throws -> [ContextualTagFeedGroup] {
        guard limit > 0, limit <= 100 else {
            throw ContextualTagFeedError.invalidSelection
        }
        if let tagIDs, tagIDs.isEmpty { return [] }
        return try database.pool.read { db in
            let filter = scopedTagFilter(tagIDs, column: "feed.tag_id")
            var arguments = StatementArguments()
            arguments += [CatalogQuerySQLHelpers.lowercaseUUID(TagGroupSeed.other.id)]
            arguments += filter.arguments
            let ranked = try Row.fetchAll(
                db,
                sql: """
                SELECT feed.id, feed.tag_id, feed.created_at_ms,
                       coalesce(tag.group_id, ?) AS group_id,
                       coalesce(tag_group.name, '') AS group_name,
                       (
                           EXISTS (
                               SELECT 1 FROM tag_model
                               WHERE media_kind = 'image' AND tag_id = feed.tag_id
                           )
                           OR EXISTS (
                               SELECT 1 FROM personal_suggestion_model
                               WHERE media_kind = 'image' AND tag_id = feed.tag_id
                           )
                       ) AS has_image_model,
                       coalesce(decision_count.accepted_count, 0) AS accepted_count,
                       coalesce(candidate_count.candidate_count, 0) AS candidate_count
                FROM contextual_tag_feed feed
                JOIN tag ON tag.id = feed.tag_id AND tag.state = 'active'
                LEFT JOIN tag_group ON tag_group.id = tag.group_id
                LEFT JOIN (
                    SELECT tag_id, COUNT(*) AS accepted_count
                    FROM asset_tag_decision
                    WHERE decision = 'accepted'
                    GROUP BY tag_id
                ) decision_count ON decision_count.tag_id = feed.tag_id
                LEFT JOIN (
                    SELECT feed_id, COUNT(*) AS candidate_count
                    FROM contextual_tag_feed_member
                    WHERE role = 'candidate'
                    GROUP BY feed_id
                ) candidate_count ON candidate_count.feed_id = feed.id
                WHERE feed.state = 'pending' \(filter.sql)
                """,
                arguments: arguments
            ).compactMap { row -> PendingFeedRank? in
                guard let id = UUID(uuidString: row["id"]),
                      let groupID = UUID(uuidString: row["group_id"])
                else { return nil }
                let groupName: String = row["group_name"]
                return PendingFeedRank(
                    id: id,
                    affinity: TagGroupSeed.contextualFeedAffinity(
                        groupID: groupID,
                        groupDisplayName: groupName
                    ),
                    hasImageModel: row["has_image_model"],
                    acceptedCount: row["accepted_count"],
                    candidateCount: row["candidate_count"],
                    createdAtMs: row["created_at_ms"]
                )
            }.sorted(by: PendingFeedRank.precedes)
            let ids = ranked.prefix(limit).map(\.id)
            return try ids.compactMap { try fetchGroup(db, feedID: $0) }
        }
    }

    @discardableResult
    func refreshRecentAcceptedAnchors(
        limit: Int,
        tagIDs: Set<UUID>?,
        timestampMs: Int64
    ) throws -> Int {
        guard limit > 0, limit <= 1_000 else {
            throw ContextualTagFeedError.invalidSelection
        }
        if let tagIDs, tagIDs.isEmpty { return 0 }
        let anchors: [(tagID: UUID, assetID: UUID)] = try database.pool.read { db in
            let filter = scopedTagFilter(tagIDs, column: "decision.tag_id")
            var arguments = filter.arguments
            arguments += [limit]
            return try Row.fetchAll(
                db,
                sql: """
                SELECT decision.tag_id, decision.asset_id
                FROM asset_tag_decision decision
                JOIN tag ON tag.id = decision.tag_id AND tag.state = 'active'
                JOIN asset ON asset.id = decision.asset_id
                JOIN source ON source.id = asset.source_id
                WHERE decision.decision = 'accepted'
                  AND asset.locator_state = 'current'
                  AND asset.availability = 'available'
                  AND source.state = 'active'
                  \(filter.sql)
                ORDER BY decision.updated_at_ms DESC, decision.tag_id, decision.asset_id
                LIMIT ?
                """,
                arguments: arguments
            ).compactMap { row -> (tagID: UUID, assetID: UUID)? in
                guard let tagID = UUID(uuidString: row["tag_id"]),
                      let assetID = UUID(uuidString: row["asset_id"])
                else { return nil }
                return (tagID, assetID)
            }
        }
        for anchor in anchors {
            _ = try generate(
                tagID: anchor.tagID,
                anchorAssetID: anchor.assetID,
                timestampMs: timestampMs
            )
        }
        return try pendingCount(tagIDs: tagIDs)
    }

    func dismiss(feedID: UUID, revision: Int, timestampMs: Int64) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE contextual_tag_feed
                SET state = 'dismissed', revision = revision + 1,
                    updated_at_ms = ?, processed_at_ms = ?
                WHERE id = ? AND revision = ? AND state = 'pending'
                """,
                arguments: [
                    timestampMs,
                    timestampMs,
                    feedID.uuidString.lowercased(),
                    revision,
                ]
            )
            guard db.changesCount == 1 else {
                throw ContextualTagFeedError.feedChanged
            }
        }
    }

    func resolve(
        feedID: UUID,
        revision: Int,
        selectedAssetIDs: [UUID],
        decision: PersistableTagDecision,
        timestampMs: Int64
    ) throws -> TagMutationPriorStateSnapshot {
        return try database.pool.write { db in
            guard let feed = try Row.fetchOne(
                db,
                sql: """
                SELECT tag_id, revision, state
                FROM contextual_tag_feed
                WHERE id = ?
                """,
                arguments: [feedID.uuidString.lowercased()]
            ), let tagID = UUID(uuidString: feed["tag_id"]),
               (feed["revision"] as Int) == revision,
               (feed["state"] as String) == ContextualTagFeedState.pending.rawValue
            else {
                throw ContextualTagFeedError.feedChanged
            }
            let candidateTokens = try String.fetchAll(
                db,
                sql: """
                SELECT asset_id FROM contextual_tag_feed_member
                WHERE feed_id = ? AND role = 'candidate'
                ORDER BY rank
                """,
                arguments: [feedID.uuidString.lowercased()]
            )
            let candidateAssetIDs = candidateTokens.compactMap { UUID(uuidString: $0) }
            guard candidateAssetIDs.count == candidateTokens.count,
                  let plan = ContextualTagFeedResolutionPlan.make(
                      orderedCandidateAssetIDs: candidateAssetIDs,
                      selectedAssetIDs: selectedAssetIDs,
                      selectedDecision: decision
                  )
            else {
                throw ContextualTagFeedError.invalidSelection
            }
            for assetToken in candidateTokens {
                let stillUndecided = try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT NOT EXISTS (
                        SELECT 1 FROM asset_tag_decision
                        WHERE tag_id = ? AND asset_id = ?
                    )
                    """,
                    arguments: [tagID.uuidString.lowercased(), assetToken]
                ) ?? false
                guard stillUndecided else {
                    throw ContextualTagFeedError.feedChanged
                }
            }

            let repository = GRDBTagCatalogRepository(database: database)
            var priorStates: [TagMutationPriorState] = []
            if !plan.acceptedAssetIDs.isEmpty {
                let accepted = try repository.applyBatchDecision(
                    in: db,
                    tagID: tagID,
                    assetIDs: plan.acceptedAssetIDs,
                    decision: .accepted,
                    timestampMs: timestampMs
                )
                priorStates.append(contentsOf: accepted.priorStates)
            }
            if !plan.rejectedAssetIDs.isEmpty {
                let rejected = try repository.applyBatchDecision(
                    in: db,
                    tagID: tagID,
                    assetIDs: plan.rejectedAssetIDs,
                    decision: .rejected,
                    timestampMs: timestampMs
                )
                priorStates.append(contentsOf: rejected.priorStates)
            }
            try db.execute(
                sql: """
                UPDATE contextual_tag_feed
                SET state = 'resolved', revision = revision + 1,
                    updated_at_ms = ?, processed_at_ms = ?
                WHERE id = ? AND revision = ? AND state = 'pending'
                """,
                arguments: [
                    timestampMs,
                    timestampMs,
                    feedID.uuidString.lowercased(),
                    revision,
                ]
            )
            guard db.changesCount == 1 else {
                throw ContextualTagFeedError.feedChanged
            }
            return TagMutationPriorStateSnapshot(
                tagID: tagID,
                priorStates: priorStates
            )
        }
    }

    func undoResolution(
        _ undo: ContextualTagFeedResolutionUndo,
        timestampMs: Int64
    ) throws {
        let assetIDs = undo.snapshot.priorStates.map(\.assetID)
        let uniqueAssetIDs = Set(assetIDs)
        let selectedAssetIDs = Set(undo.selectedAssetIDs)
        guard !assetIDs.isEmpty,
              uniqueAssetIDs.count == assetIDs.count,
              !selectedAssetIDs.isEmpty,
              selectedAssetIDs.count == undo.selectedAssetIDs.count,
              selectedAssetIDs.isSubset(of: uniqueAssetIDs)
        else {
            throw ContextualTagFeedError.invalidSelection
        }
        try database.pool.write { db in
            guard let feed = try Row.fetchOne(
                db,
                sql: """
                SELECT tag_id, revision, state, processed_at_ms
                FROM contextual_tag_feed
                WHERE id = ?
                """,
                arguments: [CatalogQuerySQLHelpers.lowercaseUUID(undo.feedID)]
            ), let tagID = UUID(uuidString: feed["tag_id"]),
               tagID == undo.snapshot.tagID,
               (feed["revision"] as Int) == undo.resolvedRevision,
               (feed["state"] as String) == ContextualTagFeedState.resolved.rawValue,
               (feed["processed_at_ms"] as Int64?) == undo.resolvedAtMs
            else {
                throw ContextualTagFeedError.feedChanged
            }

            let candidateTokens = Set(try String.fetchAll(
                db,
                sql: """
                SELECT asset_id FROM contextual_tag_feed_member
                WHERE feed_id = ? AND role = 'candidate'
                """,
                arguments: [CatalogQuerySQLHelpers.lowercaseUUID(undo.feedID)]
            ))
            let mutationTokens = Set(uniqueAssetIDs.map(CatalogQuerySQLHelpers.lowercaseUUID))
            let selectedTokens = Set(selectedAssetIDs.map(CatalogQuerySQLHelpers.lowercaseUUID))
            guard mutationTokens == candidateTokens else {
                throw ContextualTagFeedError.feedChanged
            }

            for assetToken in mutationTokens {
                let expectedDecision = selectedTokens.contains(assetToken)
                    ? undo.selectedDecision
                    : oppositeDecision(undo.selectedDecision)
                guard let decision = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT decision, updated_at_ms
                    FROM asset_tag_decision
                    WHERE tag_id = ? AND asset_id = ?
                    """,
                    arguments: [CatalogQuerySQLHelpers.lowercaseUUID(tagID), assetToken]
                ),
                    (decision["decision"] as String) == expectedDecision.rawValue,
                    (decision["updated_at_ms"] as Int64) == undo.resolvedAtMs
                else {
                    throw ContextualTagFeedError.feedChanged
                }
            }

            try GRDBTagCatalogRepository(database: database).restorePriorStates(
                in: db,
                snapshot: undo.snapshot,
                timestampMs: timestampMs
            )
            try db.execute(
                sql: """
                UPDATE contextual_tag_feed
                SET state = 'pending', revision = revision + 1,
                    updated_at_ms = ?, processed_at_ms = NULL
                WHERE id = ? AND revision = ? AND state = 'resolved'
                  AND processed_at_ms = ?
                """,
                arguments: [
                    timestampMs,
                    CatalogQuerySQLHelpers.lowercaseUUID(undo.feedID),
                    undo.resolvedRevision,
                    undo.resolvedAtMs,
                ]
            )
            guard db.changesCount == 1 else {
                throw ContextualTagFeedError.feedChanged
            }
        }
    }

    private func oppositeDecision(_ decision: PersistableTagDecision) -> PersistableTagDecision {
        switch decision {
        case .accepted: .rejected
        case .rejected: .accepted
        }
    }

    func generate(
        tagID: UUID,
        anchorAssetID: UUID,
        timestampMs: Int64
    ) throws -> ContextualTagFeedGroup? {
        try database.pool.write { db in
            try retireStalePendingFeeds(db, timestampMs: timestampMs)
            guard let anchor = try fetchAnchor(
                db,
                tagID: tagID,
                anchorAssetID: anchorAssetID
            ) else {
                return nil
            }
            let neighborhood = try fetchNeighborhood(db, anchor: anchor, tagID: tagID)
            let ranked = rankedMembers(anchor: anchor, candidates: neighborhood)
            guard ranked.count > 1 else { return nil }

            let groupKey = stableGroupKey(
                tagID: tagID,
                sourceID: anchor.sourceID,
                assetIDs: ranked.map(\.row.assetID)
            )
            if let existingIDRaw = try String.fetchOne(
                db,
                sql: """
                SELECT id FROM contextual_tag_feed
                WHERE tag_id = ? AND source_id = ? AND group_key = ? AND policy_revision = ?
                """,
                arguments: [
                    tagID.uuidString.lowercased(),
                    anchor.sourceID.uuidString.lowercased(),
                    groupKey,
                    Self.policyRevision,
                ]
            ), let existingID = UUID(uuidString: existingIDRaw) {
                return try fetchGroup(db, feedID: existingID)
            }
            for candidate in ranked where candidate.row.assetID != anchorAssetID {
                if let overlappingIDRaw = try String.fetchOne(
                    db,
                    sql: """
                    SELECT feed.id
                    FROM contextual_tag_feed feed
                    JOIN contextual_tag_feed_member member ON member.feed_id = feed.id
                    WHERE feed.tag_id = ?
                      AND feed.source_id = ?
                      AND feed.policy_revision = ?
                      AND feed.state = 'pending'
                      AND member.asset_id = ?
                    ORDER BY feed.created_at_ms, feed.id
                    LIMIT 1
                    """,
                    arguments: [
                        tagID.uuidString.lowercased(),
                        anchor.sourceID.uuidString.lowercased(),
                        Self.policyRevision,
                        candidate.row.assetID.uuidString.lowercased(),
                    ]
                ), let overlappingID = UUID(uuidString: overlappingIDRaw) {
                    return try fetchGroup(db, feedID: overlappingID)
                }
            }

            let feedID = UUID()
            try db.execute(
                sql: """
                INSERT INTO contextual_tag_feed (
                    id, tag_id, anchor_asset_id, source_id, group_key,
                    policy_revision, state, revision, created_at_ms, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, 'pending', 1, ?, ?)
                """,
                arguments: [
                    feedID.uuidString.lowercased(),
                    tagID.uuidString.lowercased(),
                    anchorAssetID.uuidString.lowercased(),
                    anchor.sourceID.uuidString.lowercased(),
                    groupKey,
                    Self.policyRevision,
                    timestampMs,
                    timestampMs,
                ]
            )
            for (rank, candidate) in ranked.enumerated() {
                let role: ContextualTagFeedMemberRole = candidate.row.assetID == anchorAssetID
                    ? .anchor
                    : .candidate
                let evidenceMask = candidate.evidence.reduce(0) { $0 | $1.kind.bit }
                try db.execute(
                    sql: """
                    INSERT INTO contextual_tag_feed_member (
                        feed_id, asset_id, role, rank, evidence_mask
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        feedID.uuidString.lowercased(),
                        candidate.row.assetID.uuidString.lowercased(),
                        role.rawValue,
                        rank,
                        evidenceMask,
                    ]
                )
                for evidence in candidate.evidence {
                    try db.execute(
                        sql: """
                        INSERT INTO contextual_tag_feed_evidence (
                            feed_id, asset_id, kind, strength, delta_ms,
                            distance_m, sequence_offset, provenance
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            feedID.uuidString.lowercased(),
                            candidate.row.assetID.uuidString.lowercased(),
                            evidence.kind.rawValue,
                            evidence.strength,
                            evidence.deltaMs,
                            evidence.distanceM,
                            evidence.sequenceOffset,
                            evidence.provenance,
                        ]
                    )
                }
            }
            return try fetchGroup(db, feedID: feedID)
        }
    }

    private func retireStalePendingFeeds(_ db: Database, timestampMs: Int64) throws {
        try db.execute(
            sql: """
            UPDATE contextual_tag_feed
            SET state = 'resolved', revision = revision + 1,
                updated_at_ms = ?, processed_at_ms = ?
            WHERE state = 'pending'
              AND EXISTS (
                  SELECT 1
                  FROM contextual_tag_feed_member member
                  JOIN asset_tag_decision decision
                    ON decision.asset_id = member.asset_id
                   AND decision.tag_id = contextual_tag_feed.tag_id
                  WHERE member.feed_id = contextual_tag_feed.id
                    AND member.role = 'candidate'
              )
            """,
            arguments: [timestampMs, timestampMs]
        )
    }

    private struct AssetContext: Sendable {
        let assetID: UUID
        let sourceID: UUID
        let sourceKind: SourceKind
        let locatorKind: AssetLocatorKind
        let relativePath: String?
        let fileName: String?
        let mediaKind: MediaKind
        let mediaCreatedAtMs: Int64?
        let latitude: Double?
        let longitude: Double?
        let locationProvenance: String?

        var parentRelativePath: String? {
            guard let relativePath, locatorKind == .file else { return nil }
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count > 1 else { return "" }
            return components.dropLast().joined(separator: "/")
        }
    }

    private struct RankedContext {
        let row: AssetContext
        let evidence: [ContextualTagFeedEvidence]
        let sequence: Int?
    }

    private struct FilenameSignature: Equatable {
        let skeleton: String
        let sequence: Int
        let sequenceWidth: Int
    }

    private func fetchAnchor(
        _ db: Database,
        tagID: UUID,
        anchorAssetID: UUID
    ) throws -> AssetContext? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT asset.id, asset.source_id, source.kind AS source_kind,
                   asset.locator_kind, asset.relative_path, asset.file_name,
                   asset.media_kind, asset.media_created_at_ms,
                   location.latitude, location.longitude,
                   location.source_kind AS location_source_kind
            FROM asset
            JOIN source ON source.id = asset.source_id
            JOIN asset_tag_decision decision
              ON decision.asset_id = asset.id
             AND decision.tag_id = ?
             AND decision.decision = 'accepted'
            JOIN tag ON tag.id = decision.tag_id AND tag.state = 'active'
            LEFT JOIN asset_location location ON location.asset_id = asset.id
            WHERE asset.id = ?
              AND asset.locator_state = 'current'
              AND asset.availability = 'available'
              AND source.state = 'active'
            """,
            arguments: [tagID.uuidString.lowercased(), anchorAssetID.uuidString.lowercased()]
        ) else {
            return nil
        }
        return decodeAssetContext(row)
    }

    private func fetchNeighborhood(
        _ db: Database,
        anchor: AssetContext,
        tagID: UUID
    ) throws -> [AssetContext] {
        var neighborhoodSQL = "0"
        var neighborhoodArguments = StatementArguments()
        if let parent = anchor.parentRelativePath {
            if parent.isEmpty {
                neighborhoodSQL = "(asset.locator_kind = 'file' AND instr(asset.relative_path, '/') = 0)"
            } else {
                let prefix = parent + "/"
                neighborhoodSQL = """
                (asset.locator_kind = 'file'
                 AND substr(asset.relative_path, 1, ?) = ?
                 AND instr(substr(asset.relative_path, ?), '/') = 0)
                """
                neighborhoodArguments += [prefix.count, prefix, prefix.count + 1]
            }
        }
        if let createdAt = anchor.mediaCreatedAtMs {
            if neighborhoodSQL == "0" {
                neighborhoodSQL = "(asset.media_created_at_ms BETWEEN ? AND ?)"
            } else {
                neighborhoodSQL += " OR (asset.media_created_at_ms BETWEEN ? AND ?)"
            }
            neighborhoodArguments += [createdAt - 86_400_000, createdAt + 86_400_000]
        }
        guard neighborhoodSQL != "0" else { return [] }

        var arguments = StatementArguments()
        arguments += [anchor.sourceID.uuidString.lowercased(), anchor.assetID.uuidString.lowercased()]
        arguments += neighborhoodArguments
        arguments += [tagID.uuidString.lowercased()]
        return try Row.fetchAll(
            db,
            sql: """
            SELECT asset.id, asset.source_id, source.kind AS source_kind,
                   asset.locator_kind, asset.relative_path, asset.file_name,
                   asset.media_kind, asset.media_created_at_ms,
                   location.latitude, location.longitude,
                   location.source_kind AS location_source_kind
            FROM asset
            JOIN source ON source.id = asset.source_id
            LEFT JOIN asset_location location ON location.asset_id = asset.id
            WHERE asset.source_id = ?
              AND asset.id != ?
              AND asset.locator_state = 'current'
              AND asset.availability = 'available'
              AND source.state = 'active'
              AND (\(neighborhoodSQL))
              AND NOT EXISTS (
                  SELECT 1 FROM asset_tag_decision decision
                  WHERE decision.asset_id = asset.id AND decision.tag_id = ?
              )
            """,
            arguments: arguments
        ).compactMap(decodeAssetContext)
    }

    private func decodeAssetContext(_ row: Row) -> AssetContext? {
        guard let assetID = UUID(uuidString: row["id"]),
              let sourceID = UUID(uuidString: row["source_id"]),
              let sourceKind = SourceKind(rawValue: row["source_kind"]),
              let locatorKind = AssetLocatorKind(rawValue: row["locator_kind"])
        else {
            return nil
        }
        let mediaKindRaw: String? = row["media_kind"]
        return AssetContext(
            assetID: assetID,
            sourceID: sourceID,
            sourceKind: sourceKind,
            locatorKind: locatorKind,
            relativePath: row["relative_path"],
            fileName: row["file_name"],
            mediaKind: mediaKindRaw.flatMap(MediaKind.init(rawValue:)) ?? .image,
            mediaCreatedAtMs: row["media_created_at_ms"],
            latitude: row["latitude"],
            longitude: row["longitude"],
            locationProvenance: row["location_source_kind"]
        )
    }

    private func rankedMembers(
        anchor: AssetContext,
        candidates: [AssetContext]
    ) -> [RankedContext] {
        let filenameComponent = filenameSequenceComponent(anchor: anchor, candidates: candidates)
        var included: [RankedContext] = candidates.compactMap { candidate in
            let sequence = filenameComponent[candidate.assetID]
            let timeDelta = timeDelta(anchor.mediaCreatedAtMs, candidate.mediaCreatedAtMs)
            let distance = distanceMeters(anchor: anchor, candidate: candidate)
            let isFilenameSequence = sequence != nil
            let matchesTimeAndSpace = timeDelta.map { $0 <= 30 * 60_000 } == true
                && distance.map { $0 <= 5_000 } == true
            let matchesTimeAndFolderSource = anchor.sourceKind == .folder
                && timeDelta.map { $0 <= 10 * 60_000 } == true
            let matchesDayAndNearby = sameUTCDay(
                anchor.mediaCreatedAtMs,
                candidate.mediaCreatedAtMs
            ) && distance.map { $0 <= 500 } == true
            guard isFilenameSequence
                    || matchesTimeAndSpace
                    || matchesTimeAndFolderSource
                    || matchesDayAndNearby
            else {
                return nil
            }

            var evidence: [ContextualTagFeedEvidence] = []
            if let sequence {
                evidence.append(ContextualTagFeedEvidence(
                    kind: .filenameSequence,
                    strength: 1,
                    deltaMs: nil,
                    distanceM: nil,
                    sequenceOffset: sequence,
                    provenance: "catalogFileName"
                ))
            }
            if let timeDelta, timeDelta <= 86_400_000 {
                evidence.append(ContextualTagFeedEvidence(
                    kind: .captureTime,
                    strength: max(0, 1 - Double(timeDelta) / 86_400_000),
                    deltaMs: timeDelta,
                    distanceM: nil,
                    sequenceOffset: nil,
                    provenance: "mediaCreatedAt"
                ))
            }
            if let distance, distance <= 5_000 {
                evidence.append(ContextualTagFeedEvidence(
                    kind: .spatialProximity,
                    strength: max(0, 1 - distance / 5_000),
                    deltaMs: nil,
                    distanceM: distance,
                    sequenceOffset: nil,
                    provenance: candidate.locationProvenance
                ))
            }
            evidence.append(ContextualTagFeedEvidence(
                kind: .sourceContext,
                strength: anchor.sourceKind == .folder ? 0.5 : 0.25,
                deltaMs: nil,
                distanceM: nil,
                sequenceOffset: nil,
                provenance: anchor.sourceKind.rawValue
            ))
            return RankedContext(row: candidate, evidence: evidence, sequence: sequence)
        }

        included.sort { lhs, rhs in
            switch (lhs.row.mediaCreatedAtMs, rhs.row.mediaCreatedAtMs) {
            case let (left?, right?) where left != right:
                return left < right
            default:
                if let left = lhs.sequence, let right = rhs.sequence, left != right {
                    return left < right
                }
                return lhs.row.assetID.uuidString.lowercased()
                    < rhs.row.assetID.uuidString.lowercased()
            }
        }
        let anchorRanked = RankedContext(row: anchor, evidence: [], sequence: 0)
        included.append(anchorRanked)
        included.sort { lhs, rhs in
            switch (lhs.row.mediaCreatedAtMs, rhs.row.mediaCreatedAtMs) {
            case let (left?, right?) where left != right:
                return left < right
            default:
                if let left = lhs.sequence, let right = rhs.sequence, left != right {
                    return left < right
                }
                return lhs.row.assetID.uuidString.lowercased()
                    < rhs.row.assetID.uuidString.lowercased()
            }
        }
        guard included.count > Self.maximumGroupSize else { return included }
        let nearest = included.sorted {
            let lhsTime = timeDelta(anchor.mediaCreatedAtMs, $0.row.mediaCreatedAtMs) ?? Int64.max
            let rhsTime = timeDelta(anchor.mediaCreatedAtMs, $1.row.mediaCreatedAtMs) ?? Int64.max
            if lhsTime != rhsTime { return lhsTime < rhsTime }
            let lhsSequence = abs($0.sequence ?? Int.max)
            let rhsSequence = abs($1.sequence ?? Int.max)
            if lhsSequence != rhsSequence { return lhsSequence < rhsSequence }
            return $0.row.assetID.uuidString.lowercased() < $1.row.assetID.uuidString.lowercased()
        }.prefix(Self.maximumGroupSize)
        return nearest.sorted { lhs, rhs in
            let leftTime = lhs.row.mediaCreatedAtMs ?? Int64.max
            let rightTime = rhs.row.mediaCreatedAtMs ?? Int64.max
            if leftTime != rightTime { return leftTime < rightTime }
            return (lhs.sequence ?? Int.max) < (rhs.sequence ?? Int.max)
        }
    }

    private func filenameSequenceComponent(
        anchor: AssetContext,
        candidates: [AssetContext]
    ) -> [UUID: Int] {
        guard let anchorName = anchor.fileName,
              let anchorSignature = filenameSignature(anchorName),
              let parent = anchor.parentRelativePath
        else {
            return [:]
        }
        var entries: [(id: UUID, sequence: Int)] = [(anchor.assetID, anchorSignature.sequence)]
        for candidate in candidates where candidate.parentRelativePath == parent {
            guard let name = candidate.fileName,
                  let signature = filenameSignature(name),
                  signature.skeleton == anchorSignature.skeleton,
                  signature.sequenceWidth == anchorSignature.sequenceWidth
            else {
                continue
            }
            entries.append((candidate.assetID, signature.sequence))
        }
        entries.sort {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
        }
        guard let anchorIndex = entries.firstIndex(where: { $0.id == anchor.assetID }) else {
            return [:]
        }
        var lower = anchorIndex
        while lower > 0,
              entries[lower].sequence - entries[lower - 1].sequence <= 3
        {
            lower -= 1
        }
        var upper = anchorIndex
        while upper + 1 < entries.count,
              entries[upper + 1].sequence - entries[upper].sequence <= 3
        {
            upper += 1
        }
        return Dictionary(uniqueKeysWithValues: entries[lower ... upper].map {
            ($0.id, $0.sequence - anchorSignature.sequence)
        })
    }

    private func filenameSignature(_ fileName: String) -> FilenameSignature? {
        let baseName = (fileName as NSString).deletingPathExtension
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let characters = Array(baseName)
        var digitRanges: [Range<Int>] = []
        var index = 0
        while index < characters.count {
            if characters[index].isNumber {
                let start = index
                while index < characters.count, characters[index].isNumber {
                    index += 1
                }
                digitRanges.append(start ..< index)
            } else {
                index += 1
            }
        }
        guard let sequenceRange = digitRanges.last,
              let sequence = Int(String(characters[sequenceRange]))
        else {
            return nil
        }
        var skeleton = ""
        index = 0
        while index < characters.count {
            if characters[index].isNumber {
                skeleton.append("#")
                while index < characters.count, characters[index].isNumber { index += 1 }
            } else {
                let character = characters[index]
                if character.isLetter { skeleton.append(character) }
                index += 1
            }
        }
        guard !skeleton.isEmpty else { return nil }
        return FilenameSignature(
            skeleton: skeleton,
            sequence: sequence,
            sequenceWidth: sequenceRange.count
        )
    }

    private func timeDelta(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        guard let lhs, let rhs else { return nil }
        let (delta, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard !overflow, delta != Int64.min else { return nil }
        return abs(delta)
    }

    private func sameUTCDay(_ lhs: Int64?, _ rhs: Int64?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs / 86_400_000 == rhs / 86_400_000
    }

    private func distanceMeters(anchor: AssetContext, candidate: AssetContext) -> Double? {
        guard let latitude1 = anchor.latitude,
              let longitude1 = anchor.longitude,
              let latitude2 = candidate.latitude,
              let longitude2 = candidate.longitude
        else {
            return nil
        }
        let degreesToRadians = Double.pi / 180
        let phi1 = latitude1 * degreesToRadians
        let phi2 = latitude2 * degreesToRadians
        let deltaPhi = (latitude2 - latitude1) * degreesToRadians
        let deltaLambda = (longitude2 - longitude1) * degreesToRadians
        let a = sin(deltaPhi / 2) * sin(deltaPhi / 2)
            + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
        return 6_371_000 * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    private func stableGroupKey(tagID: UUID, sourceID: UUID, assetIDs: [UUID]) -> String {
        let raw = ([
            Self.policyRevision,
            tagID.uuidString.lowercased(),
            sourceID.uuidString.lowercased(),
        ] + assetIDs.map { $0.uuidString.lowercased() }.sorted()).joined(separator: "|")
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func fetchGroup(_ db: Database, feedID: UUID) throws -> ContextualTagFeedGroup? {
        guard let feed = try Row.fetchOne(
            db,
            sql: """
            SELECT feed.id, feed.tag_id, tag.name AS tag_name,
                   feed.anchor_asset_id, feed.source_id, feed.state,
                   feed.revision, feed.policy_revision
            FROM contextual_tag_feed feed
            JOIN tag ON tag.id = feed.tag_id
            WHERE feed.id = ?
            """,
            arguments: [feedID.uuidString.lowercased()]
        ), let tagID = UUID(uuidString: feed["tag_id"]),
           let anchorAssetID = UUID(uuidString: feed["anchor_asset_id"]),
           let sourceID = UUID(uuidString: feed["source_id"]),
           let state = ContextualTagFeedState(rawValue: feed["state"])
        else {
            return nil
        }
        let memberRows = try Row.fetchAll(
            db,
            sql: """
            SELECT member.asset_id, member.role, member.rank,
                   asset.file_name, asset.media_kind, asset.media_created_at_ms
            FROM contextual_tag_feed_member member
            JOIN asset ON asset.id = member.asset_id
            WHERE member.feed_id = ?
            ORDER BY member.rank
            """,
            arguments: [feedID.uuidString.lowercased()]
        )
        let evidenceRows = try Row.fetchAll(
            db,
            sql: """
            SELECT asset_id, kind, strength, delta_ms, distance_m,
                   sequence_offset, provenance
            FROM contextual_tag_feed_evidence
            WHERE feed_id = ?
            ORDER BY asset_id, kind
            """,
            arguments: [feedID.uuidString.lowercased()]
        )
        var evidenceByAssetID: [UUID: [ContextualTagFeedEvidence]] = [:]
        for row in evidenceRows {
            guard let assetID = UUID(uuidString: row["asset_id"]),
                  let kind = ContextualTagFeedEvidenceKind(rawValue: row["kind"])
            else { continue }
            evidenceByAssetID[assetID, default: []].append(ContextualTagFeedEvidence(
                kind: kind,
                strength: row["strength"],
                deltaMs: row["delta_ms"],
                distanceM: row["distance_m"],
                sequenceOffset: row["sequence_offset"],
                provenance: row["provenance"]
            ))
        }
        let members = memberRows.compactMap { row -> ContextualTagFeedMember? in
            guard let assetID = UUID(uuidString: row["asset_id"]),
                  let role = ContextualTagFeedMemberRole(rawValue: row["role"])
            else { return nil }
            let mediaKindRaw: String? = row["media_kind"]
            return ContextualTagFeedMember(
                assetID: assetID,
                role: role,
                rank: row["rank"],
                fileName: row["file_name"],
                mediaKind: mediaKindRaw.flatMap(MediaKind.init(rawValue:)) ?? .image,
                mediaCreatedAtMs: row["media_created_at_ms"],
                evidence: evidenceByAssetID[assetID] ?? []
            )
        }
        return ContextualTagFeedGroup(
            id: feedID,
            tagID: tagID,
            tagDisplayName: feed["tag_name"],
            anchorAssetID: anchorAssetID,
            sourceID: sourceID,
            state: state,
            revision: feed["revision"],
            policyRevision: feed["policy_revision"],
            members: members
        )
    }
}

private struct ValidatedStandardOntologyPackage {
    let concepts: [ValidatedStandardOntologyConcept]
}

private struct ValidatedStandardOntologyConcept: Equatable {
    let conceptID: String
    let displayName: String
    let normalizedName: String
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
