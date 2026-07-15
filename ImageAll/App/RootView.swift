import SwiftUI

struct RootView: View {
    let presentation: StartupPresentation
    let workspaceModel: LibraryWorkspaceModel?

    init(
        presentation: StartupPresentation,
        workspaceModel: LibraryWorkspaceModel? = nil
    ) {
        self.presentation = presentation
        self.workspaceModel = workspaceModel
    }

    var body: some View {
        switch presentation.catalogState {
        case .catalogReady:
            if let workspaceModel {
                LibraryWorkspaceView(model: workspaceModel)
            } else {
                startupStatus
            }
        case .starting, .anotherInstanceRunning, .catalogUnavailable:
            startupStatus
        }
    }

    private var startupStatus: some View {
        VStack(spacing: 12) {
            Text(presentation.productName).font(.title)
            ProgressView()
                .opacity(isStarting ? 1 : 0)
            Text(presentation.catalogState.displayToken)
                .font(.body.monospaced())
                .accessibilityIdentifier("catalogStateToken")
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 240)
    }

    private var isStarting: Bool {
        if case .starting = presentation.catalogState { return true }
        return false
    }
}

#if DEBUG
#Preview {
    RootView(
        presentation: StartupPresentation(
            productName: "ImageAll",
            foundationReady: true,
            catalogState: .catalogReady
        )
    )
}
#endif
