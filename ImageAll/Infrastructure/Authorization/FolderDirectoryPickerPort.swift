import Foundation

@preconcurrency
@MainActor
protocol FolderDirectoryPickerPort: Sendable {
    func pickDirectory(initialDirectoryURL: URL?) async -> URL?
}

extension FolderDirectoryPickerPort {
    func pickDirectory() async -> URL? {
        await pickDirectory(initialDirectoryURL: nil)
    }
}
