import SwiftUI

@main
struct ImageAllApp: App {
    private let startupPresentation: StartupPresentation

    init() {
        startupPresentation = CompositionRoot().makeStartupPresentation()
    }

    var body: some Scene {
        WindowGroup {
            RootView(presentation: startupPresentation)
        }
    }
}
