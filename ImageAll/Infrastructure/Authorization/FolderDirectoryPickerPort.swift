import AppKit
import Foundation

protocol FolderDirectoryPickerPort: Sendable {
    func pickDirectory() -> URL?
}

enum FolderDirectoryPickerPanelConfiguration {
    static func apply(to panel: NSOpenPanel) {
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = false
        panel.canCreateDirectories = false
    }

    static func productionPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        apply(to: panel)
        return panel
    }
}
