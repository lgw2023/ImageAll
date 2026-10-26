import XCTest
@testable import ImageAllRemoteProtocol

final class ImageAllPhoneImportReadinessTests: XCTestCase {
    func testConvergedSelectedFactsAllowMediaImport() {
        XCTAssertTrue(readiness().canStartMediaImport)
    }
    func testEveryUnfinishedFactChannelStopsMediaImport() {
        for blocked in [readiness(conflicts: 1), readiness(remaining: 1), readiness(deferred: 1),
                        readiness(tags: true), readiness(collections: true), readiness(favorites: true),
                        readiness(conflicts: -1)] {
            XCTAssertFalse(blocked.canStartMediaImport)
        }
    }
    private func readiness(conflicts: Int = 0, remaining: Int = 0, deferred: Int = 0,
                           tags: Bool = false, collections: Bool = false, favorites: Bool = false) -> ImageAllPhoneImportReadiness {
        .init(conflicts: conflicts, remainingOperations: remaining, deferredOperations: deferred,
              hasMoreTagChanges: tags, hasMoreCollectionChanges: collections, hasMoreFavoriteChanges: favorites)
    }
}
