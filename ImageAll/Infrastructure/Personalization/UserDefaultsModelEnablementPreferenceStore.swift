import Foundation

final class UserDefaultsModelEnablementPreferenceStore: ModelEnablementPreferenceStore, @unchecked Sendable {
    private static let enabledKey = "model.dinov2-small.enabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }
}
