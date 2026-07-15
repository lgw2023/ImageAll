import AppKit
import Foundation

@MainActor
struct AppKitFolderDirectoryPicker: FolderDirectoryPickerPort {
    private let panelFactory: @MainActor () -> NSOpenPanel
    private let runModal: @MainActor (NSOpenPanel) -> NSApplication.ModalResponse

    init(
        panelFactory: @escaping @MainActor () -> NSOpenPanel = { AppKitFolderDirectoryPicker.makeProductionPanel() },
        runModal: @escaping @MainActor (NSOpenPanel) -> NSApplication.ModalResponse = { panel in
            panel.runModal()
        }
    ) {
        self.panelFactory = panelFactory
        self.runModal = runModal
    }

    func pickDirectory() -> URL? {
        let panel = panelFactory()
        guard runModal(panel) == .OK, let url = panel.url else {
            return nil
        }
        return url
    }

    static func makeProductionPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = false
        panel.canCreateDirectories = false
        return panel
    }
}
