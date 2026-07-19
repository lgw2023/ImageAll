import CryptoKit
import Foundation

enum PersonalModelRebuildJobFactory {
    static let kind = "personalization.personalModelRebuild"
    static let payloadVersion = 1
    static let checkpointVersion = 1
    static let contractVersion = 1
    static let maxAttempts = 5
    static let priority = 0
    static let debounceDelayMs: Int64 = 30_000

    static func coalescingKey(
        catalogScopeID: String,
        decisionSnapshotRevision: String
    ) -> String {
        "personalization:personal-rebuild:\(catalogScopeID):\(decisionSnapshotRevision)"
    }

    static func payload(
        from snapshot: PersonalTrainingSnapshot
    ) throws -> PersonalModelRebuildJobPayload? {
        guard !snapshot.personalTagIDs.isEmpty, !snapshot.decisions.isEmpty else {
            return nil
        }
        let tagIDs = snapshot.personalTagIDs.sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        let decisions = snapshot.decisions.sorted(by: decisionIsOrderedBefore)
        let embeddingKeys = Array(Set(decisions.map {
            PersonalTrainingEmbeddingCacheKey(
                catalogScopeID: snapshot.catalogScopeID,
                assetID: $0.assetID,
                contentRevision: $0.contentRevision
            )
        })).sorted(by: embeddingKeyIsOrderedBefore)
        let payload = PersonalModelRebuildJobPayload(
            contractVersion: contractVersion,
            catalogScopeID: snapshot.catalogScopeID,
            decisionSnapshotRevision: sha256(
                decisions.map(decisionIdentity).joined(separator: "\n")
            ),
            personalTagIDs: tagIDs,
            labelVocabularyRevision: sha256(
                tagIDs.map { $0.uuidString.lowercased() }.joined(separator: "\n")
            ),
            embeddingKeys: embeddingKeys,
            decisions: decisions
        )
        guard PersonalModelRebuildJobCodec.validate(payload) else {
            throw PersonalModelRebuildJobCodecError.invalidPayload
        }
        return payload
    }

    private static func decisionIsOrderedBefore(
        _ lhs: PersonalTrainingDecision,
        _ rhs: PersonalTrainingDecision
    ) -> Bool {
        decisionIdentity(lhs) < decisionIdentity(rhs)
    }

    private static func decisionIdentity(_ decision: PersonalTrainingDecision) -> String {
        "\(decision.tagID.uuidString.lowercased())|\(decision.assetID.uuidString.lowercased())|\(decision.contentRevision)|\(decision.state.rawValue)"
    }

    private static func embeddingKeyIsOrderedBefore(
        _ lhs: PersonalTrainingEmbeddingCacheKey,
        _ rhs: PersonalTrainingEmbeddingCacheKey
    ) -> Bool {
        let left = "\(lhs.assetID.uuidString.lowercased())|\(lhs.contentRevision)"
        let right = "\(rhs.assetID.uuidString.lowercased())|\(rhs.contentRevision)"
        return left < right
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct PersonalModelRebuildJobPayload: Codable, Equatable, Sendable {
    let contractVersion: Int
    let catalogScopeID: String
    let decisionSnapshotRevision: String
    let personalTagIDs: [UUID]
    let labelVocabularyRevision: String
    let embeddingKeys: [PersonalTrainingEmbeddingCacheKey]
    let decisions: [PersonalTrainingDecision]
}

enum PersonalModelRebuildJobCodec {
    static func encodePayload(_ payload: PersonalModelRebuildJobPayload) throws -> Data {
        try JSONEncoder().encode(payload)
    }

    static func decodePayload(_ data: Data) throws -> PersonalModelRebuildJobPayload {
        let payload = try JSONDecoder().decode(PersonalModelRebuildJobPayload.self, from: data)
        guard validate(payload) else {
            throw PersonalModelRebuildJobCodecError.invalidPayload
        }
        return payload
    }

    static func validate(_ payload: PersonalModelRebuildJobPayload) -> Bool {
        let keyIdentities = payload.embeddingKeys.map {
            "\($0.assetID.uuidString.lowercased())|\($0.contentRevision)"
        }
        let keyIdentitySet = Set(keyIdentities)
        return payload.contractVersion == PersonalModelRebuildJobFactory.contractVersion
            && UUID(uuidString: payload.catalogScopeID)?.uuidString.lowercased()
                == payload.catalogScopeID
            && isLowercaseSHA256(payload.decisionSnapshotRevision)
            && isLowercaseSHA256(payload.labelVocabularyRevision)
            && !payload.personalTagIDs.isEmpty
            && Set(payload.personalTagIDs).count == payload.personalTagIDs.count
            && !payload.embeddingKeys.isEmpty
            && keyIdentitySet.count == payload.embeddingKeys.count
            && payload.embeddingKeys.allSatisfy {
                $0.catalogScopeID == payload.catalogScopeID && $0.contentRevision >= 0
            }
            && !payload.decisions.isEmpty
            && payload.decisions.allSatisfy {
                $0.contentRevision >= 0
                    && payload.personalTagIDs.contains($0.tagID)
                    && keyIdentitySet.contains(
                        "\($0.assetID.uuidString.lowercased())|\($0.contentRevision)"
                    )
            }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

enum PersonalModelRebuildJobCodecError: Error, Equatable {
    case invalidPayload
}

enum PersonalModelRebuildJobEnqueue {
    static func makeEnqueueCommand(
        jobID: UUID,
        payload: PersonalModelRebuildJobPayload,
        notBeforeMs: Int64
    ) throws -> EnqueueJobCommand {
        EnqueueJobCommand(
            id: jobID,
            kind: PersonalModelRebuildJobFactory.kind,
            payloadVersion: PersonalModelRebuildJobFactory.payloadVersion,
            payload: try PersonalModelRebuildJobCodec.encodePayload(payload),
            sourceID: nil,
            coalescingKey: PersonalModelRebuildJobFactory.coalescingKey(
                catalogScopeID: payload.catalogScopeID,
                decisionSnapshotRevision: payload.decisionSnapshotRevision
            ),
            priority: PersonalModelRebuildJobFactory.priority,
            maxAttempts: PersonalModelRebuildJobFactory.maxAttempts,
            notBeforeMs: notBeforeMs
        )
    }
}

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
