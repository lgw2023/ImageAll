import Foundation

public struct RemotePairingOffer: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let hostDisplayName: String
    public let listenPort: Int
    public let usesTLS: Bool
    public let certificateFingerprintSHA256: String
    public let pairingToken: String
    public let expiresAtMs: Int64
    public let protocolVersion: Int
    public let publicBaseURL: String?

    public init(
        hostID: UUID,
        hostDisplayName: String,
        listenPort: Int,
        usesTLS: Bool,
        certificateFingerprintSHA256: String,
        pairingToken: String,
        expiresAtMs: Int64,
        protocolVersion: Int = RemoteProtocolVersion.current,
        publicBaseURL: String? = nil
    ) {
        self.hostID = hostID
        self.hostDisplayName = hostDisplayName
        self.listenPort = listenPort
        self.usesTLS = usesTLS
        self.certificateFingerprintSHA256 = certificateFingerprintSHA256
        self.pairingToken = pairingToken
        self.expiresAtMs = expiresAtMs
        self.protocolVersion = protocolVersion
        self.publicBaseURL = publicBaseURL
    }
}

public struct RemotePairingCompleteRequest: Codable, Sendable, Equatable {
    public let pairingToken: String
    public let deviceName: String
    public let devicePublicKeySPKI_SHA256: String

    public init(pairingToken: String, deviceName: String, devicePublicKeySPKI_SHA256: String) {
        self.pairingToken = pairingToken
        self.deviceName = deviceName
        self.devicePublicKeySPKI_SHA256 = devicePublicKeySPKI_SHA256
    }
}

public struct RemoteSessionTokens: Codable, Sendable, Equatable {
    public let deviceID: UUID
    public let hostID: UUID
    public let accessToken: String
    public let accessExpiresAtMs: Int64
    public let refreshToken: String
    public let certificateFingerprintSHA256: String
    public let usesTLS: Bool
    public let listenPort: Int
    public let publicBaseURL: String?

    public init(
        deviceID: UUID,
        hostID: UUID,
        accessToken: String,
        accessExpiresAtMs: Int64,
        refreshToken: String,
        certificateFingerprintSHA256: String,
        usesTLS: Bool,
        listenPort: Int,
        publicBaseURL: String? = nil
    ) {
        self.deviceID = deviceID
        self.hostID = hostID
        self.accessToken = accessToken
        self.accessExpiresAtMs = accessExpiresAtMs
        self.refreshToken = refreshToken
        self.certificateFingerprintSHA256 = certificateFingerprintSHA256
        self.usesTLS = usesTLS
        self.listenPort = listenPort
        self.publicBaseURL = publicBaseURL
    }
}

public struct RemoteTokenRefreshRequest: Codable, Sendable, Equatable {
    public let deviceID: UUID
    public let refreshToken: String

    public init(deviceID: UUID, refreshToken: String) {
        self.deviceID = deviceID
        self.refreshToken = refreshToken
    }
}

public struct RemotePairedDeviceSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { deviceID }
    public let deviceID: UUID
    public let deviceName: String
    public let pairedAtMs: Int64
    public let lastSeenAtMs: Int64?

    public init(deviceID: UUID, deviceName: String, pairedAtMs: Int64, lastSeenAtMs: Int64?) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.pairedAtMs = pairedAtMs
        self.lastSeenAtMs = lastSeenAtMs
    }
}
