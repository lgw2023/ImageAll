import SwiftUI
import ImageAllRemoteClient
import ImageAllRemoteProtocol

@main
struct ImageAllMobileApp: App {
    @StateObject private var model = RemoteCompanionModel()
    @StateObject private var localModel = LocalLibraryModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    LocalLibraryView(model: localModel)
                }
                .tabItem { Label("此 iPhone", systemImage: "iphone.gen3") }

                RemoteCompanionRootView(model: model)
                    .tabItem { Label("Mac 图库", systemImage: "desktopcomputer") }
            }
        }
    }
}
