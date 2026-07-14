import Foundation

enum LocatorIdentityRules {
    static func resolve(
        existingAsset: Asset,
        judgment: ResourceIdentityJudgment,
        newAssetID: UUID = UUID()
    ) -> Result<LocatorIdentityOutcome, DomainError> {
        switch judgment {
        case .same:
            return .success(
                LocatorIdentityOutcome(
                    retainedAssetID: existingAsset.id,
                    historicalAssetID: nil,
                    newAssetID: nil,
                    inheritsDecisions: true
                )
            )
        case .different:
            return .success(
                LocatorIdentityOutcome(
                    retainedAssetID: nil,
                    historicalAssetID: existingAsset.id,
                    newAssetID: newAssetID,
                    inheritsDecisions: false
                )
            )
        case .indeterminate:
            return .failure(.locatorConflict)
        }
    }
}
