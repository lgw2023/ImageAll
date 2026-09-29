import CryptoKit
import Foundation

public extension RemoteHTTPPaths {
    static let localLibrarySnapshot = "/v1/sync/local-library/snapshot"
    static let localLibrarySnapshotReceipt = "/v1/sync/local-library/snapshot-receipt"
    static let localLibraryTagDecision = "/v1/sync/local-library/tag-decision"
    static let localLibraryTagChanges = "/v1/sync/local-library/tag-changes"
    static let localLibraryCollectionMembership = "/v1/sync/local-library/collection-membership"
    static let localLibraryCollectionChanges = "/v1/sync/local-library/collection-changes"
    static let localLibraryFavoriteTarget = "/v1/sync/local-library/favorite-target"
    static let localLibraryFavoriteChanges = "/v1/sync/local-library/favorite-changes"
}

public struct RemoteLocalLibraryFavoriteChange: Codable, Sendable, Equatable {
    public let sequence: Int64
    public let scopeRevision: Int64
    public let assetID: UUID
    public let target: Bool
    public let fieldRevision: Int64

    public init(
        sequence: Int64, scopeRevision: Int64, assetID: UUID,
        target: Bool, fieldRevision: Int64
    ) {
        self.sequence = sequence
        self.scopeRevision = scopeRevision
        self.assetID = assetID
        self.target = target
        self.fieldRevision = fieldRevision
    }
}

public struct RemoteLocalLibraryFavoriteChangesPage: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let changes: [RemoteLocalLibraryFavoriteChange]
    public let nextCursor: Int64
    public let hasMore: Bool

    public init(
        hostID: UUID, deviceID: UUID, sourceEpoch: UUID,
        scopeRevision: Int64, changes: [RemoteLocalLibraryFavoriteChange],
        nextCursor: Int64, hasMore: Bool
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.changes = changes
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct RemoteLocalLibraryCollectionChange: Codable, Sendable, Equatable {
    public let sequence: Int64
    public let scopeRevision: Int64
    public let assetID: UUID
    public let collectionID: UUID
    public let collectionName: String
    public let included: Bool
    public let fieldRevision: Int64
    /// Set only on the first change that creates a Mac-owned collection.
    /// Older changes decode as nil and retain their existing meaning.
    public let createdCollectionID: UUID?
    /// An explicit collection name transition. Its sequence advances while
    /// the member field revision stays unchanged.
    public let renamedFrom: String?

    public init(
        sequence: Int64, scopeRevision: Int64, assetID: UUID,
        collectionID: UUID, collectionName: String,
        included: Bool, fieldRevision: Int64,
        createdCollectionID: UUID? = nil, renamedFrom: String? = nil
    ) {
        self.sequence = sequence
        self.scopeRevision = scopeRevision
        self.assetID = assetID
        self.collectionID = collectionID
        self.collectionName = collectionName
        self.included = included
        self.fieldRevision = fieldRevision
        self.createdCollectionID = createdCollectionID
        self.renamedFrom = renamedFrom
    }
}

public struct RemoteLocalLibraryCollectionChangesPage: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let changes: [RemoteLocalLibraryCollectionChange]
    public let nextCursor: Int64
    public let hasMore: Bool

    public init(
        hostID: UUID, deviceID: UUID, sourceEpoch: UUID,
        scopeRevision: Int64, changes: [RemoteLocalLibraryCollectionChange],
        nextCursor: Int64, hasMore: Bool
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.changes = changes
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct RemoteLocalLibraryTagChange: Codable, Sendable, Equatable {
    public let sequence: Int64
    public let scopeRevision: Int64
    public let assetID: UUID
    public let tagID: UUID
    public let tagName: String
    public let decision: RemoteLocalLibraryDecision
    public let fieldRevision: Int64

    public init(
        sequence: Int64, scopeRevision: Int64,
        assetID: UUID, tagID: UUID, tagName: String,
        decision: RemoteLocalLibraryDecision, fieldRevision: Int64
    ) {
        self.sequence = sequence
        self.scopeRevision = scopeRevision
        self.assetID = assetID
        self.tagID = tagID
        self.tagName = tagName
        self.decision = decision
        self.fieldRevision = fieldRevision
    }
}

public struct RemoteLocalLibraryTagChangesPage: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let changes: [RemoteLocalLibraryTagChange]
    public let nextCursor: Int64
    public let hasMore: Bool

    public init(
        hostID: UUID, deviceID: UUID, sourceEpoch: UUID, scopeRevision: Int64,
        changes: [RemoteLocalLibraryTagChange], nextCursor: Int64, hasMore: Bool
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.changes = changes
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

/// One bounded, explicitly selected directory/fact snapshot. The authenticated Host derives
/// the device ID from the access token; a client-supplied device ID is never trusted.
public struct RemoteLocalLibrarySnapshotRequest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let hostID: UUID
    public let installID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let snapshotSequence: Int64
    public let selectedAssetIDs: [UUID]
    public let assets: [RemoteLocalLibraryAsset]

    public init(
        hostID: UUID,
        installID: UUID,
        sourceEpoch: UUID,
        scopeRevision: Int64,
        snapshotSequence: Int64,
        selectedAssetIDs: [UUID],
        assets: [RemoteLocalLibraryAsset]
    ) {
        self.schemaVersion = 1
        self.hostID = hostID
        self.installID = installID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.snapshotSequence = snapshotSequence
        self.selectedAssetIDs = selectedAssetIDs
        self.assets = assets
    }
}

public struct RemoteLocalLibraryAsset: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let localIdentifier: String
    public let mediaKind: RemoteAssetMediaKind
    public let createdAtMs: Int64?
    public let observedFavorite: Bool
    public let favoriteTarget: Bool?
    public let tagDecisions: [RemoteLocalLibraryTagDecision]
    public let collections: [RemoteLocalLibraryCollection]

    public init(
        id: UUID,
        localIdentifier: String,
        mediaKind: RemoteAssetMediaKind,
        createdAtMs: Int64?,
        observedFavorite: Bool,
        favoriteTarget: Bool?,
        tagDecisions: [RemoteLocalLibraryTagDecision],
        collections: [RemoteLocalLibraryCollection]
    ) {
        self.id = id
        self.localIdentifier = localIdentifier
        self.mediaKind = mediaKind
        self.createdAtMs = createdAtMs
        self.observedFavorite = observedFavorite
        self.favoriteTarget = favoriteTarget
        self.tagDecisions = tagDecisions
        self.collections = collections
    }
}

public enum RemoteLocalLibraryDecision: String, Codable, Sendable, Equatable {
    case accepted, rejected, cleared
}

public struct RemoteLocalLibraryTagDecision: Codable, Sendable, Equatable {
    public let tagID: UUID
    public let tagName: String
    public let decision: RemoteLocalLibraryDecision

    public init(tagID: UUID, tagName: String, decision: RemoteLocalLibraryDecision) {
        self.tagID = tagID
        self.tagName = tagName
        self.decision = decision
    }
}

public struct RemoteLocalLibraryCollection: Codable, Sendable, Equatable {
    public let collectionID: UUID
    public let collectionName: String

    public init(collectionID: UUID, collectionName: String) {
        self.collectionID = collectionID
        self.collectionName = collectionName
    }
}

public struct RemoteLocalLibrarySnapshotReceipt: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let sourceEpoch: UUID
    public let snapshotSequence: Int64
    public let acceptedAssetCount: Int
    public let replayed: Bool
    /// Assets whose tag facts were first bound to the Mac shared-fact ledger by this snapshot.
    /// Missing on older Hosts; clients must not infer this list from acceptedAssetCount.
    public let importedAssetIDs: [UUID]?

    public init(
        hostID: UUID,
        deviceID: UUID,
        sourceEpoch: UUID,
        snapshotSequence: Int64,
        acceptedAssetCount: Int,
        replayed: Bool,
        importedAssetIDs: [UUID]? = nil
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.sourceEpoch = sourceEpoch
        self.snapshotSequence = snapshotSequence
        self.acceptedAssetCount = acceptedAssetCount
        self.replayed = replayed
        self.importedAssetIDs = importedAssetIDs
    }
}

/// Queries only the receipt for the exact frozen request. The request contains
/// no previously visible asset metadata, so it remains safe after permission shrinks.
public struct RemoteLocalLibrarySnapshotReceiptLookup: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let installID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let snapshotSequence: Int64
    public let requestSHA256: String

    public init(request: RemoteLocalLibrarySnapshotRequest) throws {
        hostID = request.hostID
        installID = request.installID
        sourceEpoch = request.sourceEpoch
        scopeRevision = request.scopeRevision
        snapshotSequence = request.snapshotSequence
        requestSHA256 = try request.canonicalSHA256()
    }
}

public struct RemoteLocalLibrarySnapshotReceiptLookupResult: Codable, Sendable, Equatable {
    public let receipt: RemoteLocalLibrarySnapshotReceipt?

    public init(receipt: RemoteLocalLibrarySnapshotReceipt?) {
        self.receipt = receipt
    }
}

public extension RemoteLocalLibrarySnapshotRequest {
    func canonicalSHA256() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(self)))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// A single versioned decision on an explicitly shared iPhone asset. The authenticated
/// device is derived from its token; deviceSequence is its durable local outbox sequence.
public struct RemoteLocalLibraryTagDecisionRequest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let hostID: UUID
    public let installID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let operationID: UUID
    public let deviceSequence: Int64
    public let assetID: UUID
    public let tagID: UUID
    public let tagName: String
    public let decision: RemoteLocalLibraryDecision
    public let baseRevision: Int64

    public init(
        hostID: UUID, installID: UUID, sourceEpoch: UUID,
        scopeRevision: Int64, operationID: UUID, deviceSequence: Int64,
        assetID: UUID, tagID: UUID, tagName: String,
        decision: RemoteLocalLibraryDecision, baseRevision: Int64
    ) {
        self.schemaVersion = 1
        self.hostID = hostID
        self.installID = installID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.operationID = operationID
        self.deviceSequence = deviceSequence
        self.assetID = assetID
        self.tagID = tagID
        self.tagName = tagName
        self.decision = decision
        self.baseRevision = baseRevision
    }
}

public enum RemoteLocalLibraryTagDecisionDisposition: String, Codable, Sendable, Equatable {
    case applied, unchanged, conflict
}

public enum RemoteLocalLibraryTagConflictReason: String, Codable, Sendable, Equatable {
    case fieldVersion
    case tagIdentity
    case nameAlias
}

public struct RemoteLocalLibraryTagDecisionReceipt: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let operationID: UUID
    public let disposition: RemoteLocalLibraryTagDecisionDisposition
    public let fieldRevision: Int64
    public let currentDecision: RemoteLocalLibraryDecision?
    public let replayed: Bool
    /// Absent on older Hosts; a client must leave that conflict unresolved.
    public let conflictReason: RemoteLocalLibraryTagConflictReason?

    public init(
        hostID: UUID, deviceID: UUID, operationID: UUID,
        disposition: RemoteLocalLibraryTagDecisionDisposition,
        fieldRevision: Int64, currentDecision: RemoteLocalLibraryDecision?, replayed: Bool,
        conflictReason: RemoteLocalLibraryTagConflictReason? = nil
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.operationID = operationID
        self.disposition = disposition
        self.fieldRevision = fieldRevision
        self.currentDecision = currentDecision
        self.replayed = replayed
        self.conflictReason = conflictReason
    }
}

/// A membership is an independent versioned field. `included=false` is an explicit
/// removal, not an omitted item in a PhotoKit directory snapshot.
public struct RemoteLocalLibraryCollectionMembershipRequest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let hostID: UUID
    public let installID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let operationID: UUID
    public let deviceSequence: Int64
    public let assetID: UUID
    public let collectionID: UUID
    public let collectionName: String
    public let included: Bool
    public let baseRevision: Int64

    public init(
        hostID: UUID, installID: UUID, sourceEpoch: UUID,
        scopeRevision: Int64, operationID: UUID, deviceSequence: Int64,
        assetID: UUID, collectionID: UUID, collectionName: String,
        included: Bool, baseRevision: Int64
    ) {
        self.schemaVersion = 1
        self.hostID = hostID
        self.installID = installID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.operationID = operationID
        self.deviceSequence = deviceSequence
        self.assetID = assetID
        self.collectionID = collectionID
        self.collectionName = collectionName
        self.included = included
        self.baseRevision = baseRevision
    }
}

public enum RemoteLocalLibraryCollectionConflictReason: String, Codable, Sendable, Equatable {
    case fieldVersion, collectionIdentity, nameAlias
}

public struct RemoteLocalLibraryCollectionMembershipReceipt: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let operationID: UUID
    public let disposition: RemoteLocalLibraryTagDecisionDisposition
    public let fieldRevision: Int64
    public let currentIncluded: Bool?
    public let replayed: Bool
    public let conflictReason: RemoteLocalLibraryCollectionConflictReason?

    public init(
        hostID: UUID, deviceID: UUID, operationID: UUID,
        disposition: RemoteLocalLibraryTagDecisionDisposition,
        fieldRevision: Int64, currentIncluded: Bool?, replayed: Bool,
        conflictReason: RemoteLocalLibraryCollectionConflictReason? = nil
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.operationID = operationID
        self.disposition = disposition
        self.fieldRevision = fieldRevision
        self.currentIncluded = currentIncluded
        self.replayed = replayed
        self.conflictReason = conflictReason
    }
}

/// ImageAll's desired favorite is a shared human fact. It is distinct from the
/// source PhotoKit observation and its writeback result.
public struct RemoteLocalLibraryFavoriteTargetRequest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let hostID: UUID
    public let installID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let operationID: UUID
    public let deviceSequence: Int64
    public let assetID: UUID
    public let target: Bool
    public let baseRevision: Int64

    public init(
        hostID: UUID, installID: UUID, sourceEpoch: UUID,
        scopeRevision: Int64, operationID: UUID, deviceSequence: Int64,
        assetID: UUID, target: Bool, baseRevision: Int64
    ) {
        self.schemaVersion = 1
        self.hostID = hostID
        self.installID = installID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.operationID = operationID
        self.deviceSequence = deviceSequence
        self.assetID = assetID
        self.target = target
        self.baseRevision = baseRevision
    }
}

public struct RemoteLocalLibraryFavoriteTargetReceipt: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let operationID: UUID
    public let disposition: RemoteLocalLibraryTagDecisionDisposition
    public let fieldRevision: Int64
    public let currentTarget: Bool?
    public let replayed: Bool

    public init(
        hostID: UUID, deviceID: UUID, operationID: UUID,
        disposition: RemoteLocalLibraryTagDecisionDisposition,
        fieldRevision: Int64, currentTarget: Bool?, replayed: Bool
    ) {
        self.hostID = hostID
        self.deviceID = deviceID
        self.operationID = operationID
        self.disposition = disposition
        self.fieldRevision = fieldRevision
        self.currentTarget = currentTarget
        self.replayed = replayed
    }
}


extension RemoteHTTPPaths {
    public static let phoneCleanupCopyAudit = "/v1/sync/local-library/cleanup-copy-audit"
    public static let phoneCleanupSourceReport = "/v1/sync/local-library/cleanup-source-report"
    public static let phoneCleanupRecheck = "/v1/sync/local-library/cleanup-recheck"
}

/// A request to recheck a source scope, never permission to delete it.
public struct RemotePhoneCleanupRecheck: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let hostID: UUID
    public let deviceID: UUID
    public let migrationID: UUID
    public let sourceInstallID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let manifestSHA256: String
    public let completionReceiptID: UUID
    public let backupReceiptID: UUID
    public let candidateCount: Int
    public let favoriteProtectedCount: Int
    public let createdAtMs: Int64
    public let factSnapshotSHA256: String?

    public init(id: UUID, hostID: UUID, deviceID: UUID, migrationID: UUID,
        sourceInstallID: UUID, sourceEpoch: UUID, scopeRevision: Int64, manifestSHA256: String,
        completionReceiptID: UUID, backupReceiptID: UUID, candidateCount: Int,
        favoriteProtectedCount: Int, createdAtMs: Int64, factSnapshotSHA256: String? = nil) {
        self.id = id; self.hostID = hostID; self.deviceID = deviceID; self.migrationID = migrationID
        self.sourceInstallID = sourceInstallID; self.sourceEpoch = sourceEpoch; self.scopeRevision = scopeRevision
        self.manifestSHA256 = manifestSHA256; self.completionReceiptID = completionReceiptID
        self.backupReceiptID = backupReceiptID; self.candidateCount = candidateCount
        self.favoriteProtectedCount = favoriteProtectedCount; self.createdAtMs = createdAtMs
        self.factSnapshotSHA256 = factSnapshotSHA256
    }

    public var isValid: Bool {
        (factSnapshotSHA256.map { $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } } ?? true)
            && scopeRevision >= 0 && createdAtMs >= 0 && candidateCount >= 0 && favoriteProtectedCount >= 0
            && candidateCount <= 1_000_000 && favoriteProtectedCount <= 1_000_000
            && manifestSHA256.count == 64 && manifestSHA256.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

public struct RemotePhoneCleanupInbox: Codable, Sendable, Equatable {
    public let hostID: UUID
    public let deviceID: UUID
    public let request: RemotePhoneCleanupRecheck?
    public let sourceReport: RemotePhoneCleanupSourceReport?
    public init(hostID: UUID, deviceID: UUID, request: RemotePhoneCleanupRecheck?,
        sourceReport: RemotePhoneCleanupSourceReport? = nil) {
        self.hostID = hostID; self.deviceID = deviceID; self.request = request
        self.sourceReport = sourceReport
    }
}

/// A phone's historical observation, never a deletion capability or proof of current backups.
public struct RemotePhoneCleanupSourceReport: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let request: RemotePhoneCleanupRecheck
    public let checkedAtMs: Int64
    public let verifiedItemCount: Int

    public init(id: UUID, request: RemotePhoneCleanupRecheck, checkedAtMs: Int64, verifiedItemCount: Int) {
        self.id = id; self.request = request; self.checkedAtMs = checkedAtMs
        self.verifiedItemCount = verifiedItemCount
    }

    public var isValid: Bool {
        request.isValid && request.factSnapshotSHA256 != nil && checkedAtMs >= 0
            && verifiedItemCount == request.candidateCount + request.favoriteProtectedCount
    }
}


extension RemotePhoneCleanupRecheck {
    public static func factDigest(_ snapshot: ImageAllMigrationFactSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(snapshot)).map { String(format: "%02x", $0) }.joined()
    }

    /// Binds both the media manifest and the exact fact checkpoint audited on
    /// Mac. Legacy count-only requests may be displayed but cannot pass this gate.
    public func validateSourceEvidence(header: ImageAllMigrationHeader, items: [ImageAllMigrationItem],
        archivedFacts: ImageAllMigrationFactSnapshot, currentFacts: ImageAllMigrationFactSnapshot? = nil
    ) throws {
        try ImageAllMigrationFacts.validate(archivedFacts)
        if let currentFacts { try ImageAllMigrationFacts.validate(currentFacts) }
        let protected = archivedFacts.items.filter { $0.observedFavorite || $0.favoriteTarget == true }.count
        guard isValid, let factSnapshotSHA256,
              header.migrationID == migrationID, header.sourceDeviceID == sourceInstallID,
              header.sourceEpoch == sourceEpoch, header.scopeRevision == scopeRevision,
              header.appleAlbumCoverage == .selectedAssetsOnly,
              header.declaredItemCount == items.count,
              manifestSHA256 == (try ImageAllMigrationStreamRecord.manifestSHA256(header: header, items: items)),
              factSnapshotSHA256 == (try Self.factDigest(archivedFacts)),
              archivedFacts.sourceDeviceID == sourceInstallID, archivedFacts.sourceEpoch == sourceEpoch,
              archivedFacts.scopeRevision == scopeRevision,
              let bound = archivedFacts.syncCheckpoint, bound.hostID == hostID, bound.deviceID == deviceID,
              bound.archiveManifestSHA256 == manifestSHA256, bound.sourceVerifiedAtMs != nil,
              Set(items.map(\.mediaID)).count == items.count,
              Set(archivedFacts.items.map(\.mediaID)) == Set(items.map(\.mediaID)),
              archivedFacts.items.count == items.count,
              favoriteProtectedCount == protected, candidateCount == items.count - protected else {
            throw RemoteAPIError(code: .conflict, message: "核对请求与本机归档或整理信息不一致，请在 Mac 重新预检并发送请求")
        }
        if let currentFacts {
            guard currentFacts.sourceDeviceID == sourceInstallID, currentFacts.sourceEpoch == sourceEpoch,
                  currentFacts.scopeRevision == scopeRevision, currentFacts.items == archivedFacts.items,
                  currentFacts.factWatermark == archivedFacts.factWatermark,
                  currentFacts.auditRecords == archivedFacts.auditRecords,
                  let current = currentFacts.syncCheckpoint,
                  current.hostID == bound.hostID, current.deviceID == bound.deviceID,
                  current.acknowledgedScopeRevision == bound.acknowledgedScopeRevision,
                  current.acknowledgedSnapshotSequence == bound.acknowledgedSnapshotSequence,
                  current.tagChangeCursor == bound.tagChangeCursor,
                  current.collectionChangeCursor == bound.collectionChangeCursor,
                  current.favoriteChangeCursor == bound.favoriteChangeCursor,
                  current.tagAliases == bound.tagAliases, current.collectionAliases == bound.collectionAliases,
                  current.archiveManifestSHA256 == manifestSHA256, current.sourceVerifiedAtMs != nil else {
                throw RemoteAPIError(code: .conflict, message: "手机整理信息、收藏或同步状态已变化，请先同步并更新归档与备份")
            }
        }
    }
}

/// A fresh challenge for a read-only Mac copy audit, not an execution permit.
public struct RemotePhoneCopyAuditRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceReport: RemotePhoneCleanupSourceReport
    public init(id: UUID, sourceReport: RemotePhoneCleanupSourceReport) {
        self.id = id; self.sourceReport = sourceReport
    }
}

public enum RemotePhoneCopyAuditState: String, Codable, Sendable { case running, passed, failed }

public struct RemotePhoneCopyAudit: Codable, Sendable, Equatable {
    public let request: RemotePhoneCopyAuditRequest
    public let state: RemotePhoneCopyAuditState
    public let checkedAtMs: Int64?
    public init(request: RemotePhoneCopyAuditRequest, state: RemotePhoneCopyAuditState, checkedAtMs: Int64? = nil) {
        self.request = request; self.state = state; self.checkedAtMs = checkedAtMs
    }
    public var isValid: Bool {
        request.sourceReport.isValid && (state == .passed ? (checkedAtMs.map { $0 >= 0 } ?? false) : checkedAtMs == nil)
    }
}

extension RemoteHTTPPaths {
    public static let phoneSourceRetirement = "/v1/sync/local-library/source-retirement"
}

public enum RemotePhoneSourceRetirementOutcome: String, Codable, Sendable {
    case completed, failed, outcomeUnknown
}

public struct RemotePhoneSourceRetirementBinding: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let hostID: UUID
    public let deviceID: UUID
    public let requestID: UUID
    public let sourceReportID: UUID
    public let migrationID: UUID
    public let sourceInstallID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let completionReceiptID: UUID
    public let backupReceiptID: UUID
    public let manifestSHA256: String
    public let factSnapshotSHA256: String
    public let candidateCount: Int
    public let candidateSHA256: String

    public init(operationID: UUID, hostID: UUID, deviceID: UUID, requestID: UUID, sourceReportID: UUID,
        migrationID: UUID, sourceInstallID: UUID, sourceEpoch: UUID, scopeRevision: Int64,
        completionReceiptID: UUID, backupReceiptID: UUID, manifestSHA256: String,
        factSnapshotSHA256: String, candidateAssetIDs: [UUID]) {
        self.operationID = operationID; self.hostID = hostID; self.deviceID = deviceID
        self.requestID = requestID; self.sourceReportID = sourceReportID; self.migrationID = migrationID
        self.sourceInstallID = sourceInstallID; self.sourceEpoch = sourceEpoch; self.scopeRevision = scopeRevision
        self.completionReceiptID = completionReceiptID; self.backupReceiptID = backupReceiptID
        self.manifestSHA256 = manifestSHA256; self.factSnapshotSHA256 = factSnapshotSHA256
        self.candidateCount = candidateAssetIDs.count
        self.candidateSHA256 = Self.candidateDigest(candidateAssetIDs)
    }

    public static func candidateDigest(_ ids: [UUID]) -> String {
        let canonical = ids.map { $0.uuidString.lowercased() }.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A historical source outcome only. Receiving it must never mutate archive files
/// or shared human facts, and unknown must never be interpreted as deletion.
public struct RemotePhoneSourceRetirement: Codable, Sendable, Equatable {
    public let binding: RemotePhoneSourceRetirementBinding
    public let outcome: RemotePhoneSourceRetirementOutcome
    public let updatedAtMs: Int64
    public init(binding: RemotePhoneSourceRetirementBinding, outcome: RemotePhoneSourceRetirementOutcome, updatedAtMs: Int64) {
        self.binding = binding; self.outcome = outcome; self.updatedAtMs = updatedAtMs
    }
    public var isValid: Bool {
        updatedAtMs >= 0 && binding.scopeRevision >= 0 && binding.candidateCount > 0
            && binding.candidateCount <= 1_000_000
            && [binding.manifestSHA256, binding.factSnapshotSHA256, binding.candidateSHA256].allSatisfy {
                $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) }
            }
    }
}

public struct RemotePhoneSourceRetirementReceipt: Codable, Sendable, Equatable {
    public let report: RemotePhoneSourceRetirement
    public let receivedAtMs: Int64
    public init(report: RemotePhoneSourceRetirement, receivedAtMs: Int64) {
        self.report = report; self.receivedAtMs = receivedAtMs
    }
}
