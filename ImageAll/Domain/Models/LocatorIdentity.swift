import Foundation

struct LocatorIdentityOutcome: Equatable, Sendable {
    let retainedAssetID: UUID?
    let historicalAssetID: UUID?
    let newAssetID: UUID?
    let inheritsDecisions: Bool
}
