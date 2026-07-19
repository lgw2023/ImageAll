import Foundation

enum PersonalLibrarySuggestionsJobEnqueue {
    static func makeEnqueueCommand(
        jobID: UUID,
        sourceIDs: [UUID],
        catalogCutoffMs: Int64,
        capability: PersonalModelSuggestionCapability,
        notBeforeMs: Int64
    ) throws -> EnqueueJobCommand {
        let frozenCapability = PersonalModelSuggestionCapability(
            target: capability.target,
            tagIDs: capability.tagIDs.sorted { $0.uuidString < $1.uuidString }
        )
        let payload = PersonalLibrarySuggestionsPayload(
            contractVersion: PersonalLibrarySuggestionsJobFactory.contractVersion,
            sourceIDs: sourceIDs.sorted { $0.uuidString < $1.uuidString },
            catalogCutoffMs: catalogCutoffMs,
            capability: frozenCapability
        )
        return EnqueueJobCommand(
            id: jobID,
            kind: PersonalLibrarySuggestionsJobFactory.kind,
            payloadVersion: PersonalLibrarySuggestionsJobFactory.payloadVersion,
            payload: try PersonalLibrarySuggestionsCodec.encodePayload(payload),
            sourceID: nil,
            coalescingKey: PersonalLibrarySuggestionsJobFactory.coalescingKey(
                catalogScopeID: capability.target.catalogScopeID
            ),
            priority: PersonalLibrarySuggestionsJobFactory.priority,
            maxAttempts: PersonalLibrarySuggestionsJobFactory.maxAttempts,
            notBeforeMs: notBeforeMs
        )
    }
}

enum StandardLibrarySuggestionsJobEnqueue {
    static func makeEnqueueCommand(
        jobID: UUID,
        sourceIDs: [UUID],
        catalogCutoffMs: Int64,
        target: StandardModelSuggestionTarget,
        notBeforeMs: Int64
    ) throws -> EnqueueJobCommand {
        let payload = StandardLibrarySuggestionsPayload(
            contractVersion: StandardLibrarySuggestionsJobFactory.contractVersion,
            sourceIDs: sourceIDs.sorted { $0.uuidString < $1.uuidString },
            catalogCutoffMs: catalogCutoffMs,
            target: target
        )
        return EnqueueJobCommand(
            id: jobID,
            kind: StandardLibrarySuggestionsJobFactory.kind,
            payloadVersion: StandardLibrarySuggestionsJobFactory.payloadVersion,
            payload: try StandardLibrarySuggestionsCodec.encodePayload(payload),
            sourceID: nil,
            coalescingKey: StandardLibrarySuggestionsJobFactory.coalescingKey(
                standardPackID: target.standardPackID
            ),
            priority: StandardLibrarySuggestionsJobFactory.priority,
            maxAttempts: StandardLibrarySuggestionsJobFactory.maxAttempts,
            notBeforeMs: notBeforeMs
        )
    }
}
