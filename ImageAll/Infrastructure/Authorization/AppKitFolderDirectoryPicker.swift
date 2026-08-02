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

    func pickDirectory(initialDirectoryURL: URL?) async -> URL? {
        let panel = panelFactory()
        panel.directoryURL = initialDirectoryURL
        NSApp.activate(ignoringOtherApps: true)
        // Escape the current Swift concurrency / MainActor stack before entering
        // AppKit's nested modal run loop. Calling `runModal()` directly after an
        // `await` (e.g. recycle → authorizeMutation) can leave the panel invisible
        // or never return, which freezes the UI on「正在移入回收站…」.
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let response = self.runModal(panel)
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
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
            "选择一次来源文件夹后，ImageAll 将保存持续访问权限；只有您确认快速删除或可恢复回收时才会改动原文件。"
        return panel
    }
}

extension AppKitFolderDirectoryPicker: AppStorageRootPicking {
    func pickCacheRoot() -> URL? {
        let panel = panelFactory()
        NSApp.activate(ignoringOtherApps: true)
        guard runModal(panel) == .OK, let url = panel.url else {
            return nil
        }
        return url
    }
}
