import Foundation

enum PendingSuggestionGenerationPolicy {
    /// Public generation paths retain every suggestion above the configured score threshold.
    /// `Int.max` is used only at legacy Int-based seams; workers recognize it as unbounded
    /// and must not build an in-memory Top-N collection of that size.
    static let unlimitedCount = Int.max
}

enum FullLibrarySuggestionsJobFactory {
    static let kind = "personalization.fullLibrarySuggestions"
    static let payloadVersion = 1
    static let checkpointVersion = 1
    static let contractVersion = 1
    static let maxAttempts = 5
    static let priority = -1
    static let scanBatchSize = 100
    static func coalescingKey(tagID: UUID, mediaKind: MediaKind = .image) -> String {
        let base = "personalization:\(tagID.uuidString.lowercased())"
        return mediaKind == .image ? base : "\(base):\(mediaKind.rawValue)"
    }
}

struct FrozenSampleIdentity: Equatable, Sendable, Codable {
    let assetID: UUID
    let contentRevision: Int
}

struct FullLibrarySuggestionsPayload: Equatable, Sendable, Codable {
    let contractVersion: Int
    let mediaKind: MediaKind
    let tagID: UUID
    let sourceIDs: [UUID]
    let catalogCutoffMs: Int64
    let modelRevision: Int
    let frozenPositiveSamples: [FrozenSampleIdentity]
    let frozenNegativeSamples: [FrozenSampleIdentity]

    init(
        contractVersion: Int,
        mediaKind: MediaKind = .image,
        tagID: UUID,
        sourceIDs: [UUID],
        catalogCutoffMs: Int64,
        modelRevision: Int,
        frozenPositiveSamples: [FrozenSampleIdentity],
        frozenNegativeSamples: [FrozenSampleIdentity]
    ) {
        self.contractVersion = contractVersion
        self.mediaKind = mediaKind
        self.tagID = tagID
        self.sourceIDs = sourceIDs
        self.catalogCutoffMs = catalogCutoffMs
        self.modelRevision = modelRevision
        self.frozenPositiveSamples = frozenPositiveSamples
        self.frozenNegativeSamples = frozenNegativeSamples
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case mediaKind
        case tagID
        case sourceIDs
        case catalogCutoffMs
        case modelRevision
        case frozenPositiveSamples
        case frozenNegativeSamples
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try values.decode(Int.self, forKey: .contractVersion)
        mediaKind = try values.decodeIfPresent(MediaKind.self, forKey: .mediaKind) ?? .image
        tagID = try values.decode(UUID.self, forKey: .tagID)
        sourceIDs = try values.decode([UUID].self, forKey: .sourceIDs)
        catalogCutoffMs = try values.decode(Int64.self, forKey: .catalogCutoffMs)
        modelRevision = try values.decode(Int.self, forKey: .modelRevision)
        frozenPositiveSamples = try values.decode(
            [FrozenSampleIdentity].self,
            forKey: .frozenPositiveSamples
        )
        frozenNegativeSamples = try values.decode(
            [FrozenSampleIdentity].self,
            forKey: .frozenNegativeSamples
        )
    }
}

struct FullLibrarySuggestionsCheckpoint: Equatable, Sendable, Codable {
    let lastAssetID: UUID?
    let firstBatchPublished: Bool
    let modelRevision: Int?
    let checkedCount: Int
    let eligibleCount: Int
    let suggestedCount: Int
    let skippedCount: Int

    static let empty = FullLibrarySuggestionsCheckpoint(
        lastAssetID: nil,
        firstBatchPublished: false,
        modelRevision: nil,
        checkedCount: 0,
        eligibleCount: 0,
        suggestedCount: 0,
        skippedCount: 0
    )
}

enum FullLibrarySuggestionsCodec {
    static func encodePayload(_ payload: FullLibrarySuggestionsPayload) throws -> Data {
        try JSONEncoder().encode(payload)
    }

    static func decodePayload(_ data: Data) throws -> FullLibrarySuggestionsPayload {
        let payload = try JSONDecoder().decode(FullLibrarySuggestionsPayload.self, from: data)
        guard payload.contractVersion == FullLibrarySuggestionsJobFactory.contractVersion,
              !payload.sourceIDs.isEmpty,
              payload.catalogCutoffMs >= 0,
              payload.modelRevision > 0,
              payload.frozenPositiveSamples.count >= 2,
              payload.frozenNegativeSamples.count >= 2
        else {
            throw FullLibrarySuggestionsCodecError.invalidPayload
        }
        return payload
    }

    static func encodeCheckpoint(_ checkpoint: FullLibrarySuggestionsCheckpoint) throws -> Data {
        try JSONEncoder().encode(checkpoint)
    }

    static func decodeCheckpoint(_ data: Data) throws -> FullLibrarySuggestionsCheckpoint {
        let checkpoint = try JSONDecoder().decode(FullLibrarySuggestionsCheckpoint.self, from: data)
        guard checkpoint.checkedCount >= 0,
              checkpoint.eligibleCount >= 0,
              checkpoint.suggestedCount >= 0,
              checkpoint.skippedCount >= 0
        else {
            throw FullLibrarySuggestionsCodecError.invalidCheckpoint
        }
        return checkpoint
    }

    static func jobCheckpoint(from checkpoint: FullLibrarySuggestionsCheckpoint) throws -> JobCheckpoint {
        JobCheckpoint(
            version: FullLibrarySuggestionsJobFactory.checkpointVersion,
            data: try encodeCheckpoint(checkpoint)
        )
    }

    static func checkpoint(from jobCheckpoint: JobCheckpoint?) throws -> FullLibrarySuggestionsCheckpoint {
        guard let jobCheckpoint else { return .empty }
        guard jobCheckpoint.version == FullLibrarySuggestionsJobFactory.checkpointVersion else {
            throw FullLibrarySuggestionsCodecError.invalidCheckpoint
        }
        return try decodeCheckpoint(jobCheckpoint.data)
    }
}

enum FullLibrarySuggestionsCodecError: Error, Equatable {
    case invalidPayload
    case invalidCheckpoint
}
