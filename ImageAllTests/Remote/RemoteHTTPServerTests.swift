import Foundation
import ImageIO
import ImageAllRemoteProtocol
import Network
import UniformTypeIdentifiers
import XCTest
@testable import ImageAll

final class RemoteHTTPServerTests: XCTestCase {
    private static let legacyDebugToken = "secret-token"

    func testRemoteHostDefaultsEnabledUntilUserTurnsItOff() {
        let suiteName = "RemoteHTTPServerTests.RemoteHostDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(
            RemoteHostProcessHolder.isEnabled(defaults: defaults, environment: [:])
        )

        defaults.set(false, forKey: RemoteHostProcessHolder.enabledKey)
        XCTAssertFalse(
            RemoteHostProcessHolder.isEnabled(defaults: defaults, environment: [:])
        )

        defaults.set(true, forKey: RemoteHostProcessHolder.enabledKey)
        XCTAssertTrue(
            RemoteHostProcessHolder.isEnabled(defaults: defaults, environment: [:])
        )
    }

    func testRemoteHostEnvironmentProvidesDevelopmentDefaultWithoutOverridingUserSwitch() {
        let suiteName = "RemoteHTTPServerTests.RemoteHostEnvironment.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(
            RemoteHostProcessHolder.isEnabled(
                defaults: defaults,
                environment: ["IMAGEALL_REMOTE_HOST": "1"]
            )
        )
        XCTAssertFalse(
            RemoteHostProcessHolder.isEnabled(
                defaults: defaults,
                environment: ["IMAGEALL_REMOTE_HOST": "0"]
            )
        )

        defaults.set(false, forKey: RemoteHostProcessHolder.enabledKey)
        XCTAssertFalse(
            RemoteHostProcessHolder.isEnabled(
                defaults: defaults,
                environment: ["IMAGEALL_REMOTE_HOST": "1"]
            )
        )
    }

    func testLocalWebURLUsesStableLoopbackOnlyHTTPPort() {
        XCTAssertEqual(
            RemoteHostProcessHolder.localWebURL.absoluteString,
            "http://127.0.0.1:8788"
        )
    }

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

    private func makeAccessAccountStore() -> RemoteAccessAccountStore {
        RemoteAccessAccountStore(
            storageURL: tempStorageURL(name: "access-accounts.json"),
            passwordHashIterations: 100
        )
    }

    private func makeServer(
        port: UInt16,
        catalog: any RemoteCatalogServing = RemoteHTTPServerTestCatalog(),
        pairingStore: RemotePairingStore? = nil,
        accessAccountStore: RemoteAccessAccountStore? = nil,
        hostAppVersion: String = "1.0.0",
        webAssetStore: RemoteWebCompanionAssetStore = RemoteWebCompanionAssetStore()
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
            accessAccountStore: accessAccountStore ?? makeAccessAccountStore(),
            eventBroker: RemoteEventBroker(),
            webAssetStore: webAssetStore,
            secIdentity: nil,
            port: port
        )
        return (server, store)
    }

    func testWhitelistedAccountLogsInWithoutPairingTokenOrSessionToken() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let accountStore = makeAccessAccountStore()
        _ = try await accountStore.upsert(
            username: "web-owner",
            password: "safe-web-password"
        )
        let (server, _) = makeServer(
            port: port,
            accessAccountStore: accountStore,
            hostAppVersion: "2.4.0"
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        let basic = Data("web-owner:safe-web-password".utf8).base64EncodedString()
        var login = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/web/account/login")!
        )
        login.httpMethod = "POST"
        login.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        login.setValue(
            "http://127.0.0.1:\(port)",
            forHTTPHeaderField: "Origin"
        )
        login.setValue(
            "127.0.0.1:\(port)",
            forHTTPHeaderField: "Host"
        )
        login.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")

        let (loginData, loginResponse) = try await URLSession.shared.data(for: login)
        let loginHTTP = try XCTUnwrap(loginResponse as? HTTPURLResponse)
        XCTAssertEqual(loginHTTP.statusCode, 200)
        XCTAssertNil(loginHTTP.value(forHTTPHeaderField: "Set-Cookie"))
        let loginText = try XCTUnwrap(String(data: loginData, encoding: .utf8))
        XCTAssertFalse(loginText.contains("token"))
        XCTAssertTrue(loginText.contains("\"authMode\":\"account\""))

        var capabilities = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/capabilities")!
        )
        capabilities.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: capabilities)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteCapabilities.self, from: data).hostAppVersion,
            "2.4.0"
        )

        var crossSiteMutation = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/tags/selection")!
        )
        crossSiteMutation.httpMethod = "POST"
        crossSiteMutation.httpBody = Data("{}".utf8)
        crossSiteMutation.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        crossSiteMutation.setValue(
            "Basic \(basic)",
            forHTTPHeaderField: "Authorization"
        )
        crossSiteMutation.setValue(
            "https://attacker.example",
            forHTTPHeaderField: "Origin"
        )
        crossSiteMutation.setValue(
            "cross-site",
            forHTTPHeaderField: "Sec-Fetch-Site"
        )
        let (_, crossSiteResponse) = try await URLSession.shared.data(
            for: crossSiteMutation
        )
        XCTAssertEqual(
            try XCTUnwrap(crossSiteResponse as? HTTPURLResponse).statusCode,
            403
        )

        let wrongBasic = Data("web-owner:wrong-password".utf8).base64EncodedString()
        capabilities.setValue("Basic \(wrongBasic)", forHTTPHeaderField: "Authorization")
        let (_, rejectedResponse) = try await URLSession.shared.data(for: capabilities)
        XCTAssertEqual(
            try XCTUnwrap(rejectedResponse as? HTTPURLResponse).statusCode,
            401
        )
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
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Pragma"), "no-cache")
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

    func testCreateTagAndApplyRouteUsesAtomicCatalogMutationOnceAcrossReplay() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let tagID = UUID()
        let assetIDs = [UUID(), UUID()]
        let catalog = RemoteHTTPServerTestCatalog(
            createTagResult: TagCreateAndApplyResult(
                tagID: tagID,
                displayName: "旅行",
                normalizedName: "旅行",
                priorStates: assetIDs.map {
                    TagMutationPriorState(assetID: $0, priorState: .unknown)
                }
            )
        )
        let (server, _) = makeServer(port: port, catalog: catalog)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/tags/create-and-apply")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try JSONEncoder().encode(
            RemoteCreateTagAndApplyRequest(
                operationID: UUID(),
                name: "  旅行  ",
                assetIDs: assetIDs
            )
        )

        let (firstData, firstResponse) = try await URLSession.shared.data(for: request)
        let (secondData, secondResponse) = try await URLSession.shared.data(for: request)

        XCTAssertEqual(
            try XCTUnwrap(firstResponse as? HTTPURLResponse).statusCode,
            200
        )
        XCTAssertEqual(
            try XCTUnwrap(secondResponse as? HTTPURLResponse).statusCode,
            200
        )
        let first = try JSONDecoder().decode(
            RemoteCreateTagAndApplyResponse.self,
            from: firstData
        )
        let second = try JSONDecoder().decode(
            RemoteCreateTagAndApplyResponse.self,
            from: secondData
        )
        XCTAssertEqual(first.tagID, tagID)
        XCTAssertEqual(first.appliedAssetCount, 2)
        XCTAssertFalse(first.replayed)
        XCTAssertTrue(second.replayed)
        XCTAssertEqual(catalog.createTagCallCount, 1)
    }

    func testBonjourServiceIsAdvertisedOnStart() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let hostID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
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
            accessAccountStore: makeAccessAccountStore(),
            eventBroker: RemoteEventBroker(),
            secIdentity: nil,
            port: port,
            advertisementName: "ImageAll-Test-Host",
            hostID: hostID
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        let serviceType = await server.bonjourServiceType
        await server.stop()
        XCTAssertEqual(serviceType, RemoteBonjour.serviceType)

        let service = RemoteHTTPServer.makeBonjourService(
            name: "ImageAll-Test-Host",
            hostID: hostID
        )
        XCTAssertEqual(service.type, RemoteBonjour.serviceType)
        XCTAssertEqual(service.name, "ImageAll-Test-Host")
        let txtRecord = try XCTUnwrap(service.txtRecordObject)
        XCTAssertEqual(
            txtRecord.dictionary[RemoteBonjour.TXTKey.hostID],
            hostID.uuidString
        )
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

    func testWebPairingURLKeepsOneTimeTokenInFragment() throws {
        let offer = RemotePairingOffer(
            hostID: UUID(),
            hostDisplayName: "Test Host",
            listenPort: 8787,
            usesTLS: true,
            certificateFingerprintSHA256: "fingerprint",
            pairingToken: "one-time-secret",
            expiresAtMs: 123,
            publicBaseURL: "https://imageall.example.com"
        )

        let url = try XCTUnwrap(RemoteWebCompanionSession.webPairingURL(for: offer))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "imageall.example.com")
        XCTAssertNil(url.query)
        XCTAssertEqual(url.fragment, "pair=one-time-secret")
    }

    func testWebSessionRequiresMatchingOriginAndHost() {
        XCTAssertTrue(
            RemoteWebCompanionSession.isTrustedSameOrigin(
                headers: [
                    "origin": "https://imageall.example.com",
                    "host": "imageall.example.com",
                    "sec-fetch-site": "same-origin",
                ]
            )
        )
        XCTAssertTrue(
            RemoteWebCompanionSession.isTrustedSameOrigin(
                headers: [
                    "origin": "http://127.0.0.1:8787",
                    "host": "127.0.0.1:8787",
                ]
            )
        )
        XCTAssertFalse(
            RemoteWebCompanionSession.isTrustedSameOrigin(
                headers: [
                    "origin": "https://attacker.example",
                    "host": "imageall.example.com",
                    "sec-fetch-site": "cross-site",
                ]
            )
        )
        XCTAssertFalse(
            RemoteWebCompanionSession.isTrustedSameOrigin(
                headers: ["host": "imageall.example.com"]
            )
        )
    }

    func testWebSessionCookiesAreSecureHttpOnlyAndStrict() {
        let tokens = RemoteSessionTokens(
            deviceID: UUID(),
            hostID: UUID(),
            accessToken: "access-secret",
            accessExpiresAtMs: Int64((Date().timeIntervalSince1970 + 3_600) * 1_000),
            refreshToken: "refresh-secret",
            certificateFingerprintSHA256: "fingerprint",
            usesTLS: true,
            listenPort: 8787
        )

        let values = RemoteWebCompanionSession.sessionCookieHeaders(tokens: tokens)
            .map(\.1)
        XCTAssertEqual(values.count, 3)
        XCTAssertTrue(values.allSatisfy { $0.contains("Secure") })
        XCTAssertTrue(values.allSatisfy { $0.contains("HttpOnly") })
        XCTAssertTrue(values.allSatisfy { $0.contains("SameSite=Strict") })
        XCTAssertTrue(values.contains { $0.hasPrefix("__Host-imageall_access=") })
        XCTAssertTrue(values.contains { $0.hasPrefix("__Secure-imageall_refresh=") })
        XCTAssertTrue(values.contains { $0.hasPrefix("__Secure-imageall_device=") })
    }

    func testWebPairingReturnsSafeSummaryAndSessionCookies() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let (server, store) = makeServer(port: port)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        let offer = await store.issueOffer()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/web/session/pair")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "http://127.0.0.1:\(port)",
            forHTTPHeaderField: "Origin"
        )
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.httpBody = try JSONEncoder().encode(
            RemoteWebCompanionSession.PairingRequest(
                pairingToken: offer.pairingToken,
                deviceName: "Safari",
                clientID: UUID().uuidString
            )
        )

        let (data, response) = try await session.data(for: request)
        await server.stop()

        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        let summary = try JSONDecoder().decode(
            RemoteWebCompanionSession.StatusResponse.self,
            from: data
        )
        XCTAssertTrue(summary.authenticated)
        XCTAssertNotNil(summary.deviceID)
        let responseText = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(responseText.contains("accessToken"))
        XCTAssertFalse(responseText.contains("refreshToken"))
        let cookieHeader = try XCTUnwrap(
            http.value(forHTTPHeaderField: "Set-Cookie")
        )
        XCTAssertTrue(cookieHeader.contains(RemoteWebCompanionSession.accessCookieName))
        XCTAssertTrue(cookieHeader.contains(RemoteWebCompanionSession.refreshCookieName))
        XCTAssertTrue(cookieHeader.contains(RemoteWebCompanionSession.deviceCookieName))
    }

    func testWebAssetStoreServesOnlyFixedPublicRoutes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RemoteHTTPServerTests-Web-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("<h1>ImageAll</h1>".utf8)
            .write(to: directory.appendingPathComponent("index.html"))

        let store = RemoteWebCompanionAssetStore(directoryURL: directory)
        let root = try XCTUnwrap(store.asset(for: "/"))
        XCTAssertEqual(root.contentType, "text/html; charset=utf-8")
        XCTAssertEqual(String(decoding: root.body, as: UTF8.self), "<h1>ImageAll</h1>")
        XCTAssertNil(store.asset(for: "/../pairing.json"))
        XCTAssertNil(store.asset(for: "/v1/capabilities"))
    }

    func testBundledWebCompanionExposesDailyWorkflowSurfaces() throws {
        let store = RemoteWebCompanionAssetStore()
        let html = String(
            decoding: try XCTUnwrap(store.asset(for: "/")?.body),
            as: UTF8.self
        )
        let script = String(
            decoding: try XCTUnwrap(store.asset(for: "/app.js")?.body),
            as: UTF8.self
        )

        for controlID in [
            "filterPopover",
            "batchBar",
            "reviewWorkspace",
            "jobsPopover",
            "lightbox",
            "accountLoginForm",
            "accountUsername",
            "accountPassword",
            "newTagDialog",
            "newTagForm",
            "newTagName",
            "batchNewTagButton",
            "inspectorNewTagButton",
            "mediaKindTabs",
            "gridDensitySlider",
            "tagNavigation",
            "commandPalette",
            "shortcutDialog",
            "inspectorPreviousButton",
            "inspectorNextButton",
            "inspectorTagSearch",
            "assetContextMenu",
            "sidebarVisibilityButton",
            "inspectorVisibilityButton",
        ] {
            XCTAssertTrue(html.contains("id=\"\(controlID)\""))
        }
        for endpoint in [
            "/v1/tags/selection",
            "/v1/tag-decisions/batch",
            "/v1/review/queue",
            "/v1/review/decisions/batch",
            "/v1/jobs/",
            "/web/account/login",
            "/v1/tags/create-and-apply",
        ] {
            XCTAssertTrue(script.contains(endpoint))
        }
        XCTAssertFalse(script.contains("/v1/review-queue"))
        XCTAssertFalse(script.contains("/v1/review-decisions/batch"))
        XCTAssertTrue(script.contains("setProtectedImageSource"))
        XCTAssertTrue(script.contains("Basic ${btoa(binary)}"))
        XCTAssertTrue(script.contains("assetPageFingerprint"))
        XCTAssertTrue(script.contains("fetchLoadedAssetWindow"))
        XCTAssertTrue(script.contains("reviewPageFingerprint"))
        XCTAssertTrue(script.contains("preserveUnchangedGrid: true"))
        XCTAssertTrue(script.contains("preserveLoadedWindow: true"))
        XCTAssertTrue(script.contains("syncAssetCardImage"))
        XCTAssertTrue(script.contains("button.dataset.imageKey === imageKey"))
        XCTAssertTrue(script.contains("syncAssetCardPosition(button, index)"))
        XCTAssertFalse(script.contains("elements.assetGrid.append(button);"))
        XCTAssertTrue(script.contains("confirmBatchTagDecision(action, tagName, assetCount)"))
        XCTAssertTrue(script.contains("确认要为 ${mediaItemCountText(assetCount)}${actionText}标签"))
        XCTAssertTrue(script.contains("event.metaKey || event.ctrlKey"))
        XCTAssertTrue(script.contains("event.shiftKey"))
        XCTAssertTrue(script.contains("selectAssetRange"))
        XCTAssertTrue(script.contains("selectAllLoadedAssets"))
        XCTAssertTrue(script.contains("renderTagNavigation"))
        XCTAssertTrue(script.contains("applyQuickTagFilter"))
        XCTAssertTrue(script.contains("moveLibrarySelection"))
        XCTAssertTrue(script.contains("startMarqueeSelection"))
        XCTAssertTrue(script.contains("renderAssetSelectionState"))
        XCTAssertTrue(script.contains("openCommandPalette"))
        XCTAssertTrue(script.contains("persistWorkspacePreferences"))
        XCTAssertTrue(script.contains("new IntersectionObserver"))
        XCTAssertTrue(script.contains("expandedRefreshKinds"))
        XCTAssertTrue(script.contains("assetLoadPromise"))
        XCTAssertTrue(script.contains("assetQuerySignature"))
        XCTAssertTrue(script.contains("protectedImageRequests"))
        XCTAssertTrue(script.contains("protectedImageAbortControllers"))
        XCTAssertTrue(script.contains("new AbortController()"))
        XCTAssertTrue(script.contains("imageall-protected-load"))
        XCTAssertTrue(script.contains("button.dataset.reviewKey = key"))
        XCTAssertTrue(script.contains("scheduleProjectionPoll"))
        XCTAssertTrue(script.contains("currentReviewScopeKey"))
        XCTAssertTrue(script.contains("state.workspaceGeneration"))
        XCTAssertTrue(script.contains("state.inspectorRequestGeneration"))
        XCTAssertTrue(script.contains("state.inspectorDismissed"))
        XCTAssertTrue(script.contains("state.pendingInspectorRefresh"))
        XCTAssertTrue(script.contains("preserveExisting: true"))
        XCTAssertTrue(script.contains("function closeReviewWorkspace()"))
        XCTAssertTrue(script.contains("function closeLightbox()"))
        XCTAssertTrue(script.contains("function trapOverlayFocus"))
        XCTAssertTrue(script.contains("state.review.mutating"))
        XCTAssertTrue(script.contains("state.tagMutating"))
        XCTAssertTrue(script.contains("throwOnError: true"))
        XCTAssertTrue(script.contains("界面同步暂时失败，正在重试"))
        XCTAssertTrue(script.contains("applyReviewDecision(\"accept\")"))
        XCTAssertTrue(script.contains("deferReviewSelection"))
        XCTAssertFalse(script.contains("applyReviewDecision(\"clear\")"))
        XCTAssertTrue(script.contains("event.key.toLowerCase() === \"p\""))
        XCTAssertTrue(script.contains("event.key.toLowerCase() === \"x\""))
        XCTAssertTrue(script.contains("event.key.toLowerCase() === \"u\""))
        let selectReviewStart = try XCTUnwrap(
            script.range(of: "function selectReviewIndex")
        )
        let reviewFingerprintStart = try XCTUnwrap(
            script.range(
                of: "function reviewPageFingerprint",
                range: selectReviewStart.upperBound..<script.endIndex
            )
        )
        let selectReviewScript = String(
            script[selectReviewStart.lowerBound..<reviewFingerprintStart.lowerBound]
        )
        XCTAssertFalse(selectReviewScript.contains("renderReview();"))
        let reviewDecisionStart = try XCTUnwrap(
            script.range(of: "async function applyReviewDecision")
        )
        let deferReviewStart = try XCTUnwrap(
            script.range(
                of: "function deferReviewSelection",
                range: reviewDecisionStart.upperBound..<script.endIndex
            )
        )
        let reviewDecisionScript = String(
            script[reviewDecisionStart.lowerBound..<deferReviewStart.lowerBound]
        )
        XCTAssertTrue(reviewDecisionScript.contains("preserveLoadedWindow: true"))
        XCTAssertTrue(reviewDecisionScript.contains("preserveUnchangedGrid: true"))
        XCTAssertTrue(script.contains("sort: \"fileNameAscending\""))
        XCTAssertTrue(
            html.contains(
                "<option value=\"fileNameAscending\" selected>按文件名</option>"
            )
        )
    }

    func testWebRootLoadsWithoutAuthenticationAndUsesBrowserSecurityHeaders() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RemoteHTTPServerTests-Web-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("<main>ImageAll Web</main>".utf8)
            .write(to: directory.appendingPathComponent("index.html"))

        let port = UInt16.random(in: 19_000...29_000)
        let (server, _) = makeServer(
            port: port,
            webAssetStore: RemoteWebCompanionAssetStore(directoryURL: directory)
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/")!
        )
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "<main>ImageAll Web</main>")
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Frame-Options"), "DENY")
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")
        XCTAssertTrue(
            try XCTUnwrap(http.value(forHTTPHeaderField: "Content-Security-Policy"))
                .contains("frame-ancestors 'none'")
        )
    }

    func testLoopbackWebPortServesTheSameCompanionWithoutChangingPrimaryPort() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RemoteHTTPServerTests-LoopbackWeb-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("<main>Local ImageAll Web</main>".utf8)
            .write(to: directory.appendingPathComponent("index.html"))

        let primaryPort = UInt16.random(in: 19_000...23_000)
        let localWebPort = UInt16.random(in: 25_000...29_000)
        let store = makePairingStore(listenPort: Int(primaryPort))
        let accountStore = makeAccessAccountStore()
        _ = try await accountStore.upsert(
            username: "local-owner",
            password: "local-debug-password"
        )
        let server = RemoteHTTPServer(
            facade: RemoteCatalogFacade(
                catalog: RemoteHTTPServerTestCatalog(),
                review: EmptyPersonalizationReviewPort(),
                idempotency: makeIdempotencyStore(),
                hostAppVersion: "1.0.0",
                listenPort: Int(primaryPort)
            ),
            pairingStore: store,
            accessAccountStore: accountStore,
            eventBroker: RemoteEventBroker(),
            webAssetStore: RemoteWebCompanionAssetStore(directoryURL: directory),
            secIdentity: nil,
            port: primaryPort,
            localWebPort: localWebPort
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        for port in [primaryPort, localWebPort] {
            let (data, response) = try await URLSession.shared.data(
                from: URL(string: "http://127.0.0.1:\(port)/")!
            )
            XCTAssertEqual(
                try XCTUnwrap(response as? HTTPURLResponse).statusCode,
                200
            )
            XCTAssertEqual(
                String(decoding: data, as: UTF8.self),
                "<main>Local ImageAll Web</main>"
            )
        }

        let basic = Data("local-owner:local-debug-password".utf8).base64EncodedString()
        var login = URLRequest(
            url: URL(
                string: "http://127.0.0.1:\(localWebPort)/web/account/login"
            )!
        )
        login.httpMethod = "POST"
        login.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        login.setValue(
            "http://127.0.0.1:\(localWebPort)",
            forHTTPHeaderField: "Origin"
        )
        login.setValue(
            "127.0.0.1:\(localWebPort)",
            forHTTPHeaderField: "Host"
        )
        login.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")

        let (loginData, loginResponse) = try await URLSession.shared.data(for: login)
        XCTAssertEqual(
            try XCTUnwrap(loginResponse as? HTTPURLResponse).statusCode,
            200
        )
        XCTAssertTrue(String(decoding: loginData, as: UTF8.self).contains(
            "\"authMode\":\"account\""
        ))

        if let nonLoopbackIPv4 = Host.current().addresses.first(where: {
            $0.contains(".") && !$0.hasPrefix("127.")
        }) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 0.5
            configuration.timeoutIntervalForResource = 0.5
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }

            do {
                let (_, response) = try await session.data(
                    from: URL(
                        string: "http://\(nonLoopbackIPv4):\(localWebPort)/"
                    )!
                )
                XCTFail(
                    "Loopback Web port unexpectedly accepted a non-loopback request: \(response)"
                )
            } catch {
                // Expected: the local Web listener is bound only to 127.0.0.1.
            }
        }
    }

    func testCookieAuthenticationReadsCapabilitiesAndRejectsCrossOriginWrites() async throws {
        let port = UInt16.random(in: 19_000...29_000)
        let (server, store) = makeServer(port: port, hostAppVersion: "3.0.0")
        let offer = await store.issueOffer()
        let tokens = try await store.completePairing(
            RemotePairingCompleteRequest(
                pairingToken: offer.pairingToken,
                deviceName: "Safari",
                devicePublicKeySPKI_SHA256: "web-client"
            )
        )
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var capabilitiesRequest = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/capabilities")!
        )
        capabilitiesRequest.setValue(
            "\(RemoteWebCompanionSession.accessCookieName)=\(tokens.accessToken)",
            forHTTPHeaderField: "Cookie"
        )
        let (capabilitiesData, capabilitiesResponse) = try await URLSession.shared.data(
            for: capabilitiesRequest
        )
        XCTAssertEqual(
            try XCTUnwrap(capabilitiesResponse as? HTTPURLResponse).statusCode,
            200
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteCapabilities.self, from: capabilitiesData)
                .hostAppVersion,
            "3.0.0"
        )

        var rejectedRequest = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/tag-decisions/batch")!
        )
        rejectedRequest.httpMethod = "POST"
        rejectedRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        rejectedRequest.setValue(
            "\(RemoteWebCompanionSession.accessCookieName)=\(tokens.accessToken)",
            forHTTPHeaderField: "Cookie"
        )
        rejectedRequest.setValue(
            "https://attacker.example",
            forHTTPHeaderField: "Origin"
        )
        rejectedRequest.httpBody = try JSONEncoder().encode(
            RemoteBatchTagDecisionRequest(
                operationID: UUID(),
                tagID: UUID(),
                assetIDs: [UUID()],
                action: .accept
            )
        )
        let (_, rejectedResponse) = try await URLSession.shared.data(for: rejectedRequest)
        XCTAssertEqual(
            try XCTUnwrap(rejectedResponse as? HTTPURLResponse).statusCode,
            403
        )

        var acceptedRequest = rejectedRequest
        acceptedRequest.setValue(
            "http://127.0.0.1:\(port)",
            forHTTPHeaderField: "Origin"
        )
        acceptedRequest.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        let (_, acceptedResponse) = try await URLSession.shared.data(for: acceptedRequest)
        XCTAssertEqual(
            try XCTUnwrap(acceptedResponse as? HTTPURLResponse).statusCode,
            200
        )
    }

    func testAssetRouteMapsAdvancedWebQueryFilters() async throws {
        let sourceID = UUID()
        let acceptedTagID = UUID()
        let excludedTagID = UUID()
        let catalog = RemoteHTTPServerTestCatalog()
        let port = UInt16.random(in: 19_000...29_000)
        let (server, _) = makeServer(port: port, catalog: catalog)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var components = URLComponents(
            string: "http://127.0.0.1:\(port)/v1/assets"
        )!
        components.queryItems = [
            URLQueryItem(name: "sourceIDs", value: sourceID.uuidString),
            URLQueryItem(name: "acceptedTagIDs", value: acceptedTagID.uuidString),
            URLQueryItem(name: "excludedTagIDs", value: excludedTagID.uuidString),
            URLQueryItem(name: "tagMatchMode", value: "any"),
            URLQueryItem(name: "availabilities", value: "available,missing"),
            URLQueryItem(name: "mediaKinds", value: "video"),
            URLQueryItem(name: "mediaTypes", value: "public.mpeg-4"),
            URLQueryItem(name: "tagPresence", value: "tagged"),
        ]
        var request = URLRequest(url: try XCTUnwrap(components.url))
        request.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )

        let (_, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual(
            try XCTUnwrap(response as? HTTPURLResponse).statusCode,
            200
        )
        let filter = try XCTUnwrap(catalog.lastRequestedFilter)
        XCTAssertEqual(filter.sourceIDs, [sourceID])
        XCTAssertEqual(
            filter.tagDecisionFilters,
            [TagDecisionFilter(tagID: acceptedTagID, decision: .accepted)]
        )
        XCTAssertEqual(filter.excludedTagIDs, [excludedTagID])
        XCTAssertEqual(filter.tagMatchMode, .any)
        XCTAssertEqual(filter.availabilities, [.available, .missing])
        XCTAssertEqual(filter.mediaKinds, [.video])
        XCTAssertEqual(filter.mediaTypes, ["public.mpeg-4"])
        XCTAssertEqual(filter.tagPresence, .tagged)
        XCTAssertEqual(catalog.lastRequestedSort, .fileNameAscending)
    }

    func testPreviewRouteConvertsPhotoKitTIFFIntoBrowserCompatibleImage() async throws {
        let assetID = UUID()
        let sourceTIFF = try XCTUnwrap(FolderReconcileTestSupport.minimalTIFFData())
        let catalog = RemoteHTTPServerTestCatalog(previewData: sourceTIFF)
        let port = UInt16.random(in: 19_000...29_000)
        let (server, _) = makeServer(port: port, catalog: catalog)
        try await server.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        defer { Task { await server.stop() } }

        var request = URLRequest(
            url: URL(
                string: "http://127.0.0.1:\(port)/v1/assets/\(assetID.uuidString)/preview"
            )!
        )
        request.setValue(
            "Bearer \(Self.legacyDebugToken)",
            forHTTPHeaderField: "Authorization"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let outputType = try XCTUnwrap(CGImageSourceGetType(source) as String?)
        XCTAssertTrue([UTType.jpeg.identifier, UTType.png.identifier].contains(outputType))
        XCTAssertEqual(
            http.value(forHTTPHeaderField: "Content-Type"),
            outputType == UTType.png.identifier ? "image/png" : "image/jpeg"
        )
    }

    func testWebSocketAcceptValueMatchesRFC6455Example() {
        // RFC 6455 §1.3 canonical example.
        let accept = RemoteHTTPServer.webSocketAcceptValue(secWebSocketKey: "dGhlIHNhbXBsZSBub25jZQ==")
        XCTAssertEqual(accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }
}

private final class RemoteHTTPServerTestCatalog: RemoteCatalogServing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedLastRequestedFilter: AssetPageFilter?
    private var storedLastRequestedSort: AssetPageSort?
    private let previewData: Data
    private let createTagResult: TagCreateAndApplyResult?
    private var storedCreateTagCallCount = 0

    init(
        previewData: Data = Data(),
        createTagResult: TagCreateAndApplyResult? = nil
    ) {
        self.previewData = previewData
        self.createTagResult = createTagResult
    }

    var lastRequestedFilter: AssetPageFilter? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastRequestedFilter
    }

    var lastRequestedSort: AssetPageSort? {
        lock.lock()
        defer { lock.unlock() }
        return storedLastRequestedSort
    }

    var createTagCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCreateTagCallCount
    }

    func fetchSources() throws -> [LibrarySourceSummary] { [] }

    func listTags() throws -> [TagListItem] { [] }

    func fetchAssetPage(
        filter: AssetPageFilter,
        sort: AssetPageSort,
        cursor: AssetPageCursor?,
        limit: Int
    ) throws -> AssetPageResult {
        _ = cursor
        _ = limit
        lock.lock()
        storedLastRequestedFilter = filter
        storedLastRequestedSort = sort
        lock.unlock()
        return AssetPageResult(items: [], nextCursor: nil)
    }

    func loadThumbnail(assetID: UUID) async throws -> Data {
        Data()
    }

    func loadPreview(assetID: UUID) async throws -> Data {
        previewData
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

    func createTagAndAccept(
        rawName: String,
        assetIDs: [UUID]
    ) throws -> TagCreateAndApplyResult {
        lock.lock()
        storedCreateTagCallCount += 1
        lock.unlock()
        return createTagResult ?? TagCreateAndApplyResult(
            tagID: UUID(),
            displayName: rawName,
            normalizedName: rawName,
            priorStates: assetIDs.map {
                TagMutationPriorState(assetID: $0, priorState: .unknown)
            }
        )
    }

    func fetchJobActivity() throws -> [JobActivityItem] { [] }

    func applyJobActivityAction(_ action: JobActivityAction, jobID: UUID) throws {}
}
