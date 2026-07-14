import Foundation

struct TagListItem: Sendable, Equatable {
    let id: UUID
    let displayName: String
    let state: TagState
}

struct TagSelectionAggregate: Sendable, Equatable {
    let tagID: UUID
    let acceptedCount: Int
    let rejectedCount: Int
    let unknownCount: Int
}

struct TagMutationPriorState: Sendable, Equatable {
    let assetID: UUID
    let priorState: TagDecisionQueryState
}

struct TagMutationResult: Sendable, Equatable {
    let priorStates: [TagMutationPriorState]
}

struct TagMutationPriorStateSnapshot: Sendable, Equatable {
    let tagID: UUID
    let priorStates: [TagMutationPriorState]
}
