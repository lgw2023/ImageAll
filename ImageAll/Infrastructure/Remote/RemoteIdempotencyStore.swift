import Foundation
import os

/// File-backed idempotency ledger for remote mutations (tag decisions, review decisions).
/// Keyed by client-supplied `operationID`: replaying the same `operationID` with the same
/// mutation payload returns the original response instead of re-applying it; replaying it
/// with a *different* payload is a conflict (HTTP 409 at the routing layer).
///
/// Persisted as JSON under Application Support so idempotency survives Mac Host restarts —
/// a companion device that retries a mutation after the Mac relaunches must not double-apply it.
actor RemoteIdempotencyStore {
    /// Identifies what request produced a response, so replays can be distinguished from
    /// operationID collisions across different mutations.
    struct MutationKey: Codable, Equatable, Sendable {
        let kind: String
        let tagID: UUID?
        let assetIDs: [UUID]
        let action: String
        let subject: String?

        /// Normalizes `assetIDs` so unordered-but-equal sets compare equal.
        init(kind: String, tagID: UUID, assetIDs: [UUID], action: String) {
            self.kind = kind
            self.tagID = tagID
            self.assetIDs = Array(Set(assetIDs)).sorted { $0.uuidString < $1.uuidString }
            self.action = action
            self.subject = nil
        }

        init(kind: String, subject: String, assetIDs: [UUID], action: String) {
            self.kind = kind
            self.tagID = nil
            self.assetIDs = Array(Set(assetIDs)).sorted { $0.uuidString < $1.uuidString }
            self.action = action
            self.subject = subject
        }
    }

    enum IdempotencyError: Error, Equatable {
        case conflict
    }

    private struct StoredRecord: Codable {
        let operationID: UUID
        let key: MutationKey
        let responseData: Data
        let createdAtMs: Int64
    }

    private struct PersistedState: Codable {
        var records: [StoredRecord]
    }

    /// `operationID` alone is not a unique record identity: a tag decision and a review
    /// decision issued independently could coincidentally reuse the same client-generated
    /// `operationID` without being related mutations. Namespacing by `MutationKey.kind` keeps
    /// those ledgers independent while still detecting genuine conflicts within the same kind.
    private struct RecordKey: Hashable {
        let operationID: UUID
        let kind: String
    }

    private let logger = Logger(subsystem: "com.gwlee.ImageAll", category: "RemoteIdempotencyStore")
    private let storageURL: URL
    private var records: [RecordKey: StoredRecord] = [:]

    init(storageURL: URL) {
        self.storageURL = storageURL
        self.records = Self.loadRecords(from: storageURL, logger: logger)
    }

    /// Executes `mutate` unless `operationID` already has a recorded response for an equal
    /// `key`, in which case that response is decoded and replayed. Throws `.conflict` if
    /// `operationID` was previously used with a *different* `key`.
    func perform<Response: Codable>(
        operationID: UUID,
        key: MutationKey,
        mutate: @Sendable () throws -> Response
    ) throws -> (response: Response, replayed: Bool) {
        let recordKey = RecordKey(operationID: operationID, kind: key.kind)
        if let existing = records[recordKey] {
            guard existing.key == key else {
                throw IdempotencyError.conflict
            }
            let decoded = try JSONDecoder().decode(Response.self, from: existing.responseData)
            return (decoded, true)
        }
        let response = try mutate()
        let data = try JSONEncoder().encode(response)
        records[recordKey] = StoredRecord(
            operationID: operationID,
            key: key,
            responseData: data,
            createdAtMs: Self.nowMs()
        )
        save()
        return (response, false)
    }

    /// Reads an already-recorded response without reserving a new operation. This is used
    /// by asynchronous commands that can only be persisted after the command port accepts
    /// the work. A mismatched payload remains a conflict.
    func replay<Response: Codable>(
        operationID: UUID,
        key: MutationKey,
        as _: Response.Type = Response.self
    ) throws -> Response? {
        let recordKey = RecordKey(operationID: operationID, kind: key.kind)
        guard let existing = records[recordKey] else { return nil }
        guard existing.key == key else {
            throw IdempotencyError.conflict
        }
        return try JSONDecoder().decode(Response.self, from: existing.responseData)
    }

    /// Records the response after an asynchronous command has been accepted. Re-recording
    /// the same key is harmless; using the operation ID with a different payload conflicts.
    func record<Response: Codable>(
        operationID: UUID,
        key: MutationKey,
        response: Response
    ) throws {
        let recordKey = RecordKey(operationID: operationID, kind: key.kind)
        if let existing = records[recordKey] {
            guard existing.key == key else {
                throw IdempotencyError.conflict
            }
            return
        }
        let data = try JSONEncoder().encode(response)
        records[recordKey] = StoredRecord(
            operationID: operationID,
            key: key,
            responseData: data,
            createdAtMs: Self.nowMs()
        )
        save()
    }

    /// Test/inspection hook: number of recorded operations.
    func recordedOperationCount() -> Int { records.count }

    private static func loadRecords(
        from storageURL: URL,
        logger: Logger
    ) -> [RecordKey: StoredRecord] {
        guard let data = try? Data(contentsOf: storageURL) else { return [:] }
        guard let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            logger.error("Remote idempotency state at \(storageURL.path, privacy: .public) is corrupt; starting empty")
            return [:]
        }
        return Dictionary(
            uniqueKeysWithValues: state.records.map { (RecordKey(operationID: $0.operationID, kind: $0.key.kind), $0) }
        )
    }

    private func save() {
        let state = PersistedState(records: Array(records.values))
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            logger.error("Remote idempotency state save failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}
