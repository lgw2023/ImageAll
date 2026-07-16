import Foundation

enum FullLibrarySuggestionsJobFactory {
    static let kind = "personalization.fullLibrarySuggestions"
    static let payloadVersion = 1
    static let checkpointVersion = 1
    static let contractVersion = 1
    static let maxAttempts = 5
    static let priority = -1
    static let scanBatchSize = 100

    static func coalescingKey(tagID: UUID) -> String {
        "personalization:\(tagID.uuidString.lowercased())"
    }
}

struct FrozenSampleIdentity: Equatable, Sendable, Codable {
    let assetID: UUID
    let contentRevision: Int
}

struct FullLibrarySuggestionsPayload: Equatable, Sendable, Codable {
    let contractVersion: Int
    let tagID: UUID
    let sourceIDs: [UUID]
    let catalogCutoffMs: Int64
    let modelRevision: Int
    let frozenPositiveSamples: [FrozenSampleIdentity]
    let frozenNegativeSamples: [FrozenSampleIdentity]
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
