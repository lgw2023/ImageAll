import SwiftUI

struct RootView: View {
    let presentation: StartupPresentation

    var body: some View {
        VStack(spacing: 12) {
            Text(presentation.productName)
                .font(.title)
            Text(presentation.foundationReady ? "foundationReady" : "foundationNotReady")
                .font(.body.monospaced())
        }
        .padding(24)
        .frame(minWidth: 320, minHeight: 180)
    }
}
