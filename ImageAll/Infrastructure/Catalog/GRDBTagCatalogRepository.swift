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
