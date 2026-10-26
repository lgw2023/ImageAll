import Foundation

/// Correlation only: taskID is phone-owned, never an authorization credential.
/// The host authorizes the paired device and the bound source separately.
public struct RemoteImportTaskQuery: Codable, Sendable, Equatable {
    public let taskID: UUID
    public let migrationID: UUID
    public let sourceInstallID: UUID
    public let sourceEpoch: UUID
    public let manifestSHA256: String

    public init(taskID: UUID, migrationID: UUID, sourceInstallID: UUID,
                sourceEpoch: UUID, manifestSHA256: String) {
        self.taskID = taskID; self.migrationID = migrationID
        self.sourceInstallID = sourceInstallID; self.sourceEpoch = sourceEpoch
        self.manifestSHA256 = manifestSHA256
    }
}

/// A fresh catalog observation, not a new byte-integrity or deletion receipt.
public struct RemoteImportTaskStatus: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case awaitingImport, verifying, publishing, browsable, needsAttention
    }
    public let query: RemoteImportTaskQuery
    public let phase: Phase
    public let sourceID: UUID?
    public let itemCount: Int?
    public let checkedAtMs: Int64

    public init(query: RemoteImportTaskQuery, phase: Phase, sourceID: UUID? = nil,
                itemCount: Int? = nil, checkedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) {
        self.query = query; self.phase = phase; self.sourceID = sourceID
        self.itemCount = itemCount; self.checkedAtMs = checkedAtMs
    }
}

/// Issued only after an explicit full final-archive and publication audit.
/// Accepted over the pinned paired session, for the caller's fresh nonce only.
public struct RemoteExportCleanupReceipt: Codable, Sendable, Equatable {
    public let query: RemoteImportTaskQuery
    public let nonce: UUID
    public let hostID: UUID
    public let deviceID: UUID
    public let sourceID: UUID
    public let itemCount: Int
    public let resourceCount: Int
    public let verifiedBytes: Int64
    public init(query: RemoteImportTaskQuery, nonce: UUID, hostID: UUID, deviceID: UUID,
                sourceID: UUID, itemCount: Int, resourceCount: Int, verifiedBytes: Int64) {
        self.query = query; self.nonce = nonce; self.hostID = hostID; self.deviceID = deviceID
        self.sourceID = sourceID; self.itemCount = itemCount
        self.resourceCount = resourceCount; self.verifiedBytes = verifiedBytes
    }
    public func validate(query: RemoteImportTaskQuery, nonce: UUID, hostID: UUID, deviceID: UUID) throws {
        guard self.query == query, self.nonce == nonce, self.hostID == hostID, self.deviceID == deviceID,
              itemCount >= 0, resourceCount >= 0, verifiedBytes >= 0 else {
            throw ImageAllMigrationCleanupError.incompleteReferences
        }
    }
}
