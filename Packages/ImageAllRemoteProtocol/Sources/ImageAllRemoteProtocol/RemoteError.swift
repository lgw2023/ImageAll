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

extension RemoteAPIError: LocalizedError {
    public var errorDescription: String? { message }
}

public enum RemoteHTTPPaths {
    public static let capabilities = "/v1/capabilities"
    public static let sources = "/v1/sources"
    public static let tags = "/v1/tags"
    public static let tagGroups = "/v1/tag-groups"
    public static let assets = "/v1/assets"
    public static let tagDecisionsBatch = "/v1/tag-decisions/batch"
    public static let tagDecisionsUndo = "/v1/tag-decisions/undo"
    public static let tagsCreateAndApply = "/v1/tags/create-and-apply"
    public static let tagSelection = "/v1/tags/selection"
    public static let reviewOverview = "/v1/review/overview"
    public static let reviewQueue = "/v1/review/queue"
    public static let reviewDecisionsBatch = "/v1/review/decisions/batch"
    public static let jobs = "/v1/jobs"
    public static let pairingOffer = "/v1/pairing/offer"
    public static let pairingComplete = "/v1/pairing/complete"
    public static let pairingRefresh = "/v1/pairing/token"
    public static let pairingDevices = "/v1/pairing/devices"
    public static let eventsWebSocket = "/v1/events/websocket"

    public static func assetDetail(assetID: UUID) -> String {
        "/v1/assets/\(assetID.uuidString)"
    }

    public static func thumbnail(assetID: UUID) -> String {
        "/v1/assets/\(assetID.uuidString)/thumbnail"
    }

    public static func preview(assetID: UUID) -> String {
        "/v1/assets/\(assetID.uuidString)/preview"
    }

    public static func tagRename(tagID: UUID) -> String {
        "/v1/tags/\(tagID.uuidString)/rename"
    }

    public static func tagArchive(tagID: UUID) -> String {
        "/v1/tags/\(tagID.uuidString)/archive"
    }

    public static func tagMove(tagID: UUID) -> String {
        "/v1/tags/\(tagID.uuidString)/move"
    }

    public static func tagGroupRename(groupID: UUID) -> String {
        "/v1/tag-groups/\(groupID.uuidString)/rename"
    }

    public static func tagGroupDelete(groupID: UUID) -> String {
        "/v1/tag-groups/\(groupID.uuidString)/delete"
    }

    public static func jobAction(jobID: UUID) -> String {
        "/v1/jobs/\(jobID.uuidString)/actions"
    }

    public static func pairingDevice(deviceID: UUID) -> String {
        "/v1/pairing/devices/\(deviceID.uuidString)"
    }
}

public enum RemoteHTTPHeaders {
    public static let authorization = "Authorization"
    public static let bearerPrefix = "Bearer "
}
