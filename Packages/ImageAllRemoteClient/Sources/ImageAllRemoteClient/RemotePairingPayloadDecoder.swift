import Foundation
import ImageAllRemoteProtocol

public enum RemotePairingPayloadError: Error, Equatable, Sendable {
    case malformed
    case expired
    case unsupportedProtocol
    case invalidPort
    case missingPairingToken
    case missingTLSFingerprint
    case invalidTLSFingerprint
    case invalidPublicBaseURL
}

extension RemotePairingPayloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformed:
            "二维码不是有效的 ImageAll 配对信息"
        case .expired:
            "配对二维码已过期，请在 Mac 上重新生成"
        case .unsupportedProtocol:
            "Mac Host 与此版本的 ImageAll Mobile 协议不兼容"
        case .invalidPort:
            "配对信息中的 Host 端口无效"
        case .missingPairingToken:
            "配对信息缺少一次性配对令牌"
        case .missingTLSFingerprint:
            "TLS 配对信息缺少证书指纹"
        case .invalidTLSFingerprint:
            "TLS 证书指纹格式无效"
        case .invalidPublicBaseURL:
            "公网 Host 地址无效，请在 Mac 设置中重新配置 HTTPS 域名"
        }
    }
}

public enum RemotePairingPayloadDecoder {
    public static func decode(
        _ payload: String,
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> RemotePairingOffer {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let offer = try? JSONDecoder().decode(RemotePairingOffer.self, from: data)
        else {
            throw RemotePairingPayloadError.malformed
        }
        guard offer.expiresAtMs > nowMs else {
            throw RemotePairingPayloadError.expired
        }
        guard offer.protocolVersion >= RemoteProtocolVersion.minimumClient,
              offer.protocolVersion <= RemoteProtocolVersion.current
        else {
            throw RemotePairingPayloadError.unsupportedProtocol
        }
        guard (1 ..< 65_536).contains(offer.listenPort) else {
            throw RemotePairingPayloadError.invalidPort
        }
        guard !offer.pairingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemotePairingPayloadError.missingPairingToken
        }
        if offer.usesTLS {
            guard !offer.certificateFingerprintSHA256
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            else {
                throw RemotePairingPayloadError.missingTLSFingerprint
            }
            guard RemoteTLSFingerprint.normalizedSHA256(
                offer.certificateFingerprintSHA256
            ) != nil else {
                throw RemotePairingPayloadError.invalidTLSFingerprint
            }
        }
        if offer.publicBaseURL != nil,
           RemotePublicEndpoint.normalizedHTTPSBaseURL(offer.publicBaseURL) == nil
        {
            throw RemotePairingPayloadError.invalidPublicBaseURL
        }
        return offer
    }
}
