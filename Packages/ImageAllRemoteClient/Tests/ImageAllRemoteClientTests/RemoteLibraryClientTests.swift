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
}

private struct MockTransport: RemoteHTTPTransporting {
    let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}
