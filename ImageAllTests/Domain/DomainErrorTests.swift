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

        XCTAssertEqual(SourceState.active.rawValue, "active")
        XCTAssertEqual(SourceState.disabled.rawValue, "disabled")
        XCTAssertEqual(SourceState.unavailable.rawValue, "unavailable")
        XCTAssertEqual(SourceState.authorizationRequired.rawValue, "authorizationRequired")

        XCTAssertEqual(AssetLocatorKind.file.rawValue, "file")
        XCTAssertEqual(AssetLocatorKind.photos.rawValue, "photos")

        XCTAssertEqual(AssetLocatorState.current.rawValue, "current")
        XCTAssertEqual(AssetLocatorState.historical.rawValue, "historical")

        XCTAssertEqual(AssetAvailability.available.rawValue, "available")
        XCTAssertEqual(AssetAvailability.missing.rawValue, "missing")
        XCTAssertEqual(AssetAvailability.unreadable.rawValue, "unreadable")
        XCTAssertEqual(AssetAvailability.unsupported.rawValue, "unsupported")

        XCTAssertEqual(TagState.active.rawValue, "active")
        XCTAssertEqual(TagState.archived.rawValue, "archived")

        XCTAssertEqual(PersistableTagDecision.accepted.rawValue, "accepted")
        XCTAssertEqual(PersistableTagDecision.rejected.rawValue, "rejected")
    }

    private func assertSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
