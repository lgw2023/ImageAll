import Foundation
import SwiftUI

@MainActor
final class IdleThumbnailPrewarmSettingsModel: ObservableObject {
    @Published private(set) var isEnabled: Bool

    private let store: any IdleThumbnailPrewarmPreferenceStore
    private let onChange: ((Bool) -> Void)?

    init(
        store: any IdleThumbnailPrewarmPreferenceStore = UserDefaultsIdleThumbnailPrewarmPreferenceStore(),
        onChange: ((Bool) -> Void)? = nil
    ) {
        self.store = store
        self.onChange = onChange
        isEnabled = store.isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        store.isEnabled = enabled
        isEnabled = enabled
        onChange?(enabled)
    }

    func refresh() {
        isEnabled = store.isEnabled
    }
}
