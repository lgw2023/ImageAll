import XCTest
@testable import ImageAll

final class SourceAssetRulesTests: XCTestCase {
    func testNewAssetStartsAtRevisionOne() {
        let asset = AssetRevisionRules.makeNewAsset(sourceID: UUID())
        XCTAssertEqual(asset.contentRevision, 1)
    }

    func testContentRevisionRejectsEqualValue() {
        let asset = AssetRevisionRules.makeNewAsset(sourceID: UUID())
        let result = AssetRevisionRules.advanceContentRevision(asset: asset, proposedRevision: 1)

        guard case .failure(.revisionRegression) = result else {
            return XCTFail("Expected revisionRegression when proposed revision is equal")
        }
    }

    func testContentRevisionRejectsLowerValue() {
        let asset = Asset(id: UUID(), sourceID: UUID(), contentRevision: 3, locatorState: .current, availability: .available)
        let result = AssetRevisionRules.advanceContentRevision(asset: asset, proposedRevision: 2)

        guard case .failure(.revisionRegression) = result else {
            return XCTFail("Expected revisionRegression when proposed revision is lower")
        }
    }

    func testContentRevisionAdvancePreservesAssetIdentityAndInvalidatesDerivedData() {
        let asset = AssetRevisionRules.makeNewAsset(sourceID: UUID())
        let result = AssetRevisionRules.advanceContentRevision(asset: asset, proposedRevision: 2)

        guard case let .success(advance) = result else {
            return XCTFail("Expected successful revision advance")
        }
        XCTAssertEqual(advance.assetID, asset.id)
        XCTAssertEqual(advance.previousRevision, 1)
        XCTAssertEqual(advance.newRevision, 2)
        XCTAssertTrue(advance.derivedDataInvalidated)
    }

    func testSourceDisableIsIdempotent() {
        let source = Source(id: UUID(), kind: .folder, state: .active)
        let first = SourceRules.disable(source)
        let second = SourceRules.disable(first)

        XCTAssertEqual(first.state, .disabled)
        XCTAssertEqual(second.state, .disabled)
        XCTAssertEqual(second.id, source.id)
    }

    func testSourceDisableDoesNotDeleteRelatedFacts() {
        let source = Source(id: UUID(), kind: .folder, state: .active)
        let asset = AssetRevisionRules.makeNewAsset(sourceID: source.id)
        let tag = Tag(
            id: UUID(),
            displayName: "Family",
            normalizedName: "family",
            normalizedNameKey: Data("family".utf8),
            state: .active
        )
        let decisions: [UUID: TagDecisionQueryState] = [asset.id: .accepted]

        let disabled = SourceRules.disable(source)

        XCTAssertEqual(disabled.state, .disabled)
        XCTAssertEqual(asset.sourceID, source.id)
        XCTAssertEqual(decisions[asset.id], .accepted)
        XCTAssertEqual(tag.state, .active)
    }

    func testIncompleteGenerationCannotMarkUnseenAssetMissing() {
        XCTAssertFalse(ScanGenerationRules.canMarkUnseenAssetMissing(completion: .incomplete))
    }

    func testCompleteGenerationCanMarkUnseenAssetMissing() {
        XCTAssertTrue(ScanGenerationRules.canMarkUnseenAssetMissing(completion: .complete))
    }

    func testUnavailableSourceDoesNotImplyGenerationComplete() {
        XCTAssertNil(ScanGenerationRules.generationCompletionInferredFromSourceState(.unavailable))
    }

    func testReconcileCleanRequiresMatchingDirtyEpoch() {
        XCTAssertFalse(
            ScanGenerationRules.isSourceReconcileClean(
                dirtyEpoch: 2,
                lastCompletedJobStartedDirtyEpoch: nil
            )
        )
        XCTAssertFalse(
            ScanGenerationRules.isSourceReconcileClean(
                dirtyEpoch: 2,
                lastCompletedJobStartedDirtyEpoch: 1
            )
        )
        XCTAssertTrue(
            ScanGenerationRules.isSourceReconcileClean(
                dirtyEpoch: 2,
                lastCompletedJobStartedDirtyEpoch: 2
            )
        )
    }

    func testUnavailableSourceDoesNotReleaseCurrentLocator() {
        XCTAssertFalse(SourceRules.releasesCurrentLocator(whenSourceBecomes: .unavailable))
    }

    func testSameResourceRetainsAssetID() {
        let asset = AssetRevisionRules.makeNewAsset(sourceID: UUID())
        let result = LocatorIdentityRules.resolve(existingAsset: asset, judgment: .same)

        guard case let .success(outcome) = result else {
            return XCTFail("Expected same-resource resolution to succeed")
        }
        XCTAssertEqual(outcome.retainedAssetID, asset.id)
        XCTAssertNil(outcome.newAssetID)
        XCTAssertTrue(outcome.inheritsDecisions)
    }

    func testDifferentResourceCreatesNewAssetWithoutInheritedDecisions() {
        let asset = AssetRevisionRules.makeNewAsset(sourceID: UUID())
        let newAssetID = UUID()
        let result = LocatorIdentityRules.resolve(
            existingAsset: asset,
            judgment: .different,
            newAssetID: newAssetID
        )

        guard case let .success(outcome) = result else {
            return XCTFail("Expected different-resource resolution to succeed")
        }
        XCTAssertEqual(outcome.historicalAssetID, asset.id)
        XCTAssertEqual(outcome.newAssetID, newAssetID)
        XCTAssertFalse(outcome.inheritsDecisions)
    }

    func testIndeterminateResourceIdentityReturnsLocatorConflict() {
        let asset = AssetRevisionRules.makeNewAsset(sourceID: UUID())
        let result = LocatorIdentityRules.resolve(existingAsset: asset, judgment: .indeterminate)

        guard case .failure(.locatorConflict) = result else {
            return XCTFail("Expected locatorConflict for indeterminate identity")
        }
    }
}
