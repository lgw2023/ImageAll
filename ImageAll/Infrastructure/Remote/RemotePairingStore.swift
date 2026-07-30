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

struct RemoteAccessAccountSummary: Identifiable, Sendable, Equatable {
    var id: String { username }

    let username: String
    let createdAtMs: Int64
    let updatedAtMs: Int64
}

/// Persistent username/password whitelist used by the Web Companion.
///
/// Passwords are never written to disk. Each record stores a unique salt and a
/// PBKDF2-HMAC-SHA256 derived key in an owner-readable Application Support file.
/// Successful credential checks are cached briefly so HTTP Basic authentication
/// can be verified on every request without repeating the expensive password KDF.
actor RemoteAccessAccountStore {
    enum AccountError: LocalizedError, Equatable {
        case invalidUsername
        case invalidPassword
        case tooManyAccounts
        case persistenceFailed

        var errorDescription: String? {
            switch self {
            case .invalidUsername:
                "账号名需为 3–64 个字符，且不能包含冒号或控制字符。"
            case .invalidPassword:
                "密码需为 8–256 个字符。"
            case .tooManyAccounts:
                "白名单最多可保存 32 个账号。"
            case .persistenceFailed:
                "无法安全保存网页访问账号。"
            }
        }
    }

    static let defaultPasswordHashIterations = 210_000
    static let maximumAccountCount = 32

    private struct AccountRecord: Codable, Sendable {
        let username: String
        let saltBase64: String
        let passwordHashBase64: String
        let passwordHashIterations: Int
        let createdAtMs: Int64
        let updatedAtMs: Int64
    }

    private struct PersistedState: Codable {
        let accounts: [AccountRecord]
    }

    private struct AuthenticationCacheEntry {
        let username: String
        let expiresAt: Date
    }

    private struct FailedAttemptWindow {
        var count: Int
        var startedAt: Date
    }

    private let logger = Logger(
        subsystem: "com.gwlee.ImageAll",
        category: "RemoteAccessAccountStore"
    )
    private let storageURL: URL
    private let passwordHashIterations: Int
    private var accounts: [String: AccountRecord]
    private var authenticationCache: [String: AuthenticationCacheEntry] = [:]
    private var failedAttempts: [String: FailedAttemptWindow] = [:]

    init(
        storageURL: URL,
        passwordHashIterations: Int = RemoteAccessAccountStore.defaultPasswordHashIterations
    ) {
        self.storageURL = storageURL
        self.passwordHashIterations = max(passwordHashIterations, 1)
        self.accounts = Self.loadAccounts(from: storageURL)
    }

    func listAccounts() -> [RemoteAccessAccountSummary] {
        accounts.values
            .sorted {
                if $0.createdAtMs == $1.createdAtMs {
                    return $0.username.localizedStandardCompare($1.username) == .orderedAscending
                }
                return $0.createdAtMs < $1.createdAtMs
            }
            .map {
                RemoteAccessAccountSummary(
                    username: $0.username,
                    createdAtMs: $0.createdAtMs,
                    updatedAtMs: $0.updatedAtMs
                )
            }
    }

    @discardableResult
    func upsert(username rawUsername: String, password: String) throws
        -> RemoteAccessAccountSummary
    {
        let username = try Self.validatedUsername(rawUsername)
        guard password.count >= 8, password.count <= 256 else {
            throw AccountError.invalidPassword
        }
        guard accounts[username] != nil || accounts.count < Self.maximumAccountCount else {
            throw AccountError.tooManyAccounts
        }

        let nowMs = Self.milliseconds(Date())
        let salt = Self.randomData(byteCount: 16)
        let derivedKey = Self.derivePasswordKey(
            password: password,
            salt: salt,
            iterations: passwordHashIterations
        )
        let prior = accounts[username]
        let record = AccountRecord(
            username: username,
            saltBase64: salt.base64EncodedString(),
            passwordHashBase64: derivedKey.base64EncodedString(),
            passwordHashIterations: passwordHashIterations,
            createdAtMs: prior?.createdAtMs ?? nowMs,
            updatedAtMs: nowMs
        )
        accounts[username] = record
        do {
            try save()
        } catch {
            accounts[username] = prior
            throw AccountError.persistenceFailed
        }
        authenticationCache.removeAll()
        failedAttempts[username] = nil
        return RemoteAccessAccountSummary(
            username: username,
            createdAtMs: record.createdAtMs,
            updatedAtMs: record.updatedAtMs
        )
    }

    func remove(username rawUsername: String) throws {
        let username = try Self.validatedUsername(rawUsername)
        guard let prior = accounts.removeValue(forKey: username) else { return }
        do {
            try save()
        } catch {
            accounts[username] = prior
            throw AccountError.persistenceFailed
        }
        authenticationCache = authenticationCache.filter { $0.value.username != username }
        failedAttempts[username] = nil
    }

    func authenticate(username rawUsername: String, password: String) -> Bool {
        guard let username = try? Self.validatedUsername(rawUsername),
              password.count <= 256
        else {
            return false
        }

        let now = Date()
        purgeExpiredAuthenticationCache(now: now)
        let cacheKey = Self.sha256Hex("\(username)\u{0}\(password)")
        if let cached = authenticationCache[cacheKey],
           cached.username == username,
           cached.expiresAt > now,
           accounts[username] != nil
        {
            return true
        }
        if isRateLimited(username: username, now: now) {
            return false
        }

        guard let record = accounts[username],
              let salt = Data(base64Encoded: record.saltBase64),
              let expected = Data(base64Encoded: record.passwordHashBase64)
        else {
            recordFailedAttempt(username: username, now: now)
            return false
        }
        let actual = Self.derivePasswordKey(
            password: password,
            salt: salt,
            iterations: max(record.passwordHashIterations, 1)
        )
        guard Self.constantTimeEquals(actual, expected) else {
            recordFailedAttempt(username: username, now: now)
            return false
        }

        failedAttempts[username] = nil
        authenticationCache[cacheKey] = AuthenticationCacheEntry(
            username: username,
            expiresAt: now.addingTimeInterval(5 * 60)
        )
        return true
    }

    private func isRateLimited(username: String, now: Date) -> Bool {
        guard let window = failedAttempts[username] else { return false }
        if now.timeIntervalSince(window.startedAt) >= 60 {
            failedAttempts[username] = nil
            return false
        }
        return window.count >= 5
    }

    private func recordFailedAttempt(username: String, now: Date) {
        if var window = failedAttempts[username],
           now.timeIntervalSince(window.startedAt) < 60
        {
            window.count += 1
            failedAttempts[username] = window
        } else {
            failedAttempts[username] = FailedAttemptWindow(count: 1, startedAt: now)
        }
    }

    private func purgeExpiredAuthenticationCache(now: Date) {
        authenticationCache = authenticationCache.filter { $0.value.expiresAt > now }
    }

    private static func validatedUsername(_ raw: String) throws -> String {
        let username = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard username.count >= 3,
              username.count <= 64,
              !username.contains(":"),
              !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw AccountError.invalidUsername
        }
        return username
    }

    private static func loadAccounts(from storageURL: URL) -> [String: AccountRecord] {
        guard let data = try? Data(contentsOf: storageURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else {
            return [:]
        }
        return Dictionary(
            uniqueKeysWithValues: state.accounts.map { ($0.username, $0) }
        )
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(
            PersistedState(accounts: Array(accounts.values))
        )
        try data.write(to: storageURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storageURL.path
        )
    }

    private static func derivePasswordKey(
        password: String,
        salt: Data,
        iterations: Int
    ) -> Data {
        let key = SymmetricKey(data: Data(password.utf8))
        var blockIndex = UInt32(1).bigEndian
        let firstInput = withUnsafeBytes(of: &blockIndex) { salt + Data($0) }
        var previous = Data(
            HMAC<SHA256>.authenticationCode(for: firstInput, using: key)
        )
        var accumulator = [UInt8](previous)

        if iterations > 1 {
            for _ in 1 ..< iterations {
                previous = Data(
                    HMAC<SHA256>.authenticationCode(for: previous, using: key)
                )
                for index in accumulator.indices {
                    accumulator[index] ^= previous[index]
                }
            }
        }
        return Data(accumulator)
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    private static func randomData(byteCount: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            bytes = (0 ..< byteCount).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes)
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
