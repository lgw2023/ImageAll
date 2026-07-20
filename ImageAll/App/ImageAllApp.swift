import SwiftUI

@main
struct ImageAllApp: App {
    @StateObject private var startupModel: CatalogStartupModel
    @StateObject private var modelSettingsModel: AppModelSettingsModel

    init() {
        let root = CompositionRoot()
        let modelActivationCoordinator = CompositionRoot.makeAppModelActivationCoordinator()
        _startupModel = StateObject(
            wrappedValue: root.makeStartupModel(
                modelActivationCoordinator: modelActivationCoordinator
            )
        )
        _modelSettingsModel = StateObject(
            wrappedValue: CompositionRoot.makeAppModelSettingsModel(
                coordinator: modelActivationCoordinator
            )
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
