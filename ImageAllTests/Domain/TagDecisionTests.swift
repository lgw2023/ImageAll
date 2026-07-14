import XCTest
@testable import ImageAll

final class TagDecisionTests: XCTestCase {
    func testUnknownToAccepted() {
        let next = TagDecisionRules.applyDecision(current: .unknown, decision: .accepted)
        XCTAssertEqual(next, .accepted)
    }

    func testUnknownToRejected() {
        let next = TagDecisionRules.applyDecision(current: .unknown, decision: .rejected)
        XCTAssertEqual(next, .rejected)
    }

    func testAcceptedToRejectedReplacesExistingDecision() {
        let next = TagDecisionRules.applyDecision(current: .accepted, decision: .rejected)
        XCTAssertEqual(next, .rejected)
    }

    func testRejectedToAcceptedReplacesExistingDecision() {
        let next = TagDecisionRules.applyDecision(current: .rejected, decision: .accepted)
        XCTAssertEqual(next, .accepted)
    }

    func testClearDecisionReturnsUnknown() {
        XCTAssertEqual(TagDecisionRules.clearDecision(current: .accepted), .unknown)
        XCTAssertEqual(TagDecisionRules.clearDecision(current: .rejected), .unknown)
    }

    func testUnknownIsNotPersistableDecision() {
        let unknown: TagDecisionQueryState = .unknown
        switch unknown {
        case .unknown:
            break
        case .accepted, .rejected:
            XCTFail("unknown must not be treated as a persistable decision")
        }
    }

    func testArchivedTagRejectsBatchApplyAndPreservesInput() {
        let assetID = UUID()
        let original: [UUID: TagDecisionQueryState] = [assetID: .accepted]

        let result = TagDecisionRules.applyBatchDecision(
            tagState: .archived,
            currentDecisions: original,
            decision: .rejected
        )

        guard case .failure(.invalidStateTransition) = result else {
            return XCTFail("Expected invalidStateTransition for archived tag batch apply")
        }
        XCTAssertEqual(original[assetID], .accepted)
    }

    func testActiveTagBatchApplyUpdatesDecisions() {
        let firstAsset = UUID()
        let secondAsset = UUID()
        let original: [UUID: TagDecisionQueryState] = [
            firstAsset: .unknown,
            secondAsset: .accepted,
        ]

        let result = TagDecisionRules.applyBatchDecision(
            tagState: .active,
            currentDecisions: original,
            decision: .rejected
        )

        guard case let .success(updated) = result else {
            return XCTFail("Expected batch apply to succeed for active tag")
        }
        XCTAssertEqual(updated[firstAsset], .rejected)
        XCTAssertEqual(updated[secondAsset], .rejected)
    }
}
