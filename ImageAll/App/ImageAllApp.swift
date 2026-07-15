import SwiftUI

@main
struct ImageAllApp: App {
    @StateObject private var startupModel: CatalogStartupModel

    init() {
        _startupModel = StateObject(wrappedValue: CompositionRoot().makeStartupModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                presentation: startupModel.presentation,
                workspaceModel: startupModel.workspaceModel
            )
        }
    }
}
