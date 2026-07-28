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
