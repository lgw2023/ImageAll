import Foundation
import ImageAllRemoteClient
import ImageAllRemoteProtocol
import XCTest

final class RemoteLibraryClientTests: XCTestCase {
    func testFetchesCapabilitiesAndSourcesWithBearerToken() async throws {
        let transport = MockTransport { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(request.url?.path, "/v1/capabilities")
            let payload = try JSONEncoder().encode(
                RemoteCapabilities(hostAppVersion: "1.2.3", listenPort: 8787)
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (payload, response)
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"),
            transport: transport
        )
        let capabilities = try await client.fetchCapabilities()
        XCTAssertEqual(capabilities.hostAppVersion, "1.2.3")
        XCTAssertEqual(capabilities.listenPort, 8787)
    }

    func testBuildsAssetPageQuery() async throws {
        let sourceID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let transport = MockTransport { request in
            XCTAssertEqual(request.url?.path, "/v1/assets")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let map = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(map["sourceIDs"], sourceID.uuidString)
            XCTAssertEqual(map["sort"], "newest")
            XCTAssertEqual(map["limit"], "40")
            XCTAssertEqual(map["q"], "beach")
            XCTAssertEqual(map["cursor"], "abc")
            let payload = try JSONEncoder().encode(RemoteAssetPage(items: [], nextCursor: nil))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (payload, response)
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"),
            transport: transport
        )
        _ = try await client.fetchAssets(
            RemoteAssetPageRequest(
                sourceIDs: [sourceID],
                searchText: "beach",
                sort: .newest,
                limit: 40,
                cursor: "abc"
            )
        )
    }

    func testMapsUnauthorizedAPIError() async throws {
        let transport = MockTransport { request in
            let payload = try JSONEncoder().encode(
                RemoteAPIError(code: .unauthorized, message: "invalid or missing bearer token")
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (payload, response)
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "bad"),
            transport: transport
        )
        do {
            _ = try await client.fetchSources()
            XCTFail("expected unauthorized")
        } catch let error as RemoteAPIError {
            XCTAssertEqual(error.code, .unauthorized)
        }
    }

    func testPostsTagDecisionBody() async throws {
        let operationID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let tagID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let assetID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let transport = MockTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/tag-decisions/batch")
            let body = try XCTUnwrap(request.httpBody)
            let decoded = try JSONDecoder().decode(RemoteBatchTagDecisionRequest.self, from: body)
            XCTAssertEqual(decoded.operationID, operationID)
            XCTAssertEqual(decoded.tagID, tagID)
            XCTAssertEqual(decoded.assetIDs, [assetID])
            XCTAssertEqual(decoded.action, .accept)
            let payload = try JSONEncoder().encode(
                RemoteBatchTagDecisionResponse(
                    operationID: operationID,
                    appliedAssetCount: 1,
                    replayed: false
                )
            )
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (payload, response)
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"),
            transport: transport
        )
        let response = try await client.applyTagDecision(
            RemoteBatchTagDecisionRequest(
                operationID: operationID,
                tagID: tagID,
                assetIDs: [assetID],
                action: .accept
            )
        )
        XCTAssertEqual(response.appliedAssetCount, 1)
        XCTAssertFalse(response.replayed)
    }

    func testPostsPresetTagInstallation() async throws {
        let operationID = UUID()
        let tag = RemoteTagSummary(
            id: UUID(),
            displayName: "风景",
            state: .active,
            groupID: UUID()
        )
        let transport = MockTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/tags/install-presets")
            let decoded = try JSONDecoder().decode(
                RemoteInstallPresetTagsRequest.self,
                from: try XCTUnwrap(request.httpBody)
            )
            XCTAssertEqual(decoded.operationID, operationID)
            return try Self.jsonResponse(
                RemoteInstallPresetTagsResponse(
                    operationID: operationID,
                    createdTags: [tag],
                    replayed: false
                ),
                for: request
            )
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(
                host: "127.0.0.1",
                port: 8787,
                accessToken: "secret"
            ),
            transport: transport
        )

        let response = try await client.installPresetTags(
            RemoteInstallPresetTagsRequest(operationID: operationID)
        )
        XCTAssertEqual(response.createdTags, [tag])
        XCTAssertFalse(response.replayed)
    }

    func testLoadsAssetDetailAndPreviewAtRequestedWidth() async throws {
        let assetID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let transport = MockTransport { request in
            if request.url?.path == "/v1/assets/\(assetID.uuidString)" {
                let detail = RemoteAssetDetail(
                    assetID: assetID,
                    sourceID: UUID(),
                    sourceName: "Fixture",
                    fileName: "sample.jpg",
                    relativePath: "sample.jpg",
                    mediaType: "image",
                    availability: .available,
                    contentRevision: 1,
                    acceptedTagCount: 0,
                    rejectedTagCount: 0,
                    mediaCreatedAtMs: nil,
                    mediaModifiedAtMs: nil,
                    width: 1200,
                    height: 800,
                    tags: []
                )
                return try Self.jsonResponse(detail, for: request)
            }
            XCTAssertEqual(request.url?.path, "/v1/assets/\(assetID.uuidString)/preview")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "w" })?.value, "1440")
            return (
                Data([0xFF, 0xD8, 0xFF]),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "image/jpeg"]
                )!
            )
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"),
            transport: transport
        )

        let detail = try await client.fetchAssetDetail(assetID: assetID)
        let preview = try await client.loadPreview(assetID: assetID, targetPixelWidth: 1440)

        XCTAssertEqual(detail.assetID, assetID)
        XCTAssertEqual(preview, Data([0xFF, 0xD8, 0xFF]))
    }

    func testDownloadsCloudPreviewOnlyThroughExplicitPost() async throws {
        let assetID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let transport = MockTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.url?.path,
                "/v1/assets/\(assetID.uuidString)/cloud-preview"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            return (
                Data([0x89, 0x50, 0x4E, 0x47]),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "image/png"]
                )!
            )
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(
                host: "127.0.0.1",
                port: 8787,
                accessToken: "secret"
            ),
            transport: transport
        )

        let preview = try await client.downloadCloudPreview(assetID: assetID)
        XCTAssertEqual(preview, Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testBuildsReviewQueueQueryAndPostsDecision() async throws {
        let tagID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let sourceID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let assetID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let operationID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let transport = MockTransport { request in
            if request.httpMethod == "GET" {
                XCTAssertEqual(request.url?.path, "/v1/review/queue")
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let map = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(map["tagID"], tagID.uuidString)
                XCTAssertEqual(map["sourceIDs"], sourceID.uuidString)
                XCTAssertEqual(map["mediaKind"], "video")
                XCTAssertEqual(map["limit"], "20")
                XCTAssertEqual(map["cursor"], "next")
                return try Self.jsonResponse(
                    RemoteReviewQueuePage(items: [], nextCursor: nil),
                    for: request
                )
            }

            XCTAssertEqual(request.url?.path, "/v1/review/decisions/batch")
            let body = try XCTUnwrap(request.httpBody)
            let decoded = try JSONDecoder().decode(RemoteBatchReviewDecisionRequest.self, from: body)
            XCTAssertEqual(decoded.operationID, operationID)
            XCTAssertEqual(decoded.tagID, tagID)
            XCTAssertEqual(decoded.assetIDs, [assetID])
            XCTAssertEqual(decoded.action, .accept)
            return try Self.jsonResponse(
                RemoteBatchReviewDecisionResponse(
                    operationID: operationID,
                    appliedAssetCount: 1,
                    replayed: false
                ),
                for: request
            )
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"),
            transport: transport
        )

        _ = try await client.fetchReviewQueue(
            RemoteReviewQueueRequest(
                tagID: tagID,
                sourceIDs: [sourceID],
                mediaKind: .video,
                limit: 20,
                cursor: "next"
            )
        )
        let response = try await client.applyReviewDecision(
            RemoteBatchReviewDecisionRequest(
                operationID: operationID,
                tagID: tagID,
                assetIDs: [assetID],
                action: .accept
            )
        )

        XCTAssertEqual(response.appliedAssetCount, 1)
    }

    func testPostsJobAction() async throws {
        let jobID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let transport = MockTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/jobs/\(jobID.uuidString)/actions")
            let body = try XCTUnwrap(request.httpBody)
            XCTAssertEqual(
                try JSONDecoder().decode(RemoteJobActionRequest.self, from: body).action,
                .pause
            )
            return (
                Data(),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
            )
        }
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "127.0.0.1", port: 8787, accessToken: "secret"),
            transport: transport
        )

        try await client.applyJobAction(jobID: jobID, action: .pause)
    }

    func testHostEndpointBracketsIPv6() throws {
        let endpoint = try RemoteHostEndpoint(
            host: "fe80::1",
            port: 8787,
            accessToken: "secret"
        )
        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://[fe80::1]:8787")
    }

    func testPublicHostEndpointUsesCanonicalSystemTrustedHTTPSURL() throws {
        let endpoint = try RemoteHostEndpoint(
            publicHTTPSBaseURL: " HTTPS://ImageAll.UltraHardcore.Net:443/ ",
            accessToken: "secret"
        )

        XCTAssertEqual(
            endpoint.baseURL.absoluteString,
            "https://imageall.ultrahardcore.net"
        )
        XCTAssertTrue(endpoint.usesTLS)
    }

    private static func jsonResponse<T: Encodable>(
        _ value: T,
        for request: URLRequest
    ) throws -> (Data, URLResponse) {
        (
            try JSONEncoder().encode(value),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

private struct MockTransport: RemoteHTTPTransporting {
    let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}
