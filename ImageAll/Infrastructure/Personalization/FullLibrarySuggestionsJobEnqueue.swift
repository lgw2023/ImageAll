import Foundation

enum FullLibrarySuggestionsJobEnqueue {
    static func makeEnqueueCommand(
        jobID: UUID,
        tagID: UUID,
        sourceIDs: [UUID],
        catalogCutoffMs: Int64,
        modelRevision: Int,
        frozenPositiveSamples: [FrozenSampleIdentity],
        frozenNegativeSamples: [FrozenSampleIdentity],
        notBeforeMs: Int64
    ) throws -> EnqueueJobCommand {
        let payload = FullLibrarySuggestionsPayload(
            contractVersion: FullLibrarySuggestionsJobFactory.contractVersion,
            tagID: tagID,
            sourceIDs: sourceIDs.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() },
            catalogCutoffMs: catalogCutoffMs,
            modelRevision: modelRevision,
            frozenPositiveSamples: frozenPositiveSamples,
            frozenNegativeSamples: frozenNegativeSamples
        )
        return EnqueueJobCommand(
            id: jobID,
            kind: FullLibrarySuggestionsJobFactory.kind,
            payloadVersion: FullLibrarySuggestionsJobFactory.payloadVersion,
            payload: try FullLibrarySuggestionsCodec.encodePayload(payload),
            sourceID: nil,
            coalescingKey: FullLibrarySuggestionsJobFactory.coalescingKey(tagID: tagID),
            priority: FullLibrarySuggestionsJobFactory.priority,
            maxAttempts: FullLibrarySuggestionsJobFactory.maxAttempts,
            notBeforeMs: notBeforeMs
        )
    }
}

struct MultiJobHandlerRegistry: JobHandlerRegistry, Sendable {
    private let handlers: [String: any JobHandler]

    init(handlers: [any JobHandler]) {
        var map: [String: any JobHandler] = [:]
        for handler in handlers {
            map[handler.kind] = handler
        }
        self.handlers = map
    }

    func handler(forKind kind: String) -> (any JobHandler)? {
        handlers[kind]
    }
}
