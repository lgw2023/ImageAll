import CryptoKit
import Foundation
import ImageAllRemoteProtocol
import Security
import os

/// Persistent pairing state for the Mac Host: the currently active pairing offer (if any),
/// the set of paired companion devices, and short-lived access tokens issued to them.
///
/// Paired devices (and their hashed refresh tokens) survive process restarts via a JSON
/// file under Application Support. Active pairing offers and access tokens are intentionally
/// process-scoped only: an offer is meant to be consumed within its short TTL, and a device
/// that loses its access token can always mint a new one via `refresh` using its persisted
/// refresh token.
actor RemotePairingStore {
    /// Fields describing the Mac Host itself; constant for the lifetime of a store instance.
    struct HostContext: Sendable, Equatable {
        let hostID: UUID
        let hostDisplayName: String
        let listenPort: Int
        let usesTLS: Bool
        let certificateFingerprintSHA256: String
        let protocolVersion: Int
        let publicBaseURL: String?

        init(
            hostID: UUID,
            hostDisplayName: String,
            listenPort: Int,
            usesTLS: Bool,
            certificateFingerprintSHA256: String,
            protocolVersion: Int = RemoteProtocolVersion.current,
            publicBaseURL: String? = nil
        ) {
            self.hostID = hostID
            self.hostDisplayName = hostDisplayName
            self.listenPort = listenPort
            self.usesTLS = usesTLS
            self.certificateFingerprintSHA256 = certificateFingerprintSHA256
            self.protocolVersion = protocolVersion
            self.publicBaseURL = publicBaseURL
        }
    }

    enum PairingError: Error, Equatable {
        case noActiveOffer
        case offerExpired
        case invalidToken
        case unknownDevice
        case invalidRefreshToken
    }

    static let defaultOfferLifetime: TimeInterval = 5 * 60
    static let accessTokenLifetime: TimeInterval = 60 * 60

    private struct PairedDeviceRecord: Codable, Sendable {
        let deviceID: UUID
        var deviceName: String
        let publicKeyFingerprint: String
        var refreshTokenHash: String
        let pairedAtMs: Int64
        var lastSeenAtMs: Int64?
    }

    private struct PersistedState: Codable {
        var devices: [PairedDeviceRecord]
    }

    private struct AccessTokenRecord {
        let deviceID: UUID
        let expiresAt: Date
    }

    private let logger = Logger(subsystem: "com.gwlee.ImageAll", category: "RemotePairingStore")
    private let storageURL: URL
    private let legacyDebugToken: String?
    private var hostContext: HostContext
    private var devices: [UUID: PairedDeviceRecord] = [:]
    private var activeOffer: RemotePairingOffer?
    private var accessTokens: [String: AccessTokenRecord] = [:]

    init(
        hostContext: HostContext,
        storageURL: URL,
        legacyDebugToken: String? = nil
    ) {
        self.hostContext = hostContext
        self.storageURL = storageURL
        self.legacyDebugToken = legacyDebugToken
        self.devices = Self.loadDevices(from: storageURL, logger: logger)
    }

    // MARK: - Offer lifecycle

    @discardableResult
    func issueOffer(ttl: TimeInterval = RemotePairingStore.defaultOfferLifetime) -> RemotePairingOffer {
        let token = Self.randomURLSafeToken()
        let expiresAt = Date().addingTimeInterval(ttl)
        let offer = RemotePairingOffer(
            hostID: hostContext.hostID,
            hostDisplayName: hostContext.hostDisplayName,
            listenPort: hostContext.listenPort,
            usesTLS: hostContext.usesTLS,
            certificateFingerprintSHA256: hostContext.certificateFingerprintSHA256,
            pairingToken: token,
            expiresAtMs: Self.milliseconds(expiresAt),
            protocolVersion: hostContext.protocolVersion,
            publicBaseURL: hostContext.publicBaseURL
        )
        activeOffer = offer
        return offer
    }

    /// The currently active offer, or `nil` if none was issued or it has expired.
    func currentOffer() -> RemotePairingOffer? {
        guard let offer = activeOffer else { return nil }
        guard offer.expiresAtMs > Self.milliseconds(Date()) else {
            activeOffer = nil
            return nil
        }
        return offer
    }

    func cancelOffer() {
        activeOffer = nil
    }

    // MARK: - Pairing completion

    /// Consumes the active offer (single-use) and mints a new paired device with session
    /// tokens. Throws `PairingError` on missing/expired/mismatched token.
    func completePairing(_ request: RemotePairingCompleteRequest) throws -> RemoteSessionTokens {
        guard let offer = currentOffer() else {
            throw PairingError.noActiveOffer
        }
        guard offer.pairingToken == request.pairingToken else {
            throw PairingError.invalidToken
        }
        // Single-use: consume regardless of downstream outcome once the token has matched.
        activeOffer = nil

        let deviceID = UUID()
        let now = Date()
        let (accessToken, accessExpiresAt) = issueAccessToken(deviceID: deviceID, now: now)
        let refreshToken = Self.randomURLSafeToken(byteCount: 48)
        let record = PairedDeviceRecord(
            deviceID: deviceID,
            deviceName: request.deviceName,
            publicKeyFingerprint: request.devicePublicKeySPKI_SHA256,
            refreshTokenHash: Self.sha256Hex(refreshToken),
            pairedAtMs: Self.milliseconds(now),
            lastSeenAtMs: Self.milliseconds(now)
        )
        devices[deviceID] = record
        save()

        return RemoteSessionTokens(
            deviceID: deviceID,
            hostID: hostContext.hostID,
            accessToken: accessToken,
            accessExpiresAtMs: Self.milliseconds(accessExpiresAt),
            refreshToken: refreshToken,
            certificateFingerprintSHA256: hostContext.certificateFingerprintSHA256,
            usesTLS: hostContext.usesTLS,
            listenPort: hostContext.listenPort,
            publicBaseURL: hostContext.publicBaseURL
        )
    }

    // MARK: - Token refresh

    /// Rotates the refresh token and mints a fresh access token for an already-paired device.
    func refresh(_ request: RemoteTokenRefreshRequest) throws -> RemoteSessionTokens {
        guard var record = devices[request.deviceID] else {
            throw PairingError.unknownDevice
        }
        guard record.refreshTokenHash == Self.sha256Hex(request.refreshToken) else {
            throw PairingError.invalidRefreshToken
        }
        let now = Date()
        let (accessToken, accessExpiresAt) = issueAccessToken(deviceID: record.deviceID, now: now)
        let newRefreshToken = Self.randomURLSafeToken(byteCount: 48)
        record.refreshTokenHash = Self.sha256Hex(newRefreshToken)
        record.lastSeenAtMs = Self.milliseconds(now)
        devices[record.deviceID] = record
        save()

        return RemoteSessionTokens(
            deviceID: record.deviceID,
            hostID: hostContext.hostID,
            accessToken: accessToken,
            accessExpiresAtMs: Self.milliseconds(accessExpiresAt),
            refreshToken: newRefreshToken,
            certificateFingerprintSHA256: hostContext.certificateFingerprintSHA256,
            usesTLS: hostContext.usesTLS,
            listenPort: hostContext.listenPort,
            publicBaseURL: hostContext.publicBaseURL
        )
    }

    // MARK: - Device directory

    func listDevices() -> [RemotePairedDeviceSummary] {
        devices.values
            .sorted { $0.pairedAtMs < $1.pairedAtMs }
            .map {
                RemotePairedDeviceSummary(
                    deviceID: $0.deviceID,
                    deviceName: $0.deviceName,
                    pairedAtMs: $0.pairedAtMs,
                    lastSeenAtMs: $0.lastSeenAtMs
                )
            }
    }

    func revoke(deviceID: UUID) {
        guard devices.removeValue(forKey: deviceID) != nil else { return }
        accessTokens = accessTokens.filter { $0.value.deviceID != deviceID }
        save()
    }

    // MARK: - Access token validation

    /// Returns the authenticated `deviceID` for a bearer token, or `nil` if it is missing,
    /// expired, or belongs to a device that has since been revoked. Also accepts the
    /// legacy Debug static token (if configured), returning `nil` deviceID sentinel-free by
    /// signalling success via `RemoteAuthOutcome.legacyDebugToken`.
    func authenticate(bearer: String) -> RemoteAuthOutcome {
        if let legacyDebugToken, !legacyDebugToken.isEmpty, bearer == legacyDebugToken {
            return .legacyDebugToken
        }
        guard let record = accessTokens[bearer] else { return .unauthorized }
        guard record.expiresAt > Date() else {
            accessTokens.removeValue(forKey: bearer)
            return .unauthorized
        }
        guard devices[record.deviceID] != nil else {
            accessTokens.removeValue(forKey: bearer)
            return .unauthorized
        }
        touchLastSeen(deviceID: record.deviceID)
        return .device(record.deviceID)
    }

    func updateHostContext(_ context: HostContext) {
        hostContext = context
    }

    // MARK: - Internals

    private func issueAccessToken(deviceID: UUID, now: Date) -> (String, Date) {
        let token = Self.randomURLSafeToken()
        let expiresAt = now.addingTimeInterval(Self.accessTokenLifetime)
        accessTokens[token] = AccessTokenRecord(deviceID: deviceID, expiresAt: expiresAt)
        return (token, expiresAt)
    }

    private func touchLastSeen(deviceID: UUID) {
        guard var record = devices[deviceID] else { return }
        record.lastSeenAtMs = Self.milliseconds(Date())
        devices[deviceID] = record
        // Last-seen is best-effort telemetry; avoid a disk write on every authenticated
        // request by not persisting here. It is flushed on the next mutating operation.
    }

    /// `static` (rather than an instance method) because actor initializers are synchronous
    /// and cannot hop onto the actor's executor to call other isolated instance methods; this
    /// mirrors `RemoteIdempotencyStore.loadRecords(from:logger:)`.
    private static func loadDevices(from storageURL: URL, logger: Logger) -> [UUID: PairedDeviceRecord] {
        guard let data = try? Data(contentsOf: storageURL) else { return [:] }
        guard let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            logger.error("Remote pairing state at \(storageURL.path, privacy: .public) is corrupt; starting empty")
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: state.devices.map { ($0.deviceID, $0) })
    }

    private func save() {
        let state = PersistedState(devices: Array(devices.values))
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            logger.error("Remote pairing state save failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func randomURLSafeToken(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Extremely unlikely; fall back to a still-unpredictable source rather than
            // failing pairing outright.
            bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Outcome of authenticating a bearer token against the pairing store.
enum RemoteAuthOutcome: Equatable {
    case device(UUID)
    case legacyDebugToken
    case unauthorized

    var isAuthorized: Bool {
        switch self {
        case .device, .legacyDebugToken: true
        case .unauthorized: false
        }
    }
}
