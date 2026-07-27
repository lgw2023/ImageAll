import SwiftUI
import ImageAllRemoteClient
import ImageAllRemoteProtocol

@main
struct ImageAllMobileApp: App {
    @StateObject private var model = RemoteCompanionModel()

    var body: some Scene {
        WindowGroup {
            RemoteCompanionRootView(model: model)
        }
    }
}
