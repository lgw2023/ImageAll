import Foundation

protocol TagDecisionCommandPort: Sendable {
    func createTag(rawName: String, timestampMs: Int64) throws -> Tag
    func createMissingTags(rawNames: [String], timestampMs: Int64) throws -> [Tag]
    func batchAccept(tagID: UUID, assetIDs: [UUID], timestampMs: Int64) throws -> TagMutationResult
    func batchReject(tagID: UUID, assetIDs: [UUID], timestampMs: Int64) throws -> TagMutationResult
    func batchClear(tagID: UUID, assetIDs: [UUID], timestampMs: Int64) throws -> TagMutationResult
    func createTagAndApply(
        rawName: String,
        assetIDs: [UUID],
        decision: PersistableTagDecision,
        timestampMs: Int64
    ) throws -> TagCreateAndApplyResult
    func restorePriorStates(_ snapshot: TagMutationPriorStateSnapshot, timestampMs: Int64) throws
    func moveTag(tagID: UUID, toGroupID: UUID, timestampMs: Int64) throws -> TagListItem
    func createTagGroup(rawName: String, timestampMs: Int64) throws -> TagGroupListItem
    func renameTagGroup(groupID: UUID, rawName: String, timestampMs: Int64) throws -> TagGroupListItem
    func deleteTagGroup(groupID: UUID, timestampMs: Int64) throws
}

enum ContextualTagFeedState: String, Equatable, Sendable {
    case pending
    case dismissed
    case resolved
}

enum ContextualTagFeedMemberRole: String, Equatable, Sendable {
    case anchor
    case candidate
}

enum ContextualTagFeedEvidenceKind: String, CaseIterable, Equatable, Sendable {
    case captureTime
    case spatialProximity
    case filenameSequence
    case sourceContext
    case captureDevice

    var bit: Int {
        switch self {
        case .captureTime: 1 << 0
        case .spatialProximity: 1 << 1
        case .filenameSequence: 1 << 2
        case .sourceContext: 1 << 3
        case .captureDevice: 1 << 4
        }
    }
}

struct ContextualTagFeedEvidence: Equatable, Sendable {
    let kind: ContextualTagFeedEvidenceKind
    let strength: Double
    let deltaMs: Int64?
    let distanceM: Double?
    let sequenceOffset: Int?
    let provenance: String?
}

struct ContextualTagFeedMember: Identifiable, Equatable, Sendable {
    var id: UUID { assetID }

    let assetID: UUID
    let role: ContextualTagFeedMemberRole
    let rank: Int
    let fileName: String?
    let mediaKind: MediaKind
    let mediaCreatedAtMs: Int64?
    let evidence: [ContextualTagFeedEvidence]
}

struct ContextualTagFeedGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    let tagID: UUID
    let tagDisplayName: String
    let anchorAssetID: UUID
    let sourceID: UUID
    let state: ContextualTagFeedState
    let revision: Int
    let policyRevision: String
    let members: [ContextualTagFeedMember]
}

enum ContextualTagFeedError: Error, Equatable, Sendable {
    case feedChanged
    case invalidSelection
    case persistenceFailure
}

protocol ContextualTagFeedPort: Sendable {
    func generate(tagID: UUID, anchorAssetID: UUID, timestampMs: Int64) throws
        -> ContextualTagFeedGroup?
    func pendingCount() throws -> Int
    func fetchPendingGroups(limit: Int) throws -> [ContextualTagFeedGroup]
    @discardableResult
    func refreshRecentAcceptedAnchors(limit: Int, timestampMs: Int64) throws -> Int
    func dismiss(feedID: UUID, revision: Int, timestampMs: Int64) throws
    func resolve(
        feedID: UUID,
        revision: Int,
        selectedAssetIDs: [UUID],
        decision: PersistableTagDecision,
        timestampMs: Int64
    ) throws -> TagMutationPriorStateSnapshot
}

struct EmptyContextualTagFeedPort: ContextualTagFeedPort, Sendable {
    func generate(tagID _: UUID, anchorAssetID _: UUID, timestampMs _: Int64) throws
        -> ContextualTagFeedGroup?
    {
        nil
    }

    func pendingCount() throws -> Int { 0 }
    func fetchPendingGroups(limit _: Int) throws -> [ContextualTagFeedGroup] { [] }
    func refreshRecentAcceptedAnchors(limit _: Int, timestampMs _: Int64) throws -> Int { 0 }
    func dismiss(feedID _: UUID, revision _: Int, timestampMs _: Int64) throws {}
    func resolve(
        feedID _: UUID,
        revision _: Int,
        selectedAssetIDs _: [UUID],
        decision _: PersistableTagDecision,
        timestampMs _: Int64
    ) throws -> TagMutationPriorStateSnapshot {
        throw ContextualTagFeedError.persistenceFailure
    }
}
