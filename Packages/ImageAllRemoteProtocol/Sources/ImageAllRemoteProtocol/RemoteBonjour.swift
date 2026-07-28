import Foundation

/// Bonjour / DNS-SD constants shared by Mac Host advertisement and Mobile browser.
public enum RemoteBonjour {
    /// DNS-SD service type. Must appear in `NSBonjourServices` on both apps.
    public static let serviceType = "_imageall._tcp"

    public enum TXTKey {
        public static let protocolVersion = "pv"
    }

    public static func txtRecord(protocolVersion: Int = RemoteProtocolVersion.current) -> [String: String] {
        [TXTKey.protocolVersion: String(protocolVersion)]
    }

    public static func protocolVersion(fromTXT values: [String: String]) -> Int? {
        guard let raw = values[TXTKey.protocolVersion] else { return nil }
        return Int(raw)
    }
}
