import Foundation
import ImageAllRemoteProtocol
import XCTest
@testable import ImageAll

final class RemoteHTTPServerTests: XCTestCase {
    private static let legacyDebugToken = "secret-token"

    private func makeIdempotencyStore() -> RemoteIdempotencyStore {
        RemoteIdempotencyStore(storageURL: tempStorageURL(name: "idempotency.json"))
    }

    private func tempStorageURL(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteHTTPServerTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func makePairingStore(
        hostID: UUID = UUID(),
        listenPort: Int,
        usesTLS: Bool = false,
        certificateFingerprintSHA256: String = ""
    ) -> RemotePairingStore {
        RemotePairingStore(
            hostContext: RemotePairingStore.HostContext(
                hostID: hostID,
                hostDisplayName: "Test Host",
                listenPort: listenPort,
                usesTLS: usesTLS,
                certificateFingerprintSHA256: certificateFingerprintSHA256
            ),
            storageURL: tempStorageURL(name: "pairing.json"),
            legacyDebugToken: Self.legacyDebugToken
        )
    }

    private func makeServer(
        port: UInt16,
        catalog: any RemoteCatalogServing = RemoteHTTPServerTestCatalog(),
        pairingStore: RemotePairingStore? = nil,
        hostAppVersion: String = "1.0.0"
    ) -> (RemoteHTTPServer, RemotePairingStore) {
        let store = pairingStore ?? makePairingStore(listenPort: Int(port))
        let facade = RemoteCatalogFacade(
            catalog: catalog,
            review: EmptyPersonalizationReviewPort(),
            idempotency: makeIdempotencyStore(),
            hostAppVersion: hostAppVersion,
            listenPort: Int(port)
        )
        let server = RemoteHTTPServer(
            facade: facade,
            pairingStore: store,
            eventBroker: RemoteEventBroker(),
            secIdentity: nil,
            port: port
        )
        return (server, store)
    }

    func testParserRejectsNegativeContentLength() {
        let bytes = Data(
            "POST /v1/tag-decisions:batch HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8
        )

        guard case let .rejected(status, error) = RemoteHTTPServer.parseRequest(
            buffer: bytes,
            isComplete: false
        ) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(status, 400)
        XCTAssertEqual(error.code, .badRequest)
    }

    func testParserRejectsOversizedDeclaredBodyBeforeAccumulatingIt() {
        let bytes = Data(
            "POST /v1/tag-decisions:batch HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".utf8
        )

        guard case let .rejected(status, _) = RemoteHTTPServer.parseRequest(
            buffer: bytes,
            isComplete: false
        ) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(status, 413)
    }

    func testParserRejectsDuplicateContentLength() {
        let bytes = Data(
            "POST /v1/tag-decisions/batch HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n".utf8
        )

        guard case let .rejected(status, _) = RemoteHTTPServer.parseRequest(
            buffer: bytes,
            isComplete: false
        ) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(status, 400)
    }

    func testParserRejectsUnsupportedTransferEncoding() {
        let bytes = Data(
            "POST /v1/tag-decisions/batch HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8
        )

        guard case let .rejected(status, _) = RemoteHTTPServer.parseRequest(
            buffer: bytes,
            isComplete: false
        ) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(status, 400)
    }

    func testParserRejectsTrailingBytesAfterDeclaredBody() {
        let bytes = Data(
            "POST /v1/tag-decisions:batch HTTP/1.1\r\nContent-Length: 0\r\n\r\nextra".utf8
        )

        guard case let .rejected(status, _) = RemoteHTTPServer.parseRequest(
            buffer: bytes,
            isComplete: false
        ) else {
            return XCTFail("expected rejection")
        }
        XCTAssertEqual(status, 400)
    }

    func testUnauthorizedWithoutBearerToken() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let (server, _) = makeServer(port: port)
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

    func testCapabilitiesWithLegacyDebugBearerToken() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let (server, _) = makeServer(port: port, hostAppVersion: "2.3.4")
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/capabilities")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(Self.legacyDebugToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        await server.stop()

        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        let capabilities = try JSONDecoder().decode(RemoteCapabilities.self, from: data)
        XCTAssertEqual(capabilities.hostAppVersion, "2.3.4")
        XCTAssertEqual(capabilities.protocolVersion, RemoteProtocolVersion.current)
    }

    func testBonjourServiceIsAdvertisedOnStart() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let facade = RemoteCatalogFacade(
            catalog: RemoteHTTPServerTestCatalog(),
            review: EmptyPersonalizationReviewPort(),
            idempotency: makeIdempotencyStore(),
            hostAppVersion: "1.0.0",
            listenPort: Int(port)
        )
        let server = RemoteHTTPServer(
            facade: facade,
            pairingStore: makePairingStore(listenPort: Int(port)),
            eventBroker: RemoteEventBroker(),
            secIdentity: nil,
            port: port,
            advertisementName: "ImageAll-Test-Host"
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        let serviceType = await server.bonjourServiceType
        await server.stop()
        XCTAssertEqual(serviceType, RemoteBonjour.serviceType)

        let service = RemoteHTTPServer.makeBonjourService(name: "ImageAll-Test-Host")
        XCTAssertEqual(service.type, RemoteBonjour.serviceType)
        XCTAssertEqual(service.name, "ImageAll-Test-Host")
    }

    func testPairingCompleteRequiresNoBearerTokenAndIssuesSessionTokens() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let pairingStore = makePairingStore(listenPort: Int(port))
        let (server, store) = makeServer(port: port, pairingStore: pairingStore)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)

        let offer = await store.issueOffer()

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/pairing/complete")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RemotePairingCompleteRequest(
                pairingToken: offer.pairingToken,
                deviceName: "iPhone",
                devicePublicKeySPKI_SHA256: "abc123"
            )
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        await server.stop()

        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        let tokens = try JSONDecoder().decode(RemoteSessionTokens.self, from: data)
        XCTAssertFalse(tokens.accessToken.isEmpty)
        XCTAssertFalse(tokens.refreshToken.isEmpty)
    }

    func testWebSocketAcceptValueMatchesRFC6455Example() {
        // RFC 6455 §1.3 canonical example.
        let accept = RemoteHTTPServer.webSocketAcceptValue(secWebSocketKey: "dGhlIHNhbXBsZSBub25jZQ==")
        XCTAssertEqual(accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }
}

private struct RemoteHTTPServerTestCatalog: RemoteCatalogServing {
    func fetchSources() throws -> [LibrarySourceSummary] { [] }

    func listTags() throws -> [TagListItem] { [] }

    func fetchAssetPage(
        filter: AssetPageFilter,
        sort: AssetPageSort,
        cursor: AssetPageCursor?,
        limit: Int
    ) throws -> AssetPageResult {
        _ = limit
        return AssetPageResult(items: [], nextCursor: nil)
    }

    func loadThumbnail(assetID: UUID) async throws -> Data {
        Data()
    }

    func loadPreview(assetID: UUID) async throws -> Data {
        Data()
    }

    func fetchInspectorDetail(assetID: UUID) throws -> AssetInspectorDetail {
        AssetInspectorDetail(
            assetID: assetID,
            sourceID: UUID(),
            sourceDisplayName: "",
            sourceState: .active,
            relativePath: nil,
            fileName: nil,
            mediaType: "image",
            mediaCreatedAtMs: nil,
            mediaModifiedAtMs: nil,
            width: nil,
            height: nil,
            availability: .available,
            contentRevision: 0,
            acceptedTagCount: 0,
            rejectedTagCount: 0,
            fingerprintSizeBytes: nil,
            fingerprintModifiedAtNs: nil,
            tags: []
        )
    }

    func selectionAggregate(tagIDs: [UUID], assetIDs: [UUID]) throws -> [TagSelectionAggregate] { [] }

    func mutateTag(
        tagID: UUID,
        assetIDs: [UUID],
        action: LibraryTagDecisionAction
    ) throws -> TagMutationPriorStateSnapshot {
        TagMutationPriorStateSnapshot(tagID: tagID, priorStates: [])
    }

    func fetchJobActivity() throws -> [JobActivityItem] { [] }

    func applyJobActivityAction(_ action: JobActivityAction, jobID: UUID) throws {}
}
