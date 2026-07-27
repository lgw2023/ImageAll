import Foundation
import ImageAllRemoteProtocol
import XCTest
@testable import ImageAll

final class RemoteHTTPServerTests: XCTestCase {
    func testUnauthorizedWithoutBearerToken() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let facade = RemoteCatalogFacade(
            catalog: RemoteHTTPServerTestCatalog(),
            hostAppVersion: "1.0.0",
            listenPort: Int(port)
        )
        let server = RemoteHTTPServer(
            facade: facade,
            accessToken: "secret-token",
            port: port
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/capabilities")!)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        await server.stop()

        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 401)
        let error = try JSONDecoder().decode(RemoteAPIError.self, from: data)
        XCTAssertEqual(error.code, .unauthorized)
    }

    func testCapabilitiesWithBearerToken() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let facade = RemoteCatalogFacade(
            catalog: RemoteHTTPServerTestCatalog(),
            hostAppVersion: "2.3.4",
            listenPort: Int(port)
        )
        let server = RemoteHTTPServer(
            facade: facade,
            accessToken: "secret-token",
            port: port
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/capabilities")!)
        request.httpMethod = "GET"
        request.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        await server.stop()

        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        let capabilities = try JSONDecoder().decode(RemoteCapabilities.self, from: data)
        XCTAssertEqual(capabilities.hostAppVersion, "2.3.4")
        XCTAssertEqual(capabilities.protocolVersion, RemoteProtocolVersion.current)
    }
}

private struct RemoteHTTPServerTestCatalog: RemoteCatalogServing {
    func fetchSources() throws -> [LibrarySourceSummary] { [] }

    func fetchAssetPage(
        filter: AssetPageFilter,
        sort: AssetPageSort,
        cursor: AssetPageCursor?
    ) throws -> AssetPageResult {
        AssetPageResult(items: [], nextCursor: nil)
    }

    func loadThumbnail(assetID: UUID) async throws -> Data {
        Data()
    }

    func mutateTag(
        tagID: UUID,
        assetIDs: [UUID],
        action: LibraryTagDecisionAction
    ) throws -> TagMutationPriorStateSnapshot {
        TagMutationPriorStateSnapshot(tagID: tagID, priorStates: [])
    }
}
