import Foundation

enum MediaKind: String, Sendable, Equatable, Codable, CaseIterable {
    case image
    case video
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
    var searchText: String?

    init(
        sourceIDs: [UUID] = [],
        tagDecisionFilters: [TagDecisionFilter] = [],
        excludedTagIDs: [UUID] = [],
        tagMatchMode: TagMatchMode = .all,
        availabilities: [AssetAvailability] = [],
        mediaKinds: [MediaKind] = [],
        mediaTypes: [String] = [],
        tagPresence: TagPresenceFilter = .any,
        searchText: String? = nil
    ) {
        self.sourceIDs = sourceIDs
        self.tagDecisionFilters = tagDecisionFilters
        self.excludedTagIDs = excludedTagIDs
        self.tagMatchMode = tagMatchMode
        self.availabilities = availabilities
        self.mediaKinds = mediaKinds
        self.mediaTypes = mediaTypes
        self.tagPresence = tagPresence
        self.searchText = searchText
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
