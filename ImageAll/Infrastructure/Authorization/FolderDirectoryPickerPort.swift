import Foundation

@preconcurrency
@MainActor
protocol FolderDirectoryPickerPort: Sendable {
    func pickDirectory(initialDirectoryURL: URL?) -> URL?
}

extension FolderDirectoryPickerPort {
    func pickDirectory() -> URL? {
        pickDirectory(initialDirectoryURL: nil)
    }
}
