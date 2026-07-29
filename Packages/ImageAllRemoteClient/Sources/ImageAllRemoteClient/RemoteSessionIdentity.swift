import Foundation
import ImageAllRemoteProtocol

public enum RemoteTLSFingerprint {
    public static func normalizedSHA256(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact: String
        if trimmed.contains(":") {
            let bytes = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard bytes.count == 32,
                  bytes.allSatisfy({ $0.count == 2 && $0.allSatisfy(isASCIIHexDigit) })
            else {
                return nil
            }
            compact = bytes.joined()
        } else {
            guard trimmed.count == 64, trimmed.allSatisfy(isASCIIHexDigit) else {
                return nil
            }
            compact = trimmed
        }
        return compact.lowercased()
    }

    private static func isASCIIHexDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first
        else {
            return false
        }
        switch scalar.value {
        case 48 ... 57, 65 ... 70, 97 ... 102:
            return true
        default:
            return false
        }
    }
}

public enum RemoteSessionIdentityError: Error, Equatable, Sendable {
    case hostIdentityMismatch
    case tlsModeMismatch
    case tlsFingerprintMismatch
    case invalidPort
}

extension RemoteSessionIdentityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .hostIdentityMismatch:
            "Host 身份与已配对设备不一致，请重新扫码配对"
        case .tlsModeMismatch:
            "Host TLS 模式与已配对会话不一致，请重新扫码配对"
        case .tlsFingerprintMismatch:
            "Host TLS 证书指纹已变化，请在 Mac 上确认后重新扫码配对"
        case .invalidPort:
            "Host 会话端口无效"
        }
    }
}

public enum RemoteSessionIdentityValidator {
    public static func validate(
        _ tokens: RemoteSessionTokens,
        expectedHostID: UUID?,
        expectedUsesTLS: Bool,
        expectedCertificateFingerprintSHA256: String
    ) throws {
        if let expectedHostID, tokens.hostID != expectedHostID {
            throw RemoteSessionIdentityError.hostIdentityMismatch
        }
        guard tokens.usesTLS == expectedUsesTLS else {
            throw RemoteSessionIdentityError.tlsModeMismatch
        }
        guard (1 ..< 65_536).contains(tokens.listenPort) else {
            throw RemoteSessionIdentityError.invalidPort
        }
        if expectedUsesTLS {
            guard let expectedFingerprint = RemoteTLSFingerprint.normalizedSHA256(
                expectedCertificateFingerprintSHA256
            ),
                let actualFingerprint = RemoteTLSFingerprint.normalizedSHA256(
                    tokens.certificateFingerprintSHA256
                ),
                actualFingerprint == expectedFingerprint
            else {
                throw RemoteSessionIdentityError.tlsFingerprintMismatch
            }
        }
    }
}

public enum RemoteHostSelection {
    public static func bestMatch(
        hostID: UUID,
        displayName: String? = nil,
        in hosts: [RemoteDiscoveredHost]
    ) -> RemoteDiscoveredHost? {
        if let exact = hosts.first(where: { $0.hostID == hostID }) {
            return exact
        }
        guard let displayName else { return nil }
        return hosts.first {
            $0.hostID == nil
                && $0.name.localizedCaseInsensitiveCompare(displayName) == .orderedSame
        }
    }
}
