import Foundation

public struct RemoteGalleryOverviewMediaSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: RemoteAssetMediaKind { mediaKind }

    public let mediaKind: RemoteAssetMediaKind
    public let totalCount: Int
    public let exactUniqueCount: Int
    public let exactRedundantCount: Int
    public let exactFingerprintCount: Int

    public init(
        mediaKind: RemoteAssetMediaKind,
        totalCount: Int,
        exactUniqueCount: Int,
        exactRedundantCount: Int,
        exactFingerprintCount: Int
    ) {
        self.mediaKind = mediaKind
        self.totalCount = totalCount
        self.exactUniqueCount = exactUniqueCount
        self.exactRedundantCount = exactRedundantCount
        self.exactFingerprintCount = exactFingerprintCount
    }
}

public struct RemoteGalleryOverviewSourceSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let kind: RemoteSourceKind
    public let state: RemoteSourceState
    public let imageCount: Int
    public let videoCount: Int

    public init(
        id: UUID,
        displayName: String,
        kind: RemoteSourceKind,
        state: RemoteSourceState,
        imageCount: Int,
        videoCount: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.state = state
        self.imageCount = imageCount
        self.videoCount = videoCount
    }
}

public struct RemoteGalleryOverviewTagSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let imageCount: Int
    public let videoCount: Int

    public init(id: UUID, displayName: String, imageCount: Int, videoCount: Int) {
        self.id = id
        self.displayName = displayName
        self.imageCount = imageCount
        self.videoCount = videoCount
    }
}

public struct RemoteGalleryOverviewYearSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: Int { year }

    public let year: Int
    public let imageCount: Int
    public let videoCount: Int

    public init(year: Int, imageCount: Int, videoCount: Int) {
        self.year = year
        self.imageCount = imageCount
        self.videoCount = videoCount
    }
}

public struct RemoteGalleryOverviewAvailabilitySummary: Codable, Sendable, Equatable, Identifiable {
    public var id: RemoteAssetAvailability { availability }

    public let availability: RemoteAssetAvailability
    public let imageCount: Int
    public let videoCount: Int

    public init(
        availability: RemoteAssetAvailability,
        imageCount: Int,
        videoCount: Int
    ) {
        self.availability = availability
        self.imageCount = imageCount
        self.videoCount = videoCount
    }
}

public struct RemoteGalleryOverviewFavoriteSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: RemoteAssetMediaKind { mediaKind }

    public let mediaKind: RemoteAssetMediaKind
    public let count: Int

    public init(mediaKind: RemoteAssetMediaKind, count: Int) {
        self.mediaKind = mediaKind
        self.count = count
    }
}

public struct RemoteGalleryOverviewSnapshot: Codable, Sendable, Equatable {
    public let media: [RemoteGalleryOverviewMediaSummary]
    public let sources: [RemoteGalleryOverviewSourceSummary]
    public let positiveTags: [RemoteGalleryOverviewTagSummary]
    public let years: [RemoteGalleryOverviewYearSummary]
    public let availability: [RemoteGalleryOverviewAvailabilitySummary]
    public let undatedCount: Int
    public let positiveLabeledAssetCount: Int
    public let acceptedDecisionCount: Int
    /// Missing when decoded from a Host predating the favorites capability.
    public let favorites: [RemoteGalleryOverviewFavoriteSummary]?

    public init(
        media: [RemoteGalleryOverviewMediaSummary],
        sources: [RemoteGalleryOverviewSourceSummary],
        positiveTags: [RemoteGalleryOverviewTagSummary],
        years: [RemoteGalleryOverviewYearSummary],
        availability: [RemoteGalleryOverviewAvailabilitySummary],
        undatedCount: Int,
        positiveLabeledAssetCount: Int,
        acceptedDecisionCount: Int,
        favorites: [RemoteGalleryOverviewFavoriteSummary]? = nil
    ) {
        self.media = media
        self.sources = sources
        self.positiveTags = positiveTags
        self.years = years
        self.availability = availability
        self.undatedCount = undatedCount
        self.positiveLabeledAssetCount = positiveLabeledAssetCount
        self.acceptedDecisionCount = acceptedDecisionCount
        self.favorites = favorites
    }
}
