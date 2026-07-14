import XCTest
@testable import ImageAll

final class DomainErrorTests: XCTestCase {
    func testDomainErrorsAreEquatableAndSendable() {
        let errors: [DomainError] = [
            .invalidName,
            .duplicateTag,
            .invalidStateTransition,
            .revisionRegression,
            .locatorConflict,
            .referenceNotFound,
        ]

        XCTAssertEqual(errors, errors)
        assertSendable(errors)
    }

    func testClosedVocabularyRawValuesMatchSpec() {
        XCTAssertEqual(SourceKind.folder.rawValue, "folder")
        XCTAssertEqual(SourceKind.photos.rawValue, "photos")
        XCTAssertEqual(SourceState.unavailable.rawValue, "unavailable")
        XCTAssertEqual(AssetAvailability.missing.rawValue, "missing")
        XCTAssertEqual(PersistableTagDecision.accepted.rawValue, "accepted")
        XCTAssertEqual(PersistableTagDecision.rejected.rawValue, "rejected")
    }

    private func assertSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
