import Foundation

enum MediaKind: String, Sendable, Equatable, Codable, CaseIterable {
    case image
    case video
}

enum WorldMapLocationBackfillPhase: Sendable, Equatable {
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

struct WorldMapLocationBackfillSnapshot: Identifiable, Sendable, Equatable {
    let sourceID: UUID
    let sourceKind: SourceKind
    let sourceDisplayName: String
    let sourceState: SourceState
    let phase: WorldMapLocationBackfillPhase
    let totalPhotoCount: Int
    let inspectedPhotoCount: Int
    let locatedPhotoCount: Int
    let activeJobID: UUID?
    let scanProgress: JobProgress?

    var id: UUID { sourceID }

    var canStart: Bool {
        guard sourceState == .active else { return false }
        return switch phase {
        case .ready, .retryableFailed, .cancelled, .terminalFailed:
            true
        case .queued, .running, .cancelling, .completed, .unavailable:
            false
        }
    }

    var canCancel: Bool {
        activeJobID != nil && phase != .cancelling
    }

    var coverageFraction: Double {
        guard totalPhotoCount > 0 else { return 1 }
        return min(1, Double(inspectedPhotoCount) / Double(totalPhotoCount))
    }
}

enum AssetPageSort: String, Sendable, Equatable, Codable {
    case newest
    case oldest
    case fileNameAscending
}

enum TagMatchMode: String, Sendable, Equatable {
    case all
    case any
}

enum TagPresenceFilter: String, Sendable, Equatable {
    case any
    case tagged
    case untagged
}

enum FavoriteFilter: String, Sendable, Equatable, Codable {
    case any
    case favorited
}

enum FavoriteSyncStatus: String, Sendable, Equatable, Codable {
    case localOnly
    case synced
    case pending
    case failed
}

struct MediaFavoriteState: Sendable, Equatable, Codable {
    let assetID: UUID
    let isFavorite: Bool
    let photosObservedValue: Bool?
    let syncStatus: FavoriteSyncStatus
    let intentRevision: Int
    let requestedAtMs: Int64
    let photosObservedModifiedAtMs: Int64?
    let lastErrorCode: String?

    var isDeletionProtected: Bool {
        isFavorite || photosObservedValue == true
    }

    static func none(assetID: UUID) -> MediaFavoriteState {
        MediaFavoriteState(
            assetID: assetID,
            isFavorite: false,
            photosObservedValue: nil,
            syncStatus: .localOnly,
            intentRevision: 0,
            requestedAtMs: 0,
            photosObservedModifiedAtMs: nil,
            lastErrorCode: nil
        )
    }
}

struct FavoriteMutationSummary: Sendable, Equatable {
    let changedCount: Int
    let localOnlyCount: Int
    let syncedCount: Int
    let pendingCount: Int
    let failedCount: Int

    static let zero = FavoriteMutationSummary(
        changedCount: 0,
        localOnlyCount: 0,
        syncedCount: 0,
        pendingCount: 0,
        failedCount: 0
    )
}

struct TagDecisionFilter: Sendable, Equatable {
    let tagID: UUID
    let decision: PersistableTagDecision
}

struct AssetPageFilter: Sendable, Equatable {
    var sourceIDs: [UUID] = []
    var tagDecisionFilters: [TagDecisionFilter] = []
    var excludedTagIDs: [UUID] = []
    var tagMatchMode: TagMatchMode = .all
    var availabilities: [AssetAvailability] = []
    var mediaKinds: [MediaKind] = []
    var mediaTypes: [String] = []
    var tagPresence: TagPresenceFilter = .any
    var favorite: FavoriteFilter = .any
    var searchText: String?
    var worldMapSelection: WorldMapCatalogSelectionQuery?

    init(
        sourceIDs: [UUID] = [],
        tagDecisionFilters: [TagDecisionFilter] = [],
        excludedTagIDs: [UUID] = [],
        tagMatchMode: TagMatchMode = .all,
        availabilities: [AssetAvailability] = [],
        mediaKinds: [MediaKind] = [],
        mediaTypes: [String] = [],
        tagPresence: TagPresenceFilter = .any,
        favorite: FavoriteFilter = .any,
        searchText: String? = nil,
        worldMapSelection: WorldMapCatalogSelectionQuery? = nil
    ) {
        self.sourceIDs = sourceIDs
        self.tagDecisionFilters = tagDecisionFilters
        self.excludedTagIDs = excludedTagIDs
        self.tagMatchMode = tagMatchMode
        self.availabilities = availabilities
        self.mediaKinds = mediaKinds
        self.mediaTypes = mediaTypes
        self.tagPresence = tagPresence
        self.favorite = favorite
        self.searchText = searchText
        self.worldMapSelection = worldMapSelection
    }
}

enum AssetPageCursorPayload: Sendable, Equatable, Codable {
    case timeSort(timeEmptyMarker: Int, coalescedTimeMs: Int64?, assetID: UUID)
    case fileNameSort(hasFileName: Int, fileName: String?, assetID: UUID)
}

struct AssetPageCursor: Sendable, Equatable, Codable {
    let sort: AssetPageSort
    let payload: AssetPageCursorPayload
}

struct AssetPageRequest: Sendable, Equatable {
    let filter: AssetPageFilter
    let sort: AssetPageSort
    let cursor: AssetPageCursor?
    let limit: Int
}

struct AssetGridItemProjection: Sendable, Equatable {
    let assetID: UUID
    let sourceID: UUID
    let sourceDisplayName: String
    let sourceState: SourceState
    let relativePath: String?
    let fileName: String?
    let mediaKind: MediaKind
    let mediaType: String
    let durationMs: Int64?
    let mediaCreatedAtMs: Int64?
    let mediaModifiedAtMs: Int64?
    let width: Int?
    let height: Int?
    let availability: AssetAvailability
    let contentRevision: Int
    var acceptedTagCount: Int
    var rejectedTagCount: Int

    init(
        assetID: UUID,
        sourceID: UUID,
        sourceDisplayName: String,
        sourceState: SourceState,
        relativePath: String?,
        fileName: String?,
        mediaKind: MediaKind = .image,
        mediaType: String,
        durationMs: Int64? = nil,
        mediaCreatedAtMs: Int64?,
        mediaModifiedAtMs: Int64?,
        width: Int?,
        height: Int?,
        availability: AssetAvailability,
        contentRevision: Int,
        acceptedTagCount: Int,
        rejectedTagCount: Int
    ) {
        self.assetID = assetID
        self.sourceID = sourceID
        self.sourceDisplayName = sourceDisplayName
        self.sourceState = sourceState
        self.relativePath = relativePath
        self.fileName = fileName
        self.mediaKind = mediaKind
        self.mediaType = mediaType
        self.durationMs = durationMs
        self.mediaCreatedAtMs = mediaCreatedAtMs
        self.mediaModifiedAtMs = mediaModifiedAtMs
        self.width = width
        self.height = height
        self.availability = availability
        self.contentRevision = contentRevision
        self.acceptedTagCount = acceptedTagCount
        self.rejectedTagCount = rejectedTagCount
    }
}

struct AssetPageResult: Sendable, Equatable {
    let items: [AssetGridItemProjection]
    let nextCursor: AssetPageCursor?
}

struct GalleryOverviewMediaSummary: Sendable, Equatable, Identifiable {
    var id: MediaKind { mediaKind }

    let mediaKind: MediaKind
    let totalCount: Int
    let exactUniqueCount: Int
    let exactRedundantCount: Int
    let exactFingerprintCount: Int
}

struct GalleryOverviewSourceSummary: Sendable, Equatable, Identifiable {
    var id: UUID { sourceID }
    var totalCount: Int { imageCount + videoCount }

    let sourceID: UUID
    let displayName: String
    let kind: SourceKind
    let state: SourceState
    let imageCount: Int
    let videoCount: Int
}

struct GalleryOverviewTagSummary: Sendable, Equatable, Identifiable {
    var id: UUID { tagID }
    var totalCount: Int { imageCount + videoCount }

    let tagID: UUID
    let displayName: String
    let imageCount: Int
    let videoCount: Int
}

struct GalleryOverviewYearSummary: Sendable, Equatable, Identifiable {
    var id: Int { year }
    var totalCount: Int { imageCount + videoCount }

    let year: Int
    let imageCount: Int
    let videoCount: Int
}

struct GalleryOverviewAvailabilitySummary: Sendable, Equatable, Identifiable {
    var id: AssetAvailability { availability }
    var totalCount: Int { imageCount + videoCount }

    let availability: AssetAvailability
    let imageCount: Int
    let videoCount: Int
}

struct GalleryOverviewFavoriteSummary: Sendable, Equatable, Identifiable {
    var id: MediaKind { mediaKind }
    let mediaKind: MediaKind
    let count: Int
}

struct GalleryOverviewSnapshot: Sendable, Equatable {
    let media: [GalleryOverviewMediaSummary]
    let sources: [GalleryOverviewSourceSummary]
    let positiveTags: [GalleryOverviewTagSummary]
    let years: [GalleryOverviewYearSummary]
    let availability: [GalleryOverviewAvailabilitySummary]
    let undatedCount: Int
    let positiveLabeledAssetCount: Int
    let acceptedDecisionCount: Int
    var favorites: [GalleryOverviewFavoriteSummary] = []

    var totalCount: Int { media.reduce(0) { $0 + $1.totalCount } }
    var exactUniqueCount: Int { media.reduce(0) { $0 + $1.exactUniqueCount } }
    var exactRedundantCount: Int { media.reduce(0) { $0 + $1.exactRedundantCount } }
    var exactFingerprintCount: Int { media.reduce(0) { $0 + $1.exactFingerprintCount } }
    var favoriteCount: Int { favorites.reduce(0) { $0 + $1.count } }

    func favoriteCount(for mediaKind: MediaKind) -> Int {
        favorites.first(where: { $0.mediaKind == mediaKind })?.count ?? 0
    }

    func summary(for mediaKind: MediaKind) -> GalleryOverviewMediaSummary {
        media.first(where: { $0.mediaKind == mediaKind })
            ?? GalleryOverviewMediaSummary(
                mediaKind: mediaKind,
                totalCount: 0,
                exactUniqueCount: 0,
                exactRedundantCount: 0,
                exactFingerprintCount: 0
            )
    }

    static let empty = GalleryOverviewSnapshot(
        media: MediaKind.allCases.map {
            GalleryOverviewMediaSummary(
                mediaKind: $0,
                totalCount: 0,
                exactUniqueCount: 0,
                exactRedundantCount: 0,
                exactFingerprintCount: 0
            )
        },
        sources: [],
        positiveTags: [],
        years: [],
        availability: [],
        undatedCount: 0,
        positiveLabeledAssetCount: 0,
        acceptedDecisionCount: 0
    )
}

struct InspectorTagState: Sendable, Equatable {
    let tagID: UUID
    let displayName: String
    let tagState: TagState
    let decision: TagDecisionQueryState
}

struct AssetInspectorDetail: Sendable, Equatable {
    let assetID: UUID
    let sourceID: UUID
    let sourceDisplayName: String
    let sourceState: SourceState
    let relativePath: String?
    let fileName: String?
    let mediaKind: MediaKind
    let mediaType: String
    let durationMs: Int64?
    let mediaCreatedAtMs: Int64?
    let mediaModifiedAtMs: Int64?
    let width: Int?
    let height: Int?
    let availability: AssetAvailability
    let contentRevision: Int
    let acceptedTagCount: Int
    let rejectedTagCount: Int
    let fingerprintSizeBytes: Int64?
    let fingerprintModifiedAtNs: Int64?
    let tags: [InspectorTagState]

    init(
        assetID: UUID,
        sourceID: UUID,
        sourceDisplayName: String,
        sourceState: SourceState,
        relativePath: String?,
        fileName: String?,
        mediaKind: MediaKind = .image,
        mediaType: String,
        durationMs: Int64? = nil,
        mediaCreatedAtMs: Int64?,
        mediaModifiedAtMs: Int64?,
        width: Int?,
        height: Int?,
        availability: AssetAvailability,
        contentRevision: Int,
        acceptedTagCount: Int,
        rejectedTagCount: Int,
        fingerprintSizeBytes: Int64?,
        fingerprintModifiedAtNs: Int64?,
        tags: [InspectorTagState]
    ) {
        self.assetID = assetID
        self.sourceID = sourceID
        self.sourceDisplayName = sourceDisplayName
        self.sourceState = sourceState
        self.relativePath = relativePath
        self.fileName = fileName
        self.mediaKind = mediaKind
        self.mediaType = mediaType
        self.durationMs = durationMs
        self.mediaCreatedAtMs = mediaCreatedAtMs
        self.mediaModifiedAtMs = mediaModifiedAtMs
        self.width = width
        self.height = height
        self.availability = availability
        self.contentRevision = contentRevision
        self.acceptedTagCount = acceptedTagCount
        self.rejectedTagCount = rejectedTagCount
        self.fingerprintSizeBytes = fingerprintSizeBytes
        self.fingerprintModifiedAtNs = fingerprintModifiedAtNs
        self.tags = tags
    }
}

struct AssetLocationCoordinate: Sendable, Equatable {
    let latitude: Double
    let longitude: Double

    var isValid: Bool {
        latitude.isFinite
            && longitude.isFinite
            && (-90 ... 90).contains(latitude)
            && (-180 ... 180).contains(longitude)
    }
}

struct WorldMapCatalogBounds: Sendable, Equatable, Hashable, Codable {
    let west: Double
    let south: Double
    let east: Double
    let north: Double
}

struct WorldMapCatalogQuery: Sendable, Equatable, Hashable, Codable {
    static let maximumClusterLimit = 2_000
    static let global = WorldMapCatalogQuery(bounds: nil)

    let bounds: WorldMapCatalogBounds?
    let maximumClusters: Int

    init(
        bounds: WorldMapCatalogBounds?,
        maximumClusters: Int = WorldMapCatalogQuery.maximumClusterLimit
    ) {
        self.bounds = bounds
        self.maximumClusters = maximumClusters
    }
}

struct WorldMapCatalogSelectionQuery: Sendable, Equatable, Codable {
    static let defaultAssetLimit = 36
    static let maximumAssetLimit = 120

    let cellDegrees: Double
    let longitudeBucket: Int
    let latitudeBucket: Int
    let bounds: WorldMapCatalogBounds?
    let maximumAssets: Int

    init(
        cellDegrees: Double,
        longitudeBucket: Int,
        latitudeBucket: Int,
        bounds: WorldMapCatalogBounds? = nil,
        maximumAssets: Int = WorldMapCatalogSelectionQuery.defaultAssetLimit
    ) {
        self.cellDegrees = cellDegrees
        self.longitudeBucket = longitudeBucket
        self.latitudeBucket = latitudeBucket
        self.bounds = bounds
        self.maximumAssets = maximumAssets
    }

    func limited(to maximumAssets: Int) -> WorldMapCatalogSelectionQuery {
        WorldMapCatalogSelectionQuery(
            cellDegrees: cellDegrees,
            longitudeBucket: longitudeBucket,
            latitudeBucket: latitudeBucket,
            bounds: bounds,
            maximumAssets: maximumAssets
        )
    }
}

struct WorldMapGalleryScope: Sendable, Equatable {
    let clusterID: String
    let displayName: String
    let photoCount: Int
    let selectionQuery: WorldMapCatalogSelectionQuery
}

struct WorldMapCatalogCluster: Sendable, Equatable, Identifiable, Codable {
    let id: String
    let longitude: Double
    let latitude: Double
    let photoCount: Int
    let gpsCount: Int
    let tagCount: Int
    let displayName: String
    let selectionQuery: WorldMapCatalogSelectionQuery
}

struct WorldMapCatalogAsset: Sendable, Equatable, Identifiable {
    var id: UUID { assetID }

    let assetID: UUID
    let fileName: String?
}

struct WorldMapCatalogSelection: Sendable, Equatable {
    let assets: [WorldMapCatalogAsset]
    let totalPhotoCount: Int

    var isTruncated: Bool { assets.count < totalPhotoCount }

    static let empty = WorldMapCatalogSelection(assets: [], totalPhotoCount: 0)
}

struct WorldMapCatalogSnapshot: Sendable, Equatable, Codable {
    let clusters: [WorldMapCatalogCluster]
    let eligiblePhotoCount: Int
    let locatedPhotoCount: Int
    let unlocatedPhotoCount: Int

    static let empty = WorldMapCatalogSnapshot(
        clusters: [],
        eligiblePhotoCount: 0,
        locatedPhotoCount: 0,
        unlocatedPhotoCount: 0
    )
}

enum WorldMapCatalogError: Error, Equatable, Sendable {
    case invalidQuery
    case persistenceFailure
}

enum WorldMapPlaceKind: String, Sendable, Equatable, Codable {
    case poi
    case city
    case region
    case country
}

struct WorldMapPlaceCandidate: Sendable, Equatable, Identifiable {
    var id: String { placeID }

    let placeID: String
    let displayName: String
    let subtitle: String?
    let latitude: Double
    let longitude: Double
    let kind: WorldMapPlaceKind
    // Resolver-only evidence used to scope international search results. The
    // persisted place identity remains provider-neutral and coordinate-based.
    let countryCode: String?

    init(
        placeID: String,
        displayName: String,
        subtitle: String?,
        latitude: Double,
        longitude: Double,
        kind: WorldMapPlaceKind,
        countryCode: String? = nil
    ) {
        self.placeID = placeID
        self.displayName = displayName
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
        self.kind = kind
        self.countryCode = countryCode?.uppercased()
    }
}

enum WorldMapPlaceBindingStatus: String, Sendable, Equatable {
    case unresolved
    case resolved
    case ambiguous
    case ignored
    case failed
}

struct WorldMapPlaceTagResolution: Sendable, Equatable, Identifiable {
    var id: UUID { tagID }

    let tagID: UUID
    let tagName: String
    let groupName: String
    let acceptedPhotoCount: Int
    let status: WorldMapPlaceBindingStatus
    let confirmedPlaceID: String?
    let candidates: [WorldMapPlaceCandidate]
}

enum WorldMapPlaceResolutionError: Error, Sendable, Equatable {
    case tagUnavailable
    case invalidQuery
    case candidateUnavailable
    case invalidCandidate
    case persistenceFailure
    case resolverFailed
}

enum WorldMapPlaceSearchPolicy {
    static let maximumQueryLength = 160
}

protocol WorldMapPlaceResolving: Sendable {
    func resolve(query: String) async throws -> [WorldMapPlaceCandidate]
}
