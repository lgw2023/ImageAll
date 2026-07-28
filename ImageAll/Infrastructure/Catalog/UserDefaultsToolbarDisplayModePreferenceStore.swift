import Foundation

final class UserDefaultsToolbarDisplayModePreferenceStore:
    ToolbarDisplayModePreferenceStore,
    @unchecked Sendable
{
    private static let displayModeKey = "library.toolbar.display-mode"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var displayMode: LibraryToolbarDisplayMode {
        get {
            guard let raw = defaults.string(forKey: Self.displayModeKey),
                  let mode = LibraryToolbarDisplayMode(rawValue: raw)
            else {
                return .iconOnly
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.displayModeKey)
        }
    }
}
