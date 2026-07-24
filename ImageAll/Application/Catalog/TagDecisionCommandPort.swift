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
