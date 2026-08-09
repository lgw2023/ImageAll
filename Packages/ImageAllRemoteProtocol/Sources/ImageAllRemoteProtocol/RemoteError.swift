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
    public static let sourceManagement = "/v1/source-management"
    public static let sourceManagementRequests = "/v1/source-management/requests"
    public static let storageMaintenance = "/v1/storage-maintenance"
    public static let storageMaintenanceRequests = "/v1/storage-maintenance/requests"
    public static let tags = "/v1/tags"
    public static let tagsInstallPresets = "/v1/tags/install-presets"
    public static let tagGroups = "/v1/tag-groups"
    public static let galleryOverview = "/v1/gallery-overview"
    public static let assets = "/v1/assets"
    public static let favorites = "/v1/favorites"
    public static let favoriteSyncRetry = "/v1/favorites/retry"
    public static let tagDecisionsBatch = "/v1/tag-decisions/batch"
    public static let tagDecisionsUndo = "/v1/tag-decisions/undo"
    public static let tagsCreateAndApply = "/v1/tags/create-and-apply"
    public static let tagSelection = "/v1/tags/selection"
    public static let reviewOverview = "/v1/review/overview"
    public static let reviewQueue = "/v1/review/queue"
    public static let reviewDecisionsBatch = "/v1/review/decisions/batch"
    public static let reviewDecisionsUndo = "/v1/review/decisions/undo"
    public static let librarySuggestions = "/v1/library-suggestions"
    public static let librarySuggestionRequests = "/v1/library-suggestions/requests"
    public static let trainingWorkspace = "/v1/training/workspace"
    public static let trainingSetup = "/v1/training/setup"
    public static let trainingLaunch = "/v1/training/launch"
    public static let trainingActivities = "/v1/training/activities"
    public static let embeddingPreparation = "/v1/embedding-preparation"
    public static let embeddingPreparationRequests = "/v1/embedding-preparation/requests"
    public static let sampleSuggestions = "/v1/sample-suggestions"
    public static let sampleSuggestionRequests = "/v1/sample-suggestions/requests"
    public static let tagLibrarySuggestions = "/v1/tag-library-suggestions"
    public static let tagLibrarySuggestionRequests = "/v1/tag-library-suggestions/requests"
    public static let librarySlimmingWorkspace = "/v1/library-slimming/workspace"
    public static let librarySlimmingSetup = "/v1/library-slimming/setup"
    public static let librarySlimmingLaunch = "/v1/library-slimming/launch"
    public static let librarySlimmingThresholds = "/v1/library-slimming/thresholds"
    public static let librarySlimmingRecycle = "/v1/library-slimming/recycle"
    public static let librarySlimmingRecycleRequests = "/v1/library-slimming/recycle/requests"
    public static let librarySlimmingRemovals = "/v1/library-slimming/removals"
    public static let librarySlimmingClusterReview = "/v1/library-slimming/cluster-review"
    public static let librarySlimmingIdenticalCleanupPlans =
        "/v1/library-slimming/identical-cleanup/plans"
    public static let librarySlimmingIdenticalCleanupRequests =
        "/v1/library-slimming/identical-cleanup/requests"
    public static let jobs = "/v1/jobs"
    public static let worldMapSnapshot = "/v1/world-map/snapshot"
    public static let worldMapSelection = "/v1/world-map/selection"
    public static let worldMapLocationBackfill = "/v1/world-map/location-backfill"
    public static let worldMapLocationBackfillRequests = "/v1/world-map/location-backfill/requests"
    public static let worldMapPlaceTags = "/v1/world-map/place-tags"
    public static let worldMapPlaceTagRequests = "/v1/world-map/place-tags/requests"
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

    /// Explicit single-asset recovery for a Photos item whose standard preview is
    /// only available from iCloud. This is intentionally a POST so ordinary
    /// gallery/inspector reads can never opt into network-backed PhotoKit access.
    public static func cloudPreview(assetID: UUID) -> String {
        "/v1/assets/\(assetID.uuidString)/cloud-preview"
    }

    public static func media(assetID: UUID) -> String {
        "/v1/assets/\(assetID.uuidString)/media"
    }

    public static func assetOpenOriginal(assetID: UUID) -> String {
        "/v1/assets/\(assetID.uuidString)/open-original"
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

    public static func trainingActivityAction(operationID: UUID) -> String {
        "/v1/training/activities/\(operationID.uuidString)/actions"
    }

    public static func embeddingPreparationAction(operationID: UUID) -> String {
        "/v1/embedding-preparation/requests/\(operationID.uuidString)/actions"
    }

    public static func sampleSuggestionAction(operationID: UUID) -> String {
        "/v1/sample-suggestions/requests/\(operationID.uuidString)/actions"
    }

    public static func tagLibrarySuggestionAction(operationID: UUID) -> String {
        "/v1/tag-library-suggestions/requests/\(operationID.uuidString)/actions"
    }

    public static func librarySlimmingJobAction(jobID: UUID) -> String {
        "/v1/library-slimming/jobs/\(jobID.uuidString)/actions"
    }

    public static func pairingDevice(deviceID: UUID) -> String {
        "/v1/pairing/devices/\(deviceID.uuidString)"
    }
}

public enum RemoteHTTPHeaders {
    public static let authorization = "Authorization"
    public static let bearerPrefix = "Bearer "
}
