import Foundation

@preconcurrency
@MainActor
protocol FolderDirectoryPickerPort: Sendable {
    func pickDirectory() -> URL?
}
