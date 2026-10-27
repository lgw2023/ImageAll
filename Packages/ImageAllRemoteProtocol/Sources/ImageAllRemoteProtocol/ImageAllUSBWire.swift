import Foundation

/// A USB route never establishes trust in a different saved Host identity.
public enum ImageAllUSBPairingConflict: Sendable, Equatable {
    case missingSavedIdentity, differentHost, differentCertificate

    public static func detect(hasStoredPairing: Bool, storedHostID: String?, storedFingerprint: String?, offer: RemotePairingOffer) -> Self? {
        guard hasStoredPairing else { return nil }
        guard let hostID = storedHostID.flatMap(UUID.init(uuidString:)),
              let fingerprint = storedFingerprint, !fingerprint.isEmpty else { return .missingSavedIdentity }
        guard hostID == offer.hostID else { return .differentHost }
        guard fingerprint.lowercased() == offer.certificateFingerprintSHA256.lowercased() else { return .differentCertificate }
        return nil
    }
}

/// Opening a tunnel is not authentication. Automatic resume additionally needs
/// the saved credential; the pinned TLS/session refresh still authenticates it.
public enum ImageAllUSBAutomaticResume {
    public static func permits(hasStoredPairing: Bool, storedDeviceID: String?, storedUsesTLS: Bool,
                               storedHostID: String?, storedFingerprint: String?, offer: RemotePairingOffer,
                               nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        guard hasStoredPairing, storedDeviceID.flatMap(UUID.init(uuidString:)) != nil,
              storedUsesTLS, offer.usesTLS, offer.expiresAtMs > nowMs,
              offer.certificateFingerprintSHA256.count == 64,
              offer.certificateFingerprintSHA256.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return false }
        return ImageAllUSBPairingConflict.detect(hasStoredPairing: true, storedHostID: storedHostID,
            storedFingerprint: storedFingerprint, offer: offer) == nil
    }
}

/// User consent applies only to the offer and USB session shown in the dialog.
public struct ImageAllUSBPairingConsent: Sendable {
    public let offer: RemotePairingOffer
    public let transportID: UUID
    public init(offer: RemotePairingOffer, transportID: UUID) {
        self.offer = offer; self.transportID = transportID
    }
    public func isCurrent(pendingOffer: RemotePairingOffer?, transportID: UUID,
                          nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> Bool {
        pendingOffer == offer && self.transportID == transportID && offer.expiresAtMs > nowMs
    }
}

/// Only the local phone bridge consumes this envelope. TLS and HTTP remain
/// unchanged inside the tunnel; this key authorizes sibling data connections.
public struct ImageAllUSBHello: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case control, data }
    public let role: Role
    public let sessionKey: String
    public let offer: RemotePairingOffer?
    public init(role: Role, sessionKey: String, offer: RemotePairingOffer? = nil) {
        self.role = role; self.sessionKey = sessionKey; self.offer = offer
    }
    public static let devicePort: UInt16 = 49731
    public static let maximumHeaderBytes = 16_384
    /// Pending approval has the same bounded lifetime on both ends.
    public static func approvalTimeoutSeconds(for offer: RemotePairingOffer, now: Date = Date()) -> Int {
        max(1, min(300, Int(ceil(Double(offer.expiresAtMs) / 1000 - now.timeIntervalSince1970))))
    }
    public func validated() throws -> Self {
        guard sessionKey.count == 64, sessionKey.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              (role == .control ? offer != nil : offer == nil) else { throw ImageAllUSBError.invalidHeader }
        if let offer {
            guard offer.listenPort > 0, offer.listenPort < 65536,
                  offer.usesTLS,
                  offer.certificateFingerprintSHA256.count == 64,
                  offer.certificateFingerprintSHA256.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  offer.expiresAtMs > Int64(Date().timeIntervalSince1970 * 1000) else {
                throw ImageAllUSBError.invalidHeader
            }
        }
        return self
    }
    public func framed() throws -> Data {
        _ = try validated()
        let body = try JSONEncoder().encode(self)
        guard body.count <= Self.maximumHeaderBytes else { throw ImageAllUSBError.invalidHeader }
        var length = UInt32(body.count).bigEndian
        var result = withUnsafeBytes(of: &length) { Data($0) }
        result.append(body)
        return result
    }
    public static func decode(_ body: Data) throws -> Self {
        guard body.count <= maximumHeaderBytes else { throw ImageAllUSBError.invalidHeader }
        return try JSONDecoder().decode(Self.self, from: body).validated()
    }
}

public enum ImageAllUSBError: Error, LocalizedError, Sendable {
    case invalidHeader, disconnected, unavailable(String), system(Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidHeader: "USB 会话或身份无效，请重新连接。"
        case .disconnected: "USB 连接已断开，传输暂停；不会自动改用无线网络。"
        case .unavailable(let reason): reason
        case .system(let code): "USB 通道无法建立（系统错误 \(code)）。请解锁并信任此电脑，在手机打开 ImageAll。"
        }
    }
}
