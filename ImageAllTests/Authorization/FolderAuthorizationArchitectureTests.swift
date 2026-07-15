import Foundation
import XCTest
@testable import ImageAll

final class FolderAuthorizationArchitectureTests: XCTestCase {
    func testApplicationAuthorizationErrorsDoNotLeakSensitiveFields() {
        let errors: [FolderAuthorizationError] = [
            .sourceNotFound,
            .sourceKindMismatch,
            .invalidSourceState,
            .invalidRoot,
            .sourceOverlap,
            .overlapIndeterminate,
            .identityMismatch,
            .identityIndeterminate,
            .bookmarkCreationFailed,
            .authorizationUnavailable,
            .persistenceFailure,
        ]

        for error in errors {
            let description = String(describing: error)
            XCTAssertFalse(description.contains("/Volumes/"))
            XCTAssertFalse(description.contains("/Users/"))
            XCTAssertFalse(description.localizedCaseInsensitiveContains("sqlite"))
        }
    }
}
