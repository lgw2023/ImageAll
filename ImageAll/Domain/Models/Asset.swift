import Foundation

struct Asset: Equatable, Sendable {
    let id: UUID
    let sourceID: UUID
    var contentRevision: Int
    var locatorState: AssetLocatorState
    var availability: AssetAvailability
}

struct ContentRevisionAdvance: Equatable, Sendable {
    let assetID: UUID
    let previousRevision: Int
    let newRevision: Int
    let derivedDataInvalidated: Bool
}
