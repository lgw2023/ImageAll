import Foundation

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
    var tagMatchMode: TagMatchMode = .all
    var availabilities: [AssetAvailability] = []
    var mediaTypes: [String] = []
    var tagPresence: TagPresenceFilter = .any
    var searchText: String?

    init(
        sourceIDs: [UUID] = [],
        tagDecisionFilters: [TagDecisionFilter] = [],
        tagMatchMode: TagMatchMode = .all,
        availabilities: [AssetAvailability] = [],
        mediaTypes: [String] = [],
        tagPresence: TagPresenceFilter = .any,
        searchText: String? = nil
    ) {
        self.sourceIDs = sourceIDs
        self.tagDecisionFilters = tagDecisionFilters
        self.tagMatchMode = tagMatchMode
        self.availabilities = availabilities
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
    let mediaType: String
    let mediaCreatedAtMs: Int64?
    let mediaModifiedAtMs: Int64?
    let width: Int?
    let height: Int?
    let availability: AssetAvailability
    let contentRevision: Int
    var acceptedTagCount: Int
    var rejectedTagCount: Int
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
    let mediaType: String
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
}
