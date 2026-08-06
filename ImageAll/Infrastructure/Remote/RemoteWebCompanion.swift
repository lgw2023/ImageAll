import CryptoKit
import Foundation
import ImageAllRemoteProtocol

struct RemoteWebCompanionAsset: Equatable {
    let contentType: String
    let body: Data
    let allowsSameOriginFraming: Bool
}

struct RemoteWebCompanionAssetStore {
    private struct Descriptor {
        let name: String
        let contentType: String
        let isWorldMap: Bool
        let allowsSameOriginFraming: Bool
    }

    private static let routeMap: [String: Descriptor] = [
        "/": Descriptor(name: "index.html", contentType: "text/html; charset=utf-8", isWorldMap: false, allowsSameOriginFraming: false),
        "/index.html": Descriptor(name: "index.html", contentType: "text/html; charset=utf-8", isWorldMap: false, allowsSameOriginFraming: false),
        "/app.css": Descriptor(name: "app.css", contentType: "text/css; charset=utf-8", isWorldMap: false, allowsSameOriginFraming: false),
        "/app.js": Descriptor(name: "app.js", contentType: "text/javascript; charset=utf-8", isWorldMap: false, allowsSameOriginFraming: false),
        "/service-worker.js": Descriptor(name: "service-worker.js", contentType: "text/javascript; charset=utf-8", isWorldMap: false, allowsSameOriginFraming: false),
        "/manifest.webmanifest": Descriptor(name: "manifest.webmanifest", contentType: "application/manifest+json", isWorldMap: false, allowsSameOriginFraming: false),
        "/world-map/index.html": Descriptor(name: "index.html", contentType: "text/html; charset=utf-8", isWorldMap: true, allowsSameOriginFraming: true),
        "/world-map/maplibre-gl.css": Descriptor(name: "maplibre-gl.css", contentType: "text/css; charset=utf-8", isWorldMap: true, allowsSameOriginFraming: false),
        "/world-map/world-map.css": Descriptor(name: "world-map.css", contentType: "text/css; charset=utf-8", isWorldMap: true, allowsSameOriginFraming: false),
        "/world-map/maplibre-gl.js": Descriptor(name: "maplibre-gl.js", contentType: "text/javascript; charset=utf-8", isWorldMap: true, allowsSameOriginFraming: false),
        "/world-map/maplibre-gl-worker-source.js": Descriptor(name: "maplibre-gl-worker-source.js", contentType: "text/javascript; charset=utf-8", isWorldMap: true, allowsSameOriginFraming: false),
        "/world-map/deck.gl.min.js": Descriptor(name: "deck.gl.min.js", contentType: "text/javascript; charset=utf-8", isWorldMap: true, allowsSameOriginFraming: false),
        "/world-map/natural-earth-countries.js": Descriptor(name: "natural-earth-countries.js", contentType: "text/javascript; charset=utf-8", isWorldMap: true, allowsSameOriginFraming: false),
        "/world-map/world-map.js": Descriptor(name: "world-map.js", contentType: "text/javascript; charset=utf-8", isWorldMap: true, allowsSameOriginFraming: false),
    ]

    private let directoryURL: URL?
    private let worldMapDirectoryURL: URL?

    init(
        directoryURL: URL? = nil,
        worldMapDirectoryURL: URL? = nil,
        bundle: Bundle = .main
    ) {
        self.directoryURL = directoryURL
            ?? bundle.resourceURL?.appendingPathComponent("WebCompanion", isDirectory: true)
        self.worldMapDirectoryURL = worldMapDirectoryURL
            ?? bundle.resourceURL?.appendingPathComponent("WorldMap", isDirectory: true)
    }

    func asset(for path: String) -> RemoteWebCompanionAsset? {
        guard let descriptor = Self.routeMap[path] else {
            return nil
        }
        let baseURL = descriptor.isWorldMap ? worldMapDirectoryURL : directoryURL
        guard let baseURL else { return nil }
        let url = baseURL.appendingPathComponent(descriptor.name, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return RemoteWebCompanionAsset(
            contentType: descriptor.contentType,
            body: data,
            allowsSameOriginFraming: descriptor.allowsSameOriginFraming
        )
    }

    static func isPublicAssetPath(_ path: String) -> Bool {
        routeMap[path] != nil
    }
}

enum RemoteWebCompanionSession {
    static let pairingPath = "/web/session/pair"
    static let accountLoginPath = "/web/account/login"
    static let refreshPath = "/web/session/refresh"
    static let logoutPath = "/web/session/logout"
    static let statusPath = "/web/session"

    static let accessCookieName = "__Host-imageall_access"
    static let refreshCookieName = "__Secure-imageall_refresh"
    static let deviceCookieName = "__Secure-imageall_device"

    struct PairingRequest: Codable {
        let pairingToken: String
        let deviceName: String
        let clientID: String
    }

    struct StatusResponse: Codable {
        let authenticated: Bool
        let deviceID: UUID?
        let authMode: String?
        let username: String?

        init(
            authenticated: Bool,
            deviceID: UUID?,
            authMode: String? = "pairedDevice",
            username: String? = nil
        ) {
            self.authenticated = authenticated
            self.deviceID = deviceID
            self.authMode = authMode
            self.username = username
        }
    }

    static func webPairingURL(for offer: RemotePairingOffer) -> URL? {
        guard let base = offer.publicBaseURL,
              var components = URLComponents(string: base)
        else {
            return nil
        }
        components.fragment = "pair=\(offer.pairingToken)"
        return components.url
    }

    static func cookieValue(named name: String, headers: [String: String]) -> String? {
        guard let rawCookie = headers["cookie"] else { return nil }
        for pair in rawCookie.split(separator: ";", omittingEmptySubsequences: true) {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespaces) == name
            else {
                continue
            }
            return String(pieces[1]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func basicCredentials(headers: [String: String]) -> (username: String, password: String)? {
        guard let value = headers["authorization"] else { return nil }
        let pieces = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard pieces.count == 2,
              pieces[0].lowercased() == "basic",
              let decoded = Data(base64Encoded: String(pieces[1])),
              let decodedText = String(data: decoded, encoding: .utf8),
              let separator = decodedText.firstIndex(of: ":")
        else {
            return nil
        }
        return (
            String(decodedText[..<separator]),
            String(decodedText[decodedText.index(after: separator)...])
        )
    }

    static func isTrustedSameOrigin(headers: [String: String]) -> Bool {
        guard let origin = headers["origin"],
              let requestHost = headers["host"]?.lowercased(),
              let components = URLComponents(string: origin),
              let originHost = components.host?.lowercased(),
              components.scheme == "https" || components.scheme == "http"
        else {
            return false
        }
        if let fetchSite = headers["sec-fetch-site"]?.lowercased(), fetchSite != "same-origin" {
            return false
        }

        let requestAuthority = normalizedAuthority(requestHost, scheme: components.scheme)
        let originAuthority = normalizedAuthority(
            components.port.map { "\(originHost):\($0)" } ?? originHost,
            scheme: components.scheme
        )
        return requestAuthority == originAuthority
    }

    static func fingerprint(for clientID: String) -> String {
        SHA256.hash(data: Data(clientID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func sessionCookieHeaders(tokens: RemoteSessionTokens) -> [(String, String)] {
        let accessLifetime = max(
            Int(tokens.accessExpiresAtMs / 1_000 - Int64(Date().timeIntervalSince1970)),
            1
        )
        return [
            (
                "Set-Cookie",
                "\(accessCookieName)=\(tokens.accessToken); Path=/; Max-Age=\(accessLifetime); Secure; HttpOnly; SameSite=Strict"
            ),
            (
                "Set-Cookie",
                "\(refreshCookieName)=\(tokens.refreshToken); Path=/web/session; Max-Age=7776000; Secure; HttpOnly; SameSite=Strict"
            ),
            (
                "Set-Cookie",
                "\(deviceCookieName)=\(tokens.deviceID.uuidString); Path=/web/session; Max-Age=7776000; Secure; HttpOnly; SameSite=Strict"
            ),
        ]
    }

    static var clearingCookieHeaders: [(String, String)] {
        [
            (
                "Set-Cookie",
                "\(accessCookieName)=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict"
            ),
            (
                "Set-Cookie",
                "\(refreshCookieName)=; Path=/web/session; Max-Age=0; Secure; HttpOnly; SameSite=Strict"
            ),
            (
                "Set-Cookie",
                "\(deviceCookieName)=; Path=/web/session; Max-Age=0; Secure; HttpOnly; SameSite=Strict"
            ),
        ]
    }

    static let browserSecurityHeaders: [(String, String)] = [
        (
            "Content-Security-Policy",
            "default-src 'self'; base-uri 'none'; connect-src 'self' ws: wss:; font-src 'self'; form-action 'self'; frame-ancestors 'none'; img-src 'self' blob: data:; media-src 'self' blob:; object-src 'none'; script-src 'self'; style-src 'self'; worker-src 'self'"
        ),
        ("Permissions-Policy", "camera=(), microphone=(), geolocation=()"),
        ("Referrer-Policy", "no-referrer"),
        ("X-Content-Type-Options", "nosniff"),
        ("X-Frame-Options", "DENY"),
    ]

    static let embeddedWorldMapSecurityHeaders: [(String, String)] = [
        (
            "Content-Security-Policy",
            "default-src 'self'; base-uri 'none'; connect-src 'self'; font-src 'self' data:; form-action 'none'; frame-ancestors 'self'; img-src 'self' blob: data:; media-src 'none'; object-src 'none'; script-src 'self'; style-src 'self'; worker-src 'self' blob:; child-src 'self' blob:"
        ),
        ("Permissions-Policy", "camera=(), microphone=(), geolocation=()"),
        ("Referrer-Policy", "no-referrer"),
        ("X-Content-Type-Options", "nosniff"),
        ("X-Frame-Options", "SAMEORIGIN"),
    ]

    private static func normalizedAuthority(_ authority: String, scheme: String?) -> String {
        let value = authority.lowercased()
        if value.hasSuffix(":443"), scheme == "https" {
            return String(value.dropLast(4))
        }
        if value.hasSuffix(":80"), scheme == "http" {
            return String(value.dropLast(3))
        }
        return value
    }
}
