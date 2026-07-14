import Foundation

struct CompositionRoot {
    func makeStartupPresentation() -> StartupPresentation {
        StartupPresentation(productName: "ImageAll", foundationReady: true)
    }
}
