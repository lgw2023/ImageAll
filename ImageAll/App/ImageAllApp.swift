import SwiftUI

@main
struct ImageAllApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var startupModel: CatalogStartupModel
    @StateObject private var modelSettingsModel: AppModelSettingsModel
    @StateObject private var idlePrewarmSettingsModel: IdleThumbnailPrewarmSettingsModel
    @StateObject private var toolbarDisplayModeSettingsModel: ToolbarDisplayModeSettingsModel

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
        _toolbarDisplayModeSettingsModel = StateObject(
            wrappedValue: ToolbarDisplayModeSettingsModel()
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
            .environmentObject(toolbarDisplayModeSettingsModel)
            .task { await modelSettingsModel.start() }
            .onAppear { attachSettingsPortsIfReady() }
            .onChange(of: startupModel.workspaceModel != nil) { _, _ in
                attachSettingsPortsIfReady()
            }
            .onChange(of: idlePrewarmSettingsModel.isEnabled) { _, enabled in
                startupModel.workspaceModel?.setIdleThumbnailPrewarmEnabled(enabled)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await startupModel.workspaceModel?.applicationDidBecomeActive()
                }
            }
        }
        Settings {
            AppModelSettingsView(
                model: modelSettingsModel,
                idlePrewarmSettings: idlePrewarmSettingsModel,
                toolbarDisplayModeSettings: toolbarDisplayModeSettingsModel
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
