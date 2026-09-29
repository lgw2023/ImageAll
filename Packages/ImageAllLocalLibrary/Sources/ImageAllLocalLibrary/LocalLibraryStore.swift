import Foundation
import SQLite3

public enum LocalLibraryError: Error, Equatable {
    case database(String)
    case invalidName
    case unknownAsset
    case unknownTag
    case unknownCollection
    case syncIdentityChanged
    case syncScopeNotAcknowledged
    case syncConflictRequiresResolution
    case syncEarlierOperationPending
    case unsupportedSharedOperation
    case syncRemoteTagMismatch
    case syncRemoteTagAliasRequired(LocalSharedTagAliasCandidate)
    case syncRemoteCollectionMismatch
    case syncRemoteCollectionAliasRequired(LocalSharedCollectionAliasCandidate)
    case syncConflictDetailsUnavailable
    case migrationScopeIncomplete
    case migrationSyncPending
    case sharePlanExpired
    case undoUnavailable
    case sourceRetirementConflict
}

public struct LocalShareSelectionVersion: Sendable, Equatable {
    public let sourceEpoch: UUID
    public let revision: Int64
}

public enum LocalDecision: String, Codable, Sendable {
    case accepted, rejected, cleared
}

public enum LocalFavoriteWritebackState: String, Codable, Sendable {
    case notRequested, pending, matched, failed
}

public struct LocalObservedAsset: Sendable {
    public let localIdentifier: String
    public let kind: String
    public let creationDate: Date?
    public let isFavorite: Bool

    public init(localIdentifier: String, kind: String, creationDate: Date?, isFavorite: Bool) {
        self.localIdentifier = localIdentifier
        self.kind = kind
        self.creationDate = creationDate
        self.isFavorite = isFavorite
    }
}

public struct LocalAsset: Identifiable, Sendable {
    public let id: UUID
    public let localIdentifier: String
    public let kind: String
    public let creationDate: Date?
    public let observedFavorite: Bool
    public let favoriteTarget: Bool?
    public let favoriteWritebackState: LocalFavoriteWritebackState
    public let isShared: Bool
}

public struct LocalShareSelection: Identifiable, Sendable {
    public let id: UUID
    public let localIdentifier: String
    public let kind: String
    public let creationDate: Date?
}

public struct LocalTag: Identifiable, Sendable {
    public let id: UUID
    public let name: String
}

public struct LocalCollection: Identifiable, Sendable {
    public let id: UUID
    public let name: String
}

public struct LocalPendingOperation: Identifiable, Sendable {
    public let id: UUID
    public let sequence: Int64
    public let entityID: UUID
    public let field: String
    public let value: String
}

/// Only operations on explicitly shared assets may enter the network sync path.
/// The operation ID and sequence are the same durable values as the local audit outbox.
public struct LocalSharedPendingOperation: Identifiable, Sendable {
    public let id: UUID
    public let sequence: Int64
    public let assetID: UUID
    public let field: String
    public let value: String
    public let referenceName: String?
    public let scopeRevision: Int64
    public let preparedBaseRevision: Int64?
    public let isConflicted: Bool
    public let conflictRevision: Int64?
    public let conflictValue: String?
    public let conflictDecision: LocalDecision?
    public let conflictReason: LocalSharedConflictReason?
    public let verifiedCollectionRename: String?
    public let localCurrentDecision: LocalDecision?
    public let localCurrentIncluded: Bool?
    public let localCurrentFavoriteTarget: Bool?
}

public struct LocalPreparedSharedTagOperation: Sendable {
    public let hostID: UUID
    public let deviceID: UUID
    public let operation: LocalSharedPendingOperation
    public let tagID: UUID
    public let tagName: String
    public let decision: LocalDecision
    public let baseRevision: Int64
    public let installID: UUID
    public let sourceEpoch: UUID
}

public struct LocalPreparedSharedCollectionOperation: Sendable {
    public let hostID: UUID
    public let deviceID: UUID
    public let operation: LocalSharedPendingOperation
    public let collectionID: UUID
    public let collectionName: String
    public let included: Bool
    public let baseRevision: Int64
    public let installID: UUID
    public let sourceEpoch: UUID
}

public struct LocalPreparedSharedFavoriteOperation: Sendable {
    public let hostID: UUID
    public let deviceID: UUID
    public let operation: LocalSharedPendingOperation
    public let target: Bool
    public let baseRevision: Int64
    public let installID: UUID
    public let sourceEpoch: UUID
}

public enum LocalSharedTagDisposition: Sendable {
    case applied, unchanged, conflict
}

public enum LocalSharedConflictReason: String, Sendable {
    case fieldVersion, tagIdentity, collectionIdentity, nameAlias
}

public enum LocalSharedTagConflictResolution: Sendable {
    case acceptMac, keepPhone
}

public enum LocalSharedCollectionConflictResolution: Sendable {
    case acceptMac, keepPhone
}

public enum LocalSharedFavoriteConflictResolution: Sendable {
    case acceptMac, keepPhone
}

public struct LocalSharedTagChange: Sendable {
    public let sequence: Int64
    public let assetID: UUID
    public let tagID: UUID
    public let tagName: String
    public let decision: LocalDecision
    public let fieldRevision: Int64

    public init(
        sequence: Int64, assetID: UUID, tagID: UUID, tagName: String,
        decision: LocalDecision, fieldRevision: Int64
    ) {
        self.sequence = sequence
        self.assetID = assetID
        self.tagID = tagID
        self.tagName = tagName
        self.decision = decision
        self.fieldRevision = fieldRevision
    }
}

/// An authenticated change page exposed one possible identity match. The user
/// must confirm it; a matching display name alone never changes an identity.
public struct LocalSharedTagAliasCandidate: Equatable, Sendable {
    public let hostID: UUID
    public let deviceID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let afterCursor: Int64
    public let assetID: UUID
    public let remoteTagID: UUID
    public let remoteTagName: String
    public let localTagID: UUID
    public let localTagName: String

    init(
        hostID: UUID, deviceID: UUID, sourceEpoch: UUID, scopeRevision: Int64,
        afterCursor: Int64, assetID: UUID, remoteTagID: UUID,
        remoteTagName: String, localTagID: UUID, localTagName: String
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.afterCursor = afterCursor
        self.assetID = assetID
        self.remoteTagID = remoteTagID
        self.remoteTagName = remoteTagName
        self.localTagID = localTagID
        self.localTagName = localTagName
    }
}

public struct LocalSharedTagPullResult: Sendable {
    public let applied: Int
    public let conflicts: Int
    public let nextCursor: Int64
}

public struct LocalSharedCollectionChange: Sendable {
    public let sequence: Int64
    public let assetID: UUID
    public let collectionID: UUID
    public let collectionName: String
    public let included: Bool
    public let fieldRevision: Int64
    public let renamedFrom: String?
    public let createdCollectionID: UUID?

    public init(
        sequence: Int64, assetID: UUID, collectionID: UUID,
        collectionName: String, included: Bool, fieldRevision: Int64,
        renamedFrom: String? = nil, createdCollectionID: UUID? = nil
    ) {
        self.sequence = sequence
        self.assetID = assetID
        self.collectionID = collectionID
        self.collectionName = collectionName
        self.included = included
        self.fieldRevision = fieldRevision
        self.renamedFrom = renamedFrom
        self.createdCollectionID = createdCollectionID
    }
}

public struct LocalSharedCollectionHistoryPage: Sendable {
    public let hostID: UUID
    public let deviceID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let changes: [LocalSharedCollectionChange]
    public let nextCursor: Int64

    public init(hostID: UUID, deviceID: UUID, sourceEpoch: UUID, scopeRevision: Int64,
                changes: [LocalSharedCollectionChange], nextCursor: Int64) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.changes = changes
        self.nextCursor = nextCursor
    }
}

public struct LocalSharedCollectionAliasCandidate: Equatable, Sendable {
    public let hostID: UUID
    public let deviceID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let afterCursor: Int64
    public let assetID: UUID
    public let remoteCollectionID: UUID
    public let remoteCollectionName: String
    public let localCollectionID: UUID
    public let localCollectionName: String

    init(
        hostID: UUID, deviceID: UUID, sourceEpoch: UUID,
        scopeRevision: Int64, afterCursor: Int64, assetID: UUID,
        remoteCollectionID: UUID, remoteCollectionName: String,
        localCollectionID: UUID, localCollectionName: String
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.afterCursor = afterCursor
        self.assetID = assetID
        self.remoteCollectionID = remoteCollectionID
        self.remoteCollectionName = remoteCollectionName
        self.localCollectionID = localCollectionID
        self.localCollectionName = localCollectionName
    }
}

public struct LocalSharedCollectionPullResult: Sendable {
    public let applied: Int
    public let conflicts: Int
    public let nextCursor: Int64
}

public struct LocalSharedFavoriteChange: Sendable {
    public let sequence: Int64
    public let assetID: UUID
    public let target: Bool
    public let fieldRevision: Int64

    public init(sequence: Int64, assetID: UUID, target: Bool, fieldRevision: Int64) {
        self.sequence = sequence
        self.assetID = assetID
        self.target = target
        self.fieldRevision = fieldRevision
    }
}

public struct LocalSharedFavoritePullResult: Sendable {
    public let applied: Int
    public let conflicts: Int
    public let nextCursor: Int64
}

public struct LocalCollectionRenameCommand: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { commandID }
    public let commandID: UUID
    public let hostID: UUID
    public let deviceID: UUID
    public let installID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let snapshotSequence: Int64
    public let expectedChangeCursor: Int64
    public let localCollectionID: UUID
    public let collectionID: UUID
    public let expectedName: String
    public let newName: String
}

public enum LocalAuditOrigin: String, Codable, Sendable {
    case localEdit, remoteSync, conflictResolution
}

public struct LocalMigrationAuditRecord: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let sequence: Int64
    public let assetID: UUID
    public let field: String
    public let value: String
    public let createdAtMs: Int64
    public var origin: LocalAuditOrigin? = nil
    public var referenceName: String? = nil
}

/// A directory and human-fact projection for assets the owner explicitly selected.
/// It contains no media bytes, thumbnail, GPS, or unreferenced tag/collection names.
public struct LocalSharedSnapshot: Codable, Sendable, Equatable {
    public let installID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let snapshotSequence: Int64
    /// Monotonic local operation sequence captured with this directory/fact view.
    public let outboxWatermark: Int64
    /// Explicit grants, including items temporarily hidden by PhotoKit permission changes.
    public let selectedAssetIDs: [UUID]
    public let assets: [LocalSharedAsset]
    /// Included only in explicit migration exports, never normal directory delivery.
    public var auditRecords: [LocalMigrationAuditRecord]? = nil
}

/// Captured in the same SQLite transaction as a migration fact snapshot. It
/// proves only the phone's local delivery state at this watermark; Mac must
/// still compare the three cursors with its current change-log heads.
public struct LocalMigrationSyncCheckpoint: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let acknowledgedScopeRevision: Int64
    public let acknowledgedSnapshotSequence: Int64
    public let tagChangeCursor: Int64
    public let collectionChangeCursor: Int64
    public let favoriteChangeCursor: Int64
    /// Confirmed phone-local to Mac shared identities referenced by this fact snapshot.
    public let tagAliases: [LocalMigrationTagAlias]
    public let collectionAliases: [LocalMigrationCollectionAlias]
}

public struct LocalMigrationTagAlias: Codable, Sendable, Equatable {
    public let localTagID: UUID
    public let localTagName: String
    public let remoteTagID: UUID
    public let remoteTagName: String
}

public struct LocalMigrationCollectionAlias: Codable, Sendable, Equatable {
    public let localCollectionID: UUID
    public let localCollectionName: String
    public let remoteCollectionID: UUID
    public let remoteCollectionName: String
}

public struct LocalSharedAsset: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let localIdentifier: String
    public let kind: String
    public let creationDate: Date?
    public let observedFavorite: Bool
    public let favoriteTarget: Bool?
    public let tagDecisions: [LocalSharedTagDecision]
    public let collections: [LocalSharedCollectionMembership]
}

public struct LocalSharedTagDecision: Codable, Sendable, Equatable {
    public let tagID: UUID
    public let tagName: String
    public let decision: LocalDecision
}

public struct LocalSharedCollectionMembership: Codable, Sendable, Equatable {
    public let collectionID: UUID
    public let collectionName: String
}

/// Owns only ImageAll's local index and human facts. PhotoKit remains the source of media bytes.
/// Every fact change and its future sync operation are committed in the same SQLite transaction.
public actor LocalLibraryStore {
    nonisolated(unsafe) private let db: OpaquePointer

    public func exportBackup(to destination: URL) throws -> LocalLibraryBackupReport {
        try LocalLibraryBackup.write(source: db, to: destination)
    }

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard status == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let connection { sqlite3_close(connection) }
            throw LocalLibraryError.database(message)
        }
        db = connection
        sqlite3_busy_timeout(db, 5_000)
        do {
            let schema = """
                PRAGMA journal_mode=WAL;
                PRAGMA foreign_keys=ON;
                CREATE TABLE IF NOT EXISTS source_retirement_operations (
                  id TEXT PRIMARY KEY, plan_json TEXT NOT NULL, state TEXT NOT NULL, updated_at_ms INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS source_retirement_receipts (
                  operation_id TEXT PRIMARY KEY REFERENCES source_retirement_operations(id),
                  state TEXT NOT NULL, record_updated_at_ms INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS retired_source_replicas (
                  asset_id TEXT PRIMARY KEY REFERENCES assets(id), operation_id TEXT NOT NULL
                    REFERENCES source_retirement_operations(id), presence TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS identity (
                  key TEXT PRIMARY KEY, value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS assets (
                  id TEXT PRIMARY KEY, source_epoch TEXT NOT NULL,
                  local_identifier TEXT NOT NULL, kind TEXT NOT NULL,
                  creation_time REAL, observed_favorite INTEGER NOT NULL,
                  favorite_target INTEGER,
                  UNIQUE(source_epoch, local_identifier)
                );
                CREATE TABLE IF NOT EXISTS tags (
                  id TEXT PRIMARY KEY, name TEXT NOT NULL COLLATE NOCASE UNIQUE
                );
                CREATE TABLE IF NOT EXISTS tag_decisions (
                  asset_id TEXT NOT NULL REFERENCES assets(id),
                  tag_id TEXT NOT NULL REFERENCES tags(id),
                  decision TEXT NOT NULL, revision INTEGER NOT NULL,
                  PRIMARY KEY(asset_id, tag_id)
                );
                CREATE TABLE IF NOT EXISTS collections (
                  id TEXT PRIMARY KEY, name TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS memberships (
                  collection_id TEXT NOT NULL REFERENCES collections(id),
                  asset_id TEXT NOT NULL REFERENCES assets(id),
                  included INTEGER NOT NULL, revision INTEGER NOT NULL,
                  PRIMARY KEY(collection_id, asset_id)
                );
                CREATE TABLE IF NOT EXISTS outbox (
                  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                  operation_id TEXT NOT NULL UNIQUE, entity_id TEXT NOT NULL,
                  field TEXT NOT NULL, value TEXT NOT NULL,
                  created_time REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS audit_context (
                  operation_id TEXT PRIMARY KEY REFERENCES outbox(operation_id),
                  origin TEXT NOT NULL, reference_name TEXT
                );
                CREATE TABLE IF NOT EXISTS tag_undo (
                  operation_id TEXT PRIMARY KEY REFERENCES outbox(operation_id),
                  asset_id TEXT NOT NULL REFERENCES assets(id),
                  tag_id TEXT NOT NULL REFERENCES tags(id),
                  previous_decision TEXT NOT NULL, context TEXT NOT NULL,
                  UNIQUE(asset_id,tag_id)
                );
                CREATE TABLE IF NOT EXISTS collection_undo (
                  operation_id TEXT PRIMARY KEY REFERENCES outbox(operation_id),
                  asset_id TEXT NOT NULL REFERENCES assets(id),
                  collection_id TEXT NOT NULL REFERENCES collections(id),
                  previous_included INTEGER NOT NULL, context TEXT NOT NULL,
                  UNIQUE(asset_id,collection_id)
                );
                CREATE TABLE IF NOT EXISTS collection_undo_receipts (
                  original_operation_id TEXT PRIMARY KEY REFERENCES outbox(operation_id),
                  compensation_operation_id TEXT NOT NULL UNIQUE REFERENCES outbox(operation_id)
                );
                CREATE TABLE IF NOT EXISTS private_collection_names (
                  collection_id TEXT PRIMARY KEY REFERENCES collections(id), revision INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS private_collection_rename_events (
                  operation_id TEXT PRIMARY KEY REFERENCES outbox(operation_id),
                  collection_id TEXT NOT NULL REFERENCES collections(id),
                  old_name TEXT NOT NULL, new_name TEXT NOT NULL, previous_revision INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS collection_rename_commands (
                  command_id TEXT PRIMARY KEY, payload TEXT NOT NULL,
                  state TEXT NOT NULL CHECK(state IN ('pending','completed','abandoned')),
                  resulting_cursor INTEGER
                );
                CREATE UNIQUE INDEX IF NOT EXISTS one_pending_collection_rename
                  ON collection_rename_commands(state) WHERE state='pending';
                CREATE TABLE IF NOT EXISTS favorite_writebacks (
                  asset_id TEXT PRIMARY KEY REFERENCES assets(id),
                  target INTEGER NOT NULL, state TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS shared_assets (
                  asset_id TEXT PRIMARY KEY REFERENCES assets(id)
                );
                CREATE TABLE IF NOT EXISTS shared_outbox (
                  operation_id TEXT PRIMARY KEY REFERENCES outbox(operation_id),
                  asset_id TEXT NOT NULL REFERENCES assets(id),
                  field TEXT NOT NULL, value TEXT NOT NULL,
                  reference_name TEXT, scope_revision INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS shared_outbox_asset_idx ON shared_outbox(asset_id);
                CREATE TABLE IF NOT EXISTS shared_field_versions (
                  asset_id TEXT NOT NULL REFERENCES assets(id),
                  field TEXT NOT NULL, revision INTEGER NOT NULL,
                  PRIMARY KEY(asset_id,field)
                );
                CREATE TABLE IF NOT EXISTS shared_delivery (
                  operation_id TEXT PRIMARY KEY REFERENCES shared_outbox(operation_id) ON DELETE CASCADE,
                  host_id TEXT NOT NULL, device_id TEXT NOT NULL,
                  base_revision INTEGER NOT NULL, scope_revision INTEGER NOT NULL,
                  state TEXT NOT NULL, conflict_revision INTEGER,
                  conflict_value TEXT
                );
                CREATE TABLE IF NOT EXISTS shared_conflict_details (
                  operation_id TEXT PRIMARY KEY REFERENCES shared_delivery(operation_id) ON DELETE CASCADE,
                  reason TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS shared_collection_delivery_identity (
                  operation_id TEXT PRIMARY KEY REFERENCES shared_delivery(operation_id) ON DELETE CASCADE,
                  local_collection_id TEXT NOT NULL REFERENCES collections(id),
                  wire_collection_id TEXT NOT NULL, wire_name TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS shared_collection_rename_recovery (
                  operation_id TEXT PRIMARY KEY REFERENCES shared_delivery(operation_id) ON DELETE CASCADE,
                  source_epoch TEXT NOT NULL, current_name TEXT NOT NULL,
                  change_sequence INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS shared_snapshot_delivery (
                  id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS shared_tag_aliases (
                  host_id TEXT NOT NULL, device_id TEXT NOT NULL,
                  source_epoch TEXT NOT NULL,
                  remote_tag_id TEXT NOT NULL,
                  local_tag_id TEXT NOT NULL REFERENCES tags(id),
                  remote_name TEXT NOT NULL, local_name TEXT NOT NULL,
                  confirmed_time REAL NOT NULL,
                  PRIMARY KEY(host_id,device_id,source_epoch,remote_tag_id),
                  UNIQUE(host_id,device_id,source_epoch,local_tag_id)
                );
                CREATE TABLE IF NOT EXISTS shared_collection_aliases (
                  host_id TEXT NOT NULL, device_id TEXT NOT NULL,
                  source_epoch TEXT NOT NULL,
                  remote_collection_id TEXT NOT NULL,
                  local_collection_id TEXT NOT NULL REFERENCES collections(id),
                  remote_name TEXT NOT NULL, local_name TEXT NOT NULL,
                  confirmed_time REAL NOT NULL,
                  PRIMARY KEY(host_id,device_id,source_epoch,remote_collection_id),
                  UNIQUE(host_id,device_id,source_epoch,local_collection_id)
                );
                """
            let setup = schema + """
                INSERT OR IGNORE INTO identity(key,value) VALUES('install_id','\(UUID().uuidString)');
                INSERT OR IGNORE INTO identity(key,value) VALUES('source_epoch','\(UUID().uuidString)');
                INSERT OR IGNORE INTO identity(key,value) VALUES('share_scope_revision','0');
                INSERT OR IGNORE INTO identity(key,value) VALUES('share_snapshot_sequence','0');
                INSERT OR IGNORE INTO identity(key,value) VALUES('sync_host_id','');
                INSERT OR IGNORE INTO identity(key,value) VALUES('sync_device_id','');
                INSERT OR IGNORE INTO identity(key,value) VALUES('sync_ack_scope_revision','0');
                INSERT OR IGNORE INTO identity(key,value) VALUES('sync_ack_snapshot_sequence','0');
                INSERT OR IGNORE INTO identity(key,value) VALUES('sync_tag_change_cursor','0');
                INSERT OR IGNORE INTO identity(key,value) VALUES('sync_collection_change_cursor','0');
                INSERT OR IGNORE INTO identity(key,value) VALUES('sync_favorite_change_cursor','0');
                """
            guard sqlite3_exec(db, setup, nil, nil, nil) == SQLITE_OK else {
                throw LocalLibraryError.database(String(cString: sqlite3_errmsg(db)))
            }
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    public func sourceRetirementRecords() throws -> [LocalSourceRetirementRecord] {
        try rows("""
            SELECT o.plan_json,o.state,o.updated_at_ms,r.state,r.record_updated_at_ms
            FROM source_retirement_operations o LEFT JOIN source_retirement_receipts r ON r.operation_id=o.id
            ORDER BY o.updated_at_ms,o.id
            """).map { row in
            guard let json = row[0], let rawState = row[1], let state = LocalSourceRetirementState(rawValue: rawState),
                  let time = Int64(row[2] ?? "") else { throw LocalLibraryError.sourceRetirementConflict }
            var record = LocalSourceRetirementRecord(plan: try JSONDecoder().decode(LocalSourceRetirementPlan.self, from: Data(json.utf8)),
                state: state, updatedAtMs: time)
            record.acknowledgedByMac = row[3] == rawState && row[4] == String(time)
            return record
        }
    }

    public func acknowledgeSourceRetirement(id: UUID, state: LocalSourceRetirementState, updatedAtMs: Int64) throws {
        try transaction {
            let record = try sourceRetirementRecord(id)
            guard record.state == state, record.updatedAtMs == updatedAtMs,
                  [.submitted, .outcomeUnknown, .completed, .failed].contains(state) else {
                throw LocalLibraryError.sourceRetirementConflict
            }
            try execute("""
                INSERT INTO source_retirement_receipts(operation_id,state,record_updated_at_ms) VALUES(?,?,?)
                ON CONFLICT(operation_id) DO UPDATE SET state=excluded.state,record_updated_at_ms=excluded.record_updated_at_ms
                """, [id.uuidString, state.rawValue, String(updatedAtMs)])
        }
    }

    public func retiredSourcePresence(assetID: UUID) throws -> LocalRetiredReplicaPresence? {
        guard let raw = try scalar("SELECT presence FROM retired_source_replicas WHERE asset_id=?", [assetID.uuidString]) else { return nil }
        guard let presence = LocalRetiredReplicaPresence(rawValue: raw) else { throw LocalLibraryError.sourceRetirementConflict }
        return presence
    }

    @discardableResult public func prepareSourceRetirement(_ plan: LocalSourceRetirementPlan,
        visibleIdentifiers: Set<String>
    ) throws -> LocalSourceRetirementRecord {
        if let existing = try sourceRetirementRecords().first(where: { $0.id == plan.id }) {
            guard existing.plan == plan else { throw LocalLibraryError.sourceRetirementConflict }
            return existing
        }
        try validateSourceRetirementPlan(plan, visibleIdentifiers: visibleIdentifiers)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(plan), as: UTF8.self)
        try transaction {
            let ids = Set(plan.candidateAssetIDs)
            for record in try sourceRetirementRecords() where [.prepared, .submitted, .outcomeUnknown].contains(record.state) {
                guard ids.isDisjoint(with: record.plan.candidateAssetIDs) else { throw LocalLibraryError.sourceRetirementConflict }
            }
            for id in ids {
                guard try retiredSourcePresence(assetID: id) != .retired else { throw LocalLibraryError.sourceRetirementConflict }
            }
            try execute("INSERT INTO source_retirement_operations(id,plan_json,state,updated_at_ms) VALUES(?,?,'prepared',?)",
                [plan.id.uuidString, json, String(Int64(Date().timeIntervalSince1970 * 1_000))])
        }
        return try sourceRetirementRecord(plan.id)
    }

    /// Persist immediately before the single PhotoKit submission. An interrupted
    /// submitted operation must be reconciled; it must never be auto-replayed.
    public func markSourceRetirementSubmitted(id: UUID, visibleIdentifiers: Set<String>) throws {
        let record = try sourceRetirementRecord(id)
        guard record.state == .prepared else { throw LocalLibraryError.sourceRetirementConflict }
        try validateSourceRetirementPlan(record.plan, visibleIdentifiers: visibleIdentifiers)
        try setSourceRetirementState(id, .submitted)
    }

    public func cancelSourceRetirement(id: UUID) throws {
        let record = try sourceRetirementRecord(id)
        guard record.state == .prepared || record.state == .cancelled else { throw LocalLibraryError.sourceRetirementConflict }
        if record.state == .prepared { try setSourceRetirementState(id, .cancelled) }
    }

    /// Only a successful source API callback may supply .succeeded. Missing assets
    /// or reduced permission never prove deletion. No shared tombstone is emitted.
    public func finishSourceRetirement(id: UUID, outcome: LocalSourceRetirementOutcome) throws {
        let next: LocalSourceRetirementState
        switch outcome { case .succeeded: next = .completed; case .failed: next = .failed; case .unknown: next = .outcomeUnknown }
        try transaction {
            let record = try sourceRetirementRecord(id)
            if record.state == next { return }
            guard record.state == .submitted || record.state == .outcomeUnknown else {
                throw LocalLibraryError.sourceRetirementConflict
            }
            if next == .completed {
                for assetID in record.plan.candidateAssetIDs {
                    try execute("""
                        INSERT INTO retired_source_replicas(asset_id,operation_id,presence) VALUES(?,?,'retired')
                        ON CONFLICT(asset_id) DO UPDATE SET operation_id=excluded.operation_id,presence='retired'
                        """, [assetID.uuidString, id.uuidString])
                }
            }
            try setSourceRetirementState(id, next)
        }
    }

    private func sourceRetirementRecord(_ id: UUID) throws -> LocalSourceRetirementRecord {
        guard let record = try sourceRetirementRecords().first(where: { $0.id == id }) else {
            throw LocalLibraryError.sourceRetirementConflict
        }
        return record
    }

    private func setSourceRetirementState(_ id: UUID, _ state: LocalSourceRetirementState) throws {
        try execute("UPDATE source_retirement_operations SET state=?,updated_at_ms=? WHERE id=?",
            [state.rawValue, String(Int64(Date().timeIntervalSince1970 * 1_000)), id.uuidString])
    }

    private func validateSourceRetirementPlan(_ plan: LocalSourceRetirementPlan, visibleIdentifiers: Set<String>) throws {
        let ids = Set(plan.candidateAssetIDs)
        guard !ids.isEmpty, ids.count == plan.candidateAssetIDs.count,
              [plan.manifestSHA256, plan.factSnapshotSHA256].allSatisfy({ $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }) else {
            throw LocalLibraryError.sourceRetirementConflict
        }
        let current = try migrationCompletionCheckpoint(visibleIdentifiers: visibleIdentifiers)
        let expected = plan.snapshot, actual = current.snapshot
        guard current.checkpoint == plan.checkpoint,
              actual.installID == expected.installID, actual.sourceEpoch == expected.sourceEpoch,
              actual.scopeRevision == expected.scopeRevision, actual.outboxWatermark == expected.outboxWatermark,
              actual.selectedAssetIDs == expected.selectedAssetIDs, actual.assets == expected.assets,
              actual.auditRecords == expected.auditRecords,
              ids.isSubset(of: Set(actual.assets.filter { !$0.observedFavorite && $0.favoriteTarget != true }.map(\.id))) else {
            throw LocalLibraryError.sourceRetirementConflict
        }
    }

    public func installID() throws -> UUID {
        UUID(uuidString: try requiredIdentity("install_id"))!
    }

    public func sourceEpoch() throws -> UUID {
        UUID(uuidString: try requiredIdentity("source_epoch"))!
    }

    /// Selection is local and persistent. It never starts a network transfer.
    public func setShared(assetID: UUID, shared: Bool) throws {
        guard try exists("assets", id: assetID) else { throw LocalLibraryError.unknownAsset }
        let selected = try scalar("SELECT asset_id FROM shared_assets WHERE asset_id=?", [assetID.uuidString]) != nil
        guard selected != shared else { return }
        try transaction {
            if shared {
                try execute("INSERT INTO shared_assets(asset_id) VALUES(?)", [assetID.uuidString])
                try execute("""
                    DELETE FROM private_collection_names WHERE collection_id IN
                      (SELECT collection_id FROM memberships WHERE asset_id=?)
                    """, [assetID.uuidString])
            } else {
                try execute("DELETE FROM shared_assets WHERE asset_id=?", [assetID.uuidString])
                try execute("DELETE FROM shared_outbox WHERE asset_id=?", [assetID.uuidString])
                try execute("DELETE FROM shared_field_versions WHERE asset_id=?", [assetID.uuidString])
            }
            try execute("""
                UPDATE identity SET value=CAST(value AS INTEGER)+1 WHERE key='share_scope_revision'
                """)
            try execute("DELETE FROM shared_snapshot_delivery")
            // Unprepared operations have no wire payload yet and follow the new scope.
            // Prepared operations keep their original scope/digest for exact replay.
            try execute("""
                UPDATE shared_outbox SET scope_revision=(
                  SELECT CAST(value AS INTEGER) FROM identity WHERE key='share_scope_revision'
                ) WHERE operation_id NOT IN (SELECT operation_id FROM shared_delivery)
                """)
        }
    }

    public func shareSelectionVersion() throws -> LocalShareSelectionVersion {
        LocalShareSelectionVersion(sourceEpoch: try sourceEpoch(),
                                   revision: Int64(try requiredIdentity("share_scope_revision")) ?? 0)
    }

    /// Adds exactly a confirmed set in one scope transition; existing selections are retained.
    public func addSharedSelection(localIdentifiers: Set<String>, expected: LocalShareSelectionVersion) throws -> Int {
        var added = 0
        try transaction {
            guard try shareSelectionVersion() == expected, expected.revision < Int64.max else {
                throw LocalLibraryError.sharePlanExpired
            }
            let matched = try rows("SELECT id,local_identifier FROM assets WHERE source_epoch=?", [expected.sourceEpoch.uuidString])
                .filter { localIdentifiers.contains($0[1] ?? "") }
            guard matched.count == localIdentifiers.count else { throw LocalLibraryError.sharePlanExpired }
            for row in matched {
                let id = row[0] ?? ""
                guard try scalar("SELECT asset_id FROM shared_assets WHERE asset_id=?", [id]) == nil else { continue }
                try execute("INSERT INTO shared_assets(asset_id) VALUES(?)", [id])
                try execute("""
                    DELETE FROM private_collection_names WHERE collection_id IN
                      (SELECT collection_id FROM memberships WHERE asset_id=?)
                    """, [id])
                added += 1
            }
            if added > 0 {
                try execute("UPDATE identity SET value=? WHERE key='share_scope_revision'", [String(expected.revision + 1)])
                try execute("DELETE FROM shared_snapshot_delivery")
                try execute("""
                    UPDATE shared_outbox SET scope_revision=? WHERE operation_id NOT IN
                      (SELECT operation_id FROM shared_delivery)
                    """, [String(expected.revision + 1)])
            }
        }
        return added
    }

    public func isShared(assetID: UUID) throws -> Bool {
        try scalar("SELECT asset_id FROM shared_assets WHERE asset_id=?", [assetID.uuidString]) != nil
    }

    public func sharedSelections() throws -> [LocalShareSelection] {
        let epoch = try requiredIdentity("source_epoch")
        return try rows("""
            SELECT a.id,a.local_identifier,a.kind,a.creation_time
            FROM shared_assets s JOIN assets a ON a.id=s.asset_id
            WHERE a.source_epoch=? ORDER BY a.creation_time DESC,a.id
            """, [epoch]).compactMap { row in
                guard let id = UUID(uuidString: row[0] ?? ""), let identifier = row[1] else {
                    return nil
                }
                return LocalShareSelection(
                    id: id, localIdentifier: identifier, kind: row[2] ?? "image",
                    creationDate: row[3].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
                )
            }
    }

    public func validateSharedSnapshotScope(_ snapshot: LocalSharedSnapshot, visibleIdentifiers: Set<String>) throws {
        guard snapshot.installID == (try installID()), snapshot.sourceEpoch == (try sourceEpoch()),
              snapshot.scopeRevision == Int64(try requiredIdentity("share_scope_revision")),
              Set(snapshot.assets.map(\.localIdentifier)).isSubset(of: visibleIdentifiers) else {
            throw LocalLibraryError.syncIdentityChanged
        }
    }

    /// Reads the frozen request for a digest-only receipt lookup after ACK loss.
    public func pendingSharedSnapshot() throws -> LocalSharedSnapshot? {
        guard let encoded = try scalar("SELECT payload FROM shared_snapshot_delivery WHERE id=1"),
              let payload = encoded.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(LocalSharedSnapshot.self, from: payload)
    }

    /// Persists the exact payload before network I/O so a lost ACK can replay the same sequence.
    /// A changed visible set must use a new payload; revoked PhotoKit access is never replayed.
    public func prepareSharedSnapshot(visibleIdentifiers: Set<String>) throws -> LocalSharedSnapshot {
        let current = try networkSharedSnapshot(visibleIdentifiers: visibleIdentifiers)
        if let encoded = try scalar("SELECT payload FROM shared_snapshot_delivery WHERE id=1"),
           let payload = encoded.data(using: .utf8),
           let pending = try? JSONDecoder().decode(LocalSharedSnapshot.self, from: payload),
           pending.installID == current.installID,
           pending.sourceEpoch == current.sourceEpoch,
           pending.scopeRevision == current.scopeRevision,
           pending.selectedAssetIDs == current.selectedAssetIDs,
           Set(pending.assets.map(\.id)) == Set(current.assets.map(\.id)) {
            return pending
        }
        var prepared: LocalSharedSnapshot?
        try transaction {
            try execute("""
                UPDATE identity SET value=CAST(value AS INTEGER)+1 WHERE key='share_snapshot_sequence'
                """)
            let snapshot = try networkSharedSnapshot(visibleIdentifiers: visibleIdentifiers)
            guard let payload = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8)
            else { throw LocalLibraryError.database("cannot encode shared snapshot") }
            try execute("""
                INSERT INTO shared_snapshot_delivery(id,payload) VALUES(1,?)
                ON CONFLICT(id) DO UPDATE SET payload=excluded.payload
                """, [payload])
            prepared = snapshot
        }
        guard let prepared else { throw LocalLibraryError.database("missing prepared shared snapshot") }
        return prepared
    }

    /// Fact-only migration exports must capture current values, even while a
    /// frozen network snapshot is waiting for an ACK and must remain replayable.
    public func migrationFactSnapshot(visibleIdentifiers: Set<String>) throws -> LocalSharedSnapshot {
        var snapshot: LocalSharedSnapshot?
        try transaction {
            try execute("""
                UPDATE identity SET value=CAST(value AS INTEGER)+1 WHERE key='share_snapshot_sequence'
                """)
            snapshot = try addingMigrationAudit(to: sharedSnapshot(visibleIdentifiers: visibleIdentifiers))
        }
        guard let snapshot else { throw LocalLibraryError.database("missing migration fact snapshot") }
        return snapshot
    }

    /// Freeze one candidate completion watermark only after the entire
    /// explicitly shared scope is visible, acknowledged, and has no pending
    /// delivery or unresolved shared conflict. This does not claim that the
    /// Mac has no newer changes or that the archive is complete.
    public func migrationCompletionCheckpoint(
        visibleIdentifiers: Set<String>
    ) throws -> (snapshot: LocalSharedSnapshot, checkpoint: LocalMigrationSyncCheckpoint) {
        var result: (LocalSharedSnapshot, LocalMigrationSyncCheckpoint)?
        try transaction {
            let current = try sharedSnapshot(visibleIdentifiers: visibleIdentifiers)
            guard !current.selectedAssetIDs.isEmpty,
                  current.selectedAssetIDs.count == current.assets.count else {
                throw LocalLibraryError.migrationScopeIncomplete
            }
            let scope = Int64(try requiredIdentity("sync_ack_scope_revision")) ?? -1
            let ackSequence = Int64(try requiredIdentity("sync_ack_snapshot_sequence")) ?? 0
            let hostText = try requiredIdentity("sync_host_id")
            let deviceText = try requiredIdentity("sync_device_id")
            guard scope == current.scopeRevision, ackSequence > 0,
                  let hostID = UUID(uuidString: hostText),
                  let deviceID = UUID(uuidString: deviceText) else {
                throw LocalLibraryError.syncScopeNotAcknowledged
            }
            let pending = Int64(try scalar("SELECT COUNT(*) FROM shared_outbox") ?? "0") ?? -1
            let frozenSnapshot = try scalar(
                "SELECT payload FROM shared_snapshot_delivery WHERE id=1"
            )
            guard pending == 0, frozenSnapshot == nil, try pendingCollectionRename() == nil else {
                throw LocalLibraryError.migrationSyncPending
            }
            try execute("""
                UPDATE identity SET value=CAST(value AS INTEGER)+1
                WHERE key='share_snapshot_sequence'
                """)
            let snapshot = try addingMigrationAudit(to: sharedSnapshot(visibleIdentifiers: visibleIdentifiers))
            let referencedTagIDs = Set(snapshot.assets.flatMap {
                $0.tagDecisions.map(\.tagID)
            })
            let tagAliases = try rows("""
                SELECT local_tag_id,local_name,remote_tag_id,remote_name
                FROM shared_tag_aliases
                WHERE host_id=? AND device_id=? AND source_epoch=?
                ORDER BY local_tag_id
                """, [hostID.uuidString, deviceID.uuidString,
                       snapshot.sourceEpoch.uuidString]).compactMap { row -> LocalMigrationTagAlias? in
                    guard let localTagID = UUID(uuidString: row[0] ?? ""),
                          referencedTagIDs.contains(localTagID),
                          let localName = row[1],
                          let remoteTagID = UUID(uuidString: row[2] ?? ""),
                          let remoteName = row[3] else { return nil }
                    return LocalMigrationTagAlias(
                        localTagID: localTagID, localTagName: localName,
                        remoteTagID: remoteTagID, remoteTagName: remoteName
                    )
                }
            let referencedCollectionIDs = Set(snapshot.assets.flatMap {
                $0.collections.map(\.collectionID)
            })
            let collectionAliases = try rows("""
                SELECT local_collection_id,local_name,remote_collection_id,remote_name
                FROM shared_collection_aliases
                WHERE host_id=? AND device_id=? AND source_epoch=?
                ORDER BY local_collection_id
                """, [hostID.uuidString, deviceID.uuidString,
                       snapshot.sourceEpoch.uuidString]).compactMap { row -> LocalMigrationCollectionAlias? in
                    guard let localID = UUID(uuidString: row[0] ?? ""),
                          referencedCollectionIDs.contains(localID),
                          let localName = row[1],
                          let remoteID = UUID(uuidString: row[2] ?? ""),
                          let remoteName = row[3] else { return nil }
                    return LocalMigrationCollectionAlias(
                        localCollectionID: localID, localCollectionName: localName,
                        remoteCollectionID: remoteID, remoteCollectionName: remoteName
                    )
                }
            let checkpoint = LocalMigrationSyncCheckpoint(
                hostID: hostID, deviceID: deviceID,
                acknowledgedScopeRevision: scope,
                acknowledgedSnapshotSequence: ackSequence,
                tagChangeCursor: Int64(try requiredIdentity("sync_tag_change_cursor")) ?? 0,
                collectionChangeCursor: Int64(
                    try requiredIdentity("sync_collection_change_cursor")
                ) ?? 0,
                favoriteChangeCursor: Int64(
                    try requiredIdentity("sync_favorite_change_cursor")
                ) ?? 0,
                tagAliases: tagAliases, collectionAliases: collectionAliases
            )
            result = (snapshot, checkpoint)
        }
        guard let result else {
            throw LocalLibraryError.database("missing migration completion checkpoint")
        }
        return result
    }

    /// The caller supplies the identifiers currently returned by PhotoKit. Missing permission
    /// only hides the projection; it does not revoke sharing or generate deletion records.
    private func addingMigrationAudit(to snapshot: LocalSharedSnapshot) throws -> LocalSharedSnapshot {
        let ids = Set(snapshot.assets.map(\.id))
        var result = snapshot
        result.auditRecords = try rows("""
            SELECT o.operation_id,o.sequence,o.entity_id,o.field,o.value,o.created_time,c.origin,c.reference_name
            FROM outbox o JOIN shared_assets s ON s.asset_id=o.entity_id
            LEFT JOIN audit_context c ON c.operation_id=o.operation_id
            WHERE o.sequence<=? ORDER BY o.sequence
            """, [String(snapshot.outboxWatermark)]).compactMap { row in
                guard let assetID = UUID(uuidString: row[2] ?? ""), ids.contains(assetID) else { return nil }
                guard let operationID = UUID(uuidString: row[0] ?? ""),
                      let sequence = Int64(row[1] ?? ""), let field = row[3], let value = row[4],
                      let time = Double(row[5] ?? ""), time.isFinite, time >= 0,
                      time * 1_000 < Double(Int64.max) else {
                    throw LocalLibraryError.database("invalid migration audit record")
                }
                return LocalMigrationAuditRecord(operationID: operationID, sequence: sequence,
                    assetID: assetID, field: field, value: value, createdAtMs: Int64(time * 1_000),
                    origin: row[6].flatMap(LocalAuditOrigin.init(rawValue:)), referenceName: row[7])
            }
        return result
    }

    public func sharedSnapshot(visibleIdentifiers: Set<String>) throws -> LocalSharedSnapshot {
        let epoch = try requiredIdentity("source_epoch")
        let revision = Int64(try requiredIdentity("share_scope_revision")) ?? 0
        let sequence = Int64(try requiredIdentity("share_snapshot_sequence")) ?? 0
        let outboxWatermark = Int64(try scalar("""
            SELECT MAX(sequence) FROM outbox
            """) ?? "0") ?? 0
        let selected = try rows("""
            SELECT a.id,a.local_identifier,a.kind,a.creation_time,a.observed_favorite,a.favorite_target
            FROM shared_assets s JOIN assets a ON a.id=s.asset_id
            WHERE a.source_epoch=? ORDER BY a.id
            """, [epoch])
        let assets: [LocalSharedAsset] = try selected.compactMap { row in
            guard let id = UUID(uuidString: row[0] ?? ""),
                  let identifier = row[1], visibleIdentifiers.contains(identifier) else { return nil }
            let tagDecisions = try rows("""
                SELECT t.id,t.name,d.decision FROM tag_decisions d
                JOIN tags t ON t.id=d.tag_id WHERE d.asset_id=? ORDER BY t.id
                """, [id.uuidString]).compactMap { item -> LocalSharedTagDecision? in
                    guard let tagID = UUID(uuidString: item[0] ?? ""),
                          let decision = LocalDecision(rawValue: item[2] ?? "") else { return nil }
                    return LocalSharedTagDecision(
                        tagID: tagID, tagName: item[1] ?? "", decision: decision
                    )
                }
            let collections = try rows("""
                SELECT c.id,c.name FROM memberships m
                JOIN collections c ON c.id=m.collection_id
                WHERE m.asset_id=? AND m.included=1 ORDER BY c.id
                """, [id.uuidString]).compactMap { item -> LocalSharedCollectionMembership? in
                    guard let collectionID = UUID(uuidString: item[0] ?? "") else { return nil }
                    return LocalSharedCollectionMembership(
                        collectionID: collectionID, collectionName: item[1] ?? ""
                    )
                }
            return LocalSharedAsset(
                id: id, localIdentifier: identifier, kind: row[2] ?? "image",
                creationDate: row[3].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
                observedFavorite: row[4] == "1", favoriteTarget: row[5].map { $0 == "1" },
                tagDecisions: tagDecisions, collections: collections
            )
        }
        return LocalSharedSnapshot(
            installID: try installID(), sourceEpoch: try sourceEpoch(),
            scopeRevision: revision, snapshotSequence: sequence,
            outboxWatermark: outboxWatermark,
            selectedAssetIDs: selected.compactMap { UUID(uuidString: $0[0] ?? "") },
            assets: assets
        )
    }

    /// Only the network projection uses the Mac's confirmed tag identity.
    /// Local fact and migration snapshots retain the phone's original IDs.
    private func networkSharedSnapshot(visibleIdentifiers: Set<String>) throws -> LocalSharedSnapshot {
        let local = try sharedSnapshot(visibleIdentifiers: visibleIdentifiers)
        let assets = try local.assets.map { asset in
            let tags = try asset.tagDecisions.map { tag in
                let identity = try wireTagIdentity(for: tag.tagID, localName: tag.tagName)
                return LocalSharedTagDecision(
                    tagID: identity.id, tagName: identity.name, decision: tag.decision
                )
            }
            let collections = try asset.collections.map { collection in
                let identity = try wireCollectionIdentity(
                    for: collection.collectionID, localName: collection.collectionName
                )
                return LocalSharedCollectionMembership(
                    collectionID: identity.id, collectionName: identity.name
                )
            }
            return LocalSharedAsset(
                id: asset.id, localIdentifier: asset.localIdentifier,
                kind: asset.kind, creationDate: asset.creationDate,
                observedFavorite: asset.observedFavorite,
                favoriteTarget: asset.favoriteTarget,
                tagDecisions: tags, collections: collections
            )
        }
        return LocalSharedSnapshot(
            installID: local.installID, sourceEpoch: local.sourceEpoch,
            scopeRevision: local.scopeRevision,
            snapshotSequence: local.snapshotSequence,
            outboxWatermark: local.outboxWatermark,
            selectedAssetIDs: local.selectedAssetIDs, assets: assets
        )
    }

    /// Upserts only items PhotoKit returned. Permission contraction never creates tombstones.
    public func observe(_ assets: [LocalObservedAsset]) throws {
        let epoch = try requiredIdentity("source_epoch")
        try transaction {
            for asset in assets {
                guard !asset.localIdentifier.isEmpty else { continue }
                try execute("""
                    INSERT INTO assets(id,source_epoch,local_identifier,kind,creation_time,observed_favorite)
                    VALUES(?,?,?,?,?,?)
                    ON CONFLICT(source_epoch,local_identifier) DO UPDATE SET
                      kind=excluded.kind, creation_time=excluded.creation_time,
                      observed_favorite=excluded.observed_favorite
                    """, [
                        UUID().uuidString, epoch, asset.localIdentifier, asset.kind,
                        asset.creationDate.map { String($0.timeIntervalSince1970) } ?? "",
                        asset.isFavorite ? "1" : "0"
                    ])
                // Reappearance can mean a system Photos restore. Preserve the successful
                // retirement audit while making the local replica's presence explicit.
                try execute("""
                    UPDATE retired_source_replicas SET presence='observedAgain'
                    WHERE asset_id=(SELECT id FROM assets WHERE source_epoch=? AND local_identifier=?)
                    """, [epoch, asset.localIdentifier])
                // Source observation resolves an interrupted write and detects later drift.
                try execute("""
                    UPDATE favorite_writebacks SET state=CASE
                      WHEN target=? THEN 'matched'
                      WHEN state='matched' THEN 'failed'
                      ELSE state END
                    WHERE asset_id=(SELECT id FROM assets WHERE source_epoch=? AND local_identifier=?)
                    """, [asset.isFavorite ? "1" : "0", epoch, asset.localIdentifier])
            }
        }
    }

    public func assets(visibleIdentifiers: Set<String>) throws -> [LocalAsset] {
        guard !visibleIdentifiers.isEmpty else { return [] }
        let epoch = try requiredIdentity("source_epoch")
        let placeholders = Array(repeating: "?", count: visibleIdentifiers.count).joined(separator: ",")
        return try rows(
            "SELECT a.id,a.local_identifier,a.kind,a.creation_time,a.observed_favorite,a.favorite_target,w.state,s.asset_id FROM assets a LEFT JOIN favorite_writebacks w ON w.asset_id=a.id LEFT JOIN shared_assets s ON s.asset_id=a.id WHERE a.source_epoch=? AND a.local_identifier IN (\(placeholders))",
            [epoch] + visibleIdentifiers.sorted()
        )
            .compactMap { row in
                guard visibleIdentifiers.contains(row[1] ?? ""),
                      let id = UUID(uuidString: row[0] ?? "") else { return nil }
                return LocalAsset(
                    id: id, localIdentifier: row[1] ?? "", kind: row[2] ?? "image",
                    creationDate: (row[3].flatMap(Double.init)).map(Date.init(timeIntervalSince1970:)),
                    observedFavorite: row[4] == "1",
                    favoriteTarget: row[5].map { $0 == "1" },
                    favoriteWritebackState: LocalFavoriteWritebackState(rawValue: row[6] ?? "")
                        ?? .notRequested,
                    isShared: row[7] != nil
                )
            }
    }

    public func tags() throws -> [LocalTag] {
        try rows("SELECT id,name FROM tags ORDER BY name COLLATE NOCASE").compactMap {
            guard let id = UUID(uuidString: $0[0] ?? "") else { return nil }
            return LocalTag(id: id, name: $0[1] ?? "")
        }
    }

    public func collections() throws -> [LocalCollection] {
        try rows("SELECT id,name FROM collections ORDER BY name COLLATE NOCASE").compactMap {
            guard let id = UUID(uuidString: $0[0] ?? "") else { return nil }
            return LocalCollection(id: id, name: $0[1] ?? "")
        }
    }

    @discardableResult public func createTag(name: String) throws -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalLibraryError.invalidName }
        if let existing = try scalar("SELECT id FROM tags WHERE name=? COLLATE NOCASE", [trimmed]),
           let id = UUID(uuidString: existing) { return id }
        let id = UUID()
        try transaction {
            try execute("INSERT INTO tags(id,name) VALUES(?,?)", [id.uuidString, trimmed])
            try enqueue(id, field: "tag.create", value: trimmed, origin: .localEdit)
        }
        return id
    }

    /// Positive provenance exists only for collections created after this feature was installed.
    /// It is permanently retired at the first shared identity boundary.
    public func privateCollectionNameRevisions() throws -> [UUID: Int64] {
        var result: [UUID: Int64] = [:]
        for row in try rows("SELECT collection_id,revision FROM private_collection_names") {
            if let id = UUID(uuidString: row[0] ?? ""), let revision = Int64(row[1] ?? "") { result[id] = revision }
        }
        return result
    }

    public func renamePrivateCollection(collectionID: UUID, expectedName: String,
                                        expectedRevision: Int64, newName: String) throws {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 160, name.utf8.count <= 640 else { throw LocalLibraryError.invalidName }
        try transaction {
            guard expectedRevision >= 0, expectedRevision < Int64.max,
                  try scalar("SELECT name FROM collections WHERE id=?", [collectionID.uuidString]) == expectedName,
                  try scalar("SELECT revision FROM private_collection_names WHERE collection_id=?", [collectionID.uuidString]) == String(expectedRevision),
                  try pendingCollectionRename()?.localCollectionID != collectionID,
                  !(try collections()).contains(where: { $0.id != collectionID && Self.syncTagNameKey($0.name) == Self.syncTagNameKey(name) }) else {
                throw LocalLibraryError.syncRemoteCollectionMismatch
            }
            guard name != expectedName else { return }
            try execute("UPDATE collections SET name=? WHERE id=?", [name, collectionID.uuidString])
            try execute("UPDATE private_collection_names SET revision=revision+1 WHERE collection_id=?", [collectionID.uuidString])
            try execute("DELETE FROM collection_undo WHERE collection_id=?", [collectionID.uuidString])
            let operation = try enqueue(collectionID, field: "collection.rename", value: name, origin: .localEdit)
            try execute("""
                INSERT INTO private_collection_rename_events(operation_id,collection_id,old_name,new_name,previous_revision)
                VALUES(?,?,?,?,?)
                """, [operation.uuidString, collectionID.uuidString, expectedName, name, String(expectedRevision)])
        }
    }

    public func pendingCollectionRename() throws -> LocalCollectionRenameCommand? {
        guard let payload = try scalar("SELECT payload FROM collection_rename_commands WHERE state='pending'") else { return nil }
        return try JSONDecoder().decode(LocalCollectionRenameCommand.self, from: Data(payload.utf8))
    }

    public func prepareCollectionRename(collectionID: UUID, newName: String,
                                        visibleIdentifiers: Set<String>) throws -> LocalCollectionRenameCommand {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 160, name.utf8.count <= 640 else { throw LocalLibraryError.invalidName }
        if let pending = try pendingCollectionRename() {
            guard pending.localCollectionID == collectionID, pending.newName == name else {
                throw LocalLibraryError.migrationSyncPending
            }
            try validateCollectionRename(pending, visibleIdentifiers: visibleIdentifiers)
            return pending
        }
        var result: LocalCollectionRenameCommand?
        try transaction {
            let snapshot = try sharedSnapshot(visibleIdentifiers: visibleIdentifiers)
            guard let localName = try scalar("SELECT name FROM collections WHERE id=?", [collectionID.uuidString]),
                  localName != name,
                  !(try collections()).contains(where: { $0.id != collectionID && Self.syncTagNameKey($0.name) == Self.syncTagNameKey(name) }) else {
                throw LocalLibraryError.invalidName
            }
            let wire = try wireCollectionIdentity(for: collectionID, localName: localName)
            guard let host = UUID(uuidString: try requiredIdentity("sync_host_id")),
                  let device = UUID(uuidString: try requiredIdentity("sync_device_id")),
                  Int64(try requiredIdentity("sync_ack_scope_revision")) == snapshot.scopeRevision,
                  let sequence = Int64(try requiredIdentity("sync_ack_snapshot_sequence")), sequence > 0,
                  try pendingSharedSnapshot() == nil, try pendingSharedOperations().isEmpty else {
                throw LocalLibraryError.syncScopeNotAcknowledged
            }
            let command = LocalCollectionRenameCommand(commandID: UUID(), hostID: host, deviceID: device,
                installID: snapshot.installID, sourceEpoch: snapshot.sourceEpoch, scopeRevision: snapshot.scopeRevision,
                snapshotSequence: sequence, expectedChangeCursor: try sharedCollectionChangeCursor(),
                localCollectionID: collectionID, collectionID: wire.id, expectedName: wire.name, newName: name)
            try validateCollectionRename(command, visibleIdentifiers: visibleIdentifiers)
            let payload = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
            try execute("INSERT INTO collection_rename_commands(command_id,payload,state) VALUES(?,?,'pending')",
                        [command.commandID.uuidString, payload])
            result = command
        }
        return result!
    }

    public func validateCollectionRename(_ command: LocalCollectionRenameCommand,
                                         visibleIdentifiers: Set<String>) throws {
        let snapshot = try sharedSnapshot(visibleIdentifiers: visibleIdentifiers)
        guard command.hostID.uuidString == (try requiredIdentity("sync_host_id")),
              command.deviceID.uuidString == (try requiredIdentity("sync_device_id")),
              command.installID == snapshot.installID, command.sourceEpoch == snapshot.sourceEpoch,
              command.scopeRevision == snapshot.scopeRevision,
              snapshot.assets.contains(where: { asset in
                  asset.collections.contains { $0.collectionID == command.localCollectionID }
              }),
              let localName = try scalar("SELECT name FROM collections WHERE id=?", [command.localCollectionID.uuidString]),
              try wireCollectionIdentity(for: command.localCollectionID, localName: localName).id == command.collectionID
        else { throw LocalLibraryError.syncIdentityChanged }
    }

    public func completeCollectionRename(_ command: LocalCollectionRenameCommand, resultingCursor: Int64) throws {
        try transaction {
            guard try pendingCollectionRename() == command,
                  command.hostID.uuidString == (try requiredIdentity("sync_host_id")),
                  command.deviceID.uuidString == (try requiredIdentity("sync_device_id")),
                  command.sourceEpoch == (try sourceEpoch()),
                  command.scopeRevision == Int64(try requiredIdentity("share_scope_revision")),
                  resultingCursor > command.expectedChangeCursor,
                  try sharedCollectionChangeCursor() >= resultingCursor else {
                throw LocalLibraryError.syncIdentityChanged
            }
            try execute("UPDATE collection_rename_commands SET state='completed',resulting_cursor=? WHERE command_id=?",
                        [String(resultingCursor), command.commandID.uuidString])
        }
    }

    /// Stops local retry only; an already delivered Mac command is not undone.
    public func abandonCollectionRename(commandID: UUID) throws {
        try execute("UPDATE collection_rename_commands SET state='abandoned' WHERE command_id=? AND state='pending'",
                    [commandID.uuidString])
    }

    @discardableResult public func createCollection(name: String) throws -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalLibraryError.invalidName }
        let id = UUID()
        try transaction {
            try execute("INSERT INTO collections(id,name) VALUES(?,?)", [id.uuidString, trimmed])
            try execute("INSERT INTO private_collection_names(collection_id,revision) VALUES(?,0)", [id.uuidString])
            try enqueue(id, field: "collection.create", value: trimmed, origin: .localEdit)
        }
        return id
    }

    @discardableResult
    public func setDecision(assetID: UUID, tagID: UUID, decision: LocalDecision) throws -> UUID {
        guard try exists("assets", id: assetID) else { throw LocalLibraryError.unknownAsset }
        guard try exists("tags", id: tagID) else { throw LocalLibraryError.unknownTag }
        var operationID = UUID()
        try transaction {
            let previous = try scalar("SELECT decision FROM tag_decisions WHERE asset_id=? AND tag_id=?",
                                      [assetID.uuidString, tagID.uuidString]) ?? LocalDecision.cleared.rawValue
            operationID = try writeTagDecision(assetID: assetID, tagID: tagID, decision: decision)
            let context = try tagUndoContext(assetID: assetID, tagID: tagID)
            try execute("""
                INSERT INTO tag_undo(operation_id,asset_id,tag_id,previous_decision,context) VALUES(?,?,?,?,?)
                ON CONFLICT(asset_id,tag_id) DO UPDATE SET operation_id=excluded.operation_id,
                  previous_decision=excluded.previous_decision,context=excluded.context
                """, [operationID.uuidString, assetID.uuidString, tagID.uuidString, previous, context])
        }
        return operationID
    }

    // Must be called inside the caller's transaction, including undo validation.
    private func writeTagDecision(assetID: UUID, tagID: UUID, decision: LocalDecision) throws -> UUID {
        let field = "tag.\(tagID.uuidString)"
        try execute("""
            INSERT INTO tag_decisions(asset_id,tag_id,decision,revision) VALUES(?,?,?,1)
            ON CONFLICT(asset_id,tag_id) DO UPDATE SET decision=excluded.decision, revision=revision+1
            """, [assetID.uuidString, tagID.uuidString, decision.rawValue])
        let operationID = try enqueue(assetID, field: field, value: decision.rawValue, origin: .localEdit)
        if try isShared(assetID: assetID) {
            let name = try scalar("SELECT name FROM tags WHERE id=?", [tagID.uuidString])
            try enqueueShared(operationID, assetID: assetID, field: field,
                              value: decision.rawValue, referenceName: name)
        }
        return operationID
    }

    private func tagUndoContext(assetID: UUID, tagID: UUID) throws -> String {
        let name = try scalar("SELECT name FROM tags WHERE id=?", [tagID.uuidString]) ?? ""
        let wire = try wireTagIdentity(for: tagID, localName: name)
        let field = "tag.\(tagID.uuidString)"
        let context = try [
            requiredIdentity("source_epoch"), requiredIdentity("share_scope_revision"),
            requiredIdentity("sync_host_id"), requiredIdentity("sync_device_id"),
            isShared(assetID: assetID) ? "shared" : "private",
            scalar("SELECT revision FROM shared_field_versions WHERE asset_id=? AND field=?",
                   [assetID.uuidString, field]) ?? "0",
            wire.id.uuidString, wire.name, name
        ]
        return String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
    }

    private func validatedTagUndo(operationID: UUID) throws -> (asset: UUID, tag: UUID, previous: LocalDecision) {
        guard let row = try rows("SELECT asset_id,tag_id,previous_decision,context FROM tag_undo WHERE operation_id=?",
                                 [operationID.uuidString]).first,
              let asset = UUID(uuidString: row[0] ?? ""), let tag = UUID(uuidString: row[1] ?? ""),
              let previous = LocalDecision(rawValue: row[2] ?? ""),
              row[3] == (try tagUndoContext(assetID: asset, tagID: tag)) else {
            throw LocalLibraryError.undoUnavailable
        }
        let field = "tag.\(tag.uuidString)"
        guard try scalar("SELECT operation_id FROM outbox WHERE entity_id=? AND field=? ORDER BY sequence DESC LIMIT 1",
                         [asset.uuidString, field]) == operationID.uuidString,
              try scalar("""
                  SELECT d.operation_id FROM shared_delivery d JOIN shared_outbox s ON s.operation_id=d.operation_id
                  WHERE s.asset_id=? AND s.field=? LIMIT 1
                  """, [asset.uuidString, field]) == nil else { throw LocalLibraryError.undoUnavailable }
        return (asset, tag, previous)
    }

    public func tagUndoCandidates(assetID: UUID) throws -> [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        for row in try rows("SELECT operation_id FROM tag_undo WHERE asset_id=?", [assetID.uuidString]) {
            if let id = UUID(uuidString: row[0] ?? ""), let token = try? validatedTagUndo(operationID: id) {
                result[token.tag] = id
            }
        }
        return result
    }

    /// A compensating fact with a new operation ID; never rewrites or removes history.
    /// Version/identity changes and outstanding delivery make old undo unavailable.
    @discardableResult
    public func undoTagDecision(operationID: UUID) throws -> UUID {
        var compensation = UUID()
        try transaction {
            let token = try validatedTagUndo(operationID: operationID)
            compensation = try writeTagDecision(assetID: token.asset, tagID: token.tag, decision: token.previous)
            try execute("DELETE FROM tag_undo WHERE operation_id=?", [operationID.uuidString])
        }
        return compensation
    }

    public func decisions(assetID: UUID) throws -> [UUID: LocalDecision] {
        var result: [UUID: LocalDecision] = [:]
        for row in try rows("SELECT tag_id,decision FROM tag_decisions WHERE asset_id=?", [assetID.uuidString]) {
            if let id = UUID(uuidString: row[0] ?? ""),
               let decision = LocalDecision(rawValue: row[1] ?? "") { result[id] = decision }
        }
        return result
    }

    @discardableResult
    public func setMembership(assetID: UUID, collectionID: UUID, included: Bool) throws -> UUID {
        guard try exists("assets", id: assetID) else { throw LocalLibraryError.unknownAsset }
        guard try exists("collections", id: collectionID) else { throw LocalLibraryError.unknownCollection }
        var operationID = UUID()
        try transaction {
            let previous = try scalar("SELECT included FROM memberships WHERE asset_id=? AND collection_id=?",
                                      [assetID.uuidString, collectionID.uuidString]) ?? "0"
            operationID = try writeMembership(assetID: assetID, collectionID: collectionID, included: included)
            let context = try collectionUndoContext(assetID: assetID, collectionID: collectionID)
            try execute("""
                INSERT INTO collection_undo(operation_id,asset_id,collection_id,previous_included,context)
                VALUES(?,?,?,?,?) ON CONFLICT(asset_id,collection_id) DO UPDATE SET
                  operation_id=excluded.operation_id,previous_included=excluded.previous_included,context=excluded.context
                """, [operationID.uuidString, assetID.uuidString, collectionID.uuidString, previous, context])
        }
        return operationID
    }

    // Caller supplies the transaction so fact, audit and shared queue commit atomically.
    private func writeMembership(assetID: UUID, collectionID: UUID, included: Bool) throws -> UUID {
        try execute("""
            INSERT INTO memberships(collection_id,asset_id,included,revision) VALUES(?,?,?,1)
            ON CONFLICT(collection_id,asset_id) DO UPDATE SET
              included=excluded.included, revision=revision+1
            """, [collectionID.uuidString, assetID.uuidString, included ? "1" : "0"])
        let field = "collection.\(collectionID.uuidString)"
        let value = included ? "1" : "0"
        let operationID = try enqueue(assetID, field: field, value: value, origin: .localEdit)
        if try isShared(assetID: assetID) {
            try execute("DELETE FROM private_collection_names WHERE collection_id=?", [collectionID.uuidString])
            let name = try scalar("SELECT name FROM collections WHERE id=?", [collectionID.uuidString])
            try enqueueShared(operationID, assetID: assetID, field: field, value: value, referenceName: name)
        }
        return operationID
    }

    private func collectionUndoContext(assetID: UUID, collectionID: UUID) throws -> String {
        let name = try scalar("SELECT name FROM collections WHERE id=?", [collectionID.uuidString]) ?? ""
        let wire = try wireCollectionIdentity(for: collectionID, localName: name)
        let field = "collection.\(collectionID.uuidString)"
        let context = try [
            requiredIdentity("source_epoch"), requiredIdentity("share_scope_revision"),
            requiredIdentity("sync_host_id"), requiredIdentity("sync_device_id"),
            isShared(assetID: assetID) ? "shared" : "private",
            scalar("SELECT revision FROM shared_field_versions WHERE asset_id=? AND field=?",
                   [assetID.uuidString, field]) ?? "0",
            wire.id.uuidString, wire.name, name
        ]
        return String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
    }

    private func validatedCollectionUndo(operationID: UUID) throws -> (asset: UUID, collection: UUID, previous: Bool) {
        guard let row = try rows("""
            SELECT asset_id,collection_id,previous_included,context FROM collection_undo WHERE operation_id=?
            """, [operationID.uuidString]).first,
              let asset = UUID(uuidString: row[0] ?? ""), let collection = UUID(uuidString: row[1] ?? ""),
              let previous = row[2], ["0", "1"].contains(previous),
              row[3] == (try collectionUndoContext(assetID: asset, collectionID: collection)) else {
            throw LocalLibraryError.undoUnavailable
        }
        let field = "collection.\(collection.uuidString)"
        guard try scalar("SELECT operation_id FROM outbox WHERE entity_id=? AND field=? ORDER BY sequence DESC LIMIT 1",
                         [asset.uuidString, field]) == operationID.uuidString,
              try scalar("""
                  SELECT d.operation_id FROM shared_delivery d JOIN shared_outbox s ON s.operation_id=d.operation_id
                  WHERE s.asset_id=? AND s.field=? LIMIT 1
                  """, [asset.uuidString, field]) == nil else { throw LocalLibraryError.undoUnavailable }
        return (asset, collection, previous == "1")
    }

    public func collectionUndoCandidates(assetID: UUID) throws -> [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        for row in try rows("SELECT operation_id FROM collection_undo WHERE asset_id=?", [assetID.uuidString]) {
            if let id = UUID(uuidString: row[0] ?? ""), let token = try? validatedCollectionUndo(operationID: id) {
                result[token.collection] = id
            }
        }
        return result
    }

    /// Appends one compensation without rewriting the original membership history.
    @discardableResult
    public func undoMembership(operationID: UUID) throws -> UUID {
        var compensation = UUID()
        try transaction {
            let token = try validatedCollectionUndo(operationID: operationID)
            compensation = try writeMembership(assetID: token.asset, collectionID: token.collection, included: token.previous)
            try execute("INSERT INTO collection_undo_receipts(original_operation_id,compensation_operation_id) VALUES(?,?)",
                        [operationID.uuidString, compensation.uuidString])
            try execute("DELETE FROM collection_undo WHERE operation_id=?", [operationID.uuidString])
        }
        return compensation
    }

    public func memberships(assetID: UUID) throws -> Set<UUID> {
        Set(try rows("SELECT collection_id FROM memberships WHERE asset_id=? AND included=1", [assetID.uuidString])
            .compactMap { UUID(uuidString: $0[0] ?? "") })
    }

    /// Records ImageAll's desired favorite separately from PhotoKit's last observed state.
    /// Pending intent survives a crash between source mutation and readback.
    public func setFavoriteTarget(assetID: UUID, isFavorite: Bool) throws {
        guard try exists("assets", id: assetID) else { throw LocalLibraryError.unknownAsset }
        try transaction {
            try execute("UPDATE assets SET favorite_target=? WHERE id=?", [isFavorite ? "1" : "0", assetID.uuidString])
            try execute("""
                INSERT INTO favorite_writebacks(asset_id,target,state) VALUES(?,?,'pending')
                ON CONFLICT(asset_id) DO UPDATE SET target=excluded.target,state='pending'
                """, [assetID.uuidString, isFavorite ? "1" : "0"])
            let value = isFavorite ? "1" : "0"
            let operationID = try enqueue(assetID, field: "favorite.target", value: value, origin: .localEdit)
            if try isShared(assetID: assetID) {
                try enqueueShared(
                    operationID, assetID: assetID, field: "favorite.target",
                    value: value, referenceName: nil
                )
            }
        }
    }

    public func prepareFavoriteWriteback(
        assetID: UUID, expectedTarget: Bool
    ) throws -> LocalFavoriteWritebackIntent {
        let epoch = try sourceEpoch()
        guard let row = try rows("""
            SELECT a.local_identifier,a.favorite_target,o.operation_id
            FROM assets a JOIN outbox o ON o.entity_id=a.id AND o.field='favorite.target'
            WHERE a.id=? AND a.source_epoch=? ORDER BY o.sequence DESC LIMIT 1
            """, [assetID.uuidString, epoch.uuidString]).first,
              let locator = row[0], row[1] == (expectedTarget ? "1" : "0"),
              let operationID = row[2].flatMap(UUID.init(uuidString:)) else {
            throw LocalLibraryError.syncIdentityChanged
        }
        return LocalFavoriteWritebackIntent(
            assetID: assetID, sourceEpoch: epoch, localIdentifier: locator,
            operationID: operationID, target: expectedTarget
        )
    }

    public func isCurrentFavoriteWriteback(_ intent: LocalFavoriteWritebackIntent) throws -> Bool {
        guard intent.sourceEpoch == (try sourceEpoch()),
              let row = try rows("""
                SELECT local_identifier,favorite_target FROM assets WHERE id=? AND source_epoch=?
                """, [intent.assetID.uuidString, intent.sourceEpoch.uuidString]).first,
              row[0] == intent.localIdentifier, row[1] == (intent.target ? "1" : "0") else { return false }
        return try scalar("""
            SELECT operation_id FROM outbox WHERE entity_id=? AND field='favorite.target'
            ORDER BY sequence DESC LIMIT 1
            """, [intent.assetID.uuidString]) == intent.operationID.uuidString
    }

    /// The exact durable operation must still be current, including A→B→A changes.
    @discardableResult
    public func finishFavoriteWriteback(
        _ intent: LocalFavoriteWritebackIntent, observedValue: Bool?
    ) throws -> Bool {
        let value = intent.target ? "1" : "0"
        var accepted = false
        try transaction {
            guard try isCurrentFavoriteWriteback(intent) else { return }
            if let observedValue {
                try execute("UPDATE assets SET observed_favorite=? WHERE id=?", [
                    observedValue ? "1" : "0", intent.assetID.uuidString
                ])
            }
            try execute("UPDATE favorite_writebacks SET state=? WHERE asset_id=? AND target=?", [
                observedValue == intent.target ? "matched" : "failed", intent.assetID.uuidString, value
            ])
            accepted = true
        }
        return accepted
    }

    public func pendingOperations() throws -> [LocalPendingOperation] {
        try rows("SELECT sequence,operation_id,entity_id,field,value FROM outbox ORDER BY sequence")
            .compactMap { row in
                guard let sequence = Int64(row[0] ?? ""),
                      let id = UUID(uuidString: row[1] ?? ""),
                      let entityID = UUID(uuidString: row[2] ?? "") else { return nil }
                return LocalPendingOperation(
                    id: id, sequence: sequence, entityID: entityID,
                    field: row[3] ?? "", value: row[4] ?? ""
                )
            }
    }

    public func pendingSharedOperations() throws -> [LocalSharedPendingOperation] {
        try rows("""
            SELECT o.sequence,s.operation_id,s.asset_id,s.field,s.value,s.reference_name,
                   s.scope_revision,d.base_revision,d.state,d.conflict_revision,
                   d.conflict_value,c.reason,t.decision,m.included,f.favorite_target
            FROM shared_outbox s JOIN outbox o ON o.operation_id=s.operation_id
            JOIN shared_assets a ON a.asset_id=s.asset_id
            LEFT JOIN shared_delivery d ON d.operation_id=s.operation_id
            LEFT JOIN shared_conflict_details c ON c.operation_id=s.operation_id
            LEFT JOIN tag_decisions t ON t.asset_id=s.asset_id AND s.field='tag.' || t.tag_id
            LEFT JOIN memberships m ON m.asset_id=s.asset_id AND s.field='collection.' || m.collection_id
            LEFT JOIN assets f ON f.id=s.asset_id AND s.field='favorite.target'
            ORDER BY o.sequence
            """).map { row in
                guard let sequence = Int64(row[0] ?? ""),
                      let id = UUID(uuidString: row[1] ?? ""),
                      let assetID = UUID(uuidString: row[2] ?? ""),
                      let scopeRevision = Int64(row[6] ?? "") else {
                    throw LocalLibraryError.database("invalid shared outbox row")
                }
                return LocalSharedPendingOperation(
                    id: id, sequence: sequence, assetID: assetID,
                    field: row[3] ?? "", value: row[4] ?? "",
                    referenceName: row[5].flatMap { $0.isEmpty ? nil : $0 },
                    scopeRevision: scopeRevision,
                    preparedBaseRevision: row[7].flatMap(Int64.init),
                    isConflicted: row[8] == "conflict",
                    conflictRevision: row[9].flatMap(Int64.init),
                    conflictValue: row[10],
                    conflictDecision: row[10].flatMap(LocalDecision.init(rawValue:)),
                    conflictReason: row[11].flatMap(LocalSharedConflictReason.init(rawValue:)),
                    verifiedCollectionRename: try verifiedCollectionRename(operationID: id),
                    localCurrentDecision: row[12].flatMap(LocalDecision.init(rawValue:)),
                    localCurrentIncluded: row[13].map { $0 == "1" },
                    localCurrentFavoriteTarget: row[14].map { $0 == "1" }
                )
            }
    }

    private func verifiedCollectionRename(operationID: UUID) throws -> String? {
        guard let row = try rows("""
            SELECT f.local_collection_id,f.wire_collection_id,p.current_name,p.source_epoch,
                   d.host_id,d.device_id,d.scope_revision,p.change_sequence,d.state,c.reason
            FROM shared_collection_rename_recovery p
            JOIN shared_collection_delivery_identity f ON f.operation_id=p.operation_id
            JOIN shared_delivery d ON d.operation_id=p.operation_id
            JOIN shared_conflict_details c ON c.operation_id=p.operation_id
            WHERE p.operation_id=?
            """, [operationID.uuidString]).first,
              row[8] == "conflict", row[9] == "collectionIdentity",
              row[3] == (try requiredIdentity("source_epoch")),
              row[4] == (try requiredIdentity("sync_host_id")),
              row[5] == (try requiredIdentity("sync_device_id")),
              row[6] == (try requiredIdentity("share_scope_revision")),
              row[6] == (try requiredIdentity("sync_ack_scope_revision")),
              let sequence = Int64(row[7] ?? ""),
              sequence <= (try sharedCollectionChangeCursor()),
              let localID = UUID(uuidString: row[0] ?? ""),
              let currentName = row[2],
              try scalar("SELECT name FROM collections WHERE id=?", [localID.uuidString]) == currentName,
              let wire = try? wireCollectionIdentity(for: localID, localName: currentName),
              wire.id.uuidString == row[1], wire.name == currentName else { return nil }
        return currentName
    }

    private struct CollectionHistoryContext: Equatable {
        let hostID: UUID
        let deviceID: UUID
        let sourceEpoch: UUID
        let scopeRevision: Int64
        let cursor: Int64
        let localID: UUID
        let wireID: UUID
        let currentName: String
        let referenceName: String
        let frozenName: String?
    }

    private func collectionHistoryContext(operationID: UUID) throws -> CollectionHistoryContext {
        guard let pending = try pendingSharedOperations().first(where: { $0.id == operationID }),
              pending.isConflicted, pending.conflictReason == .collectionIdentity,
              pending.field.hasPrefix("collection."),
              let localID = UUID(uuidString: String(pending.field.dropFirst(11))),
              let referenceName = pending.referenceName,
              let currentName = try scalar("SELECT name FROM collections WHERE id=?", [localID.uuidString]),
              let hostID = UUID(uuidString: try requiredIdentity("sync_host_id")),
              let deviceID = UUID(uuidString: try requiredIdentity("sync_device_id")),
              pending.scopeRevision == Int64(try requiredIdentity("share_scope_revision")),
              pending.scopeRevision == Int64(try requiredIdentity("sync_ack_scope_revision")),
              let delivery = try rows("SELECT host_id,device_id FROM shared_delivery WHERE operation_id=?",
                                      [operationID.uuidString]).first,
              delivery[0] == hostID.uuidString, delivery[1] == deviceID.uuidString else {
            throw LocalLibraryError.syncConflictDetailsUnavailable
        }
        let wire = try wireCollectionIdentity(for: localID, localName: currentName)
        guard wire.name == currentName else { throw LocalLibraryError.syncRemoteCollectionMismatch }
        let frozen = try rows("""
            SELECT local_collection_id,wire_collection_id,wire_name
            FROM shared_collection_delivery_identity WHERE operation_id=?
            """, [operationID.uuidString]).first
        if let frozen {
            guard frozen[0] == localID.uuidString, frozen[1] == wire.id.uuidString else {
                throw LocalLibraryError.syncRemoteCollectionMismatch
            }
        }
        return CollectionHistoryContext(
            hostID: hostID, deviceID: deviceID, sourceEpoch: try sourceEpoch(),
            scopeRevision: pending.scopeRevision, cursor: try sharedCollectionChangeCursor(),
            localID: localID, wireID: wire.id, currentName: currentName,
            referenceName: referenceName, frozenName: frozen?[2]
        )
    }

    /// Reads history only through the already applied cursor. It reconstructs
    /// identity evidence, without replaying facts or advancing sync cursors.
    public func recoverSharedCollectionRenameHistory(
        operationID: UUID,
        fetchPage: @Sendable (UUID, Int64, Int64) async throws -> LocalSharedCollectionHistoryPage
    ) async throws -> String {
        let context = try collectionHistoryContext(operationID: operationID)
        guard context.cursor > 0 else { throw LocalLibraryError.syncConflictDetailsUnavailable }
        var cursor: Int64 = 0
        var name: String?
        var lastTransition: (old: String, new: String)?
        var originalWireName: String?
        var verifiedSequence: Int64?
        while cursor < context.cursor {
            try Task.checkCancellation()
            let page = try await fetchPage(context.sourceEpoch, context.scopeRevision, cursor)
            guard page.hostID == context.hostID, page.deviceID == context.deviceID,
                  page.sourceEpoch == context.sourceEpoch, page.scopeRevision == context.scopeRevision,
                  page.nextCursor > cursor,
                  page.changes.allSatisfy({ $0.sequence > cursor && $0.sequence <= page.nextCursor }),
                  zip(page.changes, page.changes.dropFirst()).allSatisfy({ $0.0.sequence < $0.1.sequence }) else {
                throw LocalLibraryError.syncIdentityChanged
            }
            for change in page.changes where change.sequence <= context.cursor
                && change.collectionID == context.wireID {
                if change.createdCollectionID != nil {
                    guard change.createdCollectionID == context.wireID, name == nil,
                          change.renamedFrom == nil, change.included, change.fieldRevision == 1 else {
                        throw LocalLibraryError.syncRemoteCollectionMismatch
                    }
                    name = change.collectionName
                } else if let oldName = change.renamedFrom {
                    guard let current = name, !change.collectionName.isEmpty,
                          oldName != change.collectionName else {
                        throw LocalLibraryError.syncRemoteCollectionMismatch
                    }
                    if current == oldName {
                        if originalWireName == nil,
                           context.frozenName.map({ $0 == oldName })
                            ?? (Self.syncTagNameKey(context.referenceName) == Self.syncTagNameKey(oldName)) {
                            originalWireName = oldName
                        }
                        name = change.collectionName
                        lastTransition = (oldName, change.collectionName)
                        if originalWireName != nil { verifiedSequence = change.sequence }
                    } else {
                        // A collection rename is repeated for its other members.
                        guard current == change.collectionName,
                              lastTransition?.old == oldName,
                              lastTransition?.new == change.collectionName else {
                            throw LocalLibraryError.syncRemoteCollectionMismatch
                        }
                    }
                } else if name != change.collectionName {
                    throw LocalLibraryError.syncRemoteCollectionMismatch
                }
            }
            cursor = page.nextCursor
        }
        guard name == context.currentName, let originalWireName, let verifiedSequence else {
            throw LocalLibraryError.syncConflictDetailsUnavailable
        }
        try Task.checkCancellation()
        guard try collectionHistoryContext(operationID: operationID) == context else {
            throw LocalLibraryError.syncIdentityChanged
        }
        try transaction {
            if context.frozenName == nil {
                try execute("""
                    INSERT INTO shared_collection_delivery_identity(
                      operation_id,local_collection_id,wire_collection_id,wire_name
                    ) VALUES(?,?,?,?)
                    """, [operationID.uuidString, context.localID.uuidString,
                           context.wireID.uuidString, originalWireName])
            }
            try execute("""
                INSERT INTO shared_collection_rename_recovery(operation_id,source_epoch,current_name,change_sequence)
                VALUES(?,?,?,?) ON CONFLICT(operation_id) DO UPDATE SET
                  source_epoch=excluded.source_epoch,current_name=excluded.current_name,
                  change_sequence=excluded.change_sequence
                """, [operationID.uuidString, context.sourceEpoch.uuidString,
                       context.currentName, String(verifiedSequence)])
        }
        return context.currentName
    }

    /// Commits the authenticated Mac snapshot ACK and its first-import field baseline.
    /// Only facts captured in the accepted snapshot may absorb older local operations.
    public func acknowledgeSharedSnapshot(
        _ snapshot: LocalSharedSnapshot,
        hostID: UUID, deviceID: UUID, importedAssetIDs: [UUID]
    ) throws {
        guard snapshot.installID == (try installID()),
              snapshot.sourceEpoch == (try sourceEpoch()),
              Set(importedAssetIDs).count == importedAssetIDs.count,
              Set(importedAssetIDs).isSubset(of: Set(snapshot.assets.map(\.id))) else {
            throw LocalLibraryError.syncIdentityChanged
        }
        let byID = Dictionary(uniqueKeysWithValues: snapshot.assets.map { ($0.id, $0) })
        try transaction {
            try bindSyncIdentity(hostID: hostID, deviceID: deviceID)
            for assetID in importedAssetIDs {
                guard try isShared(assetID: assetID), let asset = byID[assetID] else { continue }
                for tag in asset.tagDecisions {
                    let localTagID = try localTagIdentity(
                        for: tag.tagID, remoteName: tag.tagName,
                        hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch
                    )
                    try execute("""
                        INSERT OR IGNORE INTO shared_field_versions(asset_id,field,revision)
                        VALUES(?,?,1)
                        """, [assetID.uuidString, "tag.\(localTagID.uuidString)"])
                }
                for collection in asset.collections {
                    let localCollectionID = try localCollectionIdentity(
                        for: collection.collectionID, remoteName: collection.collectionName,
                        hostID: hostID, deviceID: deviceID, sourceEpoch: snapshot.sourceEpoch
                    )
                    try execute("""
                        INSERT OR IGNORE INTO shared_field_versions(asset_id,field,revision)
                        VALUES(?,?,1)
                        """, [assetID.uuidString, "collection.\(localCollectionID.uuidString)"])
                }
                if asset.favoriteTarget != nil {
                    try execute("""
                        INSERT OR IGNORE INTO shared_field_versions(asset_id,field,revision)
                        VALUES(?,'favorite.target',1)
                        """, [assetID.uuidString])
                }
                try execute("""
                    DELETE FROM shared_outbox WHERE asset_id=?
                      AND operation_id IN (
                        SELECT o.operation_id FROM outbox o WHERE o.sequence<=?
                      )
                      AND operation_id NOT IN (SELECT operation_id FROM shared_delivery)
                    """, [assetID.uuidString, String(snapshot.outboxWatermark)])
            }
            if snapshot.scopeRevision == (Int64(try requiredIdentity("share_scope_revision")) ?? -1),
               snapshot.snapshotSequence >= (Int64(try requiredIdentity("sync_ack_snapshot_sequence")) ?? 0) {
                try execute("UPDATE identity SET value=? WHERE key='sync_ack_scope_revision'", [
                    String(snapshot.scopeRevision)
                ])
                try execute("UPDATE identity SET value=? WHERE key='sync_ack_snapshot_sequence'", [
                    String(snapshot.snapshotSequence)
                ])
            }
            if let encoded = try scalar("SELECT payload FROM shared_snapshot_delivery WHERE id=1"),
               let payload = encoded.data(using: .utf8),
               let prepared = try? JSONDecoder().decode(LocalSharedSnapshot.self, from: payload),
               prepared.snapshotSequence == snapshot.snapshotSequence,
               prepared.scopeRevision == snapshot.scopeRevision {
                try execute("DELETE FROM shared_snapshot_delivery")
            }
        }
    }

    /// Freezes the base revision once. A lost ACK must resend this exact operation payload.
    public func prepareSharedTagOperation(
        id: UUID, hostID: UUID, deviceID: UUID
    ) throws -> LocalPreparedSharedTagOperation? {
        guard let pending = try pendingSharedOperations().first(where: { $0.id == id }) else {
            return nil
        }
        guard pending.field.hasPrefix("tag."),
              let tagID = UUID(uuidString: String(pending.field.dropFirst(4))),
              let tagName = pending.referenceName, !tagName.isEmpty,
              let decision = LocalDecision(rawValue: pending.value) else {
            throw LocalLibraryError.unsupportedSharedOperation
        }
        guard !pending.isConflicted else { throw LocalLibraryError.syncConflictRequiresResolution }
        guard try requiredIdentity("sync_host_id") == hostID.uuidString,
              try requiredIdentity("sync_device_id") == deviceID.uuidString else {
            throw LocalLibraryError.syncIdentityChanged
        }
        guard pending.scopeRevision == (Int64(try requiredIdentity("share_scope_revision")) ?? -1),
              pending.scopeRevision == (Int64(try requiredIdentity("sync_ack_scope_revision")) ?? -1) else {
            throw LocalLibraryError.syncScopeNotAcknowledged
        }
        let wireTag = try wireTagIdentity(for: tagID, localName: tagName)
        let earlier = try scalar("""
            SELECT MIN(o.sequence) FROM shared_outbox s
            JOIN outbox o ON o.operation_id=s.operation_id
            WHERE s.asset_id=? AND s.field=?
            """, [pending.assetID.uuidString, pending.field]).flatMap(Int64.init)
        guard earlier == pending.sequence else {
            throw LocalLibraryError.syncEarlierOperationPending
        }
        let baseRevision: Int64
        if let prepared = pending.preparedBaseRevision {
            let binding = try rows("""
                SELECT host_id,device_id,scope_revision FROM shared_delivery WHERE operation_id=?
                """, [id.uuidString]).first
            guard binding?[0] == hostID.uuidString,
                  binding?[1] == deviceID.uuidString,
                  Int64(binding?[2] ?? "") == pending.scopeRevision else {
                throw LocalLibraryError.syncIdentityChanged
            }
            baseRevision = prepared
        } else {
            baseRevision = Int64(try scalar("""
                SELECT revision FROM shared_field_versions WHERE asset_id=? AND field=?
                """, [pending.assetID.uuidString, pending.field]) ?? "0") ?? 0
            try transaction {
                try execute("""
                    INSERT INTO shared_delivery(
                      operation_id,host_id,device_id,base_revision,scope_revision,state
                    ) VALUES(?,?,?,?,?,'prepared')
                    """, [
                        id.uuidString, hostID.uuidString, deviceID.uuidString,
                        String(baseRevision), String(pending.scopeRevision)
                    ])
            }
        }
        return LocalPreparedSharedTagOperation(
            hostID: hostID, deviceID: deviceID,
            operation: pending, tagID: wireTag.id, tagName: wireTag.name,
            decision: decision, baseRevision: baseRevision,
            installID: try installID(), sourceEpoch: try sourceEpoch()
        )
    }

    /// Freezes the membership base revision and wire identity for lossless ACK retry.
    public func prepareSharedCollectionOperation(
        id: UUID, hostID: UUID, deviceID: UUID
    ) throws -> LocalPreparedSharedCollectionOperation? {
        guard let pending = try pendingSharedOperations().first(where: { $0.id == id }) else {
            return nil
        }
        guard pending.field.hasPrefix("collection."),
              let collectionID = UUID(uuidString: String(pending.field.dropFirst(11))),
              let collectionName = pending.referenceName, !collectionName.isEmpty,
              pending.value == "0" || pending.value == "1" else {
            throw LocalLibraryError.unsupportedSharedOperation
        }
        guard !pending.isConflicted else { throw LocalLibraryError.syncConflictRequiresResolution }
        guard try requiredIdentity("sync_host_id") == hostID.uuidString,
              try requiredIdentity("sync_device_id") == deviceID.uuidString else {
            throw LocalLibraryError.syncIdentityChanged
        }
        guard pending.scopeRevision == (Int64(try requiredIdentity("share_scope_revision")) ?? -1),
              pending.scopeRevision == (Int64(try requiredIdentity("sync_ack_scope_revision")) ?? -1) else {
            throw LocalLibraryError.syncScopeNotAcknowledged
        }
        let frozenIdentity = try rows("""
            SELECT local_collection_id,wire_collection_id,wire_name
            FROM shared_collection_delivery_identity WHERE operation_id=?
            """, [id.uuidString]).first
        let wireCollection: (id: UUID, name: String)
        if let frozenIdentity {
            guard frozenIdentity[0] == collectionID.uuidString,
                  let wireID = UUID(uuidString: frozenIdentity[1] ?? ""),
                  let wireName = frozenIdentity[2], !wireName.isEmpty else {
                throw LocalLibraryError.syncIdentityChanged
            }
            wireCollection = (wireID, wireName)
        } else {
            wireCollection = try wireCollectionIdentity(
                for: collectionID, localName: collectionName
            )
        }
        let earlier = try scalar("""
            SELECT MIN(o.sequence) FROM shared_outbox s
            JOIN outbox o ON o.operation_id=s.operation_id
            WHERE s.asset_id=? AND s.field=?
            """, [pending.assetID.uuidString, pending.field]).flatMap(Int64.init)
        guard earlier == pending.sequence else {
            throw LocalLibraryError.syncEarlierOperationPending
        }
        let baseRevision: Int64
        if let prepared = pending.preparedBaseRevision {
            let binding = try rows("""
                SELECT host_id,device_id,scope_revision FROM shared_delivery WHERE operation_id=?
                """, [id.uuidString]).first
            guard binding?[0] == hostID.uuidString,
                  binding?[1] == deviceID.uuidString,
                  Int64(binding?[2] ?? "") == pending.scopeRevision else {
                throw LocalLibraryError.syncIdentityChanged
            }
            baseRevision = prepared
        } else {
            baseRevision = Int64(try scalar("""
                SELECT revision FROM shared_field_versions WHERE asset_id=? AND field=?
                """, [pending.assetID.uuidString, pending.field]) ?? "0") ?? 0
        }
        try transaction {
            if pending.preparedBaseRevision == nil {
                try execute("""
                    INSERT INTO shared_delivery(
                      operation_id,host_id,device_id,base_revision,scope_revision,state
                    ) VALUES(?,?,?,?,?,'prepared')
                    """, [
                        id.uuidString, hostID.uuidString, deviceID.uuidString,
                        String(baseRevision), String(pending.scopeRevision)
                    ])
            }
            if frozenIdentity == nil {
                try execute("""
                    INSERT INTO shared_collection_delivery_identity(
                      operation_id,local_collection_id,wire_collection_id,wire_name
                    ) VALUES(?,?,?,?)
                    """, [id.uuidString, collectionID.uuidString,
                           wireCollection.id.uuidString, wireCollection.name])
            }
        }
        return LocalPreparedSharedCollectionOperation(
            hostID: hostID, deviceID: deviceID, operation: pending,
            collectionID: wireCollection.id, collectionName: wireCollection.name,
            included: pending.value == "1", baseRevision: baseRevision,
            installID: try installID(), sourceEpoch: try sourceEpoch()
        )
    }

    public func prepareSharedFavoriteOperation(
        id: UUID, hostID: UUID, deviceID: UUID
    ) throws -> LocalPreparedSharedFavoriteOperation? {
        guard let pending = try pendingSharedOperations().first(where: { $0.id == id }) else {
            return nil
        }
        guard pending.field == "favorite.target",
              pending.value == "0" || pending.value == "1" else {
            throw LocalLibraryError.unsupportedSharedOperation
        }
        guard !pending.isConflicted else { throw LocalLibraryError.syncConflictRequiresResolution }
        guard try requiredIdentity("sync_host_id") == hostID.uuidString,
              try requiredIdentity("sync_device_id") == deviceID.uuidString else {
            throw LocalLibraryError.syncIdentityChanged
        }
        guard pending.scopeRevision == (Int64(try requiredIdentity("share_scope_revision")) ?? -1),
              pending.scopeRevision == (Int64(try requiredIdentity("sync_ack_scope_revision")) ?? -1) else {
            throw LocalLibraryError.syncScopeNotAcknowledged
        }
        let earlier = try scalar("""
            SELECT MIN(o.sequence) FROM shared_outbox s
            JOIN outbox o ON o.operation_id=s.operation_id
            WHERE s.asset_id=? AND s.field='favorite.target'
            """, [pending.assetID.uuidString]).flatMap(Int64.init)
        guard earlier == pending.sequence else {
            throw LocalLibraryError.syncEarlierOperationPending
        }
        let baseRevision: Int64
        if let prepared = pending.preparedBaseRevision {
            let binding = try rows("""
                SELECT host_id,device_id,scope_revision FROM shared_delivery WHERE operation_id=?
                """, [id.uuidString]).first
            guard binding?[0] == hostID.uuidString,
                  binding?[1] == deviceID.uuidString,
                  Int64(binding?[2] ?? "") == pending.scopeRevision else {
                throw LocalLibraryError.syncIdentityChanged
            }
            baseRevision = prepared
        } else {
            baseRevision = Int64(try scalar("""
                SELECT revision FROM shared_field_versions
                WHERE asset_id=? AND field='favorite.target'
                """, [pending.assetID.uuidString]) ?? "0") ?? 0
            try transaction {
                try execute("""
                    INSERT INTO shared_delivery(
                      operation_id,host_id,device_id,base_revision,scope_revision,state
                    ) VALUES(?,?,?,?,?,'prepared')
                    """, [
                        id.uuidString, hostID.uuidString, deviceID.uuidString,
                        String(baseRevision), String(pending.scopeRevision)
                    ])
            }
        }
        return LocalPreparedSharedFavoriteOperation(
            hostID: hostID, deviceID: deviceID, operation: pending,
            target: pending.value == "1", baseRevision: baseRevision,
            installID: try installID(), sourceEpoch: try sourceEpoch()
        )
    }

    /// Applied/unchanged ACKs advance the local field baseline; conflicts remain durable.
    @discardableResult
    public func recordSharedTagResult(
        operationID: UUID, hostID: UUID, deviceID: UUID,
        disposition: LocalSharedTagDisposition,
        fieldRevision: Int64, currentDecision: LocalDecision?,
        conflictReason: LocalSharedConflictReason? = nil
    ) throws -> Bool {
        guard fieldRevision >= 0 else { throw LocalLibraryError.database("invalid shared revision") }
        guard let operation = try pendingSharedOperations().first(where: { $0.id == operationID })
        else { return false } // Explicitly unshared while the request was in flight.
        let binding = try rows("""
            SELECT host_id,device_id,base_revision FROM shared_delivery WHERE operation_id=?
            """, [operationID.uuidString]).first
        guard binding?[0] == hostID.uuidString,
              binding?[1] == deviceID.uuidString,
              let base = Int64(binding?[2] ?? ""),
              fieldRevision >= base else {
            throw LocalLibraryError.syncIdentityChanged
        }
        try transaction {
            switch disposition {
            case .applied, .unchanged:
                guard currentDecision?.rawValue == operation.value else {
                    throw LocalLibraryError.database("shared ACK does not match submitted decision")
                }
                try execute("""
                    INSERT INTO shared_field_versions(asset_id,field,revision) VALUES(?,?,?)
                    ON CONFLICT(asset_id,field) DO UPDATE SET
                      revision=MAX(revision,excluded.revision)
                    """, [
                        operation.assetID.uuidString, operation.field,
                        String(fieldRevision)
                    ])
                try execute("DELETE FROM shared_outbox WHERE operation_id=?", [operationID.uuidString])
            case .conflict:
                try execute("""
                    UPDATE shared_delivery SET state='conflict',
                      conflict_revision=?,conflict_value=? WHERE operation_id=?
                    """, [
                        String(fieldRevision), currentDecision?.rawValue ?? "",
                        operationID.uuidString
                    ])
                if let conflictReason {
                    try execute("""
                        INSERT INTO shared_conflict_details(operation_id,reason) VALUES(?,?)
                        ON CONFLICT(operation_id) DO UPDATE SET reason=excluded.reason
                        """, [operationID.uuidString, conflictReason.rawValue])
                }
            }
        }
        return true
    }

    @discardableResult
    public func recordSharedCollectionResult(
        operationID: UUID, hostID: UUID, deviceID: UUID,
        disposition: LocalSharedTagDisposition,
        fieldRevision: Int64, currentIncluded: Bool?,
        conflictReason: LocalSharedConflictReason? = nil
    ) throws -> Bool {
        guard fieldRevision >= 0 else { throw LocalLibraryError.database("invalid shared revision") }
        guard let operation = try pendingSharedOperations().first(where: { $0.id == operationID }),
              operation.field.hasPrefix("collection.") else { return false }
        let binding = try rows("""
            SELECT host_id,device_id,base_revision FROM shared_delivery WHERE operation_id=?
            """, [operationID.uuidString]).first
        guard binding?[0] == hostID.uuidString,
              binding?[1] == deviceID.uuidString,
              let base = Int64(binding?[2] ?? ""),
              fieldRevision >= base else {
            throw LocalLibraryError.syncIdentityChanged
        }
        try transaction {
            switch disposition {
            case .applied, .unchanged:
                guard currentIncluded.map({ $0 ? "1" : "0" }) == operation.value else {
                    throw LocalLibraryError.database("shared ACK does not match submitted membership")
                }
                try execute("""
                    INSERT INTO shared_field_versions(asset_id,field,revision) VALUES(?,?,?)
                    ON CONFLICT(asset_id,field) DO UPDATE SET
                      revision=MAX(revision,excluded.revision)
                    """, [operation.assetID.uuidString, operation.field, String(fieldRevision)])
                try execute("DELETE FROM shared_outbox WHERE operation_id=?", [operationID.uuidString])
            case .conflict:
                try execute("""
                    UPDATE shared_delivery SET state='conflict',
                      conflict_revision=?,conflict_value=? WHERE operation_id=?
                    """, [
                        String(fieldRevision), currentIncluded.map { $0 ? "1" : "0" } ?? "",
                        operationID.uuidString
                    ])
                if let conflictReason {
                    try execute("""
                        INSERT INTO shared_conflict_details(operation_id,reason) VALUES(?,?)
                        ON CONFLICT(operation_id) DO UPDATE SET reason=excluded.reason
                        """, [operationID.uuidString, conflictReason.rawValue])
                }
            }
        }
        return true
    }

    @discardableResult
    public func recordSharedFavoriteResult(
        operationID: UUID, hostID: UUID, deviceID: UUID,
        disposition: LocalSharedTagDisposition,
        fieldRevision: Int64, currentTarget: Bool?
    ) throws -> Bool {
        guard fieldRevision >= 0 else { throw LocalLibraryError.database("invalid shared revision") }
        guard let operation = try pendingSharedOperations().first(where: { $0.id == operationID }),
              operation.field == "favorite.target" else { return false }
        let binding = try rows("""
            SELECT host_id,device_id,base_revision FROM shared_delivery WHERE operation_id=?
            """, [operationID.uuidString]).first
        guard binding?[0] == hostID.uuidString,
              binding?[1] == deviceID.uuidString,
              let base = Int64(binding?[2] ?? ""),
              fieldRevision >= base else {
            throw LocalLibraryError.syncIdentityChanged
        }
        try transaction {
            switch disposition {
            case .applied, .unchanged:
                guard currentTarget.map({ $0 ? "1" : "0" }) == operation.value else {
                    throw LocalLibraryError.database("shared ACK does not match submitted favorite")
                }
                try execute("""
                    INSERT INTO shared_field_versions(asset_id,field,revision)
                    VALUES(?,'favorite.target',?)
                    ON CONFLICT(asset_id,field) DO UPDATE SET
                      revision=MAX(revision,excluded.revision)
                    """, [operation.assetID.uuidString, String(fieldRevision)])
                try execute("DELETE FROM shared_outbox WHERE operation_id=?", [operationID.uuidString])
            case .conflict:
                try execute("""
                    UPDATE shared_delivery SET state='conflict',
                      conflict_revision=?,conflict_value=? WHERE operation_id=?
                    """, [
                        String(fieldRevision), currentTarget.map { $0 ? "1" : "0" } ?? "",
                        operationID.uuidString
                    ])
                try execute("""
                    INSERT INTO shared_conflict_details(operation_id,reason)
                    VALUES(?,'fieldVersion')
                    ON CONFLICT(operation_id) DO UPDATE SET reason=excluded.reason
                    """, [operationID.uuidString])
            }
        }
        return true
    }

    /// Resolves version conflicts or identity conflicts explained by an applied
    /// rename of this exact collection. Other identity conflicts stay pending.
    @discardableResult
    public func resolveSharedCollectionConflict(
        operationID: UUID, resolution: LocalSharedCollectionConflictResolution
    ) throws -> UUID? {
        guard let conflict = try pendingSharedOperations().first(where: { $0.id == operationID }),
              conflict.isConflicted,
              (conflict.conflictReason == .fieldVersion
                || (conflict.conflictReason == .collectionIdentity
                    && conflict.verifiedCollectionRename != nil)),
              let revision = conflict.conflictRevision,
              let macRaw = conflict.conflictValue,
              macRaw == "0" || macRaw == "1",
              conflict.field.hasPrefix("collection."),
              let collectionID = UUID(uuidString: String(conflict.field.dropFirst(11))),
              let collectionName = try scalar(
                  "SELECT name FROM collections WHERE id=?", [collectionID.uuidString]
              ),
              let localIncluded = conflict.localCurrentIncluded,
              conflict.scopeRevision == Int64(try requiredIdentity("share_scope_revision")),
              conflict.scopeRevision == Int64(try requiredIdentity("sync_ack_scope_revision")) else {
            throw LocalLibraryError.syncConflictDetailsUnavailable
        }
        let hostID = try requiredIdentity("sync_host_id")
        let deviceID = try requiredIdentity("sync_device_id")
        let rowsForField = try rows("""
            SELECT s.operation_id,o.sequence,d.state,d.host_id,d.device_id
            FROM shared_outbox s JOIN outbox o ON o.operation_id=s.operation_id
            LEFT JOIN shared_delivery d ON d.operation_id=s.operation_id
            WHERE s.asset_id=? AND s.field=? ORDER BY o.sequence
            """, [conflict.assetID.uuidString, conflict.field])
        guard let first = rowsForField.first,
              first[0] == operationID.uuidString,
              first[3] == hostID, first[4] == deviceID,
              rowsForField.dropFirst().allSatisfy({ $0[2] == nil }) else {
            throw LocalLibraryError.syncEarlierOperationPending
        }
        let baseline = Int64(try scalar("""
            SELECT revision FROM shared_field_versions WHERE asset_id=? AND field=?
            """, [conflict.assetID.uuidString, conflict.field]) ?? "0") ?? 0
        guard baseline <= revision else { throw LocalLibraryError.syncIdentityChanged }
        let macIncluded = macRaw == "1"
        var newOperationID: UUID?
        try transaction {
            for row in rowsForField {
                try execute("DELETE FROM shared_outbox WHERE operation_id=?", [row[0] ?? ""])
            }
            try execute("""
                INSERT INTO shared_field_versions(asset_id,field,revision) VALUES(?,?,?)
                ON CONFLICT(asset_id,field) DO UPDATE SET
                  revision=MAX(revision,excluded.revision)
                """, [conflict.assetID.uuidString, conflict.field, String(revision)])
            switch resolution {
            case .acceptMac:
                if localIncluded != macIncluded {
                    try execute("""
                        UPDATE memberships SET included=?,revision=revision+1
                        WHERE asset_id=? AND collection_id=?
                        """, [
                            macRaw, conflict.assetID.uuidString, collectionID.uuidString
                        ])
                    _ = try enqueue(
                        conflict.assetID, field: conflict.field, value: macRaw, origin: .conflictResolution
                    )
                }
            case .keepPhone:
                if localIncluded != macIncluded {
                    let value = localIncluded ? "1" : "0"
                    let id = try enqueue(
                        conflict.assetID, field: conflict.field, value: value, origin: .conflictResolution
                    )
                    try enqueueShared(
                        id, assetID: conflict.assetID, field: conflict.field,
                        value: value, referenceName: collectionName
                    )
                    newOperationID = id
                }
            }
        }
        return newOperationID
    }

    /// This changes ImageAll's target only. Accepting Mac leaves a separate source
    /// writeback state for the iPhone owner; it never calls PhotoKit here.
    @discardableResult
    public func resolveSharedFavoriteConflict(
        operationID: UUID, resolution: LocalSharedFavoriteConflictResolution
    ) throws -> UUID? {
        guard let conflict = try pendingSharedOperations().first(where: { $0.id == operationID }),
              conflict.isConflicted,
              conflict.conflictReason == .fieldVersion,
              let revision = conflict.conflictRevision,
              let macRaw = conflict.conflictValue,
              macRaw == "0" || macRaw == "1",
              conflict.field == "favorite.target",
              let localTarget = conflict.localCurrentFavoriteTarget,
              conflict.scopeRevision == Int64(try requiredIdentity("share_scope_revision")),
              conflict.scopeRevision == Int64(try requiredIdentity("sync_ack_scope_revision")) else {
            throw LocalLibraryError.syncConflictDetailsUnavailable
        }
        let hostID = try requiredIdentity("sync_host_id")
        let deviceID = try requiredIdentity("sync_device_id")
        let rowsForField = try rows("""
            SELECT s.operation_id,o.sequence,d.state,d.host_id,d.device_id
            FROM shared_outbox s JOIN outbox o ON o.operation_id=s.operation_id
            LEFT JOIN shared_delivery d ON d.operation_id=s.operation_id
            WHERE s.asset_id=? AND s.field='favorite.target' ORDER BY o.sequence
            """, [conflict.assetID.uuidString])
        guard let first = rowsForField.first,
              first[0] == operationID.uuidString,
              first[3] == hostID, first[4] == deviceID,
              rowsForField.dropFirst().allSatisfy({ $0[2] == nil }) else {
            throw LocalLibraryError.syncEarlierOperationPending
        }
        let baseline = Int64(try scalar("""
            SELECT revision FROM shared_field_versions
            WHERE asset_id=? AND field='favorite.target'
            """, [conflict.assetID.uuidString]) ?? "0") ?? 0
        guard baseline <= revision else { throw LocalLibraryError.syncIdentityChanged }
        let macTarget = macRaw == "1"
        var newOperationID: UUID?
        try transaction {
            for row in rowsForField {
                try execute("DELETE FROM shared_outbox WHERE operation_id=?", [row[0] ?? ""])
            }
            try execute("""
                INSERT INTO shared_field_versions(asset_id,field,revision)
                VALUES(?,'favorite.target',?)
                ON CONFLICT(asset_id,field) DO UPDATE SET
                  revision=MAX(revision,excluded.revision)
                """, [conflict.assetID.uuidString, String(revision)])
            switch resolution {
            case .acceptMac:
                if localTarget != macTarget {
                    try execute("UPDATE assets SET favorite_target=? WHERE id=?", [
                        macRaw, conflict.assetID.uuidString
                    ])
                    try execute("""
                        INSERT INTO favorite_writebacks(asset_id,target,state)
                        VALUES(?,?,CASE WHEN (
                          SELECT observed_favorite FROM assets WHERE id=?
                        )=? THEN 'matched' ELSE 'pending' END)
                        ON CONFLICT(asset_id) DO UPDATE SET
                          target=excluded.target,state=excluded.state
                        """, [conflict.assetID.uuidString, macRaw, conflict.assetID.uuidString, macRaw])
                    _ = try enqueue(conflict.assetID, field: "favorite.target", value: macRaw, origin: .conflictResolution)
                }
            case .keepPhone:
                if localTarget != macTarget {
                    let value = localTarget ? "1" : "0"
                    let id = try enqueue(conflict.assetID, field: "favorite.target", value: value, origin: .conflictResolution)
                    try enqueueShared(
                        id, assetID: conflict.assetID, field: "favorite.target",
                        value: value, referenceName: nil
                    )
                    newOperationID = id
                }
            }
        }
        return newOperationID
    }

    /// An explicit owner choice consumes the conflicted wire operation. Keeping the phone
    /// creates a new operation ID and sequence at the observed Mac revision; old audit rows stay.
    @discardableResult
    public func resolveSharedTagConflict(
        operationID: UUID, resolution: LocalSharedTagConflictResolution
    ) throws -> UUID? {
        guard let conflict = try pendingSharedOperations().first(where: { $0.id == operationID }),
              conflict.isConflicted,
              conflict.conflictReason == .fieldVersion,
              let revision = conflict.conflictRevision,
              let macDecision = conflict.conflictDecision,
              conflict.field.hasPrefix("tag."),
              let tagID = UUID(uuidString: String(conflict.field.dropFirst(4))),
              let tagName = try scalar("SELECT name FROM tags WHERE id=?", [tagID.uuidString]),
              let localRaw = try scalar("""
                  SELECT decision FROM tag_decisions WHERE asset_id=? AND tag_id=?
                  """, [conflict.assetID.uuidString, tagID.uuidString]),
              let localDecision = LocalDecision(rawValue: localRaw),
              conflict.scopeRevision == Int64(try requiredIdentity("share_scope_revision")),
              conflict.scopeRevision == Int64(try requiredIdentity("sync_ack_scope_revision")) else {
            throw LocalLibraryError.syncConflictDetailsUnavailable
        }
        let hostID = try requiredIdentity("sync_host_id")
        let deviceID = try requiredIdentity("sync_device_id")
        let rowsForField = try rows("""
            SELECT s.operation_id,o.sequence,d.state,d.host_id,d.device_id
            FROM shared_outbox s JOIN outbox o ON o.operation_id=s.operation_id
            LEFT JOIN shared_delivery d ON d.operation_id=s.operation_id
            WHERE s.asset_id=? AND s.field=? ORDER BY o.sequence
            """, [conflict.assetID.uuidString, conflict.field])
        guard let first = rowsForField.first,
              first[0] == operationID.uuidString,
              first[3] == hostID, first[4] == deviceID,
              rowsForField.dropFirst().allSatisfy({ $0[2] == nil }) else {
            throw LocalLibraryError.syncEarlierOperationPending
        }
        let baseline = Int64(try scalar("""
            SELECT revision FROM shared_field_versions WHERE asset_id=? AND field=?
            """, [conflict.assetID.uuidString, conflict.field]) ?? "0") ?? 0
        guard baseline <= revision else { throw LocalLibraryError.syncIdentityChanged }
        var newOperationID: UUID?
        try transaction {
            for row in rowsForField {
                try execute("DELETE FROM shared_outbox WHERE operation_id=?", [row[0] ?? ""])
            }
            try execute("""
                INSERT INTO shared_field_versions(asset_id,field,revision) VALUES(?,?,?)
                ON CONFLICT(asset_id,field) DO UPDATE SET
                  revision=MAX(revision,excluded.revision)
                """, [conflict.assetID.uuidString, conflict.field, String(revision)])
            switch resolution {
            case .acceptMac:
                if localDecision != macDecision {
                    try execute("""
                        UPDATE tag_decisions SET decision=?,revision=revision+1
                        WHERE asset_id=? AND tag_id=?
                        """, [
                            macDecision.rawValue, conflict.assetID.uuidString,
                            tagID.uuidString
                        ])
                    _ = try enqueue(
                        conflict.assetID, field: conflict.field,
                        value: macDecision.rawValue, origin: .conflictResolution
                    )
                }
            case .keepPhone:
                if localDecision != macDecision {
                    let id = try enqueue(
                        conflict.assetID, field: conflict.field,
                        value: localDecision.rawValue, origin: .conflictResolution
                    )
                    try enqueueShared(
                        id, assetID: conflict.assetID, field: conflict.field,
                        value: localDecision.rawValue, referenceName: tagName
                    )
                    newOperationID = id
                }
            }
        }
        return newOperationID
    }

    public func sharedTagChangeCursor() throws -> Int64 {
        Int64(try requiredIdentity("sync_tag_change_cursor")) ?? 0
    }

    /// Explicitly bind one Mac tag to an existing, still local-only phone tag.
    /// A tag that has already appeared in the shared ledger cannot be rebound.
    public func confirmSharedTagAlias(_ candidate: LocalSharedTagAliasCandidate) throws {
        let field = "tag.\(candidate.localTagID.uuidString)"
        guard candidate.remoteTagID != candidate.localTagID,
              try requiredIdentity("sync_host_id") == candidate.hostID.uuidString,
              try requiredIdentity("sync_device_id") == candidate.deviceID.uuidString,
              try requiredIdentity("source_epoch") == candidate.sourceEpoch.uuidString,
              Int64(try requiredIdentity("share_scope_revision")) == candidate.scopeRevision,
              Int64(try requiredIdentity("sync_ack_scope_revision")) == candidate.scopeRevision,
              try sharedTagChangeCursor() == candidate.afterCursor,
              try isShared(assetID: candidate.assetID),
              try scalar("SELECT name FROM tags WHERE id=?", [candidate.localTagID.uuidString])
                  == candidate.localTagName,
              try scalar("SELECT id FROM tags WHERE id=?", [candidate.remoteTagID.uuidString])
                  == nil,
              !candidate.remoteTagName.isEmpty,
              Self.syncTagNameKey(candidate.remoteTagName)
                  == Self.syncTagNameKey(candidate.localTagName),
              try scalar("SELECT operation_id FROM shared_outbox WHERE field=? LIMIT 1", [field])
                  == nil,
              try scalar("SELECT asset_id FROM shared_field_versions WHERE field=? LIMIT 1", [field])
                  == nil,
              try scalar("SELECT payload FROM shared_snapshot_delivery WHERE id=1") == nil,
              try aliasRow(
                  remoteTagID: candidate.remoteTagID, hostID: candidate.hostID,
                  deviceID: candidate.deviceID, sourceEpoch: candidate.sourceEpoch
              ) == nil,
              try scalar("""
                  SELECT remote_tag_id FROM shared_tag_aliases
                  WHERE host_id=? AND device_id=? AND source_epoch=? AND local_tag_id=?
                  """, [candidate.hostID.uuidString, candidate.deviceID.uuidString,
                         candidate.sourceEpoch.uuidString, candidate.localTagID.uuidString]) == nil
        else { throw LocalLibraryError.syncRemoteTagMismatch }
        try transaction {
            try execute("""
                INSERT INTO shared_tag_aliases(
                  host_id,device_id,source_epoch,remote_tag_id,local_tag_id,
                  remote_name,local_name,confirmed_time
                ) VALUES(?,?,?,?,?,?,?,?)
                """, [
                    candidate.hostID.uuidString, candidate.deviceID.uuidString,
                    candidate.sourceEpoch.uuidString, candidate.remoteTagID.uuidString,
                    candidate.localTagID.uuidString, candidate.remoteTagName,
                    candidate.localTagName, String(Date().timeIntervalSince1970)
                ])
        }
    }

    /// Applies one Mac change page and its cursor atomically. A pending phone intent is
    /// never overwritten by a Mac value; a prepared request must be retried first.
    public func applySharedTagChanges(
        hostID: UUID, deviceID: UUID, sourceEpoch: UUID,
        scopeRevision: Int64, afterCursor: Int64,
        changes: [LocalSharedTagChange], nextCursor: Int64
    ) throws -> LocalSharedTagPullResult {
        guard try requiredIdentity("sync_host_id") == hostID.uuidString,
              try requiredIdentity("sync_device_id") == deviceID.uuidString,
              try requiredIdentity("source_epoch") == sourceEpoch.uuidString,
              Int64(try requiredIdentity("share_scope_revision")) == scopeRevision,
              Int64(try requiredIdentity("sync_ack_scope_revision")) == scopeRevision,
              try sharedTagChangeCursor() == afterCursor,
              nextCursor >= afterCursor,
              changes.allSatisfy({
                  $0.sequence > afterCursor && $0.sequence <= nextCursor && $0.fieldRevision > 0
              }),
              zip(changes, changes.dropFirst()).allSatisfy({ $0.0.sequence < $0.1.sequence }) else {
            throw LocalLibraryError.syncIdentityChanged
        }
        // Surface a name match as a candidate before starting the page transaction.
        // No facts or cursor change until the owner confirms the two identities.
        for change in changes {
            guard try isShared(assetID: change.assetID) else {
                throw LocalLibraryError.syncRemoteTagMismatch
            }
            if try scalar("SELECT id FROM tags WHERE id=?", [change.tagID.uuidString]) != nil {
                continue
            }
            if try aliasRow(
                remoteTagID: change.tagID, hostID: hostID,
                deviceID: deviceID, sourceEpoch: sourceEpoch
            ) != nil {
                continue
            }
            let matching = try tags().filter {
                Self.syncTagNameKey($0.name) == Self.syncTagNameKey(change.tagName)
            }
            if matching.count == 1, let local = matching.first {
                let field = "tag.\(local.id.uuidString)"
                guard try scalar(
                    "SELECT operation_id FROM shared_outbox WHERE field=? LIMIT 1", [field]
                ) == nil,
                      try scalar(
                          "SELECT asset_id FROM shared_field_versions WHERE field=? LIMIT 1", [field]
                      ) == nil,
                      try scalar("""
                          SELECT remote_tag_id FROM shared_tag_aliases
                          WHERE host_id=? AND device_id=? AND source_epoch=? AND local_tag_id=?
                          """, [hostID.uuidString, deviceID.uuidString,
                                 sourceEpoch.uuidString, local.id.uuidString]) == nil
                else { throw LocalLibraryError.syncRemoteTagMismatch }
                throw LocalLibraryError.syncRemoteTagAliasRequired(.init(
                    hostID: hostID, deviceID: deviceID, sourceEpoch: sourceEpoch,
                    scopeRevision: scopeRevision, afterCursor: afterCursor,
                    assetID: change.assetID, remoteTagID: change.tagID,
                    remoteTagName: change.tagName,
                    localTagID: local.id, localTagName: local.name
                ))
            }
        }
        var applied = 0
        var conflicts = 0
        try transaction {
            for change in changes {
                guard try isShared(assetID: change.assetID) else {
                    throw LocalLibraryError.syncRemoteTagMismatch
                }
                let localTagID = try localTagIdentity(
                    for: change.tagID, remoteName: change.tagName,
                    hostID: hostID, deviceID: deviceID, sourceEpoch: sourceEpoch
                )
                let field = "tag.\(localTagID.uuidString)"
                let baseline = Int64(try scalar("""
                    SELECT revision FROM shared_field_versions WHERE asset_id=? AND field=?
                    """, [change.assetID.uuidString, field]) ?? "0") ?? 0
                if let localName = try scalar(
                    "SELECT name FROM tags WHERE id=?", [localTagID.uuidString]
                ) {
                    guard localTagID != change.tagID || localName == change.tagName else {
                        throw LocalLibraryError.syncRemoteTagMismatch
                    }
                } else {
                    let trimmed = change.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedName = Self.syncTagNameKey(trimmed)
                    let existingNames = try rows("SELECT name FROM tags").compactMap { $0[0] }
                    guard baseline == 0, change.fieldRevision == 1,
                          change.decision != .cleared,
                          trimmed == change.tagName, !trimmed.isEmpty,
                          trimmed.count <= 120, trimmed.utf8.count <= 512,
                          !existingNames.contains(where: {
                              Self.syncTagNameKey($0) == normalizedName
                          }) else {
                        throw LocalLibraryError.syncRemoteTagMismatch
                    }
                    // A Mac-issued tag identity is installed with the fact and cursor.
                    // It does not create a phone outbox operation of its own.
                    try execute("INSERT INTO tags(id,name) VALUES(?,?)", [
                        change.tagID.uuidString, trimmed
                    ])
                }
                if change.fieldRevision <= baseline { continue }
                let pending = try rows("""
                    SELECT s.operation_id,s.value,d.state
                    FROM shared_outbox s JOIN outbox o ON o.operation_id=s.operation_id
                    LEFT JOIN shared_delivery d ON d.operation_id=s.operation_id
                    WHERE s.asset_id=? AND s.field=? ORDER BY o.sequence
                    """, [change.assetID.uuidString, field]).first
                if let pending {
                    guard pending[2] != "prepared" else {
                        throw LocalLibraryError.syncEarlierOperationPending
                    }
                    if pending[1] == change.decision.rawValue,
                       pending[2] == nil {
                        try execute("DELETE FROM shared_outbox WHERE operation_id=?", [pending[0] ?? ""])
                        applied += 1
                    } else {
                        try execute("""
                            INSERT INTO shared_delivery(
                              operation_id,host_id,device_id,base_revision,scope_revision,
                              state,conflict_revision,conflict_value
                            ) VALUES(?,?,?,?,?,'conflict',?,?)
                            ON CONFLICT(operation_id) DO UPDATE SET
                              state='conflict',conflict_revision=excluded.conflict_revision,
                              conflict_value=excluded.conflict_value
                            """, [
                                pending[0] ?? "", hostID.uuidString, deviceID.uuidString,
                                String(baseline), String(scopeRevision),
                                String(change.fieldRevision), change.decision.rawValue
                            ])
                        try execute("""
                            INSERT INTO shared_conflict_details(operation_id,reason)
                            VALUES(?,'fieldVersion')
                            ON CONFLICT(operation_id) DO UPDATE SET reason=excluded.reason
                            """, [pending[0] ?? ""])
                        conflicts += 1
                    }
                } else {
                    let current = try scalar("""
                        SELECT decision FROM tag_decisions WHERE asset_id=? AND tag_id=?
                        """, [change.assetID.uuidString, localTagID.uuidString])
                    if current != change.decision.rawValue {
                        try execute("""
                            INSERT INTO tag_decisions(asset_id,tag_id,decision,revision)
                            VALUES(?,?,?,1) ON CONFLICT(asset_id,tag_id) DO UPDATE SET
                              decision=excluded.decision,revision=revision+1
                            """, [
                                change.assetID.uuidString, localTagID.uuidString,
                                change.decision.rawValue
                            ])
                        _ = try enqueue(
                            change.assetID, field: field, value: change.decision.rawValue, origin: .remoteSync
                        )
                    }
                    applied += 1
                }
                try execute("""
                    INSERT INTO shared_field_versions(asset_id,field,revision) VALUES(?,?,?)
                    ON CONFLICT(asset_id,field) DO UPDATE SET
                      revision=MAX(revision,excluded.revision)
                    """, [
                        change.assetID.uuidString, field, String(change.fieldRevision)
                    ])
            }
            try execute("UPDATE identity SET value=? WHERE key='sync_tag_change_cursor'", [
                String(nextCursor)
            ])
        }
        return LocalSharedTagPullResult(
            applied: applied, conflicts: conflicts, nextCursor: nextCursor
        )
    }

    public func sharedCollectionChangeCursor() throws -> Int64 {
        Int64(try requiredIdentity("sync_collection_change_cursor")) ?? 0
    }

    /// The owner confirms one Mac collection as the same still-local-only
    /// phone collection. This records identity only; the change page is retried.
    public func confirmSharedCollectionAlias(
        _ candidate: LocalSharedCollectionAliasCandidate
    ) throws {
        let field = "collection.\(candidate.localCollectionID.uuidString)"
        guard candidate.remoteCollectionID != candidate.localCollectionID,
              try requiredIdentity("sync_host_id") == candidate.hostID.uuidString,
              try requiredIdentity("sync_device_id") == candidate.deviceID.uuidString,
              try requiredIdentity("source_epoch") == candidate.sourceEpoch.uuidString,
              Int64(try requiredIdentity("share_scope_revision")) == candidate.scopeRevision,
              Int64(try requiredIdentity("sync_ack_scope_revision")) == candidate.scopeRevision,
              try sharedCollectionChangeCursor() == candidate.afterCursor,
              try isShared(assetID: candidate.assetID),
              try scalar("SELECT name FROM collections WHERE id=?", [
                  candidate.localCollectionID.uuidString
              ]) == candidate.localCollectionName,
              try scalar("SELECT id FROM collections WHERE id=?", [
                  candidate.remoteCollectionID.uuidString
              ]) == nil,
              !candidate.remoteCollectionName.isEmpty,
              Self.syncTagNameKey(candidate.remoteCollectionName)
                  == Self.syncTagNameKey(candidate.localCollectionName),
              try scalar("SELECT operation_id FROM shared_outbox WHERE field=? LIMIT 1", [field])
                  == nil,
              try scalar("SELECT asset_id FROM shared_field_versions WHERE field=? LIMIT 1", [field])
                  == nil,
              try scalar("SELECT payload FROM shared_snapshot_delivery WHERE id=1") == nil,
              try collectionAliasRow(
                  remoteCollectionID: candidate.remoteCollectionID,
                  hostID: candidate.hostID, deviceID: candidate.deviceID,
                  sourceEpoch: candidate.sourceEpoch
              ) == nil,
              try scalar("""
                  SELECT remote_collection_id FROM shared_collection_aliases
                  WHERE host_id=? AND device_id=? AND source_epoch=? AND local_collection_id=?
                  """, [candidate.hostID.uuidString, candidate.deviceID.uuidString,
                         candidate.sourceEpoch.uuidString,
                         candidate.localCollectionID.uuidString]) == nil else {
            throw LocalLibraryError.syncRemoteCollectionMismatch
        }
        try transaction {
            try execute("DELETE FROM private_collection_names WHERE collection_id=?", [candidate.localCollectionID.uuidString])
            try execute("""
                INSERT INTO shared_collection_aliases(
                  host_id,device_id,source_epoch,remote_collection_id,
                  local_collection_id,remote_name,local_name,confirmed_time
                ) VALUES(?,?,?,?,?,?,?,?)
                """, [
                    candidate.hostID.uuidString, candidate.deviceID.uuidString,
                    candidate.sourceEpoch.uuidString,
                    candidate.remoteCollectionID.uuidString,
                    candidate.localCollectionID.uuidString,
                    candidate.remoteCollectionName, candidate.localCollectionName,
                    String(Date().timeIntervalSince1970)
                ])
        }
    }

    /// A member change and its cursor commit together. A local pending operation is
    /// kept as an explicit conflict, and remote observation never echoes to Mac.
    public func applySharedCollectionChanges(
        hostID: UUID, deviceID: UUID, sourceEpoch: UUID,
        scopeRevision: Int64, afterCursor: Int64,
        changes: [LocalSharedCollectionChange], nextCursor: Int64
    ) throws -> LocalSharedCollectionPullResult {
        guard try requiredIdentity("sync_host_id") == hostID.uuidString,
              try requiredIdentity("sync_device_id") == deviceID.uuidString,
              try requiredIdentity("source_epoch") == sourceEpoch.uuidString,
              Int64(try requiredIdentity("share_scope_revision")) == scopeRevision,
              Int64(try requiredIdentity("sync_ack_scope_revision")) == scopeRevision,
              try sharedCollectionChangeCursor() == afterCursor,
              nextCursor >= afterCursor,
              changes.allSatisfy({
                  $0.sequence > afterCursor && $0.sequence <= nextCursor
                      && $0.fieldRevision > 0
                      && ($0.renamedFrom == nil || (
                          $0.renamedFrom?.isEmpty == false
                              && $0.renamedFrom != $0.collectionName
                              && !$0.collectionName.isEmpty
                              && $0.collectionName == $0.collectionName.trimmingCharacters(
                                  in: .whitespacesAndNewlines
                              )
                              && $0.collectionName.count <= 160
                              && $0.collectionName.utf8.count <= 640
                      ))
              }),
              zip(changes, changes.dropFirst()).allSatisfy({ $0.0.sequence < $0.1.sequence }) else {
            throw LocalLibraryError.syncIdentityChanged
        }
        for change in changes {
            guard try isShared(assetID: change.assetID) else {
                throw LocalLibraryError.syncRemoteCollectionMismatch
            }
            // A rename is an identity-preserving transition. A colliding new
            // name is rejected by the transaction, never proposed as a new alias.
            if change.renamedFrom != nil { continue }
            if try scalar("SELECT id FROM collections WHERE id=?", [
                change.collectionID.uuidString
            ]) != nil { continue }
            if try collectionAliasRow(
                remoteCollectionID: change.collectionID, hostID: hostID,
                deviceID: deviceID, sourceEpoch: sourceEpoch
            ) != nil { continue }
            let matching = try collections().filter {
                Self.syncTagNameKey($0.name) == Self.syncTagNameKey(change.collectionName)
            }
            if matching.count == 1, let local = matching.first {
                let field = "collection.\(local.id.uuidString)"
                guard try scalar(
                    "SELECT operation_id FROM shared_outbox WHERE field=? LIMIT 1", [field]
                ) == nil,
                      try scalar(
                          "SELECT asset_id FROM shared_field_versions WHERE field=? LIMIT 1", [field]
                      ) == nil,
                      try scalar("""
                          SELECT remote_collection_id FROM shared_collection_aliases
                          WHERE host_id=? AND device_id=? AND source_epoch=? AND local_collection_id=?
                          """, [hostID.uuidString, deviceID.uuidString,
                                 sourceEpoch.uuidString, local.id.uuidString]) == nil else {
                    throw LocalLibraryError.syncRemoteCollectionMismatch
                }
                throw LocalLibraryError.syncRemoteCollectionAliasRequired(.init(
                    hostID: hostID, deviceID: deviceID, sourceEpoch: sourceEpoch,
                    scopeRevision: scopeRevision, afterCursor: afterCursor,
                    assetID: change.assetID,
                    remoteCollectionID: change.collectionID,
                    remoteCollectionName: change.collectionName,
                    localCollectionID: local.id, localCollectionName: local.name
                ))
            }
        }
        var applied = 0
        var conflicts = 0
        try transaction {
            for change in changes {
                guard try isShared(assetID: change.assetID) else {
                    throw LocalLibraryError.syncRemoteCollectionMismatch
                }
                let localCollectionID = try localCollectionIdentity(
                    for: change.collectionID, remoteName: change.collectionName,
                    hostID: hostID, deviceID: deviceID, sourceEpoch: sourceEpoch,
                    renamedFrom: change.renamedFrom
                )
                try execute("DELETE FROM private_collection_names WHERE collection_id=?", [localCollectionID.uuidString])
                let field = "collection.\(localCollectionID.uuidString)"
                let value = change.included ? "1" : "0"
                let baseline = Int64(try scalar("""
                    SELECT revision FROM shared_field_versions WHERE asset_id=? AND field=?
                    """, [change.assetID.uuidString, field]) ?? "0") ?? 0
                if let localName = try scalar(
                    "SELECT name FROM collections WHERE id=?", [localCollectionID.uuidString]
                ) {
                    if let oldName = change.renamedFrom {
                        let alias = localCollectionID == change.collectionID ? nil
                            : try collectionAliasRow(
                                remoteCollectionID: change.collectionID,
                                hostID: hostID, deviceID: deviceID,
                                sourceEpoch: sourceEpoch
                            )
                        guard (alias == nil && localCollectionID == change.collectionID
                                   && (localName == oldName || localName == change.collectionName))
                                || (alias != nil && localName == alias?[2]
                                    && (alias?[1] == oldName
                                        || alias?[1] == change.collectionName)) else {
                            throw LocalLibraryError.syncRemoteCollectionMismatch
                        }
                        let needsTransition = alias == nil
                            ? localName == oldName : alias?[1] == oldName
                        if needsTransition {
                            let existingNames = try rows(
                                "SELECT id,name FROM collections"
                            )
                            guard !existingNames.contains(where: {
                                      $0[0] != localCollectionID.uuidString
                                          && Self.syncTagNameKey($0[1] ?? "")
                                              == Self.syncTagNameKey(change.collectionName)
                                  }) else {
                                throw LocalLibraryError.syncRemoteCollectionMismatch
                            }
                            // Upgrade legacy prepared deliveries before an alias
                            // changes. Retries must keep the original wire payload.
                            let legacyPrepared = try rows("""
                                SELECT s.operation_id,s.reference_name,d.state
                                FROM shared_outbox s JOIN shared_delivery d
                                  ON d.operation_id=s.operation_id
                                LEFT JOIN shared_collection_delivery_identity f
                                  ON f.operation_id=s.operation_id
                                LEFT JOIN shared_conflict_details c ON c.operation_id=s.operation_id
                                WHERE s.field=? AND f.operation_id IS NULL
                                  AND (d.state='prepared' OR (d.state='conflict' AND c.reason='collectionIdentity'))
                                """, [field])
                            for pending in legacyPrepared {
                                guard let referenceName = pending[1], referenceName == localName else {
                                    if pending[2] == "prepared" {
                                        throw LocalLibraryError.syncRemoteCollectionMismatch
                                    }
                                    // No original wire identity can be proven for
                                    // this older record; keep it pending for review.
                                    continue
                                }
                                try execute("""
                                    INSERT INTO shared_collection_delivery_identity(
                                      operation_id,local_collection_id,wire_collection_id,wire_name
                                    ) VALUES(?,?,?,?)
                                    """, [pending[0] ?? "", localCollectionID.uuidString,
                                           change.collectionID.uuidString, alias?[1] ?? referenceName])
                            }
                            let recoverable = try rows("""
                                SELECT f.operation_id,f.wire_name,p.current_name,p.source_epoch
                                FROM shared_collection_delivery_identity f
                                JOIN shared_delivery d ON d.operation_id=f.operation_id
                                LEFT JOIN shared_collection_rename_recovery p ON p.operation_id=f.operation_id
                                WHERE f.local_collection_id=? AND f.wire_collection_id=?
                                  AND d.host_id=? AND d.device_id=? AND d.scope_revision=?
                                """, [localCollectionID.uuidString, change.collectionID.uuidString,
                                       hostID.uuidString, deviceID.uuidString, String(scopeRevision)])
                            for pending in recoverable where pending[1] == oldName
                                || (pending[2] == oldName && pending[3] == sourceEpoch.uuidString) {
                                try execute("""
                                    INSERT INTO shared_collection_rename_recovery(
                                      operation_id,source_epoch,current_name,change_sequence
                                    ) VALUES(?,?,?,?)
                                    ON CONFLICT(operation_id) DO UPDATE SET
                                      source_epoch=excluded.source_epoch,current_name=excluded.current_name,
                                      change_sequence=excluded.change_sequence
                                    """, [pending[0] ?? "", sourceEpoch.uuidString,
                                           change.collectionName, String(change.sequence)])
                            }
                            // Unsent intents have no remote receipt yet and can
                            // use the newly acknowledged name when first prepared.
                            try execute("""
                                UPDATE shared_outbox SET reference_name=?
                                WHERE field=? AND reference_name=? AND operation_id NOT IN
                                  (SELECT operation_id FROM shared_delivery)
                                """, [change.collectionName, field, localName])
                            if localName != change.collectionName {
                                // A later rename back to the same text must not revive old undo.
                                try execute("DELETE FROM collection_undo WHERE collection_id=?",
                                            [localCollectionID.uuidString])
                                try execute("UPDATE collections SET name=? WHERE id=?", [
                                    change.collectionName, localCollectionID.uuidString
                                ])
                            }
                            if alias != nil {
                                try execute("""
                                    UPDATE shared_collection_aliases
                                    SET remote_name=?,local_name=?
                                    WHERE host_id=? AND device_id=? AND source_epoch=?
                                      AND remote_collection_id=?
                                    """, [
                                        change.collectionName, change.collectionName,
                                        hostID.uuidString, deviceID.uuidString,
                                        sourceEpoch.uuidString,
                                        change.collectionID.uuidString
                                    ])
                            }
                        }
                    } else {
                        guard localCollectionID != change.collectionID
                                || localName == change.collectionName else {
                            throw LocalLibraryError.syncRemoteCollectionMismatch
                        }
                    }
                } else {
                    let trimmed = change.collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalizedName = Self.syncTagNameKey(trimmed)
                    let existingNames = try rows("SELECT name FROM collections").compactMap { $0[0] }
                    guard change.renamedFrom == nil,
                          baseline == 0, change.fieldRevision == 1, change.included,
                          trimmed == change.collectionName, !trimmed.isEmpty,
                          trimmed.count <= 160, trimmed.utf8.count <= 640,
                          !existingNames.contains(where: {
                              Self.syncTagNameKey($0) == normalizedName
                          }) else {
                        throw LocalLibraryError.syncRemoteCollectionMismatch
                    }
                    // The Mac-created collection identity, first membership and
                    // cursor are installed together without a phone echo.
                    try execute("INSERT INTO collections(id,name) VALUES(?,?)", [
                        change.collectionID.uuidString, trimmed
                    ])
                }
                if change.fieldRevision <= baseline { continue }
                let pending = try rows("""
                    SELECT s.operation_id,s.value,d.state
                    FROM shared_outbox s JOIN outbox o ON o.operation_id=s.operation_id
                    LEFT JOIN shared_delivery d ON d.operation_id=s.operation_id
                    WHERE s.asset_id=? AND s.field=? ORDER BY o.sequence
                    """, [change.assetID.uuidString, field]).first
                if let pending {
                    guard pending[2] != "prepared" else {
                        throw LocalLibraryError.syncEarlierOperationPending
                    }
                    if pending[1] == value, pending[2] == nil {
                        try execute("DELETE FROM shared_outbox WHERE operation_id=?", [pending[0] ?? ""])
                        applied += 1
                    } else {
                        try execute("""
                            INSERT INTO shared_delivery(
                              operation_id,host_id,device_id,base_revision,scope_revision,
                              state,conflict_revision,conflict_value
                            ) VALUES(?,?,?,?,?,'conflict',?,?)
                            ON CONFLICT(operation_id) DO UPDATE SET
                              state='conflict',conflict_revision=excluded.conflict_revision,
                              conflict_value=excluded.conflict_value
                            """, [
                                pending[0] ?? "", hostID.uuidString, deviceID.uuidString,
                                String(baseline), String(scopeRevision),
                                String(change.fieldRevision), value
                            ])
                        try execute("""
                            INSERT INTO shared_conflict_details(operation_id,reason)
                            VALUES(?,'fieldVersion')
                            ON CONFLICT(operation_id) DO UPDATE SET reason=excluded.reason
                            """, [pending[0] ?? ""])
                        conflicts += 1
                    }
                } else {
                    let current = try scalar("""
                        SELECT included FROM memberships WHERE asset_id=? AND collection_id=?
                        """, [change.assetID.uuidString, localCollectionID.uuidString])
                    if current != value {
                        try execute("""
                            INSERT INTO memberships(collection_id,asset_id,included,revision)
                            VALUES(?,?,?,1) ON CONFLICT(collection_id,asset_id) DO UPDATE SET
                              included=excluded.included,revision=revision+1
                            """, [localCollectionID.uuidString, change.assetID.uuidString, value])
                        _ = try enqueue(change.assetID, field: field, value: value, origin: .remoteSync)
                    }
                    applied += 1
                }
                try execute("""
                    INSERT INTO shared_field_versions(asset_id,field,revision) VALUES(?,?,?)
                    ON CONFLICT(asset_id,field) DO UPDATE SET
                      revision=MAX(revision,excluded.revision)
                    """, [change.assetID.uuidString, field, String(change.fieldRevision)])
            }
            try execute("UPDATE identity SET value=? WHERE key='sync_collection_change_cursor'", [
                String(nextCursor)
            ])
        }
        return LocalSharedCollectionPullResult(
            applied: applied, conflicts: conflicts, nextCursor: nextCursor
        )
    }

    public func sharedFavoriteChangeCursor() throws -> Int64 {
        Int64(try requiredIdentity("sync_favorite_change_cursor")) ?? 0
    }

    /// A Mac target and its cursor commit together. This changes ImageAll's
    /// desired value and writeback state, but never invokes PhotoKit.
    public func applySharedFavoriteChanges(
        hostID: UUID, deviceID: UUID, sourceEpoch: UUID,
        scopeRevision: Int64, afterCursor: Int64,
        changes: [LocalSharedFavoriteChange], nextCursor: Int64
    ) throws -> LocalSharedFavoritePullResult {
        guard try requiredIdentity("sync_host_id") == hostID.uuidString,
              try requiredIdentity("sync_device_id") == deviceID.uuidString,
              try requiredIdentity("source_epoch") == sourceEpoch.uuidString,
              Int64(try requiredIdentity("share_scope_revision")) == scopeRevision,
              Int64(try requiredIdentity("sync_ack_scope_revision")) == scopeRevision,
              try sharedFavoriteChangeCursor() == afterCursor,
              nextCursor >= afterCursor,
              changes.allSatisfy({
                  $0.sequence > afterCursor && $0.sequence <= nextCursor && $0.fieldRevision > 0
              }),
              zip(changes, changes.dropFirst()).allSatisfy({ $0.0.sequence < $0.1.sequence }) else {
            throw LocalLibraryError.syncIdentityChanged
        }
        var applied = 0
        var conflicts = 0
        try transaction {
            for change in changes {
                guard try isShared(assetID: change.assetID),
                      try exists("assets", id: change.assetID) else {
                    throw LocalLibraryError.unknownAsset
                }
                let value = change.target ? "1" : "0"
                let baseline = Int64(try scalar("""
                    SELECT revision FROM shared_field_versions
                    WHERE asset_id=? AND field='favorite.target'
                    """, [change.assetID.uuidString]) ?? "0") ?? 0
                if change.fieldRevision <= baseline { continue }
                let pending = try rows("""
                    SELECT s.operation_id,s.value,d.state
                    FROM shared_outbox s JOIN outbox o ON o.operation_id=s.operation_id
                    LEFT JOIN shared_delivery d ON d.operation_id=s.operation_id
                    WHERE s.asset_id=? AND s.field='favorite.target' ORDER BY o.sequence
                    """, [change.assetID.uuidString]).first
                if let pending {
                    guard pending[2] != "prepared" else {
                        throw LocalLibraryError.syncEarlierOperationPending
                    }
                    if pending[1] == value, pending[2] == nil {
                        try execute("DELETE FROM shared_outbox WHERE operation_id=?", [
                            pending[0] ?? ""
                        ])
                        applied += 1
                    } else {
                        try execute("""
                            INSERT INTO shared_delivery(
                              operation_id,host_id,device_id,base_revision,scope_revision,
                              state,conflict_revision,conflict_value
                            ) VALUES(?,?,?,?,?,'conflict',?,?)
                            ON CONFLICT(operation_id) DO UPDATE SET
                              state='conflict',conflict_revision=excluded.conflict_revision,
                              conflict_value=excluded.conflict_value
                            """, [
                                pending[0] ?? "", hostID.uuidString, deviceID.uuidString,
                                String(baseline), String(scopeRevision),
                                String(change.fieldRevision), value
                            ])
                        try execute("""
                            INSERT INTO shared_conflict_details(operation_id,reason)
                            VALUES(?,'fieldVersion')
                            ON CONFLICT(operation_id) DO UPDATE SET reason=excluded.reason
                            """, [pending[0] ?? ""])
                        conflicts += 1
                    }
                } else {
                    let current = try scalar("""
                        SELECT favorite_target FROM assets WHERE id=?
                        """, [change.assetID.uuidString])
                    if current != value {
                        try execute("UPDATE assets SET favorite_target=? WHERE id=?", [
                            value, change.assetID.uuidString
                        ])
                        try execute("""
                            INSERT INTO favorite_writebacks(asset_id,target,state)
                            VALUES(?,?,CASE WHEN (
                              SELECT observed_favorite FROM assets WHERE id=?
                            )=? THEN 'matched' ELSE 'pending' END)
                            ON CONFLICT(asset_id) DO UPDATE SET
                              target=excluded.target,state=excluded.state
                            """, [change.assetID.uuidString, value, change.assetID.uuidString, value])
                        _ = try enqueue(change.assetID, field: "favorite.target", value: value, origin: .remoteSync)
                    }
                    applied += 1
                }
                try execute("""
                    INSERT INTO shared_field_versions(asset_id,field,revision)
                    VALUES(?,'favorite.target',?)
                    ON CONFLICT(asset_id,field) DO UPDATE SET
                      revision=MAX(revision,excluded.revision)
                    """, [change.assetID.uuidString, String(change.fieldRevision)])
            }
            try execute("UPDATE identity SET value=? WHERE key='sync_favorite_change_cursor'", [
                String(nextCursor)
            ])
        }
        return LocalSharedFavoritePullResult(
            applied: applied, conflicts: conflicts, nextCursor: nextCursor
        )
    }

    private func bindSyncIdentity(hostID: UUID, deviceID: UUID) throws {
        let savedHost = try requiredIdentity("sync_host_id")
        let savedDevice = try requiredIdentity("sync_device_id")
        guard savedHost.isEmpty || savedHost == hostID.uuidString,
              savedDevice.isEmpty || savedDevice == deviceID.uuidString else {
            throw LocalLibraryError.syncIdentityChanged
        }
        try execute("UPDATE identity SET value=? WHERE key='sync_host_id'", [hostID.uuidString])
        try execute("UPDATE identity SET value=? WHERE key='sync_device_id'", [deviceID.uuidString])
    }

    private func aliasRow(
        remoteTagID: UUID, hostID: UUID, deviceID: UUID, sourceEpoch: UUID
    ) throws -> [String?]? {
        try rows("""
            SELECT local_tag_id,remote_name,local_name FROM shared_tag_aliases
            WHERE host_id=? AND device_id=? AND source_epoch=? AND remote_tag_id=?
            """, [hostID.uuidString, deviceID.uuidString,
                   sourceEpoch.uuidString, remoteTagID.uuidString]).first
    }

    private func localTagIdentity(
        for remoteTagID: UUID, remoteName: String,
        hostID: UUID, deviceID: UUID, sourceEpoch: UUID
    ) throws -> UUID {
        guard let alias = try aliasRow(
            remoteTagID: remoteTagID, hostID: hostID,
            deviceID: deviceID, sourceEpoch: sourceEpoch
        ) else { return remoteTagID }
        guard let localID = UUID(uuidString: alias[0] ?? ""),
              alias[1] == remoteName,
              try scalar("SELECT name FROM tags WHERE id=?", [localID.uuidString]) == alias[2]
        else { throw LocalLibraryError.syncRemoteTagMismatch }
        return localID
    }

    private func wireTagIdentity(for localTagID: UUID, localName: String) throws -> (id: UUID, name: String) {
        let host = try requiredIdentity("sync_host_id")
        let device = try requiredIdentity("sync_device_id")
        let epoch = try requiredIdentity("source_epoch")
        guard !host.isEmpty, !device.isEmpty,
              let row = try rows("""
                  SELECT remote_tag_id,remote_name,local_name FROM shared_tag_aliases
                  WHERE host_id=? AND device_id=? AND source_epoch=? AND local_tag_id=?
                  """, [host, device, epoch, localTagID.uuidString]).first
        else { return (localTagID, localName) }
        guard row[2] == localName, let remoteID = UUID(uuidString: row[0] ?? ""),
              let remoteName = row[1] else {
            throw LocalLibraryError.syncRemoteTagMismatch
        }
        return (remoteID, remoteName)
    }

    private func collectionAliasRow(
        remoteCollectionID: UUID, hostID: UUID, deviceID: UUID, sourceEpoch: UUID
    ) throws -> [String?]? {
        try rows("""
            SELECT local_collection_id,remote_name,local_name FROM shared_collection_aliases
            WHERE host_id=? AND device_id=? AND source_epoch=? AND remote_collection_id=?
            """, [hostID.uuidString, deviceID.uuidString,
                   sourceEpoch.uuidString, remoteCollectionID.uuidString]).first
    }

    private func localCollectionIdentity(
        for remoteCollectionID: UUID, remoteName: String,
        hostID: UUID, deviceID: UUID, sourceEpoch: UUID,
        renamedFrom: String? = nil
    ) throws -> UUID {
        guard let alias = try collectionAliasRow(
            remoteCollectionID: remoteCollectionID, hostID: hostID,
            deviceID: deviceID, sourceEpoch: sourceEpoch
        ) else { return remoteCollectionID }
        guard let localID = UUID(uuidString: alias[0] ?? ""),
              (alias[1] == remoteName || alias[1] == renamedFrom),
              try scalar("SELECT name FROM collections WHERE id=?", [localID.uuidString]) == alias[2]
        else { throw LocalLibraryError.syncRemoteCollectionMismatch }
        return localID
    }

    private func wireCollectionIdentity(
        for localCollectionID: UUID, localName: String
    ) throws -> (id: UUID, name: String) {
        let host = try requiredIdentity("sync_host_id")
        let device = try requiredIdentity("sync_device_id")
        let epoch = try requiredIdentity("source_epoch")
        guard !host.isEmpty, !device.isEmpty,
              let row = try rows("""
                  SELECT remote_collection_id,remote_name,local_name FROM shared_collection_aliases
                  WHERE host_id=? AND device_id=? AND source_epoch=? AND local_collection_id=?
                  """, [host, device, epoch, localCollectionID.uuidString]).first
        else { return (localCollectionID, localName) }
        guard row[2] == localName, let remoteID = UUID(uuidString: row[0] ?? ""),
              let remoteName = row[1] else {
            throw LocalLibraryError.syncRemoteCollectionMismatch
        }
        return (remoteID, remoteName)
    }

    private func requiredIdentity(_ key: String) throws -> String {
        guard let value = try scalar("SELECT value FROM identity WHERE key=?", [key]) else {
            throw LocalLibraryError.database("missing identity")
        }
        return value
    }

    private static func syncTagNameKey(_ rawName: String) -> String {
        let scalars = Array(rawName.precomposedStringWithCanonicalMapping.unicodeScalars)
        var normalized: [Unicode.Scalar] = []
        var inWhiteSpace = false
        for scalar in scalars {
            if scalar.properties.isWhitespace {
                if !inWhiteSpace {
                    normalized.append(Unicode.Scalar(0x20)!)
                    inWhiteSpace = true
                }
            } else {
                normalized.append(scalar)
                inWhiteSpace = false
            }
        }
        return String(String.UnicodeScalarView(normalized))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .caseInsensitive, locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    private func exists(_ table: String, id: UUID) throws -> Bool {
        try scalar("SELECT id FROM \(table) WHERE id=?", [id.uuidString]) != nil
    }

    @discardableResult
    private func enqueue(_ entityID: UUID, field: String, value: String, origin: LocalAuditOrigin) throws -> UUID {
        let operationID = UUID()
        try execute("INSERT INTO outbox(operation_id,entity_id,field,value,created_time) VALUES(?,?,?,?,?)", [
            operationID.uuidString, entityID.uuidString, field, value, String(Date().timeIntervalSince1970)
        ])
        // Capture the display name at the event, before later rename or alias changes.
        let referenceName: String?
        if field.hasPrefix("tag."), let id = UUID(uuidString: String(field.dropFirst(4))) {
            referenceName = try scalar("SELECT name FROM tags WHERE id=?", [id.uuidString])
        } else if field.hasPrefix("collection."), let id = UUID(uuidString: String(field.dropFirst(11))) {
            referenceName = try scalar("SELECT name FROM collections WHERE id=?", [id.uuidString])
        } else {
            referenceName = nil
        }
        try execute("INSERT INTO audit_context(operation_id,origin,reference_name) VALUES(?,?,NULLIF(?,''))", [
            operationID.uuidString, origin.rawValue, referenceName ?? ""
        ])
        return operationID
    }

    private func enqueueShared(
        _ operationID: UUID, assetID: UUID, field: String,
        value: String, referenceName: String?
    ) throws {
        let scopeRevision = try requiredIdentity("share_scope_revision")
        try execute("""
            INSERT INTO shared_outbox(operation_id,asset_id,field,value,reference_name,scope_revision)
            VALUES(?,?,?,?,?,?)
            """, [
                operationID.uuidString, assetID.uuidString, field, value,
                referenceName ?? "", scopeRevision
            ])
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func scalar(_ sql: String, _ bindings: [String] = []) throws -> String? {
        try rows(sql, bindings).first?.first ?? nil
    }

    private func execute(_ sql: String, _ bindings: [String] = []) throws {
        try withStatement(sql, bindings) { statement in
            let status = sqlite3_step(statement)
            guard status == SQLITE_DONE || status == SQLITE_ROW else {
                throw LocalLibraryError.database(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func rows(_ sql: String, _ bindings: [String] = []) throws -> [[String?]] {
        try withStatement(sql, bindings) { statement in
            var output: [[String?]] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return output }
                guard status == SQLITE_ROW else {
                    throw LocalLibraryError.database(String(cString: sqlite3_errmsg(db)))
                }
                output.append((0..<sqlite3_column_count(statement)).map { index in
                    guard let text = sqlite3_column_text(statement, index) else { return nil }
                    return String(cString: text)
                })
            }
        }
    }

    private func withStatement<T>(
        _ sql: String, _ bindings: [String], _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LocalLibraryError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            let status = value.withCString { pointer in
                sqlite3_bind_text(statement, Int32(index + 1), pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard status == SQLITE_OK else {
                throw LocalLibraryError.database(String(cString: sqlite3_errmsg(db)))
            }
        }
        return try body(statement)
    }
}
