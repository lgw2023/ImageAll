import Foundation

public struct RemoteWorldMapBounds: Codable, Sendable, Equatable {
    public let west: Double
    public let south: Double
    public let east: Double
    public let north: Double

    public init(west: Double, south: Double, east: Double, north: Double) {
        self.west = west
        self.south = south
        self.east = east
        self.north = north
    }
}

public struct RemoteWorldMapSelectionQuery: Codable, Sendable, Equatable {
    public let cellDegrees: Double
    public let longitudeBucket: Int
    public let latitudeBucket: Int
    public let bounds: RemoteWorldMapBounds?
    public let maximumAssets: Int

    public init(
        cellDegrees: Double,
        longitudeBucket: Int,
        latitudeBucket: Int,
        bounds: RemoteWorldMapBounds? = nil,
        maximumAssets: Int = 36
    ) {
        self.cellDegrees = cellDegrees
        self.longitudeBucket = longitudeBucket
        self.latitudeBucket = latitudeBucket
        self.bounds = bounds
        self.maximumAssets = maximumAssets
    }
}

public struct RemoteWorldMapCluster: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let longitude: Double
    public let latitude: Double
    public let photoCount: Int
    public let gpsCount: Int
    public let tagCount: Int
    public let displayName: String
    public let selectionQuery: RemoteWorldMapSelectionQuery

    public init(
        id: String,
        longitude: Double,
        latitude: Double,
        photoCount: Int,
        gpsCount: Int,
        tagCount: Int,
        displayName: String,
        selectionQuery: RemoteWorldMapSelectionQuery
    ) {
        self.id = id
        self.longitude = longitude
        self.latitude = latitude
        self.photoCount = photoCount
        self.gpsCount = gpsCount
        self.tagCount = tagCount
        self.displayName = displayName
        self.selectionQuery = selectionQuery
    }
}

public struct RemoteWorldMapSnapshot: Codable, Sendable, Equatable {
    public let clusters: [RemoteWorldMapCluster]
    public let eligiblePhotoCount: Int
    public let locatedPhotoCount: Int
    public let unlocatedPhotoCount: Int

    public init(
        clusters: [RemoteWorldMapCluster],
        eligiblePhotoCount: Int,
        locatedPhotoCount: Int,
        unlocatedPhotoCount: Int
    ) {
        self.clusters = clusters
        self.eligiblePhotoCount = eligiblePhotoCount
        self.locatedPhotoCount = locatedPhotoCount
        self.unlocatedPhotoCount = unlocatedPhotoCount
    }
}

public struct RemoteWorldMapSelectionRequest: Codable, Sendable, Equatable {
    public let query: RemoteWorldMapSelectionQuery

    public init(query: RemoteWorldMapSelectionQuery) {
        self.query = query
    }
}

public struct RemoteWorldMapAsset: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let fileName: String?
    public let availability: RemoteAssetAvailability
    public let contentRevision: Int

    public init(
        id: UUID,
        fileName: String?,
        availability: RemoteAssetAvailability,
        contentRevision: Int
    ) {
        self.id = id
        self.fileName = fileName
        self.availability = availability
        self.contentRevision = contentRevision
    }
}

public struct RemoteWorldMapSelection: Codable, Sendable, Equatable {
    public let assets: [RemoteWorldMapAsset]
    public let totalPhotoCount: Int

    public init(assets: [RemoteWorldMapAsset], totalPhotoCount: Int) {
        self.assets = assets
        self.totalPhotoCount = totalPhotoCount
    }
}

public enum RemoteWorldMapLocationBackfillPhase: String, Codable, Sendable, Equatable {
    case ready
    case queued
    case running
    case cancelling
    case retryableFailed
    case completed
    case cancelled
    case terminalFailed
    case unavailable
}

public struct RemoteWorldMapLocationBackfillSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let sourceID: UUID
    public let sourceKind: RemoteSourceKind
    public let sourceDisplayName: String
    public let sourceState: RemoteSourceState
    public let phase: RemoteWorldMapLocationBackfillPhase
    public let totalPhotoCount: Int
    public let inspectedPhotoCount: Int
    public let locatedPhotoCount: Int
    public let activeJobID: UUID?
    public let scanProgress: RemoteJobProgress?
    public let canStart: Bool
    public let canCancel: Bool

    public var id: UUID { sourceID }

    public init(
        sourceID: UUID,
        sourceKind: RemoteSourceKind,
        sourceDisplayName: String,
        sourceState: RemoteSourceState,
        phase: RemoteWorldMapLocationBackfillPhase,
        totalPhotoCount: Int,
        inspectedPhotoCount: Int,
        locatedPhotoCount: Int,
        activeJobID: UUID? = nil,
        scanProgress: RemoteJobProgress? = nil,
        canStart: Bool,
        canCancel: Bool
    ) {
        self.sourceID = sourceID
        self.sourceKind = sourceKind
        self.sourceDisplayName = sourceDisplayName
        self.sourceState = sourceState
        self.phase = phase
        self.totalPhotoCount = totalPhotoCount
        self.inspectedPhotoCount = inspectedPhotoCount
        self.locatedPhotoCount = locatedPhotoCount
        self.activeJobID = activeJobID
        self.scanProgress = scanProgress
        self.canStart = canStart
        self.canCancel = canCancel
    }
}

public enum RemoteWorldMapLocationBackfillAction: String, Codable, Sendable, Equatable {
    case start
    case cancel
}

public struct RemoteWorldMapLocationBackfillCommandRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let sourceID: UUID
    public let action: RemoteWorldMapLocationBackfillAction

    public init(
        operationID: UUID,
        sourceID: UUID,
        action: RemoteWorldMapLocationBackfillAction
    ) {
        self.operationID = operationID
        self.sourceID = sourceID
        self.action = action
    }
}

public struct RemoteWorldMapLocationBackfillCommandResponse: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let snapshot: RemoteWorldMapLocationBackfillSnapshot
    public let replayed: Bool

    public init(
        operationID: UUID,
        snapshot: RemoteWorldMapLocationBackfillSnapshot,
        replayed: Bool
    ) {
        self.operationID = operationID
        self.snapshot = snapshot
        self.replayed = replayed
    }
}

public enum RemoteWorldMapPlaceKind: String, Codable, Sendable, Equatable {
    case poi
    case city
    case region
    case country
}

public struct RemoteWorldMapPlaceCandidate: Codable, Sendable, Equatable, Identifiable {
    public let placeID: String
    public let displayName: String
    public let subtitle: String?
    public let latitude: Double
    public let longitude: Double
    public let kind: RemoteWorldMapPlaceKind

    public var id: String { placeID }

    public init(
        placeID: String,
        displayName: String,
        subtitle: String? = nil,
        latitude: Double,
        longitude: Double,
        kind: RemoteWorldMapPlaceKind
    ) {
        self.placeID = placeID
        self.displayName = displayName
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
        self.kind = kind
    }
}

public enum RemoteWorldMapPlaceBindingStatus: String, Codable, Sendable, Equatable {
    case unresolved
    case resolved
    case ambiguous
    case ignored
    case failed
}

public struct RemoteWorldMapPlaceTagResolution: Codable, Sendable, Equatable, Identifiable {
    public let tagID: UUID
    public let tagName: String
    public let groupName: String
    public let acceptedPhotoCount: Int
    public let status: RemoteWorldMapPlaceBindingStatus
    public let confirmedPlaceID: String?
    public let candidates: [RemoteWorldMapPlaceCandidate]

    public var id: UUID { tagID }

    public init(
        tagID: UUID,
        tagName: String,
        groupName: String,
        acceptedPhotoCount: Int,
        status: RemoteWorldMapPlaceBindingStatus,
        confirmedPlaceID: String? = nil,
        candidates: [RemoteWorldMapPlaceCandidate] = []
    ) {
        self.tagID = tagID
        self.tagName = tagName
        self.groupName = groupName
        self.acceptedPhotoCount = acceptedPhotoCount
        self.status = status
        self.confirmedPlaceID = confirmedPlaceID
        self.candidates = candidates
    }
}

public struct RemoteWorldMapPlaceTagSnapshot: Codable, Sendable, Equatable {
    public let items: [RemoteWorldMapPlaceTagResolution]
    public let maximumQueryLength: Int

    public init(items: [RemoteWorldMapPlaceTagResolution], maximumQueryLength: Int) {
        self.items = items
        self.maximumQueryLength = maximumQueryLength
    }
}

public enum RemoteWorldMapPlaceTagAction: String, Codable, Sendable, Equatable {
    case search
    case confirm
}

public struct RemoteWorldMapPlaceTagCommandRequest: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let tagID: UUID
    public let action: RemoteWorldMapPlaceTagAction
    public let query: String?
    public let placeID: String?

    public init(
        operationID: UUID,
        tagID: UUID,
        action: RemoteWorldMapPlaceTagAction,
        query: String? = nil,
        placeID: String? = nil
    ) {
        self.operationID = operationID
        self.tagID = tagID
        self.action = action
        self.query = query
        self.placeID = placeID
    }
}

public struct RemoteWorldMapPlaceTagCommandResponse: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let resolution: RemoteWorldMapPlaceTagResolution
    public let replayed: Bool

    public init(
        operationID: UUID,
        resolution: RemoteWorldMapPlaceTagResolution,
        replayed: Bool
    ) {
        self.operationID = operationID
        self.resolution = resolution
        self.replayed = replayed
    }
}
