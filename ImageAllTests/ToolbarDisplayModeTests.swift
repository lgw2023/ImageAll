import XCTest

@testable import ImageAll

final class ToolbarDisplayModeTests: XCTestCase {
    func testDisplayModeDefaultsToIconOnly() {
        let defaults = UserDefaults(suiteName: "ToolbarDisplayModeTests-default")!
        defaults.removePersistentDomain(forName: "ToolbarDisplayModeTests-default")
        let store = UserDefaultsToolbarDisplayModePreferenceStore(defaults: defaults)

        XCTAssertEqual(store.displayMode, .iconOnly)
    }

    func testDisplayModePersistsSelection() {
        let defaults = UserDefaults(suiteName: "ToolbarDisplayModeTests-persist")!
        defaults.removePersistentDomain(forName: "ToolbarDisplayModeTests-persist")
        let store = UserDefaultsToolbarDisplayModePreferenceStore(defaults: defaults)

        store.displayMode = .iconAndTitle
        let reopened = UserDefaultsToolbarDisplayModePreferenceStore(defaults: defaults)

        XCTAssertEqual(reopened.displayMode, .iconAndTitle)
    }

    @MainActor
    func testSettingsModelUpdatesPublishedValue() {
        let defaults = UserDefaults(suiteName: "ToolbarDisplayModeTests-model")!
        defaults.removePersistentDomain(forName: "ToolbarDisplayModeTests-model")
        let store = UserDefaultsToolbarDisplayModePreferenceStore(defaults: defaults)
        let model = ToolbarDisplayModeSettingsModel(store: store)

        XCTAssertEqual(model.displayMode, .iconOnly)

        model.setDisplayMode(.iconAndTitle)

        XCTAssertEqual(model.displayMode, .iconAndTitle)
        XCTAssertEqual(store.displayMode, .iconAndTitle)
    }
}

final class PersistentHoverHelpSessionTests: XCTestCase {
    func testHelpRemainsVisibleUntilPointerLeavesSameButton() {
        let owner = UUID()
        var session = PersistentHoverHelpSession()

        session.enter(owner: owner)
        XCTAssertTrue(session.reveal(owner: owner))
        XCTAssertEqual(session.visibleOwner, owner)

        XCTAssertTrue(session.reveal(owner: owner))
        XCTAssertEqual(session.visibleOwner, owner)

        XCTAssertTrue(session.leave(owner: owner))
        XCTAssertNil(session.hoveredOwner)
        XCTAssertNil(session.visibleOwner)
    }

    func testStaleButtonCannotRevealOrHideCurrentButtonsHelp() {
        let firstOwner = UUID()
        let secondOwner = UUID()
        var session = PersistentHoverHelpSession()

        session.enter(owner: firstOwner)
        session.enter(owner: secondOwner)

        XCTAssertFalse(session.reveal(owner: firstOwner))
        XCTAssertTrue(session.reveal(owner: secondOwner))
        XCTAssertFalse(session.leave(owner: firstOwner))
        XCTAssertEqual(session.visibleOwner, secondOwner)
    }
}
