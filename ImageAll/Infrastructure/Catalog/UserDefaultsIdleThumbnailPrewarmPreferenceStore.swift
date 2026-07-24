import Foundation

final class UserDefaultsIdleThumbnailPrewarmPreferenceStore:
    IdleThumbnailPrewarmPreferenceStore,
    @unchecked Sendable
{
    private static let enabledKey = "library.idle-thumbnail-prewarm.enabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Defaults to ON when the preference key has never been written.
    var isEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.enabledKey) != nil else {
                return true
            }
            return defaults.bool(forKey: Self.enabledKey)
        }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
        }
    }
}
