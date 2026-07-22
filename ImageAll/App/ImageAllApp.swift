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
            .task { await modelSettingsModel.start() }
            .onAppear { attachSuggestionThresholdPortIfReady() }
            .onChange(of: startupModel.workspaceModel != nil) { _, _ in
                attachSuggestionThresholdPortIfReady()
            }
        }
        Settings {
            AppModelSettingsView(model: modelSettingsModel)
                .onAppear { attachSuggestionThresholdPortIfReady() }
                .onChange(of: startupModel.workspaceModel != nil) { _, _ in
                    attachSuggestionThresholdPortIfReady()
                }
        }
    }

    private func attachSuggestionThresholdPortIfReady() {
        modelSettingsModel.attachSuggestionThresholds(
            startupModel.workspaceModel?.suggestionThresholdPortForSettings
        )
    }
}
