import CryptoKit
import Foundation
import ImageAllRemoteProtocol

struct RemoteWebCompanionAsset: Equatable {
    let contentType: String
    let body: Data
}

struct RemoteWebCompanionAssetStore {
    private static let routeMap: [String: (name: String, contentType: String)] = [
        "/": ("index.html", "text/html; charset=utf-8"),
        "/index.html": ("index.html", "text/html; charset=utf-8"),
        "/app.css": ("app.css", "text/css; charset=utf-8"),
        "/app.js": ("app.js", "text/javascript; charset=utf-8"),
        "/manifest.webmanifest": ("manifest.webmanifest", "application/manifest+json"),
    ]

    private let directoryURL: URL?

    init(directoryURL: URL? = nil, bundle: Bundle = .main) {
        self.directoryURL = directoryURL
            ?? bundle.resourceURL?.appendingPathComponent("WebCompanion", isDirectory: true)
    }

    func asset(for path: String) -> RemoteWebCompanionAsset? {
        guard let descriptor = Self.routeMap[path], let directoryURL else {
            return nil
        }
        let url = directoryURL.appendingPathComponent(descriptor.name, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return RemoteWebCompanionAsset(contentType: descriptor.contentType, body: data)
    }

    static func isPublicAssetPath(_ path: String) -> Bool {
        routeMap[path] != nil
    }
}

enum RemoteWebCompanionSession {
    static let pairingPath = "/web/session/pair"
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
            "default-src 'self'; base-uri 'none'; connect-src 'self' ws: wss:; font-src 'self'; form-action 'self'; frame-ancestors 'none'; img-src 'self' blob: data:; object-src 'none'; script-src 'self'; style-src 'self'"
        ),
        ("Permissions-Policy", "camera=(), microphone=(), geolocation=()"),
        ("Referrer-Policy", "no-referrer"),
        ("X-Content-Type-Options", "nosniff"),
        ("X-Frame-Options", "DENY"),
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
