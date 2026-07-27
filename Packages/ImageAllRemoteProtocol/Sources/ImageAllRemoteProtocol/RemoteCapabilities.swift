import Foundation

public enum RemoteProtocolVersion {
    public static let current = 1
    public static let minimumClient = 1
}

public enum RemoteCapability: String, Codable, Sendable, Hashable, CaseIterable {
    case sources
    case tags
    case assetPages
    case thumbnails
    case tagDecisions
}

public struct RemoteCapabilities: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let hostAppVersion: String
    public let minimumClientProtocolVersion: Int
    public let capabilities: [RemoteCapability]
    public let listenPort: Int?

    public init(
        protocolVersion: Int = RemoteProtocolVersion.current,
        hostAppVersion: String,
        minimumClientProtocolVersion: Int = RemoteProtocolVersion.minimumClient,
        capabilities: [RemoteCapability] = RemoteCapability.allCases,
        listenPort: Int? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.hostAppVersion = hostAppVersion
        self.minimumClientProtocolVersion = minimumClientProtocolVersion
        self.capabilities = capabilities
        self.listenPort = listenPort
    }
}
