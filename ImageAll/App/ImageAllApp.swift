import SwiftUI

@main
struct ImageAllApp: App {
    @StateObject private var startupModel: CatalogStartupModel
    @StateObject private var modelSettingsModel: AppModelSettingsModel
    @StateObject private var idlePrewarmSettingsModel: IdleThumbnailPrewarmSettingsModel

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
        _idlePrewarmSettingsModel = StateObject(
            wrappedValue: IdleThumbnailPrewarmSettingsModel()
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                presentation: startupModel.presentation,
                workspaceModel: startupModel.workspaceModel,
                onCancelStorageMigration: {
                    startupModel.cancelStorageMigration()
                },
                onRetryBootstrap: {
                    startupModel.retryBootstrap()
                }
            )
            .task { await modelSettingsModel.start() }
            .onAppear { attachSettingsPortsIfReady() }
            .onChange(of: startupModel.workspaceModel != nil) { _, _ in
                attachSettingsPortsIfReady()
            }
            .onChange(of: idlePrewarmSettingsModel.isEnabled) { _, enabled in
                startupModel.workspaceModel?.setIdleThumbnailPrewarmEnabled(enabled)
            }
        }
        Settings {
            AppModelSettingsView(
                model: modelSettingsModel,
                idlePrewarmSettings: idlePrewarmSettingsModel
            )
            .onAppear { attachSettingsPortsIfReady() }
            .onChange(of: startupModel.workspaceModel != nil) { _, _ in
                attachSettingsPortsIfReady()
            }
        }
    }

    private func attachSettingsPortsIfReady() {
        modelSettingsModel.attachSuggestionThresholds(
            startupModel.workspaceModel?.suggestionThresholdPortForSettings
        )
        if let workspaceModel = startupModel.workspaceModel {
            workspaceModel.setIdleThumbnailPrewarmEnabled(idlePrewarmSettingsModel.isEnabled)
        }
    }
}
