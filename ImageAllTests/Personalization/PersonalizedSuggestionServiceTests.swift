import CryptoKit
import GRDB
import XCTest
@testable import ImageAll

final class PersonalizedSuggestionServiceTests: XCTestCase {
    func testLoopbackClientDiscoversTheLoadedPersonalBundleIdentity() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelSuggestionURLProtocolStub.self]
        ModelSuggestionURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/capabilities")
            XCTAssertEqual(request.httpMethod, "GET")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    """
                    {
                      "service_version": "0.1.0",
                      "personal": {
                        "status": "available",
                        "catalog_scope_id": "catalog-fixture",
                        "bundle_id": "personal-fixture",
                        "bundle_revision": "bundle-v1",
                        "encoder": {
                          "provider": "dinov2",
                          "model_id": "facebook/dinov2-small",
                          "model_revision": "model-v1",
                          "preprocessing_revision": "preprocessing-v1",
                          "element_count": 384
                        },
                        "label_vocabulary_revision": "personal-tags-v1",
                        "weights_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                        "policy_revision": "personal-policy-v1",
                        "tag_ids": ["2c000000-0000-4000-8000-000000000001"]
                      }
                    }
                    """.utf8
                )
            )
        }
        defer { ModelSuggestionURLProtocolStub.handler = nil }
        let client = try LoopbackModelSuggestionClient(
            session: URLSession(configuration: configuration)
        )

        let availability = try await client.personalCapability()

        let capability: PersonalModelSuggestionCapability
        switch availability {
        case .unavailable:
            return XCTFail("expected an available personal bundle")
        case let .available(value):
            capability = value
        }
        XCTAssertEqual(capability.target.catalogScopeID, "catalog-fixture")
        XCTAssertEqual(capability.target.bundleID, "personal-fixture")
        XCTAssertEqual(capability.target.provider, "dinov2")
        XCTAssertEqual(capability.target.modelID, "facebook/dinov2-small")
        XCTAssertEqual(capability.target.elementCount, 384)
        XCTAssertEqual(
            capability.target.weightsSHA256,
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        XCTAssertEqual(
            capability.tagIDs,
            [UUID(uuidString: "2C000000-0000-4000-8000-000000000001")!]
        )
    }

    func testLoopbackClientReportsAnExplicitlyUnavailablePersonalBundle() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelSuggestionURLProtocolStub.self]
        ModelSuggestionURLProtocolStub.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    """
                    {
                      "service_version": "0.1.0",
                      "personal": {"status": "unavailable"}
                    }
                    """.utf8
                )
            )
        }
        defer { ModelSuggestionURLProtocolStub.handler = nil }
        let client = try LoopbackModelSuggestionClient(
            session: URLSession(configuration: configuration)
        )

        let availability = try await client.personalCapability()

        XCTAssertEqual(availability, .unavailable)
    }

    func testLoopbackClientReturnsOnlyTheRequestedPersonalBundleTags() async throws {
        let endpoint = URL(string: "http://127.0.0.1:8765")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelSuggestionURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let tagID = UUID(uuidString: "2C000000-0000-4000-8000-000000000001")!
        ModelSuggestionURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/suggestions")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try requestBodyData(request)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let target = try XCTUnwrap(json["target"] as? [String: Any])
            XCTAssertEqual(target["track"] as? String, "personal")
            XCTAssertEqual(target["catalog_scope_id"] as? String, "catalog-fixture")
            XCTAssertEqual(target["bundle_id"] as? String, "personal-fixture")
            XCTAssertEqual(target["provider"] as? String, "dinov2")
            XCTAssertEqual(target["model_id"] as? String, "facebook/dinov2-small")
            XCTAssertEqual(target["model_revision"] as? String, "model-v1")
            XCTAssertEqual(target["preprocessing_revision"] as? String, "preprocessing-v1")
            XCTAssertEqual(target["element_count"] as? Int, 384)
            XCTAssertEqual(
                target["weights_sha256"] as? String,
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            )
            XCTAssertEqual(target["policy_revision"] as? String, "personal-policy-v1")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try personalSuggestionResponseData(
                    requestID: "request-fixture",
                    tagID: tagID,
                    bundleRevision: "bundle-v1"
                )
            )
        }
        defer { ModelSuggestionURLProtocolStub.handler = nil }
        let client = try LoopbackModelSuggestionClient(
            endpoint: endpoint,
            session: session
        )

        let suggestions = try await client.suggestions(
            imageData: Data([0x89, 0x50, 0x4E, 0x47]),
            requestID: "request-fixture",
            target: .personal(
                PersonalModelSuggestionTarget(
                    catalogScopeID: "catalog-fixture",
                    bundleID: "personal-fixture",
                    bundleRevision: "bundle-v1",
                    provider: "dinov2",
                    modelID: "facebook/dinov2-small",
                    modelRevision: "model-v1",
                    preprocessingRevision: "preprocessing-v1",
                    elementCount: 384,
                    labelVocabularyRevision: "personal-tags-v1",
                    weightsSHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    policyRevision: "personal-policy-v1"
                )
            )
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].tagID, tagID)
        XCTAssertNil(suggestions[0].conceptID)
        XCTAssertEqual(suggestions[0].recommendedState, .suggested)
        XCTAssertEqual(suggestions[0].bundleRevision, "bundle-v1")
    }

    func testLoopbackClientReturnsAValidatedStandardConcept() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelSuggestionURLProtocolStub.self]
        ModelSuggestionURLProtocolStub.handler = { request in
            let target = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBodyData(request))
                    as? [String: Any]
            )["target"] as? [String: Any]
            XCTAssertEqual(target?["track"] as? String, "standard")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    """
                    {
                      "request_id": "standard-request",
                      "suggestions": [{
                        "track": "standard",
                        "concept_id": "scene.water",
                        "tag_id": null,
                        "score": 0.9,
                        "recommended_state": "autoAssigned",
                        "standard_pack_id": "imageall-public-fixture",
                        "standard_pack_revision": "pack-v1",
                        "ontology_id": "imageall-public",
                        "ontology_revision": "ontology-v1",
                        "provider": "rgb-linear",
                        "model_revision": "model-v1",
                        "preprocessing_revision": "rgb-channel-mean-v1",
                        "mapping_revision": "mapping-v1",
                        "policy_revision": "policy-v1"
                      }]
                    }
                    """.utf8
                )
            )
        }
        defer { ModelSuggestionURLProtocolStub.handler = nil }
        let client = try LoopbackModelSuggestionClient(
            session: URLSession(configuration: configuration)
        )

        let suggestions = try await client.suggestions(
            imageData: Data([0x89, 0x50, 0x4E, 0x47]),
            requestID: "standard-request",
            target: .standard(
                StandardModelSuggestionTarget(
                    standardPackID: "imageall-public-fixture",
                    standardPackRevision: "pack-v1"
                )
            )
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].conceptID, "scene.water")
        XCTAssertNil(suggestions[0].tagID)
        XCTAssertEqual(suggestions[0].recommendedState, .autoAssigned)
    }

    func testLoopbackClientRejectsAPersonalSuggestionFromAnotherBundle() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelSuggestionURLProtocolStub.self]
        ModelSuggestionURLProtocolStub.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try personalSuggestionResponseData(
                    requestID: "personal-mismatch",
                    tagID: UUID(uuidString: "2C000000-0000-4000-8000-000000000001")!,
                    bundleRevision: "stale-bundle"
                )
            )
        }
        defer { ModelSuggestionURLProtocolStub.handler = nil }
        let client = try LoopbackModelSuggestionClient(
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await client.suggestions(
                imageData: Data([0x89, 0x50, 0x4E, 0x47]),
                requestID: "personal-mismatch",
                target: .personal(
                    PersonalModelSuggestionTarget(
                        catalogScopeID: "catalog-fixture",
                        bundleID: "personal-fixture",
                        bundleRevision: "bundle-v1",
                        provider: "dinov2",
                        modelID: "facebook/dinov2-small",
                        modelRevision: "model-v1",
                        preprocessingRevision: "preprocessing-v1",
                        elementCount: 384,
                        labelVocabularyRevision: "personal-tags-v1",
                        weightsSHA256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                        policyRevision: "personal-policy-v1"
                    )
                )
            )
            XCTFail("stale personal bundle response must fail closed")
        } catch {
            XCTAssertEqual(
                error as? LocalModelSuggestionClientError,
                .identityMismatch
            )
        }
    }

    func testLoopbackClientTreatsAnOfflineServiceAsOptional() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelSuggestionURLProtocolStub.self]
        ModelSuggestionURLProtocolStub.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }
        defer { ModelSuggestionURLProtocolStub.handler = nil }
        let client = try LoopbackModelSuggestionClient(
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await client.suggestions(
                imageData: Data([0x89, 0x50, 0x4E, 0x47]),
                requestID: "offline-request",
                target: .standard(
                    StandardModelSuggestionTarget(
                        standardPackID: "imageall-public-fixture",
                        standardPackRevision: "pack-v1"
                    )
                )
            )
            XCTFail("offline optional service must not return suggestions")
        } catch {
            XCTAssertEqual(
                error as? LocalModelSuggestionClientError,
                .serviceUnavailable
            )
        }
    }

    func testBuildsVersionedModelAndKeepsManualDecisionAuthoritative() async throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let accepted = [fixture.ids.assetNewest, fixture.ids.assetMiddle]
        let rejected = [fixture.ids.assetDuplicateTimeA, fixture.ids.assetDuplicateTimeB]
        let positiveCandidate = fixture.ids.assetNocaseLower
        let negativeCandidate = fixture.ids.assetNocaseUpper
        _ = try fixture.tags.batchReject(
            tagID: fixture.ids.tagFamily,
            assetIDs: rejected,
            timestampMs: DatabaseTestSupport.timestampMs + 1
        )
        try await fixture.database.pool.write { db in
            try db.execute(
                sql: "UPDATE source SET state = 'active' WHERE id = ?",
                arguments: [fixture.ids.sourceA.uuidString.lowercased()]
            )
        }

        let loader = StubFeatureVectorLoader(
            database: fixture.database,
            vectors: [
                accepted[0]: [0, 0],
                accepted[1]: [0, 1],
                rejected[0]: [10, 10],
                rejected[1]: [10, 9],
                positiveCandidate: [0, 0.5],
                negativeCandidate: [10, 9.5],
            ]
        )
        let service = PersonalizedSuggestionService(
            database: fixture.database,
            featureLoader: loader,
            clock: FixedJobClock(nowMs: DatabaseTestSupport.timestampMs + 2)
        )

        let result = try await service.generateSuggestions(
            tagID: fixture.ids.tagFamily,
            candidateAssetIDs: [positiveCandidate, negativeCandidate]
        )

        XCTAssertEqual(result.modelRevision, 1)
        XCTAssertEqual(result.positiveSampleCount, 2)
        XCTAssertEqual(result.negativeSampleCount, 2)
        XCTAssertEqual(result.evaluatedCandidateCount, 2)
        XCTAssertEqual(result.predictedCandidateCount, 1)
        let catalog = GRDBPersonalizationRepository(database: fixture.database)
        XCTAssertEqual(
            try catalog.pendingPredictions(tagID: fixture.ids.tagFamily, limit: 10).map(\.assetID),
            [positiveCandidate]
        )

        _ = try fixture.tags.batchReject(
            tagID: fixture.ids.tagFamily,
            assetIDs: [positiveCandidate],
            timestampMs: DatabaseTestSupport.timestampMs + 3
        )
        XCTAssertEqual(try catalog.pendingPredictions(tagID: fixture.ids.tagFamily, limit: 10), [])

        let revised = try await service.generateSuggestions(
            tagID: fixture.ids.tagFamily,
            candidateAssetIDs: [negativeCandidate]
        )
        XCTAssertEqual(revised.modelRevision, 2)
        XCTAssertEqual(revised.negativeSampleCount, 3)
        XCTAssertEqual(try catalog.pendingPredictions(tagID: fixture.ids.tagFamily, limit: 10), [])
        let modelFacts = try await fixture.database.pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT current_revision FROM tag_model WHERE tag_id = ?", arguments: [fixture.ids.tagFamily.uuidString.lowercased()]),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag_model_revision WHERE tag_id = ?", arguments: [fixture.ids.tagFamily.uuidString.lowercased()])
            )
        }
        XCTAssertEqual(modelFacts.0, 2)
        XCTAssertEqual(modelFacts.1, 2)
    }

    func testGeneratesSuggestionsFromPhotosSamplesAndCandidate() async throws {
        let fixture = try CatalogQueryTestSupport.openQueryDatabase()
        let sourceID = UUID(uuidString: "2B000000-0000-4000-8000-000000000001")!
        let tagID = UUID(uuidString: "2C000000-0000-4000-8000-000000000001")!
        let assetIDs = (1 ... 5).map {
            UUID(uuidString: String(format: "2D000000-0000-4000-8000-%012X", $0))!
        }
        try await fixture.database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source (id, kind, display_name, bookmark, state, created_at_ms, updated_at_ms)
                VALUES (?, 'photos', 'Apple Photos', NULL, 'active', ?, ?)
                """,
                arguments: [
                    sourceID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO tag (id, name, normalized_name, state, created_at_ms, updated_at_ms)
                VALUES (?, 'Photos', 'photos', 'active', ?, ?)
                """,
                arguments: [
                    tagID.uuidString.lowercased(),
                    DatabaseTestSupport.timestampMs,
                    DatabaseTestSupport.timestampMs,
                ]
            )
            for (index, assetID) in assetIDs.enumerated() {
                try db.execute(
                    sql: """
                    INSERT INTO asset (
                        id, source_id, locator_kind, relative_path, photos_local_identifier,
                        locator_state, media_type, file_name, content_revision, availability,
                        record_created_at_ms, record_updated_at_ms
                    ) VALUES (?, ?, 'photos', NULL, ?, 'current', 'public.jpeg', ?, 1, 'available', ?, ?)
                    """,
                    arguments: [
                        assetID.uuidString.lowercased(), sourceID.uuidString.lowercased(),
                        "photos-service-\(index)", "photo-\(index).jpg",
                        DatabaseTestSupport.timestampMs, DatabaseTestSupport.timestampMs,
                    ]
                )
            }
            for assetID in assetIDs.prefix(2) {
                try db.execute(
                    sql: "INSERT INTO asset_tag_decision VALUES (?, ?, 'accepted', ?)",
                    arguments: [
                        assetID.uuidString.lowercased(), tagID.uuidString.lowercased(),
                        DatabaseTestSupport.timestampMs,
                    ]
                )
            }
            for assetID in assetIDs.dropFirst(2).prefix(2) {
                try db.execute(
                    sql: "INSERT INTO asset_tag_decision VALUES (?, ?, 'rejected', ?)",
                    arguments: [
                        assetID.uuidString.lowercased(), tagID.uuidString.lowercased(),
                        DatabaseTestSupport.timestampMs,
                    ]
                )
            }
        }
        let loader = StubFeatureVectorLoader(
            database: fixture.database,
            vectors: [
                assetIDs[0]: [0, 0], assetIDs[1]: [0, 1],
                assetIDs[2]: [10, 10], assetIDs[3]: [10, 9],
                assetIDs[4]: [0, 0.5],
            ]
        )
        let service = PersonalizedSuggestionService(
            database: fixture.database,
            featureLoader: loader,
            clock: FixedJobClock(nowMs: DatabaseTestSupport.timestampMs)
        )

        let result = try await service.generateSuggestions(
            tagID: tagID,
            candidateAssetIDs: [assetIDs[4]]
        )

        XCTAssertEqual(result.positiveSampleCount, 2)
        XCTAssertEqual(result.negativeSampleCount, 2)
        XCTAssertEqual(result.predictedCandidateCount, 1)
    }
}

private func requestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else {
            throw stream.streamError ?? URLError(.cannotDecodeContentData)
        }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

private func personalSuggestionResponseData(
    requestID: String,
    tagID: UUID,
    bundleRevision: String
) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "request_id": requestID,
            "suggestions": [[
                "track": "personal",
                "concept_id": NSNull(),
                "tag_id": tagID.uuidString.lowercased(),
                "score": 1.25,
                "recommended_state": "suggested",
                "catalog_scope_id": "catalog-fixture",
                "bundle_id": "personal-fixture",
                "bundle_revision": bundleRevision,
                "provider": "dinov2",
                "model_id": "facebook/dinov2-small",
                "model_revision": "model-v1",
                "preprocessing_revision": "preprocessing-v1",
                "element_count": 384,
                "label_vocabulary_revision": "personal-tags-v1",
                "weights_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "policy_revision": "personal-policy-v1",
                "standard_pack_id": NSNull(),
                "standard_pack_revision": NSNull(),
                "ontology_id": NSNull(),
                "ontology_revision": NSNull(),
                "mapping_revision": NSNull(),
            ]],
        ],
        options: [.sortedKeys]
    )
}

private final class ModelSuggestionURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private actor StubFeatureVectorLoader: FeatureVectorLoading {
    let database: CatalogDatabase
    let vectors: [UUID: [Float]]

    init(database: CatalogDatabase, vectors: [UUID: [Float]]) {
        self.database = database
        self.vectors = vectors
    }

    func loadOrGenerate(assetID: UUID) async throws -> FeatureVectorPayload {
        guard let values = vectors[assetID] else {
            throw FeaturePrintError.assetNotFound
        }
        let contentRevision = try await database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT content_revision FROM asset WHERE id = ?",
                arguments: [assetID.uuidString.lowercased()]
            )
        }
        guard let contentRevision else {
            throw FeaturePrintError.assetNotFound
        }
        let data = values.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.size)
        }
        let digest = Data(SHA256.hash(data: data))
        let identity = FeatureIdentity(assetID: assetID, contentRevision: contentRevision)
        let canonical = assetID.uuidString.lowercased()
        let shard = String(canonical.replacingOccurrences(of: "-", with: "").prefix(2))
        try GRDBPersonalizationRepository(database: database).registerFeature(
            FeatureRegistration(
                identity: identity,
                elementCount: values.count,
                byteCount: data.count,
                vectorSHA256: digest,
                cacheKey: "objects/\(shard)/\(canonical)-stub.fprint",
                createdAtMs: DatabaseTestSupport.timestampMs
            )
        )
        return FeatureVectorPayload(
            identity: identity,
            elementCount: values.count,
            vectorData: data,
            vectorSHA256: digest,
            origin: .generated
        )
    }
}
