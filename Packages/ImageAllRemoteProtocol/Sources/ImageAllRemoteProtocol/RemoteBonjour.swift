import Foundation

/// Bonjour / DNS-SD constants shared by Mac Host advertisement and Mobile browser.
public enum RemoteBonjour {
    /// DNS-SD service type. Must appear in `NSBonjourServices` on both apps.
    public static let serviceType = "_imageall._tcp"

    public enum TXTKey {
        public static let protocolVersion = "pv"
        public static let hostID = "hostID"
    }

    public static func txtRecord(
        protocolVersion: Int = RemoteProtocolVersion.current,
        hostID: UUID? = nil
    ) -> [String: String] {
        var values = [TXTKey.protocolVersion: String(protocolVersion)]
        if let hostID {
            values[TXTKey.hostID] = hostID.uuidString
        }
        return values
    }

    public static func protocolVersion(fromTXT values: [String: String]) -> Int? {
        guard let raw = values[TXTKey.protocolVersion] else { return nil }
        return Int(raw)
    }

    public static func hostID(fromTXT values: [String: String]) -> UUID? {
        guard let raw = values[TXTKey.hostID] else { return nil }
        return UUID(uuidString: raw)
    }
}
