import AppKit
import SwiftUI

struct PersistentHoverHelpSession: Equatable {
    private(set) var hoveredOwner: UUID?
    private(set) var visibleOwner: UUID?

    mutating func enter(owner: UUID) {
        hoveredOwner = owner
        visibleOwner = nil
    }

    mutating func reveal(owner: UUID) -> Bool {
        guard hoveredOwner == owner else { return false }
        visibleOwner = owner
        return true
    }

    mutating func leave(owner: UUID) -> Bool {
        guard hoveredOwner == owner else { return false }
        hoveredOwner = nil
        visibleOwner = nil
        return true
    }
}

@MainActor
private final class PersistentHoverHelpPresenter {
    static let shared = PersistentHoverHelpPresenter()

    private let displayDelay: TimeInterval = 0.45
    private var session = PersistentHoverHelpSession()
    private var pendingReveal: DispatchWorkItem?
    private lazy var panel = makePanel()

    func enter(owner: UUID, text: String) {
        pendingReveal?.cancel()
        session.enter(owner: owner)
        panel.orderOut(nil)

        let mouseLocation = NSEvent.mouseLocation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.session.reveal(owner: owner) else { return }
            self.show(text: text, near: mouseLocation)
        }
        pendingReveal = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + displayDelay,
            execute: workItem
        )
    }

    func leave(owner: UUID) {
        guard session.leave(owner: owner) else { return }
        pendingReveal?.cancel()
        pendingReveal = nil
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }

    private func show(text: String, near mouseLocation: NSPoint) {
        let content = PersistentHoverHelpBubble(text: text)
        let hostingView = NSHostingView(rootView: content)
        hostingView.layoutSubtreeIfNeeded()

        let contentSize = hostingView.fittingSize
        panel.contentView = hostingView
        panel.setContentSize(contentSize)

        let fallbackFrame = NSScreen.main?.visibleFrame ?? .zero
        let visibleFrame = NSScreen.screens
            .first(where: { $0.frame.contains(mouseLocation) })?
            .visibleFrame ?? fallbackFrame
        let desiredOrigin = NSPoint(
            x: mouseLocation.x + 12,
            y: mouseLocation.y - contentSize.height - 16
        )
        let clampedOrigin = NSPoint(
            x: min(
                max(desiredOrigin.x, visibleFrame.minX + 8),
                visibleFrame.maxX - contentSize.width - 8
            ),
            y: min(
                max(desiredOrigin.y, visibleFrame.minY + 8),
                visibleFrame.maxY - contentSize.height - 8
            )
        )
        panel.setFrameOrigin(clampedOrigin)
        panel.orderFrontRegardless()
    }
}

private struct PersistentHoverHelpBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 360, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.7), lineWidth: 0.5)
            }
    }
}

private struct PersistentHoverHelpModifier: ViewModifier {
    let text: String
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onHover { isInside in
                if isInside {
                    PersistentHoverHelpPresenter.shared.enter(owner: owner, text: text)
                } else {
                    PersistentHoverHelpPresenter.shared.leave(owner: owner)
                }
            }
            .onDisappear {
                PersistentHoverHelpPresenter.shared.leave(owner: owner)
            }
            .accessibilityHint(Text(text))
    }
}

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
    func persistentHelp(_ text: String) -> some View {
        modifier(PersistentHoverHelpModifier(text: text))
    }

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
        persistentHelp(detail ?? title)
    }
}
