import Foundation

/// Evidence identifiers and the exact locally checked scope. This is not permission
/// to call PhotoKit; the foreground coordinator must obtain user confirmation and
/// revalidate source bytes, current favorites and the Mac copies separately.
public struct LocalSourceRetirementPlan: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let migrationID: UUID
    public let requestID: UUID
    public let sourceReportID: UUID
    public let completionReceiptID: UUID
    public let backupReceiptID: UUID
    public let manifestSHA256: String
    public let factSnapshotSHA256: String
    public let candidateAssetIDs: [UUID]
    public let snapshot: LocalSharedSnapshot
    public let checkpoint: LocalMigrationSyncCheckpoint

    public init(id: UUID, migrationID: UUID, requestID: UUID, sourceReportID: UUID,
        completionReceiptID: UUID, backupReceiptID: UUID, manifestSHA256: String,
        factSnapshotSHA256: String, candidateAssetIDs: [UUID], snapshot: LocalSharedSnapshot,
        checkpoint: LocalMigrationSyncCheckpoint) {
        self.id = id; self.migrationID = migrationID; self.requestID = requestID
        self.sourceReportID = sourceReportID; self.completionReceiptID = completionReceiptID
        self.backupReceiptID = backupReceiptID; self.manifestSHA256 = manifestSHA256
        self.factSnapshotSHA256 = factSnapshotSHA256; self.candidateAssetIDs = candidateAssetIDs
        self.snapshot = snapshot; self.checkpoint = checkpoint
    }
}

public enum LocalSourceRetirementState: String, Codable, Sendable {
    case prepared, submitted, completed, cancelled, failed, outcomeUnknown
}

public enum LocalSourceRetirementOutcome: Sendable {
    case succeeded, failed, unknown
}

public struct LocalSourceRetirementRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { plan.id }
    public let plan: LocalSourceRetirementPlan
    public let state: LocalSourceRetirementState
    public let updatedAtMs: Int64
}

public enum LocalRetiredReplicaPresence: String, Sendable {
    case retired, observedAgain
}

/// Adapters must validate foreground, current authorization, source versions and
/// favorites immediately before submission. Throw only when the outcome is unknown.
public protocol LocalSourceRetiring: Sendable {
    func submitRetirement() async throws -> LocalSourceRetirementOutcome
}

public enum LocalSourceRetirementExecutor {
    /// The caller has already obtained explicit foreground confirmation and fresh
    /// Mac/source evidence. Once submitted, cancellation must not discard a known
    /// source callback: persist its actual outcome before returning.
    public static func perform(_ plan: LocalSourceRetirementPlan, store: LocalLibraryStore,
        visibleIdentifiers: Set<String>, source: any LocalSourceRetiring
    ) async throws -> LocalSourceRetirementRecord {
        try Task.checkCancellation()
        _ = try await store.prepareSourceRetirement(plan, visibleIdentifiers: visibleIdentifiers)
        do {
            try Task.checkCancellation()
            try await store.markSourceRetirementSubmitted(id: plan.id, visibleIdentifiers: visibleIdentifiers)
        } catch {
            if try await store.sourceRetirementRecords().first(where: { $0.id == plan.id })?.state == .prepared {
                try await store.cancelSourceRetirement(id: plan.id)
            }
            throw error
        }
        let outcome: LocalSourceRetirementOutcome
        do { outcome = try await source.submitRetirement() }
        catch {
            try await store.finishSourceRetirement(id: plan.id, outcome: .unknown)
            throw error
        }
        try await store.finishSourceRetirement(id: plan.id, outcome: outcome)
        guard let result = try await store.sourceRetirementRecords().first(where: { $0.id == plan.id }) else {
            throw LocalLibraryError.sourceRetirementConflict
        }
        return result
    }
}
