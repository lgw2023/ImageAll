import CryptoKit
import Foundation
import Security
import os

/// Process-wide Mac Host identity: a stable `hostID` plus a self-signed TLS identity used
/// to serve local HTTPS to paired companion devices. Clients pin the certificate's SHA-256
/// fingerprint out-of-band (via the pairing offer) instead of relying on a trust chain, so
/// the certificate itself only needs to be well-formed DER, not CA-signed.
///
/// Best-effort by design: if Keychain/Security APIs are unavailable (sandboxing, missing
/// entitlements, first-run prompts denied, etc.) this degrades to `usesTLS == false` so the
/// Debug host can still serve cleartext HTTP rather than failing to start entirely.
struct RemoteHostIdentity: @unchecked Sendable {
    let hostID: UUID
    let secIdentity: SecIdentity?
    let certificateFingerprintSHA256: String
    let certificateDER: Data?

    var usesTLS: Bool { secIdentity != nil }

    private static let logger = Logger(subsystem: "com.gwlee.ImageAll", category: "RemoteHostIdentity")
    private static let hostIDDefaultsKey = "imageall.remoteHost.hostID"
    private static let keychainLabel = "com.gwlee.ImageAll.remoteHost.tls"
    private static let keychainKeyTag = Data("com.gwlee.ImageAll.remoteHost.tls.key".utf8)
    private static let validityInterval: TimeInterval = 10 * 365 * 24 * 60 * 60

    /// Loads a persisted identity or generates and persists a new one. Safe to call once
    /// per process; the underlying Keychain items persist across launches so the same
    /// `hostID` and certificate fingerprint survive restarts (pairing depends on this).
    static func loadOrCreate(defaults: UserDefaults = .standard) -> RemoteHostIdentity {
        let hostID = loadOrCreateHostID(defaults: defaults)
        if let existing = loadExistingIdentity(hostID: hostID) {
            return existing
        }
        if let created = createAndPersistIdentity(hostID: hostID) {
            return created
        }
        logger.error("Remote host TLS identity unavailable; falling back to cleartext")
        return RemoteHostIdentity(
            hostID: hostID,
            secIdentity: nil,
            certificateFingerprintSHA256: "",
            certificateDER: nil
        )
    }

    static func loadOrCreateHostID(defaults: UserDefaults) -> UUID {
        if let raw = defaults.string(forKey: hostIDDefaultsKey), let uuid = UUID(uuidString: raw) {
            return uuid
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: hostIDDefaultsKey)
        return id
    }

    // MARK: - Keychain lookup

    private static func loadExistingIdentity(hostID: UUID) -> RemoteHostIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: keychainLabel,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let certificate = item else {
            if status != errSecItemNotFound {
                logger.error("Remote host TLS certificate lookup failed: \(status, privacy: .public)")
            }
            return nil
        }
        guard CFGetTypeID(certificate) == SecCertificateGetTypeID() else { return nil }
        let secCertificate = certificate as! SecCertificate // swiftlint:disable:this force_cast
        guard let der = certificateDERData(secCertificate) else { return nil }
        var identityRef: SecIdentity?
        let identityStatus = SecIdentityCreateWithCertificate(nil, secCertificate, &identityRef)
        guard identityStatus == errSecSuccess, let identity = identityRef else {
            logger.error("Remote host TLS identity lookup failed: \(identityStatus, privacy: .public)")
            return nil
        }
        return RemoteHostIdentity(
            hostID: hostID,
            secIdentity: identity,
            certificateFingerprintSHA256: sha256Hex(der),
            certificateDER: der
        )
    }

    // MARK: - Identity creation

    private static func createAndPersistIdentity(hostID: UUID) -> RemoteHostIdentity? {
        do {
            let keyAttributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
                kSecUseDataProtectionKeychain as String: true,
                kSecPrivateKeyAttrs as String: [
                    kSecAttrIsPermanent as String: true,
                    kSecAttrApplicationTag as String: keychainKeyTag,
                    kSecAttrLabel as String: keychainLabel,
                ],
            ]
            var createError: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &createError) else {
                let error = createError?.takeRetainedValue()
                logger.error("Remote host TLS key generation failed: \(String(describing: error), privacy: .public)")
                return nil
            }
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                logger.error("Remote host TLS public key derivation failed")
                return nil
            }
            let der = try MinimalX509SelfSignedCertificate.build(
                subjectCommonName: "ImageAll Host \(hostID.uuidString)",
                publicKey: publicKey,
                privateKey: privateKey,
                notBefore: Date(),
                notAfter: Date().addingTimeInterval(validityInterval)
            )
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                logger.error("Remote host TLS certificate parse-back failed")
                return nil
            }

            // Remove any stale certificate under the same label before inserting the new one.
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: keychainLabel,
                kSecUseDataProtectionKeychain as String: true,
            ]
            SecItemDelete(deleteQuery as CFDictionary)

            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certificate,
                kSecAttrLabel as String: keychainLabel,
                kSecUseDataProtectionKeychain as String: true,
            ]
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
                logger.error("Remote host TLS certificate persist failed: \(addStatus, privacy: .public)")
                return nil
            }

            var identityRef: SecIdentity?
            let identityStatus = SecIdentityCreateWithCertificate(nil, certificate, &identityRef)
            guard identityStatus == errSecSuccess, let identity = identityRef else {
                logger.error("Remote host TLS identity creation failed: \(identityStatus, privacy: .public)")
                return nil
            }

            logger.info("Remote host TLS identity generated for host \(hostID.uuidString, privacy: .public)")
            return RemoteHostIdentity(
                hostID: hostID,
                secIdentity: identity,
                certificateFingerprintSHA256: sha256Hex(der),
                certificateDER: der
            )
        } catch {
            logger.error("Remote host TLS identity generation threw: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func certificateDERData(_ certificate: SecCertificate) -> Data? {
        SecCertificateCopyData(certificate) as Data
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Hand-rolled DER encoder producing just enough X.509v3 structure for a self-signed
/// EC P-256 certificate. There is no CA chain and no general ASN.1 support: only the
/// exact shapes needed here are implemented. Intended solely for local, fingerprint-pinned
/// TLS between the Mac Host and paired companion devices.
enum MinimalX509SelfSignedCertificate {
    enum BuildError: Error {
        case publicKeyExportFailed
        case unexpectedPublicKeyLength
        case signingFailed
    }

    static func build(
        subjectCommonName: String,
        publicKey: SecKey,
        privateKey: SecKey,
        notBefore: Date,
        notAfter: Date
    ) throws -> Data {
        var exportError: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data? else {
            throw BuildError.publicKeyExportFailed
        }
        // Uncompressed EC point for P-256: 0x04 || X(32) || Y(32) == 65 bytes.
        guard publicKeyData.count == 65, publicKeyData.first == 0x04 else {
            throw BuildError.unexpectedPublicKeyLength
        }
        let publicKeyPoint = [UInt8](publicKeyData)

        let tbs = try buildTBSCertificate(
            subjectCommonName: subjectCommonName,
            publicKeyPoint: publicKeyPoint,
            notBefore: notBefore,
            notAfter: notAfter
        )

        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            Data(tbs) as CFData,
            &signError
        ) as Data? else {
            throw BuildError.signingFailed
        }

        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue BIT STRING }
        let signatureAlgorithm = DER.sequence(DER.oid(OID.ecdsaWithSHA256))
        let certificate = DER.sequence(
            tbs + signatureAlgorithm + DER.bitString([UInt8](signature))
        )
        return Data(certificate)
    }

    private static func buildTBSCertificate(
        subjectCommonName: String,
        publicKeyPoint: [UInt8],
        notBefore: Date,
        notAfter: Date
    ) throws -> [UInt8] {
        // [0] EXPLICIT version INTEGER { v3(2) }
        let version = DER.taggedExplicit(0, DER.integer([2]))

        var serialBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serialBytes.count, &serialBytes)
        serialBytes[0] &= 0x7F // keep positive per DER INTEGER rules
        let serialNumber = DER.integer(serialBytes)

        // ECDSA signature AlgorithmIdentifier carries no parameters.
        let signatureAlgorithm = DER.sequence(DER.oid(OID.ecdsaWithSHA256))

        let name = DER.sequence(
            DER.set(
                DER.sequence(
                    DER.oid(OID.commonName) + DER.utf8String(subjectCommonName)
                )
            )
        )

        let validity = DER.sequence(
            DER.utcTime(notBefore) + DER.utcTime(notAfter)
        )

        // SubjectPublicKeyInfo ::= SEQUENCE { algorithm SEQUENCE { id-ecPublicKey, prime256v1 }, subjectPublicKey BIT STRING }
        let spkiAlgorithm = DER.sequence(DER.oid(OID.ecPublicKey) + DER.oid(OID.prime256v1))
        let subjectPublicKeyInfo = DER.sequence(spkiAlgorithm + DER.bitString(publicKeyPoint))

        // Extensions: basicConstraints (critical, CA:FALSE) — minimal hygiene; trust is
        // established out-of-band via fingerprint pinning, not this extension.
        let basicConstraintsValue = DER.sequence([])
        let basicConstraintsExtension = DER.sequence(
            DER.oid(OID.basicConstraints)
                + DER.boolean(true)
                + DER.octetString(basicConstraintsValue)
        )
        let extensions = DER.taggedExplicit(3, DER.sequence(basicConstraintsExtension))

        let tbsBody =
            version
                + serialNumber
                + signatureAlgorithm
                + name // issuer
                + validity
                + name // subject (self-signed: issuer == subject)
                + subjectPublicKeyInfo
                + extensions
        return DER.sequence(tbsBody)
    }

    private enum OID {
        static let ecdsaWithSHA256 = "1.2.840.10045.4.3.2"
        static let ecPublicKey = "1.2.840.10045.2.1"
        static let prime256v1 = "1.2.840.10045.3.1.7"
        static let commonName = "2.5.4.3"
        static let basicConstraints = "2.5.29.19"
    }
}

/// Minimal DER TLV (tag-length-value) building blocks operating on `[UInt8]` throughout.
/// No decoding, no general-purpose ASN.1: just what `MinimalX509SelfSignedCertificate` needs.
private enum DER {
    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 {
            return [UInt8(count)]
        }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [UInt8(0x80 | bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    static func sequence(_ content: [UInt8]) -> [UInt8] { tlv(0x30, content) }
    static func set(_ content: [UInt8]) -> [UInt8] { tlv(0x31, content) }

    static func integer(_ magnitudeBytes: [UInt8]) -> [UInt8] {
        var bytes = magnitudeBytes
        while bytes.count > 1, bytes[0] == 0, bytes[1] & 0x80 == 0 {
            bytes.removeFirst()
        }
        if bytes.first.map({ $0 & 0x80 != 0 }) ?? false {
            bytes.insert(0x00, at: 0)
        }
        return tlv(0x02, bytes)
    }

    static func boolean(_ value: Bool) -> [UInt8] {
        tlv(0x01, [value ? 0xFF : 0x00])
    }

    static func bitString(_ bytes: [UInt8]) -> [UInt8] {
        tlv(0x03, [0x00] + bytes)
    }

    static func octetString(_ content: [UInt8]) -> [UInt8] {
        tlv(0x04, content)
    }

    static func utf8String(_ string: String) -> [UInt8] {
        tlv(0x0C, [UInt8](string.utf8))
    }

    static func oid(_ dotted: String) -> [UInt8] {
        let parts = dotted.split(separator: ".").compactMap { UInt32($0) }
        precondition(parts.count >= 2, "OID must have at least two arcs")
        var body: [UInt8] = []
        body.append(UInt8(parts[0] * 40 + parts[1]))
        for arc in parts.dropFirst(2) {
            body.append(contentsOf: base128(arc))
        }
        return tlv(0x06, body)
    }

    static func taggedExplicit(_ number: UInt8, _ inner: [UInt8]) -> [UInt8] {
        tlv(0xA0 | number, inner)
    }

    private static func base128(_ value: UInt32) -> [UInt8] {
        var chunks: [UInt8] = [UInt8(value & 0x7F)]
        var remaining = value >> 7
        while remaining > 0 {
            chunks.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        return chunks.reversed()
    }

    static func utcTime(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let text = formatter.string(from: date)
        return tlv(0x17, [UInt8](text.utf8))
    }
}
