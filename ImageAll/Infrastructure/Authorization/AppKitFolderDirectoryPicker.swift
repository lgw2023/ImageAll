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

    func pickDirectory(initialDirectoryURL: URL?) -> URL? {
        let panel = panelFactory()
        panel.directoryURL = initialDirectoryURL
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

    static func makeMutationAuthorizationPanel() -> NSOpenPanel {
        let panel = makeProductionPanel()
        panel.title = "升级旧来源的一次性权限"
        panel.prompt = "授权并继续"
        panel.message =
            "这个来源由旧版本以只读方式导入。请选择原文件夹完成一次兼容升级；今后各功能不会再次要求授权。"
        return panel
    }

    static func makeSourceImportPanel() -> NSOpenPanel {
        let panel = makeProductionPanel()
        panel.title = "导入 ImageAll 图库来源"
        panel.prompt = "导入来源"
        panel.message =
            "选择一次来源文件夹后，ImageAll 将保存持续访问权限；只有您确认移入回收站时才会移动原文件。"
        return panel
    }
}

extension AppKitFolderDirectoryPicker: AppStorageRootPicking {
    func pickCacheRoot() -> URL? {
        pickDirectory()
    }
}
