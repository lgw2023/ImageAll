import Foundation

public struct ImageAllMigrationHandoffRequest: Codable, Sendable {
    public let manifestSHA256: String
    public init(manifestSHA256: String) { self.manifestSHA256 = manifestSHA256 }
}

/// Immutable custody registration plus a small, separately persisted local
/// status. Status is never authority to publish or delete anything.
public struct ImageAllMigrationHostJob: Codable, Sendable, Equatable, Identifiable {
    public enum Phase: String, Codable, Sendable { case received, verifying, publishing, cleanup, complete, needsAttention }
    public struct State: Codable, Sendable, Equatable {
        public let migrationID: UUID
        public let phase: Phase
        public let error: String?
        public let updatedAtMs: Int64
        public init(migrationID: UUID, phase: Phase, error: String? = nil) {
            self.migrationID = migrationID; self.phase = phase; self.error = error
            updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        }
    }
    public let receipt: ImageAllMigrationTransferSealReceipt
    public let deviceID: UUID
    public let sourceInstallID: UUID
    public let sourceEpoch: UUID
    public var state: State?
    public var id: UUID { receipt.migrationID }
    public var phase: Phase { state?.phase ?? .received }
    public var query: RemoteImportTaskQuery {
        .init(taskID: id, migrationID: id, sourceInstallID: sourceInstallID,
              sourceEpoch: sourceEpoch, manifestSHA256: receipt.manifestSHA256)
    }
}
