import SwiftUI

@main
struct ImageAllApp: App {
    @StateObject private var startupModel: CatalogStartupModel
    @StateObject private var modelSettingsModel: AppModelSettingsModel

    init() {
        let root = CompositionRoot()
        _startupModel = StateObject(wrappedValue: root.makeStartupModel())
        _modelSettingsModel = StateObject(
            wrappedValue: CompositionRoot.makeAppModelSettingsModel()
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                presentation: startupModel.presentation,
                workspaceModel: startupModel.workspaceModel
            )
            .task {
                await modelSettingsModel.start()
            }
        }
        Settings {
            AppModelSettingsView(model: modelSettingsModel)
        }
    }
}
