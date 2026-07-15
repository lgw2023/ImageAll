import Foundation
import GRDB

final class PersonalizedSuggestionService: @unchecked Sendable {
    private struct SampleCandidate: Sendable {
        let assetID: UUID
        let contentRevision: Int
        let role: ModelSampleRole
    }

    private struct LoadedSample: Sendable {
        let candidate: SampleCandidate
        let payload: FeatureVectorPayload
        let values: [Float]
    }

    private struct CandidateRevision: Sendable {
        let assetID: UUID
        let contentRevision: Int
    }

    private let database: CatalogDatabase
    private let featureLoader: any FeatureVectorLoading
    private let catalog: GRDBPersonalizationRepository
    private let clock: any JobClock

    init(
        database: CatalogDatabase,
        featureLoader: any FeatureVectorLoading,
        clock: any JobClock = SystemJobClock()
    ) {
        self.database = database
        self.featureLoader = featureLoader
        catalog = GRDBPersonalizationRepository(database: database)
        self.clock = clock
    }

    func generateSuggestions(
        tagID: UUID,
        candidateAssetIDs: [UUID]
    ) async throws -> PersonalizedSuggestionResult {
        let candidates = Self.unique(candidateAssetIDs)
        guard !candidates.isEmpty,
              candidates.count <= PersonalizationConstants.maximumCandidateCount
        else {
            throw PersonalizedSuggestionError.invalidCandidates
        }

        let samples = try await fetchSamples(tagID: tagID)
        let positives = samples.filter { $0.role == .positive }
        let negatives = samples.filter { $0.role == .negative }
        guard positives.count >= 2, negatives.count >= 2 else {
            throw PersonalizedSuggestionError.insufficientSamples
        }

        let loadedPositives = try await loadSamples(positives)
        let loadedNegatives = try await loadSamples(negatives)
        guard let dimension = loadedPositives.first?.values.count,
              dimension > 0,
              (loadedPositives + loadedNegatives).allSatisfy({ $0.values.count == dimension })
        else {
            throw PersonalizedSuggestionError.inconsistentFeatureDimensions
        }

        let eligibleCandidates = try await fetchEligibleCandidates(
            tagID: tagID,
            assetIDs: candidates
        )
        let neighborCount = min(3, loadedPositives.count, loadedNegatives.count)
        var predictions: [PredictionRegistration] = []
        for candidate in eligibleCandidates {
            let payload = try await featureLoader.loadOrGenerate(assetID: candidate.assetID)
            guard payload.identity.contentRevision == candidate.contentRevision else {
                throw PersonalizedSuggestionError.persistenceFailure
            }
            let values = try Self.decode(payload)
            guard values.count == dimension else {
                throw PersonalizedSuggestionError.inconsistentFeatureDimensions
            }
            let positiveMean = Self.nearestMeanDistance(
                candidate: values,
                samples: loadedPositives.map(\.values),
                count: neighborCount
            )
            let negativeMean = Self.nearestMeanDistance(
                candidate: values,
                samples: loadedNegatives.map(\.values),
                count: neighborCount
            )
            let score = negativeMean - positiveMean
            if score > 0 {
                predictions.append(
                    PredictionRegistration(
                        assetID: candidate.assetID,
                        contentRevision: candidate.contentRevision,
                        score: score
                    )
                )
            }
        }

        let revision = try await nextRevision(tagID: tagID)
        let sampleRegistrations = Self.registrations(
            positives: loadedPositives,
            negatives: loadedNegatives
        )
        do {
            try catalog.publishModelRevision(
                ModelRevisionRegistration(
                    tagID: tagID,
                    revision: revision,
                    threshold: 0,
                    neighborCount: neighborCount,
                    sampleBudgetPerRole: 12,
                    samples: sampleRegistrations,
                    createdAtMs: clock.nowMs
                )
            )
            try catalog.replacePredictions(
                tagID: tagID,
                modelRevision: revision,
                candidateAssetIDs: candidates,
                predictions: predictions,
                createdAtMs: clock.nowMs
            )
        } catch let error as PersonalizationCatalogError {
            switch error {
            case .notFound: throw PersonalizedSuggestionError.tagNotFound
            case .archivedTag: throw PersonalizedSuggestionError.archivedTag
            default: throw PersonalizedSuggestionError.persistenceFailure
            }
        }

        return PersonalizedSuggestionResult(
            modelRevision: revision,
            positiveSampleCount: loadedPositives.count,
            negativeSampleCount: loadedNegatives.count,
            evaluatedCandidateCount: eligibleCandidates.count,
            predictedCandidateCount: predictions.count
        )
    }

    private func fetchSamples(tagID: UUID) async throws -> [SampleCandidate] {
        try await database.pool.read { db in
            guard let tagState: String = try String.fetchOne(
                db,
                sql: "SELECT state FROM tag WHERE id = ?",
                arguments: [tagID.uuidString.lowercased()]
            ) else {
                throw PersonalizedSuggestionError.tagNotFound
            }
            guard tagState == TagState.active.rawValue else {
                throw PersonalizedSuggestionError.archivedTag
            }

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
                        AND a.locator_kind = 'file'
                        AND a.locator_state = 'current'
                        AND a.availability = 'available'
                        AND s.kind = 'folder'
                        AND s.state = 'active'
                )
                SELECT id, content_revision, decision
                FROM ranked
                WHERE role_rank <= 12
                ORDER BY decision ASC, role_rank ASC
                """,
                arguments: [tagID.uuidString.lowercased()]
            )
            return rows.compactMap { row in
                guard let assetID = UUID(uuidString: row["id"]),
                      let role = ModelSampleRole(
                          rawValue: (row["decision"] as String) == "accepted" ? "positive" : "negative"
                      )
                else { return nil }
                return SampleCandidate(
                    assetID: assetID,
                    contentRevision: row["content_revision"],
                    role: role
                )
            }
        }
    }

    private func loadSamples(_ candidates: [SampleCandidate]) async throws -> [LoadedSample] {
        var loaded: [LoadedSample] = []
        for candidate in candidates {
            let payload = try await featureLoader.loadOrGenerate(assetID: candidate.assetID)
            guard payload.identity.contentRevision == candidate.contentRevision else {
                throw PersonalizedSuggestionError.persistenceFailure
            }
            loaded.append(
                LoadedSample(
                    candidate: candidate,
                    payload: payload,
                    values: try Self.decode(payload)
                )
            )
        }
        return loaded
    }

    private func fetchEligibleCandidates(
        tagID: UUID,
        assetIDs: [UUID]
    ) async throws -> [CandidateRevision] {
        try await database.pool.read { db in
            var result: [CandidateRevision] = []
            for assetID in assetIDs {
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT a.content_revision
                    FROM asset a
                    JOIN source s ON s.id = a.source_id
                    WHERE a.id = ?
                        AND a.locator_kind = 'file'
                        AND a.locator_state = 'current'
                        AND a.availability = 'available'
                        AND s.kind = 'folder'
                        AND s.state = 'active'
                        AND NOT EXISTS (
                            SELECT 1 FROM asset_tag_decision d
                            WHERE d.asset_id = a.id AND d.tag_id = ?
                        )
                    """,
                    arguments: [assetID.uuidString.lowercased(), tagID.uuidString.lowercased()]
                ) else { continue }
                result.append(
                    CandidateRevision(assetID: assetID, contentRevision: row["content_revision"])
                )
            }
            return result
        }
    }

    private func nextRevision(tagID: UUID) async throws -> Int {
        try await database.pool.read { db in
            let current: Int = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(revision), 0) FROM tag_model_revision WHERE tag_id = ?",
                arguments: [tagID.uuidString.lowercased()]
            ) ?? 0
            return current + 1
        }
    }

    private static func registrations(
        positives: [LoadedSample],
        negatives: [LoadedSample]
    ) -> [ModelSampleRegistration] {
        positives.enumerated().map { index, sample in
            ModelSampleRegistration(identity: sample.payload.identity, role: .positive, rank: index)
        } + negatives.enumerated().map { index, sample in
            ModelSampleRegistration(identity: sample.payload.identity, role: .negative, rank: index)
        }
    }

    private static func decode(_ payload: FeatureVectorPayload) throws -> [Float] {
        guard payload.elementCount > 0,
              payload.vectorData.count == payload.elementCount * MemoryLayout<Float>.size
        else {
            throw PersonalizedSuggestionError.invalidFeatureVector
        }
        let values = payload.vectorData.withUnsafeBytes { raw in
            (0 ..< payload.elementCount).map { index in
                raw.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<Float>.size,
                    as: Float.self
                )
            }
        }
        guard values.allSatisfy(\.isFinite) else {
            throw PersonalizedSuggestionError.invalidFeatureVector
        }
        return values
    }

    private static func nearestMeanDistance(
        candidate: [Float],
        samples: [[Float]],
        count: Int
    ) -> Double {
        let nearest = samples.map { sample in
            sqrt(zip(candidate, sample).reduce(0.0) { partial, pair in
                let difference = Double(pair.0 - pair.1)
                return partial + difference * difference
            })
        }.sorted().prefix(count)
        return nearest.reduce(0, +) / Double(count)
    }

    private static func unique(_ values: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return values.filter { seen.insert($0).inserted }
    }
}
