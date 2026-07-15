import AppKit
import Foundation

struct AppKitFolderDirectoryPicker: FolderDirectoryPickerPort {
    private let panelFactory: @Sendable () -> NSOpenPanel
    private let runModal: @Sendable (NSOpenPanel) -> NSApplication.ModalResponse

    init(
        panelFactory: @escaping @Sendable () -> NSOpenPanel = FolderDirectoryPickerPanelConfiguration.productionPanel,
        runModal: @escaping @Sendable (NSOpenPanel) -> NSApplication.ModalResponse = { panel in
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
}
