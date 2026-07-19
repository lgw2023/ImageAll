import Foundation

enum PersonalLibrarySuggestionsJobFactory {
    static let kind = "personalization.personalLibrarySuggestions"
    static let payloadVersion = 1
    static let checkpointVersion = 1
    static let contractVersion = 1
    static let maxAttempts = 5
    static let priority = -1

    static func coalescingKey(catalogScopeID: String) -> String {
        "personalization:personal-library:\(catalogScopeID)"
    }
}

struct PersonalLibrarySuggestionsPayload: Codable, Equatable, Sendable {
    let contractVersion: Int
    let sourceIDs: [UUID]
    let catalogCutoffMs: Int64
    let capability: PersonalModelSuggestionCapability
}

struct PersonalLibrarySuggestionsCheckpoint: Codable, Equatable, Sendable {
    let lastAssetID: UUID?
    let capability: PersonalModelSuggestionCapability?
    let checkedCount: Int
    let suggestedCount: Int
    let skippedCount: Int

    static let empty = PersonalLibrarySuggestionsCheckpoint(
        lastAssetID: nil,
        capability: nil,
        checkedCount: 0,
        suggestedCount: 0,
        skippedCount: 0
    )
}

enum PersonalLibrarySuggestionsCodec {
    static func encodePayload(_ payload: PersonalLibrarySuggestionsPayload) throws -> Data {
        try JSONEncoder().encode(payload)
    }

    static func decodePayload(_ data: Data) throws -> PersonalLibrarySuggestionsPayload {
        let payload = try JSONDecoder().decode(PersonalLibrarySuggestionsPayload.self, from: data)
        guard payload.contractVersion == PersonalLibrarySuggestionsJobFactory.contractVersion,
              !payload.sourceIDs.isEmpty,
              Set(payload.sourceIDs).count == payload.sourceIDs.count,
              payload.catalogCutoffMs >= 0,
              validateCapability(payload.capability)
        else {
            throw PersonalLibrarySuggestionsCodecError.invalidPayload
        }
        return payload
    }

    static func encodeCheckpoint(_ checkpoint: PersonalLibrarySuggestionsCheckpoint) throws -> Data {
        try JSONEncoder().encode(checkpoint)
    }

    static func decodeCheckpoint(_ data: Data) throws -> PersonalLibrarySuggestionsCheckpoint {
        let checkpoint = try JSONDecoder().decode(PersonalLibrarySuggestionsCheckpoint.self, from: data)
        guard checkpoint.checkedCount >= 0,
              checkpoint.suggestedCount >= 0,
              checkpoint.skippedCount >= 0,
              checkpoint.skippedCount <= checkpoint.checkedCount,
              checkpoint.capability.map(validateCapability) ?? true
        else {
            throw PersonalLibrarySuggestionsCodecError.invalidCheckpoint
        }
        return checkpoint
    }

    static func jobCheckpoint(from checkpoint: PersonalLibrarySuggestionsCheckpoint) throws -> JobCheckpoint {
        JobCheckpoint(
            version: PersonalLibrarySuggestionsJobFactory.checkpointVersion,
            data: try encodeCheckpoint(checkpoint)
        )
    }

    static func checkpoint(from jobCheckpoint: JobCheckpoint?) throws -> PersonalLibrarySuggestionsCheckpoint {
        guard let jobCheckpoint else { return .empty }
        guard jobCheckpoint.version == PersonalLibrarySuggestionsJobFactory.checkpointVersion else {
            throw PersonalLibrarySuggestionsCodecError.invalidCheckpoint
        }
        return try decodeCheckpoint(jobCheckpoint.data)
    }

    static func validateCapability(_ capability: PersonalModelSuggestionCapability) -> Bool {
        let target = capability.target
        return !target.catalogScopeID.isEmpty
            && !target.bundleID.isEmpty
            && !target.bundleRevision.isEmpty
            && !target.provider.isEmpty
            && !target.modelID.isEmpty
            && !target.modelRevision.isEmpty
            && !target.preprocessingRevision.isEmpty
            && target.elementCount > 0
            && isLowercaseSHA256(target.labelVocabularyRevision)
            && isLowercaseSHA256(target.weightsSHA256)
            && !target.policyRevision.isEmpty
            && !capability.tagIDs.isEmpty
            && Set(capability.tagIDs).count == capability.tagIDs.count
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            ("0" ... "9").contains(String($0)) || ("a" ... "f").contains(String($0))
        }
    }
}

enum PersonalLibrarySuggestionsCodecError: Error, Equatable {
    case invalidPayload
    case invalidCheckpoint
}

enum StandardLibrarySuggestionsJobFactory {
    static let kind = "personalization.standardLibrarySuggestions"
    static let payloadVersion = 1
    static let checkpointVersion = 1
    static let contractVersion = 1
    static let maxAttempts = 5
    static let priority = -1

    static func coalescingKey(standardPackID: String) -> String {
        "personalization:standard-library:\(standardPackID)"
    }
}

struct StandardLibrarySuggestionsPayload: Codable, Equatable, Sendable {
    let contractVersion: Int
    let sourceIDs: [UUID]
    let catalogCutoffMs: Int64
    let target: StandardModelSuggestionTarget
}

struct StandardLibrarySuggestionsCheckpoint: Codable, Equatable, Sendable {
    let lastAssetID: UUID?
    let target: StandardModelSuggestionTarget?
    let checkedCount: Int
    let suggestedCount: Int
    let skippedCount: Int

    static let empty = StandardLibrarySuggestionsCheckpoint(
        lastAssetID: nil,
        target: nil,
        checkedCount: 0,
        suggestedCount: 0,
        skippedCount: 0
    )
}

enum StandardLibrarySuggestionsCodec {
    static func encodePayload(_ payload: StandardLibrarySuggestionsPayload) throws -> Data {
        try JSONEncoder().encode(payload)
    }

    static func decodePayload(_ data: Data) throws -> StandardLibrarySuggestionsPayload {
        let payload = try JSONDecoder().decode(StandardLibrarySuggestionsPayload.self, from: data)
        guard payload.contractVersion == StandardLibrarySuggestionsJobFactory.contractVersion,
              !payload.sourceIDs.isEmpty,
              Set(payload.sourceIDs).count == payload.sourceIDs.count,
              payload.catalogCutoffMs >= 0,
              validateTarget(payload.target)
        else {
            throw StandardLibrarySuggestionsCodecError.invalidPayload
        }
        return payload
    }

    static func encodeCheckpoint(_ checkpoint: StandardLibrarySuggestionsCheckpoint) throws -> Data {
        try JSONEncoder().encode(checkpoint)
    }

    static func decodeCheckpoint(_ data: Data) throws -> StandardLibrarySuggestionsCheckpoint {
        let checkpoint = try JSONDecoder().decode(StandardLibrarySuggestionsCheckpoint.self, from: data)
        guard checkpoint.checkedCount >= 0,
              checkpoint.suggestedCount >= 0,
              checkpoint.skippedCount >= 0,
              checkpoint.skippedCount <= checkpoint.checkedCount,
              checkpoint.target.map(validateTarget) ?? true
        else {
            throw StandardLibrarySuggestionsCodecError.invalidCheckpoint
        }
        return checkpoint
    }

    static func jobCheckpoint(from checkpoint: StandardLibrarySuggestionsCheckpoint) throws -> JobCheckpoint {
        JobCheckpoint(
            version: StandardLibrarySuggestionsJobFactory.checkpointVersion,
            data: try encodeCheckpoint(checkpoint)
        )
    }

    static func checkpoint(from checkpoint: JobCheckpoint?) throws -> StandardLibrarySuggestionsCheckpoint {
        guard let checkpoint else { return .empty }
        guard checkpoint.version == StandardLibrarySuggestionsJobFactory.checkpointVersion else {
            throw StandardLibrarySuggestionsCodecError.invalidCheckpoint
        }
        return try decodeCheckpoint(checkpoint.data)
    }

    static func validateTarget(_ target: StandardModelSuggestionTarget) -> Bool {
        !target.standardPackID.isEmpty && !target.standardPackRevision.isEmpty
    }
}

enum StandardLibrarySuggestionsCodecError: Error, Equatable {
    case invalidPayload
    case invalidCheckpoint
}
