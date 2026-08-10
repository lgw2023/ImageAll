import Foundation

public enum RemoteProtocolVersion {
    public static let current = 2
    public static let minimumClient = 1
}

public enum RemoteCapability: String, Codable, Sendable, Hashable, CaseIterable {
    case sources
    case tags
    case assetPages
    case assetDetail
    case assetLocalSuggestions
    case cloudPreviewLifecycle
    case thumbnails
    case previews
    case favorites
    case tagDecisions
    case tagSelection
    case reviewQueue
    case reviewDecisions
    case librarySuggestions
    case librarySlimming
    case sourceManagement
    case generalSettings
    case workspaceNotices
    case jobs
    case pairing
    case events
}

public extension RemoteHTTPPaths {
    static let generalSettings = "/v1/settings/general"
}

public struct RemoteCapabilities: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let hostAppVersion: String
    public let minimumClientProtocolVersion: Int
    public let capabilities: [RemoteCapability]
    public let listenPort: Int?
    public let usesTLS: Bool
    public let hostID: UUID?
    public let certificateFingerprintSHA256: String?

    public init(
        protocolVersion: Int = RemoteProtocolVersion.current,
        hostAppVersion: String,
        minimumClientProtocolVersion: Int = RemoteProtocolVersion.minimumClient,
        capabilities: [RemoteCapability] = RemoteCapability.allCases,
        listenPort: Int? = nil,
        usesTLS: Bool = false,
        hostID: UUID? = nil,
        certificateFingerprintSHA256: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.hostAppVersion = hostAppVersion
        self.minimumClientProtocolVersion = minimumClientProtocolVersion
        self.capabilities = capabilities
        self.listenPort = listenPort
        self.usesTLS = usesTLS
        self.hostID = hostID
        self.certificateFingerprintSHA256 = certificateFingerprintSHA256
    }
}
