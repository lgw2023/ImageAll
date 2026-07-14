import Foundation

enum AssetRevisionRules {
    static let initialRevision = 1

    static func makeNewAsset(
        id: UUID = UUID(),
        sourceID: UUID,
        locatorState: AssetLocatorState = .current,
        availability: AssetAvailability = .available
    ) -> Asset {
        Asset(
            id: id,
            sourceID: sourceID,
            contentRevision: initialRevision,
            locatorState: locatorState,
            availability: availability
        )
    }

    static func advanceContentRevision(
        asset: Asset,
        proposedRevision: Int
    ) -> Result<ContentRevisionAdvance, DomainError> {
        guard proposedRevision > asset.contentRevision else {
            return .failure(.revisionRegression)
        }

        return .success(
            ContentRevisionAdvance(
                assetID: asset.id,
                previousRevision: asset.contentRevision,
                newRevision: proposedRevision,
                derivedDataInvalidated: true
            )
        )
    }
}
