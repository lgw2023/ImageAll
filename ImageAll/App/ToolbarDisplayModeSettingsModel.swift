import SwiftUI

@MainActor
final class ToolbarDisplayModeSettingsModel: ObservableObject {
    @Published private(set) var displayMode: LibraryToolbarDisplayMode

    private let store: any ToolbarDisplayModePreferenceStore

    init(
        store: any ToolbarDisplayModePreferenceStore =
            UserDefaultsToolbarDisplayModePreferenceStore()
    ) {
        self.store = store
        displayMode = store.displayMode
    }

    func setDisplayMode(_ mode: LibraryToolbarDisplayMode) {
        guard displayMode != mode else { return }
        store.displayMode = mode
        displayMode = mode
    }

    func refresh() {
        displayMode = store.displayMode
    }
}
