import CryptoKit
import Foundation
import ImageAllRemoteProtocol
import Security

/// Builds a `URLSession` that only accepts a server certificate whose SHA-256
/// fingerprint matches the value exchanged during pairing.
public enum RemotePinnedURLSessionFactory {
    public static func makeSession(
        certificateFingerprintSHA256: String,
        timeout: TimeInterval = 15
    ) -> URLSession {
        let normalized = certificateFingerprintSHA256
            .replacingOccurrences(of: ":", with: "")
            .lowercased()
        let delegate = PinningDelegate(expectedFingerprint: normalized)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 4
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    public static func sha256Fingerprint(of certificate: SecCertificate) -> String? {
        let data = SecCertificateCopyData(certificate) as Data
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let expectedFingerprint: String

    init(expectedFingerprint: String) {
        self.expectedFingerprint = expectedFingerprint
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let certificate: SecCertificate?
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] {
            certificate = chain.first
        } else {
            certificate = nil
        }
        guard let certificate,
              let fingerprint = RemotePinnedURLSessionFactory.sha256Fingerprint(of: certificate),
              fingerprint == expectedFingerprint
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
