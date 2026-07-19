import CryptoKit
import GRDB
import XCTest
@testable import ImageAll

final class PersonalizedSuggestionServiceTests: XCTestCase {
    func testLoopbackClientReturnsValidatedReadyServiceHealth() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelSuggestionURLProtocolStub.self]
        ModelSuggestionURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/health")
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
                      "status": "ready",
                      "service_version": "0.1.0",
                      "provider": {
                        "provider": "dinov2",
                        "model_id": "facebook/dinov2-small",
                        "model_revision": "model-v1",
                        "preprocessing_revision": "preprocessing-v1",
                        "element_count": 384
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

        let health = try await client.serviceHealth()

        XCTAssertEqual(
            health,
            .ready(
                serviceVersion: "0.1.0",
                provider: PersonalTrainingEncoderIdentity(
                    provider: "dinov2",
                    modelID: "facebook/dinov2-small",
                    modelRevision: "model-v1",
                    preprocessingRevision: "preprocessing-v1",
                    elementCount: 384
                )
            )
        )
    }

    func testLoopbackClientReturnsDegradedServiceHealthWithoutProvider() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelSuggestionURLProtocolStub.self]
        ModelSuggestionURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/health")
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
                      "status": "degraded",
                      "service_version": "0.1.0",
                      "provider": null
                    }
                    """.utf8
                )
            )
        }
        defer { ModelSuggestionURLProtocolStub.handler = nil }
        let client = try LoopbackModelSuggestionClient(
            session: URLSession(configuration: configuration)
        )

        let health = try await client.serviceHealth()

        XCTAssertEqual(health, .degraded(serviceVersion: "0.1.0"))
    }

    func testLoopbackClientRejectsReadyHealthWithoutProvider() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelSuggestionURLProtocolStub.self]
        ModelSuggestionURLProtocolStub.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    """
                    {
                      "status": "ready",
                      "service_version": "0.1.0",
                      "provider": null
                    }
                    """.utf8
                )
            )
        }
        defer { ModelSuggestionURLProtocolStub.handler = nil }
        let client = try LoopbackModelSuggestionClient(
            session: URLSession(configuration: configuration)
        )

        do {
            _ = try await client.serviceHealth()
            XCTFail("Expected inconsistent health payload to fail closed")
        } catch let error as LocalModelSuggestionClientError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testLoopbackClientReturnsAValidatedTrainingEmbedding() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelSuggestionURLProtocolStub.self]
        ModelSuggestionURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/embeddings")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBodyData(request))
                    as? [String: Any]
            )
            XCTAssertEqual(Set(body.keys), ["request_id", "image_base64"])
            XCTAssertEqual(body["request_id"] as? String, "embedding-fixture")
            XCTAssertEqual(body["image_base64"] as? String, Data("preview".utf8).base64EncodedString())
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
                      "request_id": "embedding-fixture",
                      "provider": "dinov2",
                      "model_id": "facebook/dinov2-small",
                      "model_revision": "model-v1",
                      "preprocessing_revision": "preprocessing-v1",
                      "element_type": "float32",
                      "element_count": 2,
                      "embedding": [0.25, -0.5]
                    }
                    """.utf8
                )
            )
        }
        defer { ModelSuggestionURLProtocolStub.handler = nil }
        let client = try LoopbackModelSuggestionClient(
            session: URLSession(configuration: configuration)
        )

        let embedding = try await client.embedding(
            imageData: Data("preview".utf8),
            requestID: "embedding-fixture"
        )

        XCTAssertEqual(
            embedding,
            PersonalTrainingEmbedding(
                encoder: PersonalTrainingEncoderIdentity(
                    provider: "dinov2",
                    modelID: "facebook/dinov2-small",
                    modelRevision: "model-v1",
                    preprocessingRevision: "preprocessing-v1",
                    elementCount: 2
                ),
                values: [0.25, -0.5]
            )
        )
    }

    func testLoopbackClientSendsAVersionedEmbeddingCacheKeyWithoutPrivateFields() async throws {
        let assetID = UUID(uuidString: "2D000000-0000-4000-8000-000000000001")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelSuggestionURLProtocolStub.self]
        ModelSuggestionURLProtocolStub.handler = { request in
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBodyData(request))
                    as? [String: Any]
            )
            XCTAssertEqual(
                Set(body.keys),
                ["request_id", "image_base64", "cache_key"]
            )
            let cacheKey = try XCTUnwrap(body["cache_key"] as? [String: Any])
            XCTAssertEqual(
                Set(cacheKey.keys),
                ["schema_revision", "catalog_scope_id", "asset_id", "content_revision"]
            )
            XCTAssertEqual(cacheKey["schema_revision"] as? Int, 1)
            XCTAssertEqual(
                cacheKey["catalog_scope_id"] as? String,
                "11111111-1111-4111-8111-111111111111"
            )
            XCTAssertEqual(
                cacheKey["asset_id"] as? String,
                assetID.uuidString.lowercased()
            )
            XCTAssertEqual(cacheKey["content_revision"] as? String, "7")
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
                      "request_id": "cached-embedding-fixture",
                      "provider": "dinov2",
                      "model_id": "facebook/dinov2-small",
                      "model_revision": "model-v1",
                      "preprocessing_revision": "preprocessing-v1",
                      "element_type": "float32",
                      "element_count": 2,
                      "embedding": [0.25, -0.5]
                    }
                    """.utf8
                )
            )
        }
        defer { ModelSuggestionURLProtocolStub.handler = nil }
        let client = try LoopbackModelSuggestionClient(
            session: URLSession(configuration: configuration)
        )

        _ = try await client.embedding(
            imageData: Data("preview".utf8),
            requestID: "cached-embedding-fixture",
            cacheKey: PersonalTrainingEmbeddingCacheKey(
                catalogScopeID: "11111111-1111-4111-8111-111111111111",
                assetID: assetID,
                contentRevision: 7
            )
        )
    }

    func testLoopbackClientRebuildsFromVersionedEmbeddingsAndManualDecisions() async throws {
        let tagID = UUID(uuidString: "2C000000-0000-4000-8000-000000000001")!
        let assetID = UUID(uuidString: "2D000000-0000-4000-8000-000000000001")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelSuggestionURLProtocolStub.self]
        ModelSuggestionURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/personal/rebuild")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBodyData(request))
                    as? [String: Any]
            )
            XCTAssertEqual(body["request_id"] as? String, "rebuild-fixture")
            let expected = try XCTUnwrap(body["expected_active_bundle"] as? [String: Any])
            XCTAssertEqual(expected["bundle_revision"] as? String, "bundle-v1")
            XCTAssertEqual(
                expected["weights_sha256"] as? String,
                String(repeating: "a", count: 64)
            )
            let snapshot = try XCTUnwrap(body["snapshot"] as? [String: Any])
            XCTAssertEqual(snapshot["schema_revision"] as? Int, 1)
            XCTAssertEqual(snapshot["catalog_scope_id"] as? String, "catalog-fixture")
            XCTAssertEqual(
                snapshot["decision_snapshot_revision"] as? String,
                String(repeating: "b", count: 64)
            )
            XCTAssertEqual(
                snapshot["label_vocabulary_revision"] as? String,
                String(repeating: "c", count: 64)
            )
            XCTAssertEqual(snapshot["personal_tag_ids"] as? [String], [tagID.uuidString.lowercased()])
            let embedding = try XCTUnwrap(
                (snapshot["embeddings"] as? [[String: Any]])?.first
            )
            XCTAssertEqual(embedding["asset_id"] as? String, assetID.uuidString.lowercased())
            XCTAssertEqual(embedding["content_revision"] as? String, "1")
            XCTAssertEqual(embedding["embedding"] as? [Double], [0.25, -0.5])
            let decision = try XCTUnwrap(
                (snapshot["decisions"] as? [[String: Any]])?.first
            )
            XCTAssertEqual(decision["tag_id"] as? String, tagID.uuidString.lowercased())
            XCTAssertEqual(decision["state"] as? String, "manualAccepted")
            XCTAssertNil(snapshot["image"])
            XCTAssertNil(snapshot["image_base64"])
            XCTAssertNil(snapshot["path"])
            XCTAssertNil(snapshot["bookmark"])
            XCTAssertNil(snapshot["bytes"])
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
                      "request_id": "rebuild-fixture",
                      "personal": {
                        "status": "available",
                        "catalog_scope_id": "catalog-fixture",
                        "bundle_id": "personal-fixture",
                        "bundle_revision": "bundle-v2",
                        "encoder": {
                          "provider": "dinov2",
                          "model_id": "facebook/dinov2-small",
                          "model_revision": "model-v1",
                          "preprocessing_revision": "preprocessing-v1",
                          "element_count": 2
                        },
                        "label_vocabulary_revision": "\(String(repeating: "c", count: 64))",
                        "weights_sha256": "\(String(repeating: "d", count: 64))",
                        "policy_revision": "personal-policy-v1",
                        "tag_ids": ["\(tagID.uuidString.lowercased())"]
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
        let encoder = PersonalTrainingEncoderIdentity(
            provider: "dinov2",
            modelID: "facebook/dinov2-small",
            modelRevision: "model-v1",
            preprocessingRevision: "preprocessing-v1",
            elementCount: 2
        )

        let capability = try await client.rebuildPersonalModel(
            requestID: "rebuild-fixture",
            expectedActiveBundle: PersonalModelActiveBundleIdentity(
                bundleRevision: "bundle-v1",
                weightsSHA256: String(repeating: "a", count: 64)
            ),
            snapshot: PersonalModelRebuildSnapshot(
                catalogScopeID: "catalog-fixture",
                decisionSnapshotRevision: String(repeating: "b", count: 64),
                encoder: encoder,
                personalTagIDs: [tagID],
                labelVocabularyRevision: String(repeating: "c", count: 64),
                embeddings: [
                    PersonalTrainingEmbeddingRow(
                        assetID: assetID,
                        contentRevision: 1,
                        values: [0.25, -0.5]
                    ),
                ],
                decisions: [
                    PersonalTrainingDecision(
                        assetID: assetID,
                        contentRevision: 1,
                        tagID: tagID,
                        state: .manualAccepted
                    ),
                ]
            )
        )

        XCTAssertEqual(capability.target.bundleRevision, "bundle-v2")
        XCTAssertEqual(capability.target.catalogScopeID, "catalog-fixture")
        XCTAssertEqual(capability.tagIDs, [tagID])
    }

    func testLoopbackClientRebuildsFromCacheKeysWithoutImageFields() async throws {
        let catalogScopeID = "11111111-1111-4111-8111-111111111111"
        let tagID = UUID(uuidString: "2C000000-0000-4000-8000-000000000001")!
        let assetID = UUID(uuidString: "2D000000-0000-4000-8000-000000000001")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelSuggestionURLProtocolStub.self]
        ModelSuggestionURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/personal/rebuild-cached")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBodyData(request))
                    as? [String: Any]
            )
            XCTAssertEqual(
                Set(body.keys),
                ["request_id", "expected_active_bundle", "snapshot"]
            )
            let snapshot = try XCTUnwrap(body["snapshot"] as? [String: Any])
            XCTAssertEqual(
                Set(snapshot.keys),
                [
                    "schema_revision", "catalog_scope_id",
                    "decision_snapshot_revision", "encoder",
                    "personal_tag_ids", "label_vocabulary_revision",
                    "embedding_keys", "decisions",
                ]
            )
            let key = try XCTUnwrap(
                (snapshot["embedding_keys"] as? [[String: Any]])?.first
            )
            XCTAssertEqual(Set(key.keys), ["asset_id", "content_revision"])
            XCTAssertEqual(key["asset_id"] as? String, assetID.uuidString.lowercased())
            XCTAssertEqual(key["content_revision"] as? String, "1")
            for forbidden in ["image", "image_base64", "path", "bookmark", "bytes"] {
                XCTAssertNil(snapshot[forbidden])
            }
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
                      "request_id": "cached-rebuild-fixture",
                      "personal": {
                        "status": "available",
                        "catalog_scope_id": "\(catalogScopeID)",
                        "bundle_id": "personal-fixture",
                        "bundle_revision": "bundle-v2",
                        "encoder": {
                          "provider": "dinov2",
                          "model_id": "facebook/dinov2-small",
                          "model_revision": "model-v1",
                          "preprocessing_revision": "preprocessing-v1",
                          "element_count": 2
                        },
                        "label_vocabulary_revision": "\(String(repeating: "c", count: 64))",
                        "weights_sha256": "\(String(repeating: "d", count: 64))",
                        "policy_revision": "personal-policy-v1",
                        "tag_ids": ["\(tagID.uuidString.lowercased())"]
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
        let encoder = PersonalTrainingEncoderIdentity(
            provider: "dinov2",
            modelID: "facebook/dinov2-small",
            modelRevision: "model-v1",
            preprocessingRevision: "preprocessing-v1",
            elementCount: 2
        )

        let capability = try await client.rebuildPersonalModelFromCache(
            requestID: "cached-rebuild-fixture",
            expectedActiveBundle: nil,
            snapshot: PersonalModelCachedRebuildSnapshot(
                catalogScopeID: catalogScopeID,
                decisionSnapshotRevision: String(repeating: "b", count: 64),
                encoder: encoder,
                personalTagIDs: [tagID],
                labelVocabularyRevision: String(repeating: "c", count: 64),
                embeddingKeys: [
                    PersonalTrainingEmbeddingCacheKey(
                        catalogScopeID: catalogScopeID,
                        assetID: assetID,
                        contentRevision: 1
                    ),
                ],
                decisions: [
                    PersonalTrainingDecision(
                        assetID: assetID,
                        contentRevision: 1,
                        tagID: tagID,
                        state: .manualAccepted
                    ),
                ]
            )
        )

        XCTAssertEqual(capability.target.bundleRevision, "bundle-v2")
        XCTAssertEqual(capability.target.catalogScopeID, catalogScopeID)
        XCTAssertEqual(capability.tagIDs, [tagID])
    }

    func testLoopbackClientDiscoversTheLoadedStandardPackageIdentity() async throws {
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
                      "standard": {
                        "status": "available",
                        "standard_pack_id": "imageall-public-fixture",
                        "standard_pack_revision": "pack-v1",
                        "manifest_sha256": "dc7b0a9a8391978a56b7e55f97c1abc73fe9e9834f1c2dd16152fc13883bd873",
                        "ontology_id": "imageall-public-fixture",
                        "ontology_revision": "ontology-v1",
                        "provider": {
                          "provider": "rgb-linear",
                          "model_id": "imageall/fixture-scene-linear",
                          "model_revision": "model-v1",
                          "preprocessing_revision": "rgb-channel-mean-v1"
                        },
                        "mapping_revision": "mapping-v1",
                        "policy_revision": "policy-v1",
                        "weights_sha256": "4129427105a9392e02b5306b657a029f7d0034f05a10d1363254e5f3d579fce9"
                      },
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

        let availability = try await client.standardCapability()

        guard case let .available(capability) = availability else {
            return XCTFail("expected an available standard package")
        }
        XCTAssertEqual(
            capability.target,
            StandardModelSuggestionTarget(
                standardPackID: "imageall-public-fixture",
                standardPackRevision: "pack-v1"
            )
        )
        XCTAssertEqual(
            capability.manifestSHA256,
            "dc7b0a9a8391978a56b7e55f97c1abc73fe9e9834f1c2dd16152fc13883bd873"
        )
        XCTAssertEqual(capability.ontologyID, "imageall-public-fixture")
        XCTAssertEqual(capability.ontologyRevision, "ontology-v1")
        XCTAssertEqual(capability.provider, "rgb-linear")
        XCTAssertEqual(capability.modelID, "imageall/fixture-scene-linear")
        XCTAssertEqual(capability.modelRevision, "model-v1")
        XCTAssertEqual(capability.preprocessingRevision, "rgb-channel-mean-v1")
        XCTAssertEqual(capability.mappingRevision, "mapping-v1")
        XCTAssertEqual(capability.policyRevision, "policy-v1")
        XCTAssertEqual(
            capability.weightsSHA256,
            "4129427105a9392e02b5306b657a029f7d0034f05a10d1363254e5f3d579fce9"
        )
    }

    func testLoopbackClientReportsAnExplicitlyUnavailableStandardPackage() async throws {
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
                      "standard": {"status": "unavailable"},
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

        let availability = try await client.standardCapability()

        XCTAssertEqual(availability, .unavailable)
    }

    func testLoopbackClientRejectsMalformedStandardCapabilities() async throws {
        let malformedStandardPayloads = [
            """
            {
              "status": "available",
              "standard_pack_id": "imageall-public-fixture",
              "standard_pack_revision": "pack-v1",
              "manifest_sha256": "dc7b0a9a8391978a56b7e55f97c1abc73fe9e9834f1c2dd16152fc13883bd873",
              "ontology_id": "imageall-public-fixture",
              "ontology_revision": "ontology-v1",
              "provider": {
                "provider": "rgb-linear",
                "model_id": "imageall/fixture-scene-linear",
                "model_revision": "model-v1",
                "preprocessing_revision": "rgb-channel-mean-v1"
              },
              "mapping_revision": "mapping-v1",
              "policy_revision": "policy-v1"
            }
            """,
            """
            {
              "status": "available",
              "standard_pack_id": "imageall-public-fixture",
              "standard_pack_revision": "pack-v1",
              "manifest_sha256": "DC7B0A9A8391978A56B7E55F97C1ABC73FE9E9834F1C2DD16152FC13883BD873",
              "ontology_id": "imageall-public-fixture",
              "ontology_revision": "ontology-v1",
              "provider": {
                "provider": "rgb-linear",
                "model_id": "imageall/fixture-scene-linear",
                "model_revision": "model-v1",
                "preprocessing_revision": "rgb-channel-mean-v1"
              },
              "mapping_revision": "mapping-v1",
              "policy_revision": "policy-v1",
              "weights_sha256": "4129427105a9392e02b5306b657a029f7d0034f05a10d1363254e5f3d579fce9"
            }
            """,
            """
            {"status": "unavailable", "standard_pack_id": "contradiction"}
            """,
            """
            {"status": "unavailable", "unexpected": "field"}
            """,
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelSuggestionURLProtocolStub.self]
        defer { ModelSuggestionURLProtocolStub.handler = nil }
        let client = try LoopbackModelSuggestionClient(
            session: URLSession(configuration: configuration)
        )

        for standardPayload in malformedStandardPayloads {
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
                          "standard": \(standardPayload),
                          "personal": {"status": "unavailable"}
                        }
                        """.utf8
                    )
                )
            }
            do {
                _ = try await client.standardCapability()
                XCTFail("expected malformed standard capability to fail")
            } catch let error as LocalModelSuggestionClientError {
                XCTAssertEqual(error, .invalidResponse)
            }
        }
    }

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
