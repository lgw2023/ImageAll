import SwiftUI

struct LibraryToolbarLabel: View {
    let title: String
    let systemImage: String
    let displayMode: LibraryToolbarDisplayMode

    var body: some View {
        switch displayMode {
        case .iconOnly:
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        case .iconAndTitle:
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
        }
    }
}

extension View {
    @ViewBuilder
    func libraryToolbarLabelStyle(_ displayMode: LibraryToolbarDisplayMode) -> some View {
        switch displayMode {
        case .iconOnly:
            labelStyle(.iconOnly)
        case .iconAndTitle:
            labelStyle(.titleAndIcon)
        }
    }

    func libraryToolbarHelp(_ title: String, detail: String? = nil) -> some View {
        help(detail ?? title)
    }
}
