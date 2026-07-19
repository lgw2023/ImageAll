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

final class LoopbackModelSuggestionClient: LocalModelSuggestionClient, @unchecked Sendable {
    private struct HealthResponsePayload: Decodable {
        let status: String
        let serviceVersion: String
        let provider: PersonalTrainingEncoderIdentity?

        enum CodingKeys: String, CodingKey {
            case status
            case serviceVersion = "service_version"
            case provider
        }
    }

    private struct EmbeddingRequestPayload: Encodable {
        struct CacheKey: Encodable {
            let schemaRevision = 1
            let catalogScopeID: String
            let assetID: String
            let contentRevision: String

            enum CodingKeys: String, CodingKey {
                case schemaRevision = "schema_revision"
                case catalogScopeID = "catalog_scope_id"
                case assetID = "asset_id"
                case contentRevision = "content_revision"
            }
        }

        let requestID: String
        let imageBase64: String
        let cacheKey: CacheKey?

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case imageBase64 = "image_base64"
            case cacheKey = "cache_key"
        }
    }

    private struct EmbeddingResponsePayload: Decodable {
        let requestID: String
        let provider: String
        let modelID: String
        let modelRevision: String
        let preprocessingRevision: String
        let elementType: String
        let elementCount: Int
        let embedding: [Float]

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case provider
            case modelID = "model_id"
            case modelRevision = "model_revision"
            case preprocessingRevision = "preprocessing_revision"
            case elementType = "element_type"
            case elementCount = "element_count"
            case embedding
        }
    }

    private struct PersonalRebuildRequestPayload: Encodable {
        struct ExpectedActiveBundle: Encodable {
            let bundleRevision: String
            let weightsSHA256: String

            enum CodingKeys: String, CodingKey {
                case bundleRevision = "bundle_revision"
                case weightsSHA256 = "weights_sha256"
            }
        }

        struct Snapshot: Encodable {
            struct Embedding: Encodable {
                let assetID: String
                let contentRevision: String
                let embedding: [Float]

                enum CodingKeys: String, CodingKey {
                    case assetID = "asset_id"
                    case contentRevision = "content_revision"
                    case embedding
                }
            }

            struct Decision: Encodable {
                let assetID: String
                let contentRevision: String
                let tagID: String
                let state: PersonalTrainingDecisionState

                enum CodingKeys: String, CodingKey {
                    case assetID = "asset_id"
                    case contentRevision = "content_revision"
                    case tagID = "tag_id"
                    case state
                }
            }

            let schemaRevision = 1
            let catalogScopeID: String
            let decisionSnapshotRevision: String
            let encoder: PersonalTrainingEncoderIdentity
            let personalTagIDs: [String]
            let labelVocabularyRevision: String
            let embeddings: [Embedding]
            let decisions: [Decision]

            enum CodingKeys: String, CodingKey {
                case schemaRevision = "schema_revision"
                case catalogScopeID = "catalog_scope_id"
                case decisionSnapshotRevision = "decision_snapshot_revision"
                case encoder
                case personalTagIDs = "personal_tag_ids"
                case labelVocabularyRevision = "label_vocabulary_revision"
                case embeddings
                case decisions
            }
        }

        let requestID: String
        let expectedActiveBundle: ExpectedActiveBundle?
        let snapshot: Snapshot

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case expectedActiveBundle = "expected_active_bundle"
            case snapshot
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(requestID, forKey: .requestID)
            if let expectedActiveBundle {
                try container.encode(expectedActiveBundle, forKey: .expectedActiveBundle)
            } else {
                try container.encodeNil(forKey: .expectedActiveBundle)
            }
            try container.encode(snapshot, forKey: .snapshot)
        }
    }

    private struct PersonalRebuildResponsePayload: Decodable {
        let requestID: String
        let personal: PersonalCapabilityPayload

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case personal
        }
    }

    private struct PersonalCachedRebuildRequestPayload: Encodable {
        struct Snapshot: Encodable {
            struct EmbeddingKey: Encodable {
                let assetID: String
                let contentRevision: String

                enum CodingKeys: String, CodingKey {
                    case assetID = "asset_id"
                    case contentRevision = "content_revision"
                }
            }

            let schemaRevision = 1
            let catalogScopeID: String
            let decisionSnapshotRevision: String
            let encoder: PersonalTrainingEncoderIdentity
            let personalTagIDs: [String]
            let labelVocabularyRevision: String
            let embeddingKeys: [EmbeddingKey]
            let decisions: [PersonalRebuildRequestPayload.Snapshot.Decision]

            enum CodingKeys: String, CodingKey {
                case schemaRevision = "schema_revision"
                case catalogScopeID = "catalog_scope_id"
                case decisionSnapshotRevision = "decision_snapshot_revision"
                case encoder
                case personalTagIDs = "personal_tag_ids"
                case labelVocabularyRevision = "label_vocabulary_revision"
                case embeddingKeys = "embedding_keys"
                case decisions
            }
        }

        let requestID: String
        let expectedActiveBundle: PersonalRebuildRequestPayload.ExpectedActiveBundle?
        let snapshot: Snapshot

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case expectedActiveBundle = "expected_active_bundle"
            case snapshot
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(requestID, forKey: .requestID)
            if let expectedActiveBundle {
                try container.encode(expectedActiveBundle, forKey: .expectedActiveBundle)
            } else {
                try container.encodeNil(forKey: .expectedActiveBundle)
            }
            try container.encode(snapshot, forKey: .snapshot)
        }
    }

    private struct SuggestionRequestPayload: Encodable {
        let requestID: String
        let imageBase64: String
        let target: SuggestionTargetPayload

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case imageBase64 = "image_base64"
            case target
        }
    }

    private struct SuggestionTargetPayload: Encodable {
        let track: ModelSuggestionTrack
        let catalogScopeID: String?
        let standardPackID: String?
        let standardPackRevision: String?
        let bundleID: String?
        let bundleRevision: String?
        let provider: String?
        let modelID: String?
        let modelRevision: String?
        let preprocessingRevision: String?
        let elementCount: Int?
        let labelVocabularyRevision: String?
        let weightsSHA256: String?
        let policyRevision: String?

        enum CodingKeys: String, CodingKey {
            case track
            case catalogScopeID = "catalog_scope_id"
            case standardPackID = "standard_pack_id"
            case standardPackRevision = "standard_pack_revision"
            case bundleID = "bundle_id"
            case bundleRevision = "bundle_revision"
            case provider
            case modelID = "model_id"
            case modelRevision = "model_revision"
            case preprocessingRevision = "preprocessing_revision"
            case elementCount = "element_count"
            case labelVocabularyRevision = "label_vocabulary_revision"
            case weightsSHA256 = "weights_sha256"
            case policyRevision = "policy_revision"
        }

        init(_ target: ModelSuggestionTarget) {
            switch target {
            case let .standard(standard):
                track = .standard
                catalogScopeID = nil
                standardPackID = standard.standardPackID
                standardPackRevision = standard.standardPackRevision
                bundleID = nil
                bundleRevision = nil
                provider = nil
                modelID = nil
                modelRevision = nil
                preprocessingRevision = nil
                elementCount = nil
                labelVocabularyRevision = nil
                weightsSHA256 = nil
                policyRevision = nil
            case let .personal(personal):
                track = .personal
                catalogScopeID = personal.catalogScopeID
                standardPackID = nil
                standardPackRevision = nil
                bundleID = personal.bundleID
                bundleRevision = personal.bundleRevision
                provider = personal.provider
                modelID = personal.modelID
                modelRevision = personal.modelRevision
                preprocessingRevision = personal.preprocessingRevision
                elementCount = personal.elementCount
                labelVocabularyRevision = personal.labelVocabularyRevision
                weightsSHA256 = personal.weightsSHA256
                policyRevision = personal.policyRevision
            }
        }
    }

    private struct CapabilitiesResponsePayload: Decodable {
        let serviceVersion: String
        let standard: StandardCapabilityPayload?
        let personal: PersonalCapabilityPayload

        enum CodingKeys: String, CodingKey {
            case serviceVersion = "service_version"
            case standard
            case personal
        }
    }

    private struct StrictCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            return nil
        }
    }

    private struct StandardCapabilityPayload: Decodable {
        struct Provider: Decodable {
            let provider: String
            let modelID: String
            let modelRevision: String
            let preprocessingRevision: String

            enum CodingKeys: String, CodingKey, CaseIterable {
                case provider
                case modelID = "model_id"
                case modelRevision = "model_revision"
                case preprocessingRevision = "preprocessing_revision"
            }

            init(from decoder: Decoder) throws {
                let dynamic = try decoder.container(keyedBy: StrictCodingKey.self)
                let expected = Set(CodingKeys.allCases.map(\.rawValue))
                guard Set(dynamic.allKeys.map(\.stringValue)) == expected else {
                    throw DecodingError.dataCorrupted(
                        .init(
                            codingPath: decoder.codingPath,
                            debugDescription: "standard provider identity has unexpected fields"
                        )
                    )
                }
                let container = try decoder.container(keyedBy: CodingKeys.self)
                provider = try container.decode(String.self, forKey: .provider)
                modelID = try container.decode(String.self, forKey: .modelID)
                modelRevision = try container.decode(String.self, forKey: .modelRevision)
                preprocessingRevision = try container.decode(
                    String.self,
                    forKey: .preprocessingRevision
                )
            }
        }

        let status: String
        let standardPackID: String?
        let standardPackRevision: String?
        let manifestSHA256: String?
        let ontologyID: String?
        let ontologyRevision: String?
        let provider: Provider?
        let mappingRevision: String?
        let policyRevision: String?
        let weightsSHA256: String?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case status
            case standardPackID = "standard_pack_id"
            case standardPackRevision = "standard_pack_revision"
            case manifestSHA256 = "manifest_sha256"
            case ontologyID = "ontology_id"
            case ontologyRevision = "ontology_revision"
            case provider
            case mappingRevision = "mapping_revision"
            case policyRevision = "policy_revision"
            case weightsSHA256 = "weights_sha256"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(String.self, forKey: .status)
            let dynamic = try decoder.container(keyedBy: StrictCodingKey.self)
            let actualKeys = Set(dynamic.allKeys.map(\.stringValue))
            let expectedKeys: Set<String>
            switch status {
            case "unavailable":
                expectedKeys = [CodingKeys.status.rawValue]
            case "available":
                expectedKeys = Set(CodingKeys.allCases.map(\.rawValue))
            default:
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "standard capability status is invalid"
                    )
                )
            }
            guard actualKeys == expectedKeys else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "standard capability fields do not match status"
                    )
                )
            }
            standardPackID = try container.decodeIfPresent(String.self, forKey: .standardPackID)
            standardPackRevision = try container.decodeIfPresent(
                String.self,
                forKey: .standardPackRevision
            )
            manifestSHA256 = try container.decodeIfPresent(String.self, forKey: .manifestSHA256)
            ontologyID = try container.decodeIfPresent(String.self, forKey: .ontologyID)
            ontologyRevision = try container.decodeIfPresent(String.self, forKey: .ontologyRevision)
            provider = try container.decodeIfPresent(Provider.self, forKey: .provider)
            mappingRevision = try container.decodeIfPresent(String.self, forKey: .mappingRevision)
            policyRevision = try container.decodeIfPresent(String.self, forKey: .policyRevision)
            weightsSHA256 = try container.decodeIfPresent(String.self, forKey: .weightsSHA256)
        }
    }

    private struct PersonalCapabilityPayload: Decodable {
        struct Encoder: Decodable {
            let provider: String
            let modelID: String
            let modelRevision: String
            let preprocessingRevision: String
            let elementCount: Int

            enum CodingKeys: String, CodingKey {
                case provider
                case modelID = "model_id"
                case modelRevision = "model_revision"
                case preprocessingRevision = "preprocessing_revision"
                case elementCount = "element_count"
            }
        }

        let status: String
        let catalogScopeID: String?
        let bundleID: String?
        let bundleRevision: String?
        let encoder: Encoder?
        let labelVocabularyRevision: String?
        let weightsSHA256: String?
        let policyRevision: String?
        let tagIDs: [UUID]?

        enum CodingKeys: String, CodingKey {
            case status
            case catalogScopeID = "catalog_scope_id"
            case bundleID = "bundle_id"
            case bundleRevision = "bundle_revision"
            case encoder
            case labelVocabularyRevision = "label_vocabulary_revision"
            case weightsSHA256 = "weights_sha256"
            case policyRevision = "policy_revision"
            case tagIDs = "tag_ids"
        }
    }

    private struct SuggestionResponsePayload: Decodable {
        let requestID: String
        let suggestions: [LocalModelSuggestion]

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id"
            case suggestions
        }
    }

    private struct ErrorResponsePayload: Decodable {
        struct Detail: Decodable {
            let code: String
        }

        let detail: Detail
    }

    private let endpoint: URL
    private let session: URLSession

    init(
        endpoint: URL = URL(string: "http://127.0.0.1:8765")!,
        session: URLSession = .shared
    ) throws {
        guard endpoint.scheme == "http",
              endpoint.host == "127.0.0.1",
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil,
              endpoint.path.isEmpty || endpoint.path == "/"
        else {
            throw LocalModelSuggestionClientError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.session = session
    }

    func serviceHealth() async throws -> LocalModelServiceHealth {
        var request = URLRequest(
            url: endpoint.appendingPathComponent("v1/health"),
            timeoutInterval: 10
        )
        request.httpMethod = "GET"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LocalModelSuggestionClientError.serviceUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw LocalModelSuggestionClientError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let code = try? JSONDecoder()
                .decode(ErrorResponsePayload.self, from: data)
                .detail.code
            throw LocalModelSuggestionClientError.rejected(
                statusCode: http.statusCode,
                code: code
            )
        }
        guard let payload = try? JSONDecoder().decode(
            HealthResponsePayload.self,
            from: data
        ),
            !payload.serviceVersion.isEmpty
        else {
            throw LocalModelSuggestionClientError.invalidResponse
        }
        switch (payload.status, payload.provider) {
        case let ("ready", provider?):
            guard !provider.provider.isEmpty,
                  !provider.modelID.isEmpty,
                  !provider.modelRevision.isEmpty,
                  !provider.preprocessingRevision.isEmpty,
                  provider.elementCount > 0
            else {
                throw LocalModelSuggestionClientError.invalidResponse
            }
            return .ready(
                serviceVersion: payload.serviceVersion,
                provider: provider
            )
        case ("degraded", nil):
            return .degraded(serviceVersion: payload.serviceVersion)
        default:
            throw LocalModelSuggestionClientError.invalidResponse
        }
    }

    func personalCapability() async throws -> PersonalModelSuggestionCapabilityAvailability {
        var request = URLRequest(
            url: endpoint.appendingPathComponent("v1/capabilities"),
            timeoutInterval: 10
        )
        request.httpMethod = "GET"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LocalModelSuggestionClientError.serviceUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw LocalModelSuggestionClientError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let code = try? JSONDecoder()
                .decode(ErrorResponsePayload.self, from: data)
                .detail.code
            throw LocalModelSuggestionClientError.rejected(
                statusCode: http.statusCode,
                code: code
            )
        }
        guard let payload = try? JSONDecoder().decode(
            CapabilitiesResponsePayload.self,
            from: data
        ),
            !payload.serviceVersion.isEmpty
        else {
            throw LocalModelSuggestionClientError.invalidResponse
        }
        return try Self.personalAvailability(payload.personal)
    }

    func standardCapability() async throws -> StandardModelSuggestionCapabilityAvailability {
        var request = URLRequest(
            url: endpoint.appendingPathComponent("v1/capabilities"),
            timeoutInterval: 10
        )
        request.httpMethod = "GET"

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LocalModelSuggestionClientError.serviceUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw LocalModelSuggestionClientError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let code = try? JSONDecoder()
                .decode(ErrorResponsePayload.self, from: data)
                .detail.code
            throw LocalModelSuggestionClientError.rejected(
                statusCode: http.statusCode,
                code: code
            )
        }
        guard let payload = try? JSONDecoder().decode(
            CapabilitiesResponsePayload.self,
            from: data
        ),
            !payload.serviceVersion.isEmpty,
            let standard = payload.standard
        else {
            throw LocalModelSuggestionClientError.invalidResponse
        }
        if standard.status == "unavailable" {
            guard standard.standardPackID == nil,
                  standard.standardPackRevision == nil,
                  standard.manifestSHA256 == nil,
                  standard.ontologyID == nil,
                  standard.ontologyRevision == nil,
                  standard.provider == nil,
                  standard.mappingRevision == nil,
                  standard.policyRevision == nil,
                  standard.weightsSHA256 == nil
            else {
                throw LocalModelSuggestionClientError.invalidResponse
            }
            return .unavailable
        }
        guard standard.status == "available",
            let standardPackID = standard.standardPackID,
            !standardPackID.isEmpty,
            let standardPackRevision = standard.standardPackRevision,
            !standardPackRevision.isEmpty,
            let manifestSHA256 = standard.manifestSHA256,
            Self.isLowercaseSHA256(manifestSHA256),
            let ontologyID = standard.ontologyID,
            !ontologyID.isEmpty,
            let ontologyRevision = standard.ontologyRevision,
            !ontologyRevision.isEmpty,
            let provider = standard.provider,
            !provider.provider.isEmpty,
            !provider.modelID.isEmpty,
            !provider.modelRevision.isEmpty,
            !provider.preprocessingRevision.isEmpty,
            let mappingRevision = standard.mappingRevision,
            !mappingRevision.isEmpty,
            let policyRevision = standard.policyRevision,
            !policyRevision.isEmpty,
            let weightsSHA256 = standard.weightsSHA256,
            Self.isLowercaseSHA256(weightsSHA256)
        else {
            throw LocalModelSuggestionClientError.invalidResponse
        }
        return .available(
            StandardModelSuggestionCapability(
                target: StandardModelSuggestionTarget(
                    standardPackID: standardPackID,
                    standardPackRevision: standardPackRevision
                ),
                manifestSHA256: manifestSHA256,
                ontologyID: ontologyID,
                ontologyRevision: ontologyRevision,
                provider: provider.provider,
                modelID: provider.modelID,
                modelRevision: provider.modelRevision,
                preprocessingRevision: provider.preprocessingRevision,
                mappingRevision: mappingRevision,
                policyRevision: policyRevision,
                weightsSHA256: weightsSHA256
            )
        )
    }

    private static func personalAvailability(
        _ personal: PersonalCapabilityPayload
    ) throws -> PersonalModelSuggestionCapabilityAvailability {
        if personal.status == "unavailable" {
            guard personal.catalogScopeID == nil,
                  personal.bundleID == nil,
                  personal.bundleRevision == nil,
                  personal.encoder == nil,
                  personal.labelVocabularyRevision == nil,
                  personal.weightsSHA256 == nil,
                  personal.policyRevision == nil,
                  personal.tagIDs == nil
            else {
                throw LocalModelSuggestionClientError.invalidResponse
            }
            return .unavailable
        }
        guard personal.status == "available",
              let catalogScopeID = personal.catalogScopeID,
              !catalogScopeID.isEmpty,
              let bundleID = personal.bundleID,
              !bundleID.isEmpty,
              let bundleRevision = personal.bundleRevision,
              !bundleRevision.isEmpty,
              let encoder = personal.encoder,
              !encoder.provider.isEmpty,
              !encoder.modelID.isEmpty,
              !encoder.modelRevision.isEmpty,
              !encoder.preprocessingRevision.isEmpty,
              encoder.elementCount > 0,
              let labelVocabularyRevision = personal.labelVocabularyRevision,
              !labelVocabularyRevision.isEmpty,
              let weightsSHA256 = personal.weightsSHA256,
              Self.isLowercaseSHA256(weightsSHA256),
              let policyRevision = personal.policyRevision,
              !policyRevision.isEmpty,
              let tagIDs = personal.tagIDs,
              !tagIDs.isEmpty,
              Set(tagIDs).count == tagIDs.count
        else {
            throw LocalModelSuggestionClientError.invalidResponse
        }
        return .available(
            PersonalModelSuggestionCapability(
                target: PersonalModelSuggestionTarget(
                    catalogScopeID: catalogScopeID,
                    bundleID: bundleID,
                    bundleRevision: bundleRevision,
                    provider: encoder.provider,
                    modelID: encoder.modelID,
                    modelRevision: encoder.modelRevision,
                    preprocessingRevision: encoder.preprocessingRevision,
                    elementCount: encoder.elementCount,
                    labelVocabularyRevision: labelVocabularyRevision,
                    weightsSHA256: weightsSHA256,
                    policyRevision: policyRevision
                ),
                tagIDs: tagIDs
            )
        )
    }

    func embedding(
        imageData: Data,
        requestID: String,
        cacheKey: PersonalTrainingEmbeddingCacheKey?
    ) async throws -> PersonalTrainingEmbedding {
        var request = URLRequest(
            url: endpoint.appendingPathComponent("v1/embeddings"),
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            EmbeddingRequestPayload(
                requestID: requestID,
                imageBase64: imageData.base64EncodedString(),
                cacheKey: cacheKey.map {
                    EmbeddingRequestPayload.CacheKey(
                        catalogScopeID: $0.catalogScopeID,
                        assetID: $0.assetID.uuidString.lowercased(),
                        contentRevision: String($0.contentRevision)
                    )
                }
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LocalModelSuggestionClientError.serviceUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw LocalModelSuggestionClientError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let code = try? JSONDecoder()
                .decode(ErrorResponsePayload.self, from: data)
                .detail.code
            throw LocalModelSuggestionClientError.rejected(
                statusCode: http.statusCode,
                code: code
            )
        }
        guard let payload = try? JSONDecoder().decode(
            EmbeddingResponsePayload.self,
            from: data
        ),
            payload.requestID == requestID,
            !payload.provider.isEmpty,
            !payload.modelID.isEmpty,
            !payload.modelRevision.isEmpty,
            !payload.preprocessingRevision.isEmpty,
            payload.elementType == "float32",
            payload.elementCount > 0,
            payload.embedding.count == payload.elementCount,
            payload.embedding.allSatisfy(\.isFinite)
        else {
            throw LocalModelSuggestionClientError.invalidResponse
        }
        return PersonalTrainingEmbedding(
            encoder: PersonalTrainingEncoderIdentity(
                provider: payload.provider,
                modelID: payload.modelID,
                modelRevision: payload.modelRevision,
                preprocessingRevision: payload.preprocessingRevision,
                elementCount: payload.elementCount
            ),
            values: payload.embedding
        )
    }

    func rebuildPersonalModel(
        requestID: String,
        expectedActiveBundle: PersonalModelActiveBundleIdentity?,
        snapshot: PersonalModelRebuildSnapshot
    ) async throws -> PersonalModelSuggestionCapability {
        guard !requestID.isEmpty,
              !snapshot.catalogScopeID.isEmpty,
              Self.isLowercaseSHA256(snapshot.decisionSnapshotRevision),
              Self.isLowercaseSHA256(snapshot.labelVocabularyRevision),
              !snapshot.encoder.provider.isEmpty,
              !snapshot.encoder.modelID.isEmpty,
              !snapshot.encoder.modelRevision.isEmpty,
              !snapshot.encoder.preprocessingRevision.isEmpty,
              snapshot.encoder.elementCount > 0,
              !snapshot.personalTagIDs.isEmpty,
              Set(snapshot.personalTagIDs).count == snapshot.personalTagIDs.count,
              !snapshot.embeddings.isEmpty,
              !snapshot.decisions.isEmpty,
              expectedActiveBundle.map({
                  !$0.bundleRevision.isEmpty && Self.isLowercaseSHA256($0.weightsSHA256)
              }) ?? true,
              snapshot.embeddings.allSatisfy({ row in
                  row.contentRevision >= 0
                      && row.values.count == snapshot.encoder.elementCount
                      && row.values.allSatisfy(\.isFinite)
              }),
              snapshot.decisions.allSatisfy({ decision in
                  decision.contentRevision >= 0
                      && snapshot.personalTagIDs.contains(decision.tagID)
              })
        else {
            throw LocalModelSuggestionClientError.invalidResponse
        }
        let requestPayload = PersonalRebuildRequestPayload(
            requestID: requestID,
            expectedActiveBundle: expectedActiveBundle.map {
                PersonalRebuildRequestPayload.ExpectedActiveBundle(
                    bundleRevision: $0.bundleRevision,
                    weightsSHA256: $0.weightsSHA256
                )
            },
            snapshot: PersonalRebuildRequestPayload.Snapshot(
                catalogScopeID: snapshot.catalogScopeID,
                decisionSnapshotRevision: snapshot.decisionSnapshotRevision,
                encoder: snapshot.encoder,
                personalTagIDs: snapshot.personalTagIDs.map {
                    $0.uuidString.lowercased()
                },
                labelVocabularyRevision: snapshot.labelVocabularyRevision,
                embeddings: snapshot.embeddings.map {
                    PersonalRebuildRequestPayload.Snapshot.Embedding(
                        assetID: $0.assetID.uuidString.lowercased(),
                        contentRevision: String($0.contentRevision),
                        embedding: $0.values
                    )
                },
                decisions: snapshot.decisions.map {
                    PersonalRebuildRequestPayload.Snapshot.Decision(
                        assetID: $0.assetID.uuidString.lowercased(),
                        contentRevision: String($0.contentRevision),
                        tagID: $0.tagID.uuidString.lowercased(),
                        state: $0.state
                    )
                }
            )
        )
        var request = URLRequest(
            url: endpoint.appendingPathComponent("v1/personal/rebuild"),
            timeoutInterval: 300
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestPayload)

        return try await submitPersonalRebuild(
            request,
            requestID: requestID,
            catalogScopeID: snapshot.catalogScopeID,
            encoder: snapshot.encoder,
            personalTagIDs: snapshot.personalTagIDs,
            labelVocabularyRevision: snapshot.labelVocabularyRevision
        )
    }

    func rebuildPersonalModelFromCache(
        requestID: String,
        expectedActiveBundle: PersonalModelActiveBundleIdentity?,
        snapshot: PersonalModelCachedRebuildSnapshot
    ) async throws -> PersonalModelSuggestionCapability {
        let embeddingIdentities = snapshot.embeddingKeys.map {
            "\($0.assetID.uuidString.lowercased())|\($0.contentRevision)"
        }
        let embeddingIdentitySet = Set(embeddingIdentities)
        guard !requestID.isEmpty,
              !snapshot.catalogScopeID.isEmpty,
              Self.isLowercaseSHA256(snapshot.decisionSnapshotRevision),
              Self.isLowercaseSHA256(snapshot.labelVocabularyRevision),
              !snapshot.encoder.provider.isEmpty,
              !snapshot.encoder.modelID.isEmpty,
              !snapshot.encoder.modelRevision.isEmpty,
              !snapshot.encoder.preprocessingRevision.isEmpty,
              snapshot.encoder.elementCount > 0,
              !snapshot.personalTagIDs.isEmpty,
              Set(snapshot.personalTagIDs).count == snapshot.personalTagIDs.count,
              !snapshot.embeddingKeys.isEmpty,
              embeddingIdentitySet.count == snapshot.embeddingKeys.count,
              !snapshot.decisions.isEmpty,
              expectedActiveBundle.map({
                  !$0.bundleRevision.isEmpty && Self.isLowercaseSHA256($0.weightsSHA256)
              }) ?? true,
              snapshot.embeddingKeys.allSatisfy({ key in
                  key.catalogScopeID == snapshot.catalogScopeID && key.contentRevision >= 0
              }),
              snapshot.decisions.allSatisfy({ decision in
                  decision.contentRevision >= 0
                      && snapshot.personalTagIDs.contains(decision.tagID)
                      && embeddingIdentitySet.contains(
                          "\(decision.assetID.uuidString.lowercased())|\(decision.contentRevision)"
                      )
              })
        else {
            throw LocalModelSuggestionClientError.invalidResponse
        }
        let requestPayload = PersonalCachedRebuildRequestPayload(
            requestID: requestID,
            expectedActiveBundle: expectedActiveBundle.map {
                PersonalRebuildRequestPayload.ExpectedActiveBundle(
                    bundleRevision: $0.bundleRevision,
                    weightsSHA256: $0.weightsSHA256
                )
            },
            snapshot: PersonalCachedRebuildRequestPayload.Snapshot(
                catalogScopeID: snapshot.catalogScopeID,
                decisionSnapshotRevision: snapshot.decisionSnapshotRevision,
                encoder: snapshot.encoder,
                personalTagIDs: snapshot.personalTagIDs.map {
                    $0.uuidString.lowercased()
                },
                labelVocabularyRevision: snapshot.labelVocabularyRevision,
                embeddingKeys: snapshot.embeddingKeys.map {
                    PersonalCachedRebuildRequestPayload.Snapshot.EmbeddingKey(
                        assetID: $0.assetID.uuidString.lowercased(),
                        contentRevision: String($0.contentRevision)
                    )
                },
                decisions: snapshot.decisions.map {
                    PersonalRebuildRequestPayload.Snapshot.Decision(
                        assetID: $0.assetID.uuidString.lowercased(),
                        contentRevision: String($0.contentRevision),
                        tagID: $0.tagID.uuidString.lowercased(),
                        state: $0.state
                    )
                }
            )
        )
        var request = URLRequest(
            url: endpoint.appendingPathComponent("v1/personal/rebuild-cached"),
            timeoutInterval: 300
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestPayload)
        return try await submitPersonalRebuild(
            request,
            requestID: requestID,
            catalogScopeID: snapshot.catalogScopeID,
            encoder: snapshot.encoder,
            personalTagIDs: snapshot.personalTagIDs,
            labelVocabularyRevision: snapshot.labelVocabularyRevision
        )
    }

    func suggestions(
        imageData: Data,
        requestID: String,
        target: ModelSuggestionTarget
    ) async throws -> [LocalModelSuggestion] {
        var request = URLRequest(
            url: endpoint.appendingPathComponent("v1/suggestions"),
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            SuggestionRequestPayload(
                requestID: requestID,
                imageBase64: imageData.base64EncodedString(),
                target: SuggestionTargetPayload(target)
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LocalModelSuggestionClientError.serviceUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw LocalModelSuggestionClientError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let code = try? JSONDecoder()
                .decode(ErrorResponsePayload.self, from: data)
                .detail.code
            throw LocalModelSuggestionClientError.rejected(
                statusCode: http.statusCode,
                code: code
            )
        }
        let payload: SuggestionResponsePayload
        do {
            payload = try JSONDecoder().decode(
                SuggestionResponsePayload.self,
                from: data
            )
        } catch {
            throw LocalModelSuggestionClientError.invalidResponse
        }
        guard payload.requestID == requestID else {
            throw LocalModelSuggestionClientError.identityMismatch
        }
        return try payload.suggestions.map { suggestion in
            try Self.validate(suggestion, target: target)
        }
    }

    private static func validate(
        _ payload: LocalModelSuggestion,
        target: ModelSuggestionTarget
    ) throws -> LocalModelSuggestion {
        guard payload.score.isFinite,
              !payload.provider.isEmpty,
              !payload.modelRevision.isEmpty,
              !payload.preprocessingRevision.isEmpty,
              !payload.policyRevision.isEmpty
        else {
            throw LocalModelSuggestionClientError.invalidResponse
        }
        switch target {
        case let .standard(expected):
            guard payload.track == .standard,
                  payload.conceptID?.isEmpty == false,
                  payload.tagID == nil,
                  payload.standardPackID == expected.standardPackID,
                  payload.standardPackRevision == expected.standardPackRevision,
                  payload.catalogScopeID == nil,
                  payload.bundleID == nil,
                  payload.bundleRevision == nil,
                  payload.elementCount == nil,
                  payload.labelVocabularyRevision == nil,
                  payload.weightsSHA256 == nil
            else {
                throw LocalModelSuggestionClientError.identityMismatch
            }
        case let .personal(expected):
            guard payload.track == .personal,
                  payload.conceptID == nil,
                  payload.tagID != nil,
                  payload.recommendedState == .suggested,
                  payload.catalogScopeID == expected.catalogScopeID,
                  payload.bundleID == expected.bundleID,
                  payload.bundleRevision == expected.bundleRevision,
                  payload.provider == expected.provider,
                  payload.modelID == expected.modelID,
                  payload.modelRevision == expected.modelRevision,
                  payload.preprocessingRevision == expected.preprocessingRevision,
                  payload.elementCount == expected.elementCount,
                  payload.labelVocabularyRevision == expected.labelVocabularyRevision,
                  payload.weightsSHA256 == expected.weightsSHA256,
                  payload.policyRevision == expected.policyRevision,
                  payload.standardPackID == nil,
                  payload.standardPackRevision == nil
            else {
                throw LocalModelSuggestionClientError.identityMismatch
            }
        }
        return payload
    }

    private func submitPersonalRebuild(
        _ request: URLRequest,
        requestID: String,
        catalogScopeID: String,
        encoder: PersonalTrainingEncoderIdentity,
        personalTagIDs: [UUID],
        labelVocabularyRevision: String
    ) async throws -> PersonalModelSuggestionCapability {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LocalModelSuggestionClientError.serviceUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw LocalModelSuggestionClientError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let code = try? JSONDecoder()
                .decode(ErrorResponsePayload.self, from: data)
                .detail.code
            throw LocalModelSuggestionClientError.rejected(
                statusCode: http.statusCode,
                code: code
            )
        }
        guard let payload = try? JSONDecoder().decode(
            PersonalRebuildResponsePayload.self,
            from: data
        ),
            payload.requestID == requestID,
            case let .available(capability) = try Self.personalAvailability(payload.personal),
            capability.target.catalogScopeID == catalogScopeID,
            capability.target.provider == encoder.provider,
            capability.target.modelID == encoder.modelID,
            capability.target.modelRevision == encoder.modelRevision,
            capability.target.preprocessingRevision == encoder.preprocessingRevision,
            capability.target.elementCount == encoder.elementCount,
            capability.target.labelVocabularyRevision == labelVocabularyRevision,
            capability.tagIDs == personalTagIDs
        else {
            throw LocalModelSuggestionClientError.identityMismatch
        }
        return capability
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
}
