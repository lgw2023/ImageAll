import Foundation

/// Canonical validation for a public HTTPS endpoint carried in pairing/session DTOs.
///
/// Public endpoints are intentionally stricter than general URLs: ImageAll currently
/// publishes one dedicated hostname at the origin root and always uses the standard HTTPS
/// port. Keeping this shape narrow avoids ambiguous base-path joining, embedded credentials,
/// and accidentally treating a LAN/IP endpoint as the Cloudflare system-trust path.
public enum RemotePublicEndpoint {
    public static func normalizedHTTPSBaseURL(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let rawHost = components.host?.lowercased()
        else {
            return nil
        }
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost
        guard !host.isEmpty,
              host.contains("."),
              !isIPAddress(host),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port == nil || components.port == 443,
              components.path.isEmpty || components.path == "/"
        else {
            return nil
        }

        components.scheme = "https"
        components.host = host
        components.port = nil
        components.path = ""
        components.percentEncodedQuery = nil
        components.fragment = nil
        return components.url?.absoluteString
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") {
            return true
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = UInt16(part) else {
                return false
            }
            return value <= 255
        }
    }
}
