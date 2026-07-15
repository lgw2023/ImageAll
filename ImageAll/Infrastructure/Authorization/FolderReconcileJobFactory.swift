import Foundation

enum FolderReconcileJobFactory {
    static let kind = "folder.reconcile.v1"
    static let payloadVersion = 1
    static let contractVersion = 1
    static let maxAttempts = 5
    static let priority = 0

    static func coalescingKey(sourceID: UUID) -> String {
        "\(kind):\(sourceID.uuidString.lowercased())"
    }

    static func makePayload(sourceID: UUID) throws -> Data {
        let payload: [String: Any] = [
            "contract_version": contractVersion,
            "source_id": sourceID.uuidString.lowercased(),
        ]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw FolderAuthorizationError.persistenceFailure
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    static func decodedPayloadKeys(_ payload: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw FolderAuthorizationError.persistenceFailure
        }
        return object
    }

    static func makeEnqueueCommand(
        jobID: UUID,
        sourceID: UUID,
        notBeforeMs: Int64
    ) throws -> EnqueueJobCommand {
        EnqueueJobCommand(
            id: jobID,
            kind: kind,
            payloadVersion: payloadVersion,
            payload: try makePayload(sourceID: sourceID),
            sourceID: sourceID,
            coalescingKey: coalescingKey(sourceID: sourceID),
            priority: priority,
            maxAttempts: maxAttempts,
            notBeforeMs: notBeforeMs
        )
    }
}
