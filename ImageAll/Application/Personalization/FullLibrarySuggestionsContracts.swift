import Foundation

enum PendingSuggestionGenerationLimits {
    static let defaultMaxCount = 500
    static let minCount = 1
    static let maxCount = 10_000
}

protocol PendingSuggestionCountPreferenceStore: Sendable {
    var maxPendingSuggestionsPerTag: Int { get nonmutating set }
}

final class UserDefaultsPendingSuggestionCountPreferenceStore:
    PendingSuggestionCountPreferenceStore,
    @unchecked Sendable
{
    private static let key = "library.review.max-pending-suggestions-per-tag.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var maxPendingSuggestionsPerTag: Int {
        get {
            guard defaults.object(forKey: Self.key) != nil else {
                return PendingSuggestionGenerationLimits.defaultMaxCount
            }
            return Self.clamp(defaults.integer(forKey: Self.key))
        }
        set {
            defaults.set(Self.clamp(newValue), forKey: Self.key)
        }
    }

    private static func clamp(_ value: Int) -> Int {
        min(
            max(value, PendingSuggestionGenerationLimits.minCount),
            PendingSuggestionGenerationLimits.maxCount
        )
    }
}

enum FullLibrarySuggestionsJobFactory {
    static let kind = "personalization.fullLibrarySuggestions"
    static let payloadVersion = 1
    static let checkpointVersion = 1
    static let contractVersion = 1
    static let maxAttempts = 5
    static let priority = -1
    static let scanBatchSize = 100
    /// Per-tag review queue keeps only the highest-scoring pending suggestions.
    static let maxPendingSuggestionsPerTag = PendingSuggestionGenerationLimits.defaultMaxCount

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
