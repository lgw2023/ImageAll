import Foundation

public enum RemoteAPIErrorCode: String, Codable, Sendable, Equatable {
    case unauthorized
    case notFound
    case badRequest
    case conflict
    case internalError
}

public struct RemoteAPIError: Codable, Sendable, Equatable, Error {
    public let code: RemoteAPIErrorCode
    public let message: String

    public init(code: RemoteAPIErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum RemoteHTTPPaths {
    public static let capabilities = "/v1/capabilities"
    public static let sources = "/v1/sources"
    public static let assets = "/v1/assets"
    public static let tagDecisionsBatch = "/v1/tag-decisions/batch"

    public static func thumbnail(assetID: UUID) -> String {
        "/v1/assets/\(assetID.uuidString)/thumbnail"
    }
}

public enum RemoteHTTPHeaders {
    public static let authorization = "Authorization"
    public static let bearerPrefix = "Bearer "
}
