import Foundation

enum LibraryToolbarDisplayMode: String, CaseIterable, Sendable {
    case iconOnly
    case iconAndTitle

    var displayName: String {
        switch self {
        case .iconOnly: "仅图标"
        case .iconAndTitle: "图标与名称"
        }
    }
}

protocol ToolbarDisplayModePreferenceStore: AnyObject {
    var displayMode: LibraryToolbarDisplayMode { get set }
}
