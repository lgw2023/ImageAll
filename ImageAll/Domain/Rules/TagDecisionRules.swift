import Foundation

enum TagDecisionRules {
    static func applyDecision(
        current: TagDecisionQueryState,
        decision: PersistableTagDecision
    ) -> TagDecisionQueryState {
        switch decision {
        case .accepted:
            .accepted
        case .rejected:
            .rejected
        }
    }

    static func clearDecision(current: TagDecisionQueryState) -> TagDecisionQueryState {
        .unknown
    }

    static func applyBatchDecision(
        tagState: TagState,
        currentDecisions: [UUID: TagDecisionQueryState],
        decision: PersistableTagDecision
    ) -> Result<[UUID: TagDecisionQueryState], DomainError> {
        guard tagState == .active else {
            return .failure(.invalidStateTransition)
        }

        var updated = currentDecisions
        for assetID in currentDecisions.keys {
            updated[assetID] = applyDecision(current: currentDecisions[assetID] ?? .unknown, decision: decision)
        }
        return .success(updated)
    }
}
