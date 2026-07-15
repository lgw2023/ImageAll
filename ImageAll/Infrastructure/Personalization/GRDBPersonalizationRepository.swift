import Foundation
import GRDB

struct GRDBPersonalizationRepository: PersonalizationCatalogPort, Sendable {
    let database: CatalogDatabase

    func registerFeature(_ registration: FeatureRegistration) throws {
        guard registration.identity.provider == PersonalizationConstants.provider,
              registration.identity.requestRevision > 0,
              registration.identity.preprocessingRevision > 0,
              registration.identity.contentRevision > 0,
              registration.elementCount > 0,
              registration.byteCount == registration.elementCount * MemoryLayout<Float>.size,
              registration.vectorSHA256.count == 32,
              registration.createdAtMs >= 0,
              Self.isSafeCacheKey(registration.cacheKey)
        else {
            throw PersonalizationCatalogError.invalidInput
        }

        do {
            try database.pool.write { db in
                guard let contentRevision = try Int.fetchOne(
                    db,
                    sql: "SELECT content_revision FROM asset WHERE id = ?",
                    arguments: [Self.uuid(registration.identity.assetID)]
                ) else {
                    throw PersonalizationCatalogError.notFound
                }
                guard contentRevision == registration.identity.contentRevision else {
                    throw PersonalizationCatalogError.staleAssetRevision
                }

                try db.execute(
                    sql: """
                    INSERT INTO feature (
                        asset_id, provider, request_revision, preprocessing_revision,
                        content_revision, element_type, element_count, byte_count,
                        vector_sha256, cache_key, created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, 'float32', ?, ?, ?, ?, ?)
                    ON CONFLICT (
                        asset_id, provider, request_revision, preprocessing_revision, content_revision
                    ) DO UPDATE SET
                        element_type = excluded.element_type,
                        element_count = excluded.element_count,
                        byte_count = excluded.byte_count,
                        vector_sha256 = excluded.vector_sha256,
                        cache_key = excluded.cache_key,
                        created_at_ms = excluded.created_at_ms
                    """,
                    arguments: [
                        Self.uuid(registration.identity.assetID),
                        registration.identity.provider,
                        registration.identity.requestRevision,
                        registration.identity.preprocessingRevision,
                        registration.identity.contentRevision,
                        registration.elementCount,
                        registration.byteCount,
                        registration.vectorSHA256,
                        registration.cacheKey,
                        registration.createdAtMs,
                    ]
                )
            }
        } catch let error as PersonalizationCatalogError {
            throw error
        } catch {
            throw PersonalizationCatalogError.persistenceFailure
        }
    }

    func featureRegistration(identity: FeatureIdentity) throws -> FeatureRegistration? {
        do {
            return try database.pool.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT element_count, byte_count, vector_sha256, cache_key, created_at_ms
                    FROM feature
                    WHERE asset_id = ?
                        AND provider = ?
                        AND request_revision = ?
                        AND preprocessing_revision = ?
                        AND content_revision = ?
                    """,
                    arguments: [
                        Self.uuid(identity.assetID),
                        identity.provider,
                        identity.requestRevision,
                        identity.preprocessingRevision,
                        identity.contentRevision,
                    ]
                ) else {
                    return nil
                }
                return FeatureRegistration(
                    identity: identity,
                    elementCount: row["element_count"],
                    byteCount: row["byte_count"],
                    vectorSHA256: row["vector_sha256"],
                    cacheKey: row["cache_key"],
                    createdAtMs: row["created_at_ms"]
                )
            }
        } catch {
            throw PersonalizationCatalogError.persistenceFailure
        }
    }

    func publishModelRevision(_ registration: ModelRevisionRegistration) throws {
        let positives = registration.samples.filter { $0.role == .positive }
        let negatives = registration.samples.filter { $0.role == .negative }
        guard registration.revision > 0,
              registration.threshold.isFinite,
              !positives.isEmpty,
              !negatives.isEmpty,
              registration.neighborCount > 0,
              registration.neighborCount <= positives.count,
              registration.neighborCount <= negatives.count,
              registration.sampleBudgetPerRole >= positives.count,
              registration.sampleBudgetPerRole >= negatives.count,
              registration.createdAtMs >= 0,
              Set(registration.samples.map(\.identity.assetID)).count == registration.samples.count,
              Self.hasContiguousRanks(positives),
              Self.hasContiguousRanks(negatives),
              registration.samples.allSatisfy({ sample in
                  sample.identity.provider == PersonalizationConstants.provider
                      && sample.identity.requestRevision == PersonalizationConstants.requestRevision
                      && sample.identity.preprocessingRevision == PersonalizationConstants.preprocessingRevision
              })
        else {
            throw PersonalizationCatalogError.invalidInput
        }

        do {
            try database.pool.write { db in
                guard let tagState = try String.fetchOne(
                    db,
                    sql: "SELECT state FROM tag WHERE id = ?",
                    arguments: [Self.uuid(registration.tagID)]
                ) else {
                    throw PersonalizationCatalogError.notFound
                }
                guard tagState == TagState.active.rawValue else {
                    throw PersonalizationCatalogError.archivedTag
                }

                if let current = try Int.fetchOne(
                    db,
                    sql: "SELECT current_revision FROM tag_model WHERE tag_id = ?",
                    arguments: [Self.uuid(registration.tagID)]
                ), registration.revision <= current {
                    throw PersonalizationCatalogError.staleModelRevision
                }

                for sample in registration.samples {
                    guard try Self.sampleIsCurrentAndEligible(db, tagID: registration.tagID, sample: sample) else {
                        throw PersonalizationCatalogError.missingFeature
                    }
                }

                try db.execute(
                    sql: """
                    INSERT INTO tag_model_revision (
                        tag_id, revision, provider, request_revision, preprocessing_revision,
                        threshold, positive_count, negative_count, neighbor_count,
                        sample_budget_per_role, created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        Self.uuid(registration.tagID),
                        registration.revision,
                        PersonalizationConstants.provider,
                        PersonalizationConstants.requestRevision,
                        PersonalizationConstants.preprocessingRevision,
                        registration.threshold,
                        positives.count,
                        negatives.count,
                        registration.neighborCount,
                        registration.sampleBudgetPerRole,
                        registration.createdAtMs,
                    ]
                )

                for sample in registration.samples {
                    try db.execute(
                        sql: """
                        INSERT INTO tag_model_sample (
                            tag_id, model_revision, asset_id, content_revision, role, rank,
                            provider, request_revision, preprocessing_revision
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            Self.uuid(registration.tagID),
                            registration.revision,
                            Self.uuid(sample.identity.assetID),
                            sample.identity.contentRevision,
                            sample.role.rawValue,
                            sample.rank,
                            sample.identity.provider,
                            sample.identity.requestRevision,
                            sample.identity.preprocessingRevision,
                        ]
                    )
                }

                try db.execute(
                    sql: """
                    INSERT INTO tag_model (tag_id, current_revision, updated_at_ms)
                    VALUES (?, ?, ?)
                    ON CONFLICT(tag_id) DO UPDATE SET
                        current_revision = excluded.current_revision,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                    arguments: [
                        Self.uuid(registration.tagID),
                        registration.revision,
                        registration.createdAtMs,
                    ]
                )
            }
        } catch let error as PersonalizationCatalogError {
            throw error
        } catch {
            throw PersonalizationCatalogError.persistenceFailure
        }
    }

    func replacePredictions(
        tagID: UUID,
        modelRevision: Int,
        candidateAssetIDs: [UUID],
        predictions: [PredictionRegistration],
        createdAtMs: Int64
    ) throws {
        let uniqueCandidates = Array(Set(candidateAssetIDs))
        let candidateSet = Set(uniqueCandidates)
        guard modelRevision > 0,
              !uniqueCandidates.isEmpty,
              uniqueCandidates.count <= PersonalizationConstants.maximumCandidateCount,
              createdAtMs >= 0,
              Set(predictions.map(\.assetID)).count == predictions.count,
              predictions.allSatisfy({ candidateSet.contains($0.assetID) && $0.contentRevision > 0 && $0.score.isFinite })
        else {
            throw PersonalizationCatalogError.invalidInput
        }

        do {
            try database.pool.write { db in
                guard let state = try String.fetchOne(
                    db,
                    sql: "SELECT state FROM tag WHERE id = ?",
                    arguments: [Self.uuid(tagID)]
                ) else {
                    throw PersonalizationCatalogError.notFound
                }
                guard state == TagState.active.rawValue else {
                    throw PersonalizationCatalogError.archivedTag
                }
                guard try Int.fetchOne(
                    db,
                    sql: "SELECT current_revision FROM tag_model WHERE tag_id = ?",
                    arguments: [Self.uuid(tagID)]
                ) == modelRevision else {
                    throw PersonalizationCatalogError.staleModelRevision
                }

                for assetID in uniqueCandidates {
                    try db.execute(
                        sql: "DELETE FROM prediction WHERE asset_id = ? AND tag_id = ? AND model_revision = ?",
                        arguments: [Self.uuid(assetID), Self.uuid(tagID), modelRevision]
                    )
                }

                for prediction in predictions {
                    guard let currentRevision = try Int.fetchOne(
                        db,
                        sql: "SELECT content_revision FROM asset WHERE id = ?",
                        arguments: [Self.uuid(prediction.assetID)]
                    ) else {
                        throw PersonalizationCatalogError.notFound
                    }
                    guard currentRevision == prediction.contentRevision else {
                        throw PersonalizationCatalogError.staleAssetRevision
                    }
                    let hasDecision = try Bool.fetchOne(
                        db,
                        sql: "SELECT EXISTS(SELECT 1 FROM asset_tag_decision WHERE asset_id = ? AND tag_id = ?)",
                        arguments: [Self.uuid(prediction.assetID), Self.uuid(tagID)]
                    ) ?? false
                    guard !hasDecision else { continue }

                    try db.execute(
                        sql: """
                        INSERT INTO prediction (
                            asset_id, tag_id, content_revision, model_revision,
                            score, state, created_at_ms
                        ) VALUES (?, ?, ?, ?, ?, 'pendingReview', ?)
                        """,
                        arguments: [
                            Self.uuid(prediction.assetID),
                            Self.uuid(tagID),
                            prediction.contentRevision,
                            modelRevision,
                            prediction.score,
                            createdAtMs,
                        ]
                    )
                }
            }
        } catch let error as PersonalizationCatalogError {
            throw error
        } catch {
            throw PersonalizationCatalogError.persistenceFailure
        }
    }

    func pendingPredictions(tagID: UUID, limit: Int) throws -> [PendingPrediction] {
        guard (1 ... PersonalizationConstants.maximumCandidateCount).contains(limit) else {
            throw PersonalizationCatalogError.invalidInput
        }
        do {
            return try database.pool.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT p.asset_id, p.tag_id, p.content_revision, p.model_revision, p.score
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
                    ORDER BY p.score DESC, p.asset_id
                    LIMIT ?
                    """,
                    arguments: [Self.uuid(tagID), limit]
                ).compactMap { row in
                    guard let assetID = UUID(uuidString: row["asset_id"]),
                          let persistedTagID = UUID(uuidString: row["tag_id"])
                    else { return nil }
                    return PendingPrediction(
                        assetID: assetID,
                        tagID: persistedTagID,
                        contentRevision: row["content_revision"],
                        modelRevision: row["model_revision"],
                        score: row["score"]
                    )
                }
            }
        } catch {
            throw PersonalizationCatalogError.persistenceFailure
        }
    }

    private static func sampleIsCurrentAndEligible(
        _ db: Database,
        tagID: UUID,
        sample: ModelSampleRegistration
    ) throws -> Bool {
        let expectedDecision = sample.role == .positive
            ? PersistableTagDecision.accepted.rawValue
            : PersistableTagDecision.rejected.rawValue
        return try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1
                FROM feature f
                JOIN asset a
                    ON a.id = f.asset_id
                    AND a.content_revision = f.content_revision
                JOIN asset_tag_decision d
                    ON d.asset_id = f.asset_id
                    AND d.tag_id = ?
                    AND d.decision = ?
                WHERE f.asset_id = ?
                    AND f.provider = ?
                    AND f.request_revision = ?
                    AND f.preprocessing_revision = ?
                    AND f.content_revision = ?
            )
            """,
            arguments: [
                uuid(tagID),
                expectedDecision,
                uuid(sample.identity.assetID),
                sample.identity.provider,
                sample.identity.requestRevision,
                sample.identity.preprocessingRevision,
                sample.identity.contentRevision,
            ]
        ) ?? false
    }

    private static func hasContiguousRanks(_ samples: [ModelSampleRegistration]) -> Bool {
        samples.map(\.rank).sorted() == Array(0 ..< samples.count)
    }

    private static func isSafeCacheKey(_ cacheKey: String) -> Bool {
        guard cacheKey.count <= 200,
              cacheKey.hasPrefix("objects/"),
              cacheKey.hasSuffix(".fprint"),
              !cacheKey.contains(".."),
              !cacheKey.contains("\\"),
              !cacheKey.contains("\0")
        else { return false }
        let components = cacheKey.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 3
            && components[1].count == 2
            && components[1].allSatisfy { $0.isHexDigit && !$0.isUppercase }
            && !components[2].isEmpty
    }

    private static func uuid(_ value: UUID) -> String {
        value.uuidString.lowercased()
    }
}
